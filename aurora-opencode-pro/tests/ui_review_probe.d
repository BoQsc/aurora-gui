module ui_review_probe;

/// Renders the Pro UI offscreen against a seeded, deterministic history so a
/// review render shows the sidebar's two-line conversation rows and its date
/// bands.
///
/// `--screenshot` on the real executable paints after a single tick, which
/// lands before the deferred session snapshot is walked into the list, so that
/// capture always shows an empty sidebar. This probe seeds its own state
/// directory, waits the deferred restore out, and then saves the frame.
///
/// Usage: ui-review-probe <output.ppm>

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.time : MonoTime, seconds;
import std.datetime : Clock;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;

private void seedState(string stateDir)
{
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    const now = Clock.currTime.toUnixTime();
    JSONValue sessions = JSONValue(string[].init);

    void add(string title, string objective, string reply, long ageSeconds,
        string[] steps = null)
    {
        JSONValue session;
        session["title"] = title;
        session["model"] = "deepseek/deepseek-v4.1-flash";
        session["thinking"] = true;
        session["objective"] = objective;
        session["updatedAt"] = now - ageSeconds;
        // A completed checklist, so the review render shows the plan card's
        // header count, progress bar and checked step rows.
        JSONValue taskSteps = JSONValue.emptyArray;
        foreach (index, text; steps)
        {
            JSONValue step;
            step["text"] = text;
            step["status"] = "completed";
            step["id"] = "step-" ~ to!string(index + 1);
            step["kind"] = "";
            step["done"] = "";
            step["evidence"] = JSONValue(string[].init);
            step["blocker"] = "";
            taskSteps.array ~= step;
        }
        session["taskSteps"] = taskSteps;
        JSONValue messages = JSONValue(string[].init);
        JSONValue user;
        user["role"] = "user";
        user["content"] = title;
        user["time"] = "09:00";
        messages.array ~= user;
        JSONValue assistant;
        assistant["role"] = "assistant";
        assistant["content"] = reply;
        assistant["time"] = "09:01";
        messages.array ~= assistant;
        session["messages"] = messages;
        sessions.array ~= session;
    }

    // Spread the history over every band the sidebar groups by: today,
    // yesterday, earlier this week and older.
    add("Rebuild the settings dialog",
        "Replace the legacy modal with the docked settings panel",
        "The docked panel now carries the same options as the modal.", 600,
        ["Locate the blocking call(s)", "Fix the identified UI-thread block",
            "Compile/build to prove the fix is valid"]);
    add("Taller sidebar rows",
        "Give every conversation row a summary line and a date band",
        "Rows carry the objective under the title again.", 1800);
    add("Composer polish", "Match the release artwork's composer action row",
        "Search pill added beside the model picker.", 5400);
    add("Add dark theme tokens",
        "Move every opencode colour into the shared core package",
        "The tokens live in core.d now.", 90000);
    add("Write the release notes", "Summarize the last month of UI work",
        "Notes drafted into the changelog.", 260000);
    add("Investigate the startup crash",
        "Trace the faulting frame through the crash handler",
        "The crash came from a stale settings file.", 950000);

    JSONValue root;
    root["sessions"] = sessions;
    root["current"] = 0;
    write(buildPath(stateDir, "sessions.json"), root.toString());
}

int main(string[] args)
{
    const stateDir = buildPath(tempDir(), "aurora-opencode-pro-ui-review-state");
    seedState(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    // The review canvas is the design reference's own size, so the render can
    // be compared with it panes-for-pane instead of against a narrower window
    // that collapses the right-hand panel.
    WindowOptions options;
    options.title = "Aurora OpenCode Pro review";
    options.width = 1564;
    options.height = 1006;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.paint();
    scope (exit)
    {
        root.shutdownClient();
        window.close();
    }

    // Wait out the deferred history load: the snapshot is walked in on a tick
    // once the parse worker has finished, not during construction.
    const deadline = MonoTime.currTime + seconds(30);
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        driver.paint();
    }
    // A second of runtime, the cadence the insight pane and the peak badge
    // refresh on, so the capture shows settled live state instead of the
    // values painted on the very first frame.
    root.tickTree(1.1);
    driver.paint();

    writeln("restored sessions: ", root.sessionCountForTesting(),
        "  startup pending: ", root.startupPendingForTesting());
    // The last argument is the output path: the D runtime hands the program
    // name first, and a launcher may repeat it, so index 1 is not reliable.
    if (args.length > 1)
    {
        window.saveScreenshot(args[$ - 1]);
        writeln("wrote ", args[$ - 1]);
    }
    return 0;
}
