"""Measure native color transfer independently of Aurora outline coverage.

All native calls are reference tooling; no calibration is installed at runtime.
"""
import importlib.util
import json
from pathlib import Path
import warnings

warnings.simplefilter("ignore", DeprecationWarning)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/native-text-progress"
spec = importlib.util.spec_from_file_location("native_reference", ROOT / "scripts/compare-font-rendering.py")
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)
records = []
for family, filename in (("segoe", "segoeui.ttf"), ("consolas", "consola.ttf")):
    native = reference.NativeReference("C:/Windows/Fonts/" + filename)
    try:
        for size in (13, 26):
            info = json.loads((BUILD / (family + "-natural-current") / f"{size}.json").read_text())
            # Separate glyphs to keep overlapping draw operations out of transfer analysis.
            for index, glyph in enumerate(info["glyphs"]):
                glyph["x"] = 8 + index * size * 2
            info["width"] = 16 + len(info["glyphs"]) * size * 2
            alpha = list(native.render(info, neutral=True, foreground=(255,)*3,
                                       background=(0,)*3).convert("L").getdata())
            for foreground in ((0,)*3, (240,)*3, (30, 80, 200)):
                for background in ((0,)*3, (24,)*3, (128,)*3, (255,)*3):
                    if foreground == background:
                        continue
                    target = native.render(info, foreground=foreground, background=background)
                    direction = [f-b for f,b in zip(foreground, background)]
                    norm = sum(d*d for d in direction)
                    bins = {}
                    incompatible = 0
                    for a, pixel in zip(alpha, target.getdata()):
                        if not 0 < a < 255:
                            continue
                        inferred = 255 * sum((p-b)*d for p,b,d in zip(pixel, background, direction)) / norm
                        bins.setdefault(a, []).append(inferred)
                        # Can any scalar A8 alpha reproduce all three native channels?
                        if not any(all(abs(round((f*v+b*(255-v))/255)-p) <= 1
                                       for p,f,b in zip(pixel, foreground, background))
                                   for v in range(256)):
                            incompatible += 1
                    records.append({"font": family, "size": size, "foreground": foreground,
                        "background": background, "scalar_alpha_incompatible_pixels_tolerance_1": incompatible,
                        "bins": {str(a): {"count": len(values), "minimum": min(values),
                            "maximum": max(values), "mean": sum(values)/len(values)}
                                 for a,values in sorted(bins.items())}})
    finally:
        native.close()
(HERE / "native-transfer.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
print("Native transfer cases:", len(records))
print("Cases incompatible with scalar A8 (one-level tolerance):",
      sum(r["scalar_alpha_incompatible_pixels_tolerance_1"] > 0 for r in records))
