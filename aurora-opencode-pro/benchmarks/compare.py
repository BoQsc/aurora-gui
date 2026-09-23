"""Paired, isolated coding-task benchmark for Aurora and original OpenCode.

Run from any directory with: python aurora-opencode-pro/benchmarks/compare.py
Results contain synthetic task data and token counts, never the API key.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from textwrap import dedent
from urllib.parse import urlparse


PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parent
MODEL = "deepseek-v4.1-flash"


@dataclass(frozen=True)
class Task:
    name: str
    prompt: str
    files: dict[str, str]
    verifier: str
    expected: str


TASKS = {
    task.name: task
    for task in [
        Task(
            "clamp",
            "Add `int clamp(int value, int minimum, int maximum)` to "
            "source/math.d. Update source/app.d to print "
            "clamp(doubleValue(6), 0, 10). Make the changes, compile and run "
            "the program, then answer concisely.",
            {
                "source/math.d": "module math;\n\nint doubleValue(int value)\n{\n"
                "    return value * 2;\n}\n",
                "source/app.d": "module app;\n\nimport std.stdio;\n"
                "import math;\n\nvoid main()\n{\n"
                "    writeln(doubleValue(6));\n}\n",
            },
            "import math;\nvoid main() { assert(clamp(-3,0,10)==0); "
            "assert(clamp(7,0,10)==7); assert(clamp(12,0,10)==10); }\n",
            "",
        ),
        Task(
            "task_store",
            "Complete the task-store feature across this D project. Add "
            "`bool complete(string title)` to TaskStore: mark only the first "
            "pending exact-title match and return whether one changed. Add "
            "`Task[] pendingSorted() const` returning a copy of unfinished "
            "tasks ordered by descending priority, then ascending title, "
            "without reordering the store. Implement `formatPendingReport`: "
            "numbered lines exactly like `1. [5] Fix bug`, each ending in a "
            "newline, or `(none)\\n`. Update app.d to complete Write docs "
            "and print the report. Compile and run it, then answer concisely.",
            {
                "source/domain.d": dedent("""\
                    module domain;
                    struct Task { string title; int priority; bool done; }
                """),
                "source/task_store.d": dedent("""\
                    module task_store;
                    import domain;
                    struct TaskStore {
                        private Task[] tasks;
                        void add(string title, int priority) {
                            tasks ~= Task(title, priority, false);
                        }
                        const(Task)[] all() const { return tasks; }
                    }
                """),
                "source/report.d": dedent("""\
                    module report;
                    import task_store;
                    string formatPendingReport(ref TaskStore store) {
                        return "TODO\\n";
                    }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    import report;
                    import task_store;
                    void main() {
                        TaskStore store;
                        store.add("Write docs", 2);
                        store.add("Fix bug", 5);
                        store.add("Refactor", 5);
                        writeln(formatPendingReport(store));
                    }
                """),
            },
            dedent("""\
                import std.stdio;
                import report;
                import task_store;
                void main() {
                    TaskStore store;
                    store.add("Zulu", 2);
                    store.add("Alpha", 5);
                    store.add("Beta", 5);
                    store.add("Alpha", 1);
                    assert(!store.complete("Missing"));
                    assert(store.complete("Alpha"));
                    auto pending = store.pendingSorted();
                    assert(pending.length == 3);
                    assert(pending[0].title == "Beta");
                    assert(pending[1].title == "Zulu");
                    assert(pending[2].title == "Alpha");
                    assert(store.all()[0].title == "Zulu");
                    assert(formatPendingReport(store) ==
                        "1. [5] Beta\\n2. [2] Zulu\\n3. [1] Alpha\\n");
                    TaskStore empty;
                    assert(formatPendingReport(empty) == "(none)\\n");
                    writeln("complex-ok");
                }
            """),
            "complex-ok",
        ),
        Task(
            "counter_repair",
            "Fix source/counter.d. `increment` must add one up to the maximum "
            "and stay at the maximum thereafter; `reset` must return the value "
            "to zero. Preserve the public API. Add a small demonstration to "
            "source/app.d, compile and run it, then answer concisely.",
            {
                "source/counter.d": dedent("""\
                    module counter;
                    struct Counter {
                        int value;
                        int maximum;
                        this(int maximum) { this.maximum = maximum; }
                        void increment() { value += 2; }
                        void reset() { value = maximum; }
                    }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    import counter;
                    void main() { Counter c = Counter(3); c.increment();
                        writeln(c.value); }
                """),
            },
            dedent("""\
                import std.stdio;
                import counter;
                void main() {
                    Counter c = Counter(2);
                    assert(c.value == 0);
                    c.increment(); assert(c.value == 1);
                    c.increment(); assert(c.value == 2);
                    c.increment(); assert(c.value == 2);
                    c.reset(); assert(c.value == 0);
                    writeln("counter-ok");
                }
            """),
            "counter-ok",
        ),
        Task(
            "range_filter",
            "Implement `int[] valuesInRange(const(int)[] values, int low, "
            "int high)` in source/filter.d. Return a new array containing "
            "values between low and high inclusive, in original order. "
            "Do not mutate the input. Update source/app.d to print the "
            "filtered values from [4, -2, 7, 4, 12] for range 4..7. "
            "Compile and run it, then answer concisely.",
            {
                "source/filter.d": "module filter;\n",
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    void main() { writeln("TODO"); }
                """),
            },
            dedent("""\
                import std.stdio;
                import filter;
                void main() {
                    int[] input = [4, -2, 7, 4, 12];
                    assert(valuesInRange(input, 4, 7) == [4, 7, 4]);
                    assert(input == [4, -2, 7, 4, 12]);
                    assert(valuesInRange(input, 8, 2).length == 0);
                    assert(valuesInRange([], -1, 1).length == 0);
                    writeln("filter-ok");
                }
            """),
            "filter-ok",
        ),
        Task(
            "stack_api",
            "Add `bool tryPop(out int value)` to IntStack in source/stack.d. "
            "Pop the most recently pushed value and return true. If empty, "
            "set value to zero and return false. Keep `length` correct. "
            "Update source/app.d to demonstrate both cases, compile and run.",
            {
                "source/stack.d": dedent("""\
                    module stack;
                    struct IntStack {
                        private int[] data;
                        void push(int value) { data ~= value; }
                        size_t length() const { return data.length; }
                    }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    import stack;
                    void main() { IntStack stack; stack.push(3);
                        writeln(stack.length); }
                """),
            },
            dedent("""\
                import std.stdio;
                import stack;
                void main() {
                    IntStack stack;
                    int value = 99;
                    assert(!stack.tryPop(value) && value == 0);
                    stack.push(3); stack.push(8);
                    assert(stack.length == 2);
                    assert(stack.tryPop(value) && value == 8);
                    assert(stack.tryPop(value) && value == 3);
                    assert(stack.length == 0);
                    assert(!stack.tryPop(value) && value == 0);
                    writeln("stack-ok");
                }
            """),
            "stack-ok",
        ),
        Task(
            "settings_parser",
            "Implement `string[string] parseSettings(string text)` in "
            "source/settings.d. Parse `key=value` lines; trim whitespace "
            "around keys and values, skip blank lines and lines starting "
            "with `#`, ignore lines without `=`, and let the last duplicate "
            "key win. Ignore empty keys. Update source/app.d to demonstrate "
            "it, compile and run.",
            {
                "source/settings.d": dedent("""\
                    module settings;
                    string[string] parseSettings(string text) { return null; }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    void main() { writeln("TODO"); }
                """),
            },
            dedent("""\
                import std.stdio;
                import settings;
                void main() {
                    auto parsed = parseSettings(
                        " # comment\\n a = first \\ninvalid\\n b=two\\n"
                        ~ "a=last\\n =ignored\\n\\n");
                    assert(parsed.length == 2);
                    assert(parsed["a"] == "last");
                    assert(parsed["b"] == "two");
                    assert(parseSettings("#x\\n\\n").length == 0);
                    writeln("settings-ok");
                }
            """),
            "settings-ok",
        ),
        Task(
            "interval_merge",
            "Implement `Interval[] mergeIntervals(const(Interval)[] values)` "
            "in source/intervals.d. Each interval has inclusive start/end. "
            "Return a new array sorted by start, merging intervals that "
            "overlap or are adjacent. Do not mutate input. Compile and run "
            "a demonstration in source/app.d.",
            {
                "source/intervals.d": dedent("""\
                    module intervals;
                    struct Interval { int start; int end; }
                    Interval[] mergeIntervals(const(Interval)[] values) {
                        return [];
                    }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    void main() { writeln("TODO"); }
                """),
            },
            dedent("""\
                import std.stdio;
                import intervals;
                void main() {
                    Interval[] input = [Interval(8, 10), Interval(1, 2),
                        Interval(3, 5), Interval(9, 12), Interval(20, 20)];
                    auto merged = mergeIntervals(input);
                    assert(merged == [Interval(1, 5), Interval(8, 12),
                        Interval(20, 20)]);
                    assert(input[0] == Interval(8, 10));
                    assert(mergeIntervals([]).length == 0);
                    writeln("intervals-ok");
                }
            """),
            "intervals-ok",
        ),
        Task(
            "log_summary",
            "Implement `int[string] countLevels(string text)` in "
            "source/logs.d. For each line shaped `LEVEL: message`, trim "
            "whitespace around LEVEL and count it. Ignore blank lines, "
            "lines without a colon, and empty levels. Matching is case "
            "sensitive. Update source/app.d to demonstrate it, compile and run.",
            {
                "source/logs.d": dedent("""\
                    module logs;
                    int[string] countLevels(string text) { return null; }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    void main() { writeln("TODO"); }
                """),
            },
            dedent("""\
                import std.stdio;
                import logs;
                void main() {
                    auto counts = countLevels(
                        " INFO : start\\nWARN: slow\\nINFO: done\\n"
                        ~ "no colon\\n: empty\\ninfo: lower\\n");
                    assert(counts.length == 3);
                    assert(counts["INFO"] == 2);
                    assert(counts["WARN"] == 1);
                    assert(counts["info"] == 1);
                    assert(countLevels("\\ninvalid\\n").length == 0);
                    writeln("logs-ok");
                }
            """),
            "logs-ok",
        ),
        Task(
            "spaced_path",
            "Read the rules in `docs/score rules.txt` and implement "
            "`int score(int base, int bonus)` in source/scoring.d. Update "
            "source/app.d to demonstrate it, compile and run.",
            {
                "docs/score rules.txt": "Score = base + max(bonus, 0). "
                "Clamp the final score to the inclusive range 0..100.\n",
                "source/scoring.d": dedent("""\
                    module scoring;
                    int score(int base, int bonus) { return base; }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    void main() { writeln("TODO"); }
                """),
            },
            dedent("""\
                import std.stdio;
                import scoring;
                void main() {
                    assert(score(10, 5) == 15);
                    assert(score(95, 20) == 100);
                    assert(score(-10, -4) == 0);
                    assert(score(40, -9) == 40);
                    writeln("score-ok");
                }
            """),
            "score-ok",
        ),
        Task(
            "broken_build",
            "Fix the syntax error in source/math.d and add "
            "`int multiply(int a, int b)` there. Update source/app.d to "
            "print `multiply(add(2, 3), 4)`. Compile and run the program, "
            "then answer concisely.",
            {
                "source/math.d": dedent("""\
                    module math;
                    int add(int a, int b) { return a + ; }
                """),
                "source/app.d": dedent("""\
                    module app;
                    import std.stdio;
                    import math;
                    void main() { writeln(add(2, 3)); }
                """),
            },
            dedent("""\
                import std.stdio;
                import math;
                void main() {
                    assert(add(2, 3) == 5);
                    assert(add(-4, 1) == -3);
                    assert(multiply(5, 4) == 20);
                    assert(multiply(-3, 2) == -6);
                    writeln("build-ok");
                }
            """),
            "build-ok",
        ),
    ]
}

