"""0BSD: Build the Windows UCRT backend using the CI runner's C++ tools."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
VSWHERE = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / (
    "Microsoft Visual Studio/Installer/vswhere.exe"
)
installation = subprocess.check_output(
    [str(VSWHERE), "-latest", "-products", "*", "-requires",
     "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
     "-property", "installationPath"],
    text=True,
).strip()
if not installation:
    raise RuntimeError("Visual C++ compiler was not found on this build host")

with tempfile.TemporaryDirectory(prefix="portablecrt-build-") as temporary:
    temporary = Path(temporary)
    vcvars = Path(installation) / "VC/Auxiliary/Build/vcvars64.bat"
    wrapper = temporary / "environment.cmd"
    wrapper.write_text(
        f'@echo off\ncall "{vcvars}"\nif errorlevel 1 exit /b %errorlevel%\nset\n',
        encoding="ascii",
    )
    result = subprocess.run(
        ["cmd", "/d", "/c", str(wrapper)], capture_output=True, text=True
    )
    if result.returncode:
        raise RuntimeError(
            f"Could not initialize Visual C++ ({result.returncode}):\n"
            f"{result.stdout[-4000:]}\n{result.stderr[-4000:]}"
        )
    environment = os.environ.copy()
    for line in result.stdout.splitlines():
        name, separator, value = line.partition("=")
        if separator and name and not name.startswith("="):
            environment[name] = value

    compiler = shutil.which("cl.exe", path=environment.get("Path") or
                            environment.get("PATH"))
    if not compiler:
        candidates = sorted((Path(installation) / "VC/Tools/MSVC").glob(
            "*/bin/Hostx64/x64/cl.exe"
        ))
        compiler = str(candidates[-1]) if candidates else None
    if not compiler:
        raise RuntimeError("Visual C++ environment has no x64 cl.exe")
    librarian = str(Path(compiler).with_name("lib.exe"))

    objects = []
    for source_name in ("windows_ucrt_startup.c", "windows_ucrt_shims.c"):
        source = ROOT / source_name
        output = temporary / f"{source.stem}.obj"
        subprocess.run(
            [compiler, "/nologo", "/std:c11", "/O2", "/GS-", "/Zl",
             "/c", f"/Fo{output}", str(source)],
            env=environment, check=True,
        )
        objects.append(str(output))

    subprocess.run(
        [librarian, "/nologo", f"/out:{ROOT / 'portablecrt.lib'}", *objects],
        env=environment, check=True,
    )
    print(f"Created {ROOT / 'portablecrt.lib'}")
