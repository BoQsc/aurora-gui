module liveness_contracts;

import auroraopencode.executioncontrol;
import std.stdio : writeln;
import std.string : indexOf;

uint bit(TurnOperation operation) { return cast(uint) operation; }

int main()
{
    const empty = turnOwnedOperations(false, false, false, 0, 0, false,
        false, false, false, false);
    assert(!turnOwnsOperation(empty) && turnOperationLabel(empty) == "none",
        "An empty turn was treated as owning an operation");

    struct Case
    {
        string name;
        bool stopping, provider, compacting, continuation, storage, events,
            children, paused;
        int results;
        size_t calls;
        uint expected;
    }
    const cases = [
        Case("stopping", true, false, false, false, false, false, false, false,
            0, 0, bit(TurnOperation.stopping)),
        Case("provider", false, true, false, false, false, false, false, false,
            0, 0, bit(TurnOperation.provider)),
        Case("compaction", false, false, true, false, false, false, false,
            false, 0, 0, bit(TurnOperation.compaction)),
        Case("tool-result", false, false, false, false, false, false, false,
            false, 1, 0, bit(TurnOperation.toolResult)),
        Case("tool-call", false, false, false, false, false, false, false,
            false, 0, 1, bit(TurnOperation.toolCall)),
        Case("continuation", false, false, false, true, false, false, false,
            false, 0, 0, bit(TurnOperation.continuation)),
        Case("storage-effect", false, false, false, false, true, false, false,
            false, 0, 0, bit(TurnOperation.storageEffect)),
        Case("queued-event", false, false, false, false, false, true, false,
            false, 0, 0, bit(TurnOperation.queuedEvent)),
        Case("child-agent", false, false, false, false, false, false, true,
            false, 0, 0, bit(TurnOperation.childAgent)),
        Case("paused-continuation", false, false, false, false, false, false,
            false, true, 0, 0, bit(TurnOperation.pausedContinuation)),
    ];
    foreach (c; cases)
    {
        const operations = turnOwnedOperations(c.stopping, c.provider,
            c.compacting, c.results, c.calls, c.continuation, c.storage,
            c.events, c.children, c.paused);
        assert(turnOwnsOperation(operations), c.name ~ " was not recognized");
        assert((operations & c.expected) != 0,
            c.name ~ " produced " ~ turnOperationLabel(operations));
        assert(turnOperationLabel(operations) != "none");
    }

    const combined = turnOwnedOperations(false, true, true, 1, 1, true, true,
        true, true, true);
    assert((combined & bit(TurnOperation.provider)) != 0 &&
        (combined & bit(TurnOperation.compaction)) != 0 &&
        (combined & bit(TurnOperation.toolResult)) != 0 &&
        (combined & bit(TurnOperation.toolCall)) != 0 &&
        (combined & bit(TurnOperation.continuation)) != 0 &&
        (combined & bit(TurnOperation.storageEffect)) != 0 &&
        (combined & bit(TurnOperation.queuedEvent)) != 0 &&
        (combined & bit(TurnOperation.childAgent)) != 0 &&
        (combined & bit(TurnOperation.pausedContinuation)) != 0);
    assert(turnOperationLabel(combined).indexOf("provider") >= 0);

    // Stop is an owned operation, but it must not hide the fact that the
    // previous provider/tool operation is already gone.
    const stopping = turnOwnedOperations(true, false, false, 0, 0, false,
        false, false, false, false);
    assert(stopping == bit(TurnOperation.stopping));
    writeln("PASS every owned-operation phase is recognized and an empty turn is rejected");
    return 0;
}