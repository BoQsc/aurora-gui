# Thinking defaults

DeepSeek 4.1 Flash (`deepseek-v4.1-flash`, and the CommandCode
`deepseek/deepseek-v4.1-flash` form) reasons by default.
`defaultReasoningEffortForModel` already returned `high` for it, but Thinking
itself was resolved from the raw per-conversation flag, so a conversation whose
stored flag was `false` silently sent `reasoning_effort` `none`/`off` — the
composer could even read "Thinking: High" while requests carried no reasoning.
`defaultThinkingForModel` now marks the model as thinking-by-default.

## The mode belongs to the conversation

`ChatSession.thinkingMode` (`"off"`, `"low"`, `"medium"` or `"high"`) is the
source of truth for that chat. It is persisted with the session metadata as
`thinkingMode`, decoded only when it is one of those values, and carried in
runtime thread payloads. `activeThinkingMode` / `sessionThinkingMode` in
`appui.d` feed the composer selector, the dropdown's single checked row, the
live "Thinking…" phase label and `requestThinking`/`requestEffort`, so the label
cannot disagree with what is sent.

- Setting a mode writes only the open conversation (plus the app-wide default a
  future chat starts from). Choosing Off in one chat leaves every other chat's
  stored mode untouched, so switching chats shows each chat's own mode.
- Every normal new chat starts at High. It does not inherit the last choice made
  in another chat, and it does not fall back to the per-model default (Low for
  every model except DeepSeek 4.1 Flash). A console session still starts Off on
  its own low-latency route.
- Older conversations have no stored mode. `pinSessionThinkingMode` resolves
  their historical on/off flag against the route/model default the first time
  they are opened or send, stores the result, and from then on they behave like
  any other per-chat mode. A stale `false` flag therefore still resolves a
  DeepSeek 4.1 Flash chat to High once, not to Off.
- A non-GUI (console/command-line) run keeps its own low-latency route
  (`deepseek/deepseek-v4.1-flash-fast`, Thinking off) even while the saved
  Settings enable Thinking. That model id deliberately does not match the
  DeepSeek 4.1 Flash default, and `app.d` does not mirror either value into the
  saved Settings, so a shell launch leaves the GUI's own choice alone.

## Set once, then show it

Opening a conversation only reflects its stored mode; it does not copy that
chat's state into `_settings.thinking`. The saved app-wide switch and per-route
records change when the user picks a mode, so browsing chats cannot rewrite the
default a new chat inherits.

The selector is re-pushed whenever the active route changes: a new chat, the
model picker, a provider preset switch, the Settings connection save, a catalog
realignment of an unavailable model id, and the console-default switch.

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
- `tests/thinking_mode_switch_contracts.d` — click New chat and choose High,
  create a second chat and choose Off, then switch through the sidebar with
  real clicks: chat A keeps High (selector, dropdown checkmark and request)
  while chat B stays Off; changing A to Medium leaves B Off; a third new chat
  still starts High; the saved Thinking switch is untouched by opening A; and
  each chat's stored metadata round-trips its own mode.

Run the focused fixtures with the recipe below (it also covers the checkout-lock
contracts described in `tool-lease-scope.md`):

    aurora-opencode-pro/build/aurora-fix-verify.json
