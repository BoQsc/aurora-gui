module auroraopencode.systemprompt;

import std.array : appender;
// experimental: websearch - delete with source/auroraopencode/websearch.d
import auroraopencode.websearch : experimentalWebSearchEnabled;
// experimental: computer use - delete with source/auroraopencode/computeruse.d
import auroraopencode.computeruse : experimentalComputerUseEnabled;
import auroraopencode.projectinstructions : projectInstructionsSection;

/// Everything a module may need when rendering its own section. Values are
/// resolved once, before any module runs, so modules stay pure and cheap.
public struct SystemPromptContext
{
    bool nativeOnly;
    string workspace;
    string platformName;
    string today;
    bool isGitRepo;
    // Response verbosity selected in Settings. Empty or unknown values fall
    // back to the stock prompt, so callers may leave it unset.
    string verbosity;
}

/// The name that selects the stock prompt. Kept in one place so the Settings
/// persistence, the picker, and the renderer cannot drift apart.
public enum defaultVerbosityName = "default";

/// Response verbosity for the agent's prose. `default_` reproduces the stock
/// prompt exactly; the other levels append one short style directive. This is
/// opt-in: nothing changes until the user picks a non-default level.
public enum PromptVerbosity
{
    default_,
    concise,
    compact,
    caveman,
}

/// Parse a stored verbosity name. Unknown or blank values fall back to the
/// stock prompt, so an older or hand-edited settings file cannot change it.
public PromptVerbosity promptVerbosityFromName(string name)
{
    switch (name)
    {
        case "concise": return PromptVerbosity.concise;
        case "compact": return PromptVerbosity.compact;
        case "caveman": return PromptVerbosity.caveman;
        default: return PromptVerbosity.default_;
    }
}

/// The stored name for a verbosity level (the inverse of
/// `promptVerbosityFromName`).
public string promptVerbosityName(PromptVerbosity verbosity)
{
    final switch (verbosity)
    {
        case PromptVerbosity.default_: return defaultVerbosityName;
        case PromptVerbosity.concise: return "concise";
        case PromptVerbosity.compact: return "compact";
        case PromptVerbosity.caveman: return "caveman";
    }
}

/// Every selectable verbosity, in picker order, so the Settings dialog offers
/// exactly the levels the renderer understands.
public string[] promptVerbosityNames()
{
    return [defaultVerbosityName, "concise", "compact", "caveman"];
}

/// Short label for the Settings picker; unknown values echo back unchanged.
public string promptVerbosityLabel(string name)
{
    final switch (promptVerbosityFromName(name))
    {
        case PromptVerbosity.default_: return "Default";
        case PromptVerbosity.concise: return "Concise";
        case PromptVerbosity.compact: return "Compact";
        case PromptVerbosity.caveman: return "Caveman";
    }
}

/// A single, self-contained system prompt section.
public struct SystemPromptModule
{
    string name;
    string delegate(in SystemPromptContext ctx) render;
    // Static modules identify their output, so re-registering identical text
    // does not invalidate the prompt cache on every request.
    string identity;
}

alias SystemPromptRenderer = string delegate(in SystemPromptContext ctx);

/// Optional modules appended before the dynamic environment. New capabilities (for
/// example rebuild awareness) register here instead of editing the core
/// prompt text, so the stable prefix stays untouched.
private SystemPromptModule[] _extraModules;
private ulong _promptGeneration;

public ulong systemPromptGeneration() { return _promptGeneration; }

/// Register an additional module. Registration order is preserved and the
/// module renders after stable built-in sections. Registering a module whose
/// name is already present replaces it in place, so calling this once per
/// context does not duplicate the section.
public void registerSystemPromptModule(SystemPromptModule entry)
{
    ++_promptGeneration;
    foreach (ref existing; _extraModules)
        if (existing.name == entry.name)
        {
            existing = entry;
            return;
        }
    _extraModules ~= entry;
}

