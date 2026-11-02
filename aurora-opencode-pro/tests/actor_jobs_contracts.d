module actor_jobs_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import auroraopencode.runtime : projectAgentRuntimeEvents;
import actorview;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : join;
import std.conv : to;
import std.file : mkdirRecurse, exists, write;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.range : repeat;
import std.stdio : writeln;
import std.algorithm : startsWith, canFind;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", ""), releases = environment.get("AURORA_CONTRACT_RELEASE_DIR", "");
    assert(base.length && releases.length, "Run test_actor_jobs.py");
    const directory = absolutePath("actor-jobs-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    foreach (mode; ["title", "rename", "title-bound", "summary", "summary-goal", "summary-stop", "summary-invalid", "summary-branch"])
    {
        ChatSession initial; initial.id = mode; initial.model = mode;
        ActorConfiguration config; config.baseUrl = base; config.recordTrace = true; config.workspace = directory;
        config.request.contextLimit = 10_000; config.outageBudgetMs = 3000;
        const summary = mode.startsWith("summary"); config.quickTitle = !summary;
        config.modelCompaction = summary; config.request.compactionEnabled = summary;
        if (summary)
        {
            foreach (i; 0 .. 40)
            {
                ChatMessage message; message.id = "history-" ~ to!string(i); message.parentId = initial.activeLeafId;
                message.role = i % 2 ? "assistant" : "user";
                message.content = "Analysis evidence " ~ repeat("abcd ", 500).join();
                initial.messages ~= message; initial.activeLeafId = message.id;
            }
        }
        auto repository = new ConversationRepository();
        auto journal = new RepositoryRuntime(repository, buildPath(directory, mode ~ "-events.jsonl"));
        auto actor = new ConversationActor(initial, config, journal); auto view = new ActorTestView(initial, actor);
        assert(actor.post(ActorCommand(ActorCommandKind.start, "Analyze these findings and explain the design.")) == ActorAdmission.accepted);
        void waitFor(bool delegate() condition)
        {
            const deadline = MonoTime.currTime + 12.seconds;
            while (!condition() && MonoTime.currTime < deadline)
            { view.take(); assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs); }
            view.take(); assert(condition(), "Timed out: " ~ mode ~ "/" ~ view.model.turnStatus);
        }
        waitFor(() => view.model.turnStatus == "completed" && exists(buildPath(releases, mode ~ ".started")));
        assert(!exists(buildPath(releases, mode ~ ".release")), "Fixture released the job before observing foreground completion");
        const extractive = view.model.compactionSummary;
        if (summary) assert(extractive.length && !extractive.canFind("Model summary of earlier work:"));
        if (mode == "rename")
        {
            assert(actor.post(ActorCommand(ActorCommandKind.setTitle, "User chosen name")) == ActorAdmission.accepted);
            waitFor(() => view.model.title == "User chosen name");
        }
        if (mode == "summary-goal")
        {
            auto command = ActorCommand(ActorCommandKind.setGoal, "New acceptance condition"); command.activate = false;
            assert(actor.post(command) == ActorAdmission.accepted); waitFor(() => view.model.goal == command.text);
        }
        if (mode == "summary-stop") { actor.stop(); waitFor(() => view.model.turnStatus == "interrupted"); }
        if (mode == "summary-branch")
        {
            assert(actor.post(ActorCommand(ActorCommandKind.selectBranch, "", "history-5")) == ActorAdmission.accepted);
            waitFor(() => view.model.activeLeafId == "history-5");
        }
        write(buildPath(releases, mode ~ ".release"), "release");
        waitFor(() => !actor.activity().busy);
        actor.close(); const state = parseJSON(actor.finalSnapshot());
        auto recovered = projectAgentRuntimeEvents(journal.history());
        assert(recovered.length == 1 && sessionToJson(recovered[0]) == state, "Journal-only recovery lost optional job or transcript state");
        repository.close();
        if (mode == "title") assert(state["title"].str == "Ясність 😀 агентів");
        if (mode == "rename") assert(state["title"].str == "User chosen name" && state["titleManual"].boolean);
        if (mode == "title-bound") assert(view.model.titleAttempts == 2 && !view.model.title.length);
        if (summary) assert(state["compactionSummary"].str.canFind("Model summary of earlier work:") == (mode == "summary"));
        assert(!exists(buildPath(directory, "forbidden.txt")), "A summary/title tool call executed");
        const trace = actor.recordedTrace(); write(buildPath(directory, mode ~ "-trace.json"), trace);
        auto offline = config; offline.baseUrl = "http://127.0.0.1:1";
        assert(parseJSON(ConversationActor.replay(initial, offline, trace)) == state, "Offline job replay differs: " ~ mode);
        writeln("PASS HTTP background job ", mode);
    }
    return 0;
}
