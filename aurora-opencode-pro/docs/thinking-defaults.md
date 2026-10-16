# Thinking defaults

DeepSeek 4.1 Flash (`deepseek-v4.1-flash`, and the CommandCode
`deepseek/deepseek-v4.1-flash` form) reasons by default.
`defaultReasoningEffortForModel` already returned `high` for it, but Thinking
itself was resolved from the raw per-conversation flag, so a conversation whose
stored flag was `false` silently sent `reasoning_effort` `none`/`off` — the
composer could even read "Thinking: High" while requests carried no reasoning.
`defaultThinkingForModel` now marks the model as thinking-by-default.

## One resolver per conversation

`effectiveThinkingForRoute` in `appui.d` answers one question — does this
conversation think? — and is shared by the composer selector, its dropdown, the
live "Thinking…" phase label and the outgoing request, so the label cannot
disagree with what is sent.

- On when this conversation's own switch is on, or when the route resolves on:
  an explicit per-route effort, the saved global switch, or the model default
  (`high` for DeepSeek 4.1 Flash, `low` for everything else).
- A per-route `off` record suppresses the model default and the global switch, so
  a deliberate Off is not re-enabled by the DeepSeek default. `setReasoningControlForModel`
  accepts `off`, and `setThinkingMode` records it — choosing Off in any
  conversation is itself an explicit per-route choice.
- A stale `false` flag (older Settings file, older conversation) no longer
  drags a DeepSeek 4.1 Flash route to Off.
- A non-GUI (console/command-line) run keeps its own low-latency route
  (`deepseek/deepseek-v4.1-flash-fast`, Thinking off) even while the saved
  Settings enable Thinking. That model id deliberately does not match the
  DeepSeek 4.1 Flash default, and `app.d` does not mirror either value into the
  saved Settings, so a shell launch leaves the GUI's own choice alone.

The provider adapter still sends `reasoning_effort` only when `thinking` is true,
and maps an unset effort onto `defaultReasoningEffortForModel`.

## Verification

- `tests/reasoning_default_contracts.d` — an unconfigured DeepSeek 4.1 Flash
  route resolves thinking high; an explicit per-route `off` is respected; an
  explicit Off survives the Settings round trip; `deepseek-v4.1-flash-fast` is
  not treated as DeepSeek 4.1 Flash.
- `tests/console_default_contracts.d` — a console conversation reads
  "Thinking: Off" while the saved Settings enable Thinking, the saved Settings
  keep the user's model, and a GUI conversation reads "Thinking: High".
- `tests/headless_pro_smoke.d` — the Thinking dropdown's checkmark and the
  selector label for a conversation whose stored flag is `false`, plus the
  Off/Low/Medium/High menu and the per-model effort it persists.

Run the focused fixtures with the recipe below (it also covers the checkout-lock
contracts described in `tool-lease-scope.md`):

    aurora-opencode-pro/build/aurora-fix-verify.json
