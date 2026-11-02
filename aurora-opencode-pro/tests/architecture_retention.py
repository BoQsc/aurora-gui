"""Serialize artifact retention and never remove a live fixture run."""
from pathlib import Path
import os
import shutil
import stat
import time


class FileLease:
    def __init__(self, path: Path, blocking: bool = False):
        self.file = path.open("a+b")
        if not path.stat().st_size:
            self.file.write(b"\0")
            self.file.flush()
        deadline = time.monotonic() + (30 if blocking else 0)
        while True:
            try:
                self.file.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    self.file.close()
                    raise
                time.sleep(0.05)

    def close(self):
        if self.file.closed:
            return
        self.file.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(self.file.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(self.file.fileno(), fcntl.LOCK_UN)
        self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def active_run(directory: Path) -> bool:
    marker = directory / ".running.lock"
    if not marker.exists():
        # Protect the creation gap before a new runner claims its marker.
        return time.time() - directory.stat().st_mtime < 30
    try:
        with FileLease(marker):
            return False
    except OSError:
        return True


def safe_run(root: Path, directory: Path) -> bool:
    return (directory.name.startswith("architecture-checks-")
            and not directory.is_symlink()
            and not getattr(directory, "is_junction", lambda: False)()
            and directory.resolve().parent == root.resolve())


def prune_runs(root: Path, keep: int, current: Path | None = None) -> int:
    """Retain `keep` completed runs plus every active run; check each target."""
    if keep < 1:
        raise ValueError("keep must be positive")
    root = root.resolve()
    with FileLease(root / ".architecture-retention.lock", blocking=True):
        runs = []
        for candidate in root.iterdir():
            try:
                if candidate == current or not candidate.is_dir() or not safe_run(root, candidate) or active_run(candidate):
                    continue
                runs.append((candidate.stat().st_mtime, candidate))
            except FileNotFoundError:
                continue
        runs.sort(key=lambda item: item[0], reverse=True)

        def remove_readonly(function, path, error):
            try:
                os.chmod(path, stat.S_IWRITE)
                function(path)
            except FileNotFoundError:
                pass

        removed = 0
        for _, candidate in runs[keep:]:
            try:
                if not safe_run(root, candidate) or active_run(candidate):
                    continue
                shutil.rmtree(candidate, onexc=remove_readonly)
            except FileNotFoundError:
                continue
            except OSError as error:
                print(f"PRUNE WARNING {candidate}: {error}", flush=True)
            else:
                removed += 1
        return removed
