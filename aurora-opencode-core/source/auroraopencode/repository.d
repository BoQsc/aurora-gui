module auroraopencode.repository;

import auroraopencode.runtime : AgentRuntime, AgentRuntimeEvent, DurableAgentRuntime;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

private final class RepositoryJob
{
    void delegate() effect;
    bool completed;
    Throwable failure;
    this(void delegate() effect) { this.effect = effect; }
}

/// All journal appends and snapshot writes share a single ordered owner.
/// Callers transfer detached state; effects must never access live UI fields.
public final class ConversationRepository
{
    private Mutex _mutex;
    private Condition _wake, _settled;
    private RepositoryJob[] _jobs;
    private Thread _worker;
    private bool _closed;
    private enum size_t maxPendingJobs = 128;

    this()
    {
        _mutex = new Mutex();
        _wake = new Condition(_mutex);
        _settled = new Condition(_mutex);
        _worker = new Thread(&run);
        _worker.isDaemon = true;
        _worker.start();
    }

    bool submit(void delegate() effect)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_closed || _jobs.length >= maxPendingJobs) return false;
        _jobs ~= new RepositoryJob(effect);
        _wake.notify();
        return true;
    }

    /// Intent and effect records require a durable acknowledgement. Waiting for
    /// the owner preserves that contract without competing file writers.
    void commit(void delegate() effect)
    {
        auto job = new RepositoryJob(effect);
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_closed) throw new Exception("Conversation repository is closed");
        while (_jobs.length >= maxPendingJobs && !_closed) _settled.wait();
        if (_closed) throw new Exception("Conversation repository is closed");
        _jobs ~= job;
        _wake.notify();
        while (!job.completed) _settled.wait();
        if (job.failure !is null) throw job.failure;
    }

    void flush() { commit(delegate() {}); }

    void close()
    {
        _mutex.lock();
        if (_closed) { _mutex.unlock(); return; }
        _closed = true;
        _wake.notifyAll();
        _settled.notifyAll();
        _mutex.unlock();
        _worker.join();
    }

    private void run()
    {
        while (true)
        {
            _mutex.lock();
            while (!_jobs.length && !_closed) _wake.wait();
            if (!_jobs.length && _closed) { _mutex.unlock(); return; }
            auto job = _jobs[0];
            _jobs = _jobs[1 .. $];
            _settled.notifyAll();
            _mutex.unlock();
            try job.effect();
            catch (Throwable error) { job.failure = error; }
            _mutex.lock();
            job.completed = true;
            _settled.notifyAll();
            _mutex.unlock();
        }
    }
}

/// Keep synchronous durable acknowledgements for intents. Partial stream
/// checkpoints can queue asynchronously on the same owner.
public final class RepositoryRuntime : AgentRuntime
{
    private ConversationRepository _repository;
    private DurableAgentRuntime _journal;
    private ulong _checkpointFailureRevision;
    private string _checkpointError;
    public struct CheckpointFailure { ulong revision; string message; }
    CheckpointFailure checkpointFailure() const
    {
        synchronized (cast(Object) this)
            return CheckpointFailure(_checkpointFailureRevision, _checkpointError);
    }
    this(ConversationRepository repository, string path)
    {
        _repository = repository;
        _repository.commit(delegate() { _journal = new DurableAgentRuntime(path); });
    }
    bool publish(AgentRuntimeEvent event)
    {
        bool success;
        _repository.commit(delegate() { success = _journal.publish(event); });
        return success;
    }
    bool checkpoint(AgentRuntimeEvent event)
    {
        return _repository.submit(delegate() {
            if (!_journal.publish(event))
                synchronized (this)
                {
                    ++_checkpointFailureRevision;
                    _checkpointError = _journal.lastError();
                }
        });
    }
    AgentRuntimeEvent[] history()
    {
        AgentRuntimeEvent[] events;
        _repository.commit(delegate() { events = _journal.history(); });
        return events;
    }
    AgentRuntimeEvent[] eventsAfter(ulong sequence)
    {
        AgentRuntimeEvent[] events;
        _repository.commit(delegate() { events = _journal.eventsAfter(sequence); });
        return events;
    }
    AgentRuntimeEvent[] eventsFrom(ulong offset)
    {
        AgentRuntimeEvent[] events;
        _repository.commit(delegate() { events = _journal.eventsFrom(offset); });
        return events;
    }
    // These are read-only journal queries, protected by its own lock. They may
    // also be called from snapshot effects on the repository worker.
    ulong latestSequence() const { return _journal.latestSequence(); }
    ulong journalSize() const { return _journal.journalSize(); }
    string lastError() const { return _journal.lastError(); }
}
