module corrupt_restore_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import auroraopencode.runtime : readAgentRuntimeEventsFrom, readLatestSequence;
import core.thread : Thread;
import core.time : msecs;
import std.file : mkdirRecurse, write, readText, exists;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int main()
{
    const state = absolutePath("corrupt-restore-state");
    mkdirRecurse(buildPath(state, "threads"));
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","quickTitle":false,"toolsEnabled":false}`);
    const index = buildPath(state, "threads.index.json");
    const conversation = buildPath(state, "threads", "preserved.json");
    const history = `{"messages":[{"id":"answer","role":"assistant","content":"Accepted history"}]}`;
    write(index, "corrupt original index");
    write(conversation, history);
    const unreadable = buildPath(state, "unreadable-journal");
    mkdirRecurse(unreadable);
    bool rejected;
    try readAgentRuntimeEventsFrom(unreadable, 0, true);
    catch (Exception) rejected = true;
    assert(rejected, "Physical journal read failure was reported as an empty history");
    rejected = false;
    try readLatestSequence(unreadable, true);
    catch (Exception) rejected = true;
    assert(rejected, "Unreadable journal reset the sequence to zero");
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options; options.width = 900; options.height = 600;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    auto driver = new UiTestDriver(window);
    foreach (_; 0 .. 100) { window.onNativeTick(0.05); Thread.sleep(2.msecs); }
    assert(root.startupPendingForTesting() && !root.sendEnabledForTesting());
    assert(driver.paint());
    root.persistForTesting();
    root.shutdownClient();
    assert(readText(index) == "corrupt original index", "Failed restore overwrote the index on close");
    assert(readText(conversation) == history);
    assert(!exists(buildPath(state, "journal.folded")), "Failed restore acknowledged a partial snapshot");
    writeln("PASS failed startup stays responsive and cannot overwrite the original store on save or shutdown");
    window.close();
    return 0;
}