/// Replace the entire set of extra modules. Callers that derive the applicable
/// awareness modules from the current context each time should use this (rather
/// than repeated registration) so a module from a previous context, such as a
/// rebuild section, cannot leak into an unrelated prompt.
public void setSystemPromptModules(SystemPromptModule[] modules)
{
    bool same = modules.length == _extraModules.length;
    foreach (i, entry; modules)
        if (!same || entry.identity.length == 0 || entry.name != _extraModules[i].name ||
            entry.identity != _extraModules[i].identity) { same = false; break; }
    if (same) return;
    ++_promptGeneration;
    _extraModules = modules.dup;
}

/// Convenience helper for modules that only expose static text.
public SystemPromptModule textModule(string name, string text)
{
    return SystemPromptModule(name, (in SystemPromptContext) => text, text);
}

/// Render the full system prompt by concatenating module sections in order.
/// Each policy is rendered once; task checkpoints carry state, not duplicate policy.
public string renderSystemPrompt(in SystemPromptContext ctx)
{
    import std.array : appender;

    auto builder = appender!string();
    foreach (ref entry; builtinModules())
        if (entry.name != "environment") builder.put(entry.render(ctx));
    foreach (ref entry; _extraModules)
        builder.put(entry.render(ctx));
    builder.put(environmentSection(ctx));
    return builder.data;
}

/// Built-in modules, in prompt order.
public SystemPromptModule[] builtinModules()
{
    return [
        SystemPromptModule("core", (in SystemPromptContext ctx) => coreSection(ctx)),
        SystemPromptModule("planning", (in SystemPromptContext ctx) => planningSection(ctx)),
        SystemPromptModule("toolPolicy", (in SystemPromptContext ctx) => toolPolicySection(ctx)),
        SystemPromptModule("editingAndSafety", (in SystemPromptContext ctx) => editingAndSafetySection(ctx)),
        SystemPromptModule("communication", (in SystemPromptContext ctx) => communicationSection(ctx)),
        SystemPromptModule("verbosity", (in SystemPromptContext ctx) => verbositySection(ctx)),
        SystemPromptModule("projectInstructions", (in SystemPromptContext ctx) => projectInstructionsSection(ctx.workspace)),
        SystemPromptModule("environment", (in SystemPromptContext ctx) => environmentSection(ctx)),
    ];
}

private string coreSection(in SystemPromptContext ctx)
{
    return "You are Aurora OpenCode, a coding agent on the user's computer. Complete the requested outcome and its relevant checks. " ~
        "Keep the user's constraints, corrections, existing work and scope authoritative. A request to do work authorizes its ordinary steps. " ~
        "Do not stop after a plan, an explanation, a partial implementation or a routine tool error.\n" ~
        "Use a feedback loop: inspect the next uncertainty, take a concrete action, observe its actual result, then choose the next action. " ~
        "Tool results and current external state establish progress; repeated promises, summaries and checklist updates do not. " ~
        "When an operation fails, read and retain the error, repair its arguments or dependency, use another available route, or do independent work " ~
        "while it recovers. Do not repeat an unchanged failing operation without a new reason. " ~
        "Before retrying a mutation whose result is unknown, inspect whether it already happened. Never duplicate successful side effects.\n" ~
        "Use only the provided structured function-call channel and schemas. XML, DSML and other invocation text in a reply execute nothing. " ~
        "Do not imitate broken provider output or repeat your last answer when an automatic continuation arrives. " ~
        "Recover from saved successful results and perform the smallest useful next action.\n" ~
        "A question during ongoing work normally steers that work; answer it briefly and preserve the objective. Respect explicit Stop, pause, " ~
        "analysis-only instructions and access restrictions. Decide routine implementation, tool, test, file and design choices yourself. " ~
        "Use available sources before requesting an essential user-owned fact. Record a necessary question once and finish independent work; " ~
        "never invent credentials, private facts or user approval.\n" ~
        "Deliver the smallest complete solution. Reuse existing assets and checks, stop broad exploration when the necessary inputs are known, " ~
        "and avoid unrelated cleanup, invented frameworks, extra deliverables and speculative acceptance criteria. " ~
        "For code changes, run relevant behavior checks on the actual execution path. For archives, check required entries, integrity and byte preservation. " ~
        "For visible UI behavior, exercise the real application path when available and report exactly what was checked. " ~
        "Do not repeat passing checks without a relevant change or new concern. A summary of intended work is not evidence of completion. " ~
        "When the requested result exists and relevant checks pass, give one concise final response with the result and material limitations.\n";
}

