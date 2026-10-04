"""Compare Pro's UI tick against Git HEAD using isolated local fixtures."""
from pathlib import Path
import json
import re
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "aurora-opencode-pro"


def main():
    baseline = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    report = {"baseline_commit": baseline, "conversations": 100, "selected_messages": 1502,
              "scope": "Root/widget UI tick only; excludes painting, provider, and persistence",
              "trials": 5, "ticks_per_trial": 300}
    with tempfile.TemporaryDirectory(prefix="aurora-pro-ticks-") as directory:
        scratch = Path(directory)
        prior = scratch / "prior"
        for source in ["aurora-opencode-pro/source/auroraopencode/appui.d",
                       "aurora-opencode-pro/source/auroraopencode/tools.d",
                       "aurora-opencode-core/source/auroraopencode/opencode_client.d"]:
            target = prior / Path(source).relative_to(Path(source).parts[0] + "/source")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(subprocess.check_output(["git", "show", baseline + ":" + source], cwd=ROOT))
        for name in ["before", "after"]:
            executable = scratch / (name + ".exe")
            includes = ([prior] if name == "before" else []) + [PACKAGE / "source", PACKAGE / "shared",
                        ROOT / "aurora-opencode-core/source", ROOT / "vendor/aurora-d-0.4.5/source"]
            command = [shutil.which("dmd") or "dmd", "-i", "-O", "-version=AuroraHeadless"]
            command += ["-I" + str(path) for path in includes]
            command += [str(PACKAGE / "benchmarks/chat_tick.d"), "user32.lib", "gdi32.lib", "shell32.lib",
                        "wininet.lib", "winmm.lib", "-of=" + str(executable)]
            subprocess.run(command, cwd=scratch, check=True, timeout=180)
            result = subprocess.run([str(executable), str(scratch / (name + "-state"))],
                                    cwd=scratch, check=True, capture_output=True, text=True, timeout=120)
            medians = [int(value) for value in re.findall(r"tick_median_us=(\d+)", result.stdout)]
            p95 = [int(value) for value in re.findall(r"tick_p95_us=(\d+)", result.stdout)]
            assert len(medians) == len(p95) == 5, result.stdout
            report[name] = {"median_us": statistics.median(medians), "p95_us": statistics.median(p95),
                            "median_trials_us": medians, "p95_trials_us": p95}
    report["speedup"] = report["before"]["median_us"] / max(1, report["after"]["median_us"])
    target = ROOT / "artifacts/opencode-pro-flow-review/chat-ticks.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
