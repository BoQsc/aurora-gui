module auroraopencode.toolstate;

/// Resource-blocked work never entered the tool body. Keep this distinct from
/// an executed failure, both for presentation and for deterministic recovery.
public enum ToolState { unspecified, queued, running, completed, failed, cancelled, resourceBlocked }

public string toolStateName(ToolState state)
{
    final switch (state)
    {
        case ToolState.unspecified: return "";
        case ToolState.queued: return "queued";
        case ToolState.running: return "running";
        case ToolState.completed: return "completed";
        case ToolState.failed: return "failed";
        case ToolState.cancelled: return "cancelled";
        case ToolState.resourceBlocked: return "resource_blocked";
    }
}

public ToolState parseToolState(string name)
{
    foreach (state; [ToolState.queued, ToolState.running, ToolState.completed,
        ToolState.failed, ToolState.cancelled, ToolState.resourceBlocked])
        if (name == toolStateName(state)) return state;
    return ToolState.unspecified;
}

public ToolState terminalToolState(ToolState state, bool failed)
{
    if (state == ToolState.cancelled || state == ToolState.resourceBlocked) return state;
    return failed ? ToolState.failed : ToolState.completed;
}
