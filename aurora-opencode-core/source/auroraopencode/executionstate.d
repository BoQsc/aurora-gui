module auroraopencode.executionstate;

public enum RequestPhase { idle, waiting, streaming, executingTools, stopped, failed, completed }
public enum ExecutionCommandKind { accept, networkBegan, delta, toolsRequested, complete, fail, stop }

public struct ExecutionCommand
{
    ExecutionCommandKind kind;
    ulong requestId;
    bool cancelled;
}

public struct ExecutionState
{
    RequestPhase phase;
    ulong requestId;
    ulong revision;
}

public struct ExecutionTransition
{
    ExecutionState state;
    bool accepted;
}

/// Deterministic protocol reduction. No clocks, widgets, I/O, or callbacks.
/// The effect coordinator applies only accepted transitions to presentation.
public ExecutionTransition reduceExecution(ExecutionState state,
    ExecutionCommand command) pure nothrow @safe @nogc
{
    if (command.kind != ExecutionCommandKind.accept &&
        command.kind != ExecutionCommandKind.stop && command.requestId &&
        command.requestId != state.requestId)
        return ExecutionTransition(state, false);
    final switch (command.kind)
    {
        case ExecutionCommandKind.accept:
            state.requestId = command.requestId;
            state.phase = RequestPhase.waiting;
            break;
        case ExecutionCommandKind.networkBegan:
        case ExecutionCommandKind.delta: state.phase = RequestPhase.streaming; break;
        case ExecutionCommandKind.toolsRequested: state.phase = RequestPhase.executingTools; break;
        case ExecutionCommandKind.complete:
            state.phase = command.cancelled ? RequestPhase.stopped : RequestPhase.completed;
            break;
        case ExecutionCommandKind.fail: state.phase = RequestPhase.failed; break;
        case ExecutionCommandKind.stop:
            state.requestId = 0;
            state.phase = RequestPhase.stopped;
            break;
    }
    ++state.revision;
    return ExecutionTransition(state, true);
}
