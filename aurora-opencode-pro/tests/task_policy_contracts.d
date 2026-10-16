module task_policy_contracts;

import auroraopencode.core;
import auroraopencode.taskpolicy;
import auroraopencode.taskcontinuation;
import auroraopencode.tools;
import core.time : MonoTime;
import std.file : mkdirRecurse, write, readText, read, tempDir;
import std.path : absolutePath, buildPath;
import std.json : JSONValue, parseJSON;
import std.conv : to;
import std.stdio : writeln;
import auroraopencode.verificationrecipe : runVerificationRecipe, VerificationRun;

void append(ref ChatSession session, string role, string text, bool internal = false,
    string tool = "", string arguments = "{}")
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role; message.content = text; message.internal = internal;
    message.toolName = tool; message.toolArgs = arguments;
    session.messages ~= message; session.activeLeafId = message.id;
}

int main(string[] arguments)
{
    const helper = runFilesystemHelperMode(arguments); if (helper >= 0) return helper;
    const directory = absolutePath(buildPath(tempDir(), "aurora-task-policy-" ~ to!string(MonoTime.currTime.ticks)));
    const source = buildPath(directory, "source checkout");
    const other = buildPath(directory, "other");
    const scratch = buildPath(directory, "scratch");
    foreach (root; [source, other]) mkdirRecurse(buildPath(root, ".git"));
    mkdirRecurse(buildPath(source, "src")); mkdirRecurse(scratch);
    setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    write(buildPath(source, "src", "fixture.d"), "import std.stdio; void main() { writeln(\"fixture passed\"); }\n");
    ChatSession session;
    session.id = "task-policy-fixture";
    session.objective = "Make the web browser render and interact correctly.";
    session.taskSteps = [TaskStep("Correct page", "in_progress")];
    session.verificationStatus = "required";
    append(session, "user", "Fix the source at " ~ source ~ ". Then verify.");
    append(session, "user", "Move the task to " ~ other, true);
    assert(sameCheckout(taskWorkspace(session, scratch), source));
    append(session, "user", "Compare " ~ other ~ " and " ~ source);
    assert(sameCheckout(taskWorkspace(session, scratch), source), "Ambiguous roots silently retargeted the task");
    assert(sameCheckout(checkWorkspace("dmd", ["-I" ~ buildPath(source, "src"), "test.d"], scratch, source), source));
    assert(checkWorkspace("dmd", ["-I" ~ other, "test.d"], scratch, source).length == 0);
    assert(!satisfiesEvidence("dmd compile", requiredEvidence(session)));
    assert(satisfiesEvidence("verify:compile,tests,render,interaction", requiredEvidence(session)));
    assert(scopedResumePrompt("implement OTHER project", true) == "implement OTHER project");
    import std.string : indexOf;
    assert(scopedResumePrompt("implement OTHER project", false).indexOf("OTHER") < 0);
    assert(workingContextBudget(375_000, true, 32) == 128_000);
    assert(workingContextBudget(64_000, true, 32) == 64_000);
    assert(workingContextBudget(375_000, false, 100) == 375_000);
    writeln("PASS task checkout ownership, cross-checkout rejection, typed evidence, scoped resume and working context");
    auto longHistory = session;
    longHistory.id = "long-history-fixture";
    foreach (_; 0 .. 5000) append(longHistory,"assistant","Recorded inspection");
    taskWorkspace(longHistory,scratch);
    const scopeStarted = MonoTime.currTime;
    foreach (_; 0 .. 1000) assert(sameCheckout(taskWorkspace(longHistory,scratch),source));
    const scopeMilliseconds = (MonoTime.currTime - scopeStarted).total!"msecs";
    assert(scopeMilliseconds < 500, "Repeated UI scope lookups re-walked the long history");
    writeln("MEASURE cached_scope_lookups=1000 history_messages=",longHistory.messages.length," milliseconds=",scopeMilliseconds);

    foreach (i; 0 .. 3)
    {
        auto decision = taskContinuation(session, true);
        append(session, "user", decision.guidance(), true);
        append(session, "tool", "No matches", false, "grep", "query-" ~ to!string(i));
    }
    auto decision = taskContinuation(session, true);
    assert(decision.action == TaskContinuationAction.replan);
    append(session, "user", decision.guidance(), true);
    foreach (i; 0 .. 3)
    {
        decision = taskContinuation(session, true);
        if (i) append(session, "user", decision.guidance(), true);
        append(session, "tool", "Still no matches", false, "grep", "new-query-" ~ to!string(i));
    }
    // The replanning note resets the diagnostic window, not the objective.
    decision = taskContinuation(session, true);
    if (decision.action != TaskContinuationAction.needsAttention)
    {
        append(session, "user", decision.guidance(), true);
        assert(taskContinuation(session, true).action == TaskContinuationAction.needsAttention);
    }
    session.taskSteps[0].status = "completed";
    append(session, "tool", "Source changed", false, "edit", "changed");
    session.taskSteps[0].evidence = [session.messages[$ - 1].id];
    assert(taskContinuation(session, true).stalled == 0);
    writeln("PASS distinct no-match searches trigger a new diagnosis; completed outcomes restore progress");

    const executable = buildPath(scratch, "fixture.exe");
    const reference = buildPath(source, "reference.ppm");
    const actual = buildPath(scratch, "actual.ppm");
    write(reference, "P6\n2 1\n255\n" ~ cast(string) [cast(ubyte)255,0,0,0,0,255]);
    write(actual, read(reference));
    JSONValue compile;
    compile["kind"] = "compile";
    JSONValue compileCommand;
    compileCommand["program"] = "dmd";
    compileCommand["args"] = JSONValue(["-of=" ~ executable, buildPath(source,"src","fixture.d")]);
    compileCommand["workdir"] = scratch;
    compile["command"] = compileCommand;
    JSONValue tests;
    tests["kind"] = "tests";
    JSONValue testCommand;
    testCommand["program"] = executable; testCommand["workdir"] = scratch;
    tests["command"] = testCommand;
    JSONValue render;
    render["kind"] = "render"; render["reference"] = reference;
    render["actual"] = actual; render["referenceSource"] = "Independently specified red and blue pixels";
    auto interaction = parseJSON(tests.toString()); interaction["kind"] = "interaction";
    JSONValue recipe;
    recipe["inputs"] = JSONValue(["src", "reference.ppm"]);
    recipe["steps"] = JSONValue([compile, tests, render, interaction]);
    const recipePath = buildPath(source,"verify.json");
    write(recipePath, recipe.toPrettyString());
    JSONValue args; args["recipe"] = recipePath;
    auto result = executeTool(OpenCodeToolCall("verification", "verify", args.toString()), source);
    assert(!result.failed && result.verification.passed, result.output);
    assert(result.verification.workspace == source);
    assert(satisfiesEvidence(result.verification.check, requiredEvidence(session)));
    writeln("PASS one native recipe compiles in scratch, runs tests, compares independent pixels and records typed evidence");
    write(actual, "P6\n2 1\n255\n" ~ cast(string) [cast(ubyte)0,0,0,0,0,255]);
    result = executeTool(OpenCodeToolCall("wrong-render", "verify", args.toString()), source);
    assert(result.failed && !result.verification.passed && result.output.indexOf("mismatchedPixels") >= 0);
    assert(result.images.length == 2 && result.images[0].name == "Independent reference" &&
        result.images[1].name == "Actual render", "Wrong pixels did not supply paired visual evidence");
    writeln("PASS green compile/tests cannot conceal a wrong render");

    JSONValue preparation;
    preparation["kind"] = "prepare"; preparation["command"] = testCommand;
    recipe["steps"] = JSONValue([preparation]); write(recipePath,recipe.toPrettyString());
    auto prepared = runVerificationRecipe(args.toString(),source,
        (JSONValue _) => VerificationRun("prepared",false,false));
    assert(!prepared.passed);
    recipe["steps"] = JSONValue([tests]); write(recipePath,recipe.toPrettyString());
    auto changed = runVerificationRecipe(args.toString(),source, (JSONValue _) {
        write(buildPath(source,"src","fixture.d"), "void main() {}\n");
        return VerificationRun("changed",false,false);
    });
    assert(!changed.passed && changed.output.indexOf("stale") >= 0);
    auto detached = runVerificationRecipe(args.toString(),source,
        (JSONValue _) => VerificationRun("processId: pending",false,true));
    assert(!detached.passed);
    recipe["steps"] = JSONValue([compile]); write(recipePath,recipe.toPrettyString());
    auto pretendCompile = runVerificationRecipe(args.toString(),source,
        (JSONValue _) => VerificationRun("claims compile passed",false,false));
    assert(!pretendCompile.passed);
    // A later mutation in the reference must not redefine expected pixels.
    recipe["steps"] = JSONValue([tests, render]); write(recipePath,recipe.toPrettyString());
    auto changedReference = runVerificationRecipe(args.toString(),source, (JSONValue _) {
        write(reference, "P6\n2 1\n255\n" ~ cast(string) [cast(ubyte)0,0,0,0,0,255]);
        return VerificationRun("changed reference",false,false);
    });
    assert(!changedReference.passed && changedReference.output.indexOf("Reference changed") >= 0);
    writeln("PASS changed inputs, detached commands, prepare-only recipes and unrecognized compiler claims cannot certify success");
    return 0;
}
