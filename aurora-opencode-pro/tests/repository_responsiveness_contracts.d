module repository_responsiveness_contracts;

import auroraopencode.repository;
import auroraopencode.runtime;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.file : mkdirRecurse;
import std.path : buildPath;
import std.stdio : writeln;

int main()
{
    mkdirRecurse("repository-responsive-state");
    auto repository = new ConversationRepository();
    scope(exit) repository.close();
    auto entered = new Semaphore();
    auto release = new Semaphore();
    assert(repository.submit({ entered.notify(); release.wait(); }));
    entered.wait();
    // A fallback release makes regressions fail instead of hanging the runner.
    auto rescue = new Thread({ Thread.sleep(1200.msecs); release.notify(); });
    rescue.start();
    scope(exit) rescue.join();
    const started = MonoTime.currTime;
    auto runtime = new RepositoryRuntime(repository,
        buildPath("repository-responsive-state", "runtime-events.jsonl"));
    assert((MonoTime.currTime - started).total!"msecs" < 100,
        "Runtime construction waited behind repository I/O");
    assert(!runtime.initialized());
    foreach (_; 0 .. 5000)
    {
        assert(runtime.latestSequence() == 0);
        assert(runtime.journalSize() == 0);
        assert(runtime.lastError().length == 0);
    }
    assert((MonoTime.currTime - started).total!"msecs" < 100,
        "Read-only UI metadata queries waited for disk ownership");
    AgentRuntimeEvent event;
    event.kind = AgentEventKind.threadStarted;
    event.threadId = "chat";
    event.payloadJson = `{"title":"Accepted after durable intent"}`;
    assert(runtime.enqueue(event));
    bool effect;
    assert(runtime.afterCommitted({
        assert(runtime.latestSequence() == 1 && runtime.journalSize() > 0);
        effect = true;
    }, (string failure) { assert(false, failure); }));
    assert(!effect && runtime.latestSequence() == 0,
        "An effect ran before the pending intent reached durable storage");
    release.notify();
    repository.flush();
    assert(runtime.initialized() && effect && runtime.latestSequence() == 1);
    assert(runtime.history().length == 1);
    writeln("PASS blocked owner leaves constructor/metadata responsive; ordered durable admission preserved");
    return 0;
}
