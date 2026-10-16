module auroraopencode.verificationrecipe;

import auroraopencode.core : OpenCodeToolDef, ChatImageAttachment;
import auroraopencode.attachments : attachmentImageForInlineData;
import auroraopencode.checkout : canonicalPath, checkoutIdentity;
import aurora.image : loadImage, encodePng;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.exception : enforce;
import std.file : readText, read, exists, isDir, isFile, isSymlink, getSize, dirEntries, SpanMode;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildPath;
import std.string : startsWith, endsWith;

struct VerificationRun
{
    string output;
    bool failed;
    bool detached;
    string check;
}

struct RecipeResult
{
    string output;
    string check;
    string workspace;
    bool passed;
    ChatImageAttachment[] images;
}

OpenCodeToolDef verificationToolDefinition()
{
    return OpenCodeToolDef("verify",
        "Run a saved project verification recipe in one supervised operation. " ~
        "The JSON recipe declares inputs, sequential command steps with kind " ~
        "compile/tests/interaction, and render steps comparing current pixels " ~
        "against an independently specified reference image. It records source " ~
        "and recipe hashes, fails on changed inputs or a failing step, and stops " ~
        "at the first failure. Use this for build/test/render sequences instead " ~
        "of separate model rounds. Compilation alone cannot verify rendering. " ~
        "Recipe format: {inputs:[source paths],steps:[{kind:compile/tests/interaction/prepare," ~
        "command:{program,args,workdir,timeout}},{kind:render,reference,actual,referenceSource}]}. " ~
        "prepare captures/converts outputs without claiming a test passed. Paths resolve " ~
        "from the task checkout; keep generated outputs outside inputs. Wrong pixels " ~
        "attach both reference and actual images for diagnosis. The full schema is in Aurora's docs/task-verification.md.",
        `{"type":"object","properties":{"recipe":{"type":"string","description":"JSON recipe path within the task checkout"}},"required":["recipe"]}`);
}

private string fingerprint(string workspace, JSONValue inputs, bool delegate() cancelled)
{
    enforce(inputs.type == JSONType.array && inputs.array.length > 0 && inputs.array.length <= 64,
        "Recipe inputs must name 1..64 source files/directories.");
    string[] paths;
    ulong bytes;
    size_t entries;
    void add(string path, size_t depth)
    {
        enforce(cancelled is null || !cancelled(), "Verification cancelled.");
        enforce(++entries <= 20_000 && depth <= 64 && !isSymlink(path), "Verification inputs exceed the traversal bound or include a link.");
        enforce(checkoutIdentity(path) == checkoutIdentity(workspace), "Verification input leaves the task checkout.");
        if (isDir(path))
        {
            foreach (entry; dirEntries(path, SpanMode.shallow))
            {
                enforce(paths.length < 20_000, "Too many verification input files.");
                add(entry.name, depth + 1);
            }
        }
        else
        {
            enforce(isFile(path), "Missing verification input: " ~ path);
            bytes += getSize(path);
            enforce(bytes <= 64UL * 1024 * 1024, "Verification inputs exceed 64 MiB.");
            paths ~= canonicalPath(path);
        }
    }
    foreach (input; inputs.array)
    {
        enforce(input.type == JSONType.string, "Verification input must be a path.");
        add(absolutePath(input.str, workspace), 0);
    }
    paths.sort();
    SHA256 hash;
    foreach (path; paths)
    {
        enforce(cancelled is null || !cancelled(), "Verification cancelled.");
        hash.put(cast(const(ubyte)[]) path);
        hash.put(cast(const(ubyte)[]) "\0");
        hash.put(cast(const(ubyte)[]) read(path));
    }
    return hash.finish().toHexString().idup;
}

