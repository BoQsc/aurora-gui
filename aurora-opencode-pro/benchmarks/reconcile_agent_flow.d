// Opt-in real-provider continuation at an actual premature-completion checkpoint.
module reconcile_agent_flow;
import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationprojection;
import auroraopencode.conversationcodec : decodeSessionMetadata, decodeMessages;
import auroraopencode.requestpolicy : prepareAgentRequest;
import auroraopencode.tools : buildSystemPrompt, nativeOnlyToolDefinitions, runFilesystemHelperMode;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.file : readText, write, mkdirRecurse;
import std.json : parseJSON, JSONValue;
import std.path : absolutePath, buildPath;
import std.string : indexOf;
import std.stdio : writeln;

int main(string[] args)
{
    const helperCode = runFilesystemHelperMode(args);
    if (helperCode >= 0) return helperCode;
    assert(args.length == 2, "Pass the isolated Aurora replay directory; uses the real provider");
    const root = absolutePath(args[1]);
    assert(root.indexOf("aurora-flow-replays") >= 0);
    const workspace = buildPath(root, "checkout", "aurora-opencode-pro");
    const state = buildPath(root, "appdata", "Aurora OpenCode");
    const index = parseJSON(readText(buildPath(state, "threads.index.json")));
    ChatSession initial;
    decodeSessionMetadata(index["sessions"][0], initial);
    decodeMessages(parseJSON(readText(buildPath(state, "threads", initial.id ~ ".json")))["messages"], initial);
    assert(initial.messages[$ - 1].role == "assistant" && !initial.messages[$ - 1].toolCalls.length);
    initial.messages = initial.messages[0 .. $ - 1].dup;
    initial.activeLeafId = initial.messages[$ - 1].id;
    initial.turnStatus = "idle";
    auto settings = loadSettings();
    initial.thinking = effectiveThinkingForModel(settings, settings.baseUrl, initial.model);
    const output = buildPath(root, "completion-repair"); mkdirRecurse(output);
    setOpencodeStateDirectoryForTesting(buildPath(output, "state"));
    settings.workspace = workspace; settings.quickTitle = false;
    settings.developerMode = false; settings.developerSourceDir = workspace;
    saveSettings(settings);
    scope(exit)
    {
        auto file = buildPath(output, "state", "settings.json");
        auto clean = parseJSON(readText(file));
        foreach (key; ["apiKey", "additionalApiKey", "providerKeys", "providerApiKeys"]) clean.object.remove(key);
        write(file, clean.toString());
    }
    ActorConfiguration config;
    config.baseUrl = settings.baseUrl; config.apiKey = settings.apiKey; config.workspace = workspace;
    config.request.toolsEnabled = true; config.request.contextLimit = 500_000;
    config.request.compactionEnabled = true;
    config.request.availableTools = nativeOnlyToolDefinitions();
    config.request.baseSystemPrompt = buildSystemPrompt(true, workspace, "win32");
    const prepared = prepareAgentRequest(initial, config.request);
    assert(prepared.messages[$ - 1].content.indexOf("Outcome check before the final reply") >= 0);
    auto actor = new ConversationActor(initial, config, null);
    auto projection = new ConversationProjection(initial); auto view = initial;
    const started = MonoTime.currTime; bool ready, sawRunning;
    size_t seen = initial.messages.length;
    assert(actor.post(ActorCommand(ActorCommandKind.start)) == ActorAdmission.accepted);
    while (MonoTime.currTime < started + 600.seconds && !ready)
    {
        const applied = projection.apply(view, actor.takeChanges()); assert(!applied.error.length, applied.error);
        if (applied.requestSnapshot) actor.post(ActorCommand(ActorCommandKind.snapshot));
        foreach (message; view.messages[seen .. $])
            if (message.role == "tool") writeln("LIVE tool=", message.toolName, " failed=", message.failed, " check=", message.verificationCheck);
        seen = view.messages.length;
        sawRunning = sawRunning || projection.busy;
        ready = sawRunning && !projection.busy && view.turnStatus == "completed";
        assert(!actor.fault().length, actor.fault()); Thread.sleep(20.msecs);
    }
    actor.close();
    auto snapshot = parseJSON(actor.finalSnapshot());
    write(buildPath(output, "final.json"), snapshot.toPrettyString());
    JSONValue report; report["seconds"] = (MonoTime.currTime - started).total!"seconds";
    report["status"] = ready ? "completed" : "timeout";
    report["initialMessages"] = cast(long)initial.messages.length;
    report["newTools"] = 0;
    foreach (message; snapshot["messages"].array[initial.messages.length .. $])
        if (message["role"].str == "tool") report["newTools"] = report["newTools"].integer + 1;
    report["taskStatus"] = snapshot["taskStatus"]; report["verificationStatus"] = snapshot["verificationStatus"];
    write(buildPath(output, "result.json"), report.toPrettyString());
    writeln("REAL COMPLETION REPLAY ", report.toString(), " ARTIFACTS ", output);
    assert(ready && snapshot["taskStatus"].str == "completed", "Actual checkpoint did not settle");
    return 0;
}
