module actor_branch_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationprojection;
import auroraopencode.conversationencode : sessionToJson;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, write, exists;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.json : JSONValue, parseJSON;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_provider_roundtrip.py --actor");
    const directory = absolutePath("actor-branches-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    ChatSession initial; initial.id = "branch-chat"; initial.model = "actor-branch-fixture";
    ActorConfiguration config; config.baseUrl = base; config.workspace = directory; config.recordTrace = true;
    auto actor = new ConversationActor(initial, config, null);
    ChatSession mirror = initial;
    auto projection = new ConversationProjection(initial);
    scope (exit) actor.close();
    void send(ActorCommand command) { assert(actor.post(command) == ActorAdmission.accepted); }
    immutable(ActorChange)[] take()
    {
        auto changes = actor.takeChanges();
        auto applied = projection.apply(mirror, changes);
        assert(!applied.error.length, applied.error);
        if (applied.needsSnapshot) send(ActorCommand(ActorCommandKind.snapshot));
        return changes;
    }
    void answer(string expected)
    {
        bool seen, idle;
        const deadline = MonoTime.currTime + 5.seconds;
        while ((!seen || !idle) && MonoTime.currTime < deadline)
        {
            foreach (change; take())
            {
                if (change.kind == ActorChangeKind.updated)
                {
                    auto message = parseJSON(change.text);
                    if (message["role"].str == "assistant" && message["content"].str == expected) seen = true;
                }
                if (change.kind == ActorChangeKind.metadata && !change.busy &&
                    parseJSON(change.text)["turnStatus"].str == "completed") idle = true;
            }
            assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
        }
        assert(seen && idle, "The actor did not settle " ~ expected);
    }
    JSONValue snapshot()
    {
        send(ActorCommand(ActorCommandKind.snapshot));
        const deadline = MonoTime.currTime + 5.seconds;
        while (MonoTime.currTime < deadline)
        {
            foreach (change; take())
                if (change.kind == ActorChangeKind.snapshot) return parseJSON(change.text);
            assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
        }
        assert(false, "Snapshot signal was not serviced");
    }
    send(ActorCommand(ActorCommandKind.start, "Analyze the original")); answer("Actor answer 1");
    auto first = snapshot();
    const originalUser = first["messages"].array[0]["id"].str;
    const originalReply = first["messages"].array[1]["id"].str;
    send(ActorCommand(ActorCommandKind.regenerate, "", originalReply)); answer("Actor answer 2");
    auto regenerated = snapshot();
    assert(regenerated["messages"].array.length == 3);
    assert(regenerated["messages"].array[1]["content"].str == "Actor answer 1");
    assert(regenerated["messages"].array[1]["finishReason"].str == "stop");
    assert(regenerated["messages"].array[2]["parentId"].str == originalUser);

    send(ActorCommand(ActorCommandKind.editPrompt, "Analyze the revised request", originalUser)); answer("Actor answer 3");
    auto edited = snapshot();
    assert(edited["messages"].array.length == 5 && edited["messages"].array[0]["content"].str == "Analyze the original");
    const revisedReply = edited["messages"].array[4]["id"].str;
    send(ActorCommand(ActorCommandKind.continueAnswer, "", revisedReply)); answer("Actor answer 4");
    auto continued = snapshot();
    assert(continued["messages"].array.length == 7);
    assert(continued["messages"].array[5]["parentId"].str == revisedReply);
    send(ActorCommand(ActorCommandKind.selectBranch, "", originalReply));
    auto selected = snapshot();
    assert(selected["activeLeaf"].str == originalReply && selected["turnStatus"].str == "completed",
        "Idle branch navigation marked a completed conversation interrupted");

    send(ActorCommand(ActorCommandKind.start, "Hold this reply"));
    bool partial;
    const streaming = MonoTime.currTime + 5.seconds;
    while (!partial && MonoTime.currTime < streaming)
    {
        foreach (change; take())
            if (change.kind == ActorChangeKind.delta && change.text == "partial") partial = true;
        Thread.sleep(2.msecs);
    }
    assert(partial);
    auto interrupted = snapshot();
    const heldPrompt = interrupted["messages"].array[$ - 2]["id"].str;
    const heldReply = interrupted["messages"].array[$ - 1]["id"].str;
    send(ActorCommand(ActorCommandKind.editPrompt, "Analyze the recovered request", heldPrompt)); answer("Actor answer 6");
    auto recovered = snapshot();
    bool keptPartial;
    foreach (message; recovered["messages"].array)
        if (message["id"].str == heldReply)
        { keptPartial = true; assert(message["content"].str == "partial" && message["finishReason"].str == "cancelled"); }
    assert(keptPartial && recovered["messages"].array.length == 11);
    send(ActorCommand(ActorCommandKind.setGoal, "Finish a replacement objective", "", false));
    auto goal = snapshot();
    assert(goal["goalStatus"].str == "paused" && goal["objective"].str == "Finish a replacement objective");
    assert(goal["taskArchive"].array.length && goal["messages"].array.length == 11,
        "Goal replacement lost the preceding analysis task or message versions");
    send(ActorCommand(ActorCommandKind.start, "Unexpected tool call"));
    bool rejectedTool;
    const rejection = MonoTime.currTime + 5.seconds;
    while (!rejectedTool && MonoTime.currTime < rejection)
    {
        foreach (change; take())
            if (change.kind == ActorChangeKind.metadata && parseJSON(change.text)["turnStatus"].str == "failed") rejectedTool = true;
        assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
    }
    assert(rejectedTool && !exists(buildPath(directory, "must-not-exist.txt")));
    auto refused = snapshot();
    assert(!("toolCalls" in refused["messages"].array[$ - 1].object), "A disabled tool request left an unpaired envelope");
    actor.close(); assert(!actor.fault().length, actor.fault());
    const finalState = actor.finalSnapshot();
    assert(parseJSON(sessionToJson(mirror).toString()) == parseJSON(finalState),
        "UI projection did not retain the execution owner's final graph and task state");
    Thread.sleep(1100.msecs); config.baseUrl = "http://127.0.0.1:1";
    assert(parseJSON(ConversationActor.replay(initial, config, actor.recordedTrace())) == parseJSON(finalState));
    write(buildPath(directory, "final.json"), finalState);
    writeln("PASS autonomous regenerate/edit/continue/navigation, cancellation during a live stream, retained versions, goal replacement and exact replay");
    return 0;
}
