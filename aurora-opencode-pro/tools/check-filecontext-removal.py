"""Compile Aurora after removing Smart File Context, without editing the checkout."""
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent


def strip_regions(text):
    out, inside, count = [], False, 0
    for line in text.splitlines(keepends=True):
        if re.search(r"// >>> filecontext:begin\b", line):
            assert not inside, "Nested removal region"
            inside, count = True, count + 1
        elif re.search(r"// <<< filecontext:end\b", line):
            assert inside, "Unmatched removal region"
            inside = False
        elif not inside:
            out.append(line)
    assert not inside and count, "Missing or unclosed removal regions"
    result = "".join(out)
    assert not re.search(r"FileContext|fileContext|smartFileContext", result), "Unmarked feature dependency"
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="aurora-no-filecontext-") as tmp:
        root = Path(tmp)
        for name in ("aurora-opencode-pro/source", "aurora-opencode-pro/shared",
                     "aurora-opencode-pro/assets", "aurora-opencode-core/source",
                     "vendor/aurora-d-0.4.5/source"):
            shutil.copytree(REPO / name, root / name)
        (root / "aurora-opencode-pro/source/auroraopencode/filecontext.d").unlink()
        for name in ("aurora-opencode-pro/source/auroraopencode/appui.d",
                     "aurora-opencode-core/source/auroraopencode/core.d"):
            path = root / name
            path.write_text(strip_regions(path.read_text(encoding="utf-8")), encoding="utf-8")
        args = ["dmd", "-i", "-o-", "-c", "-verrors=20"]
        args += ["-I" + str(root / name) for name in
                 ("aurora-opencode-pro/source", "aurora-opencode-pro/shared",
                  "aurora-opencode-core/source", "vendor/aurora-d-0.4.5/source")]
        args += ["-J" + str(root / "aurora-opencode-pro/assets"),
                 str(root / "aurora-opencode-pro/source/app.d")]
        result = subprocess.run(args, cwd=root, timeout=120)
        if result.returncode:
            return result.returncode
    print("PASS Smart File Context can be removed by deleting its module and marked regions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
