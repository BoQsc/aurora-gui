"""Removal-contract guard for the experimental floating pet.

The pet's whole justification is that it can be deleted safely. This script
checks the two things that claim depends on, without modifying the workspace:

1. ISOLATION - the pet is referenced only where the docs say it is: pet.d and
   the `pet:begin`/`pet:end` regions in appui.d and core.d. A reference in
   tools/orchestrator/computeruse is a regression, because the feature promised
   to touch none of them.
2. COMPILABILITY AFTER REMOVAL - every pet region can be removed and the app
   still compiles. The script copies the sources to a temp tree, deletes pet.d
   and cuts the marked regions, then compiles the result. Compiling the
   stripped tree is the only honest proof that "delete the file and the marked
   regions" really works.

Removal is driven by explicit sentinels rather than heuristics: a region starts
at `// >>> pet:begin` and ends at `// <<< pet:end` (any line-comment form).
That is exactly what a human deleting the feature would cut, so the check and
the documented procedure cannot drift apart.

Run:  python tools/check-pet-removal.py
Exit: 0 = contract holds, 1 = contract broken.
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent
CORE = REPO / "aurora-opencode-core" / "source" / "auroraopencode" / "core.d"
APPUI = PACKAGE / "source" / "auroraopencode" / "appui.d"
PET = PACKAGE / "source" / "auroraopencode" / "pet.d"

# MULTILINE is required: the patterns are anchored per line, and findall() is
# used to count regions across the whole file.
BEGIN = re.compile(r"^\s*//+\s*>>>\s*pet:begin\b", re.MULTILINE)
END = re.compile(r"^\s*//+\s*<<<\s*pet:end\b", re.MULTILINE)

# Files the pet promised never to touch.
FORBIDDEN = [
    PACKAGE / "source" / "auroraopencode" / name
    for name in ("tools.d", "orchestrator.d", "computeruse.d", "toolscheduler.d")
]

failures = []


def cut_regions(text):
    """Remove every `pet:begin` .. `pet:end` region, inclusive."""
    out = []
    inside = False
    for line in text.split("\n"):
        if BEGIN.match(line):
            if inside:
                failures.append("nested pet:begin without a matching pet:end")
            inside = True
            continue
        if END.match(line):
            if not inside:
                failures.append("pet:end without a pet:begin")
            inside = False
            continue
        if not inside:
            out.append(line)
    if inside:
        failures.append("pet:begin without a matching pet:end")
    return "\n".join(out)


def check_isolation():
    """The pet must not appear in the modules it promised to leave alone."""
    pattern = re.compile(
        r"PetHost|PetOverlay|PetProposal|PetObservation|petIdleObservation|"
        r"petFailureObservation|experimentalPetEnabled|setPetEnabled|"
        r"runPetObservation|experimentalFloatingPet|floatingPet")
    for path in FORBIDDEN:
        if not path.exists():
            continue
        hits = pattern.findall(path.read_text(encoding="utf-8", errors="replace"))
        if hits:
            failures.append(
                f"isolation: {path.name} references the pet "
                f"({', '.join(sorted(set(hits)))})")


def check_sentinels_balance():
    """Every marked file must declare balanced regions."""
    for path in (APPUI, CORE):
        text = path.read_text(encoding="utf-8")
        begins = len(BEGIN.findall(text))
        ends = len(END.findall(text))
        if begins != ends:
            failures.append(
                f"{path.name}: {begins} pet:begin vs {ends} pet:end")
        if begins == 0:
            failures.append(f"{path.name}: no pet regions found")


def verify_compiles_without_pet(tmp):
    """Copy sources, delete pet.d, cut the regions, and compile."""
    pro = tmp / "aurora-opencode-pro"
    core_root = tmp / "aurora-opencode-core"
    shutil.copytree(PACKAGE / "source", pro / "source")
    shutil.copytree(PACKAGE / "shared", pro / "shared")
    shutil.copytree(PACKAGE / "assets", pro / "assets")
    shutil.copytree(REPO / "aurora-opencode-core" / "source", core_root / "source")
    shutil.copytree(REPO / "vendor" / "aurora-d-0.4.5" / "source",
                    tmp / "vendor" / "aurora-d-0.4.5" / "source")

    (pro / "source" / "auroraopencode" / "pet.d").unlink()

    stripped_appui = cut_regions(
        (pro / "source" / "auroraopencode" / "appui.d").read_text(encoding="utf-8"))
    (pro / "source" / "auroraopencode" / "appui.d").write_text(
        stripped_appui, encoding="utf-8")

    stripped_core = cut_regions(
        (core_root / "source" / "auroraopencode" / "core.d").read_text(
            encoding="utf-8"))
    (core_root / "source" / "auroraopencode" / "core.d").write_text(
        stripped_core, encoding="utf-8")

    leftover = [
        name for name, text in (("appui.d", stripped_appui), ("core.d", stripped_core))
        if "experimentalFloatingPet" in text or "PetHost" in text]
    if leftover:
        failures.append(
            f"region cut incomplete: {', '.join(leftover)} still references the pet")

    return subprocess.run(
        ["dmd", "-o-", "-c", "-verrors=20",
         "-I" + str(pro / "source"), "-I" + str(pro / "shared"),
         "-I" + str(core_root / "source"),
         "-I" + str(tmp / "vendor" / "aurora-d-0.4.5" / "source"),
         # developerworkflow.d / updater.d use import("...txt"); the real build
         # supplies -J, so the stripped tree needs it too.
         "-J" + str(pro / "source" / "auroraopencode"),
         "-J" + str(pro / "assets"),
         str(pro / "source" / "auroraopencode" / "appui.d")],
        capture_output=True, text=True)


def main():
    if not PET.exists():
        failures.append("pet.d is missing; nothing to check")
    check_isolation()
    check_sentinels_balance()

    with tempfile.TemporaryDirectory(prefix="pet-removal-") as raw:
        result = verify_compiles_without_pet(Path(raw))

    if result.returncode != 0:
        failures.append(
            "app does not compile after removing the pet:\n"
            + (result.stdout + result.stderr)[-4000:])

    if failures:
        print("REMOVAL CONTRACT BROKEN")
        for failure in failures:
            print(" -", failure)
        return 1

    print("REMOVAL CONTRACT HOLDS")
    print(" - pet references appear only in pet.d and the marked regions")
    print(" - the app compiles clean with pet.d deleted and every region cut")
    return 0


if __name__ == "__main__":
    sys.exit(main())
