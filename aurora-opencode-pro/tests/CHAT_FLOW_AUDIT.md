# Chat flow audit — 2026-10-10

Tested a conversation that moves from casual planning into file work and
debugging, along with interruption, concurrent chats and restored history.
All probes use isolated state and workspaces; the user's conversations are
not used as test fixtures.

## Findings and fixes

1. Writing a prose document marked executable verification as required. Even
   after the agent read the Markdown back, Aurora manufactured another model
   request and another final answer. Successful native write/edit operations
   on `.md`, `.markdown`, `.rst` and `.adoc` no longer introduce that requirement.
   They do not clear verification already outstanding for code or other changes.
2. `python -u -m unittest` was not recognized as verification, because the
   command recognizer expected `-m` as the first argument. Supported interpreter
   switches can now precede the module. Arbitrary scripts, `-c`, help and
   collection-only invocations still cannot stand in for an executed check.
3. Failed tools showed a red rail without naming the outcome in their collapsed
   row. Their headers now say `Shell · Failed` before the long command, and
   collapsed action groups include a failure count. The original output stays
   available by expanding the row.

## Deterministic conversation

Run `python aurora-opencode-pro/tests/test_conversation_flow.py` from the repo
root with DMD on PATH. This starts a local provider and drives the real composer,
HTTP/SSE client, tool workers, transcript layout and persistence. The provider
streams tool arguments in separate frames and checks request history itself.

| Scenario | Verified |
| --- | --- |
| Casual planning and a correction | Original preferences and corrected constraints remain in outgoing context; no tool activity for plain replies |
| Save a Markdown plan and read it back | Exactly one final response, two tools, no synthetic verification continuation |
| Debug a failing Python test | Actual failure reaches the provider; an edit is followed by the same passing unittest command |
| Steering during a running command | Guidance is queued and delivered exactly once at a safe boundary |
| Queued recap | Runs after the repair and retains tool history |
| Failure presentation | Collapsed group names the failed command; child header includes `Failed` |
| Stop then send again | Partial response is retained; late output cannot overwrite the new answer |
| Switch chats during streaming | Both conversations receive their own output and survive reload |
| Mixed document and code changes | Document write/read cannot clear outstanding code verification |

The final scenario passed with exactly **16 HTTP requests**, including the
background conversation. Before the Python verification fix, the same scenario
made 19 requests because stale verification state reopened later turns.

## Live model probe

The explicit opt-in command
`python aurora-opencode-pro/tests/probe_live_conversation.py --live` uses the
configured provider and makes paid requests. It launches the rebuilt desktop
image through `--headless-loop`, keeping the real widgets and one conversation
alive across four prompts. The saved settings credential is scrubbed afterward.

The live run used `deepseek/deepseek-v4.1-flash` via CommandCode:

- Four connected user turns; seven tool calls; 21.58 seconds for the complete run.
- Two casual turns retained dietary/time preferences and corrected the guest
  count without using tools.
- The agent wrote and read back the dinner plan without running commands.
- For a separate Python bug, it reproduced the failing test, changed the
  implementation, and reran `python -u -B -m unittest test_guest_count` successfully.
- An independent test rerun passed. Neither the test file nor the dinner plan
  was changed to make the repair appear successful.
- No redundant verification continuations were recorded.

Timing varies with the provider. This is one observed model conversation,
not a guarantee about every future answer. Evidence is retained locally at
`build/live-conversation-wqzhmz4s/`, including prompts, transcript, result JSON,
isolated chat history and the independent check.

## Regression and delivery checks

All nine default architecture/UI fixtures passed against D source fingerprint
`5bc5eaaecc8edb6e9b1d65cfb6c3c7a2d623201d3a48d817545a74a9ff855fd9`.
The real HTTP provider round trip, retry/transport tests and regeneration/history
tests also passed. Twelve stalled-stream cancellations completed without
blocking the caller (worst measured cancellation call: 0 ms at millisecond
resolution).

One initial concurrent suite run reached the smoke fixture's five-second native
tool-result deadline with zero results. The isolated rerun passed, as did the
conversation-level tool scenario. No product root cause was established for
that isolated stress failure; preserve its evidence rather than interpreting
the successful rerun as proof under every load. Logs are in
`build/architecture-checks-sn9bgbx8/`; the passing rerun is in
`build/architecture-checks-9pustja4/`.

The built-in release rebuild succeeded and the new desktop window relaunched.
The executable is newer than the source, and its SHA-256 is
`002528b62853c6fe8b7b7b8dd2e98aaed36fc6835cb48c630ace11b37f054e51`.
The actual built image also passed four local HTTP/SSE rounds with native
write/run tools, a completed plan and a persisted final answer.

After rebuilding, the native delivery fixture passed six streamed responses
over one reused TCP connection, with **16.954 ms median** and **28.724 ms maximum**
from first token to render submission. Every first paint preceded stream
completion. These measure local client/frame overhead using a controlled
provider, not live provider wait time or an absolute achievable minimum.
Delivery evidence is in `build/architecture-checks-u065x28a/`.

Reproduce with:

```powershell
python aurora-opencode-pro/tests/run_architecture_checks.py
python aurora-opencode-pro/tests/test_conversation_flow.py
python aurora-opencode-pro/tests/test_provider_roundtrip.py
python aurora-opencode-pro/tests/test_latency_transport.py
python aurora-opencode-pro/tests/test_latency_transport.py --history
# After the built-in release rebuild and relaunch:
python aurora-opencode-pro/tests/test_provider_roundtrip.py --production
python aurora-opencode-pro/tests/test_latency_transport.py --delivery
# Optional: real configured provider, paid requests:
python aurora-opencode-pro/tests/probe_live_conversation.py --live
```
