# Chat flow hardening: bounded stage

The user deferred the broader redesign on 2026-10-06. This stage finishes the
changes already underway; it does not complete the autonomous engine migration.

## Delivered behavior

- Read, glob, grep, image inspection and dshell run in bounded helper processes.
  Stop or a hard deadline terminates the host and releases its physical slot.
  Four blocked filesystem calls can no longer permanently occupy four workers.
  Images retain their name, MIME type and exact encoded evidence over IPC.
- Journal intents queue without waiting on the window thread. Chat starts and
  tool batches enter the same ordered repository after their preceding intents.
  Stop revokes queued admissions. Failed storage refuses effects and requires a
  successful snapshot acknowledgement before recovery.
- Large snapshot serialization and writes use a separate owner, after a journal
  fence. They no longer occupy the journal's intent/effect queue.
- A bounded per-client wire cache reuses unchanged escaped message projections;
  changing tool arguments invalidates the affected entry. Provider JSON remains
  compatible and semantic context is not truncated by this cache.
- Transcript projection reconciles existing children, retains focus and caches
  settled groups. Tool-result ownership lookup supports repeated call IDs in
  later rounds. Only the latest action group receives an automatically open tail.
- Upload, headers and streaming milestones are separated. WinHTTP calls execute
  outside the callback mutex with a handle lease protecting concurrent Stop.
  The body uses WriteData and its completion notification; SendRequest completion
  with an inline body proved unsuitable as an upload boundary in the local test.

## Verification

The isolated runner records the complete D-source fingerprint, executable hash,
Git HEAD, status and duration beside each fixture. All tests use private state
and executables. The final checks and deployment evidence are recorded below.

The delayed-header transport fixture reads the entire request body, waits 400 ms,
then sends headers. It requires at least 350 ms between upload completion and
headers. It also checks actual TCP reuse across clients, eight parallel requests,
Stop before headers, retry, first-chunk delivery and opt-in token counting.

The resilience fixture blocks all four filesystem hosts, cancels one, completes
a fifth chat's read, and checks every blocked process has terminated. Other
contracts cover storage failure/recovery, ordering, Stop before acknowledgement,
exact image IPC, cache invalidation and focus retention across a 10,000-row
projection. These are fixture measurements, not production speedup claims.

## Deferred

The window thread still owns substantial request preparation, policy and
continuation logic. Compaction/title/computer-use paths need further effect
extraction. Full actor migration, deeper context improvements, complex-content
benchmarks and real gateway latency attribution remain for later.

No binary provider protocol is introduced. Payload size, provider wait and
presentation costs should be measured independently before replacing compatible
JSON/SSE. Process startup overhead also needs production measurement.

## Final source verification

All eight final fixtures passed for D-source fingerprint
2c7fde57109532f34c6b2f60396d7cd7cc4aeb42479c28d5b06e5c2acafca1ff.

- uild/architecture-checks-c9kzj54n/: full UI smoke, native-service/storage
  recovery, and flow resilience. Fifth-chat read completed in 155 ms after
  cancelling one of four blocked hosts; zero blocked hosts survived.
- uild/architecture-checks-vq9xlt2t/: architecture, presentation, chat
  consistency and tool contracts.
- uild/architecture-checks-9_kt0acf/: local transport contracts, plus the
  Python server assertions for actual TCP reuse and eight concurrent requests.
  The delayed-header trace recorded upload at 15031 us and headers at 428401 us.

Commands: python -X utf8 aurora-opencode-pro/tests/run_architecture_checks.py
(the seven fixtures were split across two invocations), and
python -X utf8 aurora-opencode-pro/tests/test_latency_transport.py.
git diff --check passed.

## Deployment verification

The Aurora self-helper rebuilt the release image with exit code 0 and relaunched
it under supervision. Duration: 112154 ms. New app PID: 17344.
The binary is newer than every compiled source and matches the verified source
fingerprint above. Image SHA-256:
250734dbd293f288c59658b66190bacc33cb0ae6f5a8d3d0d3cb54617494863.

Evidence: uild/flow-deploy.json. The built executable passed its read, grep,
glob, dshell and view_image helper modes in private state/workspace; image name,
MIME type and exact pixels survived. Results:
uild/production-filesystem-62r3k8q4/. These single host launches took 39–60 ms
in this isolated check; they do not establish interactive production latency.

The same built image passed four actual HTTP/SSE rounds against the loopback
provider through its headless real-widget entry point: plan, native writes, a
Python unittest, paired results, final READY response and persisted history.
Artifacts: uild/production-roundtrip-5ubtci23/. Its recorded image hash matches
the deployed executable. Real remote-provider behavior remains unverified by
these local fixtures.

The current stage is finished. The broader migration is paused at the user's
request; no further redesign is scheduled by this stage.
