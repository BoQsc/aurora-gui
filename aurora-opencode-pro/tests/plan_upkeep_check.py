"""Build the plan-upkeep fixture in a temp folder and run it there.

A verification recipe's ``tests`` step is accepted evidence, so the fixture must
run without modifying the checkout: build artifacts inside the package would
change the workspace revision and make the receipt unscopable. The filesystem
host is built here as well, because the app needs it for workspace reads and
process supervision in a headless fixture.
"""
import os
import subprocess
import sys
import tempfile

PACKAGE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = tempfile.mkdtemp(prefix="plan-upkeep-")
INCLUDES = [
    "-Isource", "-Ishared", "-Itests",
    "-I../aurora-opencode-core/source",
    "-I../vendor/aurora-d-0.4.5/source",
    "-Jassets",
]
LIBS = ["user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib", "winmm.lib"]


def build(source, name):
    exe = os.path.join(ROOT, name + ".exe")
    subprocess.run(
        ["dmd", "-i", "-verrors=20", "-od" + ROOT + os.sep, *INCLUDES,
         "-of" + exe, source, *LIBS],
        cwd=PACKAGE, check=True)
    return exe


host = build("tests/filesystem_host.d", "filesystem_host")
fixture = build("tests/early_plan_contracts.d", "early_plan_contracts")
env = dict(os.environ, AURORA_FILESYSTEM_HOST=host)
sys.exit(subprocess.run([fixture], cwd=ROOT, env=env).returncode)
