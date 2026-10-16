"""Read-only Aurora conversation audit; writes aggregate evidence outside live state.

No settings, chat state, source files, running applications or provider APIs are
changed. Stored conversation text is evidence, never executable instructions.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import statistics


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {
        "count": len(values), "min": values[0], "median": statistics.median(values),
        "p95": values[int(0.95 * (len(values) - 1))], "max": values[-1],
        "sum": sum(values),
    }


def message_time(message):
    match = re.match(r"m(\d+)-", message["id"])
    if not match:
        return None
    instant = datetime(1, 1, 1, tzinfo=timezone.utc)
    instant += timedelta(microseconds=int(match[1]) // 10)
    return instant


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path,
                        default=Path(os.environ["APPDATA"]) / "Aurora OpenCode")
    parser.add_argument("--chat", default="t-m639276073661326566-0")
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).with_name("metrics.json"))
    args = parser.parse_args()
    state, output = args.state.resolve(), args.output.resolve()
    if output.is_relative_to(state):
        raise ValueError("Audit output must be outside the live state directory")
    chat_path = state / "threads" / (args.chat + ".json")
    raw = chat_path.read_bytes()
    messages = json.loads(raw.decode("utf-8-sig"))["messages"]
    index = json.loads((state / "threads.index.json").read_text(encoding="utf-8-sig"))
    meta = next(x for x in index["sessions"] if x["id"] == args.chat)
    by_id = {x["id"]: x for x in messages}
    requested_leaf = meta.get("activeLeaf", "")
    leaf = requested_leaf if requested_leaf in by_id else messages[-1]["id"]
    path, seen = [], set()
    current = by_id.get(leaf)
    while current and current["id"] not in seen:
        seen.add(current["id"])
        path.append(current)
        current = by_id.get(current.get("parentId"))
    path.reverse()
    assistants = [x for x in path if x["role"] == "assistant"]
    tools = [x for x in path if x["role"] == "tool"]
    projects = json.loads((state / "projects.json").read_text(encoding="utf-8-sig"))
    project = next((x for x in projects.get("projects", [])
                    if x["id"] == meta.get("project")), {})
    rounds = [x for x in assistants if x.get("toolCalls")]
    calls = [c for x in rounds for c in x["toolCalls"]]
    repeats = Counter((c["name"], c["arguments"]) for c in calls)
    controls = Counter()
    continuations = []
    notices = []
    for x in path:
        if not x.get("internal"):
            continue
        content = x["content"]
        if content.startswith("Durable task-state checkpoint"):
            controls["task_checkpoint"] += 1
        elif content.startswith("Progress guidance:"):
            controls["progress_guidance"] += 1
        elif content.startswith("Continuation: unfinished authorized work\n"):
            controls["task_continuation"] += 1
            try:
                continuations.append(json.loads(content.split("\n")[1]))
            except (ValueError, IndexError):
                pass
        elif content.startswith("The application was rebuilt"):
            controls["rebuild_notice"] += 1
            notices.append({"message_id": x["id"], "content": content})
        else:
            controls["other"] += 1

    logs = []
    for logfile in (state / "logs").glob("errors*.log"):
        # These logs contain diagnostics, not request bodies or credentials.
        lines = logfile.read_text(encoding="utf-8", errors="replace").splitlines()
        logs.extend(lines)
    logs.sort()
    requests = {}
    stages = Counter()
    finished_tools = []
    latencies = []
    payloads = []
    scope_times = []
    for line in logs:
        if args.chat in line and "agent-lifecycle {" in line:
            try:
                event = json.loads(line[line.index("{"):])
            except ValueError:
                continue
            if event.get("thread") != args.chat:
                continue
            scope_times.append(line.split(" [", 1)[0])
            stages[event["stage"]] += 1
            if event["stage"] == "request.prepared":
                requests[event["request"]] = event
            if event["stage"] == "tool.finished":
                finished_tools.append(event)
        for marker, destination in [("request latency:", latencies),
                                    ("request payload:", payloads)]:
            if marker not in line:
                continue
            fields = dict(re.findall(r"(\w+)=([^\s]+)", line))
            if marker == "request latency:" and fields.get("milestone") != "settled":
                continue
            if int(fields.get("id", -1)) not in requests:
                continue
            for key, value in list(fields.items()):
                try:
                    fields[key] = int(value)
                except ValueError:
                    pass
            fields["logged_at"] = line.split(" [", 1)[0]
            destination.append(fields)

    image_blobs = Counter()
    external_browser_runs = []
    recognized_check_workdirs = Counter()
    for x in tools:
        if x.get("toolName") == "view_image" and not x.get("failed"):
            match = re.search(r"Original attachmentBlob: ([0-9A-F]+)", x["content"])
            if match:
                image_blobs[match[1]] += 1
        if x.get("toolName") == "run":
            try:
                invocation = json.loads(x.get("toolArgs", "{}"))
            except ValueError:
                continue
            program = Path(invocation.get("program", "")).stem.lower()
            if program in {"chrome", "msedge", "chromium", "playwright"}:
                external_browser_runs.append(x["id"])
            arguments = invocation.get("args", [])
            recognized = (
                program in {"dmd", "ldc2", "gdc"} and any(a.endswith(".d") for a in arguments)
            ) or (program == "dub" and arguments and arguments[0] in {"build", "test"})
            if recognized and not x.get("failed"):
                recognized_check_workdirs[invocation.get("workdir", "(default)")] += 1

    journal_verification = Counter()
    journal_projects = Counter()
    last_ticks = int(re.match(r"m(\d+)-", path[-1]["id"])[1])
    with (state / "runtime-events.jsonl").open(encoding="utf-8-sig") as stream:
        for line in stream:
            if args.chat not in line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if (event.get("threadId") != args.chat or event["type"] != "thread.updated"
                    or event.get("recordedAt", 0) > last_ticks):
                continue
            payload = event.get("payload", {})
            journal_verification[payload.get("verificationStatus", "")] += 1
            journal_projects[payload.get("projectId", "")] += 1

    # A conservative estimate only: an identical command can be necessary after
    # a source edit. The audit does not label repeated checks as wasted work.
    repeated_summary = []
    for (name, arguments), count in repeats.most_common(15):
        try:
            parsed = json.loads(arguments)
        except ValueError:
            parsed = {}
        repeated_summary.append({
            "tool": name, "count": count,
            "program": parsed.get("program"), "args": parsed.get("args"),
        })

    first_time, last_time = message_time(path[0]), message_time(path[-1])
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "chat": args.chat, "title": meta.get("title"), "model": meta.get("model"),
        "snapshot": {
            "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw),
            "stored_messages": len(messages), "selected_path_messages": len(path),
            "requested_leaf": requested_leaf, "audited_leaf": leaf,
            "live_index_ahead_of_snapshot": requested_leaf != leaf,
            "first_message_utc": first_time.isoformat(),
            "last_message_utc": last_time.isoformat(),
            "span_hours": (last_time - first_time).total_seconds() / 3600,
        },
        "task": {
            "objective": meta.get("objective"), "status": meta.get("taskStatus"),
            "verification": meta.get("verificationStatus"),
            "summary_characters": len(meta.get("compactionSummary", "")),
        },
        "path_metrics": {
            "roles": dict(Counter(x["role"] for x in path)),
            "human_messages": sum(x["role"] == "user" and not x.get("internal") for x in path),
            "tool_calls": len(calls), "tool_rounds": len(rounds),
            "batched_rounds": sum(len(x["toolCalls"]) > 1 for x in rounds),
            "tool_names": dict(Counter(c["name"] for c in calls)),
            "failed_tools": sum(bool(x.get("failed")) for x in tools),
            "tool_elapsed_seconds_sum": sum(x.get("toolElapsedMs", 0) for x in tools) / 1000,
            "prompt_tokens": distribution([x["promptTokens"] for x in assistants if x.get("promptTokens")]),
            "completion_tokens_sum": sum(x.get("completionTokens", 0) for x in assistants),
            "tool_output_characters": sum(len(x["content"]) for x in tools),
            "internal_characters": sum(len(x["content"]) for x in path if x.get("internal")),
            "controls": dict(controls),
            "continuation_stalled": dict(Counter(x["stalled"] for x in continuations)),
            "repeated_identical_calls": sum(n - 1 for n in repeats.values() if n > 1),
            "most_repeated_calls": repeated_summary,
            "successful_image_inspections_with_blob": sum(image_blobs.values()),
            "distinct_inspected_image_blobs": len(image_blobs),
            "direct_external_browser_runs": external_browser_runs,
            "assistant_errors": dict(Counter(x.get("error", "") for x in assistants if x.get("failed"))),
        },
        "rebuild_notices": notices,
        "verification_scope": {
            "chat_project": project,
            "successful_recognized_check_workdirs": dict(recognized_check_workdirs),
            "successful_recognized_checks_matching_project": sum(
                n for workdir, n in recognized_check_workdirs.items()
                if workdir.lower() == project.get("path", "").lower()
            ),
            "journal_thread_updated_verification_states": dict(journal_verification),
            "journal_thread_updated_projects": dict(journal_projects),
        },
        "all_stored_branch_assistant_errors": dict(Counter(
            x.get("error", "") for x in messages
            if x["role"] == "assistant" and x.get("failed")
        )),
        "logs": {
            "scope_start_local": min(scope_times) if scope_times else None,
            "scope_end_local": max(scope_times) if scope_times else None,
            "stage_counts": dict(stages), "matched_request_latencies": len(latencies),
            "prepared_message_bytes": distribution([x["messageBytes"] for x in requests.values()]),
            "prepared_context_budget": distribution([x["contextBudget"] for x in requests.values()]),
            "latency_fields": {
                key: distribution([x[key] for x in latencies if isinstance(x.get(key), int) and x[key] >= 0])
                for key in ["acceptedUs", "serializedUs", "uploadedUs", "firstTokenUs", "settledUs", "bytes"]
            },
            "wire_payload_fields": {
                key: distribution([x[key] for x in payloads if isinstance(x.get(key), int)])
                for key in ["wireBytes", "textBytes", "reasoningBytes", "toolOutputBytes", "imageBase64Bytes", "argumentBytes"]
            },
            "requests_without_first_token": [x for x in latencies if x.get("firstTokenUs", -1) < 0],
            "tool_elapsed_seconds_sum": sum(x.get("elapsedMs", 0) for x in finished_tools) / 1000,
            "tool_queued_ms": distribution([x.get("queuedMs", 0) for x in finished_tools]),
            "compile_or_check_successes": sum(bool(x.get("verificationPassed")) for x in finished_tools),
            "unknown_run_invalidations": sum(x["tool"] == "run" and x.get("workspaceChanged", False) for x in finished_tools),
        },
        "limitations": [
            "Live session: this is a timestamped snapshot, not a final conversation total.",
            "Selected path follows saved parent IDs; other branches are excluded.",
            "Provider prompt-token totals include repeated history and potentially cached tokens; not unique or billable tokens.",
            "Repeated identical tools can be justified by intervening edits; no waste fraction is inferred.",
            "Retained logs cover only part of the conversation; latency fields are cumulative milestones, not additive stages.",
            "Elapsed sums may overlap; the three-hour outlier could include machine suspension or callback delay.",
            "Zero direct external-browser runs does not rule out manual reference viewing or an opaque wrapper script.",
        ],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"report": str(output), "snapshot": report["snapshot"],
                      "tools": len(calls), "rounds": len(rounds),
                      "latency_requests": len(latencies)}, indent=2))


if __name__ == "__main__":
    main()
