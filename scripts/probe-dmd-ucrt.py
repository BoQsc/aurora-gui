"""Build Aurora in an isolated directory with DMD's dynamic UCRT fallback."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument("--compiler", type=Path, required=True)
args = parser.parse_args()

repository = Path(__file__).resolve().parent.parent
compiler = args.compiler.resolve()
dub = compiler.with_name("dub.exe")
if not compiler.is_file() or not dub.is_file():
    raise SystemExit("Pass the bin64/dmd.exe from the portable DMD archive; its dub.exe is also required")
saved_dir = repository / "build" / "ucrt-probe"
package = repository / "aurora-opencode-pro"
source_recipe = package / "dub.json"
temporary_recipe = package / "dub.ucrt-probe.json"
if temporary_recipe.exists():
    raise SystemExit(f"Refusing to replace existing {temporary_recipe}")

recipe = json.loads(source_recipe.read_text(encoding="utf-8"))
for configuration in recipe.get("configurations", []):
    configuration.pop("postBuildCommands-windows", None)
    if configuration.get("name") == "newbuild":
        configuration["targetName"] = "aurora-ucrt-probe"
recipe["libs-windows"] = list(recipe.get("libs-windows", [])) + [
    "legacy_stdio_definitions"
]

with tempfile.TemporaryDirectory(prefix="aurora-ucrt-build-") as temporary:
    output = Path(temporary)
    memory_imports = output / "ucrt-memory-imports.lib"
    subprocess.run(
        [sys.executable, str(repository / "scripts" /
                             "generate-ucrt-memory-imports.py"),
         "--out", str(memory_imports)],
        check=True,
    )
    recipe["lflags-windows"] = list(recipe.get("lflags-windows", [])) + [
        f"/WHOLEARCHIVE:{memory_imports.resolve()}"
    ]
    temporary_recipe.write_text(json.dumps(recipe, indent=2), encoding="utf-8")
    command = [
        str(dub), "build", f"--recipe={temporary_recipe}", "--config=newbuild",
        "--build=release", f"--compiler={compiler}", f"--dest={output}",
        "--force", "--verbose", "--non-interactive",
    ]
    try:
        result = subprocess.run(command, cwd=package, capture_output=True,
                                text=True, check=False)
    finally:
        temporary_recipe.unlink()
    log = output / "dub-build.log"
    log.write_text(result.stdout + result.stderr, encoding="utf-8")
    saved_dir.mkdir(parents=True, exist_ok=True)
    saved_log = saved_dir / "aurora-ucrt-probe.log"
    shutil.copy2(log, saved_log)
    print(f"Build exit: {result.returncode}")
    print(f"Build log: {saved_log}")
    if result.returncode:
        print((result.stdout + result.stderr)[-6000:])
    executables = list(output.rglob("aurora-ucrt-probe.exe"))
    if executables:
        # Keep the isolated result after the temporary build directory closes.
        saved = saved_dir / "aurora-ucrt-probe.exe"
        shutil.copy2(executables[0], saved)
        print(f"Saved isolated EXE: {saved}")
        try:
            import pefile
        except ImportError:
            print("Install the optional pefile Python package to list DLL imports")
        else:
            image = pefile.PE(str(saved))
            imports = sorted(entry.dll.decode("ascii")
                             for entry in image.DIRECTORY_ENTRY_IMPORT)
            print("DLL imports:", ", ".join(imports))
            if any(name.lower().startswith("vcruntime") for name in imports):
                print("A VC++ runtime DLL dependency remains")
                raise SystemExit(2)
    raise SystemExit(result.returncode)
