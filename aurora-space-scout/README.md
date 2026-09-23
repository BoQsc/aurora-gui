# Aurora Space Scout

Aurora Space Scout finds large, recently changed files and folders under a
folder you choose. Scanning is read-only. A result is moved only after you
select it, review its path and size, and confirm the Recycle Bin prompt.

## Start on Windows

Run `RUN-WINDOWS.bat` with DMD or LDC and DUB available on `PATH`. The initial
scan starts in your Windows user profile. Use **Choose folder** to inspect a
different folder or drive.

## Using the results

- Switch between **Large files** and **Large folders**.
- Change the recent-modification window (7, 30, or 90 days).
- Change the minimum size (100 MB, 500 MB, or 1 GB).
- Results are ordered largest first. Select one to inspect its full path,
  modification date, and size. Double click opens the item in Windows.
- **Move to Recycle Bin** requires confirmation and uses Windows undo support.

Directory junctions and symbolic links are skipped during scanning to avoid
loops and results outside the selected root. Items that cannot be read are
skipped and counted in the completion status.

## Build

```bat
cd aurora-space-scout
dub build
dub build --build=portable-release
```
