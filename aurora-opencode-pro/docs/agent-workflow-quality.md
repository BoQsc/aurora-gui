# Planning, assistance and delegated work

Review date: 19 October 2026. Fixes: 0.66.24.

The existing durable task/checklist machinery does not establish reliable task
execution by itself. This review found defects in intent classification,
evidence lifetime and delegated handoffs. These are harness defects, independent
of the quality of the selected model.

## Corrected behavior

- Explicit requests such as "Plan how to fix this without changing files" now
  enter analysis intent and its native mutation guard. "Plan, then implement"
  retains implementation intent. This uses the existing conservative English
  classifier; it is not a general natural-language permission boundary.
- Status questions and ordinary resume requests retain action evidence from the
  current task. Completing verification after resuming no longer requires another
  edit merely to replace hidden evidence. New corrective requests, new tasks,
  branch selection and internal corrective assignments retain separate evidence
  boundaries.
- `read_plan` provides task context but cannot certify research or an inspected
  source outcome. Actual source inspection still supplies research evidence.
- Delegated reports use the selected branch's latest instruction and successful
  reply. Earlier assignments and unselected branches cannot supply the answer.
  Reported workspace changes belong to the current action scope.
- Failed, interrupted, empty or unfinished child work remains incomplete.
  Outstanding verification and checklist outcomes prevent a successful handoff.
  Failed reports and reports with required/failed checks cannot certify a parent
  outcome. Subagent rows display the recorded incomplete state.

No transcript entries are removed. Plans, branches and previous assignments
remain saved.

## Verification

```text
python tests/run_architecture_checks.py agent_workflow_contracts agent_handoff_contracts conversation_quality_contracts task_policy_contracts early_plan_contracts plan_consistency_contracts orchestrator_headless_smoke
python tests/test_task_continuation.py --debug
python tests/test_conversation_flow.py
python tests/test_resume_evidence.py
python tests/test_provider_roundtrip.py --production
python tests/test_latency_transport.py --delivery --release --vulkan
```

The first workflow regression failed against the previous implementation because
a status question hid a successful edit. The production fixture checks the real
built desktop image with an isolated local HTTP/SSE provider and private storage:
a planning-only write must fail, a document is saved, a required fact pauses the
task, and supplying it resumes verification without another write. It requires
exactly seven model requests, accepted verification and a completed task.
No fixture uses hosted models or real deployment destinations.

## Competitive assessment and remaining gaps

Aurora's tracked checklist is not equivalent to a full planning workflow.
The current [OpenCode agent documentation](https://opencode.ai/docs/agents/)
describes separate Build/Plan primary agents, permission settings and specialized
subagents. [Claude Code](https://code.claude.com/docs/en/sub-agents) and
[Codex](https://learn.chatgpt.com/docs/agent-configuration/subagents) document
dedicated subagent workflows. Those feature descriptions are comparison targets,
not measured quality rankings.

Aurora's multi-agent routing remains experimental. This change does not provide
isolated worktrees per worker, a new explicit Plan/Build selector, or a semantic
judge of whether a patch satisfies every requested behavior. The classifier still
has limited English phrase coverage. A successful tool receipt proves an action
ran, not that its assertions cover the whole task.

The earlier ten-task OpenCode comparison is too small and synthetic to establish
parity on long tasks, planning quality, interruptions or recovery. No fresh
same-task comparison against Claude Code, Codex and OpenCode was run in this
review. Such a comparison needs matched tasks and models where available,
independent behavioral checks, several repetitions, and separate reporting of
local client overhead versus provider/network latency. These corrections should
be judged by the reproduced failures they fix; they are not evidence of overall
competitive parity.
