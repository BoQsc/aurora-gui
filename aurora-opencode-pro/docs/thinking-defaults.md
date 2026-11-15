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

The displayed mode is `thinkingMenuMode`: on resolves through
`effectiveReasoningEffort` (`low`/`medium`/`high`, otherwise the model default),
off is `off`. The selector's text and the dropdown's single checked row are both
built from it, so a route recorded as `off` can no longer be printed as
"Low" through `thinkingEffortLabel`'s fallback.

- On when this conversation's own switch is on, or when the route resolves on:
  an explicit per-route effort, the saved global switch, or the model default
  (`high` for DeepSeek 4.1 Flash, `low` for everything else).
- A per-route `off` record suppresses the model default and the global switch, so
  a deliberate Off is not re-enabled by the DeepSeek default. `setReasoningControlForModel`
  accepts `off`, and `setThinkingMode` records it — choosing Off in any
  conversation is itself an explicit per-route choice.
- That explicit `off` also wins over a conversation's older `true` flag.
  Otherwise the request would send the model's default effort while the selector
  showed the route's `off` as `Low`, and the value appeared to change on every
  switch to a chat created before the choice.
- A stale `false` flag (older Settings file, older conversation) no longer
  drags a DeepSeek 4.1 Flash route to Off.
- A non-GUI (console/command-line) run keeps its own low-latency route
  (`deepseek/deepseek-v4.1-flash-fast`, Thinking off) even while the saved
  Settings enable Thinking. That model id deliberately does not match the
  DeepSeek 4.1 Flash default, and `app.d` does not mirror either value into the
  saved Settings, so a shell launch leaves the GUI's own choice alone.

## Set once, then show it

Opening a conversation only reflects its state; it no longer copies that chat's
flag into `_settings.thinking`. The saved app-wide switch and the per-route
records change when the user picks a mode (`setThinkingMode`), so browsing chats
cannot rewrite the default that the next new chat inherits.

Because the mode is resolved per endpoint/model, every place that can change the
active route re-pushes the selector: a new chat, the model picker, a provider
preset switch, the Settings connection save, a catalog realignment of an
unavailable model id, and the console-default switch. Before that, the selector
kept the previous route's text and only jumped when a conversation switch
refreshed it.

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
- `tests/thinking_mode_switch_contracts.d` — High in one chat, Off in the next,
  switching back and forth keeps the selector and request on the chosen mode, a
  per-route Off beats the older chat's `true` flag (no "Low" fallback), and
  opening a conversation leaves the saved Thinking switch alone.

Run the focused fixtures with the recipe below (it also covers the checkout-lock
contracts described in `tool-lease-scope.md`):

    aurora-opencode-pro/build/aurora-fix-verify.json