RecipeResult runVerificationRecipe(string arguments, string workspace,
    VerificationRun delegate(JSONValue) run,
    bool delegate() cancelled = null, void delegate(string) progress = null)
{
    RecipeResult result;
    result.workspace = workspace;
    JSONValue report;
    report["steps"] = JSONValue.emptyArray;
    try
    {
        const args = parseJSON(arguments);
        const path = absolutePath(args["recipe"].str, workspace);
        enforce(checkoutIdentity(path) == checkoutIdentity(workspace), "Recipe must belong to the task checkout.");
        enforce(getSize(path) <= 64 * 1024, "Recipe exceeds 64 KiB.");
        const text = readText(path);
        const recipeHash = sha256Of(text).toHexString().idup;
        const recipe = parseJSON(text);
        const inputs = recipe["inputs"];
        const before = fingerprint(workspace, inputs, cancelled);
        const steps = recipe["steps"];
        enforce(steps.type == JSONType.array && steps.array.length > 0 && steps.array.length <= 16,
            "Recipe requires 1..16 steps.");
        string[string] references;
        foreach (step; steps.array)
        {
            const kind = step["kind"].str;
            enforce(["compile", "tests", "render", "interaction", "prepare"].canFind(kind), "Unknown verification kind.");
            if (kind == "render")
            {
                const reference = absolutePath(step["reference"].str, workspace);
                enforce(step["referenceSource"].str.length > 0, "Reference provenance is required.");
                enforce(getSize(reference) <= 32 * 1024 * 1024, "Reference exceeds 32 MiB.");
                references[reference] = sha256Of(cast(const(ubyte)[]) read(reference)).toHexString().idup;
            }
            else
            {
                const command = step["command"];
                enforce(command.type == JSONType.object && command["program"].str.length > 0,
                    "Command requires a program.");
                if (auto commandArguments = "args" in command.object)
                {
                    enforce(commandArguments.type == JSONType.array, "Command args must be an array.");
                    foreach (argument; commandArguments.array)
                        enforce(argument.type == JSONType.string, "Every command argument must be a string.");
                }
            }
        }
        report["recipe"] = path;
        report["recipeSha256"] = recipeHash;
        report["inputsSha256"] = before;
        string[] kinds;
        foreach (index, step; steps.array)
        {
            enforce(cancelled is null || !cancelled(), "Verification cancelled.");
            const kind = step["kind"].str;
            enforce(["compile", "tests", "render", "interaction", "prepare"].canFind(kind), "Unknown verification kind.");
            if (progress !is null) progress("Verification " ~ to!string(index + 1) ~ "/" ~
                to!string(steps.array.length) ~ ": " ~ kind);
            JSONValue row;
            row["kind"] = kind;
            if (kind == "render")
            {
                const reference = absolutePath(step["reference"].str, workspace);
                const actual = absolutePath(step["actual"].str, workspace);
                enforce(sha256Of(cast(const(ubyte)[]) read(reference)).toHexString() == references[reference],
                    "Reference changed during verification.");
                enforce(canonicalPath(reference) != canonicalPath(actual), "Reference and actual image must be different files.");
                enforce(step["referenceSource"].str.length > 0,
                    "Render comparison requires the independent reference's provenance.");
                enforce(getSize(reference) <= 32 * 1024 * 1024 && getSize(actual) <= 32 * 1024 * 1024,
                    "Verification images exceed 32 MiB.");
                auto expected = loadImage(reference);
                auto got = loadImage(actual);
                enforce(got.width == expected.width && got.height == expected.height,
                    "Render viewport/dimensions differ from the reference.");
                enforce(cast(ulong) got.width * got.height <= 16_000_000, "Verification image is too large.");
                ulong mismatched;
                const first = expected.pixels;
                const second = got.pixels;
                long tolerance, allowed;
                if (auto value = "channelTolerance" in step.object) tolerance = value.integer;
                if (auto value = "maxDifferentPixels" in step.object) allowed = value.integer;
                enforce(tolerance >= 0 && tolerance <= 8 && allowed >= 0 &&
                    allowed <= cast(long) got.width * got.height / 50,
                    "Render tolerance must be 0..8 channel values and at most 2% different pixels.");
                foreach (pixel; 0 .. cast(size_t) got.width * got.height)
                {
                    bool different;
                    foreach (channel; 0 .. 4)
                    {
                        const delta = cast(int) first[pixel * 4 + channel] - second[pixel * 4 + channel];
                        if (delta < -tolerance || delta > tolerance) different = true;
                    }
                    if (different) ++mismatched;
                }
                row["reference"] = reference; row["actual"] = actual;
                row["width"] = got.width; row["height"] = got.height;
                row["channelTolerance"] = tolerance; row["maxDifferentPixels"] = allowed;
                row["referenceSource"] = step["referenceSource"].str;
                row["referenceSha256"] = sha256Of(cast(const(ubyte)[]) read(reference)).toHexString().idup;
                row["actualSha256"] = sha256Of(cast(const(ubyte)[]) read(actual)).toHexString().idup;
                row["mismatchedPixels"] = cast(long) mismatched;
                row["passed"] = mismatched <= allowed;
                report["steps"].array ~= row;
                if (mismatched > cast(ulong) allowed)
                {
                    result.images = [
                        attachmentImageForInlineData("image/png", "Independent reference", encodePng(expected), true),
                        attachmentImageForInlineData("image/png", "Actual render", encodePng(got), true)];
                }
                enforce(mismatched <= cast(ulong) allowed, "Rendering differs from the independent reference.");
            }
            else
            {
                auto command = parseJSON(step["command"].toString());
                enforce(command.type == JSONType.object, "Step command must contain a program and argument list.");
                command["background"] = false;
                if (!("timeout" in command.object)) command["timeout"] = 120_000;
                const outcome = run(command);
                row["command"] = command;
                row["output"] = outcome.output;
                row["passed"] = !outcome.failed && !outcome.detached;
                report["steps"].array ~= row;
                enforce(!outcome.detached, "Verification command detached; inspect its process before claiming success.");
                enforce(!outcome.failed, "Verification step failed.");
                if (kind == "compile")
                    enforce(outcome.check.endsWith(" compile") || outcome.check.endsWith(" build") ||
                        outcome.check == "cargo check", "Compile evidence requires a recognized compiler/build targeting the task checkout.");
            }
            if (kind != "prepare" && !kinds.canFind(kind)) kinds ~= kind;
        }
        enforce(readText(path) == text && fingerprint(workspace, inputs, cancelled) == before,
            "Source inputs or recipe changed during verification; results are stale.");
        foreach (reference, hash; references)
            enforce(sha256Of(cast(const(ubyte)[]) read(reference)).toHexString() == hash,
                "Reference changed during verification; results are stale.");
        enforce(kinds.length > 0, "Preparation alone supplies no verification evidence.");
        result.passed = true;
        result.check = "verify:";
        foreach (i, kind; kinds) result.check ~= (i ? "," : "") ~ kind;
        report["passed"] = true;
    }
    catch (Exception error)
    {
        report["passed"] = false;
        report["error"] = error.msg;
    }
    result.output = report.toPrettyString();
    return result;
}
