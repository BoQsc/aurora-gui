# DeepSeek V4.1 latency: flash vs flash-fast

Endpoint: `https://api.commandcode.ai/provider/v1` (the configured CommandCode
provider). Measured 2026-10-16 on the repository checkout.

Available DeepSeek 4.1 routes (from the live `/models` catalog, and named in
`aurora-opencode-core/source/auroraopencode/core.d`):

- `deepseek/deepseek-v4.1-flash`
- `deepseek/deepseek-v4.1-flash-fast`

## Result

`deepseek/deepseek-v4.1-flash-fast` is faster on every measured metric, on both
transports. It wins on time to first token and on total completion time.

### curl transport, thinking off (`reasoning_effort: "off"`), 4 rounds, interleaved

| Model | Case | n | first token (median) | range | total (median) |
|---|---|---|---|---|---|
| flash-fast | tiny | 4 | **1.136 s** | 0.894-1.948 | **1.274 s** |
| flash      | tiny | 4 | 1.359 s | 1.113-1.668 | 1.363 s |
| flash-fast | long | 4 | **1.064 s** | 0.778-1.410 | **6.101 s** |
| flash      | long | 4 | 1.664 s | 1.254-2.080 | 8.356 s |

All 16 requests: HTTP 200, `reasoning_tokens: 0`.

### Aurora's real WinINet client (`benchmarks/latency_client.d`), 3 rounds

| Model | Case | n | first token (median) | range | total (median) |
|---|---|---|---|---|---|
| flash-fast | tiny | 3 | **1.219 s** | 1.003-1.650 | **1.373 s** |
| flash      | tiny | 3 | 1.548 s | 1.514-1.947 | 1.684 s |
| flash-fast | long | 3 | **0.865 s** | 0.666-0.957 | **16.460 s** |
| flash      | long | 3 | 1.976 s | 1.166-2.627 | 25.250 s |

The WinINet breakdown is informative: `sent_ms` was 46-109 ms for every request,
so upload is negligible; nearly all first-token time is upstream wait
(`headers_ms`). The fast route returned headers in 418-1077 ms versus
1120-2556 ms for the regular route.

## Statistical confirmation (24 samples, interleaved)

The first sweeps used 3-4 samples per cell, too few to rule out chance. A larger
interleaved run (12 rounds, `reasoning_effort: "off"`, `reasoning_tokens: 0`
throughout) pairs each round's two models and applies an exact two-sided sign
test, which assumes nothing about the latency distribution.

| Case | n pairs | flash median | fast median | mean diff | wins flash | wins fast | two-sided p |
|---|---|---|---|---|---|---|---|
| tiny | 12 | 1.483 s | **0.817 s** | +0.875 s | 1 | **11** | **0.0063** |
| long | 12 | 1.602 s | **0.856 s** | +1.073 s | 0 | **12** | **0.0005** |

Both cases are significant below the conventional 0.05 level, and the long case
is unanimous. `flash-fast` is genuinely quicker to first token, not an artifact
of a small sample.

Note: an earlier revision of the sign test summed the wrong binomial tail and
printed `p = 1.0` for these same numbers. The corrected test is in
`benchmarks/deepseek41_latency_sweep.py`, and
`build/deepseek41-sweep/reanalyze.py` recomputes the statistics from saved JSON
without new API calls.

## Robustness: is the gap tail-driven?

One result initially looked contradictory: the first sweep (which used the
ignored thinking switch) showed the long case at roughly 21.2 s vs 21.3 s — a
tie — while later runs show a wide gap. If the routes had an intrinsic speed
difference, that tie should not happen. The competing explanation was that
first-token time is dominated by provider-side variance, and the gap is really
"one route is less often slow", not "one route is always faster".

Pooling all 88 timed samples across every saved sweep and testing that directly:

| Case | n | model | min | q1 | median | q3 | max | gap (trimmed) |
|---|---|---|---|---|---|---|---|---|
| tiny | 22 | flash | 1.113 | 1.285 | 1.512 | 1.668 | 4.699 | - |
| tiny | 22 | flash-fast | 0.623 | 0.812 | **0.972** | 1.219 | 1.948 | +0.539 s |
| long | 22 | flash | 1.166 | 1.447 | 1.602 | 2.627 | 3.494 | - |
| long | 22 | flash-fast | 0.666 | 0.805 | **0.866** | 0.983 | 1.812 | +0.660 s |

Findings:

- **Not tail-driven.** Dropping the single worst flash sample barely moves the
  median (tiny 1.512 -> 1.511 s; long 1.602 -> 1.526 s). The gap persists, so it
  is not one or two slow outliers.
