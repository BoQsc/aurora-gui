# Native utility services, 0.66.44

Aurora now exposes shared archive operations, structured data editing and
environment inspection, and extends its existing supervised processes with
bounded waits and incremental output. No DUB dependencies, external utility
packages, language servers or installers were added.

## Shared archives

`archive` provides `create`, `list`, `extract` and `validate`. The source snapshot
wrapper, developer-tool extraction, assistant operations and diagnostic ZIP
collector use `auroraopencode.archives`; the collector no longer implements ZIP
creation in Python. Independent test readers still use Python's ZIP/TAR modules
as interoperability oracles.

ZIP metadata and creation reuse D's existing standard library. Extraction and
validation stream through the zlib already linked by that library, checking
expanded length and CRC-32 without retaining every expanded member. The standard
library's `ZipArchive.expand` did not perform CRC checking. Uncompressed ustar TAR
uses bounded streaming I/O. Native file operations supply staging and atomic
renames.

Create takes explicit workspace-relative inputs under `root`. Output archives
and extraction destinations must be new. Tool extraction stages the complete
result before publishing the destination. Paths, links, conflicting destinations
and Windows reserved names are checked. Failed tool extraction removes its
staging directory. Listing is paged; validation and extraction return summaries
instead of repeating the manifest into the model's context.
Private source/provisioning callers retain their earlier overwrite behavior
through an internal option, so interrupted installs can retry. Each replacement
is staged and published only after its payload checks pass.

Current bounds: ZIP's memory-backed input/creation is limited to 512 MiB;
streaming TAR and expanded archive contents to 8 GiB; archives to 100,000 entries.
TAR links and extension records, encrypted ZIPs and unsupported compression
methods fail explicitly. TAR validation checks structure and header checksums;
ZIP validation additionally checks each payload CRC. Neither establishes that
the selected files satisfy every domain-specific handoff requirement.

## Structured data

`data` supports JSON and CSV query, validation, formatting, set and remove.
Pointers follow RFC 6901. CSV is an array of string rows, including the header;
quoted delimiters, escaped quotes, multiline fields, LF and CRLF are supported.
Files are bounded to 16 MiB and query responses to 24 KiB. JSON parsing and
pointer traversal have explicit depth bounds.

Model-facing replacements use `valueJson`, an explicitly JSON-encoded string:

```json
{"action":"set","path":"config.json","pointer":"/enabled","valueJson":"true"}
```

This avoids the live provider's tendency to turn an unconstrained schema value
into a string. Values are parsed exactly once, without guessing or coercing
ordinary strings. The internal API retains correctly typed `value` compatibility.
Batch changes commit together; invalid edits preserve the original file.
Queries return SHA-256, and optional `expectedSha256` rejects stale updates.
Writes check the current original again and atomically replace the file.
Reserialization preserves values, not original whitespace. TOML and YAML are
not advertised as supported formats.

## Process waiting and inspection

`process` retains its registry, stdin and termination operations. `wait` adds
`event=exit|output`, a 0–60,000 ms deadline, and byte-offset output cursors.
Completion wakes waiters through the registry condition variable; output waits
check the local log at bounded intervals. Returned chunks are bounded and avoid
cutting an incomplete UTF-8 sequence. `nextOffset` prevents rereading old logs.
Legacy accumulated-output calls remain compatible.

A wait deadline leaves the same process running. Cancelling a wait interrupts
the wait promptly and leaves the process supervised. Requested termination is
reported as `killed`, without turning a successful kill-and-wait into a failed
tool. Unexpected nonzero exits and execution timeouts remain failures. Existing
source-development background-command protections remain enabled.

`environment` returns system/workspace identity, executable resolution without
execution, disk capacity, bounded process listings and Windows TCP listeners
with owning PIDs, using standard-library/platform APIs. Executable versions are
queried through explicit `run` arguments when needed. TCP inspection supports
IPv4 and IPv6. It does not dump environment variable values. Available platform
implementations are Windows/Linux process inspection and Windows/POSIX disk
inspection; TCP listener inspection currently supports Windows.

Read-only operations use the parallel observer lane. Archive/data mutations
use the existing checkout protection, mutation serialization, safety journal,
post-edit hooks and verification invalidation. Unchanged data writes preserve
existing verification. Integrity/format validation does not automatically claim
complete behavioral verification of a task.

## Maintenance entry point

Before GUI/settings/history loading, the same executable accepts:

```text
aurora-opencode-pro --aurora-native-tool archive request.json WORKSPACE
```

`data` and `environment` use the same entry point. The response is JSON and the
exit status signals failure. Diagnostic collectors discover the installed app
or accept `--archiver`; `AURORA_NATIVE_ARCHIVER` supplies an isolated test binary.

## Real isolated tasks

The maintained diagnostic collector exported an actual Aurora UI-freeze chat:
218 messages, 21 archive entries and a 978,395-byte ZIP. Python independently
opened the result, checked CRCs, and confirmed the selected chat/report files.
Project-source collection and process inspection were disabled for that export.

The opt-in `benchmarks/native_services_live.py` uses actual Aurora source files
in a fresh checkout, private APPDATA/TEMP, and the configured hosted model. It
asks for a source review ZIP, JSON/CSV metadata, native environment inspection,
and a real localhost HTTP download followed by server cleanup. An independent
checker compares every archived file hash to the pre-task source manifest,
checks metadata and CSV, compares the downloaded archive, and verifies the
server port is closed. No task patches are copied back into production.

| Attempt | Seconds | Tool results | Result |
| --- | ---: | ---: | --- |
| Initial harness | 173.2 | 41 at last observation | Aborted: missing isolated Git metadata; also exposed stringified unconstrained data values |
| Valid checkout with self-development protection | 99.5 | 35 | Completed; independent checks passed; explicit source-background refusal and requested-kill failure exposed avoidable work |
| Normal task workspace, explicit JSON values and concise validation | 92.5 | 42 | Completed; independent checks passed; native JSON/CSV updates; zero failed tools |

These are different iterations of one workload, not a controlled speedup claim.
The last run used `deepseek/deepseek-v4.1-flash` and 100 real source files. The
task exercises real execution and networking; provider responses are not canned.
The first attempt's artifacts are retained as a rejected run. No TerraForest
project or snapshot was read or modified.

Native contracts cover ZIP/TAR round trips, CRC corruption, traversal and
overwrite rejection, failed-extraction cleanup, JSON pointer edits and stale
guards, atomic batch failure, quoted CSV, executable/process/disk/TCP inspection,
process output/completion waits, deadlines and cancellation. Existing developer
workflow, tool-resource, source-background, tracked-check and delivery-latency
checks cover integration. The diagnostic collector's Python suite passed
24 tests, with one symlink test skipped because link creation was unavailable.

Private live artifacts are beneath `%TEMP%/aurora-native-services-live-06644-*`;
diagnostic export artifacts are beneath `%TEMP%/aurora-native-real-diagnostics-*`.
The executable and delivery performance are verified separately during rebuild.
