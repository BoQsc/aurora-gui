# Aurora versus original OpenCode benchmark

This benchmark runs the same synthetic D coding tasks through Aurora's actual
`OpenCodeRoot` conversation path (in a software-rendered test window) and the
installed original `opencode run` CLI. Each attempt gets a fresh workspace.
An independent verifier compiles and runs both the requested app and hidden
behavior assertions after the agent stops.

## Run

From the repository root on Windows, with Python, DMD, and original OpenCode
installed:

```text
python aurora-opencode-pro/benchmarks/compare.py --list
python aurora-opencode-pro/benchmarks/compare.py --tasks clamp --repeats 1
python aurora-opencode-pro/benchmarks/compare.py
```

The default command runs all ten tasks twice on each harness: 40 model runs.
Use `--tasks` to select comma-separated IDs, `--repeats` to change replication,
and `--timeout` to set each agent's time limit. Runs alternate harness order
on successive repetitions. The runner uses Aurora's configured OpenCode Go key
for both harnesses, or `AURORA_BENCH_KEY` if set. It passes the key to original
OpenCode through an environment reference in a temporary config file. Each
Aurora test state directory temporarily contains the key and is removed after
that run, including if the run fails.

Results go to a timestamped directory under the system temp directory by
default. `results.json` is machine readable, `index.html` is an offline
interactive dashboard, and individual run folders contain synthetic workspaces
and process output. Use `--output PATH` to choose a new result directory.

```text
python aurora-opencode-pro/benchmarks/compare.py --report PATH/results.json
python aurora-opencode-pro/benchmarks/compare.py --reverify PATH/results.json
python aurora-opencode-pro/benchmarks/compare.py --merge FIRST/results.json SECOND/results.json
python -m unittest discover -s aurora-opencode-pro/benchmarks -p test_compare.py
```

`--reverify` requires the saved workspaces. A merged report can reverify while
its source run directories still exist.

## Reading the results

- A pass means the agent returned successfully, the requested demonstration
  compiled and ran, and hidden behavior assertions passed. Tool errors are
  counted separately even when the agent recovers.
- Token totals sum provider usage across all assistant rounds. For original
  OpenCode this is input + output + cache reads + cache writes. Aurora's saved
  usage reports prompt, completion, and total, but not separate cache reads.
  The dashboard shows missing usage as unknown rather than zero.
- Time is end-to-end process time for each run; it includes harness startup and
  excludes the one-time compilation of the Aurora benchmark driver.
- The suite tests coding behavior and tool loops, including a path with spaces
  and a broken build. It does not measure visible-window interaction or network
  fault recovery. Two repetitions are a baseline, not a statistical guarantee.

The checked-in baseline under `reports/2026-09-23/` used DeepSeek V4.1 Flash
and installed original OpenCode 1.18.32. Both harnesses passed 20/20 attempts.
Aurora used 666,643 provider tokens across the suite, versus 1,620,983 for
original OpenCode. Aurora recorded eight recoverable tool errors, while
original OpenCode recorded none. The individual attempts and per-task medians
are in the dashboard; several errors were generated-code compile failures,
so they are not all evidence of a broken tool implementation.

## API latency probes

`latency.py` separates time to first streamed output from generation time. It
uses the active Aurora provider key through curl's stdin and writes only timings,
payload sizes, token usage, and errors. It never saves credentials or chat text.

```text
python aurora-opencode-pro/benchmarks/latency.py --repeats 2 --output PATH/results.json
python aurora-opencode-pro/benchmarks/latency.py --cases none --context-lines 6500 --output PATH/context.json
python aurora-opencode-pro/benchmarks/latency.py --cases none --image stored --output PATH/stored.json
python aurora-opencode-pro/benchmarks/latency.py --cases none --image compressed --output PATH/compressed.json
```

The two synthetic image modes contain identical pixels. `--saved-images` sends
the active saved chat's newest two images with a synthetic prompt; its text is
excluded. Image bodies and base64 exist only in temporary files during the run.
`--prompt` can request longer output to measure generation throughput.

To compare Aurora's real WinINet client, compile `latency_client.d` with the core
and Aurora import paths and the Windows libraries, then pass
`--client PATH/latency-client.exe`. `sent_ms` uses WinINet's request-sent callback;
`headers_ms` includes the subsequent upstream wait. Curl's `time_posttransfer`
is the corresponding upload boundary. Historical Aurora logs incorrectly used
the header time for both fields.

The October 1 results and their limitations are in
`reports/2026-10-01-latency/RESULTS.txt`.

`--image-files PATH [PATH ...]` accepts PNG/JPEG fixtures and detects their MIME
types. It records sizes and timings without retaining the images. This supports
comparing the prior two PNG frames with the current single JPEG frame, with
`--context-lines 6500` supplying roughly 70k tokens of synthetic chat history.

Generated screen captures now use native-size JPEG at quality 85. Requests carry
one latest generated frame, or its current focused recovery pair, independently
of user attachments. The transcript
retains two generated frames across all branches and upgrades retained legacy
PNG frames on startup. Earlier attachment metadata and chat text remain saved.

