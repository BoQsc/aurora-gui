module auroraopencode.preferencewriter;

import auroraopencode.core : Settings, ProjectState;
import auroraopencode.logging : logError;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;

Settings preferenceSnapshot(Settings value)
{
    value.providerKeys = value.providerKeys.dup;
    foreach (ref keys; value.providerKeys) keys.extraApiKeys = keys.extraApiKeys.dup;
    value.contextBudgets = value.contextBudgets.dup;
    value.contextCompactions = value.contextCompactions.dup;
    value.reasoningControls = value.reasoningControls.dup;
    return value;
}

ProjectState preferenceSnapshot(ProjectState value)
{
    value.projects = value.projects.dup;
    return value;
}

/// One active write and one replaceable pending value, regardless of click rate.
/// The sink never runs under the mutex or on the submitting thread.
final class PreferenceWriter(T)
{
    private Mutex mutex;
    private Condition changed;
    private Thread worker;
    private void delegate(T) sink;
    private T pending;
    private bool dirty, active, closed;

    this(void delegate(T) sink)
    {
        this.sink = sink;
        mutex = new Mutex();
        changed = new Condition(mutex);
        worker = new Thread(&run);
        worker.isDaemon = true;
        worker.start();
    }

    void save(T value)
    {
        auto snapshot = preferenceSnapshot(value);
        synchronized (mutex)
        {
            if (closed) return;
            pending = snapshot;
            dirty = true;
            changed.notifyAll();
        }
    }

    /// Explicit durability barrier for shutdown and tests, never an ordinary tick.
    void flush()
    {
        synchronized (mutex) while (dirty || active) changed.wait();
    }

    void close()
    {
        synchronized (mutex)
        {
            closed = true;
            changed.notifyAll();
        }
        worker.join();
    }

    private void run()
    {
        while (true)
        {
            T value;
            synchronized (mutex)
            {
                while (!dirty && !closed) changed.wait();
                if (!dirty) return;
                value = pending;
                pending = T.init;
                dirty = false;
                active = true;
            }
            try sink(value);
            catch (Throwable error) logError("Preference save failed: " ~ error.msg);
            synchronized (mutex)
            {
                active = false;
                changed.notifyAll();
            }
        }
    }
}
