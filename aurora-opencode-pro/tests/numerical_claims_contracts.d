module numerical_claims_contracts;
import auroraopencode.core;
import auroraopencode.numericalclaims;
import auroraopencode.executioncontrol;
import auroraopencode.taskflow : acceptTaskRequest;
import std.conv : to;
import std.stdio : writeln;

void add(ref ChatSession s, string role, string text, string tool = "", string args = "", bool failed = false)
{
    ChatMessage m; m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = text; m.toolName = tool; m.toolArgs = args; m.failed = failed;
    s.messages ~= m; s.activeLeafId = m.id;
    if (role == "user") acceptTaskRequest(s, text, m.id);
}
int main()
{
    ChatSession s;
    add(s, "user", "Read invoice.py without changing files. Independently calculate the current and required results. Return only JSON.");
    add(s, "tool", "44.1\n49\n54.0\nVerification receipt: {\"inputsSha256\":\"48.60\"}", "run",
        `{"program":"python","args":["-B","-c","import invoice; print(invoice.total(49,True))"]}`);
    add(s, "assistant", `{"current":"44.10","required":"48.60","at_60_with_coupon":"54.00"}`);
    assert(unobservedNumericalClaim(s) == "48.60");
    const pending = executionState(s);
    assert(pending.numericalGroundingMissing && executionShouldContinue(s, true, pending),
        "An observed current result allowed an uncalculated required value to finish");
    add(s, "tool", `{"results":[{"expression":"48.60","value":49.1}]}`, "calculate", "{}");
    add(s, "assistant", `{"current":"44.10","required":"48.60","at_60_with_coupon":"54.00"}`);
    assert(unobservedNumericalClaim(s) == "48.60", "An expression literal was treated as a calculated result");
    add(s, "assistant", `{"current":"4.410e1","required":"49.10","at_60_with_coupon":54}`);
    assert(!unobservedNumericalClaim(s).length && !executionState(s).numericalGroundingMissing);
    assert(s.verificationStatus == "not_required", "Numerical calculations created a verification recipe obligation");
    add(s, "assistant", `{"current":"44.10000000000001"}`);
    assert(unobservedNumericalClaim(s).length, "Float tolerance accepted a distinct decimal claim");
    ChatSession unavailable;
    add(unavailable, "user", "Read invoice.py without changing files. Independently calculate current and expected results. Return JSON.");
    add(unavailable, "tool", "Unavailable", "run", "{}", true);
    add(unavailable, "assistant", `{"current":null,"required":"49.10","limitation":"Execution unavailable; required value is source-based reasoning."}`);
    assert(!unobservedNumericalClaim(unavailable).length, "Unavailable execution forced an endless answer loop");
    ChatSession verified;
    add(verified, "user", "Read invoice.py without changing files. Independently compute current values. Return JSON.");
    add(verified, "tool", `{"steps":[{"output":"-0.00 1.2300e-3"}],"inputsSha256":"49.10"}`, "verify", "{}");
    add(verified, "assistant", `{"zero":"0","small":"0.00123","unsupported":"49.10"}`);
    const missing = unobservedNumericalClaim(verified);
    assert(missing == "49.10", "Unexpected missing value: " ~ missing);
    add(verified, "assistant", `{"zero":"0","small":"0.00123"}`);
    assert(!unobservedNumericalClaim(verified).length);
    add(verified, "assistant", `{"floating_json_number":0.00123}`);
    assert(!unobservedNumericalClaim(verified).length, "Unsupported binary-float serialization created an impossible exact-decimal gate");
    writeln("PASS decimal-string/integer JSON claims have calculation output; exact identity; no proof from expressions/receipts/failed tools; unsupported formats and unavailable execution stay reportable");
    return 0;
}
