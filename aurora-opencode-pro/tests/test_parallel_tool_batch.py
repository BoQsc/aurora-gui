"""Exercise tool workers with the same isolated filesystem host as other contracts."""
import subprocess
import sys
from pathlib import Path

package = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                "parallel_tool_batch_test"], check=True, cwd=package.parent, timeout=180)