APP_OUTPUT = {
    "clamp": "10",
    "task_store": "1. [5] Fix bug",
    "range_filter": "[4, 7, 4]",
    "broken_build": "20",
}


def configured_key() -> tuple[str, str]:
    key = os.environ.get("AURORA_BENCH_KEY", "")
    path = Path(os.environ.get("APPDATA", "")) / "Aurora OpenCode" / "settings.json"
    settings = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    key = key or settings.get("apiKey", "")
    if not key:
        raise RuntimeError("No Aurora API key; configure Aurora or AURORA_BENCH_KEY")
    endpoint = urlparse(settings.get("baseUrl", "")).hostname or "unknown"
    return key, endpoint


def compile_aurora_driver(output: Path) -> None:
    cmd = [
        "dmd", "-i",
        "-I" + str(PACKAGE / "source"),
        "-I" + str(ROOT / "aurora-opencode-core" / "source"),
        "-I" + str(ROOT / "vendor" / "aurora-d-0.4.5" / "source"),
        "-J" + str(PACKAGE / "assets"),
        "-of" + str(output),
        str(PACKAGE / "tests" / "benchmark_app_path.d"),
        "user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib",
    ]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Aurora driver build failed:\n" + result.stdout + result.stderr)
    object_file = output.with_suffix(".obj")
    if object_file.is_file():
        object_file.unlink()


