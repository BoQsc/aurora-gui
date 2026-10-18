module journal_block_probe;

// Reproducer for a UI-thread block that is still open.
//
// With a journal far larger than the bounded repair lookup, one tick spends
// about 2.1 s on the UI thread. The phase split puts the whole cost inside the
// tick's own work (onTick ~2.1 s, project 0 ms, paint ~50 ms), and it is the
// same with a complete transcript where no repair runs at all, so the cost is
// not the parent-link repair: it is the startup load opening the journal, i.e.
// `_runtime = new RepositoryRuntime((appui.d ~11447) -> ConversationRepository
// .commit (repository.d ~113-116) -> new DurableAgentRuntime(path)`, whose
// effect the calling UI thread waits on (`_settled.wait()`, repository.d ~49-61).
//
// The assertion below is expected to fail until that open moves off the UI
// thread; the probe is kept as the measured case, not as a green check. It also
// clears the result's parent so the same run exercises the deferred repair.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, Duration, seconds, msecs;
import core.thread : Thread;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse, write;
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
        `{"id":"result","parentId":"call","role":"tool","toolName":"list","toolCallId":"list-call","content":"done"}]}`);
    auto journal = File(buildPath(state, "runtime-events.jsonl"), "w");
    // ~48 MB of unrelated durable history, then the decisive event inside the
    // bounded tail. The UI thread must not parse any of it.
    const filler = `{"schema":1,"type":"thread.updated","threadId":"other","payload":{"ignored":"` ~
        "x".replicate(8192) ~ `"}}` ~ "\n";
    foreach (sequence; 1 .. 6000) journal.write(filler);
    journal.write(`{"schema":1,"sequence":6000,"type":"item.added","threadId":"big-journal","itemId":"result","payload":{"role":"tool","parentId":"call","toolName":"list","toolCallId":"list-call","content":"done"}}` ~ "\n");
    journal.close();
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
    assert(worst < 400.msecs,
        "One tick spent " ~ to!string(worstMs) ~ " ms on the UI thread with a large journal present");
    writeln("PASS no tick blocks on the journal and the parent link is still restored");
    return 0;
}
