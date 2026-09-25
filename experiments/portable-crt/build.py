"""Build the experimental library, optionally adding its C ABI objects."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--with-c", action="store_true",
                    help="compile C ABI sources using the MSVC compiler")
args = parser.parse_args()


def msvc_environment():
    vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / (
        "Microsoft Visual Studio/Installer/vswhere.exe"
    )
    installation = subprocess.check_output(
        [str(vswhere), "-latest", "-products", "*", "-requires",
         "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
         "-property", "installationPath"],
        text=True,
    ).strip()
    if not installation:
        raise RuntimeError("Visual Studio C++ compiler was not found")
    vcvars = Path(installation) / "VC/Auxiliary/Build/vcvars64.bat"
    with tempfile.TemporaryDirectory(prefix="aurora-vcvars-") as temporary:
        wrapper = Path(temporary) / "environment.cmd"
        wrapper.write_text(
            f'@echo off\ncall "{vcvars}"\nif errorlevel 1 exit /b %errorlevel%\nset\n',
            encoding="ascii",
        )
        result = subprocess.run(
            ["cmd", "/d", "/c", str(wrapper)],
            capture_output=True,
            text=True,
        )
    if result.returncode:
        raise RuntimeError(
            f"Could not initialize the Visual C++ environment ({result.returncode}):\n"
            f"{result.stdout[-4000:]}\n{result.stderr[-4000:]}"
        )
    environment = os.environ.copy()
    for line in result.stdout.splitlines():
        name, separator, value = line.partition("=")
        if separator and name and not name.startswith("="):
            environment[name] = value
    return environment


d_sources = [
    root / name for name in (
        "memory.d", "process.d", "thread.d", "environment.d", "fd.d",
        "stdio.d", "time_locale.d", "parse_bridge.d",
    )
]

with tempfile.TemporaryDirectory(prefix="aurora-crt-build-") as temporary:
    objects = []
    if args.with_c:
        environment = msvc_environment()
        for source_name in ("bootstrap.c", "format_parse.c"):
            source = root / source_name
            output = Path(temporary) / f"{source.stem}.obj"
            subprocess.run(
                ["cl", "/nologo", "/std:c11", "/O2", "/GS-", "/Zl", "/c",
                 f"/I{root}", f"/Fo{output}", str(source)],
                env=environment,
                check=True,
            )
            objects.append(output)

    completed = subprocess.run(
        ["dmd", "-m64", "-betterC", "-release", "-lib",
         f"-of={root / 'aurora_crt.lib'}",
         *(str(source) for source in d_sources),
         *(str(obj) for obj in objects)],
        check=False,
    )
    raise SystemExit(completed.returncode)