def fixture(task: Task, workspace: Path) -> None:
    workspace.mkdir(parents=True)
    for name, content in task.files.items():
        path = workspace / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def aurora_usage(state: Path) -> dict:
    sessions_file = state / "sessions.json"
    if not sessions_file.is_file():
        return {"tokens": None, "rounds": 0, "tool_calls": 0,
                "tool_failures": 0, "tool_error_details": [],
                "cached_read": None, "cached_write": None}
    data = json.loads(sessions_file.read_text(encoding="utf-8"))
    sessions = data.get("sessions", [])
    messages = sessions[0].get("messages", []) if sessions else []
    assistants = [m for m in messages if m.get("role") == "assistant"]
    tools = [m for m in messages if m.get("role") == "tool"]
    errors = [m for m in tools if m.get("failed")]
    totals = [m.get("totalTokens", 0) for m in assistants]
    return {
        "tokens": sum(totals) if totals and all(t > 0 for t in totals) else None,
        "rounds": len(assistants),
        "tool_calls": sum(len(m.get("toolCalls", [])) for m in assistants),
        "tool_failures": len(errors),
        "tool_error_details": [
            f"{m.get('toolName', 'tool')}: {str(m.get('content', ''))[:240]}"
            for m in errors],
        "cached_read": None,
        "cached_write": None,
    }


