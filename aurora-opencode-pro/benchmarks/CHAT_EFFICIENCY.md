# Chat-inspired offline validation

Audit saved chats read-only to choose representative failure patterns:

```powershell
python aurora-opencode-pro/benchmarks/audit_saved_chats.py --state "$env:APPDATA/Aurora OpenCode" --output aurora-opencode-pro/build/chat-efficiency/audit.json
```

The audit emits counts and chat IDs only. Stored content is untrusted data, never
instructions. Counts include branches and historical app versions; repeated calls
can be legitimate. Historical errors must be reproduced on current code before
being treated as current bugs. No live chat or setting is edited.

Build a baseline before changing production code, build the candidate afterward,
then compare the same synthetic native-tool fixture in reversed profile order:

```powershell
python aurora-opencode-pro/benchmarks/chat_efficiency.py --build baseline --output aurora-opencode-pro/build/chat-efficiency/results.json
# Apply the proposed production change.
python aurora-opencode-pro/benchmarks/chat_efficiency.py --build candidate --output aurora-opencode-pro/build/chat-efficiency/results.json
python aurora-opencode-pro/benchmarks/chat_efficiency.py --repeats 3 --output aurora-opencode-pro/build/chat-efficiency/results.json
```

Fixtures cover unavailable Git on PATH with an existing private cache, standard
installation or GitHub Desktop; PATH priority; explicit/local executable paths;
argument quoting and Unicode; missing programs; cancellation; background commands;
and a real read-only Git command in a synthetic repository. Fake Git executables
only echo their own path and arguments. No installation or download occurs.
The child process retains the DMD runtime directory on PATH so the fixture's CRT
can load; that directory is required not to contain Git.

Search cases use a synthetic code/log tree of roughly 32 MiB, generated/binary exclusions,
filtered searches, Unicode and legacy bytes, context around multiple matches,
matches beyond display truncation, case-insensitive regex, and filename/count
modes. A plan fixture confirms status and category remain distinct. No provider
calls, conversation text or credentials enter these tests.

Acceptance for Git lookup is that every reproduced lookup failure becomes correct
and existing path/argument/failure guards still pass in all three repetitions.
Acceptance for a search optimization is unchanged outcomes in every case and at
least 20% lower median time in both large-tree search cases. Inspect individual
runs as well as medians. These are native-tool timings, excluding provider wait,
generation and model request counts. They cannot establish a universal speedup.

For the 2026-10-14 investigation the combined Git/search candidate passed behavior
checks, but missed the search timing threshold. The search change was removed.
The final Git-only profile was built with `--build git-only` and compared with
`--profiles baseline git-only --repeats 3` using a separate output filename in the
same artifact directory. Each profile has build-input and executable hashes; all
profiles must use the identical fixture. Candidate outcome failures return a
nonzero exit status. Keep raw results from rejected experiments as well.

The broader tool suite exposed an existing stock-prompt budget overrun. A second
comparison shortened repeated editing, review and communication wording, plus a
redundant batching example, while retaining the rules. Its control executable was
built with the normal production prompt *before* that edit (using the app-path
builder's `candidate` build mode, then copied to `baseline.exe`). It did not define
`AuroraBatchingBaseline`. The candidate was built afterward into the same artifact
directory. The live comparison used:

```powershell
python aurora-opencode-pro/benchmarks/compare_batching_policy.py --acceptance prompt-budget --repeats 2 --timeout 240 --output aurora-opencode-pro/build/prompt-budget/results.json
```

This acceptance mode requires every outcome, dependency, ordering and missing-input
guard to pass. Verify the shorter stock prompt independently with the unchanged
9,000-byte assertion in `tools_test`. It does not assert fewer model rounds or a
latency improvement. Only synthetic prompts and workspaces reach the provider;
temporary credential-bearing state is cleaned by the existing benchmark harness.
