# Project instructions (AGENTS.md / AURORA.md)

A model keeps nothing between conversations. A rule that matters later has to
live in the project, and this feature is how it gets into every prompt.

## What is read

- `AGENTS.md` in the **workspace root**, applied first.
- `AURORA.md` in the same folder, applied second (for rules that only make sense
  in this app).

Nothing else: no parent-directory search, no recursion, no globs. A monorepo's
file therefore cannot silently govern a nested project, and a generated tree
cannot flood the prompt. Empty or unreadable files are skipped silently.

Each file is capped at 16 KiB. Past the cap the text is cut at a character
boundary and a visible marker says so, so a truncated file is never mistaken for
the whole thing.

## Where it lands

The section is `# Project instructions`, placed after the built-in rules and
before the `<env>` block, so the stable instruction prefix stays cacheable. A
project with no instruction file renders nothing, which keeps the stock prompt
unchanged for everyone who does not use the feature.

The section states the precedence plainly: project instructions are house rules
and are followed like the user's stated preferences, but they cannot grant
permissions, weaken the safety/verification/communication rules, or override a
direct instruction in the conversation. When they conflict, the agent says so and
follows the user.

## Writing them well

- State rules the agent cannot infer: build commands, formatting, the one path
  that must not be touched, house style.
- Prefer checks to prose: "run `python -u -B -m unittest`" beats "test carefully".
- Keep durable knowledge that costs hours to rediscover. Example:
  [computer-use-game-testing.md](computer-use-game-testing.md) records the three
  input bugs and the operating rules that followed from them.

## Verifying it

`tests/verify-project-instructions.json` compiles and runs
`tests/project_instructions_test.d`, which asserts: both files load under their
own headings, the precedence rule is present, an unused project adds no section,
and an oversized file is cut with its tail withheld (`PASS project instructions
load, stay absent when unused, and are bounded`).