def original_usage(output: str) -> dict:
    steps = []
    tool_calls = tool_failures = 0
    tool_error_details = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        part = event.get("part") or {}
        kind = part.get("type") or event.get("type")
        if kind == "step-finish" or kind == "step_finish":
            tokens = part.get("tokens") or event.get("tokens") or {}
            if tokens:
                cache = tokens.get("cache") or {}
                steps.append({
                    "tokens": sum(int(tokens.get(k, 0) or 0) for k in ("input", "output"))
                    + sum(int(cache.get(k, 0) or 0) for k in ("read", "write")),
                    "read": int(cache.get("read", 0) or 0),
                    "write": int(cache.get("write", 0) or 0),
                })
        if kind == "tool":
            tool_calls += 1
            if (part.get("state") or {}).get("status") == "error":
                tool_failures += 1
                state = part["state"]
                tool_error_details.append(
                    f"{part.get('tool', 'tool')}: {str(state.get('error', ''))[:240]}")
    return {
        "tokens": sum(s["tokens"] for s in steps) if steps else None,
        "rounds": len(steps),
        "tool_calls": tool_calls,
        "tool_failures": tool_failures,
        "tool_error_details": tool_error_details,
        "cached_read": sum(s["read"] for s in steps) if steps else None,
        "cached_write": sum(s["write"] for s in steps) if steps else None,
    }


