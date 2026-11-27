"""Opt-in real-provider autonomy, grounding, scope and efficiency task matrix."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import time

from task_matrix_cases import all_cases
from task_matrix_runner import read_json, run_case

PACKAGE = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--exe", type=Path, default=PACKAGE / "aurora-opencode-pro.exe")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cases", nargs="*")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    assert 1 <= args.jobs <= 3 and args.repeats >= 1
    cases = all_cases()
    if args.cases:
        assert set(args.cases) <= {c.name for c in cases}, "Unknown case name"
        cases = [c for c in cases if c.name in args.cases]
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    executable = args.exe.resolve(strict=True)
    saved = read_json(Path(os.environ["APPDATA"]) / "Aurora OpenCode/settings.json")
    assert saved and saved.get("apiKey"), "Configure Aurora's real provider first"
    started = time.monotonic()
    result = {"status": "running", "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
              "model": saved["model"], "thinking": saved.get("thinking", True), "parallelCases": args.jobs,
              "externalSteering": False, "scenarios": [], "sourceFiles": {
                  p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                  [Path(__file__), PACKAGE / "benchmarks/task_matrix_runner.py",
                   PACKAGE / "benchmarks/task_matrix_cases.py", PACKAGE / "benchmarks/task_matrix_project.py"]}}
    print("MATRIX", len(cases) * args.repeats, "runs", "MODEL", saved["model"], "ARTIFACTS", root, flush=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_case, case, executable, saved, root / (case.name + "-" + str(repeat)), repeat): (case.name, repeat)
                   for repeat in range(1, args.repeats + 1) for case in cases}
        for future in as_completed(futures):
            try:
                row = future.result()
            except Exception as error:
                name, repeat = futures[future]
                row = {"name": name, "repeat": repeat, "status": "harness_error", "errors": [str(error)]}
            result["scenarios"].append(row)
            result["scenarios"].sort(key=lambda r: (r["name"], r["repeat"]))
            (root / "matrix.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    result.update(seconds=round(time.monotonic() - started, 3),
                  resolved=sum(r["status"] == "passed" for r in result["scenarios"]),
                  efficiencyExceeded=[r["name"] for r in result["scenarios"] if r.get("efficiencyExceeded")],
                  userInputRequests=sum(r.get("userInputRequests", 0) for r in result["scenarios"]))
    result["status"] = "passed" if result["resolved"] == len(cases) * args.repeats else "failed"
    result["qualityStatus"] = "passed" if result["status"] == "passed" and not result["efficiencyExceeded"] else "needs_improvement"
    (root / "matrix.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print("MATRIX RESULT", result["status"], result["resolved"], "/", len(cases) * args.repeats,
          "EFFICIENCY EXCEEDED", result["efficiencyExceeded"], "ARTIFACTS", root, flush=True)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
