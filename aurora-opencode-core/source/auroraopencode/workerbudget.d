module auroraopencode.workerbudget;

import core.sync.mutex : Mutex;
import std.conv : to;
import std.process : environment;

/// Admission counts physically running work. Logical cancellation never
/// releases a slot until the worker actually returns.
public final class WorkerBudget
{
    private Mutex _mutex;
    private size_t _active;
    immutable size_t capacity;
    this(size_t capacity)
    {
        assert(capacity > 0);
        this.capacity = capacity;
        _mutex = new Mutex();
    }
    bool acquire()
    {
        synchronized (_mutex)
        {
            if (_active >= capacity) return false;
            ++_active;
            return true;
        }
    }
    void release()
    {
        synchronized (_mutex)
        {
            assert(_active > 0);
            --_active;
        }
    }
    size_t active()
    {
        synchronized (_mutex) return _active;
    }
}

private __gshared WorkerBudget _providerWorkers;
shared static this()
{
    size_t capacity = 16;
    try capacity = to!size_t(environment.get("AURORA_PROVIDER_WORKERS", "16"));
    catch (Exception) {}
    if (capacity < 1 || capacity > 256) capacity = 16;
    _providerWorkers = new WorkerBudget(capacity);
}
public WorkerBudget providerWorkerBudget() { return _providerWorkers; }