- **Near-disjoint distributions.** On the tiny prompt flash's lower quartile
  (1.285 s) sits *above* fast's upper quartile (1.219 s). The two ranges overlap
  only narrowly, which a pure variance story would not produce.
- **Both routes have a slow tail.** Each model has exactly one sample over twice
  its own median, so flash-fast is not simply "the route without spikes".

Conclusion: the ordering is a real difference in the typical response time, not
an artifact of a few slow samples on one route. The lone tie in the earliest
sweep is best explained by that run's different (ineffective) thinking setting,
which let both routes emit reasoning tokens and inflated both totals toward the
generation-bound regime, compressing the difference.

## Is the faster route actually selectable in the app?

Yes. This matters because the probes speak raw HTTP and bypass the app's catalog
filtering, so a faster id would be useless if the picker never offered it.

- `applyModels` in `source/auroraopencode/appui.d` receives the endpoint's raw
  `/models` ids. Its only filter, `openCodeGoSupportsChatCompletions`, runs
  solely when `isOpenCodeApiBaseUrl` holds. The configured CommandCode base URL
  is not that endpoint, so no id is dropped there, and unknown ids are treated
  as supported by design.
- The live CommandCode catalog lists `deepseek/deepseek-v4.1-flash-fast` with
  `supported_endpoints: ["/chat/completions","/responses"]`, so it is offered.
- `isDeepSeekV41FlashModel` / `defaultReasoningEffortForModel` in
  `aurora-opencode-core/source/auroraopencode/core.d` match on the normalized id,
  so the fast route inherits the correct DeepSeek 4.1 reasoning default.
- Aurora's own client completed 12/12 requests to the fast route with exit 0,
  so the wiring works end to end, not just at the API surface.

Note also that `defaultModels` (the offline fallback list) contains only
`deepseek-v4.1-flash`, not the fast route. That fallback is used only before
`/models` is fetched; the live catalog supersedes it.

## Notes and limitations

- The endpoint ignores `thinking: {type: "disabled"}`. Genuine thinking-off on
  CommandCode is `reasoning_effort: "off"`, which is what
  `buildChatBody` in `aurora-opencode-core/source/auroraopencode/provideradapter.d`
  emits when the composer has Thinking disabled. The first sweep used the
  ignored switch and still showed the same ordering, but with far noisier
  totals because both models were secretly reasoning.
- 3-4 repetitions per cell is a screening test, not statistical proof. Absolute
  seconds will drift with upstream load and cache state; the long-case spread
  (0.67-2.63 s first token) shows that variance is real.
- The ranking was consistent in all 7 interleaved rounds across both transports.
- The client harness reports no token usage; `content_chars` differs between
  models because each stops the list at a different point, not because of speed.
- These probes hit the API directly. They never modified settings, the selected
  model, or any conversation.

## Reproducing

```text
dmd -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared ^
    -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source -i ^
    -of=aurora-opencode-pro/build/deepseek41-sweep/latency-client.exe ^
    -L/SUBSYSTEM:CONSOLE -Luser32.lib -Lgdi32.lib -Lshell32.lib -Lwininet.lib ^
    aurora-opencode-pro/benchmarks/latency_client.d ^
    aurora-opencode-core/source/auroraopencode/opencode_client.d ^
    aurora-opencode-core/source/auroraopencode/core.d ^
    aurora-opencode-core/source/auroraopencode/provideradapter.d ^
    aurora-opencode-core/source/auroraopencode/providerstream.d ^
    aurora-opencode-core/source/auroraopencode/provideraudit.d ^
    aurora-opencode-core/source/auroraopencode/httptransport.d ^
    aurora-opencode-core/source/auroraopencode/latency.d ^
    aurora-opencode-core/source/auroraopencode/retrypolicy.d ^
    aurora-opencode-core/source/auroraopencode/workerbudget.d ^
    aurora-opencode-core/source/auroraopencode/outputguard.d ^
    aurora-opencode-core/source/auroraopencode/logging.d ^
    aurora-opencode-core/source/auroraopencode/events.d ^
    aurora-opencode-core/source/auroraopencode/markdown.d

python aurora-opencode-pro/benchmarks/deepseek41_latency_sweep.py --repeats 4 \
    --thinking-off off --output aurora-opencode-pro/build/deepseek41-sweep/thinking-off.json

python aurora-opencode-pro/benchmarks/deepseek41_latency_sweep.py --repeats 3 \
    --thinking-off off --client aurora-opencode-pro/build/deepseek41-sweep/latency-client.exe \
    --output aurora-opencode-pro/build/deepseek41-sweep/aurora-client.json
```

Raw samples: `build/deepseek41-sweep/{results,thinking-off,aurora-client}.json`.
