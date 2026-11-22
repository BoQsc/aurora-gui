# Controller Supervision Policy

Host applications use one visible window by default and one app instance unless
the app explicitly requests an isolated test group.

## Host-core responsibilities

- `aurorahost.single_instance` claims the app instance and activates an existing
  window on a duplicate launch.
- `aurorahost.lifecycle` records intentional closes and reports unexpected
  previous exits.
- `aurorahost.controller_supervisor` owns launch, wait, retry, and bounded
  restart of an app-provided controller executable.
- Host core owns TCP/control transport and reconnection.

## App responsibilities

- Provide the controller executable, port, retry limit, and log callback.
- Implement the controller's business logic and API/session behavior.
- Keep the controller optional: simple apps can use the embedded controller.

## Required rules

1. Every single-window app claims an instance before creating its window.
2. A second ordinary launch activates the existing window and exits.
3. Parallel testing is explicit with a distinct `--instance-group`; it is never
   accidental.
4. Test hosts use `--no-activate` and must close their windows.
5. A controller failure is isolated and supervised; it must not close the host.
6. A host must never quietly exit without recording run intent.
7. Verification uses the live host when one exists; it must not launch a second
   copy of the app.
