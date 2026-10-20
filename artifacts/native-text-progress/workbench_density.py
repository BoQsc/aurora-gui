"""Measure the existing workbench ink fixture at controlled software DPI."""
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "vendor/aurora-d-0.4.5"
BUILD = ROOT / "build-validation/native-text-progress/workbench-density"
BUILD.mkdir(parents=True, exist_ok=True)
source = BUILD / "fixture.d"
source.write_text('''module fixture;
import aurora;
import experiment.aurorahost.scene : loadScene, createWindow, NodeRegistry;
import experiment.aurorahost.host_editor : HostTextEditor;
import std.conv : to;
import std.file : write;
import std.json : JSONValue;
int main(string[] args) {
    auto scene = loadScene("experiments/aurora-host/samples/workbench.scene.json");
    auto registry = new NodeRegistry();
    auto window = createWindow(scene, registry);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(scene.window.width, scene.window.height), DisplayScale.fromDpi(args[1].to!uint));
    auto editor = cast(HostTextEditor) registry.widget("editor");
    editor.setSelection(editor.textView.length, editor.textView.length);
    driver.paint();
    const origin = editor.globalOrigin();
    JSONValue info;
    info["editor_x"] = origin.x; info["editor_y"] = origin.y;
    info["logical_width"] = scene.window.width;
    write(args[2] ~ ".json", info.toPrettyString());
    window.saveScreenshot(args[2] ~ ".ppm");
    window.close();
    return 0;
}
''', encoding="utf-8")
includes = [CORE / "source", ROOT / "vendor/aurora-standard/source",
            ROOT / "experiments/aurora-host/source", ROOT / "experiments/aurora-host/generated"]
exe = BUILD / "fixture.exe"
subprocess.run(["dmd", "-i", "-O", "-version=AuroraHeadless", *["-I"+str(p) for p in includes],
                "-od="+str(BUILD), "-of="+str(exe), str(source), "user32.lib", "gdi32.lib"], check=True)
sys.path.insert(0, str(ROOT / "experiments/aurora-host/tools"))
from ui_depth_test import ink_fraction
records = []
for mode, hint in (("baseline", "0"), ("natural", "natural")):
    env = os.environ.copy()
    env.update(AURORA_HINTING=hint, AURORA_TEXT_COVERAGE="foreground", AURORA_TEXT_CONTRAST="0.5")
    for dpi in (96, 120, 144, 192):
        prefix = BUILD / f"{mode}-{dpi}"
        subprocess.run([str(exe), str(dpi), str(prefix)], cwd=ROOT, env=env, check=True)
        info = json.loads(prefix.with_suffix(".json").read_text("utf-8"))
        image = Image.open(prefix.with_suffix(".ppm")).convert("RGB")
        scale = image.width / info["logical_width"]
        x,y = round(info["editor_x"]*scale), round(info["editor_y"]*scale)
        ink = ink_fraction(image.tobytes(), image.width, x+round(8*scale), y+round(4*scale),
                           x+round(450*scale), y+round(150*scale))
        records.append({"mode": mode, "dpi": dpi, "width": image.width, "height": image.height,
                        "ink": ink, "passes_B_guard": ink >= 0.045, "passes_approved_C_guard": ink >= 0.039})
        image.save(HERE / f"workbench-{mode}-{dpi}.png")
        print(mode, dpi, round(ink,6), flush=True)
(HERE / "workbench-density.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
