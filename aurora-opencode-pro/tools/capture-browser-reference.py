"""Capture independent, frozen local HTML references in an isolated browser profile.

Uses an explicitly selected installed Chromium/Edge executable. No provider API,
user browser profile, live website or browser-engine source is changed.
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from datetime import datetime, timezone


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", required=True, type=Path)
    parser.add_argument("--fixtures", type=Path,
                        default=Path(__file__).resolve().parents[1] / "tests/browser-fixtures")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--verify", action="store_true", help="Build and run the current engine against the frozen reference corpus")
    parser.add_argument("--verify-existing", action="store_true", help="Verify against the established immutable references without recapturing")
    args = parser.parse_args()
    browser, fixtures, output = args.browser.resolve(), args.fixtures.resolve(), args.output.resolve()
    if not browser.is_file() or not 100 <= args.width <= 4096 or not 100 <= args.height <= 4096:
        parser.error("Select an installed browser and viewport dimensions between 100 and 4096")
    output.mkdir(parents=True, exist_ok=True)
    pages = sorted(fixtures.glob("*.html"))
    if not pages:
        parser.error("No frozen HTML fixtures found")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
        functools.partial(Handler, directory=str(fixtures)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    manifest = {"createdAtUtc": datetime.now(timezone.utc).isoformat(),
                "browser": str(browser), "browserSha256": sha(browser),
                "viewport": {"width": args.width, "height": args.height, "deviceScaleFactor": 1},
                "cases": []}
    if args.verify_existing:
        manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
        for case in manifest["cases"]:
            if sha(Path(case["html"])) != case["htmlSha256"] or sha(Path(case["reference"])) != case["referenceSha256"]:
                raise RuntimeError("Frozen fixture or reference changed; capture a new corpus in another output directory")
        args.verify = True
    try:
        for page in ([] if args.verify_existing else pages):
            if page.stem == "interaction":
                continue  # Interaction expectations are explicit DOM assertions.
            reference = output / (page.stem + ".png")
            if reference.exists():
                raise RuntimeError("Refusing to overwrite an established reference: " + str(reference))
            profile = tempfile.mkdtemp(prefix="aurora-reference-profile-")
            command = [str(browser), "--headless=new", "--no-first-run",
                       "--no-default-browser-check", "--disable-extensions", "--hide-scrollbars",
                       "--disable-background-networking", "--disable-component-update", "--disable-sync",
                       "--force-device-scale-factor=1", f"--window-size={args.width},{args.height}",
                       "--virtual-time-budget=1000", "--user-data-dir=" + profile,
                       "--screenshot=" + str(reference),
                       f"http://127.0.0.1:{server.server_port}/{page.name}"]
            result = subprocess.run(command, capture_output=True, timeout=45,
                                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            if result.returncode or not reference.is_file():
                raise RuntimeError("Reference capture failed: " + result.stderr.decode(errors="replace")[-1200:])
            manifest["cases"].append({"name": page.stem, "html": str(page),
                "htmlSha256": sha(page), "reference": str(reference),
                "referenceSha256": sha(reference),
                "referenceSource": "Installed reference browser " + str(browser) +
                    "; frozen HTML " + sha(page) + "; viewport " + str(manifest["viewport"])})
    finally:
        server.shutdown()
        server.server_close()
    receipt = output / "manifest.json"
    receipt.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    package = Path(__file__).resolve().parents[1]
    repo = package.parent
    probe = output / "browser-probe.exe"
    checks = output / "engine-checks.exe"
    common = ["-i", "-I" + str(repo / "aurora-web/source"),
              "-I" + str(repo / "vendor/aurora-d-0.4.5/source")]
    libraries = ["user32.lib", "gdi32.lib", "shell32.lib", "ws2_32.lib", "advapi32.lib", "ole32.lib"]

    def command(program, args):
        return {"program": str(program), "args": [str(x) for x in args], "workdir": str(output), "timeout": 120000}

    steps = [
        {"kind": "compile", "command": command("dmd", common + ["-of=" + str(probe), str(package / "tools/browser-probe.d")] + libraries)},
        {"kind": "compile", "command": command("dmd", common + ["-unittest", "-main", "-of=" + str(checks), str(package / "tools/browser-engine-check.d")] + libraries)},
        {"kind": "tests", "command": command(checks, [])},
    ]
    for case in manifest["cases"]:
        actual = output / (case["name"] + ".actual.ppm")
        steps += [{"kind": "prepare", "command": command(probe, [case["html"], args.width, args.height, actual])},
                  {"kind": "render", "reference": case["reference"], "actual": str(actual),
                   "referenceSource": case["referenceSource"]}]
    steps.append({"kind": "interaction", "command": command(probe, ["--interaction", fixtures / "interaction.html"])})
    recipe = output / "verify.json"
    recipe.write_text(json.dumps({"inputs": [str(repo / "aurora-web/source"),
        str(repo / "vendor/aurora-d-0.4.5/source"), str(fixtures),
        str(package / "tools/browser-probe.d"), str(package / "tools/browser-engine-check.d")],
        "steps": steps}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(receipt), "recipe": str(recipe), "cases": len(manifest["cases"])}), flush=True)
    if args.verify:
        runner = output / "verification-runner.exe"
        subprocess.run(["dmd", "-i", "-I" + str(package / "source"), "-I" + str(package / "shared"),
            "-I" + str(repo / "aurora-opencode-core/source"), "-I" + str(repo / "vendor/aurora-d-0.4.5/source"),
            "-J" + str(package / "assets"),
            "-of=" + str(runner), str(package / "tests/verification_recipe_runner.d"),
            "user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib", "winmm.lib"], cwd=output, check=True, timeout=120)
        result = subprocess.run([str(runner), str(repo), str(recipe), str(output / "comparison.json")], cwd=output, timeout=300)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
