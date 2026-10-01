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
one latest generated frame independently of user attachments. The transcript
retains two generated frames across all branches and upgrades retained legacy
PNG frames on startup. Earlier attachment metadata and chat text remain saved.

`tests/screenshot_history_test.d` exercises 4,500 frames, inactive branches,
independent user images, native JPEG dimensions and color orientation, and
rolling text compaction with tool-pair preservation and save/reload. Compile it
with the same Pro/core/Aurora import paths and Windows libraries as the benchmark
driver. Its optional first argument is an output directory for a JPEG fixture;
further arguments are PNG fixtures to convert using the production encoder.

## Computer input regression checks

```text
python aurora-opencode-pro/tests/test_computeruse_input.py
```

This compiles the production input code and opens two disposable fixture
windows. It verifies target changes across windows, keyboard target inheritance,
explicit overrides, native input delivery through actual text/button events,
own-process refusal, failed-batch screenshots, and capture without changing
foreground. The fixtures close and their state directory is removed afterward.

`computer` accepts `input_mode: "native"` or `"virtual"` for a call and its
batch/nested actions; omission uses Settings. Posted virtual messages report
queue delivery with an unverified application response. Use native input for
games and shell controls that ignore posted messages. Input actions now return
a fresh JPEG by default; `screenshot: false` explicitly suppresses it. Valid
image evidence survives failed tool results, and observing the screen no longer
raises a remembered input target. The steering prompt requires current visual
evidence before claiming progress or repeating an ineffective action.
