# Large-file tool workflow

The remote “Qwen Image Turbo memory and speed issue” chat exposed a tool-host
problem as well as missing transfer feedback. A native move was interrupted;
subsequent tools timed out waiting for a workspace lease. Clearing completed
process records could not help, because native file operations do not appear in
that process registry.

The previous history implementation read every source and destination into RAM,
duplicated the buffers, and wrote before/after blobs. For multi-gigabyte model
files that work could hold the workspace writer for a long time and consume
tens of gigabytes before the move even began. Native copy had no cancellation
or byte progress; native move only used rename and could not cross volumes.

## Tools

- `copy` and `move` handle files, folders, and batches, with a live inline bar,
  byte counts, file counts, transfer speed, approximate remaining time, and the
  current path. Scanning has an indeterminate bar. Progress remains visible in
  collapsed live groups and survives transcript reconstruction.
- Same-volume moves use Windows renames. They report metadata movement without
  inventing a byte transfer rate. Cross-volume moves finish every destination
  copy before removing any source. If source cleanup fails, completed copies
  remain and the tool reports partial completion.
- Copy uses Windows native streaming I/O and temporary destination files;
  installation refuses to replace a destination created during the copy.
  Stop cancels unfinished work, cleans partial copies, and restores completed
  same-volume renames when possible. Failures identify cleanup/rollback errors.
  Do not assume an interrupted operation made no changes: inspect both paths.
- `download` streams an HTTP(S) URL into a file using Windows HTTP APIs. It
  follows redirects, reports progress, optionally verifies a publisher SHA-256,
  and never overwrites an existing destination. Stop and connection failures
  keep recognized partial data. Repeating the same request resumes using a
  resource validator or an expected checksum; a server ignoring Range restarts
  from zero. A complete partial file stopped during checksum can be recovered
  from HTTP 416. A checksum mismatch removes rejected partial data.
- `checksum` hashes a file with a 1 MiB read buffer and optional expected SHA-256.
  It reports progress and supports Stop. This avoids Python `read_bytes()` on
  multi-gigabyte downloads. A model checksum establishes file integrity, not a
  successful render or application verification.
- `dshell info` includes available and total volume bytes on Windows.
- `tool_status` reports active native tools, elapsed time, workspace writer
  ownership, and queue counts. It and plan updates use the control worker lane,
  so a workspace writer cannot block them. `process` remains the tool for
  supervised external commands. Removing process records does not cancel tools.

History captures at most 1 MiB per file, 16 MiB of content per operation, and
10,000 paths. Larger content is recorded as metadata; automatic restore is
explicitly unavailable for those paths. Small-file and small-folder restores
remain available. Legacy oversized snapshots are not loaded into the UI.
File transfers scan at most 100,000 entries and 256 folder levels per batch.
Symbolic links and junctions are refused before mutation. Existing targets are
always refused; transfers do not merge or silently skip collisions.

Native download uses per-network-operation timeouts (default 10 seconds), not
a whole-download deadline. Stop is checked between reads; a blocked Windows
network call can take until its timeout to return. Native download currently
requires Windows. Archive extraction and arbitrary external programs still use
the supervised `run`/`process` tools and do not receive native transfer bars.

## Verification and resuming the affected chat

Fixtures cover an 8 GiB sparse same-volume move, bounded history, small-folder
restore, cross-volume copy/delete execution, cancellation, collisions appearing
mid-copy, progress rendering, control-lane responsiveness, HTTP redirects,
truncation/resume, cancellation during checksum, HTTP errors, and checksum
rejection. A local HTTP server is used for download tests. The cross-volume
fixture forces the copy/delete path; a move between two physical drives still
needs validation on the affected computer.

After updating Aurora on the affected computer, resume its existing chat. The
agent should inspect `downloads` and `models`, check file sizes and available
space, resolve existing-file collisions deliberately, verify model checksums,
move the remaining files using `move`, then run the actual image-generation
check. The remote image-generation application has not been tested here.
Keep the previous installation until the replacement passes that check.