def run_process(cmd: list[str], cwd: Path, env: dict[str, str],
                seconds: int) -> tuple[int | None, str, str, float]:
    started = time.monotonic()
    try:
        result = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                                text=True, errors="replace", timeout=seconds)
        return result.returncode, result.stdout, result.stderr, time.monotonic() - started
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or b""
        stderr = error.stderr or b""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", "replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", "replace")
        return None, stdout, stderr + "\nProcess timed out", time.monotonic() - started


def verify(task: Task, workspace: Path) -> tuple[bool, str]:
    app_code, app_out, app_err, _ = run_process(
        ["dmd", "-Isource", "-i", "-run", "source/app.d"],
        workspace, os.environ.copy(), 45,
    )
    app_expected = APP_OUTPUT.get(task.name, "")
    if app_code != 0 or (app_expected and app_expected not in app_out):
        return False, ("App compile/run failed or output mismatched:\n" +
                       app_out + app_err).strip()[:600]
    (workspace / "verify.d").write_text(task.verifier, encoding="utf-8")
    code, out, err, _ = run_process(
        ["dmd", "-Isource", "-i", "-run", "verify.d"],
        workspace, os.environ.copy(), 45,
    )
    ok = code == 0 and task.expected in out
    return ok, (out + err).strip()[:600]


def safe_remove_state(state: Path, run_directory: Path) -> None:
    if state.exists():
        if (state.is_symlink() or state.resolve().parent != run_directory.resolve()
                or state.name != "state"):
            raise RuntimeError("Refusing to remove unexpected state path")
        shutil.rmtree(state)


def run_one(task: Task, harness: str, attempt: int, output: Path,
            driver: Path | None, opencode: str | None, key: str, timeout: int,
            config: Path) -> dict:
    run_directory = output / task.name / harness / f"run-{attempt:02d}"
    workspace = run_directory / "workspace"
    state = run_directory / "state"
    fixture(task, workspace)
    prompt_file = run_directory / "prompt.txt"
    prompt_file.write_text(task.prompt, encoding="utf-8")
    env = os.environ.copy()
    env["AURORA_BENCH_KEY"] = key
    if harness == "aurora":
        assert driver is not None
        cmd = [str(driver), str(workspace), str(state), str(prompt_file),
               MODEL, str(timeout)]
    else:
        assert opencode is not None
        env["OPENCODE_CONFIG"] = str(config)
        cmd = [opencode, "run", "--pure", "--auto", "--format", "json",
               "--model", "opencode-go/" + MODEL, "--dir", str(workspace),
               task.prompt]
    try:
        code, stdout, stderr, elapsed = run_process(cmd, workspace, env, timeout + 30)
        (run_directory / "stdout.txt").write_text(stdout, encoding="utf-8")
        (run_directory / "stderr.txt").write_text(stderr, encoding="utf-8")
        usage = aurora_usage(state) if harness == "aurora" else original_usage(stdout)
        usage["tool_error_details"] = [
            detail.replace(key, "[redacted]").replace(str(workspace),
                                                       "<workspace>")
            for detail in usage["tool_error_details"]]
        passed, verifier_output = verify(task, workspace)
        reason = "" if code == 0 and passed else (
            "timeout" if code is None else
            f"harness exit {code}" if code != 0 else "independent verifier failed")
        return {"task": task.name, "harness": harness, "attempt": attempt,
                "passed": not reason, "failure": reason, "seconds": round(elapsed, 2),
                "verifier": verifier_output, **usage}
    finally:
        safe_remove_state(state, run_directory)


def summary(records: list[dict], harness: str) -> dict:
    subset = [r for r in records if r["harness"] == harness]
    durations = [r["seconds"] for r in subset]
    tokens = [r["tokens"] for r in subset if r["tokens"] is not None]
    return {"runs": len(subset), "passed": sum(r["passed"] for r in subset),
            "median_seconds": statistics.median(durations) if durations else None,
            "median_tokens": statistics.median(tokens) if tokens else None,
            "unmetered": len(subset) - len(tokens),
            "tool_failures": sum(r["tool_failures"] for r in subset)}