`python aurora-opencode-pro/tests/test_screenshot_history.py` runs
`tests/screenshot_history_test.d`, which exercises 4,500 frames, 1,000 recovery
pairs, inactive branches,
independent user images, native JPEG dimensions and color orientation, and
rolling text compaction with tool-pair preservation and save/reload. Compile it
with the same Pro/core/Aurora import paths and Windows libraries as the benchmark
driver. Its optional first argument is an output directory for a JPEG fixture;
further arguments are PNG fixtures to convert using the production encoder.

## Computer input regression checks

```text
python aurora-opencode-pro/tests/test_computeruse_input.py
python aurora-opencode-pro/tests/test_mouse_buttons.py
```

This compiles the production input code and opens two disposable fixture
windows. It verifies target changes across windows, keyboard target inheritance,
explicit overrides, native input delivery through actual text/button events,
own-process refusal, failed-batch screenshots, and capture without changing
foreground. The fixtures close and their state directory is removed afterward.
Run desktop input tests sequentially; they share the desktop. The button test
records real Win32 down/up events for native and virtual left/right/middle
clicks, double-clicks, the right-click alias and batches. Invalid button values
are refused. `click` with `button: "right"` sends the same button as `right_click`.

`computer` accepts `input_mode: "native"` or `"virtual"` for a call and its
batch/nested actions; omission uses Settings, except nested subagent loops default
to native input. Posted virtual messages report
queue delivery with an unverified application response. Use native input for
games and shell controls that ignore posted messages. Input actions now return
a fresh JPEG by default; `screenshot: false` suppresses routine captures returned
to the model. A withheld stalled click still returns current evidence. Valid
image evidence survives failed tool results, and observing the screen no longer
raises a remembered input target. The steering prompt requires current visual
evidence before claiming progress or repeating an ineffective action.

## Stalled interaction and explanation checks

```text
python aurora-opencode-pro/tests/test_computeruse_progress.py
python aurora-opencode-pro/tests/test_computeruse_input.py
```

After three nearby clicks with little visible change, the next click is withheld
and returns a native target crop plus an instruction strip as JPEGs, with desktop
origins and actual crop dimensions. The first pair permits one grounded retry;
further nearby clicks are withheld if that retry shows little change. This
includes coordinate jitter, batches and
calls with `screenshot: false`. A coarse RGB comparison tolerates small animation,
corner hover effects and the taskbar clock; it is a heuristic, not a semantic
success detector. A successful crop of at least 32x32 pixels permits another
attempt; a full-frame screenshot alone does not reset the guard. Changed visible
state, a different mouse button/input action/area/target/mode, or a real new user request also
permits recovery.

Explanation-only follow-ups such as "why you couldn't complete" preserve the
unfinished checklist, skip plan reconciliation and automatic continuation, and
refuse desktop input. They do not clear a kill-switch stop. Explicit resume or
combined diagnosis-and-action requests permit work again. Intent recognition is
conservative English phrase matching, not a general natural-language classifier.

The progress test can also replay a 1920x1080 RGB frame before the stalled click
sequence plus four post-click frames as command-line arguments. Private chat
images are not included in the test fixtures.

The latest button-dispatch diagnosis and recovery checks are recorded in
`reports/2026-10-01-latency/COMPUTER_BUTTON_RECOVERY_RESULTS.txt`.

## Drag, timed wait and nested-loop checks

```text
python aurora-opencode-pro/tests/test_computeruse_drags.py
python aurora-opencode-pro/tests/test_computeruse_nested.py
```

Three drags with the same target, button, delivery mode and direction require a
focused crop before continuing. Coordinate jitter and scene motion do not reset
the limit. The automatic crop permits one retry; reversing direction, changing
approach or explicitly inspecting a crop permits re-grounding. This is a bounded
interaction policy, not a semantic detector of whether a camera objective passed.

Use `mouse_move` followed by `wait` with `duration_ms` for edge-pan dwell. `wait`
waits the whole requested 1..10000 ms and checks the kill switch every 50 ms.
`wait_for_change` now uses the coarse visible-change comparison, which tolerates
small animation; it can still finish early on a large animation or unrelated
screen change and does not prove completion.

Nested loops use the selected application model unless `model` explicitly
overrides it. Their default frame is half size, matching the schema. `window`
binds a loop to that target; otherwise it inherits an established target.
Switching desktop shortcuts, other-window inputs and escaping drag endpoints
are refused within a bound loop. Native loops activate that target before each
capture and input. Inner calls inherit the outer input mode. Requested native
crops and recovery pairs reach only the next model request, with origin/scale
guidance; routine frames and old crops do not accumulate. Loop-limit and
unresolved-refusal exits report failure and return a current JPEG.

The nested regression uses a loopback scripted provider and disposable windows.
It records outbound model selections, actual fixture typing, refused shortcuts
and other-window inputs, crop dimensions, and absence of stale images. It does
not use the user's provider credentials or resume their game. Details are in
`reports/2026-10-01-latency/COMPUTER_DRAG_NESTED_RESULTS.txt`.
