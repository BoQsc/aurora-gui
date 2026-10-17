# Agent output recovery

When tools are enabled, Aurora detects repeated prose and XML invocations of
offered tools printed in the answer channel. Fenced code and quoted examples
remain ordinary text. Printed invocations are never converted to executable
calls. Detection covers growing streams and settled responses, including a
single complete invocation with no structured call.

The failed response stays in the saved chat for diagnosis but is excluded from
subsequent provider requests. Aurora retains tool schemas and successful tool
results while requesting a valid action or supported answer. Repeated failures
continue recovery and can route to the configured diagnostic reviewer. They do
not require the user to restart an unfinished task. Stop still cancels execution.

Whole-answer replays with only a small addition also use this recovery path.
For llama.cpp, folding a trailing system continuation now adds a wire-only user
boundary, avoiding accidental prefill of the preceding assistant answer.
Hosted providers retain chronological instruction messages.

The identical-call limit counts executions since the latest real user
instruction or successful file mutation. Source edits, including comment and
whitespace changes, release an identical build command. No-op and failed edits
do not release it.
An exhausted call is skipped and recovery requests a different action or
hypothesis. Its repeated effects are never executed, and its limit does not
terminate the user's whole plan.

## Provider diagnostics

Start Aurora with `AURORA_PROVIDER_TRACE=1` in its environment to capture opt-in
request and SSE evidence in the normal `logs/errors.log`. Entries have the
`provider-wire` prefix, request ID, selected model, and request/SSE kind. This
shows whether invocation markup arrived inside `delta.content` or a provider
returned actual `delta.tool_calls`. `agent-output` entries link failures and
recovery decisions to the request and thread.

Headers are omitted. The configured API key, known credential fields, and
inline data URLs are redacted. Text fields are limited to 2 KiB and each
request to 128 KiB; the normal log rotation still applies. This is a diagnostic
sample, not a complete raw capture. Other conversation and tool text can remain
in the logs, so inspect them before sharing. Tracing is off by default.

## Offline checks

From the repository root:

```text
python scripts/check-opencode-agent-loops.py
python scripts/check-opencode-agent-loops.py --snapshot C:/path/to/chat-snapshot.zip
python scripts/check-opencode-chat.py --pro
```

The first check uses a local HTTP/SSE fixture and separate test executables.
It verifies recovery, no execution of printed XML, continued recovery after repeated
failure, prose-loop recovery, replay detection, diagnostic redaction, and build
guard resets. The optional snapshot replays the three identified archived
responses. These checks do not contact a model provider or replace the live app.
