# Latency improvements

Updated 2026-10-06. This stage improves request startup, transport ownership and
stream delivery. It does not complete the autonomous conversation-engine migration.

## Changes

- Local llama.cpp generation starts without a separate synchronous tokenizer
  request by default. Streamed provider usage remains authoritative. Set
  `AURORA_TOKEN_PREFLIGHT=1` to retain exact preflight for tokenizer diagnostics;
  token counts remain unknown until reported, rather than showing stale counts.
- Chat, title and compaction requests use asynchronous WinHTTP network operations
  on bounded provider workers. Process-owned sessions and connection leases allow
  different chats to reuse sockets. HTTP/2 is enabled when Windows and the server
  negotiate it; HTTP/1.1 remains supported. No HTTP/2 speedup has been established.
  Default connection capacity follows the provider worker budget. Idle origin
  handles are limited to 32; active leases survive until final close callbacks.
- Stop closes only its request. Callback state and read buffers remain owned
  through `HANDLE_CLOSING`; request teardown cannot invalidate another chat's
  connection. Requests do not share provider cookies or automatically follow
  redirects carrying API headers. Configure the actual API endpoint directly.
- `AURORA_HTTP_TRANSPORT=wininet` selects the compatibility transport before a
  request starts. HTTP status, typed retry policy, SSE decoding and request
  correlation are shared by both paths. Model discovery and optional exact token
  counting retain WinINet in this stage.
- Stream readers request only available bytes, avoiding full-buffer waits for
  short SSE chunks. Uploads retain one immutable JSON body instead of copying
  the entire body again, including inline base64 images.
- Workers post empty-to-nonempty queue notifications to the native application
  service. Bounded drains repost remaining work; the Win32 loop gives paint a
  turn between service passes. Native resize and widget animation timers are
  independent of these notifications. Periodic service remains a fallback.
- Optional titles start after foreground work across chats settles. They no
  longer compete with the first answer or its tool/verification continuations.
  Independent tools remain batched, with mutation barriers and required checks
  intact. Existing bounded continuation policy remains in place.
- Tool schema parsing is cached by full schema content, with bounded entries
  and input bytes. Hosted request serialization avoids another full message-array
  clone. Stable extension instructions now precede the changing environment;
  changing task checkpoints remain chronological messages for hosted providers.

## Measurements

`request latency:` log entries retain one request identity across Send, worker
admission, serialization, actual WinHTTP connection/upload notifications,
headers, first SSE bytes, first token, application, render submission and
settlement. Values are microseconds from the same monotonic origin. Missing
stages are `-1`, including a reused connection without a new connect callback.
WinINet's older connection-handle timing is not a TCP/TLS measurement.

Render submission is measured for the viewed conversation following its latest
response. It is not display scanout or a hidden conversation's first visible
frame. Different requests retain separate traces even when a continuation starts
before paint. Request preparation and durable acceptance are included for Send.

Local fixture, source fingerprint
`651701b457ef1c837bc674efe0a44aac0a233d733fe61e87d125b6832e35dace`:

| Fixture stage | First token |
| --- | ---: |
| Cold request, tokenizer preflight skipped | 23.177 ms |
| Warm request from a separate client | 1.826 ms |
| Opt-in tokenizer call with intentional 500 ms server delay | 525.829 ms |

Cancellation before response headers returned in less than one measured
millisecond. These are deterministic localhost measurements, not production
gateway improvements. The deliberate tokenizer delay demonstrates removal of
one serial request; it does not estimate a real model's token-counting time.

## Verification

```
python aurora-opencode-pro/tests/run_architecture_checks.py
python aurora-opencode-pro/tests/test_latency_transport.py
python aurora-opencode-pro/tests/test_provider_roundtrip.py
python aurora-opencode-pro/tests/test_parallel_tool_batch.py
```

Transport evidence: `build/architecture-checks-49_b7um0/`. It checks actual TCP
reuse across clients, eight simultaneous requests, isolated stream cancellation,
pre-header cancellation, first-chunk delivery before stream completion, 503
recovery, WinINet parity, opt-in token counting, schema identity, stable prompt
prefix and idle handle limits. The desktop fixture covers four tool rounds,
verification, first-token-to-render timing and title generation after the final
foreground round. UI contracts dispatch actual native notifications with timer
messages excluded.

No binary wire format or assembly rewrite was introduced: provider compatibility
requires the existing JSON/SSE contract, and no profiling evidence identifies
machine-code execution as the dominant wait. Large binary attachments already
have separate local blob storage; provider image uploads still follow its API.

## Remaining

Full per-chat actors, background request projection and immutable UI subscriptions
remain unfinished. The application service runs independently of widget ticks
but still uses the window thread; expensive coordination or synchronous durable
acceptance can therefore delay input. Incremental structural transcript/group
projection and production latency baselines remain required. See
`message-response-implementation-status.md` for the broader migration gates.

## Deployment

The existing self-helper completed one release rebuild and relaunched the app.
Build exit code: 0; duration: 64,150 ms; live process: 51504. The executable is
newer than every compiled D source and matches the verified source fingerprint.
The per-build publisher skip was used only for this local deployment.

Executable SHA-256:
`c1655d9002f904fc126cd398c593bc02372fbe163fc5a4864e423a6b0e853d0d`.
Deployment evidence: `build/latency-deploy.json`.

All six regression suites passed under `build/architecture-checks-6_c12d_x/`.
The desktop/title/cancellation fixture passed under
`build/architecture-checks-2j7pji4i/`; twelve stalled-stream cancellations
returned in less than one measured millisecond. 140 real tool batches passed.

The deployed production executable also passed four real local HTTP/SSE rounds,
native writes, a Python check, READY response and persisted reload state through
its own `--headless` entry point. Its hash matches the live image. That process
used isolated state and workspace. Evidence:
`build/production-roundtrip-yke9to4b/result.json`.
