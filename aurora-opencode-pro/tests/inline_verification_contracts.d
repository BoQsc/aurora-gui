module inline_verification_contracts;

import auroraopencode.verificationrecipe : runVerificationRecipe, VerificationRun, verificationInputsSignature;
import auroraopencode.recipeevidence : RecipeEvidenceCache;
import auroraopencode.core : ChatMessage;
import auroraopencode.checkout : checkoutIdentity, checkoutOwnsPath;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, exists, tempDir, remove;
import std.path : absolutePath, buildPath;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln, File;

void main()
{
    // Reproduced by a live provider: in a plain task folder every file was
    // mistaken for a separate checkout, making every behavioral check fail.
    const plain = buildPath(tempDir(), "aurora-nonrepo-check-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(buildPath(plain, "source"));
    write(buildPath(plain, "source", "output.txt"), "verified output");
    assert(checkoutOwnsPath(plain, buildPath(plain, "source", "output.txt")));
    assert(!checkoutOwnsPath(plain, plain ~ "-outside"));
    int plainRuns;
    auto plainResult = runVerificationRecipe(
        `{"inputs":["source/output.txt"],"steps":[{"kind":"tests","command":{"program":"checker"}}]}`,
        plain, delegate(JSONValue command) { ++plainRuns; return VerificationRun("checked", false, false, "tests"); });
    assert(plainResult.passed && plainRuns == 1, plainResult.output);
    ChatMessage plainProof;
    plainProof.id = "plain-inline"; plainProof.toolName = "verify";
    plainProof.toolArgs = `{"inputs":["source/output.txt"],"steps":[{"kind":"tests","command":{"program":"checker"}}]}`;
    plainProof.content = plainResult.output; plainProof.verificationCheck = plainResult.check;
    RecipeEvidenceCache plainCache;
    assert(plainCache.current(plainProof, checkoutIdentity(plain) ~ "|1"),
        "A plain-directory receipt could run but could not revalidate its identical inputs");
    write(buildPath(plain, "temporary.pyc"), "untracked cache");
    remove(buildPath(plain, "temporary.pyc"));
    RecipeEvidenceCache afterCleanup;
    assert(afterCleanup.current(plainProof, checkoutIdentity(plain) ~ "|2"),
        "Unrelated cache cleanup invalidated unchanged explicitly verified inputs");
    mkdirRecurse(buildPath(plain, "checks"));
    write(buildPath(plain, "checks", "verify.json"), plainProof.toolArgs);
    const savedArgs = `{"recipe":"checks/verify.json"}`;
    auto savedPlain = runVerificationRecipe(savedArgs, plain,
        delegate(JSONValue command) { return VerificationRun("checked", false, false, "tests"); });
    assert(savedPlain.passed);
    auto savedProof = plainProof; savedProof.id = "plain-saved"; savedProof.toolArgs = savedArgs;
    savedProof.content = savedPlain.output;
    RecipeEvidenceCache savedCache;
    assert(savedCache.current(savedProof, checkoutIdentity(plain) ~ "|3"),
        "A saved recipe inside a plain task directory lost its accepted proof");
    write(buildPath(plain, "source", "output.txt"), "changed source");
    RecipeEvidenceCache changedPlain;
    assert(!changedPlain.current(plainProof, checkoutIdentity(plain) ~ "|4"),
        "Receipt revalidation accepted changed deliverable bytes");
    bool outsideRejected;
    try { verificationInputsSignature(plain, JSONValue([plain ~ "-outside"])); }
    catch (Exception) { outsideRejected = true; }
    assert(outsideRejected, "The signature admitted an input outside the task directory");
    mkdirRecurse(buildPath(plain, "nested", ".git"));
    write(buildPath(plain, "nested", "foreign.txt"), "other checkout");
    assert(!checkoutOwnsPath(plain, buildPath(plain, "nested", "foreign.txt")));
    auto nestedResult = runVerificationRecipe(
        `{"inputs":["nested/foreign.txt"],"steps":[{"kind":"tests","command":{"program":"checker"}}]}`,
        plain, delegate(JSONValue command) { ++plainRuns; return VerificationRun("must not run", false, false, "tests"); });
    assert(!nestedResult.passed && plainRuns == 1, "Nested Git checkout isolation was lost");
    writeln("PASS non-Git task inputs verify while outside paths and nested Git checkouts remain isolated");
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
