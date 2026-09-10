"""Capture Aurora vs Windows DirectWrite using identical shaped glyph origins.

Windows-only reference tooling; none of these APIs enter Aurora's renderer.
Requires DMD and Pillow. Outputs unscaled PNG captures and comparison sheets.
"""
from __future__ import annotations

import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

from PIL import Image, ImageDraw


class GUID(C.Structure):
    _fields_ = [("data", C.c_ubyte * 16)]

    def __init__(self, value):
        super().__init__((C.c_ubyte * 16).from_buffer_copy(uuid.UUID(value).bytes_le))


class GlyphOffset(C.Structure):
    _fields_ = [("advance", C.c_float), ("ascender", C.c_float)]


class GlyphRun(C.Structure):
    _fields_ = [("face", C.c_void_p), ("em", C.c_float), ("count", W.UINT),
                ("indices", C.POINTER(W.WORD)), ("advances", C.POINTER(C.c_float)),
                ("offsets", C.POINTER(GlyphOffset)), ("sideways", W.BOOL),
                ("bidi", W.UINT)]


class Bitmap(C.Structure):
    _fields_ = [("type", W.LONG), ("width", W.LONG), ("height", W.LONG),
                ("stride", W.LONG), ("planes", W.WORD), ("bpp", W.WORD),
                ("bits", C.c_void_p)]


class BitmapHeader(C.Structure):
    _fields_ = [("size", W.DWORD), ("width", W.LONG), ("height", W.LONG),
                ("planes", W.WORD), ("bpp", W.WORD), ("compression", W.DWORD),
                ("image_size", W.DWORD), ("xppm", W.LONG), ("yppm", W.LONG),
                ("used", W.DWORD), ("important", W.DWORD)]


class DibSection(C.Structure):
    _fields_ = [("bitmap", Bitmap), ("header", BitmapHeader),
                ("masks", W.DWORD * 3), ("section", W.HANDLE), ("offset", W.DWORD)]


def method(obj, index, result, *args):
    table = C.cast(obj, C.POINTER(C.POINTER(C.c_void_p))).contents
    return C.WINFUNCTYPE(result, C.c_void_p, *args)(table[index])


def checked(hr):
    if hr < 0:
        raise OSError(f"DirectWrite HRESULT 0x{hr & 0xffffffff:08x}")


def grayscale_error(actual, reference, background):
    """MAE on the union of ink pixels; a diagnostic, not a readability score."""
    errors = [abs(a - b) for a, b in zip(actual.convert("L").getdata(),
                                        reference.convert("L").getdata())
              if a != background or b != background]
    return {"ink_pixels": len(errors), "mean_absolute_error": sum(errors) / max(1, len(errors))}


def exact_comparison(actual, reference):
    """Compare every RGB byte with zero tolerance, including the background."""
    if actual.size != reference.size:
        return {"exact": False, "actual_size": actual.size,
                "reference_size": reference.size, "reason": "image dimensions differ"}
    actual = actual.convert("RGB")
    reference = reference.convert("RGB")
    changed = 0
    maximum = 0
    first = None
    for index, (a, b) in enumerate(zip(actual.getdata(), reference.getdata())):
        if a != b:
            changed += 1
            maximum = max(maximum, *(abs(x - y) for x, y in zip(a, b)))
            if first is None:
                first = {"x": index % actual.width, "y": index // actual.width,
                         "aurora_rgb": a, "native_rgb": b}
    return {"exact": changed == 0, "different_pixels": changed,
            "total_pixels": actual.width * actual.height,
            "maximum_channel_error": maximum, "first_difference": first,
            "aurora_rgb_sha256": hashlib.sha256(actual.tobytes()).hexdigest(),
            "native_rgb_sha256": hashlib.sha256(reference.tobytes()).hexdigest()}


def difference_image(actual, reference):
    """Red marks every mismatching pixel; equal pixels are black."""
    result = Image.new("RGB", actual.size)
    result.putdata([(255, 0, 0) if a != b else (0, 0, 0)
                    for a, b in zip(actual.convert("RGB").getdata(), reference.convert("RGB").getdata())])
    return result


