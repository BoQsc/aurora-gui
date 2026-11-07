module project_instructions_test;

// Contract for the project-instructions prompt section: it appears with the
// project's files, it is absent (and the stock prompt stays byte-identical) when
// a project has none, and an oversized file is cut at the cap with a marker.

import auroraopencode.projectinstructions : projectInstructionsLimit,
    projectInstructionsSection, projectInstructionsSignature,
    projectInstructionsText;
import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uuid : randomUUID;

private void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

int main()
{
    const root = buildPath(tempDir(), "aurora-instructions-" ~ randomUUID().toString());
    // D forbids try/catch inside a scope guard, so the cleanup is a function.
    void cleanup()
    {
        try { rmdirRecurse(root); }
        catch (Exception) {}
    }
    scope (exit) cleanup();

    // 1. A project with both files: both are carried, under their own heading,
    //    after a precedence rule that keeps them from overriding the contract.
    const withFiles = buildPath(root, "with-files");
    mkdirRecurse(withFiles);
    write(buildPath(withFiles, "AGENTS.md"),
        "\n- Indent with 3 spaces.\n- Native-resolution screenshots only.\n");
    write(buildPath(withFiles, "AURORA.md"),
        "- Keep docs/ current.\n");
    SystemPromptContext ctx;
    ctx.workspace = withFiles;
    const prompt = renderSystemPrompt(ctx);
    require(prompt.indexOf("# Project instructions") >= 0,
        "the section header is missing");
    require(prompt.indexOf("## AGENTS.md") >= 0, "AGENTS.md heading is missing");
    require(prompt.indexOf("Indent with 3 spaces.") >= 0,
        "AGENTS.md body is missing");
    require(prompt.indexOf("## AURORA.md") >= 0, "AURORA.md heading is missing");
    require(prompt.indexOf("Keep docs/ current.") >= 0,
        "AURORA.md body is missing");
    require(prompt.indexOf("cannot grant permissions") >= 0,
        "the precedence rule is missing");
    require(prompt.indexOf("# Project instructions") < prompt.indexOf("# Environment"),
        "project instructions must precede the environment block");
    // House rules must also reach the prompt builder the app itself calls, not
    // only the standalone renderer.
    import auroraopencode.tools : buildSystemPrompt;
    const appPrompt = buildSystemPrompt(true, withFiles, "win32");
    require(appPrompt.indexOf("Indent with 3 spaces.") >= 0,
        "the app's prompt builder did not carry the project instructions");
    require(appPrompt.indexOf("# Project instructions") >= 0,
        "the app's prompt builder did not add the section");

    // 2. A project with no instruction file adds no section at all. The full
    //    prompts cannot be compared byte-for-byte: the environment block prints
    //    the workspace path, which differs by construction.
    const empty = buildPath(root, "empty");
    mkdirRecurse(empty);
    SystemPromptContext emptyCtx;
    emptyCtx.workspace = empty;
    require(renderSystemPrompt(emptyCtx).indexOf("# Project instructions") < 0,
        "a project without instruction files must not add the section");
    require(buildSystemPrompt(true, empty, "win32").indexOf("# Project instructions") < 0,
        "the app's prompt builder must not add the section for an empty project");
    require(projectInstructionsText(empty) == "",
        "an empty project must yield no instruction text");
    require(projectInstructionsSection(empty) == "",
        "an empty project must yield no section");

    // 3. An oversized file is cut at the cap, at a character boundary, with a
    //    visible marker, and the rest is not loaded.
    const huge = buildPath(root, "huge");
    mkdirRecurse(huge);
    // A repeating body cannot prove truncation: any slice of it also appears in
    // the kept prefix. The sentinel only exists past the cap.
    const body = "- a rule that repeats.\n".replicate(
        projectInstructionsLimit / 10 + 200) ~ "UNIQUE-TAIL-MARKER\n";
    require(body.length > projectInstructionsLimit,
        "fixture must exceed the cap");
    write(buildPath(huge, "AGENTS.md"), body);
    const text = projectInstructionsText(huge);
    require(text.indexOf("_(truncated at") >= 0, "the truncation marker is missing");
    require(text.length < projectInstructionsLimit + 200,
        "the truncated text is not bounded: " ~ to!string(text.length));
    require(text.indexOf("UNIQUE-TAIL-MARKER") < 0,
        "text past the cap leaked into the prompt");

    // 4. The prompt cache keys on the file signature, so an edited rule file must
    //    change it - otherwise the session keeps serving a stale prompt.
    require(projectInstructionsSignature(empty) == "",
        "an empty project must have an empty signature");
    const before = projectInstructionsSignature(withFiles);
    require(before.length > 0, "a project with rules must have a signature");
    write(buildPath(withFiles, "AGENTS.md"),
        "\n- Indent with 4 spaces now, and run the formatter before committing.\n");
    require(projectInstructionsSignature(withFiles) != before,
        "editing AGENTS.md must change the signature");
    require(renderSystemPrompt(ctx).indexOf("run the formatter before committing") >= 0,
        "the edited rule must reach a freshly rendered prompt");
    writeln("PASS project instructions load, stay absent when unused, and are bounded");
    return 0;
}
