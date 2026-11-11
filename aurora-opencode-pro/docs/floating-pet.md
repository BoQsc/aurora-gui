# Floating pet (experimental, removal-first)

Status: **implemented, dormant and off by default.**

Shipped in this build:

- `source/auroraopencode/pet.d` - the whole feature. Gate, budgeted proposal
  ledger, formatting, the always-on-top overlay (creature face, bubble,
  click-to-write input, Notes and Pause), text-only scene sampling, and the
  bounded notes file.
- `tests/floating_pet_smoke.d` - headless behavioral suite: dormant while off,
  starts and proposes when on, typed prompt reaches the UI thread once, bubble
  mirrors the request and reply, notes are bounded, sampling is text-only and
  throttled, proactive comments are slow, pause records nothing, settings
  round-trip, computer-use hint, placement, and click-reveals-input.
- `tests/floating_pet_env_smoke.d` - the `AURORA_FLOATING_PET` enable path.
  Asserts that an unrecognised value leaves the pet **off**: the gate fails
  closed, so a typo can never enable it.
- `tests/floating_pet_scene_probe.d`, `tests/floating_pet_live_probe.d` -
  manual probes: the real foreground sampler, and the real overlay window.
- `tools/check-pet-removal.py` - enforces the removal contract by deleting
  `pet.d`, cutting the marked regions, and compiling the result.
- `aurora-opencode-core/source/auroraopencode/core.d` - `experimentalFloatingPet`,
  `petScreenWatching` and `petCommentaryMinutes` plus their load/save lines.
- `source/auroraopencode/appui.d` - the pet regions: host, observation,
  typed-prompt hand-off, conversation mirroring, computer-use hint, and the
  Settings checkboxes (`oc-floatingpet`, `oc-petscreen`).

What it does:

- **Creature.** Bottom-right above the taskbar (16px inset), and above the mini
  chat overlay when both are visible. Clicking it opens the input row; Send
  hands the text to `submitOverlayPrompt`, the same path as the main composer.
- **Answers.** After a pet-typed prompt the bubble mirrors the conversation it
  was asked in: `You: …` and then the reply, up to three short lines.
- **Notes.** `<state>/pet/notes.md`, one markdown bullet per observation, capped
  at the newest 400 lines. The Notes button opens that file.
- **Screen awareness (opt-out).** The foreground app name and window title, as
  text, clipped to a 60/80 character digest and sampled at most every 20s. It
  never captures pixels and never reads file contents; `petScreenWatching` off
  means no capture at all.
- **Proactive but sparing.** A scene comment at most every
  `petCommentaryMinutes` (default 10) and only when the scene digest changed; an
  idle comment once per quiet stretch after ten minutes; the repeated-failure
  offer is unchanged. The 4-per-minute ceiling and duplicate suppression still
  apply to all of them.
- **Pause.** Pause/Resume in the overlay stops notes, sampling and commentary
  while the pet stays visible, and the watching line reads `Paused`.
- **Repeated tool failures.** When the same tool call has failed twice in a row
  it offers *"2 failed. Want me to take another look and retry?"*, reading only
  the failure counter, never the command or its output.
- **Chained computer use.** Requests go through `submitOverlayPrompt`, so
  computer-use tools stay behind the existing approval gate. With computer use
  off, a screen-style request shows *"Computer use is off in Settings; I'll stay
  with text."*

Rate-limited to 4 proposals per rolling minute with duplicate suppression, and
each failure count is reported once. It has no execution path: a proposal is
inert text the user must act on, and any retry flows through the normal tool
pipeline and its existing approval gate.

### Overlay rendering constraint

In this toolkit build the overlay window only rasterises text and the panel
chrome: custom-painted shapes (the drawn creature, even the `TitleBar`) never
reach its surface. The visible face is therefore a `Label` glyph (`•‿•`) in the
creature column, while `PetFace` keeps the mood, blink/bob state and the click
target. Revisit this if the vendored renderer starts honouring draws in that
window; the vector body is still in `paintPetFace`.

The vendored `Label` has no word-wrap, so text that does not fit is clipped with
an ellipsis. Two consequences are deliberate:

