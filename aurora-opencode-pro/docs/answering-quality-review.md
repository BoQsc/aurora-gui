# Answering quality checkpoint: 0.66.31

This bounded pass addresses a demonstrated failure in the active desktop path.
The actor migration remains deferred. Further feature work waits for human review.

## Reproduced problem

With the configured live model, 0.66.30 was asked:

> How would you fix invoice.py? Delivery should cost 5 below a merchandise subtotal of 50 and be free at 50 or above. Coupons should discount only merchandise by 10%. Explain your proposed approach and tradeoffs.

It created an automatic implementation goal, changed the source and added tests,
then answered that the file "now bills delivery first". An independent check
confirmed the file changed despite this being an advice question. The classifier
also failed a regression assertion on "How would you fix it?".

An independent five-turn live evaluation completed the arithmetic, implementation,
status and changed-requirement cases, but its first explanation contained a false
defect: it called 60 with a 10% coupon returning 54 incorrect. The requested rule
actually requires 54. The report failed its concision check as well. These failures
are retained; the evaluation is not represented as an overall pass.

## Change

Modal advice questions such as "What would you change?" and "Which files could
you remove?" now stay questions. A later explicit instruction in another sentence
still takes effect. "Can you fix it?" remains an action request. Questions preserve
the existing plan and verification state, settle without task continuation, and
do not manufacture a persistent goal. This fixes a boundary relevant to long
tasks: asking about an approach must not silently resume unfinished work.

The ordinary model prompt now asks it to distinguish observed behavior from the
requested rule, check examples against both, and avoid inventing requirements.
This guidance is probabilistic; it is not a guarantee of factual correctness.

## Review evidence and limits

`benchmarks/conversation_quality.py --live --advice` reproduces the natural-language
advice case with the actual configured provider and independent file checks.
`--live --extended` covers five turns including calculation and a changed threshold.
They use isolated workspaces and do not change GUI provider settings. Results
record the executable hash. Captured before/after responses and post-build checks
are kept under `build/answering-quality-review-06631/`.

The targeted regression gate covers question/action intent, plan preservation,
task continuation, goal state, compaction and context continuity. Post-build checks
also cover a goal waiting for a missing fact and resuming, and exact history recall
after compaction. Scripted provider tests establish control flow, not model quality.
Live examples are small samples, without a general quality or speedup claim.

Human review: compare the advice answers, try asking a question during unfinished
work, and then explicitly authorize the next step. Judge whether the boundary and
explanation feel clearer. Do not expand this pass into another architecture rewrite.
