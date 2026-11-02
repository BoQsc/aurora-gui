module auroraopencode.historymailbox;

public enum HistoryActionKind
{
    startRequest, duplicate, compactCopy, switchBranch, selectBranch,
    editPrompt, recoverTitle, emergency, resume
}

/// Commands retain conversation identity, never a sidebar index or widget.
public struct HistoryAction
{
    string threadId;
    HistoryActionKind kind;
    int argument, direction;
    bool userTurn;
    long submittedTicks;
    string text;
}

public struct HistoryMailbox
{
    private HistoryAction[] _pending;
    enum maxPending = 128;
    enum maxTextBytes = 256 * 1024;

    size_t length() const { return _pending.length; }
    bool enqueue(HistoryAction action)
    {
        if (!action.threadId.length || action.text.length > maxTextBytes) return false;
        size_t bytes = action.text.length;
        foreach (pending; _pending)
        {
            // A periodic recovery scan must not multiply the same effect.
            if (pending.threadId == action.threadId && pending.kind == action.kind &&
                (action.kind == HistoryActionKind.recoverTitle ||
                 action.kind == HistoryActionKind.startRequest ||
                 action.kind == HistoryActionKind.resume)) return true;
            bytes += pending.text.length;
        }
        if (_pending.length >= maxPending || bytes > maxTextBytes) return false;
        _pending ~= action;
        return true;
    }

    HistoryAction[] take(string id)
    {
        HistoryAction[] result, retained;
        foreach (action; _pending)
            if (action.threadId == id) result ~= action;
            else retained ~= action;
        _pending = retained;
        return result;
    }

    void cancel(string id) { take(id); }
}
