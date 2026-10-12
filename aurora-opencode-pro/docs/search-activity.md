# Visible search activity

Grep, glob file discovery, and `dshell list` now report structured activity in
their live chat rows. The row displays the search expression and filter, root
scope, current path, files/folders/entries checked, matching lines or paths,
and up to two recent matches. Grep also shows lines and text bytes read.

Grep uses two stages. **Discovering candidate files** walks the selected tree
once, applies the filename/generated-folder/extension/size policies, and keeps
the eligible paths. It shows the current path, discovered candidates, and scan
counts without a progress bar: the total is still unknown. **Searching contents**
then processes that fixed candidate list. Its bar and `Processed X of Y candidate
files · Z% by file` come from completed file attempts, rather than animation.
The percentage measures files, not remaining time; one large or expensive file
can hold it still while line/byte counters continue. There is no estimated finish
time. Filename searches and directory listing do their useful work during
discovery, so they retain activity counts without an animated bar or a redundant
counting pass.

The candidate list is a snapshot of paths, not a frozen filesystem. Files added
after discovery are outside that search. Files that disappear, become unreadable,
or exceed the recursive size policy before processing report errors or skips.
Binary detection happens when opening candidates. These attempts count as
processed, with explicit skip/error counts; 100% of the list attempted does not
erase an incomplete outcome caused by unreadable paths. A file interrupted by
Stop, timeout, or the content result limit does not count as completed. In
matching-file mode, finding the first match completes that file's requested work.

Discovery is bounded to 100000 candidates and 32 MiB of stored path text. Hitting
either bound returns an incomplete result asking for a narrower path or filter,
without searching a silently truncated list. The soft deadline covers both stages.
Counting first delays initial content matches until discovery finishes, but avoids
a second directory walk and makes the denominator stable. A discovery timeout has
no percentage; an interrupted content search retains its actual fraction.

Skip counts distinguish filters, generated folders, binary files, oversized
files, links, and unreadable paths. Recursive grep retains its existing 8 MiB
per-file policy; a named text file can be searched explicitly when larger.
Binary detection also checks an initial 8 KiB for NUL bytes. Glob and grep do
not descend into directory links, and bound recursion to 256 folder levels.

The filesystem helper forwards the activity payload without exposing its raw
encoding or replacing it with process diagnostics. While the helper is busy,
the parent updates elapsed time and reports how long it has received no new
scan activity. This is an observation, not a claim that the search is hung.
Stop and hard timeouts retain the last reported counts and recent matches in
the tool result, marked incomplete. The helper is still isolated so Stop can
terminate a blocked directory call or regular-expression search.

Grep result limits, soft deadlines, and unreadable files are distinguished
from a completed search. Glob no longer silently treats capped results or
traversal errors as completion. Directory listing keeps its existing immutable
continuation checkpoints and carries cumulative scan counts to the next page.
The latest-match preview and scan counts are bounded; they are not a complete
incremental result stream. Grep timeouts require a focused retry, while only
directory listing supports continuation cursors.

Verification covers actual helper communication, CRLF matching, skip reasons,
inventory totals, all grep result modes, partial-file limits, zero candidates,
unreadable files, discovery/content deadlines, quiet-host heartbeats, Stop,
timeout evidence, and directory continuation. UI checks render discovery without
a bar and measured content progress, verify quiet periods and interruption do
not fabricate progress, preserve activity through transcript reconstruction, and
check that the added details do not overlap other rows.

The behavior was checked against Notepad++'s current source on 2026-10-13:
[`createFilelistForFiles` / `findInFiles` / `findInFilelist`](https://github.com/notepad-plus-plus/notepad-plus-plus/blob/master/PowerEditor/src/Notepad_plus.cpp).
It collects candidates under a discovery phase, then supplies file-count progress
while searching the list. Aurora implements that approach with its own existing
filters, deadlines, helper isolation, and bounded inventory.
