# Aurora Browser: implementation and completion brief

**Prepared:** 16 October 2026.  
**Intended executor:** Aurora OpenCode Pro working on the native Aurora Browser and Aurora Web engine.  
**Requested licensing target:** `0BSD` for implementation material and
`CC0-1.0` for documentation/content whose rights permit that grant, with a
separately verified distribution inventory.
**Repository:** `C:/Users/windows10/Documents/github_repositories/aurora-gui`.  
**Related conversation:** `t-m639276073661326566-0`, titled “web browser”.

### Reading map

| Start here | Sections |
| --- | --- |
| Objective, evidence and current implementation | 1–4 |
| CC0/0BSD provenance and completion contract | 5–6 |
| Architecture and reliable verification, including current recipe defects | 7–9 |
| HTML, DOM, CSS, layout, text and rendering | 10–14 |
| JavaScript, web APIs and interaction | 15–17 |
| Networking, TLS and browser security | 18–20 |
| Runtime/agent performance and actual platform support | 21–22 |
| Test corpus and durable working state | 23–24 |
| Ordered implementation milestones and first work packet | 25 |
| Packaging, final gates and evidence reports | 26–29 |
| Copy-ready executor instruction | 30 |

## 1. The instruction to carry forward

Implement Aurora Browser as a real, cross-platform browser using the project's own engine. Complete the underlying browser behavior needed to retrieve, parse, style, lay out, paint, script, and interact with real web pages correctly. Preserve the user's intention to build the fundamental parts. Carry the licensing migration through to an auditable result under the requested CC0/0BSD terms.

Treat `https://boqsc.eu` as a required integration target inherited from the browser conversation. The browser must load the real page and its resources, reproduce its intended presentation, and support its interactions. Keep independent local fixtures and other sites in the acceptance corpus so that implementation remains general.

The goal includes quality, consistency, efficiency, and runtime performance. A successful compiler invocation, a pleasant screenshot of a demonstration page, or a large collection of recently added functions is insufficient evidence of completion. Each milestone must establish observable behavior against an independent expectation and preserve previously established behavior.

This brief is an execution contract and an engineering roadmap. It does not assert that the present browser is complete, secure, or already available under the requested licenses. It also does not promise a particular completion time. A native browser engine, JavaScript implementation, and secure network stack are substantial systems. The practical way to finish is to make the work finite, dependency ordered, measurable, and resistant to false success.

Use the following priority order when tradeoffs arise:

1. Preserve the user's objective, existing work, and provenance.
2. Establish correct, secure behavior with independent evidence.
3. Implement reusable engine mechanisms that resolve classes of failures.
4. Remove measured performance bottlenecks while preserving correctness.
5. Improve developer and agent throughput through reproducible tools.
6. Polish presentation and convenience features after their foundations work.

Do not silently remove fonts, gradients, image formats, scripting, layout modes, or interaction behavior from the objective because implementation is difficult. Classify gaps explicitly and keep them in the completion backlog. A milestone can be complete while the browser remains incomplete.

## 2. How to use this document

Read sections 3–9 before editing. They establish the factual baseline, licensing policy, completion contract, architecture, and verification loop. Then work through the milestones in section 25, using the subsystem requirements in sections 10–24 as the implementation checklist.

At the beginning of each work session:

1. Inspect the actual checkout, branch, commit, and dirty files.
2. Read the current completion ledger and the most recent verification receipt.
3. Reproduce the highest priority unresolved failure with current source.
4. Select one bounded, dependency coherent change.
5. State the failing expectation and the evidence that will establish success.
6. Implement, verify, inspect the result, and update the ledger.

Proceed autonomously through reversible investigation, fixtures, implementation, and verification that the user has authorized. Ask for a decision only when a material unresolved choice actually requires the user's authority, such as expanding the allowed distribution licenses or abandoning an explicit requirement. Describe the concrete choice and the work already completed. Do not repeatedly ask whether to continue ordinary implementation.

This document does not authorize changing unrelated chats, sending messages to people, publishing private conversation data, replacing other projects' policies, or discarding user modifications. A browser implementation task and an Aurora OpenCode Pro application rebuild have separate ownership and acceptance evidence.

The document uses three kinds of statement:

- **Observed:** established by inspected source or a saved result identified below.
- **Required:** an acceptance condition for future implementation.
- **Proposed:** a design or organizational choice that should be validated before adoption.

Keep these distinctions in future status reports. An implementation plan is not an implementation result.

## 3. What the previous long run actually teaches

The audited conversation snapshot spans approximately 34.53 hours, including waits and interruptions. It contains 5,308 tool calls over 3,504 tool rounds, 1,015 patch calls, 2,438 run calls, and 357 plan updates. Its median reported input context was 246,195 tokens. These figures describe the saved snapshot, not a current live total and not a billing calculation.

The audit found a concrete verification ownership defect: successful builds in the real repository or a temporary probe directory were not accepted for a chat whose recorded workspace differed. It also found that rebuild guidance could cross chat boundaries and that tool novelty could count as progress even when the browser's result did not improve.

Aurora OpenCode Pro received changes addressing those mechanisms in commit `d882eb562bb1460cefa4b2f337585667f489e838`. Those changes improve the working process; they do not implement the missing browser standards. The relevant execution guide is [Task execution and verification](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/docs/task-verification.md).

The critical browser lesson is that existing green tests did not predict correct pixels. A saved verification run on 16 October passed tests reported as “38 modules passed unittests”, then failed the first independent 320 × 240 box-model reference with 14,200 mismatched pixels out of 76,800. Its source-input hash was `8A28DF2DFFBE00B6086BD1F423165CD842639E7FF63E5FB90EC33DDD8ACD39D3`. The result and image pair are local historical evidence:

- [Comparison receipt](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/build/browser-reference-validation/comparison.json).
- [Independent reference](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/build/browser-reference-validation/comparison.json.reference.png).
- [Aurora output](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/build/browser-reference-validation/comparison.json.actual.png).

The image pair showed incorrect border color and outer geometry. The runner stopped at that first failure, so that receipt establishes no result for later visual cases or interaction assertions.

The checkout inspected while drafting this brief was at `68fd43c1053c502e5f207e49f8e8207ddee46760`, with a local modification to `auroraweb.layout`. It therefore differs from the historical verification input. Re-run the established corpus before describing that failure as current or fixed. Do not overwrite its frozen references to obtain a green result.

Adopt these process changes permanently:

| Previous failure pattern | Required replacement |
| --- | --- |
| Rebuild repeatedly and infer quality from exit status | Compare the current artifact with explicit semantic, visual, and interaction expectations |
| Read and patch large files without a discriminating hypothesis | Reduce a failure, identify its owning stage, and test a causal explanation |
| Count tool use and plan updates as progress | Count accepted behaviors, closed defects, and verified performance improvements |
| Revisit an old theory after context compaction | Preserve a short evidence ledger with rejected hypotheses and their counterexamples |
| Patch one site's appearance directly | Implement the underlying rule and exercise it with unrelated fixtures |
| Treat a screenshot as self-explanatory | Record viewport, scale, fonts, load state, source hash, and reference provenance |
| Continue indefinitely without changing diagnosis | After repeated non-improvement, change the experiment or seek a bounded diagnostic review |

## 4. The current source map and its limits

The following map identifies inspected implementation locations. Presence of code means there is something to evaluate and improve; it does not establish standards conformance.

| Area | Existing source | Observed starting point | What must be established |
| --- | --- | --- | --- |
| Browser host | [Application entry](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/source/app.d), [browser UI](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/source/aurorabrowser/appui.d) | Native Aurora window, page view, navigation and tab-related host code | End-to-end loading, lifecycle, input, errors, responsiveness and platform behavior |
| Page coordination | [WebPage](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/package.d) | Coordinates parsing, resources, scripts, layout and painting | Explicit document lifecycle, invalidation, asynchronous ownership and deterministic test control |
| HTML | [HTML parser](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/html.d) | A pragmatic parser; its header explicitly disclaims full HTML tree construction | Tokenizer/tree-builder states, malformed input behavior, foreign content and fragment parsing |
| DOM and style data | [DOM](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/dom.d) | Tree, attributes, computed style and geometry records | Tree invariants, identity, mutation semantics, typed style and consistent geometry |
| CSS | [CSS](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/css.d) | Rule parsing, matching, cascade and media-related code | A tested property pipeline and correct cascade across contexts |
| Layout | [Layout](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/layout.d) | Substantial layout code, including several formatting modes | Correct sizes, positions, intrinsic contributions, fragmentation and incremental invalidation |
| Painting | [Paint](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/paint.d) | Box, text, image, decoration and effect rendering | Correct stacking, clipping, colors, transforms and agreement with hit testing |
| Text | [Shaping integration](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/shaping.d), Aurora text modules | Shared memoized shaping over the GUI library's text system | Correct fonts, script shaping, line breaking, fallback, cache keys and invalidation |
| JavaScript | [Interpreter](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/js.d) | A tree-walking ECMAScript subset, explicitly described as not fully conformant | Language semantics and host integration sufficient for the declared browser profile |
| Web bindings | [DOM bindings](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/dombind.d) | Many host APIs and event/fetch-related paths | Actual semantics, exceptions, identity, promises, origins and lifecycle |
| Scheduling | [Event loop](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/eventloop.d) | Task queues, timers, microtasks and rendering hooks | Ordering, fairness, cancellation, time control and resistance to runaway content |
| Interaction | [Interaction](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/interact.d) | Hit testing and page interaction | Pointer, keyboard, focus, form behavior, selection and transform/clip consistency |
| HTTP and URL handling | [Network](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/net.d) | Owned HTTP/1.1 code, redirects, cookies and compression paths | URL conformance, robust framing, fetch policy, caching and adversarial limits |
| TCP | [Transport](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/transport.d) | `std.socket` byte transport with nonblocking socket operations and deadlines | DNS/connect/read/write cancellation and UI integration on every platform |
| TLS and cryptography | [TLS](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/tls.d), [crypto](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/crypto.d) | Native TLS 1.3, handshake-signature verification and certificate DNS-name matching | Trust-chain validation, certificate policy, protocol robustness and security review |
| SVG | [SVG](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/source/auroraweb/svg.d) | An owned SVG implementation | Geometry, inherited styling, viewBox, transforms, clipping, text and resource behavior |
| Raster codecs | [Aurora image layer](C:/Users/windows10/Documents/github_repositories/aurora-gui/vendor/aurora-d-0.4.5/source/aurora/image.d) and its codec modules | PNG and image-format dispatch, plus other codec paths | Format-specific coverage, malformed-input limits, color/alpha behavior and licensing |

