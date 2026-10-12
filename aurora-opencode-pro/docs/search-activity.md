# Visible search activity

Grep, glob file discovery, and `dshell list` now report structured activity in
their live chat rows. The row displays the search expression and filter, root
scope, current path, files/folders/entries checked, matching lines or paths,
and up to two recent matches. Grep also shows lines and text bytes read.
An animated bar indicates ongoing discovery; the size of a directory tree is
unknown, so searches do not display an invented completion percentage.

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
result caps, empty completed searches, unreadable files, quiet-host heartbeats,
Stop, timeout evidence, and directory continuation. UI checks render all three
tool types, verify their activity survives transcript reconstruction, and check
that the added details do not overlap other rows. Transfer UI, execution UI,
tool behavior, architecture, and history preservation regressions also pass.
