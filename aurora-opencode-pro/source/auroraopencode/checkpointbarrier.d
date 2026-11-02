module auroraopencode.checkpointbarrier;

import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import core.sync.mutex : Mutex;

struct CheckpointResult
{
    bool ready;
    string error;
}

/// Journal fence -> ordered snapshot -> acknowledgement. No caller waits for
/// disk or a worker. The effect owns detached inputs and never accesses widgets.
final class CheckpointBarrier
{
    private Mutex mutex;
    private CheckpointResult result;
    private void delegate() wake;

    this(void delegate() wake = null) { mutex = new Mutex(); this.wake = wake; }

    void begin(ConversationRepository journal, ConversationRepository snapshots,
        RepositoryRuntime runtime, void delegate(ulong, ulong) save)
    {
        if (!journal.submit({
            const sequence = runtime.latestSequence();
            const bytes = runtime.journalSize();
            if (!snapshots.submit({
                try { save(sequence, bytes); finish(""); }
                catch (Throwable error) { finish(error.msg.length ? error.msg : "Checkpoint failed"); }
            })) finish("Snapshot owner is closed or at capacity");
        })) finish("Journal owner is closed or at capacity");
    }

    CheckpointResult poll() { synchronized (mutex) return result; }

    private void finish(string error)
    {
        synchronized (mutex) result = CheckpointResult(true, error);
        if (wake !is null) wake();
    }
}
