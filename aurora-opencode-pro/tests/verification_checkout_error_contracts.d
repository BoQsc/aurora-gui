module verification_checkout_error_contracts;

import auroraopencode.checkout : checkoutIdentity;
import auroraopencode.verificationrecipe : runVerificationRecipe, VerificationRun;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    auto workspace = buildPath(tempDir(), "verify-error-workspace-" ~ to!string(MonoTime.currTime.ticks));
    auto outside = buildPath(tempDir(), "verify-error-outside-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    mkdirRecurse(outside);
    mkdirRecurse(buildPath(workspace, ".git"));
    mkdirRecurse(buildPath(outside, ".git"));
    write(buildPath(outside, "recipe.json"), "{}");
    write(buildPath(outside, "input.txt"), "outside");
    VerificationRun delegate(JSONValue) run = (JSONValue command) {
        assert(0, "recipe steps must not run");
        return VerificationRun.init;
    };

    auto recipeArgs = JSONValue.emptyObject;
    recipeArgs["recipe"] = buildPath(outside, "recipe.json");
    auto recipeResult = runVerificationRecipe(recipeArgs.toString(), workspace, run);
    assert(!recipeResult.passed, "cross-checkout recipe was accepted");
    auto recipeReport = parseJSON(recipeResult.output);
    const recipeError = recipeReport["error"].str;
    const recipeRejected = recipeError.indexOf("belongs to checkout") >= 0 &&
        recipeError.indexOf(checkoutIdentity(buildPath(outside, "recipe.json"))) >= 0 &&
        recipeError.indexOf(checkoutIdentity(workspace)) >= 0;
    assert(recipeRejected, "cross-checkout recipe error did not name both checkouts: " ~ recipeError);

    auto inside = JSONValue.emptyObject;
    inside["inputs"] = JSONValue.emptyArray;
    inside["inputs"].array ~= JSONValue(buildPath(outside, "input.txt"));
    inside["steps"] = JSONValue.emptyArray;
    write(buildPath(workspace, "inside.json"), inside.toString());
    auto inputArgs = JSONValue.emptyObject;
    inputArgs["recipe"] = buildPath(workspace, "inside.json");
    auto inputResult = runVerificationRecipe(inputArgs.toString(), workspace, run);
    assert(!inputResult.passed, "cross-checkout input was accepted");
    auto inputReport = parseJSON(inputResult.output);
    const inputError = inputReport["error"].str;
    const inputRejected = inputError.indexOf("Verification input") >= 0 &&
        inputError.indexOf("belongs to checkout") >= 0 &&
        inputError.indexOf(checkoutIdentity(buildPath(outside, "input.txt"))) >= 0 &&
        inputError.indexOf(checkoutIdentity(workspace)) >= 0;
    assert(inputRejected, "cross-checkout input error did not name both checkouts: " ~ inputError);
    writeln("PASS cross-checkout recipe and input errors name the offending checkout and the task checkout");
    return 0;
}