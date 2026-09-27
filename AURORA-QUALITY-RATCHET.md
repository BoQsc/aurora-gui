# Aurora quality ratchet

Aurora applications should improve the framework, not accumulate private fixes.
Every application in this repository compiles the same canonical source tree at
`vendor/aurora-d-0.4.5/source`, so a corrected framework default reaches old and
new programs on their next rebuild.

Recency is not evidence of quality. A newer application's behavior is only a
candidate until it has been tested, compared with the current standard, and
explicitly approved by the project owner.

## Promotion rule

When an application discovers better rendering or interaction behavior:

1. Reproduce and measure it in the application without changing the standard.
2. Preserve the current standard as baseline A and implement the proposal as
   candidate B behind a test-only switch or isolated branch.
3. Decide whether it is product policy or general GUI behavior. General behavior
   is eligible for Aurora-D, but is not promoted yet.
4. Run framework regressions and application smoke tests against both A and B.
5. Capture deterministic, same-size A/B images for affected themes, DPI scales,
   renderers, and representative old and new applications. Include a pixel diff
   when it is meaningful; include measurements for performance or input changes.
6. Present the evidence to the project owner. Only the owner may approve A, B,
   neither, or request another candidate. Silence is not approval.
7. After approval, move the default or reusable mechanism into the narrowest
   Aurora module and add a framework-level regression test before removing the
   application copy.
8. Rebuild and smoke-test representative old and new applications. Keep an
   explicit compatibility switch only when the new default can break authored
   content or established interaction.
9. Update `AURORA-USAGE-STANDARDS.md` only with the approved durable rule;
   visual evidence and the decision belong in the review record, and historical
   detail belongs in `AURORA-PATCHES.md`.

An application may override a framework default for an intentional product
choice. It must not copy a framework policy merely because that application was
where the improvement was discovered.

## Enforced baseline

Run:

```text
python scripts/audit-aurora-standards.py
python -m unittest scripts.tests.test_aurora_standards_audit
```

The audit verifies that all `aurora-*` DUB packages use one Aurora-D source and
that core contracts such as sharp grayscale text, the native-weight coverage
curve, and safe frame deltas remain framework-owned. Known downstream copies
are reported as debt. A new font-rendering policy copy fails the audit, making
the current state a ratchet rather than a suggestion.

Use `--json` for tooling and `--fail-on-debt` when paying down the current
allowlist.

## Visual approval package

After capturing baseline and candidate images, create the review with:

```text
python scripts/make-aurora-visual-review.py \
  --baseline evidence/current.png \
  --candidate evidence/candidate.png \
  --difference evidence/difference.png \
  --title "Font rendering at 100% DPI" \
  --output build/reviews/font-rendering-100
```

`review.html` provides equal-size side-by-side images, an aligned wipe slider,
an A/B blink control, and the optional difference image. `review.json` records
the source paths and SHA-256 hashes and always starts with
`pending-user-review` and no decision. The comparison must be shown to the
project owner; generating it never authorizes a standard change.

For a visual change, provide at minimum the default light and dark themes at
100% and 150% DPI, plus one older and one newer affected application. Font
changes also need the text regression corpus and both software and Vulkan
captures when those renderers do not produce identical pixels.

## Current promotion backlog

No candidates are currently awaiting review.

This backlog is intentionally short. Add an item when a local workaround is
found; remove it only after the behavior and its regression test live in Aurora.

## Approved promotions

- **OpenCode font bootstrap — B approved 2026-09-27.** Aurora's `GlyphAtlas`
  retains ownership of the `0.5` coverage-contrast default. The project owner
  approved removal of the duplicate OpenCode helper after matched 1200×800 A/B
  captures showed zero application-content differences, both release builds
  passed, and the font/DPI regression covered 96–192 DPI. The OpenCode Pro
  full-frame captures differed only in their compile-time titlebar timestamp.
- **Frameless window shell — B approved 2026-09-27.** Shared movement,
  work-area maximize/restore, restore-on-drag, snap-preview mapping/application,
  and system-menu behavior now live in `FramelessWindowTitleBar`. Designer,
  Notepad, OpenCode Pro, and Stream retain their product styling and content.
  The project owner approved B after all four release builds and four focused
  framework suites passed; Designer and Notepad were pixel-identical, while
  OpenCode Pro differed only in its compile-time titlebar timestamp.
