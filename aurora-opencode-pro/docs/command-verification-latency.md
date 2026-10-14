# Avoiding unnecessary verification requests

Validated 2026-10-14 against source baseline
`33b6ff442dab9a03d40356abc87159471c4142f4`.

Aurora used to treat every unrecognized foreground executable as a workspace
mutation, even when a program only printed its result. Running that program
after a successful compiler check reopened verification. Completing the plan
then required another model request, another compiler invocation and another
final response. Image retirement and task-blocker metadata also occupied the
workspace mutation lane.

The scheduler now treats image retirement and task-blocker metadata as control
operations. For an unrecognized successful foreground executable, a complete
bounded snapshot before and after execution can preserve existing verification
when checkout file contents and paths are unchanged. The executable does not
become a verification check. A separate Aurora developer source checkout still
receives conservative invalidation when only the active project was observed.

## Safety and limits

Snapshots include untracked files and empty directories, without ignore rules.
The root is the whole Git checkout when the workspace is inside one. Symlinks,
unreadable entries, unsupported entries or incomplete inventories return unknown.
The limits are 16 MiB, 512 files, 128 directories and depth 32. Each snapshot
has a soft 200 ms deadline checked between OS calls; a single OS call can exceed
it. Cancellation returns unknown. Failed, timed out, background or automatically
detached executions remain conservative. Ordinary chat requests do not take
these snapshots.

Large or inaccessible projects retain the existing verification behavior.
The observation concerns checkout contents during the command; it does not
establish properties of external services or later background activity.

## Causal comparison

`benchmarks/validate_command_rounds.py` drives the actual desktop conversation,
tool scheduler and durable plan loop using a controlled local SSE provider.
It creates independent temporary workspaces and synthetic credentials, and
deletes them afterward. Both binaries use the same prompt policy. The provider
adds fixed delays of 0, 250 and 1,000 ms per request. It returns another compiler
check only when Aurora reopens a completed task. Every case independently checks
the compiled output, unrelated file contents, tool-result pairing and final
verification status.

All 24 runs passed. At a fixed 1,000 ms delay per provider request:

| Task | Previous requests | Current requests | Previous elapsed | Current elapsed |
| --- | ---: | ---: | ---: | ---: |
| Compile, then run a read-only executable | 7 | 5 | 7.969 s | 5.843 s |
| Compile, then retire an actual branch image | 8 | 6 | 9.016 s | 6.844 s |
| Run an executable that changes a file | 7 | 7 | 8.828 s | 8.703 s |
| Run with an oversized workspace | 7 | 7 | 8.609 s | 8.266 s |

These timings demonstrate avoided requests under a controlled delay. They do
not predict live provider latency or establish a universal speed improvement.

`benchmarks/command_effects.py` compares identical native scheduler fixtures
using the old committed tools/scheduler overlay and current production modules.
It records binary and module digests. Checks cover read-only execution,
mutations, file creation, failures, timeout, background execution, control
operations and a separate developer checkout. The candidate must pass every
case; baseline failures on the improved cases are expected. Across three
counterbalanced repetitions, the baseline passed 18/30 checks and the candidate
passed 30/30. Tools, task continuation, flow recovery, Git mutation hooks and
snapshot limit regressions also passed.

## Reproducing

Build an isolated `tests/benchmark_app_path.d` executable from the baseline
commit and another from the current source, with identical compiler flags and
without `AuroraBatchingBaseline`. Never replace the running desktop executable
for a benchmark. Then run:

```
python benchmarks/validate_command_rounds.py --baseline <old.exe> --candidate <new.exe> --output build/command-rounds/results.json
python benchmarks/command_effects.py --build baseline --baseline-ref 33b6ff442dab9a03d40356abc87159471c4142f4 --output build/command-effects/results.json
python benchmarks/command_effects.py --build candidate --output build/command-effects/results.json
python benchmarks/command_effects.py --output build/command-effects/results.json
python tests/run_architecture_checks.py tools_test task_continuation_contracts flow_resilience_contracts
python tests/run_architecture_checks.py --release latency_cleanup_contracts workspace_fingerprint_contracts
```

Delivery additionally requires the standard rebuild, relaunch, source publication,
required update publication and post-relaunch native GUI delivery check from
`AGENTS.md`. Preserve chat history and user settings throughout.