def shared_alpha_feasibility(light, dark):
    """Can one A8 mask reproduce both themes through Aurora's current blend?

    Use isolated glyphs: overlapping glyph draws can blend a pixel repeatedly.
    This is a compositor diagnostic, never a replacement for pixel equality.
    """
    if light.size != dark.size:
        raise ValueError("Paired captures must have identical dimensions")
    pairs = {(255 - alpha, (240 * alpha + 24 * (255 - alpha) + 127) // 255)
             for alpha in range(256)}
    impossible = 0
    first = None
    for index, (a, b) in enumerate(zip(light.convert("RGB").getdata(),
                                      dark.convert("RGB").getdata())):
        if len(set(a)) != 1 or len(set(b)) != 1 or (a[0], b[0]) not in pairs:
            impossible += 1
            if first is None:
                alpha = 255 - a[0]
                first = {"x": index % light.width, "y": index // light.width,
                         "native_light_rgb": a, "native_dark_rgb": b,
                         "alpha_required_by_light": alpha,
                         "predicted_dark_channel": (240 * alpha + 24 * (255 - alpha) + 127) // 255}
    return {"compatible": impossible == 0, "incompatible_pixels": impossible,
            "first_incompatible_pixel": first}


class NativeReference:
    def __init__(self, font):
        self.objects = []
        self.gdi = C.WinDLL("gdi32")
        self.gdi.GetCurrentObject.argtypes = [W.HDC, W.UINT]
        self.gdi.GetCurrentObject.restype = W.HANDLE
        self.gdi.GetObjectW.argtypes = [W.HANDLE, C.c_int, C.c_void_p]
        self.gdi.PatBlt.argtypes = [W.HDC, C.c_int, C.c_int, C.c_int, C.c_int, W.DWORD]
        self.gdi.CreateSolidBrush.argtypes = [W.DWORD]
        self.gdi.CreateSolidBrush.restype = W.HANDLE
        self.gdi.SelectObject.argtypes = [W.HDC, W.HANDLE]
        self.gdi.SelectObject.restype = W.HANDLE
        self.gdi.DeleteObject.argtypes = [W.HANDLE]
        dwrite = C.WinDLL("dwrite")
        dwrite.DWriteCreateFactory.argtypes = [C.c_int, C.POINTER(GUID), C.POINTER(C.c_void_p)]
        self.factory = C.c_void_p()
        checked(dwrite.DWriteCreateFactory(0, C.byref(GUID("b859ee5a-d838-4b5b-a2e8-1adc7d93db48")), C.byref(self.factory)))
        self.objects.append(self.factory)
        file = self.create(self.factory, 7, [W.LPCWSTR, C.c_void_p], str(Path(font).resolve()), None)
        supported, file_type, face_type, count = W.BOOL(), W.UINT(), W.UINT(), W.UINT()
        checked(method(file, 5, C.c_long, C.POINTER(W.BOOL), C.POINTER(W.UINT), C.POINTER(W.UINT), C.POINTER(W.UINT))(
            file, C.byref(supported), C.byref(file_type), C.byref(face_type), C.byref(count)))
        if not supported.value:
            raise ValueError("DirectWrite cannot load this font")
        files = (C.c_void_p * 1)(file.value)
        self.face = self.create(self.factory, 9, [W.UINT, W.UINT, C.POINTER(C.c_void_p), W.UINT, W.UINT], face_type.value, 1, files, 0, 0)
        self.params = self.create(self.factory, 10, [])
        self.interop = self.create(self.factory, 17, [])
        self.settings = {name: method(self.params, index, typ)(self.params)
                         for name, index, typ in [("gamma", 3, C.c_float), ("contrast", 4, C.c_float),
                         ("cleartype_level", 5, C.c_float), ("pixel_geometry", 6, W.UINT), ("mode", 7, W.UINT)]}
        params1 = self.create(self.params, 0, [C.POINTER(GUID)],
                              C.byref(GUID("94413cf4-a6fc-4248-8b50-6674348fcad3")))
        self.settings["grayscale_contrast"] = method(params1, 8, C.c_float)(params1)
        factory1 = self.create(self.factory, 0, [C.POINTER(GUID)],
                               C.byref(GUID("30572f99-dac6-41db-a16e-0486307e606a")))
        # Diagnostic only: the acceptance reference always retains monitor settings.
        self.neutral_params = self.create(factory1, 25,
            [C.c_float, C.c_float, C.c_float, C.c_float, W.UINT, W.UINT],
            1.0, 0.0, 0.0, self.settings["cleartype_level"],
            self.settings["pixel_geometry"], self.settings["mode"])

    def create(self, obj, index, types, *args):
        out = C.c_void_p()
        checked(method(obj, index, C.c_long, *types, C.POINTER(C.c_void_p))(obj, *args, C.byref(out)))
        self.objects.append(out)
        return out

    def render(self, info, dark=False, cleartype=False, neutral=False):
        w, h = info["width"], info["height"]
        target = self.create(self.interop, 7, [W.HDC, W.UINT, W.UINT], None, w, h)
        target1 = self.create(target, 0, [C.POINTER(GUID)], C.byref(GUID("791e8298-3ef3-4230-9880-c9bdecc42064")))
        checked(method(target1, 12, C.c_long, W.UINT)(target1, 0 if cleartype else 1))
        checked(method(target, 6, C.c_long, C.c_float)(target, 1.0))
        dc = method(target, 4, W.HDC)(target)
        brush = self.gdi.CreateSolidBrush(0x181818 if dark else 0xffffff)
        previous = self.gdi.SelectObject(dc, brush)
        self.gdi.PatBlt(dc, 0, 0, w, h, 0x00F00021)  # PATCOPY
        self.gdi.SelectObject(dc, previous)
        self.gdi.DeleteObject(brush)
        draw = method(target, 3, C.c_long, C.c_float, C.c_float, W.UINT,
                      C.POINTER(GlyphRun), C.c_void_p, W.DWORD, C.c_void_p)
        for glyph in info["glyphs"]:
            indices = (W.WORD * 1)(glyph["id"])
            advances = (C.c_float * 1)(0)
            offsets = (GlyphOffset * 1)()
            run = GlyphRun(self.face, info["pixel_size"], 1, indices, advances, offsets, 0, 0)
            checked(draw(target, glyph["x"], glyph["y"], 0, C.byref(run),
                         self.neutral_params if neutral else self.params,
                         0xf0f0f0 if dark else 0, None))
        self.gdi.GdiFlush()
        section = DibSection()
        bitmap = self.gdi.GetCurrentObject(dc, 7)
        if self.gdi.GetObjectW(bitmap, C.sizeof(section), C.byref(section)) != C.sizeof(section):
            raise OSError("Native reference is not a DIB section")
        assert section.bitmap.bpp == 32 and section.bitmap.bits
        data = C.string_at(section.bitmap.bits, section.bitmap.stride * h)
        # DirectWrite guarantees top-down storage; GetObject can nevertheless
        # report a positive biHeight on this Windows version.
        result = Image.frombytes("RGB", (w, h), data, "raw", "BGRX", section.bitmap.stride, 1)
        for obj in (target1, target):
            method(obj, 2, W.ULONG)(obj)
            self.objects.remove(obj)
        return result

    def close(self):
        for obj in reversed(self.objects):
            method(obj, 2, W.ULONG)(obj)
        self.objects.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", default="C:/Windows/Fonts/segoeui.ttf")
    parser.add_argument("--out", type=Path, default=Path("build-validation/font-quality/current"))
    parser.add_argument("--sizes", nargs="+", type=int, default=[11, 13, 17, 21, 26, 34])
    parser.add_argument("--text", default="Hamburgefontsiv 0123456789 = + - _ Il1 O0 | AV fi")
    parser.add_argument("--mode", choices=["sharp", "smooth"], default="sharp")
    parser.add_argument("--audit-shared-alpha", action="store_true",
                        help="Test whether one A8 mask can match both native themes; requires a single glyph")
    parser.add_argument("--audit-neutral", action="store_true",
                        help="Also capture native gamma=1/contrast=0 output to isolate coverage; never changes acceptance")
    parser.add_argument("--require-exact", action="store_true",
                        help="Exit with status 1 unless every pixel equals native DirectWrite grayscale")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("The native reference requires Windows")
    root = Path(__file__).resolve().parents[1]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    exe = out / "font-quality.exe"
    subprocess.run(["dmd", "-i", "-O", "-version=AuroraHeadless", "-I" + str(root / "vendor/aurora-d-0.4.5/source"),
                    "-of=" + str(exe), "-od=" + str(out), str(root / "vendor/aurora-d-0.4.5/tests/font_quality.d")], check=True)
    native = NativeReference(args.font)
    sheets = []
    measurements = []
    parity = []
    alpha_audit = []
    neutral_audit = []
    try:
        for size in args.sizes:
            prefix = out / str(size)
            env = os.environ.copy()
            env["AURORA_TEST_SMOOTH"] = "1" if args.mode == "smooth" else "0"
            subprocess.run([str(exe), str(Path(args.font).resolve()), str(size), str(prefix), args.text], env=env, check=True)
            info = json.loads(prefix.with_suffix(".json").read_text(encoding="utf-8"))
            if args.audit_shared_alpha and len(info["glyphs"]) != 1:
                raise ValueError("--audit-shared-alpha requires exactly one shaped glyph (for example --text H)")
            native_themes = []
            neutral_themes = []
            for dark in (False, True):
                theme = "dark" if dark else "light"
                aurora = Image.open(out / f"{size}-{theme}.ppm").convert("RGB")
                aurora.save(out / f"{size}-{theme}-aurora.png")
                gray = native.render(info, dark)
                native_themes.append(gray)
                if args.audit_neutral:
                    neutral = native.render(info, dark, neutral=True)
                    if not exact_comparison(neutral, native.render(info, dark, neutral=True))["exact"]:
                        raise RuntimeError("Neutral reference changed between identical draws")
                    neutral.save(out / f"{size}-{theme}-native-neutral.png")
                    neutral_themes.append(neutral)
                    neutral_audit.append({"size": size, "theme": theme,
                        "aurora_vs_neutral": exact_comparison(aurora, neutral),
                        "error": grayscale_error(aurora, neutral, 24 if dark else 255)})
                if not exact_comparison(gray, native.render(info, dark))["exact"]:
                    raise RuntimeError("Native reference changed between identical draws")
                clear = native.render(info, dark, True)
                gray.save(out / f"{size}-{theme}-native-gray.png")
                clear.save(out / f"{size}-{theme}-native-cleartype.png")
                measurements.append({"size": size, "theme": theme,
                                     **grayscale_error(aurora, gray, 24 if dark else 255)})
                parity.append({"size": size, "theme": theme, **exact_comparison(aurora, gray)})
                difference_image(aurora, gray).save(out / f"{size}-{theme}-difference.png")
                rows = [("Aurora", aurora)]
                if args.audit_neutral:
                    rows.append(("Native neutral", neutral))
                rows.extend([("Native grayscale", gray), ("Native ClearType", clear)])
                sheet = Image.new("RGB", (max(600, info["width"] + 160), (info["height"] + 6) * len(rows) + 26), "#dedede")
                draw = ImageDraw.Draw(sheet)
                draw.text((8, 6), f"{Path(args.font).stem} {size}px / {theme} / {args.mode} / identical shaped positions / actual pixels", fill="black")
                for row, (label, img) in enumerate(rows):
                    y = 26 + row * (info["height"] + 6)
                    draw.text((8, y + 8), label, fill="black")
                    sheet.paste(img, (155, y))
                sheet.save(out / f"{size}-{theme}-comparison.png")
                sheets.append(sheet)
            if args.audit_shared_alpha:
                alpha_audit.append({"size": size, **shared_alpha_feasibility(*native_themes)})
                if args.audit_neutral:
                    alpha_audit[-1]["neutral_reference"] = shared_alpha_feasibility(*neutral_themes)
        width = max(s.width for s in sheets)
        montage = Image.new("RGB", (width, sum(s.height + 12 for s in sheets)), "#bdbdbd")
        y = 0
        for sheet in sheets:
            montage.paste(sheet, (0, y))
            y += sheet.height + 12
        montage.save(out / "comparison.png")
        manifest = {"font": str(Path(args.font).resolve()), "font_sha256": hashlib.sha256(Path(args.font).read_bytes()).hexdigest(),
                    "native": native.settings, "sizes": args.sizes, "text": args.text, "aurora_mode": args.mode,
                    "aurora_experimental_hinting": os.environ.get("AURORA_HINTING", "0") in ("1", "natural"),
                    "aurora_hinting_mode": os.environ.get("AURORA_HINTING", "0"),
                    "grayscale_comparison": measurements,
                    "exact_grayscale_match": all(case["exact"] for case in parity),
                    "pixel_equality": parity,
                    "shared_alpha_audit": alpha_audit,
                    "neutral_reference_audit": neutral_audit,
                    "note": "DirectWrite natural measuring mode, same Aurora glyph IDs/origins; compares rasterization, not shaping."}
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    finally:
        native.close()
    print(out / "comparison.png")
    failed = sum(not case["exact"] for case in parity)
    print(f"Pixel equality: {len(parity) - failed}/{len(parity)} exact cases; "
          f"{sum(case.get('different_pixels', 0) for case in parity)} differing pixels")
    if args.require_exact and failed:
        print("FAIL: native grayscale parity has not been achieved (zero tolerance)")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
