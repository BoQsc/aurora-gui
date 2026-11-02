from pathlib import Path
import os
import tempfile
import threading
import time
from architecture_retention import FileLease, prune_runs, safe_run

with tempfile.TemporaryDirectory(prefix="aurora-retention-") as temporary:
    root = Path(temporary).resolve()
    runs = []
    for number in range(6):
        run = root / f"architecture-checks-{number}"
        run.mkdir()
        (run / "evidence.json").write_text("{}", encoding="utf-8")
        (run / ".running.lock").write_bytes(b"\0")
        os.utime(run, (time.time() - 100 + number, time.time() - 100 + number))
        runs.append(run)
    with FileLease(runs[0] / ".running.lock"):
        results = []
        threads = [threading.Thread(target=lambda: results.append(prune_runs(root, 2))) for _ in range(3)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert runs[0].exists() and runs[4].exists() and runs[5].exists()
        assert sum(results) == 3, results
        assert not safe_run(root, root.parent / "architecture-checks-outside")
        assert not safe_run(root, root / "unrelated")
    assert prune_runs(root, 2) == 1 and not runs[0].exists()
print("PASS concurrent retention preserves live runs, keeps completed evidence, and rejects targets outside its artifact root")
