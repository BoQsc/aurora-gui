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

/// Journal I/O belongs to the ordered repository owner. UI queries read a
/// short-lived metadata lock, never the lock held across a physical write.
public final class RepositoryRuntime : AgentRuntime
{
    private ConversationRepository _repository;
    private DurableAgentRuntime _journal;
    private string _path;
    private bool _initialized;
    private ulong _sequence, _bytes;
    private string _lastError;
    private ulong _checkpointFailureRevision;
    private string _checkpointError;
    private bool _effectsBlocked;
    private void delegate() _wake;
    public struct CheckpointFailure { ulong revision; string message; }
    CheckpointFailure checkpointFailure() const
    {
        synchronized (cast(Object) this)
            return CheckpointFailure(_checkpointFailureRevision, _checkpointError);
    }
    this(ConversationRepository repository, string path)
    {
        _repository = repository;
        _path = path;
        if (!_repository.submit(delegate() {
            try initialize();
            catch (Throwable error) { recordFailure(error.msg); }
            synchronized (this) _initialized = true;
            notify();
        }))
        {
            recordFailure("Conversation repository is closed or at capacity.");
            synchronized (this) _initialized = true;
        }
    }
    bool initialized() const { synchronized (cast(Object) this) return _initialized; }
    private void initialize()
    {
        if (_journal is null) _journal = new DurableAgentRuntime(_path);
        refreshMetadata();
    }
    // Owner-thread only: never call journal methods while holding the metadata
    // lock, or UI reads could inherit the journal's disk wait again.
    private void refreshMetadata()
    {
        const sequence = _journal.latestSequence();
        const bytes = _journal.journalSize();
        const error = _journal.lastError();
        synchronized (this) { _sequence = sequence; _bytes = bytes; _lastError = error; }
    }
    private bool publishOnOwner(AgentRuntimeEvent event)
    {
        try
        {
            initialize();
            const success = _journal.publish(event);
            refreshMetadata();
            if (!success) recordFailure(lastError());
            return success;
        }
        catch (Throwable error) { recordFailure(error.msg); return false; }
    }
    bool publish(AgentRuntimeEvent event)
    {
        bool success;
        _repository.commit(delegate() { success = publishOnOwner(event); });
        return success;
    }
    void setWake(void delegate() wake)
    {
        synchronized (this) _wake = wake;
        notify();
    }
    private void notify()
    {
        void delegate() wake;
        synchronized (this) wake = _wake;
        if (wake !is null) wake();
    }
    private void recordFailure(string error)
    {
        void delegate() wake;
        synchronized (this)
        {
            ++_checkpointFailureRevision;
            _checkpointError = error;
            _lastError = error;
            _effectsBlocked = true;
            wake = _wake;
        }
        if (wake !is null) wake();
    }
    /// The UI transfers an immutable event and returns immediately. Later
    /// effects enter this same ordered owner only after preceding intents.
    bool enqueue(AgentRuntimeEvent event)
    {
        const accepted = _repository.submit(delegate() { publishOnOwner(event); });
        if (!accepted) recordFailure("Conversation journal queue is at capacity or closed.");
        return accepted;
    }
    /// Large immutable snapshots are encoded on the owner, in journal order.
    bool enqueueGenerated(AgentRuntimeEvent delegate() generate)
    {
        const accepted = _repository.submit(delegate() {
            try publishOnOwner(generate());
            catch (Throwable error) { recordFailure(error.msg); }
        });
        if (!accepted) recordFailure("Conversation journal queue is at capacity or closed.");
        return accepted;
    }
    bool afterCommitted(void delegate() effect, void delegate(string) failed)
    {
        return _repository.submit(delegate() {
            string error;
            bool blocked;
            synchronized (this) { blocked = _effectsBlocked; error = _checkpointError; }
            if (blocked) { failed(error.length ? error : "Conversation checkpoint failed"); return; }
            try effect();
            catch (Throwable failure) { failed(failure.msg); }
        });
    }
    /// Called only after a detached snapshot and its fold marker are written.
    void acknowledgeSnapshot(ulong failureRevision)
    {
        synchronized (this)
            if (failureRevision == _checkpointFailureRevision &&
                _lastError.length == 0) _effectsBlocked = false;
    }
    bool effectsBlocked() { synchronized (this) return _effectsBlocked; }
    bool checkpoint(AgentRuntimeEvent event)
    {
        return enqueue(event);
    }
    AgentRuntimeEvent[] history()
    {
        AgentRuntimeEvent[] events;
        _repository.commit(delegate() { initialize(); events = _journal.history(); });
        return events;
    }
    AgentRuntimeEvent[] eventsAfter(ulong sequence)
    {
        AgentRuntimeEvent[] events;
        _repository.commit(delegate() { initialize(); events = _journal.eventsAfter(sequence); });
        return events;
    }
    AgentRuntimeEvent[] eventsFrom(ulong offset)
    {
        AgentRuntimeEvent[] events;
        _repository.commit(delegate() { initialize(); events = _journal.eventsFrom(offset); });
        return events;
    }
    ulong latestSequence() const { synchronized (cast(Object) this) return _sequence; }
    ulong journalSize() const { synchronized (cast(Object) this) return _bytes; }
    string lastError() const { synchronized (cast(Object) this) return _lastError; }
}
