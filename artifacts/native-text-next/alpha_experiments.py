"""Evaluate Microsoft's published grayscale alpha model without changing C.

The neutral reference is itself contrast-boosted for DirectWrite's legacy thin
families, including Courier New. It must not be treated as raw outline coverage.
Formula/coefficients: Microsoft Terminal, MIT license, dwrite_helpers.cpp/.hlsl.
"""
import json
from pathlib import Path
import warnings

from PIL import Image
from diagnose import ref, FONTS, SIZES, BUILD, HERE

warnings.simplefilter("ignore", DeprecationWarning)
GAMMA = (0.1469 * 65536 / 65025, -0.8911 * 256 / 255,
         1.4644 * 65536 / 65025, -0.3234 * 256 / 255)


def corrected(a, foreground, thin=False):
    intensity = foreground / 255
    contrast = max(0, min(1, 3 - 4 * intensity)) + (0.5 if thin else 0)
    a = a * (1 + contrast) / (1 + a * contrast)
    a += a * (1 - a) * ((GAMMA[0] * intensity + GAMMA[1]) * a +
                        GAMMA[2] * intensity + GAMMA[3])
    return max(0, min(1, a))


def main():
    records = []
    for family in FONTS:
        for size in SIZES:
            prefix = BUILD / "C" / f"{family}-{size}"
            # Black-on-white with contrast=0 exports the shared raw A8 samples.
            raw = Image.open(str(prefix) + "-light-raw.png").convert("L")
            for dark in (False, True):
                theme = "dark" if dark else "light"
                fg, bg = (240, 24) if dark else (0, 255)
                target = Image.open(str(prefix) + f"-{theme}-native.png").convert("RGB")
                baseline = Image.open(str(prefix) + f"-{theme}-aurora.png").convert("RGB")
                # Reference-transform audit isolates the model from Aurora geometry.
                neutral = Image.open(str(prefix) + "-light-neutral.png").convert("L")
                result = {"font": family, "size": size, "theme": theme,
                          "C_error": ref.grayscale_error(baseline, target, bg)["mean_absolute_error"]}
                for name, mask, thin in (("alpha", raw, False),
                                         ("alpha-thin", raw, family == "courier"),
                                         ("native-mask-alpha", neutral, False)):
                    lut = [round(bg + (fg - bg) * corrected((255-v)/255, fg, thin)) for v in range(256)]
                    actual = mask.point(lut).convert("RGB")
                    result[name + "_error"] = ref.grayscale_error(actual, target, bg)["mean_absolute_error"]
                    if name == "alpha-thin":
                        actual.save(str(prefix) + f"-{theme}-alpha.png")
                records.append(result)
    summary = {}
    for name in ("alpha", "alpha-thin", "native-mask-alpha"):
        summary[name] = {"improved": sum(r[name + "_error"] < r["C_error"] for r in records),
                         "regressed": sum(r[name + "_error"] > r["C_error"] for r in records),
                         "equal": sum(r[name + "_error"] == r["C_error"] for r in records),
                         "mean_error": sum(r[name + "_error"] for r in records) / len(records)}
    (HERE / "alpha-experiments.json").write_text(json.dumps({"default_changed": False,
        "gamma": 1.8, "grayscale_contrast": 1.0, "gamma_ratios": GAMMA,
        "reference": "https://github.com/microsoft/terminal/blob/main/src/renderer/atlas/dwrite_helpers.cpp",
        "summary": summary, "comparisons": records}, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    for row in sorted(records, key=lambda r: r["alpha-thin_error"] - r["C_error"], reverse=True)[:8]:
        print(row)


if __name__ == "__main__":
    main()
