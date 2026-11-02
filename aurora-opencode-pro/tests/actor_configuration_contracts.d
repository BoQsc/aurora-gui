module actor_configuration_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, readText, exists, rename, write;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    const release = environment.get("AURORA_CONTRACT_RELEASE_FILE", "");
    assert(base.length && release.length, "Run test_actor_configuration.py");
    const directory = absolutePath("actor-configuration-" ~ to!string(MonoTime.currTime.ticks));
    const oldWorkspace = buildPath(directory, "old"), newWorkspace = buildPath(directory, "new");
    mkdirRecurse(oldWorkspace); mkdirRecurse(newWorkspace); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    ChatSession initial; initial.id = "configuration-chat"; initial.model = "configuration-old";
    ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture-secret-before";
    config.workspace = oldWorkspace; config.recordTrace = true; config.outageBudgetMs = 15_000;
    config.request.toolsEnabled = true; config.request.contextLimit = 64_000;
    config.request.baseSystemPrompt = buildSystemPrompt(true, oldWorkspace, "win32", "auto");
    config.request.availableTools = nativeOnlyToolDefinitions();
    auto actor = new ConversationActor(initial, config, null);
    assert(actor.post(ActorCommand(ActorCommandKind.start, "Analyze this design and record a plain text note.")) == ActorAdmission.accepted);
    bool partial;
    const partialDeadline = MonoTime.currTime + 10.seconds;
    while (!partial && MonoTime.currTime < partialDeadline)
    {
        foreach (change; actor.takeChanges()) if (change.kind == ActorChangeKind.delta) partial = true;
        assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
    }
    assert(partial);
    auto next = config; next.workspace = newWorkspace; next.apiKey = "fixture-secret-after"; next.outageBudgetMs = 5_000;
    next.request.baseSystemPrompt = "New captured policy."; next.request.availableTools = null;
    foreach (tool; config.request.availableTools) if (tool.name == "read") next.request.availableTools ~= tool;
    assert(next.request.availableTools.length == 1);
    assert(actor.configure(next, "configuration-new", true) == ActorAdmission.accepted);
    assert(actor.post(ActorCommand(ActorCommandKind.setTitle, "User chosen title")) == ActorAdmission.accepted);
    auto background = ActorCommand(ActorCommandKind.selectView); background.activate = false;
    assert(actor.post(background) == ActorAdmission.accepted);
    next.request.availableTools[0].name = "Caller edited its own array";
    bool configured; JSONValue latest;
    const configurationDeadline = MonoTime.currTime + 10.seconds;
    while (!configured && MonoTime.currTime < configurationDeadline)
    {
        foreach (change; actor.takeChanges()) if (change.kind == ActorChangeKind.metadata) latest = parseJSON(change.text);
        if (latest.type == JSONType.object) configured = latest["model"].str == "configuration-new" &&
            latest["title"].str == "User chosen title";
        assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
    }
    assert(configured); write(release, "release original provider request");
    bool finished;
    const deadline = MonoTime.currTime + 15.seconds;
    while (!finished && MonoTime.currTime < deadline)
    {
        foreach (change; actor.takeChanges())
        {
            assert(change.kind != ActorChangeKind.fault, change.text);
            if (change.kind == ActorChangeKind.metadata) latest = parseJSON(change.text);
        }
        if (latest.type == JSONType.object) finished = latest["turnStatus"].str == "completed";
        assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
    }
    write(buildPath(directory, "last-header.json"), latest.toString());
    assert(finished, "Reconfigured turn did not settle: " ~ latest["turnStatus"].str ~ "/" ~ latest["taskStatus"].str);
    assert(latest["unread"].boolean, "Background completion did not retain its unread state");
    assert(readText(buildPath(oldWorkspace, "fenced.md")) == "original workspace");
    assert(!exists(buildPath(newWorkspace, "fenced.md")), "Changing configuration redirected an already requested tool");
    auto selected = ActorCommand(ActorCommandKind.selectView); selected.activate = true;
    assert(actor.post(selected) == ActorAdmission.accepted);
    bool read;
    const readDeadline = MonoTime.currTime + 5.seconds;
    while (!read && MonoTime.currTime < readDeadline)
    {
        foreach (change; actor.takeChanges()) if (change.kind == ActorChangeKind.metadata)
            read = !("unread" in parseJSON(change.text).object);
        Thread.sleep(2.msecs);
    }
    assert(read);
    assert(actor.post(ActorCommand(ActorCommandKind.configure, "{}")) == ActorAdmission.accepted);
    bool rejected;
    const invalidDeadline = MonoTime.currTime + 5.seconds;
    while (!rejected && MonoTime.currTime < invalidDeadline)
    {
        foreach (change; actor.takeChanges()) if (change.kind == ActorChangeKind.notice) rejected = true;
        assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
    }
    assert(rejected, "Malformed configuration did not return an explicit rejection");
    actor.close();
    const state = parseJSON(actor.finalSnapshot());
    assert(state["model"].str == "configuration-new" && state["thinking"].boolean && state["title"].str == "User chosen title");
    auto captured = actor.finalConfiguration();
    assert(captured.workspace == newWorkspace && captured.outageBudgetMs == 5000 && captured.request.availableTools[0].name == "read");
    const trace = actor.recordedTrace();
    assert(trace.indexOf("fixture-secret-before") < 0 && trace.indexOf("fixture-secret-after") < 0,
        "A connection credential entered a configuration command recording");
    write(buildPath(directory, "trace.json"), trace); write(buildPath(directory, "final.json"), state.toString());
    rename(oldWorkspace, oldWorkspace ~ "-offline"); rename(newWorkspace, newWorkspace ~ "-offline");
    config.baseUrl = "http://127.0.0.1:1"; config.apiKey = "offline";
    assert(parseJSON(ConversationActor.replay(initial, config, trace)) == state,
        "Hot configuration or read-state replay depended on live connections/workspaces");
    writeln("PASS ordered model/tool/credential changes, original effect scope, independent caller arrays, read state and secret-free offline replay");
    return 0;
}