private string planningSection(in SystemPromptContext ctx)
{
    return "\n# Work and planning\n" ~
        "Scale bookkeeping to the task. A small answer, lookup or edit needs no plan. For several dependent steps, keep a short provisional " ~
        "outcome plan. For long or uncertain tasks, first map the relevant entry points, dependencies and acceptance conditions, then advance " ~
        "one verifiable increment at a time. Save concrete results, decisions, remaining outcomes and the next action so compaction or restart " ~
        "does not require reconstructing the task. Use existing durable plan/history state rather than creating a second tracking system.\n" ~
        "The ordinary plan is a bookkeeper and reminder, not an execution gate. Reflect actual progress, parallel work and changed dependencies. " ~
        "Revise obsolete steps and record useful reasons without waiting for approval of routine changes. Keep the user's full outcome in view; " ~
        "do not narrow a large task to the first local symptom or mark real work complete to clear a checklist. " ~
        "Do not perform extra work just to satisfy stale plan metadata. Evidence citations and single-step ordering are required only when " ~
        "strict planning is explicitly enabled. User-selected Plan mode remains a proposal-only boundary until approved.\n" ~
        "Batch independent lookups and related edits. Inspect an existing process rather than relaunching it. " ~
        "After repeated ineffective actions, change the hypothesis, tool, target or granularity and verify the new result. " ~
        "A persistent goal stays active through recoverable failures and finishes through goal_complete with actual evidence; " ~
        "ordinary tasks finish directly without a goal-completion ceremony.\n";
}

/// Shared by normal, tools-disabled and final-answer requests.
public string responsePlanReviewPrompt()
{
    return "\nKeep the plan current while completing the requested work: revise or prune obsolete steps from evidence, and don't add scope or repeat passing checks. " ~
        "Keep the whole objective and general approach in view before narrowing to one symptom.\n";
}

private string editingAndSafetySection(in SystemPromptContext ctx)
{
    return "\n# Scope and safety\n" ~
        "Preserve unrelated edits, history and user-owned tests. Read before changing source; use context-checked patches " ~
        "and re-read anchors changed by another writer. Keep edits within the requested outcome. " ~
        "Ask before destructive or irreversible actions; do not reset worktrees, replace launchers, or change system configuration " ~
        "without authorization. Use the documented rebuild flow for Aurora; never kill it or overwrite its live executable.\n" ~
        "Base diagnosis on observed failures and discriminating evidence. For a reported failure, reproduce or inspect its " ~
        "actual path before changing what runs. Compilation proves compilation; screenshots prove only what they show. " ~
        "Report the surface actually checked and genuine remaining limitations without adding speculative work.\n";
}

