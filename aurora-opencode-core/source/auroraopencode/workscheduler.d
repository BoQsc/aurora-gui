module auroraopencode.workscheduler;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.path : buildNormalizedPath;
import std.string : toLower;

public abstract class WorkItem
{
    string workspace;
    string resource;
    bool exclusive;
    bool changed;
    abstract void execute();
    abstract void settle(ulong workspaceRevision);
}

private struct Lease { size_t readers; bool writer; ulong revision; }

/// Bounded workers and writer-preferring workspace leases. A cancelled task
/// keeps its physical lease until execute returns; logical Stop cannot let a
/// later edit overtake an effect that is still running.
public final class WorkScheduler
{
    private Mutex _mutex;
    private Condition _wake;
    private WorkItem[] _pending;
    private Lease[string] _leases;
    private bool[string] _resources;
    private Thread[] _workers;
    private bool _closed;
    private size_t _capacity;

    this(size_t workers = 4, size_t capacity = 512)
    {
        assert(workers > 0 && capacity > 0);
        _capacity = capacity;
        _mutex = new Mutex();
        _wake = new Condition(_mutex);
        foreach (_; 0 .. workers)
        {
            auto worker = new Thread(&run);
            worker.isDaemon = true;
            worker.start();
            _workers ~= worker;
        }
    }

    bool submit(WorkItem item)
    {
        synchronized (_mutex)
        {
            if (_closed || _pending.length >= _capacity) return false;
            _pending ~= item;
            _wake.notifyAll();
            return true;
        }
    }

    ulong revision(string workspace)
    {
        synchronized (_mutex)
        {
            auto lease = key(workspace) in _leases;
            return lease is null ? 0 : lease.revision;
        }
    }

    size_t pending()
    {
        synchronized (_mutex) return _pending.length;
    }

    private static string key(string workspace)
    {
        auto normalized = buildNormalizedPath(workspace);
        version (Windows) return normalized.toLower();
        else return normalized;
    }

    private size_t nextEligible()
    {
        bool[string] waitingWriter;
        foreach (i, item; _pending)
        {
            if (item.resource.length && item.resource in _resources) continue;
            const workspace = key(item.workspace);
            if (workspace !in _leases) _leases[workspace] = Lease.init;
            auto lease = &_leases[workspace];
            if (item.exclusive)
            {
                waitingWriter[workspace] = true;
                if (!lease.writer && !lease.readers) return i;
            }
            else if (!lease.writer && workspace !in waitingWriter) return i;
        }
        return size_t.max;
    }

    private void run()
    {
        while (true)
        {
            _mutex.lock();
            size_t slot;
            while ((slot = nextEligible()) == size_t.max && !_closed) _wake.wait();
            if (slot == size_t.max && _closed) { _mutex.unlock(); return; }
            auto item = _pending[slot];
            _pending = _pending[0 .. slot] ~ _pending[slot + 1 .. $];
            const workspace = key(item.workspace);
            auto lease = &_leases[workspace];
            if (item.exclusive) lease.writer = true;
            else ++lease.readers;
            if (item.resource.length) _resources[item.resource] = true;
            _mutex.unlock();
            // WorkItem implementations must turn failures into terminal values.
            try item.execute();
            catch (Throwable) {}
            _mutex.lock();
            lease = &_leases[workspace];
            if (item.changed) ++lease.revision;
            const revision = lease.revision;
            if (item.exclusive) lease.writer = false;
            else --lease.readers;
            if (item.resource.length) _resources.remove(item.resource);
            _wake.notifyAll();
            _mutex.unlock();
            try item.settle(revision);
            catch (Throwable) {}
        }
    }
}
