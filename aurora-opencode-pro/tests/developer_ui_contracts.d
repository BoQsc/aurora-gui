module developer_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    loadSettings, setOpencodeStateDirectoryForTesting, OpenCodeToolCall, opencodeTheme;
import auroraopencode.tools : executeTool, syncRequestHandler, rebuildRequestHandler, rebuildSourceCheckHandler,
    builtinToolDefinitions, nativeOnlyToolDefinitions;
import auroraopencode.developerworkflow : DeveloperSyncResult;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.json : parseJSON, JSONValue;
import rebuild : findAuroraSourceFolder, findDeveloperSourceDirectory;
import core.time : MonoTime;
import std.file : copy, exists, mkdirRecurse, readText, tempDir, thisExePath, write;
import std.path : buildPath;
import std.process : Config, execute;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf, startsWith;
import std.array : join;

Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children())
        if (auto result = find(child, id)) return result;
    return null;
}

T findType(T)(Widget root)
{
    if (auto result = cast(T) root) return result;
    foreach (child; root.children())
        if (auto result = findType!T(child)) return result;
    return null;
}

void main(string[] args)
{
    const state = buildPath(tempDir(), "aurora-developer-ui-" ~ to!string(MonoTime.currTime.ticks));
    if (args.length == 1)
    {
        // The harness executable is inside the maintainer's checkout. Move the
        // fixture outside it to exercise a downloaded installation honestly.
        mkdirRecurse(state);
        const packaged = buildPath(state, "Aurora OpenCode.exe");
        copy(thisExePath(), packaged);
        foreach (scenario; ["configured", "recovered", "stale", "repository", "source-subdirectory", "snapshot", "flat", "nested", "recipe", "reported", "chosen", "missing"])
        {
            auto result = execute([packaged, scenario], null, Config.suppressConsole);
            assert(result.status == 0, scenario ~ ": " ~ result.output);
            writeln(result.output);
        }
        return;
    }
    const scenario = args[1];
    const source = scenario == "configured" || scenario == "chosen"
        ? buildPath(state, "custom", "aurora-opencode-pro")
        : scenario == "flat" ? buildPath(state, "source", "aurora-opencode-pro")
        : scenario == "nested" ? buildPath(state, "source", "older-download", "aurora-gui-renamed", "aurora-opencode-pro")
        : buildPath(state, "source", scenario == "snapshot" ? "aurora-gui-main" : "aurora-gui", "aurora-opencode-pro");
    if (scenario != "missing")
    {
        mkdirRecurse(buildPath(source, "source"));
        if (scenario != "recipe" && scenario != "reported")
        {
            mkdirRecurse(buildPath(source, "shared"));
            write(buildPath(source, "shared", "rebuild.d"), "module rebuild;");
        }
        write(buildPath(source, "dub.json"), `{"name":"aurora-opencode-pro"}`);
        write(buildPath(source, "source", "app.d"), "module app;");
        write(buildPath(source, "source", "local-work.d"), "developer's unfinished changes");
        if (scenario == "reported")
        {
            // Exact diagnostic layout: blank saved path, a Git checkout and a
            // ZIP copy, both older packages with no shared/ directory at all.
            mkdirRecurse(buildPath(state, "source", "aurora-gui", ".git"));
            const archive = buildPath(state, "source", "aurora-gui-main", "aurora-opencode-pro");
            mkdirRecurse(buildPath(archive, "source"));
            write(buildPath(archive, "dub.json"), `{"name":"aurora-opencode-pro"}`);
            write(buildPath(archive, "source", "app.d"), "older ZIP copy");
            assert(!exists(buildPath(source, "shared")) && !exists(buildPath(archive, "shared")));
        }
    }
    else mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.developerMode = true;
    if (scenario == "configured") settings.developerSourceDir = source;
    else if (scenario == "stale") settings.developerSourceDir = buildPath(state, "old-location", "aurora-opencode-pro");
    else if (scenario == "repository") settings.developerSourceDir = buildPath(state, "source", "aurora-gui");
    else if (scenario == "source-subdirectory") settings.developerSourceDir = buildPath(source, "source");
    settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false;
    saveSettings(settings);
    // Upgrade an old settings file that predates the opt-out preference.
    auto oldSettings = parseJSON(readText(buildPath(state, "settings.json")));
    oldSettings.object.remove("developerRequireLatestSource");
    write(buildPath(state, "settings.json"), oldSettings.toString());
    assert(loadSettings().developerRequireLatestSource,
        "The rebuild source check must default on for existing installations");
    if (scenario != "missing" && scenario != "chosen")
        assert(findDeveloperSourceDirectory(settings.developerSourceDir, state, thisExePath()) == source,
            "Source resolver mismatch: expected " ~ source ~ " got " ~
            findDeveloperSourceDirectory(settings.developerSourceDir, state, thisExePath()));
    WindowOptions options;
    options.width = 1200; options.height = 900;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(driver.paint());
    if (scenario != "missing" && scenario != "chosen")
        assert(root.introSuggestionPromptsForTesting().join("\n").indexOf(source) >= 0,
            "Developer starters must target the recovered source folder on a packaged installation: " ~ scenario ~
                " expected " ~ source ~ " got " ~ root.introSuggestionPromptsForTesting().join("\n"));
    auto open = cast(Button) find(root, "oc-settings-button");
    assert(open !is null);
    open.activate();
    assert(driver.paint());
    assert(find(root, "oc-developer-use-source") !is null,
        "Every installation needs a way to choose an existing source folder");
    auto sourceOpen = find(root, "oc-developer-source");
    assert(sourceOpen !is null && sourceOpen.bounds().width > 0 &&
        sourceOpen.bounds().right() <= sourceOpen.parent().bounds().width,
        "Long source paths must not push the Open folder button outside the dialog");
    if (scenario == "chosen")
    {
        auto choose = cast(Button) find(root, "oc-developer-use-source");
        choose.activate();
        assert(driver.paint());
        auto picker = findType!FileDialogPanel(root);
        assert(picker !is null, "Use existing source must open a folder picker");
        picker.onAccepted(buildPath(state, "custom"));
        assert(driver.paint());
    }
    assert(find(root, "oc-settings-developer") !is null);
    assert(find(root, "oc-developer") !is null);
    auto publish = find(root, "oc-developer-publish-pr");
    assert(publish !is null,
        "Publish must exist even when GitHub CLI is not installed or source is an older snapshot");
    assert(find(root, "oc-developer-source") !is null);
    auto rebuild = find(root, "oc-developer-rebuild");
    assert(rebuild !is null,
        "Rebuild must be reachable in Developer settings after source retrieval");
    auto requireLatest = cast(CheckBox) find(root, "oc-developer-require-latest-source");
    assert(requireLatest !is null && requireLatest.checked());
    requireLatest.setChecked(false);
    root.flushSettingsForTesting();
    assert(!loadSettings().developerRequireLatestSource, "The explicit opt-out must persist");
    requireLatest.setChecked(true);
    root.flushSettingsForTesting();
    assert(loadSettings().developerRequireLatestSource);
    auto status = cast(Label) find(root, "oc-developer-sourcestatus");
    assert(status !is null);
    if (scenario == "missing")
    {
        assert(publish.enabled() && rebuild.enabled(),
            "Missing source must guide the user through setup instead of disabling actions");
        assert(find(root, "oc-developer-getsource") !is null);
        assert(status.text().indexOf("Source not located") >= 0);
        (cast(Button) publish).activate();
        assert(driver.paint());
        assert(find(root, "oc-developer-source-setup") !is null);
        assert(find(root, "oc-developer-choose-source") !is null);
        assert(find(root, "oc-developer-fetch-source") !is null);
        (cast(Button) find(root, "oc-developer-source-cancel")).activate();
        assert(driver.paint());
        (cast(Button) find(root, "oc-developer-rebuild")).activate();
        assert(driver.paint());
        assert(find(root, "oc-developer-source-setup") !is null,
            "Rebuild must offer source setup without launching an empty build");
        (cast(Button) find(root, "oc-developer-choose-source")).activate();
        assert(driver.paint());
        auto picker = findType!FileDialogPanel(root);
        assert(picker !is null);
        picker.onAccepted(state);
        assert(driver.paint());
        root.flushSettingsForTesting();
        assert(loadSettings().developerSourceDir.length == 0,
            "Selecting a non-source folder must not overwrite the configured source");
        writeln("PASS: both missing-source actions open recovery; invalid selections preserve settings");
        return;
    }
    assert(publish.enabled() && rebuild.enabled(),
        "Existing source must enable both Developer actions: " ~ scenario);
    assert(find(root, "oc-developer-syncsource") !is null);
    assert(find(root, "oc-developer-getsource") is null,
        "Retrieved source must not still say Get source");
    assert(status.text().indexOf("Source ready") >= 0);
    root.flushSettingsForTesting();
    assert(loadSettings().developerSourceDir == source,
        "Recovered source must survive subsequent launches");
    assert(readText(buildPath(source, "source", "local-work.d")) == "developer's unfinished changes",
        "Source discovery must preserve local work");
    if (scenario == "nested")
    {
        const second = buildPath(state, "source", "another-copy", "aurora-opencode-pro");
        mkdirRecurse(buildPath(second, "shared"));
        write(buildPath(second, "shared", "rebuild.d"), "module rebuild;");
        assert(findAuroraSourceFolder(buildPath(state, "source")).length == 0,
            "Multiple nonstandard checkouts require a choice, never an arbitrary target");
    }
    assert(find(root, "oc-developer-commit") is null);
    assert(find(root, "oc-developer-pr") is null);
    writeln("PASS: packaged Developer actions enabled and local work preserved: ", scenario);

    if (scenario == "reported")
    {
        foreach (failure; ["Maintainer source is newer", "Error: network unavailable", "Error: Resolve conflicts first: local.d"])
        {
            root.rebuildSourceCheckForTesting = (string dir, bool required) {
                assert(dir == source && required);
                return DeveloperSyncResult(failure.startsWith("Error:"),
                    !failure.startsWith("Error:"), "latest", failure);
            };
            (cast(Button) find(root, "oc-developer-rebuild")).activate();
            const deadline = MonoTime.currTime + seconds(5);
            while (find(root, "oc-rebuild-source-blocked") is null && MonoTime.currTime < deadline)
            {
                root.tickTree(0.02);
                Thread.sleep(msecs(10));
            }
            assert(driver.paint());
            assert(find(root, "oc-rebuild-source-blocked") !is null,
                "A rejected source check must show a visible dialog");
            auto detail = cast(TextArea) find(root, "oc-rebuild-source-message");
            assert(detail !is null && detail.textUtf8().indexOf(failure) >= 0);
            assert(find(root, "oc-rebuild-source-copy") !is null);
            assert(!exists(buildPath(source, "rebuildstate.json")),
                "A blocked rebuild must never start the helper");
            assert(readText(buildPath(source, "source", "local-work.d")) == "developer's unfinished changes");
            (cast(Button) find(root, "oc-rebuild-source-close")).activate();
            open.activate();
            assert(driver.paint());
        }
        auto blockedTool = executeTool(OpenCodeToolCall("stale-rebuild", "rebuild", "{}"), state);
        assert(blockedTool.failed && blockedTool.output.indexOf("Resolve conflicts") >= 0,
            "The same rejection must reach the agent before it is told a rebuild started");
        auto optOut = cast(CheckBox) find(root, "oc-developer-require-latest-source");
        optOut.setChecked(false);
        bool requested;
        root.rebuildSourceCheckForTesting = (string dir, bool required) {
            assert(!required, "The agent preflight must honor the Developer opt-out");
            return DeveloperSyncResult.init;
        };
        rebuildRequestHandler = (string reason) { requested = true; return true; };
        auto allowedTool = executeTool(OpenCodeToolCall("opted-out-rebuild", "rebuild", "{}"), state);
        assert(!allowedTool.failed && requested);
        rebuildSourceCheckHandler = null;
        rebuildRequestHandler = null;
        writeln("PASS: real Rebuild clicks keep Aurora open and show update/offline/conflict recovery; agent receives failure");
    }
    bool nativeSync, legacySync;
    foreach (tool; nativeOnlyToolDefinitions()) if (tool.name == "sync") nativeSync = true;
    foreach (tool; builtinToolDefinitions()) if (tool.name == "sync") legacySync = true;
    assert(nativeSync && legacySync);
    syncRequestHandler = (string arguments) => "Error: fetch failed";
    auto failed = executeTool(OpenCodeToolCall("failed-sync", "sync", "{}"), state);
    assert(failed.failed && failed.output.indexOf("fetch failed") >= 0);
    syncRequestHandler = (string arguments) => "Local work reapplied.";
    assert(!executeTool(OpenCodeToolCall("good-sync", "sync", "{}"), state).failed);
    syncRequestHandler = null;
    assert(executeTool(OpenCodeToolCall("missing-sync", "sync", "{}"), state).failed);
    writeln("PASS: sync is available to both tool sets and failures reach the agent as failed results");
}
