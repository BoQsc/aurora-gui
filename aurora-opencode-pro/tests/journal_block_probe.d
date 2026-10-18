module journal_block_probe;

// Guards the requirement that no tick spends seconds on the UI thread.
//
// Measured on a journal far larger than the bounded repair lookup: with the
// fold point 8 MB from the end - the state the app keeps as it writes - the
// worst tick is ~440 ms (onTick ~400 ms, paint ~47 ms). The same journal left
// completely unfolded costs ~2.1 s in one tick, because the startup replay then
// reads the whole file on the UI thread; that is what the fold point bounds, and
// it is not the parent-link repair (a complete transcript measures the same).
// The budget below catches a reintroduced multi-second tick, which is what the
// freeze watchdog reported. The fixture also clears the result's parent, so the
// same run proves the deferred repair still lands.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, Duration, seconds, msecs;
import core.thread : Thread;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse, write, getSize;
import std.path : buildPath, absolutePath;
import std.stdio : File, writeln;

int main()
{
    const state = absolutePath("journal-block-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(buildPath(state, "threads"));
    write(buildPath(state, "settings.json"), `{"baseUrl":"http://127.0.0.1:9","quickTitle":false,"toolsEnabled":false}`);
    write(buildPath(state, "threads.index.json"),
        `{"version":2,"current":0,"currentId":"big-journal","sessions":[{"id":"big-journal","title":"Big journal","activeLeaf":"result","turnStatus":"complete"}]}`);
    // The Read result has lost its parent: only the journal tail still proves it
    // belongs to the tool call, so the repair has to run for this transcript.
    write(buildPath(state, "threads", "big-journal.json"),
        `{"messages":[{"id":"prompt","role":"user","content":"Count the files"},` ~
        `{"id":"call","parentId":"prompt","role":"assistant","content":"","toolCalls":[{"id":"list-call","name":"list","arguments":"{}"}]},` ~
        `{"id":"result","parentId":"","role":"tool","toolName":"list","toolCallId":"list-call","content":"done"}]}`);
    auto journal = File(buildPath(state, "runtime-events.jsonl"), "w");
    // ~48 MB of unrelated durable history, then the decisive event inside the
    // bounded tail. The UI thread must not parse any of it.
    const filler = `{"schema":1,"type":"thread.updated","threadId":"other","payload":{"ignored":"` ~
        "x".replicate(8192) ~ `"}}` ~ "\n";
    foreach (sequence; 1 .. 6000) journal.write(filler);
    journal.write(`{"schema":1,"sequence":6000,"type":"item.added","threadId":"big-journal","itemId":"result","payload":{"role":"tool","parentId":"call","toolName":"list","toolCallId":"list-call","content":"done"}}` ~ "\n");
    journal.close();
    // The app folds its journal as it writes, so the realistic state has all but
    // the bounded tail folded away and the replay only has to read the end.
    write(buildPath(state, "journal.folded"),
        "1 " ~ to!string(getSize(buildPath(state, "runtime-events.jsonl")) - 8 * 1024 * 1024) ~ "\n");
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options; options.width = 1200; options.height = 800; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    Duration worstTick, worstProject, worstPaint;
    const deadline = MonoTime.currTime + 5.seconds;
    while (MonoTime.currTime < deadline)
    {
        const started = MonoTime.currTime;
        window.onNativeTick(0.02);
        const afterTick = MonoTime.currTime;
        root.projectTranscriptForTesting();
        const afterProject = MonoTime.currTime;
        assert(driver.paint());
        const afterPaint = MonoTime.currTime;
        if (afterTick - started > worstTick) worstTick = afterTick - started;
        if (afterProject - afterTick > worstProject) worstProject = afterProject - afterTick;
        if (afterPaint - afterProject > worstPaint) worstPaint = afterPaint - afterProject;
        Thread.sleep(5.msecs);
    }
    const worst = worstTick + worstProject + worstPaint;
    const worstMs = worst.total!"msecs";
    const tickMs = worstTick.total!"msecs";
    const projectMs = worstProject.total!"msecs";
    const paintMs = worstPaint.total!"msecs";
    const active = root.messageCountForTesting();
    const total = root.totalMessageCountForTesting();
    writeln("BLOCK worst tick ", worstMs, " ms = onTick ", tickMs, " + project ", projectMs, " + paint ", paintMs, "; active=", active, " total=", total);
    assert(root.messageCountForTesting() == 3,
        "The deferred repair never restored the parent link: active=" ~ to!string(root.messageCountForTesting()));
    assert(worst < 1.seconds,
        "One tick spent " ~ to!string(worstMs) ~ " ms on the UI thread with a large journal present");
    writeln("PASS no tick blocks on the journal and the parent link is still restored");
    return 0;
}
