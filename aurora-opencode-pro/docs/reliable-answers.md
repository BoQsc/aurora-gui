# Reliable, precise answers: 0.66.32

This change targets the active desktop assistant's observed answering failures.
It does not migrate the desktop to the standalone actor. The user requested
continued improvements without making human review a prerequisite.

## Behavior

- A short answer contract follows the projected conversation on every request,
  including tools-disabled and compacted contexts. It prioritizes the latest
  user's scope and format, supported conclusions, necessary detail and explicit
  uncertainty. It is not saved as another conversation message.
- Explicit JSON requests receive a JSON-only reminder. Questions about producing
  JSON and requests for JSON followed by an explanation retain their own formats.
- The calculator's description distinguishes arithmetic from program execution.
  The answer contract asks for a minimal safe execution probe when a numerical
  or branch claim determines the diagnosis. Unsafe/unavailable execution should
  be labelled as static inference, rather than presented as observed behavior.
- A failed check during a completed analysis is evidence of the reported defect,
  not authorization for endless verification or a repair. The failed receipt
  remains recorded. Implementation requests still require their pending outcomes
  and verification; incomplete diagnostic plans are also preserved.

## Live evidence

The same configured model, `deepseek/deepseek-v4.1-flash`, was used in isolated
workspaces with the same concise and thinking-off settings in before/after runs.
No GUI model preference was changed.

In 0.66.31, an explanation invented a third defect: `total(50)` supposedly
returned 55. The original implementation actually returns 50. Its JSON-only
calculation returned correct values followed by unsolicited explanatory prose.
The run failed. The earlier advice run also contained invented behavior and
176 words despite the concise setting.

The revised candidate passed all five conversation scenarios: analysis, strict
JSON arithmetic, implementation, answer-only status and a changed requirement.
The final diagnosis was 57 words and identified the two actual defects. Numerical
claims came from executing the implementation. Its numerical answer was exactly
`{"actual":44.1,"expected":49.1}`. Implementation and the changed threshold passed
independent behavioral checks with no completion/verification-state mismatches.

Four additional cases checked branch boundaries, boolean precedence, stable
deduplication order and an unavailable shipment arrival time. Both 0.66.31 and
the candidate passed all four; these are regression evidence, not a claimed
four-case improvement. The unknown fact was returned as null rather than guessed.

An initial candidate exposed the diagnostic-continuation loop described above.
That failed run is retained with the passing candidate and original failures.
No failed result was replaced with a successful retry at the same source state.

## Validation and limits

The default architecture suite now includes answer-format and latest-intent
checks. Additional cases ensure that a diagnostic failure settles without
discarding its failed receipt. The desktop conversation fixture covers 16
HTTP/SSE rounds with corrections, failure repair, steering, queued follow-ups,
Stop/resend, background work and reload.

Reproduce live checks with `benchmarks/conversation_quality.py --live --extended`
and `benchmarks/grounded_answers.py --live --output <private-directory>`.
Both accept `--exe` for an isolated candidate; they record responses and tested
binary hashes. The candidate console exercises the real desktop root, tools and
persistence. Final rebuilt-image results are retained separately under
`build/reliable-answers-06632/` together with deployment provenance.

These are small samples, not a guarantee of general factual correctness or a
measured overall speedup. Execution probes can add latency while preventing a
confidently wrong diagnosis. The contract remains model guidance; synthetic
state-transition tests do not prove semantic answer quality. Productive long
work remains uncapped, and the standalone actor migration remains deferred.
