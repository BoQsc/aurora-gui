"""0BSD: Relink Aurora's cached object without running the resulting EXE."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument("build_log", type=Path)
parser.add_argument("libraries", nargs="*", default=["ucrtbase.lib", "kernel32.lib"])
args = parser.parse_args()

command = next(
    (line.strip() for line in args.build_log.read_text(errors="replace").splitlines()
     if "lld-link.exe /NOLOGO" in line),
    None,
)
if command is None:
    parser.error("build log does not contain an lld-link command")

output = Path(tempfile.gettempdir()) / "aurora-portablecrt-probe.exe"
linker = Path(command.split(" /NOLOGO", 1)[0].strip('"'))
dmd_libraries = linker.parent.parent / "lib64"
command, count = re.subn(
    r'/OUT:"[^"]+"', lambda _: f'/OUT:"{output}"', command, count=1
)
if count != 1:
    parser.error("lld-link command does not contain a quoted /OUT path")

command += f' /LIBPATH:"{dmd_libraries}" /ERRORLIMIT:0 /NODEFAULTLIB:aurora_crt.lib '
command += " ".join(
    f'/DEFAULTLIB:"{library}"' for library in args.libraries
)
result = subprocess.run(command, capture_output=True, text=True, check=False)
diagnostics = result.stdout + result.stderr
symbols = re.findall(
    r"^lld-link: error: (?:<root>: )?undefined symbol: (.+)$",
    diagnostics, flags=re.MULTILINE,
)
print(f"Unresolved symbols: {len(symbols)}")
print("\n".join(symbols))
if result.returncode and not symbols:
    print(diagnostics[-4000:])
raise SystemExit(result.returncode)
