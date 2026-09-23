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
