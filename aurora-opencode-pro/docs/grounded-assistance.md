# Grounded assistance, 0.66.25

This release improves the agent's inputs, action boundaries and recovery. It
keeps the selected model and reasoning settings; it does not claim to increase
the underlying model's intelligence or guarantee correct reasoning.

## Decisions and evidence

The execution contract asks the model to separate facts, hypotheses and unknowns,
resolve the most consequential unknown first, and probe the actual implementation
when describing code behavior. Checking a hypothetical expression does not prove
that code follows the assumed branch.

`calculate` provides native arithmetic in both tool modes, analysis and diagnostic
review. One call accepts 1–16 expressions, each at most 512 bytes. It supports
decimal/scientific numbers, parentheses, unary signs, addition, subtraction,
multiplication, division, remainder and right-associative exponentiation (`^`).
The bounded parser rejects identifiers, scripts, zero divisors, excessive nesting
and non-finite results. Results use double precision. Calculations supply
research evidence; they do not certify source verification or a successful edit.

The bounded task context now carries recent failed tool IDs, targets and useful
diagnostic lines, plus actual native file effects. This also enters compaction
headers. Verification metadata cannot displace the assertion error. A successful
rerun of the same target clears its earlier failure; another branch cannot supply
that success. Tool text stays quoted data. Full results and history remain saved.
The brief looks at the latest 128 path entries and contains at most 1,400 bytes.
It is a recovery aid, not a semantic classification of every possible error.
Long objective/request excerpts preserve both their beginning and ending so a
final constraint survives a bounded compaction header.
An external application rebuild can resume interrupted chats without marking
their unrelated compile/check outcomes complete.

Repeated command output no longer becomes fresh evidence simply because the
arguments change. Real workspace changes permit renewed experiments. Productive
work retains its existing unlimited continuation policy, and normal tools are
not withheld for plan maintenance.

## Intent and tool selection

Direct collaborative requests such as "Can we improve this?" now carry action
intent. "How can we improve this?" and "Should we change the API?" remain
questions. "Continue and complete" retains existing action evidence; a new
corrective request still requires fresh work.

Analysis and answer-only requests receive a smaller toolbox without native edit,
download, sync, rebuild or delegation tools. Native execution enforces the same
boundary even if a model requests an unadvertised mutation. Arithmetic, inspection
and actual behavior probes remain available. Direct commands are still governed
by the existing command policy; analysis mode is not an OS sandbox for arbitrary
executables. Local intent recognition remains conservative English parsing.

## Concise communication

The selected response style owns the length target. Concise targets 40 words,
normally within 80 words and three short sentences or bullets, with room for
requested or essential detail. The prompt and durable reminder use the same
style function, with no competing numerical limits. Recovery guidance is shorter and names actual
remaining outcomes. Visible brevity does not turn down reasoning, truncate model
answers, or require an extra summarization request.

## Verification

```text
python tests/run_architecture_checks.py calculator_contracts work_brief_contracts decision_quality_contracts tools_test conversation_quality_contracts task_continuation_contracts early_plan_contracts plan_consistency_contracts agent_workflow_contracts agent_handoff_contracts
python tests/test_task_continuation.py --debug
python tests/test_conversation_flow.py
python tests/test_intelligent_workflow.py
python tests/test_resume_evidence.py
python tests/test_provider_roundtrip.py --production
python tests/test_latency_transport.py --delivery --release --vulkan
```

The new real HTTP fixture runs the built desktop image in private storage. Ten
requests cover arithmetic during analysis, a premature answer to a collaborative
action request, a failing behavioral assertion, diagnostic retention, a correction,
accepted verification, an answer-only question and resume without needless edits.
CI includes the native contracts and built-image fixture.

An opt-in live evaluation adds independent numerical checking to the existing
analysis/implementation/question/correction suite:

```text
python benchmarks/conversation_quality.py --live --extended
```

It checks the numerical JSON answer, unchanged source during analysis/questions,
independent behavior assertions, accepted verification, settled task status and
answer length. Defaults now use a workspace outside the application checkout so
development source leases cannot contaminate the run. Credentials are removed
from saved fixture settings after execution. Timings include the hosted model
and network and cannot be interpreted as local client overhead.

The first live baseline completed its coding task but volunteered incorrect
arithmetic. An intermediate candidate also failed the new numerical check by
calculating the wrong code branch. That failure was retained and led to the
actual-implementation probe guidance. A passing small suite cannot establish a
general reasoning improvement, a universal success rate, or competitive parity.
