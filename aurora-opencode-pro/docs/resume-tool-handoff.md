# Native tool results after Stop and resume

The 2026-10-15 report showed a directory listing apparently running for 56.2
seconds, with a placeholder saying it was waiting for conversation storage.
The matching native lifecycle record shows that the listing actually finished
successfully in 40 ms. Its result was absent from the saved conversation.

Stop latched the conversation's `turnCancelled` flag. Normal Send cleared it,
but Continue, Regenerate and queued prompts started requests through other
paths. Those requests could produce and execute native tool calls while
`applyToolOutput` and `applyToolResult` silently rejected their events because
the old flag was still set. The pending row retained its initial storage-wait
text and continued counting time after the tool finished.

`startChatRequest` now clears the old presentation cancellation latch when it
opens a new user turn, including Continue, Retry/Regenerate and queued prompts.
Automatic tool continuations do not clear it. The old cancellation tokens remain
cancelled, and request-ID filtering continues rejecting events from the old
request. No storage or tool-execution barrier is bypassed.

## Reproduction and verification

`tests/test_resume_tool_handoff.py` drives real action callbacks, HTTP/SSE,
native directory listing, result consumption and final response. All data,
credentials and state are synthetic. The original source stalls after Stop in
Continue, Regenerate and queued-message scenarios; the normal-Send control
passes. The fixed source passes all four scenarios in exactly two HTTP requests
each. Every scenario also verifies that Stop rejects a late tool result.

Baseline: 1/4 passes; three scenarios remain pending until the eight-second
fixture deadline despite native completion. Candidate: 4/4 passes, with measured
local elapsed times of 94–166 ms. These are controlled regression timings, not
live provider latency predictions.

```
python tests/test_resume_tool_handoff.py --build --output build/resume-handoff/results.json
python tests/test_resume_tool_handoff.py --output build/resume-handoff/results.json
python tests/test_conversation_flow.py
python tests/run_architecture_checks.py execution_ui_contracts flow_resilience_contracts task_continuation_contracts
python tests/test_latency_transport.py --history
```

Delivery follows `AGENTS.md`: source publication, clean rebuild and relaunch,
required update publication and a final optimized native GUI delivery check.
