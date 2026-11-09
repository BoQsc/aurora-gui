module inline_verification_contracts;

import auroraopencode.verificationrecipe : runVerificationRecipe, VerificationRun;
import auroraopencode.recipeevidence : RecipeEvidenceCache;
import auroraopencode.core : ChatMessage;
import auroraopencode.checkout : checkoutIdentity;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, exists;
import std.path : absolutePath, buildPath;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln, File;

void main()
{
    const workspace = absolutePath("inline-check-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    write(buildPath(workspace, "deliverable.txt"), "requested output");
    const args = `{"inputs":["deliverable.txt"],"steps":[{"kind":"tests","command":{"program":"checker"}}]}`;
    int runs;
    auto result = runVerificationRecipe(args, workspace,
        (JSONValue) { ++runs; return VerificationRun("Check passed", false, false); });
    assert(result.passed && runs == 1, result.output);
    const receipt = parseJSON(result.output);
    assert(receipt["recipe"].str == "inline" && receipt["inputs"].array[0].str == "deliverable.txt");
    assert(receipt["workspace"].str == workspace);
    assert(!exists(buildPath(workspace, "verify.json")), "One-off checking required a ceremony file");
    ChatMessage receiptMessage;
    receiptMessage.id = "inline-proof"; receiptMessage.toolName = "verify";
    receiptMessage.toolArgs = args; receiptMessage.content = result.output;
    receiptMessage.verificationCheck = result.check;
    RecipeEvidenceCache cache;
    cache.observe(receiptMessage);
    assert(cache.current(receiptMessage, checkoutIdentity(workspace) ~ "|1"),
        "Accepted inline receipt was lost during continuation/recovery");
    auto changed = runVerificationRecipe(args, workspace,
        (JSONValue) { write(buildPath(workspace, "deliverable.txt"), "changed"); return VerificationRun("OK", false, false); });
    assert(!changed.passed, "Inline checks weakened changed-input rejection");
    RecipeEvidenceCache afterChange;
    assert(!afterChange.current(receiptMessage, checkoutIdentity(workspace) ~ "|2"),
        "An old inline receipt accepted changed deliverable bytes");
    auto failed = runVerificationRecipe(args, workspace,
        (JSONValue) => VerificationRun("Failed assertion", true, false));
    assert(!failed.passed, "Inline checking accepted a failed process");
    // The live handoff is larger than the old receipt-inventory limit.
    auto archive = File(buildPath(workspace, "large.zip"), "wb");
    archive.seek(65 * 1024 * 1024);
    archive.rawWrite(cast(const(ubyte)[]) "end"); archive.close();
    const largeArgs = `{"inputs":["large.zip"],"steps":[{"kind":"tests","command":{"program":"checker"}}]}`;
    auto large = runVerificationRecipe(largeArgs, workspace,
        (JSONValue) => VerificationRun("OK", false, false));
    assert(large.passed, large.output);
    receiptMessage.id = "large-proof"; receiptMessage.toolArgs = largeArgs;
    receiptMessage.content = large.output; receiptMessage.verificationCheck = large.check;
    RecipeEvidenceCache largeCache;
    assert(largeCache.current(receiptMessage, checkoutIdentity(workspace) ~ "|3"),
        "A large passing archive became unverifiable during continuation");
    writeln("PASS one inline check, tracked deliverable, changed-input and failed-check rejection");
}
