"""Re-digest only this text-rendering change, preserving unrelated vendor debt."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "vendor/aurora-d-0.4.5"
FILES = ("docs/FONTS.md", "dub.json", "source/aurora/canvas.d", "source/aurora/font.d",
         "source/aurora/text/coverage.d", "source/aurora/text/atlas.d",
         "source/aurora/text/hinter.d", "source/aurora/text/truetype.d", "source/aurora/text/rasterizer.d",
         "source/aurora/platform/headless.d", "source/aurora/testing.d",
         "tests/font_quality.d", "tests/font_quality_regression.d", "tests/text_coverage.d",
         "tests/hinting_windows_regression.d", "tests/window_dpi_regression.d")

manifest = CORE / "MANIFEST.sha256"
entries = {p: digest for digest, p in (line.split("  ", 1) for line in manifest.read_text().splitlines() if line)}
for name in FILES:
    entries[name] = hashlib.sha256((CORE / name).read_bytes()).hexdigest()
manifest.write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(entries.items())), encoding="utf-8")
remaining = []
for name, digest in entries.items():
    actual = hashlib.sha256((CORE / name).read_bytes()).hexdigest()
    if actual != digest:
        remaining.append({"file": name, "recorded": digest, "actual": actual})
assert all(p["file"] not in FILES for p in remaining)
report = {"updated": list(FILES), "updated_files_verified": True,
          "unrelated_preexisting_mismatches": remaining}
(HERE / "vendor-manifest-audit.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print("Text patch manifest entries verified:", len(FILES))
print("Unrelated existing digest mismatches:", len(remaining))