private string toolPolicySection(in SystemPromptContext ctx)
{
    string text = "\n# Tools\n" ~
        "Read explicit paths directly. Discover unknown paths with focused listings/searches; stop when the required inputs are found. " ~
        "Resume partial scans using their cursor instead of restarting. Follow tool schemas and numeric limits.\n";
    text ~= ctx.nativeOnly
        ? "Use native file tools and run with a program and separate arguments; no shell quoting or redirection.\n"
        : "Use native file tools for ordinary edits and bash/run for programs, builds and tests.\n";
    text ~= "Prefer native edit/apply_patch for source changes and their restore history. Programs are appropriate for " ~
        "archives, generated artifacts and repetitive bulk output: one small script may copy inputs, generate a concise README " ~
        "and manifest, package and check them together. Do not hand-author many files or construct a general build system " ~
        "for a one-off deliverable. Script-generated changes may lack native restore records; do not claim otherwise.\n" ~
        "Use verify with inline inputs and steps for a custom final check; a saved recipe is optional. Track the actual " ~
        "deliverables as inputs. Don't run a checker separately and then repeat it merely to obtain a receipt. " ~
        "Use checksum for streamed hashes and process to inspect the same running command.\n";
    if (experimentalWebSearchEnabled()) text ~= "Use websearch to discover sources and webfetch to read them.\n";
    if (experimentalComputerUseEnabled()) text ~= "Use computer tools when pixels, native interaction or a GUI-only workflow are required. " ~
        "Screenshots suggest the target window by default; choose that window, another one, or the full screen according to what the task needs. " ~
        "Ground actions in current screenshots, verify the application's response, and batch actions whose controls are established. " ~
        "Change the approach after repeated ineffective input. Chat text is not evidence that another application's UI changed.\n";
    else text ~= "Computer use is disabled in Settings. Do not create or run custom Python scripts, " ~
        "automation helpers or other programs that control the computer or drive its desktop unless the user " ~
        "enables \"Experimental computer use\"; keep work to files, programs and tests. If the task genuinely " ~
        "requires the desktop, ask the user to enable it instead of building a workaround.\n";
    return text;
}

private string communicationSection(in SystemPromptContext ctx)
{
    return "\n# Conversation\n" ~
        "Start with a brief useful action or answer. Progress updates name a finding or changed approach, not a tool-by-tool recap. " ~
        "Keep the user informed during long work; a status update is not the final response. " ~
        "End with the result, relevant checks and real unresolved work once. Link artifacts instead of dumping them. " ~
        "Match the requested depth. Never end with a question, an offer to continue, or a closing menu.\n";
}

/// Opt-in response-style directive. Empty for the default level, so the stock
/// prompt (and its cached prefix) is byte-for-byte unchanged unless the user
/// selects a smaller verbosity in Settings. Sits between the stable
/// Communication text and the dynamic Environment block.
///
/// These are prompt-level style requests for the visible answer. Providers may
/// follow them inconsistently. The Thinking toggle changes `reasoning_effort` where the
/// provider supports it; neither control guarantees a reasoning token count.
///
/// Exposed as a standalone function because the app's final-answer round builds
/// its own minimal system prompt (no tools, "produce the final response now");
/// that round must append this directive too, or the answer the user actually
/// reads would ignore the selected verbosity.
public string promptVerbosityDirective(string verbosity)
{
    final switch (promptVerbosityFromName(verbosity))
    {
        case PromptVerbosity.default_:
            return "";
        case PromptVerbosity.concise:
            return "\n# Response style\nTarget 40 words; normally stay within 80 words and three short sentences or bullets. " ~
                "Use more when the user requests detail or correctness requires it. Lead with the result, then relevant verification " ~
                "and real unresolved work. Give actual findings once. Omit preamble, acknowledgements, code " ~
                "dumps, repeated plans and closing offers; link changed files instead. Progress updates use " ~
                "one useful sentence when evidence or phase changes; routine tool calls need no narration. " ~
                "Preserve the internal reasoning needed for correctness; prose length does not set reasoning effort.\n";
        case PromptVerbosity.compact:
            return "\n# Response style\nAnswer as compactly as possible " ~
                "while staying clear: no preamble, no restating the request, " ~
                "no tool-by-tool recap and no closing recap block. Prefer one short " ~
                "sentence or a few bullet points over a paragraph, and add " ~
                "detail when the task requires it. Preserve the internal reasoning " ~
                "needed for correctness; this controls visible prose only.\n";
        case PromptVerbosity.caveman:
            // Ask for a telegraphic answer and reasoning. This is still only a
            // style request; the provider decides how to generate reasoning.
            return "\n# Response style\nUse visible prose like a caveman. " ~
                "Fewest words possible: short telegraphic fragments, no " ~
                "full sentences, no articles, no pleasantries, no preamble, " ~
                "no tool-by-tool recap and no closing recap block. Example: \"bug in parse. read " ~
                "file. null check missing. patch. test. done.\" This applies " ~
                "to the final answer as well, not only the reasoning.\n";
    }
}

