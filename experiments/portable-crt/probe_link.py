"""Relink an existing DUB object against the experimental CRT.

Pass the log from a DUB build that printed its lld-link command after a
link failure. This only writes a temporary EXE and never launches it.
"""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument("build_log", type=Path)
args = parser.parse_args()

root = Path(__file__).resolve().parent
lines = args.build_log.read_text(errors="replace").splitlines()
command = next((line.strip() for line in lines if "lld-link.exe /NOLOGO" in line), None)
if command is None:
    parser.error("build log does not contain an lld-link command")

output = Path(tempfile.gettempdir()) / "aurora-crt-probe.exe"
linker = Path(command.split(" /NOLOGO", 1)[0].strip('"'))
system_libs = linker.parent.parent / "lib64"
command, replacements = re.subn(
    r'/OUT:"[^"]+"', lambda _: f'/OUT:"{output}"', command, count=1
)
if replacements != 1:
    parser.error("lld-link command does not contain a quoted /OUT path")

command += (
    f' /DEFAULTLIB:aurora_crt.lib /DEFAULTLIB:kernel32.lib'
    f' /LIBPATH:"{root}" /LIBPATH:"{system_libs}"'
    ' /ERRORLIMIT:0'
)
completed = subprocess.run(command, capture_output=True, text=True, check=False)
symbols = re.findall(r"^lld-link: error: (?:<root>: )?undefined symbol: (.+)$",
                     completed.stdout + completed.stderr, flags=re.MULTILINE)
print(f"Unresolved symbols: {len(symbols)}")
print("\n".join(symbols))
raise SystemExit(completed.returncode)
