"""One supervised verification of quick chat-title generation.

Chains the three contracts that together prove the reported bug is fixed:

* ``test_quick_title.py``      - a brand-new chat is named while another
                                 conversation is still busy (the starvation case).
* ``test_quick_title_agent_turn.py`` - the name lands across an agent turn's
                                 tool rounds, while the turn is still running.
* ``test_quick_title_restore.py``    - a rewrite lost to a restart/rebuild, or
                                 left stranded by the earlier whole-turn gate,
                                 is re-queued on the next launch.

Each harness builds its own D fixture through ``run_architecture_checks.py`` and
asserts on real output; a non-zero result from any of them fails this script.
The harness shells out to ``git`` for the head commit, so a PATH entry for git
is supplied here rather than assumed.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GIT_FALLBACK = (
    r"C:/Users/windows10/AppData/Local/GitHubDesktop/app-3.6.7/"
    r"resources/app/git/cmd"
)

TESTS = [
    "aurora-opencode-pro/tests/test_quick_title.py",
    "aurora-opencode-pro/tests/test_quick_title_agent_turn.py",
    "aurora-opencode-pro/tests/test_quick_title_restore.py",
]


def with_git_on_path(env):
    if shutil.which("git", path=env.get("PATH", "")):
        return env
    env = dict(env)
    env["PATH"] = GIT_FALLBACK + os.pathsep + env.get("PATH", "")
    return env


def main():
    env = with_git_on_path(os.environ)
    failures = []
    for test in TESTS:
        print(f"---- {test}", flush=True)
        result = subprocess.run(
            [sys.executable, "-u", test], cwd=REPO, env=env, timeout=1200
        )
        if result.returncode != 0:
            failures.append((test, result.returncode))
    if failures:
        for test, code in failures:
            print(f"FAILED {test} (exit {code})", flush=True)
        return 1
    print("PASS quick title generation: new chat named under a busy conversation, "
          "across tool rounds, and a stranded rewrite recovered on restart",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