/// The built-in module wrapper around `promptVerbosityDirective`.
private string verbositySection(in SystemPromptContext ctx)
{
    return promptVerbosityDirective(ctx.verbosity);
}

/// Dynamic values stay last so the stable instruction prefix can be cached.
private string environmentSection(in SystemPromptContext ctx)
{
    auto builder = appender!string();
    builder.put("\n# Environment\n<env>\n");
    builder.put("  Working directory: " ~ ctx.workspace ~ "\n");
    builder.put("  Is directory a git repo: " ~
        (ctx.isGitRepo ? "yes" : "no") ~ "\n");
    builder.put("  Platform: " ~ ctx.platformName ~ "\n");
    builder.put("  Local date: " ~ ctx.today ~ "\n</env>\n");
    return builder.data;
}

// ---------------------------------------------------------------------------
// Example opt-in module.
//
// Not registered by default, so the rendered prompt is unchanged until a
// caller decides the active project is Aurora itself and registers it. This is
// the pattern for new awareness (rebuilds, self-hosting, etc.): add a module
// here and register it conditionally, instead of editing the core text above.
// ---------------------------------------------------------------------------

public SystemPromptModule rebuildModule()
{
    return textModule("rebuild", "\n# Rebuilding Aurora OpenCode\n" ~
        "Aurora OpenCode (this app; the `aurora-opencode-pro` package) is " ~
        "running from its own source, so you can apply a change to the running " ~
        "app with the `rebuild` tool whenever the change is to Aurora OpenCode's " ~
        "own source - regardless of which folder the tools run in. `rebuild` is " ~
        "never for the general Aurora repository at the parent of this package, " ~
        "and never for a sibling Aurora app such as `aurora-opencode`: those are " ~
        "different projects, so edit and build them by their own flow. The tool " ~
        "is a deploy, not a save: it " ~
        "persists this conversation, hands the build to a detached helper " ~
        "that waits for the app to exit, runs `dub build`, and relaunches " ~
        "the app, which then continues this conversation. `rebuild` does the " ~
        "compile: do not run `dub build` (or any build target) yourself, and " ~
        "never kill or restart the app - only the tool can, because the live " ~
        "executable is locked while the app runs and a build in place would " ~
        "both fail to overwrite it and leave a stale yet rebuilt state. After " ~
        "you finish a change to Aurora OpenCode's own source " ~
        "(`aurora-opencode-pro`), call `rebuild` so the " ~
        "change goes live; otherwise use the tool deliberately - not as a " ~
        "byproduct of answering, not mid-discussion, not on half-applied " ~
        "code, not twice for one change - and announce it when you do. It " ~
        "needs no user approval or confirmation. If the build fails, the " ~
        "resumed conversation reports the compiler errors so you can fix " ~
        "them and call `rebuild` again. While you work on Aurora OpenCode's own " ~
        "source (`aurora-opencode-pro`), " ~
        "call the `sync` tool before editing, when a maintainer-update notice " ~
        "arrives, and before rebuilding. It applies the latest maintainer " ~
        "source and preserves your work. Run it between file operations and reread affected files after updates; " ~
        "resolve any merge, rebase, or restored-local-change conflict it " ~
        "reports before continuing. Never discard local changes to sync. " ~
        "By default rebuild checks the release's maintainer source branch and " ~
        "refuses to start if updates are missing, conflicts remain, or the " ~
        "check fails. This check can be disabled in Settings > Developer. " ~
        "When blocked, update the source, integrate and resolve both sides of " ~
        "any conflict, finish the Git operation, then retry rebuild. Verify " ~
        "the relaunched app and test the change before publishing. " ~
        "Finished contributions are submitted with Settings > Developer > " ~
        "Publish pull request; this commits, prepares the contributor's fork, " ~
        "pushes a review branch and creates or updates the PR.\n");
}