Comments in this checkout are not uniformly current. For example, browser UI comments still mention WinINet while the inspected network implementation uses the owned byte transport. The TLS header understates work now present in its body: `CertificateVerify` signatures and DNS-name matching have implementations. Conversely, neither those functions nor encryption establish trust-chain validation. Resolve claims by inspecting executable paths and running relevant tests, then update stale comments with the change they describe.

Both [engine package metadata](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-web/dub.json) and [browser package metadata](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/dub.json) now declare `0BSD` for first-party source. They include Aurora-D source directly. Its [license](C:/Users/windows10/Documents/github_repositories/aurora-gui/vendor/aurora-d-0.4.5/LICENSE) is 0BSD, and it carries a separate [Unicode license](C:/Users/windows10/Documents/github_repositories/aurora-gui/vendor/aurora-d-0.4.5/LICENSE-UNICODE.txt). The strict distribution target therefore remains future work, not a description of current packaging.

## 5. Licensing and provenance are part of completion

### 5.1 The requested grant

Use `0BSD` for original source code and `CC0-1.0` for original documentation and
content that their rights holders can offer under those terms. Do not invent a
combined legal text or claim that two different licenses are identical. Keep the
exact official texts separately and explain the split in the project's license
overview. The canonical references are [CC0 1.0 legal code](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en) and [BSD Zero Clause text](https://spdx.org/licenses/0BSD.html).

CC0 seeks a waiver of covered rights and provides a fallback license where needed; its text expressly leaves patent and trademark rights unaffected. The 0BSD text gives a broad copyright permission and warranty disclaimer without the notice-retention conditions found in multi-clause BSD licenses. Neither is evidence that third-party material in this repository has been relicensed.

User intent establishes the desired project policy. A complete migration also requires evidence of rights for existing contributions. An AI assistant generating a patch is not a provenance audit. Record the source and applicable grant of material actually incorporated, including generated data and imported examples.

### 5.2 Separate two claims that are often confused

**Project-source claim:** browser-owned source is available under `0BSD`, and
browser-owned documentation/content under `CC0-1.0`, with other components
identified separately.

**Strict distribution claim:** all redistributable implementation and data included in a particular source/binary package meet the user's strict CC0/0BSD-only condition.

The second claim is stronger. Do not use it unless the distribution inventory proves it. If the user's requirement is interpreted as strict-only, preserve that interpretation until the owner explicitly accepts exceptions. Ordinary permissive licenses such as Boost, Unicode, zlib or BSD-3-Clause must not be relabeled as 0BSD. A mixed-license package may be lawful and useful while still failing the strict-only target.

The existing D runtime/standard-library implementation, compiler support libraries, compression implementation, GUI library, fonts, Unicode tables, certificate data, image codecs, icons and packaged runtime DLLs all need classification. `std.zlib` and `etc.c.zlib` imports are visible in current source. Calling them through a D module does not establish that the implementation is original D or CC0/0BSD. Inspect actual linkage and shipped files.

For a conflicting component, resolve it by obtaining an applicable grant from the relevant rights holder, independently replacing it, removing a genuinely unnecessary dependency, or obtaining an explicit owner decision to permit the existing license. Preserve the conflict in the ledger until resolved. A wrapper or a changed SPDX line does not resolve it.

### 5.3 Build a per-artifact inventory

Create a machine-readable inventory with at least these fields:

```json
{
  "component": "component name",
  "versionOrCommit": "pinned identifier",
  "paths": ["paths covered by this entry"],
  "origin": "original work, upstream source, generator, or installed system facility",
  "rightsEvidence": "grant, license file, provenance record, or unresolved",
  "licenseExpression": "verified SPDX expression or NOASSERTION",
  "role": "runtime-source | bundled-binary | generated-data | asset | build-only | test-only | system",
  "redistributed": false,
  "strictTargetSatisfied": false,
  "resolution": "specific remaining action"
}
```

Include transitive and statically linked code, not only DUB dependencies. Generate a final manifest from the actual release directory and archive contents. A build-only component can become a runtime distribution issue if its helper DLL, test data, font, or binary is copied into the package.

Treat generated tables as artifacts with their own input provenance. Retain the generator version, input hashes, source URLs and applicable data terms. Unicode publishes its own [license text](https://www.unicode.org/license.txt); regenerating Unicode tables does not by itself remove the terms applicable to their inputs.

External operating-system facilities and separately installed test browsers should be identified accurately. An installed Edge reference browser is a test oracle; it is not the Aurora rendering engine and must not be bundled or advertised as CC0/0BSD. An operating-system API is a platform dependency; copying an associated runtime binary introduces a separate distribution question.

### 5.4 Test licenses remain distinct

The Web Platform Tests repository's [top-level license](https://raw.githubusercontent.com/web-platform-tests/wpt/master/LICENSE.md) is BSD-3-Clause. Per-file and bundled resource terms also require inspection. Do not copy it into a strict CC0/0BSD source tree and label it 0BSD. Use a separately acquired, pinned test checkout with its notices intact, or write original local assertions from the required behavior. Keep external suite code outside the redistributable product unless the accepted policy permits its terms.

Apply the same review to Test262, cryptographic vectors, fonts, sample images, public-suffix data, certificates and captured site assets. A test resource being publicly downloadable is not permission to redistribute it under different terms. Keep private site captures and user content out of public release artifacts unless their provenance supports inclusion.

### 5.5 Licensing exit conditions

The migration is complete only when:

- Covered first-party files and package metadata consistently state the approved grant.
- Exact license texts and a clear coverage statement are present.
- Existing contributions have documented provenance or a recorded unresolved blocker.
- All distributed components have an inventory entry and verified terms.
- Conflicts with the selected strictness policy are resolved rather than hidden.
- Source and binary archives have been inspected after packaging.
- Release notes state the license scope truthfully.

Do not modify unrelated Aurora packages' licenses as a side effect of the browser task. Shared code needs its own rights and dependency analysis.

## 6. Define completion without shrinking the objective

Create a versioned `BrowserCompletionProfile` before claiming a release complete. This is a finite contract for the intended browser version, with a backlog for continued standards evolution. It must preserve the capabilities the user already requested.

The profile must name:

1. Supported desktop platforms, architectures, build modes and minimum system environments.
2. The HTML, DOM, CSS, ECMAScript and web API behaviors being claimed.
3. Network protocols, certificate policy, storage and origin security guarantees.
4. Image, font, SVG, canvas and media format support.
5. Desktop usability and accessibility requirements.
6. The frozen conformance-suite revisions and selected test manifests.
7. The real-page corpus, interactions, viewports and resource expectations.
8. Performance budgets, benchmark machines, input sizes and measurement procedures.
9. The license scope and exact distribution contents.
10. Known unsupported features and their relationship to the user's objective.

A profile cannot make an incomplete requested behavior disappear by omitting it. Unresolved scope decisions remain visible. A release claiming broad modern-browser compatibility needs a correspondingly broad profile; passing one site's static rendering cannot support that claim.

Use these completion levels in status reports:

| Level | Meaning | Permitted claim |
| --- | --- | --- |
| Infrastructure ready | Reproduction, provenance, build and verification tools work | “The implementation workflow is ready” |
| Local behavior verified | One general rule passes independent cases and regression checks | “This behavior is implemented and verified for these cases” |
| Required site verified | Frozen and live target-page journeys pass at the declared environments | “The required site works under the recorded conditions” |
| Browser profile verified | Every required feature group and platform gate passes | “This version meets its documented browser profile” |
| Release delivered | Profile, security, licensing, packaging and delivery gates pass | “This browser release is complete for the published profile” |

The original full-browser objective is fulfilled at the final two levels, with no unresolved mandatory exclusions. Intermediate success is valuable but must be named accurately.

For every required feature, record `unknown`, `missing`, `partial`, `failing`, or `verified`. A `verified` entry must link to current evidence. `Not run`, `unsupported`, `skipped` and `expected failure` do not count as passes. Publish both coverage and pass rate so that selecting a tiny subset cannot masquerade as full conformance.

## 7. Architecture: make ownership and invariants explicit

Preserve the useful native implementation. Refactor only where a demonstrated coupling or missing abstraction prevents correctness, testing, or performance. A wholesale rewrite without a working comparison loop would repeat the previous failure pattern.

The proposed data flow is:

```text
Browser host / navigation controller
    -> URL + origin + navigation generation
    -> resource loader -> transport / TLS / HTTP / cache
    -> decoding + HTML tokenizer + tree builder
    -> DOM + document lifecycle + script host
    -> stylesheet parsing + cascade + computed style
    -> layout / fragments / scroll geometry
    -> display list + stacking + clips + transforms
    -> raster / compositor -> native surface

Input -> host coordinate conversion -> hit testing -> DOM dispatch/default action
DOM/style/resource changes -> invalidation -> scheduled update -> paint
```

Define these boundaries before adding more special cases:

- **Document ownership:** one document owns its DOM, script realm, resources and lifecycle state.
- **Navigation ownership:** every asynchronous completion carries a navigation/document generation; stale results cannot mutate a replaced page.
- **Resource ownership:** a request has a URL, origin policy, cancellation token, byte budget and terminal outcome.
- **Style ownership:** specified values, computed values and used values are distinguishable.
- **Geometry ownership:** layout produces geometry; paint and hit testing consume a consistent representation.
- **Scheduling ownership:** the event loop decides when tasks, microtasks, animation callbacks and rendering occur.
- **Platform ownership:** windowing, input delivery, system font discovery, secure randomness and explicitly chosen trust-store access belong behind narrow adapters.

The platform boundary may use operating-system facilities required for a desktop application. It must not substitute Chromium, WebView, CEF, a hidden remote renderer, or a platform HTTP/TLS implementation for the owned core where the user's native-engine constraint applies. Secure system randomness is a necessary primitive, not a replacement browser engine.

Add original, small architecture records when an interface changes. Each record should name the invariant, alternatives considered, compatibility consequences and validating tests. Avoid broad abstractions that do not yet serve a demonstrated need.

### Geometry invariant

Current paint code documents `box.x`/`box.y` as the border-box origin and `box.width`/`box.height` as content dimensions. Audit every producer and consumer against that convention. If it is retained, provide named helpers for content, padding, border and margin rectangles rather than repeating arithmetic across layout, paint, scrolling and hit testing.

Use a layout-unit representation capable of retaining fractional CSS coordinates. Round at defined rasterization boundaries. Early integer truncation can create accumulating width, line-wrap and alignment errors. Introduce this deliberately, with differential geometry tests and overflow limits, rather than replacing numeric types throughout the engine at once.

### Failure invariant

Malformed content can fail a resource, document operation or script evaluation. It must not silently convert a missing capability into successful empty output, corrupt another tab, escape the origin boundary, or terminate the application. Error outcomes need structured reasons and testable behavior.

## 8. The evidence loop that every change must follow

### 8.1 First establish the failure

Before patching, save a reproduction that fails for the reported reason. For a rendering defect, obtain independent expected geometry or pixels. For a script defect, assert values, exceptions and observable ordering. For a network defect, use a controlled peer and inspect bytes or response state. For a performance defect, identify an input, stage and measured regression.

A local test that merely repeats the implementation's current formula is weak evidence. Add counterexamples capable of distinguishing the intended rule from the proposed shortcut. Include at least one neighboring case that should remain unchanged.

### 8.2 Reduce and locate the owning stage

For a complex site failure, preserve the original captured state privately, then remove unrelated HTML, styles, scripts and resources until the failure is small. Preserve any relevant base URL, encoding, viewport and font assumptions. Keep the minimal case independent of the target hostname.

Inspect the earliest stage whose output differs:

```text
response bytes -> decoded text -> DOM tree -> matched declarations
-> computed values -> used geometry -> display ordering -> pixels
-> hit target -> event/default action -> resulting state
```

For example, an incorrect border color may arise from declaration parsing, shorthand expansion, cascade, computed style, side-color resolution or painting. A width error may arise from shorthand expansion, box sizing, percentages, intrinsic size or double-counted edges. Do not patch painting to compensate for incorrect layout.

### 8.3 State a falsifiable hypothesis

Write one sentence naming the suspected cause, then an experiment that would disprove it. Example: “The shorthand parser applies a numeric token twice, so a longhand-only case should have correct geometry while the equivalent shorthand case fails.” If both fail identically, revise the hypothesis before adding compensation code.

### 8.4 Implement the general rule

Change the owning layer. Reuse one resolver or representation when multiple callers require the same semantics. Add tests that cover the original failure, equivalent syntax, nested contexts, boundary values and a negative case. Avoid hostname checks, element-ID checks, injected target-site CSS, absolute screenshot coordinates or cached page pictures in product logic.

### 8.5 Verify from narrow to broad

Run the smallest meaningful check first, then the affected subsystem suite, the frozen browser corpus, and relevant real-page journeys. Reuse already built tools when their source fingerprint is unchanged. Rebuild tools when their inputs changed. Broaden testing because dependencies or risks justify it, not because repeating an unrelated build feels reassuring.

A change that alters shared geometry, style application, text metrics, DOM identity or scheduling needs integration coverage beyond the immediate fixture. A comment-only correction does not require rebuilding the browser.

### 8.6 Inspect and record

Read the receipt and inspect failed visual pairs. On success, record the input hash, test identifiers, reference provenance, measured result, changed files and any remaining limitations. Update the completion ledger only after the evidence is accepted. If source changes during verification, the result belongs to an earlier revision and must be rerun for the final candidate.

## 9. Use the verification tools already available

Aurora OpenCode Pro has a native `verify` tool for a saved finite recipe. It records typed evidence: `compile`, `tests`, `render`, and `interaction`; `prepare` executes supporting steps without independently certifying behavior. Browser work requiring rendering and interaction needs all four evidence classes in the relevant acceptance recipe.

The runner hashes source inputs and the recipe before and after execution, freezes reference hashes, rejects stale or detached results, compares decoded images and attaches failed reference/actual frames. Its assertions are only as complete as the recipe author makes them. A command labeled `interaction` must actually assert interaction outcomes.

### Existing independent corpus

The original fixtures are at [browser fixtures](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/tests/browser-fixtures/box-model.html), with sibling flex/grid, SVG-position and interaction cases. The tools are [reference capture](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/tools/capture-browser-reference.py), [page probe](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/tools/browser-probe.d), and [engine check entry](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-opencode-pro/tools/browser-engine-check.d).

From the repository root, recheck the established references with:

```powershell
python .\aurora-opencode-pro\tools\capture-browser-reference.py --browser "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" --output .\aurora-opencode-pro\build\browser-reference-validation --verify-existing
```

The installed browser argument is currently required even when rechecking existing references; choose a valid installed path. `--verify-existing` enables verification without recapturing images. This is a Windows/DMD harness with explicitly listed Windows libraries. Do not describe it as an already portable cross-platform test runner. Extend the harness or provide equivalent platform-specific launchers when enabling Linux and macOS gates.

To establish a new reference corpus, select an installed reference browser explicitly and use a new output directory:

```powershell
python .\aurora-opencode-pro\tools\capture-browser-reference.py --browser "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" --output .\aurora-opencode-pro\build\browser-references-new --verify
```

The script captures local originals with a private browser profile. Its manifest includes HTML and image hashes, browser identity, viewport and device scale. The current default viewport is 320 × 240. Preserve the manifest's dimensions when rechecking an existing corpus; validate harness behavior before using other sizes.

The generated recipe can be supplied to Aurora's native tool, for example:

```json
{"recipe":"aurora-opencode-pro/build/browser-reference-validation/verify.json"}
```

Current recipe limits include 16 steps, 64 input roots, 20,000 traversed entries, 64 MiB of source input, and 16 million decoded pixels. These are runner limits, not browser-completion limits. Split a growing corpus into named recipes and aggregate their receipts with a tested fail-closed summary. Do not omit required cases merely to fit one recipe. Large corpora and full-page captures may require a separately designed bounded runner.

### Reference policy

Use exact comparison for the existing font-free, integer-coordinate fixtures. Do not loosen tolerances to hide wrong geometry or colors. Text and antialiasing cases may need independently justified per-case tolerances or semantic geometry assertions. Record the reason, channel threshold and allowed mismatch count. The current native runner permits at most 2% differing pixels and channel tolerance up to 8; this does not establish that those allowances are appropriate for a particular case.

Freeze references before the implementation run. A changed reference requires its own review and an explanation of which expectation changed. Reference-browser output can contain bugs or platform variation; when oracles disagree, consult the relevant rule, use a second independent engine where available, and preserve the disagreement as a test investigation.

The [WPT reftest guide](https://web-platform-tests.org/writing-tests/reftests.html) provides an established model for visual assertions and controlled comparison timing. Adopt the principle of explicit readiness: fonts, resource outcomes, script setup and pending paints must reach the recorded test state before capture. A fixed sleep alone is insufficient evidence that a page is ready.

### A currently inadequate browser acceptance recipe

The inspected [browser render recipe](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/tests/verify-render.json) needs correction before it can establish the requested result. It was modified locally during drafting, so inspect its current contents before acting. The inspected version has these concrete gaps:

1. Its input list names selected engine files but omits other compiled inputs, including paint, JavaScript, browser host, vendor source and the smoke-test source. A receipt cannot establish final-source freshness if relevant inputs are absent from its fingerprint.
2. Its `interaction` step runs a temporary `pageshot.exe` with URL, dimensions and output image arguments. The recipe shows no interaction assertion in that command. A capture step belongs in `prepare` unless the executable demonstrably performs and asserts the required interactions.
3. The temporary page-capture executable is not rebuilt by that recipe. Its source/binary relationship therefore is not established by the run.
4. Its reference description identifies a page captured after an Aurora fix and inspected by eye; it does not establish an independent rendering oracle. Comparing Aurora with its own earlier image is a regression check, not proof of browser correctness.
5. It uses live site content and machine-specific temporary paths. A network/content change can create a difference unrelated to an engine change, while another machine cannot reproduce the paths.
6. It gives compilation a 30-minute timeout and test/capture steps 10-minute timeouts without documented baselines. Measure normal durations and select bounded, justified limits that expose hangs promptly.

The [headless smoke suite](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/tests/headless_smoke.d) contains useful native chrome and page interaction assertions. Reuse and strengthen them. Execute tests in an isolated profile; the current suite's bookmark backup behavior is a reason to avoid pointing it at a real user's data directory.

Replace the acceptance recipe's weak evidence with complete source inputs, freshly built probes, frozen original fixtures or appropriately handled site snapshots, an independent reference, real interaction assertions and per-stage measured deadlines. Keep any useful Aurora-to-Aurora snapshots clearly labeled as regression baselines. This is an early milestone, not a reason to discard the existing implementation.

## 10. HTML, decoding and DOM foundations

**Objective:** the engine must construct the correct document before attempting to repair its appearance.

Use the [HTML Standard](https://html.spec.whatwg.org/multipage/), [DOM Standard](https://dom.spec.whatwg.org/) and [Encoding Standard](https://encoding.spec.whatwg.org/) as implementation references. Record the revisions used by the conformance manifest. The checklist below is the proposed engineering decomposition, not a claim that the present engine implements those standards.

### HTML and decoding work

- Separate byte decoding, tokenization and tree construction so each can be tested independently.
- Establish BOM, declared charset, default decoding and malformed-sequence behavior. Do not assume every response is valid UTF-8.
- Cover data, tag, attribute, comment, doctype, character-reference, raw-text, RCDATA and script-related tokenizer states.
- Implement the tree-builder insertion modes required by ordinary documents, tables, templates, select elements and foreign content.
- Preserve namespaces, case rules, void-element behavior and fragment parsing context.
- Handle malformed nesting and parser recovery deterministically. Include formatting-element reconstruction and table foster-parenting cases in the roadmap.
- Distinguish parser-created scripts, inserted scripts, blocking stylesheets and dynamic DOM insertion.
- Define standards/quirks mode selection and its effect on layout.
- Bound nesting, token sizes, attribute counts and total document resource use without accepting corrupted state.

Do not normalize malformed HTML into a hand-invented “reasonable” tree and then style around that difference. Compare tree serialization for the reduced fixture before investigating layout.

### DOM work

- Maintain parent/child/sibling consistency through insert, remove, replace, move and fragment operations.
- Preserve stable node identity across JavaScript wrappers and DOM queries.
- Implement text-node behavior, document order, namespaces, attributes and reflected properties deliberately.
- Specify live versus static collection behavior for each exposed API.
- Cover selectors, traversal, event targets, cloning, document fragments, template contents and ownership changes.
- Ensure mutations invalidate the correct style, layout, paint and resource state.
- Implement mutation observers and relevant scheduling once required by the profile.
- Treat disconnected subtrees, stale wrappers and navigation teardown as lifecycle cases.

**Exit evidence:** tree expectations for valid and malformed documents; mutation invariant checks; original host API assertions; selected external conformance results with their denominator; no unexpected crash or retained old-document mutation after navigation.

## 11. CSS parsing, cascade and value semantics

**Objective:** each supported declaration must survive a complete path from syntax to observable behavior. Use the [CSS Snapshot](https://www.w3.org/TR/css/) to organize module coverage, and the [cascade specification](https://www.w3.org/TR/css-cascade-5/) to resolve precedence questions. Pin the module versions used rather than advertising an undefined “CSS support” percentage.

Build a property coverage registry. For each property, record:

```text
accepted syntax -> expansion -> cascade participation -> inheritance/default
-> computed value -> used-value resolution -> layout/paint effect
-> invalidation -> exposed value -> tests
```

The registry should include initial value, inheritance, percentages, logical/physical mapping, animation implications and unsupported syntax. A parser recognizing a property name is not implementation of the property.

### Parsing and matching

- Tokenize strings, comments, escapes, identifiers, numbers, dimensions, URLs and nested functions consistently.
- Recover from invalid declarations and rules without corrupting adjacent valid content.
- Parse selector lists, combinators, attribute selectors and required pseudo-classes/pseudo-elements.
- Compute specificity structurally and preserve source order.
- Cover matching after class, attribute, ancestor, sibling, focus and state changes.
- Keep selector indexing as an optimization with a correct slow reference path for differential tests.
- Handle imports, media conditions, support conditions, namespaces and required rule groups.

### Cascade and values

- Implement user-agent defaults, author rules, inline declarations and required origin/importance ordering.
- Cover inheritance, initial/unset/revert behavior, layers where required, and invalid computed values.
- Expand shorthands consistently; a shorthand must interact correctly with earlier and later longhands.
- Resolve custom-property inheritance, token substitution, cycles, fallbacks and invalid values.
- Use typed values for lengths, percentages, colors, enums and compound records rather than repeatedly interpreting unrelated strings at every stage.
- Support the units and math functions needed by the profile, including font-relative and viewport-dependent values.
- Resolve percentages against the correct containing dimension and definite/indefinite size rules.
- Cover current color, transparency, inherited colors and per-side border colors.

A change to `ComputedStyle` requires an audit of copying, inheritance, equality, cache keys, resetting and all consumers. Avoid a growing manual field list that silently omits new properties. Generate or centralize metadata where that measurably improves consistency.

### Required high-value coverage

Complete the core property groups together: display and positioning; box sizing and edges; widths/heights and min/max constraints; typography and whitespace; overflow and scrolling; flex/grid; backgrounds and gradients; borders and radii; transforms and stacking; visibility and opacity; lists/tables; replaced-element sizing; object fit/position; generated content; required animations/transitions; responsive conditions; and logical properties.

**Exit evidence:** original syntax/cascade/value cases, independent computed-style assertions, equivalent shorthand/longhand renders, state-change invalidation tests and relevant conformance results. Unknown declarations must be handled according to the chosen semantics, not converted into plausible numeric zeros.

## 12. Layout: solve geometry systematically

**Objective:** one consistent geometry model must support painting, scrolling, hit testing and JavaScript measurements. The [CSS Box Model](https://www.w3.org/TR/css-box-3/) is an initial reference; consult the applicable formatting-module specification for each later feature.

### 12.1 Begin with the established box fixture

The existing font-free fixture declares an outer content width of 120 CSS px, content height of 70, padding of 11 on all sides, and solid border of 7 on all sides. Under its content-box conditions:

```text
border-box width  = 120 + 11 + 11 + 7 + 7 = 156
border-box height =  70 + 11 + 11 + 7 + 7 = 106
border origin     = (23, 17)
content origin    = (23 + 7 + 11, 17 + 7 + 11) = (41, 35)
border color      = #123456
background        = #fedcba
inner content     = 60 by 30, #00aa66
```

Use those values to trace the current implementation. Check declaration parsing, computed fields, edge resolution, layout assignment and paint inputs. Test the equivalent longhands, asymmetric edges, `border-box`, a nested container, zero edges and a resized viewport. Do not assume the historical error has only one cause or remains unchanged in current source.

### 12.2 Normal flow and sizing

- Establish containing blocks and available inline/block sizes explicitly.
- Implement auto sizing, min/max clamping and definite versus indefinite dimensions.
- Cover percentage sizes, aspect ratios, replaced elements and intrinsic width/height contributions.
- Implement block flow, anonymous boxes, margin collapsing, floats and clearance.
- Cover inline formatting with fragments, whitespace processing, line boxes, baselines, vertical alignment and bidirectional ordering.
- Preserve subpixel positions through layout; specify where integer surface coordinates are produced.
- Keep document, viewport, scroll and local coordinates distinct.
- Ensure overflow geometry includes content and effects that actually participate in scrolling.

### 12.3 Flexbox

Implement the algorithm as coherent phases: item collection and order, base/hypothetical sizing, line collection, flexible-length resolution, cross-size calculation, alignment and final positioning. Cover intrinsic minimums, `min-width: auto`, growing and shrinking, wrap, gap, direction, alignment, auto margins and nested percentage sizing.

A row of fixed-width colored children is a useful initial fixture. It does not establish flexible sizing or wrapping correctness. Add cases where naive equal distribution, unconditional shrinking or treating all sizes as definite would fail.

### 12.4 Grid

Separate explicit/implicit tracks, placement, track sizing and alignment. Cover fixed, fractional, intrinsic and minmax tracks, gaps, spanning items, auto placement, dense placement where claimed, named lines/areas and nested sizing. Add cross-axis and overflow cases. Track-size algorithms need geometry assertions, not only a screenshot with a few rectangular cells.

### 12.5 Positioned, table and fragmented content

Cover relative offsets, absolute containing blocks, fixed positioning, sticky constraints, insets, static positions, transformed ancestors and stacking interactions. Implement tables with row/column/cell sizing and border behavior rather than treating them as ordinary blocks. Address multicolumn and other fragmentation required by the profile in a separately tested stage.

### 12.6 Layout architecture and termination

Use explicit formatting contexts and layout result records to reduce repeated cross-mode special cases. Cache intrinsic measurements only with complete dependency keys. Detect cyclic or repeated invalidation, bound pathological work, and make iterative resolution rules explicit. Layout must converge or produce a controlled failure; it must not stall the desktop UI indefinitely.

**Exit evidence:** numeric geometry assertions, exact font-free images, text-aware references, multiple viewports and nested mode combinations. Include layout after DOM/style/resource changes and ensure unaffected branches retain correct geometry.

## 13. Text, fonts and line breaking

**Objective:** text must have correct metrics and visual behavior across the supported scripts and fonts. Text is part of layout correctness, not optional decoration.

Audit the GUI text implementation and the engine's integration together. Establish font-family resolution, generic families, weight/style/stretch matching, fallback, size adjustment and font loading. Support the declared web-font formats with input bounds and documented provenance. System font discovery must behave predictably on Windows, Linux and macOS.

Implement and test:

- Font metrics, ascent/descent, line height, baseline alignment and glyph advances.
- Grapheme segmentation, shaping clusters, script selection and bidirectional runs.
- Required OpenType substitutions/positioning, kerning and variation behavior.
- Whitespace collapse/preservation, tabs, wrapping, word breaking and line breaking.
- Letter/word spacing, text alignment, decoration, overflow and ellipsis.
- Mixed scripts, combining marks, emoji/variation sequences and fallback boundaries.
- Selection and caret positions mapped through shaped clusters.

Current shaping integration memoizes text runs. Verify the cache key includes all effective inputs: selected face/fallback configuration, font size and style, wrap width, direction, language/script and relevant text options. Include font-environment generation or invalidation when fonts change or a web font finishes loading. A process-wide cache is correct only if its ownership, concurrency and dependencies are correct.

Separate deterministic test fonts from installed-font integration cases. Verify font licenses before committing or redistributing them. Font-free rectangles remain useful for isolating geometry, but do not let them become the entire rendering corpus.

**Exit evidence:** metric assertions, line-break positions, cluster/caret tests, representative script renders, web-font load transitions and cross-platform results under recorded fonts and scale. Apply visual tolerances only where justified by rasterizer variation.

## 14. Painting, effects, SVG and images

**Objective:** correct layout must produce correct pixels without causing painting and interaction to disagree.

### Painting and compositing

Use a coherent ordering model for backgrounds, borders, inline content, positioned descendants and stacking contexts. Cover opacity, z-index, transforms, clipping, overflow, rounded corners, masks and effects required by the profile. A display list with explicit clip/transform state is a proposed way to share ordering with hit testing and support incremental repaint.

Implement backgrounds as structured layers: color, images, positioning, sizing, repeat, clipping and origin. Gradients must be rendered as gradients with correct stops and geometry; choosing a fallback color does not complete the feature. Cover linear/radial and other claimed gradient types, alpha, edge cases and resize behavior.

Define alpha representation and color conversion at every boundary. Test premultiplied versus straight-alpha handling, interpolation, image scaling, compositing and transparent edges. Distinguish CSS pixels from device pixels and apply scale once.

### SVG

Use the [SVG specification](https://www.w3.org/TR/SVG2/) for feature definitions. Implement viewports, `viewBox`, aspect-ratio fitting, nested transforms, paths, shapes, inherited presentation attributes, CSS styling, fill/stroke rules, gradients, clipping and referenced resources as coherent mechanisms. Cover SVG text, masks, filters, markers, patterns and animation when required by the profile.

Test inline SVG and SVG as an image separately. Specify document/origin/script behavior for each embedding mode. Defend against reference cycles, excessive path complexity, expansion bombs and recursive resource loads. One correctly positioned rectangle establishes only that case, not general SVG support.

### Raster images

Create a format matrix listing container variants and actual decoder coverage. Test PNG bit depths/color modes/interlacing, baseline/progressive JPEG as claimed, GIF transparency/animation, WebP lossless/lossy/alpha/animation as claimed, and other required formats such as AVIF. Keep unsupported variants explicit and in the backlog when required by real content. Format sniffing is not decoding support.

Cover orientation metadata, intrinsic dimensions, aspect ratio, density selection, `srcset`/`sizes`, object fitting, decode failure and late image arrival. Bound dimensions, decoded bytes, frame counts, recursion and decompression work. Use checked arithmetic before allocation and indexing. Preserve the UI's responsiveness during decode and cancel obsolete work on navigation.

Current image code uses compression-library paths and rejects some PNG variants. Evaluate the actual imported decoder modules before deciding which formats are complete. Verify all codec provenance and redistribution terms.

**Exit evidence:** independently generated or properly licensed input samples, known pixel/geometry expectations, malformed inputs, alpha/scaling references, animation timing assertions, inline/embedded SVG cases and real-page resource accounting.

## 15. JavaScript: build a language implementation, not an API-shaped facade

**Objective:** scripts must execute with consistent language semantics and safe host behavior. The current interpreter explicitly implements a subset. Extending it with isolated syntax recognizers will not establish compatibility with modern applications.

Use a pinned edition or revision of the [ECMAScript specification](https://tc39.es/ecma262/multipage/) and a pinned, separately licensed [Test262 checkout](https://github.com/tc39/test262). Review its [license](https://raw.githubusercontent.com/tc39/test262/main/LICENSE) and individual resource provenance before incorporating test material. Select and report tests by feature, with unsupported and unrun counts visible. Do not advertise broad ECMAScript conformance from hand-written arithmetic examples.

### 15.1 Stabilize semantics first

- Values and conversions: undefined/null/boolean/number/string/object and required symbols/BigInt; exact conversion and equality behavior.
- Object model: property keys/descriptors, own/inherited access, getters/setters, prototypes, extensibility and enumerability.
- Execution: lexical environments, scope, binding initialization, hoisting, closures, `this`, strict mode, calls and construction.
- Completion behavior: return/throw/break/continue through nested control flow and finally blocks.
- Syntax: required operators, destructuring, classes, templates, iteration, generators, modules and asynchronous constructs.
- Built-ins: Object, Array, String, Number, Math, Date, RegExp, JSON, collections, promises, typed arrays and buffers, plus additional APIs in the profile.
- Text semantics: JavaScript string indexing and operations must match the required UTF-16 model rather than inadvertently exposing D byte or scalar indexing.
- Errors: correct exception classes and propagation, with useful source locations and stack traces.

Test behavior that catches tempting shortcuts: coercion with side effects, property accessors, sparse arrays, inherited properties, temporal dead zones, closure capture, nested finally, iterator cleanup, promise rejection and multiple suspension points.

### 15.2 Promises, async execution and modules

Promises need real settlement, adoption, chaining, rejection and queued reaction behavior. An immediate callback on an object named Promise is insufficient. Audit old shim paths alongside newer runtime support so different APIs do not expose inconsistent semantics.

Represent suspended async execution with continuation state that preserves program position, environments and pending completion. Re-entering a function and skipping previously visited nodes requires strong tests for repeated side effects, nested loops, exceptions, multiple awaits and interleaved calls. If those semantics cannot be established in the present design, replace the suspension representation with a coherent mechanism rather than layering more skip rules.

Implement module resolution, loading, linking, evaluation and errors through the resource/origin policy. Cover import cycles and asynchronous evaluation where claimed. Separate language jobs from browser tasks and rendering.

### 15.3 Execution safety and performance

Introduce interrupt checks or instruction budgets so a page can be stopped without freezing browser chrome. Keep limits observable and testable. Audit memory ownership across DOM wrappers, closures, native callbacks and navigation teardown. Do not allow script access to process files, sockets or native pointers through accidental host exposure.

A bytecode interpreter may improve maintainability and performance after semantics are stable. A JIT is not required to make a useful correct browser, and should not precede evidence of an interpreter bottleneck. Profile representative scripts and repeated DOM work before choosing the execution architecture.

**Exit evidence:** feature-group conformance reports, meaningful host assertions, asynchronous ordering tests, interrupted infinite-loop recovery, memory/lifetime checks and real applications that exercise the declared language/API profile.

## 16. Web APIs, scheduling and document lifecycle

**Objective:** the host must expose actual browser behavior behind API names.

Build an API registry recording interface, method/property semantics, exceptions, identity, origin restrictions, invalidation and tests. Use a consistent binding layer so conversions and error handling are not reimplemented differently for every method. Audit all existing stubs and synchronous shims; their presence in comments is a prompt for investigation, not definitive proof of current execution behavior.

### Lifecycle and scheduling

- Model navigation, document creation, parsing, script execution, readiness, load, unload and replacement explicitly.
- Keep task queues, microtask checkpoints, timers, animation callbacks and rendering updates in a tested order.
- Use a monotonic clock for runtime deadlines and an injected clock for deterministic tests.
- Bound microtask/timer work enough to preserve application control while respecting documented semantics.
- Cancel or detach old-document timers, observers, requests and callbacks on lifecycle transitions.
- Ensure background tabs and hidden windows follow a deliberate scheduling policy.
- Use actual readiness signals for screenshots and interaction tests.

### Required API groups

Evaluate DOM/query APIs, events, location/history, navigator, URL-related APIs, fetch/XHR, timers, animation frames, storage, observers, forms, canvas, workers, messaging and other interfaces required by the completion profile. Keep service workers, IndexedDB, streams, WebSocket, WebAssembly, media and graphics APIs visible as distinct capability groups; determine requirements from the declared profile and corpus rather than silently calling them outside scope.

For fetch, implement request/response state, headers, bodies, promises, abort, redirects, credentials and origin policy coherently. Use the [Fetch Standard](https://fetch.spec.whatwg.org/) to resolve browser policy semantics. A successful HTTP client response alone does not implement web `fetch`.

For canvas, test drawing state, transforms, clipping, compositing, text, image operations and pixel access. Enforce origin-clean behavior. For worker/messaging APIs, specify thread/realm ownership, structured transfer/clone behavior, termination and failure reporting before adding concurrency.

**Exit evidence:** deterministic order traces, lifecycle/navigation race cases, binding assertions, API feature coverage, failed-request behavior and integration journeys requiring asynchronous updates.

## 17. Interaction, forms and accessibility

**Objective:** the rendered page must respond to actual desktop input, keyboard navigation and assistive access.

Unify layout/paint/hit-test coordinates, stacking, transforms, clipping, scrolling and device scale. Clicking a visible element must reach the same element that painting places under the pointer. Include overflow, opacity policy, pointer-events, overlapping contexts and transformed descendants in the tests.

Implement:

- Pointer/mouse events, hover state, capture where required, wheel scrolling and drag behavior.
- Event capture/target/bubble phases, cancellation and default actions.
- Focus order, focus/blur changes, keyboard activation, shortcuts and visible focus indication.
- Text entry, selection, clipboard behavior, caret movement and platform input-method composition.
- Form controls with editing, checked/selected state, disabled/readonly handling, labels and validation.
- Form submission, encoding, submitter behavior, GET/POST, file input and origin policy.
- Link activation, fragments, navigation targets and history transitions.
- Text selection and scrolling to focused/anchored content.
- Accessible names, roles, states, tree updates and the supported platform accessibility bridge.

Keep browser-chrome shortcuts and page input ownership explicit. A script with an endless loop must not prevent the user from stopping a load or closing a tab. File selection, downloads and permissions must use explicit host policy rather than giving content direct filesystem access.

The existing interaction probe checks a handler's attribute mutation and a link destination. Preserve it, then add keyboard, focus, preventDefault, overlapping/translated elements, scrolling, form submission and navigation tests. Use observable page state and controlled server receipts as assertions. A non-crashing click is not enough.

**Exit evidence:** automated page-content assertions plus native host input tests on every supported platform, keyboard-only journeys, accessible-tree inspection and failure recovery.

## 18. URL, HTTP, loading and storage

**Objective:** correctly retrieve the right resources, under the right origin, with bounded work and accurate failures.

### URL and origin

Replace assumptions in the current URL parser with a tested model grounded in the [URL Standard](https://url.spec.whatwg.org/). Cover relative resolution, base elements, percent encoding, fragments, queries, user information where applicable, IPv4/IPv6 literals, ports, host normalization, internationalized names and special schemes required by the profile. Use one canonical origin representation for comparisons; never compare security origins with ad hoc string prefixes.

Specify `http`, `https`, `file`, `data`, `blob` and internal page handling separately. A local file document must not automatically inherit unrestricted access to other files or network identities. Validate redirect destinations through the same policy as original requests.

### HTTP

Use [HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110.html) and [HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112) as protocol references. Test partial reads/writes, split headers, framing, chunk extensions/trailers, informational responses, empty bodies, redirects, connection closure and malformed/ambiguous messages.

Set bounded headers, body sizes, decompressed output, redirects, concurrency and connection lifetimes. Cover compression streams and failures without zip-bomb behavior. Implement connection reuse, caching, validators and content decoding deliberately. Add HTTP/2, HTTP/3 and compression formats as separate capabilities when required by the profile; do not advertise them through negotiation unless the corresponding protocol is implemented.

DNS, connect, handshake, headers and body transfer need cancellation and stage-level timeout reporting. Current socket calls have deadlines, but DNS and host integration must be tested independently. A network deadline does not guarantee the GUI thread remains responsive if a synchronous caller waits on that thread.

### Resource loader

Resolve stylesheets, imports, images, fonts, scripts, module graphs, frames and media through one policy-aware loader. Record original/final URL, initiator, origin, status, MIME type, byte counts, decode outcome and blocking/readiness implications. Distinguish a deliberately blocked request from an accidentally missing resource.

Avoid duplicate loads, prioritize work that affects first render, and bound parallelism. Attach request completions to document generations. Loading an image after navigating away must not mutate the new document or retain the old tab indefinitely.

### Cookies, cache and storage

Implement cookie domain/path, expiry, secure/HttpOnly/SameSite policy and relevant partitioning rules. Treat public-suffix data and algorithms as a provenance and correctness workstream. Test cross-origin and cross-site cases with controlled hosts. Persistent storage must use explicit profile directories, durable formats, quotas and safe recovery from partial writes.

Keep cache contents and local storage isolated by the declared privacy/origin model. Make clearing browsing data actually remove the selected data. Never include a user's history, cookies, captured authenticated pages or credentials in release packages or public diagnostics.

**Exit evidence:** controlled HTTP fixtures, network failure/cancellation cases, URL/origin assertions, resource accounting, cache/cookie/storage tests and responsive native navigation under slow/failing peers.

## 19. TLS and cryptography: trust is a mandatory gate

**Observed:** the inspected TLS body verifies selected handshake signatures and checks certificate DNS names. No complete X.509 path/trust-store validation was found in that source. The header is partly stale, but the missing trust-chain gate is material. Do not display trusted-HTTPS status or claim authenticated secure browsing until certificate trust is established.

Use [TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446), [X.509 validation](https://www.rfc-editor.org/rfc/rfc5280), [TLS service identity](https://www.rfc-editor.org/rfc/rfc9525.html) and [secure TLS recommendations](https://www.rfc-editor.org/rfc/rfc9325.html) as separate references. Handshake correctness, identity matching, path validation and policy are distinct obligations.

### Certificate and trust work

- Parse DER with checked lengths, nesting bounds and strict error handling.
- Construct and verify an acceptable certificate path to an explicitly trusted anchor.
- Check certificate signatures, validity times, issuer/subject relationships, basic constraints, path lengths, key usage, extended key usage, critical extensions, name constraints and supported policy requirements.
- Check service identity using the applicable DNS/IP identifier rules and controlled wildcard/IDN behavior.
- Reject untrusted, expired, not-yet-valid, wrong-host, malformed and disallowed-algorithm certificates by default.
- Define trust-anchor acquisition and updates on each platform, with provenance and distribution policy for any bundled data.
- Document revocation, transparency and other browser security policy decisions; do not imply coverage that has not been implemented and tested.
- Keep any explicit local-development trust exception separate, visible, narrow and absent from default production verification.

### Protocol and primitive work

- Verify transcript construction, key schedules, AEAD nonces, record limits, alerts, message fragmentation and handshake state transitions.
- Cover key updates, session behavior and negotiated algorithms according to the declared profile.
- Reject downgrade or protocol-confusion conditions and unsupported negotiation correctly.
- Use operating-system secure randomness with checked failures.
- Audit primitive arithmetic, encoding checks, constant-time behavior where secrets are involved, and secret lifetime handling.
- Test known-answer vectors, differential behavior against an independent implementation, negative vectors, truncation, bit flips, wrong signatures and malformed peer messages.

Independent TLS implementations may serve as test peers without becoming product dependencies. Review licenses of test tools and vector datasets. Do not copy a cryptographic implementation under a conflicting license and call it an original translation.

Security review is a required release activity. Agent-written crypto passing its own tests is insufficient evidence for production security. Record review findings, fixes and remaining limitations. Continue local deterministic rendering work while this stream is open, but keep the secure-browsing release gate failed until it is resolved.

**Exit evidence:** controlled valid/invalid certificate chains, hostname/IP cases, protocol interoperability, adversarial inputs, original primitive assertions, independent review and truthful browser security indicators.

## 20. Browser security, isolation and privacy

**Objective:** untrusted page content must not gain browser-host privileges or compromise unrelated origins and profiles. Rendering accuracy does not establish this security property.

Create a threat model covering malicious HTML/CSS/SVG/images/fonts/scripts, hostile servers, compromised resources, navigation races, cross-origin documents, local files, downloads and update artifacts. Name the trust boundaries and how each is enforced. Keep security requirements in the same completion ledger as visual and functional work.

Required security work includes:

- A consistent origin model for documents, requests, frames, storage and script access.
- Same-origin enforcement, CORS behavior, credentials policy and cross-context messaging checks.
- Content Security Policy and other response/document security policies required by the browser profile.
- Mixed-content, secure-context, MIME and download handling.
- Separation of internal browser pages from untrusted page script and data.
- Profile and private-browsing data isolation, with truthful persistence behavior.
- Bounds and checked arithmetic throughout parsers, decoders, allocation and native interfaces.
- Safe file paths, controlled downloads and no content-supplied shell commands.
- Explicit permission handling for sensitive APIs.
- Crash/hang recovery that leaves the user in control.

Evaluate process separation and platform sandboxing as release requirements for browsing untrusted sites. A single-process prototype may remain useful for development, but do not silently present it as having the containment of a hardened general-purpose browser. If isolation is a mandatory profile gate, implement and test it before release; document remaining containment limits otherwise and keep the broad secure-browser claim open.

Fuzz the HTML/CSS/URL/DER/HTTP parsers, script lexer/parser/runtime, image/font/SVG decoders and binding boundaries. Use deterministic seeds and retain minimized regressions. Cover allocation failures and cancellation. Run meaningful sanitizers or runtime instrumentation available for the selected compiler/platform and explain any coverage gaps.

Keep logs privacy aware. Diagnostic receipts should record hashes, outcomes and timings without copying credentials, authorization headers, cookie values or personal page content into public artifacts. Redact by design and preserve enough structured information to reproduce a failure with synthetic inputs.

**Exit evidence:** origin/security assertions, hostile-input corpus results, containment tests, private-profile checks, review findings and a release security assessment tied to the candidate build.

## 21. Performance: measure both browser work and agent work

**Objective:** improve time to correct behavior and runtime responsiveness without weakening the acceptance standard.

### 21.1 Browser measurements

Instrument the pipeline before choosing optimizations. Record monotonic durations and useful counters for DNS, connect, TLS, headers/body, decoding, parsing, style matching/cascade, intrinsic measurement, shaping, layout, image decode, display-list construction, rasterization, compositing and presentation.

Record node/rule counts, selector candidates, cache hits/misses, shaped runs, layout passes, invalidated nodes, painted area, decoded pixels, requests and allocated/retained memory. Include document generation and input hash so traces can be matched to the correct page state.

Use a benchmark corpus containing small static pages, deep and wide DOMs, many style rules, large text, repeated cards, flex/grid combinations, images/SVG, script-driven mutation and slow resources. Include the required real site and unrelated sites. Separate network time from engine CPU time, cold from warm caches, and debug from optimized builds. Record compiler flags, CPU, memory, OS, DPI and fonts.

The following are **proposed initial budgets**, to be calibrated on a named reference machine. They are not measured current performance or guaranteed targets for arbitrary pages:

| Operation | Initial budget or rule | Measurement |
| --- | --- | --- |
| Idle static page | No repeated full style/layout without invalidation | Stage counters over a fixed idle interval |
| Ordinary chrome/input handling | p95 visible response within 100 ms under the benchmark workload | Native event timestamp through presentation |
| 60 Hz scrolling/animation target | p95 frame work near or below 16.7 ms on the declared corpus | Frame CPU/presentation trace; also report missed frames |
| Controlled local first render | Establish baseline, then set a page-size-specific bound | Request start through documented render-ready state |
| Stop/navigation cancellation | User control remains responsive; obsolete work terminates promptly | Controlled slow server and script/decode workloads |
| Repeated navigation/tab cycles | No unexplained continuing growth after steady state | Retained memory after warmup and repeated cycles |
| Geometry/paint changes | No correctness loss accepted for speed | Same semantic, visual and interaction gates before/after |

Report p50/p95 and worst relevant outliers across enough repetitions to expose variance. Keep raw observations. Do not subtract network delays and then claim the reduced value as total page-load time.

### 21.2 Optimize in dependency order

Common candidates to investigate are repeated full-tree style scans, repeated shaping, missing intrinsic-size caches, full layout on hover, redundant resource requests, serial decode/network waits, repeated surface allocations and full repaint for small changes. A candidate becomes work only after a trace establishes its cost.

Apply optimizations with explicit invalidation keys:

- Selector indexing must preserve complete matching semantics.
- Style sharing must include all relevant inherited/state-dependent inputs.
- Shaping and intrinsic caches must track font, content and constraint changes.
- Incremental layout must include ancestor/descendant dependencies that can change geometry.
- Partial repaint must include old/new damage, clips, transforms and effects.
- Asynchronous decode/network work must preserve document ownership and cancellation.

Maintain a correct uncached or full-update path in diagnostic builds where feasible. Differential checks between optimized and reference paths are valuable for finding invalidation errors.

### 21.3 Agent efficiency measurements

For each resolved defect, record elapsed wall time, active tool time, model wait time where available, tool rounds, builds, patches, failed hypotheses, changed lines and accepted cases. These metrics diagnose throughput; none is a substitute for accepted quality.

Track:

```text
time to reproduce
time to first discriminating experiment
time to verified fix
regressions introduced
accepted coverage gained
repeated builds/searches that produced no new evidence
```

Use the current Aurora working-context and stagnation features. Keep a compact factual checkpoint so a smaller context does not lose requirements or counterexamples. A different model can be evaluated for bounded diagnosis if the user configures it; switching models is an experiment, not a guarantee.

Avoid large unfiltered tool output, repeated full-file reads and constant plan rewriting. Batch independent inspection and group coherent edits. Do not parallelize mutations to shared engine invariants without explicit coordination. Use subagents only when the applicable instructions or user authorize them.

**Exit evidence:** correctness-preserving before/after benchmark receipts, stable raw timings, no unexplained memory growth and a measured reduction in avoidable diagnostic/build cycles on comparable defects.

## 22. Cross-platform and browser-host completion

**Objective:** the same owned engine must operate correctly through real desktop hosts on Windows, Linux and macOS under the declared support matrix.

Current package metadata lists libraries/frameworks for those systems. That is build intent, not proof that the browser builds, launches or behaves correctly on each. Create a platform matrix containing compiler version, architecture, OS image, GUI backend, rendering backend, fonts, DPI, trust-store strategy and artifact type.

For every platform, establish:

- A clean source build using pinned, documented tooling.
- Launch, window creation, resize, minimize/restore, close and shutdown.
- Page layout at the actual content viewport, including fractional scale where supported.
- Mouse/wheel/keyboard/clipboard/IME behavior.
- Font discovery, fallback and controlled web-font loading.
- TCP/TLS/network cancellation and trust behavior.
- Storage/profile paths and permissions.
- Accessible-tree exposure and platform integration required by the profile.
- Crash/hang recovery and diagnostics.
- Packaging, installation or portable launch, and removal without data loss.

Complete the desktop experience needed for real browsing: address parsing/search policy, back/forward/reload/stop, tabs, titles, favicons, loading/error states, zoom, find, selection/copy, bookmarks/history, downloads, profile controls and settings. Include printing/PDF, password handling or additional facilities when part of the declared profile. Implement settings through stable data and test migrations.

Retain headless page-content tests and native host tests. A software-rendered headless window cannot prove real IME, clipboard, DPI, accessibility, GPU/backend or window-manager behavior. Conversely, manual native smoke testing cannot replace deterministic engine assertions.

Mark unavailable platform checks as unrun. Continue other streams productively, but keep the cross-platform completion gate open until actual evidence is available.

## 23. Corpus design and conformance reporting

**Objective:** a growing test corpus must expose independent failures and interactions among features without becoming impossible to run or misleading to summarize.

Organize four complementary layers:

| Layer | Purpose | Examples |
| --- | --- | --- |
| Original small cases | Isolate one rule with known expectations and clear provenance | Box edges, cascade precedence, malformed token, promise order |
| Original combination cases | Expose composition errors | Flex item containing SVG/text; transformed clipped link; late font changing layout |
| External conformance suites | Measure behavior against established broad tests | Pinned WPT and Test262 in separately licensed checkouts |
| Real-page journeys | Validate complete loading and user behavior | Required site plus unrelated content and interactive applications |

Do not let one layer replace the others. Small cases explain; combinations catch integration; conformance suites reveal gaps; real pages establish usefulness.

### Reference and resource manifest

Each case should identify source/asset hashes, provenance/license, viewport, device scale, font setup, color policy, navigation/base URL, clock state, readiness condition, expected requests, semantic assertions, reference generator and tolerance policy. Keep dynamic site snapshots and independent reference output tied to the same content. Use a controlled local server/replay environment where permitted and technically appropriate.

Keep live-site runs separate. They detect integration changes and are part of required-site acceptance, but cannot reliably isolate engine regressions when content changes. Record capture time, redirects, response/resource hashes and observed load state. Never infer that a page is complete simply because it stopped producing network traffic.

### Conformance adapters

Build a minimal headless automation interface able to navigate, set viewport/scale, await explicit readiness, execute test script, deliver input, collect assertions and capture page content. Expand it toward the external suite's required automation protocol as needed. Do not reimplement an entire suite framework before proving a few representative cases run correctly.

Make unsupported syntax and missing APIs visible. A test that cannot load because the runner lacks a feature is not a browser pass. Track infrastructure errors separately from assertion failures. Pin suite revisions, selected manifests and expectations so results are comparable.

### Reports

Every report should show selected, passed, failed, skipped, unsupported, timed out and not-run counts, plus the selected proportion of the intended feature group. Explain exclusions. Preserve the case list and raw logs. An aggregate collector must fail if a required recipe is missing, stale, failed, cancelled or bound to different source inputs.

Add periodic full runs and affected-feature runs to the workflow. Use dependencies to select fast subsets during diagnosis, then run the full required matrix for a release candidate. Re-run after any relevant source change rather than merging receipts from unrelated revisions into a synthetic “all green”.

## 24. Working state, stagnation and recovery

**Objective:** an interrupted or long-running agent must resume the real problem with the evidence needed to make the next decision.

Create a small durable state file and a human-readable ledger. Proposed fields:

```json
{
  "objective": "Native cross-platform Aurora Browser under the approved CC0/0BSD policy",
  "workspace": "absolute checkout path",
  "baseCommit": "commit identifier",
  "dirtyInputFingerprint": "hash covering current relevant source",
  "profileVersion": "versioned completion contract",
  "currentMilestone": "M01",
  "currentFailure": "specific observable failure",
  "reproduction": "case identifier and command/recipe",
  "expected": "independently established result",
  "observed": "current result and receipt",
  "hypothesis": "current causal explanation",
  "rejectedHypotheses": ["hypothesis plus disproving observation"],
  "lastAcceptedOutcome": "case/milestone and current receipt",
  "nextExperiment": "one bounded discriminating action",
  "openLicenseAndSecurityGates": ["specific unresolved items"]
}
```

This is a proposed schema, not an existing API. Keep it short enough to read after interruption. Preserve the full conversation/history separately; a checkpoint should not become a second enormous transcript.

Use a defect ledger with these columns: ID, user-visible symptom, reduced case, expected/observed result, owning layer, dependencies, priority, current status, latest evidence and next action. Link existing cases instead of duplicating them. Use stable IDs for milestones, defects and cases.

### Stagnation rule

Aurora's current continuation policy triggers re-diagnosis after three stalled continuations and requires attention after a further stalled window. Cooperate with it. Even before that threshold, repeated experiments producing the same contradictory evidence require a changed approach.

On re-diagnosis:

1. State the exact remaining failure and whether the original reproduction still fails.
2. List the last experiments and what each established.
3. Remove unsupported assumptions and stale results.
4. Reduce further or inspect an earlier pipeline stage.
5. Consult the relevant normative rule or a second independent oracle.
6. Propose a different causal hypothesis with a disconfirming test.
7. Obtain bounded diagnostic review if configured and appropriate.

Do not reset stagnation by running another successful compiler invocation, changing a query, rewriting a plan or adding a stub. If the next required input genuinely cannot be obtained, preserve the work and report the precise missing decision or environment. Avoid hours of unbounded retries against an unchanged blocker.

### Context and progress reporting

Keep active context focused on the objective, current invariant, failing case, source map, accepted evidence and rejected hypotheses. Retrieve old conversation details when needed. Do not carry hundreds of obsolete patches and speculative diagnoses into every decision.

Report the outcome, evidence and next unresolved point in plain language. Example: “Asymmetric padding now matches the independent reference at both widths; the nested flex case still overflows because intrinsic minimum sizing is unresolved.” Avoid “fully implemented” unless the complete corresponding acceptance contract passes.

## 25. Ordered implementation milestones

Use this as the initial dependency plan. Reorder independent work when evidence warrants it, but preserve prerequisites and keep all mandatory gates visible. These milestones do not imply authorization to delegate to additional agents.

| ID | Deliverable | Dependencies | Exit evidence |
| --- | --- | --- | --- |
| M00 | Preserve current work; record baseline, completion profile and provenance inventory | None | Actual checkout/dirty state recorded; no lost modifications; required feature/license/security gates visible |
| M01 | Repair browser acceptance recipes and establish trustworthy current baseline | M00 | Complete input fingerprint; freshly built tools; independent render references; real interaction assertions; current receipts |
| M02 | Resolve the smallest foundational box/style discrepancies | M01 | Box, borders, shorthand/longhand and nested cases pass independent geometry and pixels |
| M03 | Establish decoding, tokenizer/tree-builder and DOM invariants | M01 | Valid/malformed tree cases, mutations and lifecycle identity checks pass |
| M04 | Complete the core CSS property pipeline and invalidation model | M02, M03 | Property registry, cascade/value assertions and computed-style/render equivalence cases |
| M05 | Correct normal flow, inline layout, intrinsic sizing and text integration | M04 | Geometry, line wrapping, font transitions and multiple viewports verified |
| M06 | Complete flex, grid, positioned, table and required fragmentation behavior | M05 | Algorithm phases and nested combination cases verified |
| M07 | Complete raster images, SVG, backgrounds and visual effects required by the profile | M04–M06 as applicable | Independent format/visual cases, limits, late-resource and composition checks |
| M08 | Establish URL/origin/resource-loader and HTTP correctness | M01; origin model coordinated with M11 | Controlled peer, redirects, cache/cookies, resource coverage, cancellation and freshness |
| M09 | Complete certificate trust and harden owned TLS/crypto | M08 | Invalid-chain rejection, interoperable protocol behavior, review findings resolved; secure indicator truthful |
| M10 | Establish ECMAScript semantics and asynchronous execution architecture | M03 | Declared language groups verified; no facade-only Promise/async behavior; interruptibility |
| M11 | Complete web bindings, event loop, origin policy and document lifecycle | M08, M10 | Binding conformance, ordering, lifecycle races, security policy and required API groups |
| M12 | Complete page input, forms, focus, selection and accessibility | M06, M11 | Real native input and keyboard journeys, form requests, accessible-tree evidence |
| M13 | Verify target-site and unrelated real-page journeys | Relevant M03–M12 capabilities | Frozen and live corpus results with resources, pixels, semantics and interactions at all required viewports |
| M14 | Remove measured performance bottlenecks and prove stability | M01; repeat after semantic milestones | Before/after timings, correctness unchanged, frame/input/memory gates pass |
| M15 | Validate actual Windows/Linux/macOS hosts and packaging | Relevant implementation milestones | Clean builds, native tests and profile matrix pass; unrun platforms remain open |
| M16 | Finish licensing migration and distribution audit | M00; updated with every dependency change | Requested grant has provenance; actual package inventory satisfies approved strictness |
| M17 | Complete security/isolation review and hostile-content verification | M08–M12, M15 | Threat model, fuzz/negative tests, containment and review gates satisfied |
| M18 | Release candidate and final handoff | All mandatory gates above | Fresh unified evidence, correct artifact, truthful documentation, preserved user data and delivery proof |

M09, M16 and M17 are release-blocking streams. They may progress alongside rendering work, but must never be left as an unmentioned future exercise after a broad “complete browser” claim.

### The first practical work packet

Start with M00–M02, not with the entire feature list at once:

1. Record the current commit, dirty files and relevant source fingerprints.
2. Inspect the latest browser recipe and replace its weak assertions/provenance as described in section 9.
3. Run the established independent box/flex-grid/SVG corpus without recapturing references.
4. If the box case fails, dump matched declarations, computed edges, content size, border rectangle and paint colors for the outer element.
5. Locate the first incorrect value and create equivalent longhand/asymmetric/nested counterexamples.
6. Fix the general rule and rerun the narrow case, then the full established recipe.
7. If the baseline already passes, record that evidence and move to the next independent failure; do not manufacture work from a historical discrepancy.
8. Run the native smoke suite in an isolated profile with freshly built inputs.
9. Update the ledger with accepted outcomes, remaining failures and the next dependency.

Do not spend another long session browsing the entire repository before reproducing a concrete failure. The source map and existing corpus are sufficient to begin.

## 26. Build, packaging and delivery discipline

**Objective:** the artifact delivered to the user must be the artifact that passed the final gates.

Use isolated test outputs and profiles while developing. Preserve active browser binaries and user data. Do not delete temporary directories whose resolved ownership is uncertain, and do not overwrite another chat's build output. Prefer documented project build commands and stable scripts over repeated hand-built compiler command variations.

Pin compilers, flags, runtime/linkage choices and dependency sources. Record optimized-with-assertions versus release-mode differences. Test the actual production configuration in addition to diagnostic builds. A successful diagnostic executable cannot establish the behavior of a separately built release executable.

For each release candidate:

1. Freeze the candidate source and dependency state, including any permitted dirty inputs.
2. Build the exact intended source/binary package.
3. Record artifact hashes, build flags, toolchain and source fingerprints.
4. Run the required semantic, visual, interaction, network, security, performance and platform checks against that candidate or a demonstrably equivalent build.
5. Inspect archive contents for unexpected binaries, license conflicts, credentials, personal data and missing assets.
6. Launch the packaged browser in a clean profile and perform the required native journeys.
7. Write release notes describing supported behavior and remaining limitations accurately.
8. Perform the requested delivery action under the applicable repository/release authorization, then verify that the delivered artifact matches the tested hash.

Publishing a release or updating a running application is separate from creating this document. Follow the actual application's policy and the user's authorization when execution reaches that stage. A Pro-client rebuild never certifies the browser engine, and a browser build never certifies Pro-client changes.

Keep source commits focused and reviewable. Preserve user modifications. Do not include private audit logs or site captures simply because they appear in the working directory. If concurrent work is changing engine files, coordinate through recorded revisions and rebaseline before accepting a final receipt.

## 27. Completion checklist

Use these checks as release gates, with links to current evidence rather than unchecked assurances:

- [ ] The browser profile preserves the user's original required behavior and declares all platforms/capabilities.
- [ ] Mandatory gaps are resolved; unsupported and unrun counts are visible.
- [ ] HTML/DOM correctness is established independently of rendering.
- [ ] CSS cascade, values and the complete supported property pipeline are verified.
- [ ] Box, inline, flex, grid, positioned, table and required fragmentation cases pass.
- [ ] Text, fonts, line breaking, SVG, images, gradients and effects meet the profile.
- [ ] ECMAScript and required web APIs have real semantics and current conformance evidence.
- [ ] Events, input, focus, forms, navigation and accessibility work through real host input.
- [ ] Resource loading, HTTP, cookies, cache and storage have correctness and failure coverage.
- [ ] HTTPS trust-chain, identity and protocol security gates pass.
- [ ] Origin policy, sensitive APIs, hostile inputs and containment have been reviewed and tested.
- [ ] Required-site frozen and live journeys pass, with all resource outcomes explained.
- [ ] Unrelated real pages and combination fixtures pass without site-specific product hacks.
- [ ] Performance and memory gates pass on the declared machines/configurations.
- [ ] Every supported platform has actual build, native execution and packaging evidence.
- [ ] CC0/0BSD coverage and provenance are correct; strict distribution claims match the inventory.
- [ ] All required receipts refer to the same final relevant inputs or a proved equivalent candidate.
- [ ] Packaged files, documentation and hashes match the tested candidate.
- [ ] The delivered artifact launches, preserves user data and is retrievable as intended.
- [ ] The final report names verified scope, evidence and any honest remaining limitations.

If a mandatory checkbox remains open, report the achieved milestones and the exact remaining work. Do not declare the original full-browser task complete.

## 28. Required evidence packet for each milestone

Use a compact report with this shape:

```text
Milestone and defect IDs:
User-visible behavior changed:
Relevant source commit + dirty-input fingerprint:
Independent expected result and provenance:
Before result:
General implementation change:
After result and receipt paths:
Semantic / visual / interaction checks:
Affected regressions and broader corpus:
Performance / memory observations if relevant:
License / security consequences:
Remaining limitation and next dependency:
```

Include paired images for a visual fix where they aid review, but keep the machine-readable comparison and geometry assertions. Name the actual interaction outcomes. Preserve failed experiments when they explain an important invariant or rejected approach; avoid dumping the whole chronological tool history into the report.

For a performance milestone, include baseline and candidate measurements under identical conditions, correctness receipts and the observed source of savings. For a licensing milestone, include the inventory change and grant/provenance evidence. For security, include the negative cases and review finding identifiers.

## 29. Instructions that prevent false completion

Do not:

- Claim modern-browser completeness from a single working page.
- Treat compilation, a successful process exit or a screenshot capture as rendering/interaction correctness.
- Use Aurora's own output as the only independent acceptance oracle.
- Accept a temporary binary without a current source/build fingerprint.
- Change fixtures, references or tolerances simply to make a failure disappear.
- Patch target-site HTML/CSS or insert hostname-specific rendering exceptions into the engine.
- Replace required fonts, gradients, images or scripts with placeholders and call the feature complete.
- Expose methods that silently return successful empty values when required semantics are absent.
- Ignore missing resources, console errors, rejected promises or security failures because a page is readable.
- Call HTTPS trusted while certificate path validation is unresolved.
- Relabel third-party code or data to satisfy a license scan.
- Count skipped/unrun tests as passes or omit their denominator.
- Infer Linux/macOS support from conditional linker flags alone.
- Claim a speedup without comparable measurements or accept speed by weakening behavior.
- Reset progress through repetitive builds, searches, patch volume or plan rewrites.
- Lose original requirements, user changes or rejected hypotheses after compaction/restart.
- Publish private audit, user-profile or authenticated page data with the product.

Use these positive replacements: independent expectations, current artifacts, general mechanisms, negative cases, declared coverage, bounded experiments, explicit provenance and truthful status.

## 30. Copy-ready instruction for Aurora OpenCode Pro

The short companion [agent handoff](C:/Users/windows10/Documents/github_repositories/aurora-gui/aurora-browser/docs/AGENT-HANDOFF.md) points to this brief. Its operational instruction is:

> Continue implementing the native Aurora Browser and Aurora Web engine in the existing repository. Read this implementation brief and preserve the full browser objective, the required real-site behavior, cross-platform intent and CC0/0BSD licensing target. Start by recording the current checkout and user changes, repairing weak acceptance evidence, and rerunning the independent frozen corpus. Work through the dependency-ordered milestones, implementing general behavior and verifying current source with semantic, visual and real interaction assertions. Keep licensing, certificate trust, origin security, performance and actual platform validation as completion gates. Proceed through authorized reversible work without repeated permission requests. Report accepted outcomes and remaining concrete failures; claim full completion only when the required browser profile and release gates pass.

This brief is deliberately demanding. It gives the agent a path to complete the work while making unsupported success claims harder. The next useful action is a current, trustworthy baseline followed by the smallest general fix that changes that baseline.


