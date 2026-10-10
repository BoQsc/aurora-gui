# Hello latency, 2026-10-10

The production trace at 13:17:26 used CommandCode with
`deepseek/deepseek-v4.1-flash`, Thinking disabled and tools enabled.
Measured from Send:

| Stage | Elapsed |
| --- | ---: |
| Serialized | 7.285 ms |
| Connected | 595.970 ms |
| Uploaded | 621.642 ms |
| Response headers | 4060.651 ms |
| First token | 4166.625 ms |
| Render submitted | 4170.326 ms |
| Settled | 4613.231 ms |

The request contained 27,525 wire bytes, including 15,382 bytes of tool
schemas. Provider usage reported 6,412 uncached input tokens. First-token
delivery to render submission took 3.701 ms. Most of the delay occurred
between upload and response headers, rather than in local rendering.

## Fix

CommandCode now accepts `reasoning_effort: "off"`. Previously Aurora omitted
the option with Thinking disabled because `"none"` is rejected there. A live
minimal greeting probe with the option omitted returned 20 reasoning tokens;
the explicit `"off"` probes returned zero. The adapter now sends `"off"` for
the CommandCode endpoint while preserving enabled effort and other providers.

Direct curl probes against the configured model measured first visible content
at 2.424 seconds with the option omitted, and 2.117 / 1.755 seconds with
`"off"`. A separate synthetic 5,420-input-token request with `"off"` took
1.322 seconds. These small, sequential samples demonstrate correct reasoning
control, not a reliable speedup estimate or a minimum achievable latency.
The synthetic context does not reproduce production tool schemas or history.
Timing-only evidence is in `build/hello-latency-diagnostic.json` at repository
root; credentials and generated greeting text are not retained there.

Large always-present tools and instructions remain a possible optimization,
but this sample does not isolate their latency cost. Silently dropping them
for arbitrary messages could change agent capabilities and follow-up behavior.
