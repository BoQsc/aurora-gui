"""Compile and exercise the real tool worker without touching user chat state."""
import subprocess
import tempfile
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent
with tempfile.TemporaryDirectory(prefix="aurora-parallel-test-") as temporary:
    directory = Path(temporary)
    executable = directory / "parallel_tool_batch_test.exe"
    subprocess.run([
        "dmd", "-i", "-I" + str(package / "source"),
        "-I" + str(package / "shared"),
        "-I" + str(repo / "aurora-opencode-core/source"),
        "-I" + str(repo / "vendor/aurora-d-0.4.5/source"),
        "-J" + str(package / "assets"), "-of" + str(executable),
        str(package / "tests/parallel_tool_batch_test.d"),
        "user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib",
    ], check=True, cwd=directory)
    subprocess.run([str(executable)], check=True, cwd=directory, timeout=60)