def dashboard(data: dict, target: Path) -> None:
    records = data["runs"]
    cards = []
    for harness in ("aurora", "original"):
        stats = summary(records, harness)
        total_tokens = sum(r["tokens"] or 0 for r in records
                           if r["harness"] == harness)
        cards.append(
            f"<section class='card'><h2>{harness.title()}</h2>"
            f"<strong>{stats['passed']}/{stats['runs']} passed</strong>"
            f"<p>Median tokens: {stats['median_tokens'] if stats['median_tokens'] is not None else 'unknown'}"
            f" · Median time: {stats['median_seconds'] if stats['median_seconds'] is not None else 'unknown'}s"
            f" · Total measured tokens: {total_tokens}"
            f" · Tool failures: {stats['tool_failures']}"
            f" · Unmetered: {stats['unmetered']}</p></section>")
    comparison_rows = []
    for task in data["tasks"]:
        by_harness = {
            name: [r for r in records if r["task"] == task and r["harness"] == name]
            for name in ("aurora", "original")}
        values = {}
        for name, subset in by_harness.items():
            metered = [r["tokens"] for r in subset
                       if r["passed"] and r["tokens"] is not None]
            passed = [r for r in subset if r["passed"]]
            values[name] = (
                f"{len(passed)}/{len(subset)}",
                statistics.median(metered) if metered else None,
                statistics.median(r["seconds"] for r in passed) if passed else None,
            )
        aurora, original = values["aurora"], values["original"]
        savings = (f"{100 * (1 - aurora[1] / original[1]):.1f}%"
                   if aurora[1] is not None and original[1] else "—")
        cells = [task, aurora[0], original[0],
                 str(aurora[1]) if aurora[1] is not None else "—",
                 str(original[1]) if original[1] is not None else "—",
                 savings,
                 str(aurora[2]) if aurora[2] is not None else "—",
                 str(original[2]) if original[2] is not None else "—"]
        comparison_rows.append("<tr>" + "".join(
            f"<td>{html.escape(value)}</td>" for value in cells) + "</tr>")
    rows = []
    for record in records:
        status = "PASS" if record["passed"] else "FAIL"
        fields = [record["task"], record["harness"], str(record["attempt"]),
                  status, str(record["tokens"]) if record["tokens"] is not None else "unknown",
                  str(record["seconds"]), str(record["rounds"]),
                  str(record["tool_calls"]), str(record["tool_failures"]),
                  record["failure"] or "—"]
        cells = "".join(f"<td>{html.escape(value)}</td>" for value in fields)
        rows.append(f"<tr data-task='{html.escape(record['task'])}' "
                    f"data-harness='{record['harness']}' data-status='{status}'>{cells}</tr>")
    failures = [r for r in records if not r["passed"]]
    details = "".join(
        f"<details><summary>{html.escape(r['task'])} / {r['harness']} / "
        f"run {r['attempt']}: {html.escape(r['failure'])}</summary>"
        f"<pre>{html.escape(r['verifier'])}</pre></details>" for r in failures)
    tool_errors = [r for r in records if r["tool_failures"]]
    tool_details = "".join(
        f"<details><summary>{html.escape(r['task'])} / {r['harness']} / "
        f"run {r['attempt']}: {r['tool_failures']} recovered tool error(s)</summary>"
        f"<pre>{html.escape(chr(10).join(r.get('tool_error_details') or
               ['Details unavailable in this run']))}</pre></details>"
        for r in tool_errors)
    page = f"""<!doctype html><html lang="en"><meta charset="utf-8">
<title>Aurora harness benchmark</title><meta name="viewport" content="width=device-width">
<style>
body {{ font: 15px system-ui; max-width: 1200px; margin: 32px auto; padding: 0 20px;
 background: #101722; color: #e6edf7 }}
h1 {{ margin-bottom: 4px }} p, small {{ color: #aebdd0 }}
.cards {{ display: flex; gap: 16px; flex-wrap: wrap; margin: 24px 0 }}
.card {{ background: #1b2838; border: 1px solid #39506a; border-radius: 12px;
 padding: 16px; min-width: 280px }} .card h2 {{ margin-top: 0 }}
.card strong {{ font-size: 25px }}
select {{ background: #1b2838; color: #e6edf7; padding: 8px; margin: 4px;
 border: 1px solid #5a7290; border-radius: 6px }}
.scroll {{ overflow-x: auto }} table {{ border-collapse: collapse; width: 100%; margin: 14px 0 }}
th, td {{ border-bottom: 1px solid #344860; padding: 9px; text-align: left }}
th {{ color: #bcd4ee }} tr[data-status=FAIL] {{ background: #462b32 }}
details {{ border: 1px solid #5a3840; border-radius: 6px; padding: 10px; margin: 8px 0 }}
pre {{ overflow-x: auto; white-space: pre-wrap }}
</style><h1>Aurora vs original OpenCode</h1>
<p>Model: {html.escape(data['model'])} · OpenCode: {html.escape(data['opencode_version'])}
 · Created: {html.escape(data['created_at'])}</p>
<p>Provider total tokens sum input, output, and cached input. Missing usage is shown as unknown.
 Each run uses a fresh synthetic workspace and an independent verifier.</p>
<div class="cards">{''.join(cards)}</div>
<h2>Per-task comparison</h2>
<div class="scroll"><table><thead><tr><th>Task</th><th>Aurora pass</th>
<th>Original pass</th><th>Aurora median tokens</th><th>Original median tokens</th>
<th>Aurora token savings</th><th>Aurora median seconds</th>
<th>Original median seconds</th></tr></thead>
<tbody>{''.join(comparison_rows)}</tbody></table></div>
<h2>Individual runs</h2>
<label>Task <select id="task"><option value="">All</option>{''.join(f'<option>{html.escape(x)}</option>' for x in data['tasks'])}</select></label>
<label>Harness <select id="harness"><option value="">All</option><option>aurora</option><option>original</option></select></label>
<label>Status <select id="status"><option value="">All</option><option>PASS</option><option>FAIL</option></select></label>
<div class="scroll"><table><thead><tr><th>Task</th><th>Harness</th><th>Run</th><th>Result</th>
<th>Tokens</th><th>Seconds</th><th>Rounds</th><th>Calls</th><th>Tool errors</th><th>Failure</th>
</tr></thead><tbody id="runs">{''.join(rows)}</tbody></table></div>
<h2>Failures</h2>{details or '<p>No failures recorded.</p>'}
<h2>Tool errors, including recovered errors</h2>{tool_details or '<p>No tool errors recorded.</p>'}
<script>
const filters = ['task','harness','status'].map(id => document.getElementById(id));
function filter() {{ document.querySelectorAll('#runs tr').forEach(row => {{
 row.hidden = filters.some(input => input.value && row.dataset[input.id] !== input.value);
}}); }} filters.forEach(input => input.addEventListener('change', filter));
</script></html>"""
    target.write_text(page, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tasks", default=",".join(TASKS),
                        help="Comma-separated task IDs")
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--harness", choices=("both", "aurora", "original"),
                        default="both")
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--list", action="store_true", help="List tasks without running")
    parser.add_argument("--report", type=Path, help="Regenerate HTML from results.json")
    parser.add_argument("--reverify", type=Path,
                        help="Rerun independent checks on saved workspaces")
    parser.add_argument("--merge", nargs="+", type=Path,
                        help="Merge results.json files into one dashboard")
    args = parser.parse_args()
    if args.list:
        print("\n".join(TASKS))
        return 0
    if args.report:
        data = json.loads(args.report.read_text(encoding="utf-8"))
        dashboard(data, args.report.with_name("index.html"))
        print(args.report.with_name("index.html"))
        return 0
    if args.reverify:
        path = args.reverify.resolve()
        data = json.loads(path.read_text(encoding="utf-8"))
        roots = [path.parent] + [Path(source).parent
                                 for source in data.get("sources", [])]
        for record in data["runs"]:
            candidates = [root / record["task"] / record["harness"] /
                          f"run-{record['attempt']:02d}" / "workspace"
                          for root in roots]
            workspace = next((item for item in candidates if item.is_dir()), None)
            if workspace is None:
                parser.error(f"saved workspace missing for {record['task']}")
            passed, detail = verify(TASKS[record["task"]], workspace)
            if not passed:
                record["passed"] = False
                record["failure"] = "independent verifier failed"
            record["verifier"] = detail
        data["reverified_at"] = datetime.now(timezone.utc).isoformat()
        data["verifier_scope"] = "app compile/run plus hidden behavior assertions"
        path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        dashboard(data, path.with_name("index.html"))
        print("Verified", len(data["runs"]), "runs; failures:",
              sum(not r["passed"] for r in data["runs"]))
        return 0 if all(r["passed"] for r in data["runs"]) else 1
    if args.merge:
        inputs = [json.loads(path.read_text(encoding="utf-8")) for path in args.merge]
        if len({(item["model"], item["opencode_version"])
                for item in inputs}) != 1:
            parser.error("cannot merge different models or OpenCode versions")
        merged = dict(inputs[0])
        merged["created_at"] = datetime.now(timezone.utc).isoformat()
        merged["tasks"] = list(dict.fromkeys(
            task for item in inputs for task in item["tasks"]))
        merged["runs"] = [run for item in inputs for run in item["runs"]]
        merged["sources"] = [str(path.resolve()) for path in args.merge]
        output = (args.output or Path(tempfile.gettempdir()) /
                  "aurora-benchmark-runs" /
                  ("merged-" + datetime.now().strftime("%Y%m%d-%H%M%S"))).resolve()
        if output.exists():
            parser.error(f"output already exists: {output}")
        output.mkdir(parents=True)
        (output / "results.json").write_text(
            json.dumps(merged, indent=2), encoding="utf-8")
        dashboard(merged, output / "index.html")
        print("Dashboard:", output / "index.html")
        return 0
    selected = [name.strip() for name in args.tasks.split(",")]
    if not selected or any(name not in TASKS for name in selected):
        parser.error("unknown task; use --list")
    if args.repeats < 1 or args.timeout < 1:
        parser.error("repeats and timeout must be positive")
    harnesses = ("aurora", "original") if args.harness == "both" else (args.harness,)
    opencode = shutil.which("opencode") if "original" in harnesses else None
    if "original" in harnesses and not opencode:
        parser.error("installed original opencode CLI is missing")
    key, endpoint = configured_key()
    output = (args.output or Path(tempfile.gettempdir()) / "aurora-benchmark-runs" /
              datetime.now().strftime("%Y%m%d-%H%M%S")).resolve()
    if output.exists():
        parser.error(f"output already exists: {output}")
    output.mkdir(parents=True)
    config = output / "opencode-config.json"
    config.write_text(json.dumps({
        "$schema": "https://opencode.ai/config.json",
        "provider": {"opencode-go": {"options": {
            "apiKey": "{env:AURORA_BENCH_KEY}"}}},
        "permission": "allow",
    }), encoding="utf-8")
    driver = output / "benchmark_app_path.exe" if "aurora" in harnesses else None
    if driver:
        compile_aurora_driver(driver)
    version = subprocess.run([opencode, "--version"], capture_output=True,
                             text=True).stdout.strip() if opencode else "not run"
    data = {"created_at": datetime.now(timezone.utc).isoformat(),
            "model": MODEL, "provider_host": endpoint,
            "opencode_version": version, "tasks": selected,
            "repeats": args.repeats, "runs": []}
    print("Results:", output, flush=True)
    for attempt in range(1, args.repeats + 1):
        order = harnesses if attempt % 2 else tuple(reversed(harnesses))
        for name in selected:
            for harness in order:
                print(f"Running {name} / {harness} / {attempt}", flush=True)
                record = run_one(TASKS[name], harness, attempt, output,
                                 driver, opencode, key, args.timeout, config)
                data["runs"].append(record)
                (output / "results.json").write_text(
                    json.dumps(data, indent=2), encoding="utf-8")
                dashboard(data, output / "index.html")
                print(f"  {'PASS' if record['passed'] else 'FAIL'} "
                      f"{record['tokens']} tokens, {record['seconds']}s",
                      flush=True)
    print("Dashboard:", output / "index.html")
    return 0 if all(r["passed"] for r in data["runs"]) else 1


if __name__ == "__main__":
    sys.exit(main())