- The approval notice is its own `Label` row (`id "pet-approval"`, "Nothing
  happens without your approval.") rather than a suffix appended to the
  suggestion. A suffix would be truncated away by any long suggestion - exactly
  the line a user most needs to see.
- Proposal strings in `formatPetProposal` are kept short for the same reason.
  Adding a longer suggestion means checking the render, not just the unit test:
  build `tests/floating_pet_smoke.d`, run it, and inspect
  `build/pet-smoke/floating-pet-overlay.ppm`.

A floating companion that passively observes activity, reacts to notable
events, and *proposes* actions. Every proposal is an ordinary tool call and is
blocked on the existing user approval gate. The feature is off by default and
must be deletable without touching the rest of the app.

## Framing: observer, not actor

"Any action needs approval" already means the pet cannot be autonomous. Design
it as a **proactive suggestion layer**, not an autonomous agent. That framing
removes the only unsafe part (unapproved autonomy) while keeping the useful
part (noticing things a human would miss).

## Non-goals

- No autonomous execution. The pet never acts without approval.
- No new effect path. It cannot bypass the tool pipeline or `taskpolicy`.
- No persistence that other modules depend on.
- No always-on cost to interaction latency.

## Reused surfaces (do not rebuild)

| Need | Existing surface |
| --- | --- |
| Screen / activity awareness | `source/auroraopencode/computeruse.d`, `execution.d`, `checkpoint.d` |
| Action execution + approval gate | `source/auroraopencode/tools.d`, `toolscheduler.d` |
| Workspace scoping of effects | `source/auroraopencode/taskpolicy.d` (`taskWorkspace`, `checkWorkspace`, `requiredEvidence`) |
| Triggering | `orchestrator.d` |
| Internal-only chatter (kept out of user history) | `controlhistory.d` (internal control messages) |
| Overlay + toggle UI | `appui.d`, `preferencewriter.d` |

## Module boundary

- **One new module**: `source/auroraopencode/pet.d` (grow into a `pet/` package
  only if needed).
- **At most three guarded hook points**, each behind a single `enum petEnabled`
  and an off-by-default preference:
  1. `appui.d` — draw the overlay and add one Settings toggle.
  2. Subscribe point to the existing event/tool stream (awareness input).
  3. Settings default.
- **Zero edits** to `tools.d`, `orchestrator.d`, `computeruse.d` logic.
- **Isolated state**: the pet's own file. No shared schema references it.

If any of these bounds is exceeded, the design is wrong — it will no longer be
removable.

## Safety invariants (hard requirements)

1. **Deny by default.** The pet can only propose; it can never execute.
2. **Approval through the existing gate.** Every proposal is a normal tool call
   under the current approval flow. No parallel approval mechanism.
3. **Never auto-approve**, never bypass `taskpolicy` workspace scoping.
4. **Read-only awareness.** Observation obeys the same scope/privacy rules as
   the agent.
5. **Visible presence.** When awareness is on, show an unmistakable "watching"
   indicator. Off or unavailable means the pet is simply absent — no degraded
   mode.
6. **Budgets.** CPU tick cap, proposals-per-minute cap, and max awareness depth,
   so "always on" cannot become "always expensive."

## Known cosmetic limitation

The overlay's rows are `flex`-split, so when a suggestion wraps or the content
is short there is visible empty space between the suggestion and the bottom
approval footer. This is cosmetic only: the approval line is a separate row and
is never clipped, which is the property that matters. Do not "fix" it by
merging the two onto one line - that reintroduces the truncation defect found
during development, where a long suggestion pushed the approval notice out of
view entirely.

## Removal procedure

Every hook lives inside an explicit region:

```
// >>> pet:begin (reason)
   ... the hook ...
// <<< pet:end
```

Removal is exactly:

1. Delete `source/auroraopencode/pet.d`.
2. In `source/auroraopencode/appui.d` and
   `aurora-opencode-core/source/auroraopencode/core.d`, delete every
   `pet:begin` .. `pet:end` region (including the sentinel lines).

That is the whole procedure, and it is enforced rather than described:
`python tools/check-pet-removal.py` copies the sources, deletes `pet.d`, cuts
every marked region, and compiles the result. It also fails if the pet is
referenced from `tools.d`, `orchestrator.d`, `computeruse.d` or
`toolscheduler.d`, which the feature promised never to touch. Because the check
and this procedure both key off the same sentinels, they cannot drift apart.

If removal requires anything beyond those two steps, the change was not built
to spec.

## Risks

- **Privacy** — passive screen awareness is invasive; opt-in per session, with a
  visible indicator.
- **Approval fatigue** — constant suggestions train blind approvals, which
  destroys the guardrail. Cap frequency; silence is the default; speak only at
  high confidence.
- **Threading** — the monitor loop must run off the UI thread with a hard tick
  budget, or it will cost interaction latency.
- **Removal rot** — "easy to remove" only holds if it stays one module with
  near-zero edits elsewhere.

## Open questions

- Per-session or app-wide awareness scope?
- Which event classes are worth a reaction (build failure, long idle, repeated
  failed command, uncommitted changes)?
- Does the pet produce internal control messages via `controlhistory.d`, or a
  separate non-history surface?
