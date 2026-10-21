# Aurora Browser agent handoff

Paste the following prompt into the existing Aurora OpenCode Pro browser conversation. The implementation brief is the full contract; this prompt is its entry point.

---

Continue the native Aurora Browser and Aurora Web engine in:

`C:/Users/windows10/Documents/github_repositories/aurora-gui`

Read [the comprehensive implementation brief](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/docs/IMPLEMENTATION-BRIEF.md), especially sections 3–9 and 25. Preserve the original objective: implement the underlying browser mechanisms, load/render/interact with the real required site `https://boqsc.eu`, achieve general correctness on independent cases and other pages, deliver actual cross-platform behavior, and satisfy the CC0/0BSD licensing policy with provenance evidence.

Start with these actions:

1. Record current commit, relevant dirty files and source fingerprints. Preserve existing user changes and inspect concurrent work before accepting evidence.
2. Audit the current browser acceptance recipe. Correct incomplete input hashing, stale temporary probes, screenshot-only “interaction” steps and references that are merely earlier Aurora output. Retain useful smoke assertions and run them in an isolated profile.
3. Recheck the established independent references without recapturing them. From the repository root:

   ```powershell
   python .\aurora-opencode-pro\tools\capture-browser-reference.py --browser "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" --output .\aurora-opencode-pro\build\browser-reference-validation --verify-existing
   ```

4. Inspect the first current failure. The old box-model failure is historical evidence, not proof of the current state. Trace the earliest incorrect stage, reduce the case, state a falsifiable hypothesis, and fix the general mechanism.
5. Verify with current-source compilation, meaningful semantic assertions, independent render comparison and real interaction assertions. Use the saved native `verify` recipes and preserve receipts. A green build alone cannot complete this task.
6. Continue through the brief's ordered milestones. Keep a compact ledger of accepted outcomes, rejected hypotheses, current failure and next experiment. Change diagnosis when repeated work produces no improvement.

Do not add hostname-specific layout fixes, replace missing behavior with successful stubs, overwrite references to match Aurora, hide missing resources, omit required capabilities, or call an unrun platform verified.

Both browser packages and the Aurora-owned vendor packages now declare 0BSD for
source, and the repository CC0 grant covers first-party documentation and
content. Unicode, Microsoft Terminal MIT, DMD/Phobos and zlib terms remain
separate: a license label does not relicense those dependencies. Complete the
separately scoped distribution audit truthfully.

Treat certificate-chain validation, origin security, hostile-content containment/review, performance, licensing and actual platform evidence as release gates. Handshake signatures and hostname matching alone do not establish trusted HTTPS.

Proceed autonomously through already authorized reversible investigation, implementation and verification. Ask only for a concrete decision requiring the owner's authority or genuinely unavailable required input. Do not ask repeatedly whether to continue.

Report each verified behavior with its current source fingerprint and evidence. Claim the browser fully complete only when the mandatory browser profile, real-page journeys and final release checklist pass. Until then, state the achieved milestone and the exact remaining work.
