# Tool lease scope

Inspection should not queue behind inspection. Two conversations — or a
conversation and a command-line run — reading the same checkout were excluding
each other on the exclusive cross-process `CheckoutLease`, so a `checksum`,
`dshell`, `read`, `glob`, `grep` or `view_image` could wait out the 45 s
acquisition window and then fail with "Source checkout is still in use".
Workspace-free tools (`webfetch`, `websearch`) separately held the in-process
workspace writer lease and blocked every other tool of the same checkout.

## What still owns the lock

- Mutating tools — `write`, `edit`, `apply_patch`, `copy`, `move`, `remove`,
  `rename`, `create_folder`, `run`, `download` — take the writer lease and, when
  the workspace is Aurora's own source checkout, the exclusive cross-process
  lock for the whole operation. A native transfer can hold it for minutes.
- `sync` and `rebuild` take it because they rewrite the checkout.
- A running command owns the writer lease until it exits, so tools that need the
  workspace wait for it. That is deliberate: a command can write anywhere.
  `tool_status`, plan updates and Stop use the control worker lane and are never
  blocked by a writer. A trivial `dshell sleep` issued while a long command runs
  still waits — measured here, and expected.

## What no longer takes it

- `checkoutObserver` in `tools.d` covers the read-only inspectors (`read`,
  `glob`, `grep`, `dshell`, `view_image`) and the workspace-free tools
  (`checksum`, `webfetch`, `websearch`); they skip the cross-process
  `CheckoutLease`. They keep the shared reader lease in process, so two readers
  run together and a reader never delays a writer's acquisition.
- `toolscheduler.d` treats `checksum`, `webfetch` and `websearch` as parallel
  tools, so they no longer hold the workspace writer lease while the network or
  disk work runs.
- A reader that never touches the checkout no longer serializes against a
  mutation owned by another process (GUI against command line, or two GUIs).

## Verification

`tests/read_only_checkout_contracts.d` holds the checkout lock in a child
process and asserts that a native inspector completes while it is held, with a
real write as the negative control. Measured: inspection finishes in ~5 ms with
the lock held; the write waits and is then refused, and the source file is
unchanged.

Run it with the rest of the focused fixtures:

    aurora-opencode-pro/build/aurora-fix-verify.json

`tests/tool_control_contracts.d` and `tests/developer_safety_contracts.d` cover
the control lane and the developer-source write guards that must keep working.
