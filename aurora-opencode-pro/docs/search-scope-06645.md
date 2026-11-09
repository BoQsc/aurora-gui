# Search selection and recovery, 0.66.45

The opening of chat `t-m639298375290728147-406` searched the entire Aurora
repository for `aurorahost`, timed out after 10 seconds, then retried a broader
regex with a 120-second deadline. That second search read 245.9 MiB and 18,158
files before timing out. A parallel directory listing had already identified
`experiments/aurora-host`. The search code was unchanged in 0.66.44; the runtime
still encouraged deadline escalation instead of finding the appropriate scope.

## Runtime changes

- An unfiltered workspace-root grep now performs bounded project-folder
  discovery first. It checks standard project manifests and ranks normalized
  project names, including separator differences such as `examplehost` versus
  `example-host`. Discovery has a 250 ms cooperative budget, a depth bound and
  a 2,000-entry bound. It does not scan file contents or maintain a background
  index.
- When projects match, grep returns `status=scope_selection`, explicitly states
  `contentsSearched=false`, and supplies ready-to-use narrower search arguments.
  It does not silently substitute a scoped content search for a complete
  repository search. `scope=contents` deliberately requests content search
  across the selected root.
- Unfiltered auto searches at the workspace root retain their 10-second budget
  even if a caller blindly raises `timeout`. The filesystem host applies that
  bound too, with its existing 5-second termination grace. Catch-all filters
  such as `*` do not bypass discovery or the root budget. Chosen subdirectories,
  files, meaningful include filters and explicit content searches retain
  configurable deadlines.
- Generated audit/output directories, including `artifacts`, `.aurora`,
  `.audit-inputs` and `screenshots`, join the existing generated-folder skip
  list. `includeGenerated=true` opts in; an explicitly selected generated
  directory is also searchable directly.
- Both soft and host timeout results prioritize narrower paths/filters and
  partial-result inspection. Soft timeouts include concrete narrower calls
  without carrying forward the expanded deadline. The old instruction to
  rerun the same search with a larger timeout is removed.
- Include matching uses the standard-library glob matcher. Brace alternatives
  and character classes work, and a regex is no longer compiled for every
  candidate file. This fixes the real replay's false no-match result for
  `*.{md,bat,ps1,py,yml,yaml,json}`.

The changes are shared by the native-only and shell-enabled grep definitions.
No new dependencies, mandatory plan steps or separate search tools were added.

## Real isolated replay

`benchmarks/replay_search_scope.py --live` copies actual Aurora source and audit
artifact text, replays the saved opening grep arguments, then submits the
original opening question to the configured real provider. Original paths are
mapped to the copy; APPDATA/TEMP and history are private. Inputs are hashed
before and after, and the harness rejects source mutations and long searches.
Authored verification recipes are retained; private state and binaries are not.
No TerraForest project, assets or snapshots are used.

On the same initial frozen 2,188-file source copy, the pre-change binary's first
saved grep timed out after **10,064 ms**, having read 78.4 MiB. The candidate
returned project choices in **47 ms** and completed the selected project search
in **860 ms** on the cold first pass. The saved 120-second retry returned choices
in **61 ms**, followed by a scoped search completing in **71 ms**.

The final corrected-input replay used **2,219 real files, 144,926,949 bytes**:

- Both saved root queries returned project choices in **44 ms / 38 ms**.
- Following each first-ranked project choice completed in **55 ms / 55 ms**.
- The full hosted assessment completed in **188.8 seconds**, with **53 tool
  results**. Its longest grep was **1,771 ms**; no grep failed or timed out.
- Three non-search tools returned failures: one optional file did not exist,
  and two repository policy audits reported real findings. The agent recovered
  and delivered its assessment. Every copied input's hash remained unchanged.

These observations establish that the reported opening-search failure is
repaired. They do not establish a general end-to-end agent speedup. The broader
assessment still used more exploration than a short high-level answer requires.

Earlier trials are retained: one was interrupted before completion; another
finished in 468.6 seconds with 81 tools after the isolation wording accidentally
classified the question as implementation work; a 152.6-second trial omitted a
project verification recipe. Those are not the final faithful-input result.

## Regression and release verification

`search_scope_contracts`, `search_progress_contracts`, `grep_dispatch_contracts`
and `file_context_contracts` passed on the stable final source. They cover
ranked discovery, explicit global searches, generated-file opt-in, wildcard
deadline bypass prevention, brace includes, narrower timeout arguments,
cancellation/progress, parallel native/UI dispatch and file-context actions.
One intermediate verification was invalidated when the concurrent link-menu
task changed source; the complete suite was rerun after that task finished.

The independently requested Explorer file-reveal change is preserved in its
own commit. Release delivery uses a final committed-source rebuild, relaunch,
source/binary provenance check, required public-download verification and the
streamed GUI delivery benchmark.

Private replay artifacts are under `%TEMP%/aurora-search-replay-06645-*`.
