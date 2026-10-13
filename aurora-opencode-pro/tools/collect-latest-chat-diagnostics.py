"""Collect an Aurora chat for diagnosis; Python standard library only.

Run: python collect-latest-chat-diagnostics.py
Optional: --list, --chat "chat title or id", --project-index 2 --pinned-index 1,
--observe-seconds 10, --state-dir PATH, --include-file PATH
Writes one ZIP beside this script. Does not modify Aurora, run project commands,
fetch from the network, or upload anything. Chat text and tool results ARE included.
Known keys and common credential formats are redacted; review before sharing.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile


MIB = 1024 * 1024
META_KEYS = ("id", "title", "model", "thinking", "project", "projectId", "objective",
             "taskStatus", "turnStatus", "verificationStatus", "taskSteps", "nestedPlans",
             "updatedAt", "activeLeafId", "compactionSummary", "compactedThroughMessageId")
MESSAGE_KEYS = ("id", "parentId", "role", "content", "time", "failed", "error",
                "finishReason", "toolCalls", "toolCallId", "toolName", "toolArgs", "toolDiff",
                "toolElapsedMs", "diffAdditions", "diffDeletions", "internal", "authorId",
                "promptTokens", "completionTokens", "totalTokens", "workedSeconds")
SAFE_SETTINGS = ("model", "baseUrl", "thinking", "toolsEnabled", "nativeOnly",
                 "workspace", "developerMode", "developerSourceDir", "developerAutoReapply",
                 "developerRequireLatestSource", "contextBudgetTokens", "maxToolRounds",
                 "sortSessionsByRecency", "legacyTools", "autoRetireImages",
                 "experimentalComputerUse", "experimentalOrchestrator")
SAFE_SETTINGS += ("contextBudgets", "contextCompactions")
SKIP_FIELDS = {"images", "attachments", "base64Data", "reasoning", "reasoningContent", "draft"}


def absolute(value):
    return Path(os.path.expandvars(str(value).strip().strip('"'))).expanduser().absolute()


def read_json(path, warnings, limit=128 * MIB):
    try:
        with path.open("rb") as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            warnings.append("JSON exceeded read limit: " + str(path))
            return {}
        value = json.loads(data.decode("utf-8-sig"))
        if not isinstance(value, dict):
            warnings.append("Expected a JSON object: " + str(path))
            return {}
        return value
    except (OSError, ValueError) as error:
        if path.exists():
            warnings.append(type(error).__name__ + " reading " + str(path))
        return {}


def snapshot_json(path, warnings):
    value = read_json(path, warnings)
    if not value and path.with_name(path.name + ".bak").is_file():
        value = read_json(path.with_name(path.name + ".bak"), warnings)
        if value:
            warnings.append("Used backup snapshot: " + str(path))
    return value


def activity_time(value):
    if not isinstance(value, (int, float)) or not math.isfinite(value):
        return 0
    # Journal recordedAt is D SysTime.stdTime (100 ns since year 1).
    # Snapshot updatedAt is Unix seconds. Compare them on the same clock.
    return value / 10000000 - 62135596800 if value > 10000000000000000 else value


def tail_bytes(path, limit):
    with path.open("rb") as stream:
        stream.seek(0, 2)
        size = stream.tell()
        start = max(0, size - limit)
        boundary = True
        if start:
            stream.seek(start - 1)
            boundary = stream.read(1) == b"\n"
        stream.seek(start)
        data = stream.read(limit)
    if not boundary:
        data = data.partition(b"\n")[2]
    return data.decode("utf-8-sig", errors="replace"), bool(start)


def metadata(path, hash_file=False):
    result = {"path": str(path), "exists": path.exists()}
    try:
        if path.exists():
            stat = path.stat()
            result.update(size=stat.st_size, modified_utc=datetime.fromtimestamp(
                stat.st_mtime, timezone.utc).isoformat())
            if hash_file and path.is_file() and stat.st_size <= 100 * MIB:
                with path.open("rb") as stream:
                    result["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest() \
                        if hasattr(hashlib, "file_digest") else hash_stream(stream)
    except OSError as error:
        result["error"] = type(error).__name__
    return result


def hash_stream(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(MIB), b""):
        digest.update(block)
    return digest.hexdigest()


def sensitive_key(key):
    name = re.sub(r"[^a-z0-9]", "", str(key).lower())
    return bool(re.search(r"apikey|password|passwd|secret|authorization|credential|"
                          r"privatekey|connectionstring|(?:access|auth|refresh|bot)?token$", name)) \
        or name in {"key", "keys", "pwd", "pass"}


class Redactor:
    def __init__(self, settings, max_chars=24000):
        self.max_chars = max_chars
        self.counts = Counter()
        self.secrets = set()

        def discover(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    if sensitive_key(key):
                        candidates = child if isinstance(child, list) else [child]
                        self.secrets.update(v for v in candidates if isinstance(v, str) and len(v) >= 4)
                    discover(child)
            elif isinstance(value, list):
                for child in value:
                    discover(child)
        discover(settings)

    def text(self, value):
        for secret in sorted(self.secrets, key=len, reverse=True):
            self.counts["known_setting_secret"] += value.count(secret)
            value = value.replace(secret, "[REDACTED]")
        patterns = [
            (r"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----", "[PRIVATE KEY REDACTED]"),
            (r"\b(?:sk-[A-Za-z0-9_-]{12,}|fsk_[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,})\b", "[TOKEN REDACTED]"),
            (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", "[JWT REDACTED]"),
            (r"(?i)(\b(?:Bearer|Basic|Bot)\s+)[A-Za-z0-9_+/=.~-]{8,}", r"\1[REDACTED]"),
            (r"(?i)(https?://)[^/\s@]+:[^/\s@]+@", r"\1[REDACTED]@"),
            (r"(?i)(https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api(?:/v\d+)?/webhooks/\d+/)[A-Za-z0-9_-]+", r"\1[REDACTED]"),
            (r"(?i)([?&](?:api[_-]?key|token|password|secret|access_token)=)[^&\s\"'<>]+", r"\1[REDACTED]"),
            (r"(?i)(\b[\w-]*(?:api[_-]?key|password|passwd|secret|access[_-]?token|auth[_-]?token)"
             r"[\w-]*[\"']?\s*(?:[:=]|\s)\s*)(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}<>]+)", r"\1[REDACTED]"),
            (r"(?i)(\b[\w-]*(?:token|connection[_-]?string)[\"']?\s*[:=]\s*)"
             r"(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}<>]+)", r"\1[REDACTED]"),
            (r"(?i)(\b(?:name|key)\s*=\s*[\"'][^\"']*(?:password|secret|apikey|token)[^\"']*"
             r"[\"'][^>\r\n]*?\bvalue\s*=\s*[\"'])[^\"']*", r"\1[REDACTED]"),
            (r"(?i)(<(?:password|secret|apikey|token)>)[^<]*", r"\1[REDACTED]"),
            (r"data:(?:image|audio|video)(?:/|\\/)[^\s\"']+", "[MEDIA DATA OMITTED]"),
            (r'(?i)("base64Data"\s*:\s*)"(?:[^"\\]|\\.)*"', r'\1"[MEDIA DATA OMITTED]"'),
        ]
        for pattern, replacement in patterns:
            value, count = re.subn(pattern, replacement, value)
            self.counts["credential_or_media_pattern"] += count
        return value

    def clean(self, value, depth=0):
        if depth > 30:
            return "[DEPTH LIMIT]"
        if isinstance(value, dict):
            return {str(key): "[REDACTED]" if sensitive_key(key) else self.clean(child, depth + 1)
                    for key, child in value.items() if key not in SKIP_FIELDS}
        if isinstance(value, list):
            if len(value) > 20000:
                self.counts["truncated_lists"] += 1
            return [self.clean(child, depth + 1) for child in value[:20000]]
        if isinstance(value, str):
            # Tool arguments are often JSON encoded inside a string.
            if value.lstrip().startswith(("{", "[")):
                try:
                    parsed = json.loads(value)
                    value = json.dumps(self.clean(parsed, depth + 1), ensure_ascii=False)
                except (ValueError, RecursionError):
                    pass
            value = self.text(value)
            if len(value) > self.max_chars:
                self.counts["truncated_text_fields"] += 1
                half = self.max_chars // 2
                value = value[:half] + "\n[... TEXT TRUNCATED; original chars: " + str(len(value)) + "]\n" + value[-half:]
            return value
        return value


def journal_data(state, warnings):
    path = state / "runtime-events.jsonl"
    events = []
    folded = 0
    marker = state / "journal.folded"
    if marker.is_file():
        try:
            folded = int(marker.read_text(encoding="utf-8").split()[0])
        except (OSError, ValueError, IndexError):
            warnings.append("Invalid journal checkpoint; using available journal records.")
    if path.is_file():
        try:
            text, truncated = tail_bytes(path, 32 * MIB)
        except OSError as error:
            warnings.append(type(error).__name__ + " reading runtime journal.")
            return events
        if truncated:
            warnings.append("Only the last 32 MiB of the runtime journal were read.")
        bad = 0
        for line in text.splitlines():
            try:
                event = json.loads(line)
                if not isinstance(event, dict) or not isinstance(event.get("threadId"), str):
                    continue
                payload = event.get("payload", {})
                if isinstance(payload, str):
                    payload = json.loads(payload)
                event["payload"] = payload if isinstance(payload, dict) else {}
                sequence = event.get("sequence", 0)
                event["_folded"] = isinstance(sequence, int) and 0 < sequence <= folded
                events.append(event)
            except ValueError:
                bad += 1
        if bad:
            warnings.append(str(bad) + " incomplete/invalid journal line(s) ignored; Aurora may still be writing.")
    return events


def chat_catalog(state, events, warnings):
    index = snapshot_json(state / "threads.index.json", warnings)
    if not index.get("sessions"):
        index = snapshot_json(state / "sessions.json", warnings)
    sessions = index.get("sessions", [])
    if not isinstance(sessions, list):
        sessions = []
    catalog = {item["id"]: dict(item, _creation_order=i) for i, item in enumerate(sessions)
               if isinstance(item, dict) and isinstance(item.get("id"), str)}
    snapshot_ids = set(catalog)
    for item in catalog.values():
        if "activeLeaf" in item:
            item["activeLeafId"] = item["activeLeaf"]
        item["updatedAt"] = activity_time(item.get("updatedAt"))
    for event in events:
        ident = event["threadId"]
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", ident):
            continue
        item = catalog.setdefault(ident, {"id": ident, "_creation_order": len(catalog)})
        kind = event.get("type", event.get("kind"))
        if not event["_folded"] or ident not in snapshot_ids:
            if kind in ("thread.started", "thread.updated"):
                item.update({key: event["payload"][key] for key in META_KEYS if key in event["payload"] and key != "id"})
                if "projectId" in event["payload"]:
                    item["project"] = event["payload"]["projectId"]
            if kind == "thread.deleted":
                item["deleted"] = True
            elif kind == "thread.started":
                item.pop("deleted", None)
            elif kind == "item.added" and isinstance(event.get("itemId"), str):
                item["activeLeafId"] = event["itemId"]
            elif kind in ("turn.started", "turn.completed", "turn.interrupted", "turn.failed"):
                item["turnStatus"] = {"started": "running"}.get(kind[5:], kind[5:])
        item["updatedAt"] = max(activity_time(event.get("recordedAt")), activity_time(item.get("updatedAt")))
    for item in catalog.values():
        ident = str(item["id"])
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", ident):
            item["deleted"] = True
            continue
        path = state / "threads" / (ident + ".json")
        if not item.get("updatedAt") and path.is_file():
            try:
                item["updatedAt"] = path.stat().st_mtime
            except OSError:
                pass
    return sorted((item for item in catalog.values() if not item.get("deleted")),
                  key=lambda item: activity_time(item.get("updatedAt")), reverse=True)


def chat_messages(state, chat, events, warnings, active_only=True):
    path = state / "threads" / (chat["id"] + ".json")
    snapshot = snapshot_json(path, warnings)
    raw = snapshot.get("messages", chat.get("messages", []))
    messages = [dict(item) for item in raw if isinstance(item, dict)] if isinstance(raw, list) else []
    by_id = {item["id"]: item for item in messages if isinstance(item.get("id"), str)}
    for event in events:
        if event["threadId"] != chat["id"] or event.get("type", event.get("kind")) not in ("item.added", "item.updated"):
            continue
        payload = event["payload"]
        ident = event.get("itemId") or payload.get("id")
        if event["_folded"] and snapshot and ident in by_id:
            continue
        if not isinstance(ident, str) or not ident or not any(key in payload for key in ("role", "content", "error", "toolCalls")):
            continue
        if ident not in by_id:
            by_id[ident] = {"id": ident}
            messages.append(by_id[ident])
        by_id[ident].update({key: payload[key] for key in (*MESSAGE_KEYS, "images") if key in payload})
    if not active_only:
        return messages, len(messages)
    leaf = chat.get("activeLeafId")
    if isinstance(leaf, str) and leaf and leaf in by_id:
        active, seen = [], set()
        while isinstance(leaf, str) and leaf in by_id and leaf not in seen:
            seen.add(leaf)
            active.append(by_id[leaf])
            leaf = by_id[leaf].get("parentId")
        if leaf:
            warnings.append("Active branch has a missing parent or cycle; exported all available messages instead.")
        else:
            return list(reversed(active)), len(messages)
    elif leaf:
        warnings.append("Active branch leaf is missing; exported all available messages instead.")
    return messages, len(messages)


def run(arguments, cwd=None, timeout=8):
    try:
        env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
        result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True,
                                encoding="utf-8", errors="replace", timeout=timeout,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return {"exit_code": result.returncode, "output": (result.stdout + result.stderr)[-40000:]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": type(error).__name__}


def read_id_list(path, warnings):
    for candidate in (path, path.with_name(path.name + ".bak")):
        if not candidate.is_file():
            continue
        try:
            with candidate.open("rb") as stream:
                data = stream.read(4 * MIB + 1)
            if len(data) > 4 * MIB:
                raise ValueError("Read limit")
            value = json.loads(data.decode("utf-8-sig"))
            if isinstance(value, list):
                return [item for item in value if isinstance(item, str)]
        except (OSError, ValueError):
            warnings.append("Could not read sidebar preferences: " + str(candidate))
    return []


def sidebar_inventory(state, catalog, settings, warnings):
    raw = snapshot_json(state / "projects.json", warnings).get("projects", [])
    projects = [{key: item[key] for key in ("id", "name", "path") if key in item}
                for item in raw if isinstance(item, dict) and isinstance(item.get("id"), str)] \
        if isinstance(raw, list) else []
    if not any(item["id"] == "sandbox" for item in projects):
        projects.insert(0, {"id": "sandbox", "name": "sandbox 1",
                           "path": str(state / "sandbox" / "sandbox 1")})
    pins = set(read_id_list(state / "pins.json", warnings))
    archived = set(read_id_list(state / "archived.json", warnings))
    recency = settings.get("sortSessionsByRecency", True) is not False
    # UI traverses the saved sessions newest-created first, then stably sorts
    # each pinned/unpinned group by updatedAt when recency sorting is enabled.
    ordered = sorted(catalog, key=lambda c: c.get("_creation_order", 0), reverse=True)
    if recency:
        ordered.sort(key=lambda c: activity_time(c.get("updatedAt")), reverse=True)
    inventory = []
    for number, project in enumerate(projects, 1):
        members = [c for c in ordered if (c.get("project") or c.get("projectId") or "sandbox") == project["id"]
                   and c["id"] not in archived]
        pinned = [c for c in members if c["id"] in pins]
        inventory.append({"project_index": number, **project,
                          "visible_chats": len(members),
                          "pinned_chats": [{"pinned_index": i, "id": c["id"],
                                            "title": c.get("title", "Untitled"), "updatedAt": c.get("updatedAt")}
                                           for i, c in enumerate(pinned, 1)]})
    return inventory, recency


def pinned_selection(inventory, catalog, project_index, pinned_index):
    project = next((p for p in inventory if p["project_index"] == project_index), None)
    if project is None:
        raise ValueError("Project " + str(project_index) + " was not found. Run --list to see project positions.")
    pinned = project["pinned_chats"]
    if not 1 <= pinned_index <= len(pinned):
        raise ValueError("Pinned chat " + str(pinned_index) + " was not found in project " +
                         str(project.get("name", project["id"])) + ". Run --list; no other chat was substituted.")
    ident = pinned[pinned_index - 1]["id"]
    return next(c for c in catalog if c["id"] == ident)


def processes():
    powershell = shutil.which("powershell.exe")
    if os.name != "nt" or not powershell:
        return []
    command = """
$ErrorActionPreference='SilentlyContinue'
$all=@(Get-CimInstance Win32_Process)
$ids=@{}
foreach($p in $all){if($p.Name -like '*aurora*'){$ids[[int]$p.ProcessId]=$true}}
do{$changed=$false;foreach($p in $all){if($ids.ContainsKey([int]$p.ParentProcessId) -and -not $ids.ContainsKey([int]$p.ProcessId)){$ids[[int]$p.ProcessId]=$true;$changed=$true}}}while($changed)
@($all | Where-Object {$ids.ContainsKey([int]$_.ProcessId) -or $_.Name -match '^(dmd|dub|ldc2?|rg|git|robocopy)\\.exe$'} | Select-Object -First 100 | ForEach-Object {
$live=Get-Process -Id $_.ProcessId
[PSCustomObject]@{name=$_.Name;pid=$_.ProcessId;parent_pid=$_.ParentProcessId;exe=$_.ExecutablePath;responding=$live.Responding;started_utc=if($_.CreationDate){$_.CreationDate.ToUniversalTime().ToString('o')}else{$null};cpu_100ns=([double]$_.KernelModeTime+[double]$_.UserModeTime);read_bytes=[double]$_.ReadTransferCount;write_bytes=[double]$_.WriteTransferCount;working_set_bytes=[double]$_.WorkingSetSize;threads=$_.ThreadCount;handles=$_.HandleCount;aurora_tree=$ids.ContainsKey([int]$_.ProcessId)}
}) | ConvertTo-Json -Compress
"""
    result = run([powershell, "-NoProfile", "-NonInteractive", "-Command", command])
    try:
        value = json.loads(result.get("output", "[]") or "[]")
        return value if isinstance(value, list) else [value]
    except ValueError:
        return [{"unavailable": "Process inspection failed, timed out, or returned incomplete data."}]


def git_context(folder):
    git = shutil.which("git")
    if not git or not folder or not Path(folder).is_dir():
        return {"available": False}
    prefix = [git, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false", "-C", str(folder)]
    head = run(prefix + ["rev-parse", "HEAD"])
    if head.get("exit_code") != 0:
        return {"available": False, "head": head}
    return {name: run(prefix + args) for name, args in {
        "head": ["rev-parse", "HEAD"], "branch": ["branch", "--show-current"],
        "status": ["status", "--short"], "changes_summary": ["diff", "--no-ext-diff", "--no-textconv", "--stat"],
        "staged_summary": ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--stat"],
    }.items()}


def analyze_messages(messages, chat):
    calls, results, signatures = {}, {}, Counter()
    latest_user = max((i for i, m in enumerate(messages) if m.get("role") == "user" and not m.get("internal")), default=-1)
    latest_plan = max((i for i, m in enumerate(messages) if m.get("role") == "tool" and m.get("toolName") == "update_plan"), default=-1)
    positions = {m.get("id"): i for i, m in enumerate(messages)}
    for message in messages:
        for call in message.get("toolCalls", []) if isinstance(message.get("toolCalls"), list) else []:
            if not isinstance(call, dict):
                continue
            function = call.get("function", call)
            if not isinstance(function, dict):
                continue
            name, arguments = function.get("name"), function.get("arguments", "{}")
            try:
                canonical = json.dumps(json.loads(arguments), sort_keys=True) if isinstance(arguments, str) else json.dumps(arguments, sort_keys=True)
            except (ValueError, TypeError):
                canonical = str(arguments)
            signatures[(str(name), canonical)] += 1
            if call.get("id"):
                calls[call["id"]] = {"id": call["id"], "name": name,
                                     "arguments": arguments, "assistant_message": message.get("id")}
                # Providers may reuse IDs in later rounds. An older reply must
                # not make a new, unanswered occurrence look complete.
                results.pop(call["id"], None)
        if message.get("role") == "tool" and message.get("toolCallId"):
            results[message["toolCallId"]] = message
    pending = [call for ident, call in calls.items() if ident not in results]
    current_pending = [call for call in pending if positions.get(call.get("assistant_message"), -1) > latest_user]
    orphaned = [ident for ident in results if ident not in calls]
    continuations = [m for m in messages if m.get("internal") and
                     str(m.get("content", "")).startswith(("Continuation:", "Plan reconciliation checkpoint:"))]
    steps = chat.get("taskSteps", [])
    incomplete = [step for step in steps if isinstance(step, dict) and step.get("status") != "completed"] if isinstance(steps, list) else []
    return {"pending_tool_calls": pending, "current_turn_pending_tool_calls": current_pending,
            "historical_pending_count": len(pending) - len(current_pending),
            "plan_predates_latest_request": bool(chat.get("taskSteps") and latest_user > latest_plan >= 0),
            "orphan_tool_result_ids": orphaned,
            "repeated_calls": [{"name": name, "arguments": arguments, "attempts": count}
                               for (name, arguments), count in signatures.most_common(30) if count > 1],
            "finish_reasons": dict(Counter(m["finishReason"] for m in messages if m.get("finishReason"))),
            "automatic_continuations": len(continuations),
            "latest_continuation": continuations[-1].get("content") if continuations else None,
            "unfinished_steps": incomplete,
            "ended_with_unfinished_work": chat.get("turnStatus") == "completed" and
                bool(incomplete or chat.get("verificationStatus") == "required"),
            "note": "Pending calls may still be running; repeated calls alone do not establish a stall."}


def image_inventory(state, messages):
    inventory = []
    for message in messages:
        for image in message.get("images", []) if isinstance(message.get("images"), list) else []:
            if not isinstance(image, dict):
                continue
            entry = {key: image[key] for key in ("name", "mimeType", "blob", "originalBlob",
                     "width", "height", "originalWidth", "originalHeight", "normalizationVersion", "attachmentError") if key in image}
            entry["message_id"] = message.get("id")
            entry["inline_base64_chars"] = len(image.get("base64Data", "")) if isinstance(image.get("base64Data", ""), str) else 0
            blob = image.get("originalBlob") or image.get("blob")
            if isinstance(blob, str) and re.fullmatch(r"[0-9A-Fa-f]{64}", blob):
                entry["stored_original"] = metadata(state / "attachments" / (blob + ".b64"))
            inventory.append(entry)
    return inventory


def cached_outputs(state, messages, redactor, warnings):
    files, paths = {}, {}
    for position, message in enumerate(messages):
        text = str(message.get("content", "")) + "\n" + str(message.get("toolArgs", ""))
        for name in re.findall(r"(?:tool-output[/\\]+)(\d+-\d+\.txt)\b", text):
            paths[state / "tool-output" / name] = position
        for identity in re.findall(r"\bp-\d+-\d+\b", text):
            paths[Path(tempfile.gettempdir()) / ("aurora-opencode-process-" + identity + ".out")] = position
    for i, path in enumerate(sorted(paths, key=lambda p: (paths[p], str(p)), reverse=True)[:30]):
        if not path.is_file():
            warnings.append("Referenced tool output is no longer available: " + str(path))
            continue
        try:
            text, truncated = tail_bytes(path, 2 * MIB)
            files["tool-output/" + str(i) + "-" + path.name] = redactor.text(text)
            if truncated:
                warnings.append("Referenced output tail only: " + str(path))
        except OSError:
            warnings.append("Could not read referenced tool output: " + str(path))
    if len(paths) > 30:
        warnings.append("Referenced output collection limited to the 30 most recently referenced files.")
    return files


def project_sources(workspace, redactor, warnings):
    """Bounded text snapshot of this project's code, without following links."""
    if not workspace or not Path(workspace).is_dir():
        return {}, []
    root = Path(workspace).resolve()
    excluded = {".git", ".dub", "build", "bin", "obj", "target", "node_modules",
                ".venv", "venv", "__pycache__", "dist", "loop-investigation"}
    extensions = {".d", ".di", ".py", ".rs", ".c", ".h", ".cpp", ".hpp",
                  ".js", ".ts", ".tsx", ".jsx", ".html", ".css", ".lua"}
    root_files = {"dub.json", "dub.sdl", "dub.selections.json", "package.json",
                  "cargo.toml", "readme.md", "agents.md", "cmakelists.txt"}
    files, inventory, total = {}, [], 0

    def linked(path):
        try:
            return path.is_symlink() or bool(getattr(path.lstat(), "st_file_attributes", 0) & 0x400)
        except OSError:
            return True

    for directory, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d.lower() not in excluded and
                         not d.startswith(".") and not linked(Path(directory) / d))
        for name in sorted(names):
            path = Path(directory) / name
            if (path.suffix.lower() not in extensions and name.lower() not in root_files) or \
                    re.search(r"(?i)credential|secret|private.?key|settings|publisher", name) or linked(path):
                continue
            try:
                if root not in path.resolve().parents:
                    continue
                with path.open("rb") as stream:
                    raw = stream.read(512 * 1024 + 1)
                if len(raw) > 512 * 1024 or b"\x00" in raw:
                    warnings.append("Project source omitted (large/binary): " + str(path))
                    continue
                if len(files) >= 500 or total + len(raw) > 8 * MIB:
                    warnings.append("Project source snapshot reached its 500-file/8-MiB limit.")
                    return files, inventory
                member = "project-source/" + path.relative_to(root).as_posix()
                files[member] = redactor.text(raw.decode("utf-8-sig"))
                inventory.append({**metadata(path), "archive_member": member,
                                  "sha256_before_redaction": hashlib.sha256(raw).hexdigest()})
                total += len(raw)
            except (OSError, UnicodeError):
                warnings.append("Could not read project source: " + str(path))
    return files, inventory


def aurora_source_diff(folder, redactor):
    git = shutil.which("git")
    if not git:
        return {}
    prefix = [git, "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", str(folder)]
    result = {}
    for label, options in [("working", []), ("staged", ["--cached"])]:
        diff = run(prefix + ["diff", *options, "--no-ext-diff", "--no-textconv", "--", "*.d", "*.di", "*.py"])
        if diff.get("exit_code") == 0 and diff["output"]:
            result[label + ".diff"] = redactor.text(diff["output"])
    return result


def observe_activity(state, chat_id, seconds, include_processes=True):
    def snapshot():
        paths = [state / "threads" / (chat_id + ".json"), state / "runtime-events.jsonl",
                 state / "logs" / "errors.log"]
        return {"captured_utc": datetime.now(timezone.utc).isoformat(),
                "files": [metadata(path) for path in paths], "processes": processes() if include_processes else []}
    before = snapshot()
    started = time.monotonic()
    time.sleep(seconds)
    after = snapshot()
    deltas = []
    previous = {(p.get("pid"), p.get("started_utc")): p for p in before["processes"]}
    for p in after["processes"]:
        old = previous.get((p.get("pid"), p.get("started_utc")))
        if old is None:
            continue
        row = {key: p.get(key) for key in ("pid", "name", "aurora_tree")}
        for field, label, divisor in (("cpu_100ns", "cpu_seconds", 10000000),
                                      ("read_bytes", "read_bytes", 1), ("write_bytes", "write_bytes", 1)):
            if isinstance(p.get(field), (float, int)) and isinstance(old.get(field), (float, int)):
                row[label] = max(0, (p[field] - old[field]) / divisor)
        deltas.append(row)
    changed = [a["path"] for b, a in zip(before["files"], after["files"])
               if (b.get("size"), b.get("modified_utc")) != (a.get("size"), a.get("modified_utc"))]
    return {"requested_seconds": seconds, "elapsed_seconds": round(time.monotonic() - started, 3),
            "before": before, "after": after, "process_deltas": deltas, "changed_files": changed,
            "note": "A quiet interval can be a legitimate provider/lock wait. These samples alone cannot prove a hang; process activity may belong to another chat."}


def collect(state, chat_query=None, max_messages=1000, include_processes=True,
            project_index=None, pinned_index=None, log_limit=2 * MIB, max_text_chars=100000,
            process_snapshot=None, include_project_source=False):
    warnings = []
    settings = read_json(state / "settings.json", warnings, 4 * MIB)
    publisher = read_json(state / "forge-publisher.json", warnings, 64 * 1024)
    redactor = Redactor({"settings": settings, "publisher": publisher}, max_chars=max_text_chars)
    events = journal_data(state, warnings)
    catalog = chat_catalog(state, events, warnings)
    sidebar, by_recency = sidebar_inventory(state, catalog, settings, warnings)
    if chat_query:
        exact = [item for item in catalog if chat_query.casefold() in
                 (item["id"].casefold(), str(item.get("title", "")).casefold())]
        choices = exact or [item for item in catalog if chat_query.casefold() in str(item.get("title", "")).casefold()]
        if len(choices) != 1:
            raise ValueError("Chat selection is missing or ambiguous. Run --list, then use --chat with its exact ID.")
    elif project_index is not None or pinned_index is not None:
        if project_index is None or pinned_index is None:
            raise ValueError("Supply both --project-index and --pinned-index.")
        choices = [pinned_selection(sidebar, catalog, project_index, pinned_index)]
    else:
        choices = catalog
    chat, messages, graph_count = {}, [], 0
    for candidate in choices:
        candidate_messages, count = chat_messages(state, candidate, events, warnings)
        if candidate_messages or chat_query or project_index is not None:
            chat, messages, graph_count = candidate, candidate_messages, count
            break
    if not chat:
        warnings.append("No nonempty chat was found. Check --state-dir and save/close Aurora before retrying.")
    graph, _ = chat_messages(state, chat, events, warnings, active_only=False) if chat else ([], 0)
    diagnosis = analyze_messages(messages, chat)
    media = image_inventory(state, graph)
    total = len(messages)
    if total > max_messages:
        warnings.append("Conversation limited to its first user prompt and last " + str(max_messages) + " messages.")
        first_user = next((item for item in messages if item.get("role") == "user"), None)
        messages = messages[-max_messages:]
        if first_user and first_user is not messages[0] and first_user not in messages:
            messages.insert(0, first_user)
    exported = [{key: item[key] for key in MESSAGE_KEYS if key in item} for item in messages]
    project_list = read_json(state / "projects.json", warnings, 4 * MIB).get("projects", [])
    if not isinstance(project_list, list):
        project_list = []
    project_id = chat.get("project", chat.get("projectId"))
    project = next((item for item in project_list if isinstance(item, dict) and item.get("id") == project_id), {})
    project = {key: project[key] for key in ("id", "name", "path") if key in project}
    workspace = project.get("path") or settings.get("workspace")
    running = process_snapshot if process_snapshot is not None else processes() if include_processes else []
    images = [absolute(item["exe"]) for item in running if isinstance(item, dict) and item.get("exe")]
    source_candidates = [state / "source", state / "source" / "aurora-opencode-pro",
                         state / "source" / "aurora-gui" / "aurora-opencode-pro",
                         state / "source" / "aurora-gui-main" / "aurora-opencode-pro"]
    if settings.get("developerSourceDir"):
        saved = absolute(settings["developerSourceDir"])
        source_candidates = [saved, saved / "aurora-opencode-pro"] + source_candidates
    for image in images:
        source_candidates.extend(list(image.parents)[:6])
    sources = []
    for folder in dict.fromkeys(source_candidates):
        recipe = read_json(folder / "dub.json", warnings, MIB)
        if recipe.get("name") == "aurora-opencode-pro":
            sources.append(folder)
    log_names = ("errors.log", "errors.previous.log", "native-crash.log", "emergency.log")
    log_paths = [state / "logs" / name for name in log_names]
    log_paths += [state / "rebuild.log", state / "unexpected-exits.log"]
    folders = list(dict.fromkeys(sources + [image.parent for image in images]))
    log_paths += [folder / "logs" / name for folder in folders for name in log_names]
    log_paths += [folder / name for folder in folders for name in ("build.log", "rebuild-report.txt", "rebuild.log", "unexpected-exits.log")]
    files = cached_outputs(state, graph + messages, redactor, warnings)
    project_inventory = []
    if include_project_source:
        code, project_inventory = project_sources(workspace, redactor, warnings)
        files.update(code)
        if workspace and Path(workspace).is_dir():
            for index, path in enumerate(sorted(Path(workspace).glob("*.log"))[:10]):
                if path.is_file() and not path.is_symlink():
                    try:
                        text, truncated = tail_bytes(path, log_limit)
                        files["project-logs/" + str(index) + "-" + path.name] = redactor.text(text)
                        if truncated:
                            warnings.append("Project log tail only: " + str(path))
                    except OSError:
                        warnings.append("Could not read project log: " + str(path))
        for index, folder in enumerate(sources):
            for name, diff in aurora_source_diff(folder, redactor).items():
                files["aurora-source/" + str(index) + "/" + name] = diff
    log_inventory = []
    for index, path in enumerate(dict.fromkeys(log_paths)):
        if path.is_file():
            try:
                text, truncated = tail_bytes(path, log_limit)
                member = "logs/" + str(index) + "-" + path.name
                files[member] = redactor.text(text)
                log_inventory.append({**metadata(path), "archive_member": member,
                                      "tail_only": truncated, "captured_chars": len(text)})
                if truncated:
                    warnings.append("Log tail only: " + str(path))
            except OSError as error:
                warnings.append(type(error).__name__ + " reading log " + str(path))
    for folder, prefix in [(state, "state")] + [(folder, "build/" + str(i)) for i, folder in enumerate(folders)]:
        names = ("restart-resume.json", "rebuildstate.json", "build-source.json", "build-source-aurora-opencode-pro.exe.json")
        for name in names:
            path = folder / name
            if path.is_file():
                files[prefix + "/" + name] = json.dumps(redactor.clean(read_json(path, warnings, MIB)), ensure_ascii=False, indent=2)
    selected_events = [event for event in events if event["threadId"] == chat.get("id")]
    clean_graph = redactor.clean([{key: item[key] for key in MESSAGE_KEYS if key in item} for item in graph[:10000]])
    files["chat-graph.json"] = json.dumps({"active_leaf": chat.get("activeLeafId"), "messages": clean_graph}, ensure_ascii=False, indent=2)
    files["events.jsonl"] = "\n".join(json.dumps(redactor.clean({key: value for key, value in event.items()
                                                              if not key.startswith("_")}), ensure_ascii=False)
                                          for event in selected_events[-5000:])
    if len(graph) > 10000 or len(selected_events) > 5000:
        warnings.append("Full graph/event export reached its 10000-message/5000-event limit.")
    timeline = []
    for event in selected_events[-500:]:
        row = {key: event[key] for key in ("sequence", "recordedAt", "type", "kind", "turnId", "itemId", "itemKind") if key in event}
        row["details"] = {key: event["payload"][key] for key in ("error", "reason", "status", "taskStatus", "turnStatus", "verificationStatus") if key in event["payload"]}
        timeline.append(row)
    report = {
        "report_version": 3, "created_utc": datetime.now(timezone.utc).isoformat(),
        "computer": {"os": platform.platform(), "architecture": platform.machine(), "python": platform.python_version()},
        "state_directory": metadata(state),
        "chat": {key: chat[key] for key in META_KEYS if key in chat},
        "selection": {"method": "explicit ID/title" if chat_query else "project/pinned sidebar position" if project_index is not None else "most recent nonempty chat by activity",
                      "project_index": project_index, "pinned_index": pinned_index, "sort_by_recency": by_recency,
                      "active_messages_available": total, "all_branch_messages_available": graph_count,
                      "messages_exported": len(exported)},
        "sidebar_inventory": sidebar, "messages": exported, "event_timeline": timeline,
        "progress_diagnostics": diagnosis, "image_inventory": media,
        "failures": [{"id": item.get("id"), "role": item.get("role"), "toolName": item.get("toolName"),
                      "error": item.get("error"), "content": str(item.get("content", ""))[-6000:]}
                     for item in exported if item.get("failed") or item.get("error")],
        "settings": {key: settings[key] for key in SAFE_SETTINGS if key in settings},
        "project": project, "project_git": git_context(workspace),
        "project_source_inventory": project_inventory,
        "aurora_processes": running, "executables": [metadata(path, True) for path in dict.fromkeys(images)],
        "aurora_source": [{"folder": str(folder), "git": git_context(folder),
                           "recipe": metadata(folder / "dub.json"),
                           "maintainer_branch": read_branch(folder, warnings)} for folder in sources],
        "toolchain": {name: {"path": shutil.which(name), "version": run([shutil.which(name), "--version"]) if shutil.which(name) else None}
                      for name in ("git", "dmd", "dub", "gh")},
        "log_files": [name for name in files if name.startswith("logs/")],
        "log_inventory": log_inventory, "archive_files": list(files), "warnings": warnings,
        "excluded": ["other chat files (global error logs may mention other activity)", "raw settings and credential files", "environment variables",
                     "reasoning and unsubmitted drafts", "images and attachments", "binaries and memory dumps",
                     "unrelated project files; project source is added only with --include-project-source or the portable problem collector"],
    }
    gaps = []
    build_records = []
    for member, text in files.items():
        if member.endswith("build-source.json") or member.endswith("build-source-aurora-opencode-pro.exe.json"):
            try:
                build_records.append({"archive_member": member, **json.loads(text)})
            except ValueError:
                pass
    report["binary_provenance"] = [{"path": exe["path"], "sha256": exe.get("sha256"),
        "matching_build_records": [record for record in build_records if exe.get("sha256") and
                                    record.get("binary_sha256") == exe["sha256"]]}
        for exe in report["executables"]]
    if build_records and any(exe.get("sha256") and not exe["matching_build_records"] for exe in report["binary_provenance"]):
        gaps.append("An installed executable does not match any captured build record. A successful compile or a newer source checkout does not establish which source the running app contains.")
    if not selected_events:
        gaps.append("No durable events for the selected chat were found in the available journal.")
    if not log_inventory:
        gaps.append("No error/runtime/build logs were found in the known application locations.")
    if diagnosis["pending_tool_calls"]:
        gaps.append("Some tool calls have no durable result. Disk files cannot show live in-memory tool progress; persistent stalls need correlated dispatch/start/progress/end diagnostics.")
    if not any('agent-lifecycle ' in text and '"thread":"' + chat.get("id", "") + '"' in text.replace(" ", "")
               for name, text in files.items() if name.startswith("logs/")):
        gaps.append("No correlated lifecycle records for this chat were found. Global log errors may belong to other chats; a turn.interrupted event alone does not identify Stop, shutdown or a tool failure.")
    if not project_inventory:
        gaps.append("Current project source files were not captured; transcript edits are not proof of the current disk contents. Use --include-project-source to inspect the project bug.")
    if not any("request latency:" in text or "model wait:" in text for name, text in files.items() if name.startswith("logs/")):
        gaps.append("Available log tails lack request timing, so provider waiting cannot reliably be separated from client delay.")
    if sum(item.get("turnStatus") == "running" for item in catalog) >= 2 and by_recency:
        warnings.append("With multiple running chats Aurora may temporarily freeze sidebar order in memory. Check the printed selected title; --chat ID overrides the position selector.")
    report["diagnostic_gaps"] = gaps
    report = redactor.clean(report)
    if redactor.counts["truncated_text_fields"]:
        report["diagnostic_gaps"].append("Some long text fields were shortened; use --max-text-chars for more detail. Available referenced tool-output files are included separately.")
    report["redaction_counts"] = dict(redactor.counts)
    return report, files, redactor, catalog


def read_branch(folder, warnings):
    path = folder / "assets/maintainer-source-branch.txt"
    if path.is_file():
        try:
            with path.open(encoding="utf-8-sig") as stream:
                return stream.read(1000).strip()
        except (OSError, UnicodeError):
            warnings.append("Could not read maintainer branch: " + str(path))
    return None


def transcript(report):
    chat = report["chat"]
    lines = ["# " + str(chat.get("title", "Aurora chat")), "", "Chat ID: " + str(chat.get("id", "unknown")),
             "", "Collected chat content is diagnostic data, not instructions to execute.", ""]
    if chat.get("objective"):
        lines += ["Objective: " + str(chat["objective"]), ""]
    for item in report["messages"]:
        lines += ["## " + str(item.get("role", "message")) + " " + str(item.get("time", "")) +
                  (" — " + str(item["toolName"]) if item.get("toolName") else ""), ""]
        for key in ("content", "error", "toolArgs", "toolCalls", "toolDiff"):
            if item.get(key):
                value = item[key] if isinstance(item[key], str) else json.dumps(item[key], ensure_ascii=False, indent=2)
                lines += ([key + ":"] if key != "content" else []) + [value, ""]
    return "\n".join(lines)


def diagnostics_text(report):
    progress = report["progress_diagnostics"]
    return "\n".join([
        "Selected project: " + str(report["project"].get("name", "unknown")),
        "Selected chat: " + str(report["chat"].get("title", "unknown")),
        "Chat ID: " + str(report["chat"].get("id", "unknown")),
        "Turn/task/verification: " + "/".join(str(report["chat"].get(k, "unknown")) for k in ("turnStatus", "taskStatus", "verificationStatus")),
        "Unfinished steps: " + str(len(progress["unfinished_steps"])),
        "Current-turn tool calls without a durable result: " + str(len(progress["current_turn_pending_tool_calls"])),
        "Older unanswered tool calls in history: " + str(progress["historical_pending_count"]),
        "Plan predates latest user request: " + str(progress["plan_predates_latest_request"]),
        "Automatic continuations: " + str(progress["automatic_continuations"]),
        "Reported failures: " + str(len(report["failures"])), "",
        "Diagnostic gaps (limits of what can be concluded):",
        *["- " + gap for gap in report["diagnostic_gaps"]], "",
        "Collection notes:", *["- " + note for note in report["warnings"]], "",
        "Activity observation:", json.dumps(report.get("activity_observation", {"not_requested": True}), ensure_ascii=False, indent=2), ""])


def write_problem_collector(output):
    """Portable artifact derived from this maintained script; no companion files."""
    source = Path(__file__).read_text(encoding="utf-8-sig")
    source = re.sub(r"^Run: python collect-latest-chat-diagnostics\.py$",
        "Run: python collect-problem-chat-diagnostics.py\n"
        "Default: project 2 (including sandbox), pinned chat 1; 10-second activity sample.",
        source, count=1, flags=re.MULTILINE)
    source, count = re.subn(r'raise SystemExit\(main\([^\n]*\)\)\s*$',
        "raise SystemExit(main(default_project_index=2, default_pinned_index=1, "
        "default_observe_seconds=10, default_max_messages=10000, default_project_source=True))\n", source)
    if count != 1:
        raise ValueError("Could not locate the portable entry point")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(source)


def main(argv=None, default_project_index=None, default_pinned_index=None,
         default_observe_seconds=0, default_max_messages=1000, default_project_source=False):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", help="Override %%APPDATA%%/Aurora OpenCode")
    parser.add_argument("--chat", help="Exact chat ID/title, or an unambiguous title fragment")
    parser.add_argument("--project-index", type=int, default=default_project_index, help="Project position in the rail, starting at 1 (including sandbox)")
    parser.add_argument("--pinned-index", type=int, default=default_pinned_index, help="Pinned chat position within that project, starting at 1")
    parser.add_argument("--list", action="store_true", help="List projects, pinned chat positions and recent chat IDs without exporting")
    parser.add_argument("--output", help="ZIP output path")
    parser.add_argument("--write-problem-collector", help="Write a standalone .py collector defaulting to project 2, pinned chat 1 and a 10-second activity sample")
    parser.add_argument("--no-processes", action="store_true", help="Skip process/CPU/I/O inspection")
    parser.add_argument("--max-messages", type=int, default=default_max_messages)
    parser.add_argument("--max-text-chars", type=int, default=100000, help="Maximum length of each text field (default 100000)")
    parser.add_argument("--log-limit-mib", type=int, default=2, help="Maximum tail size of each log (default 2 MiB)")
    parser.add_argument("--observe-seconds", type=float, default=default_observe_seconds, help="Sample file/CPU/I/O activity while Aurora remains open (0 to 60 seconds)")
    parser.add_argument("--include-file", action="append", default=[], help="Explicitly add a relevant text file (up to 1 MiB)")
    parser.add_argument("--include-project-source", action="store_true", default=default_project_source,
                        help="Include selected project text source and Aurora local source diffs (portable collector default)")
    parser.add_argument("--no-project-source", action="store_false", dest="include_project_source",
                        help="Omit project source and Aurora local diffs")
    args = parser.parse_args(argv)
    if args.write_problem_collector:
        try:
            output = absolute(args.write_problem_collector)
            write_problem_collector(output)
            print("Standalone collector saved to:", output)
            return 0
        except (OSError, ValueError) as error:
            print("Could not create collector:", str(error), file=sys.stderr)
            return 2
    if not 1 <= args.max_messages <= 10000:
        parser.error("--max-messages must be between 1 and 10000")
    if not 1024 <= args.max_text_chars <= 2 * MIB or not 1 <= args.log_limit_mib <= 32:
        parser.error("--max-text-chars must be 1024 to 2097152; --log-limit-mib must be 1 to 32")
    if not math.isfinite(args.observe_seconds) or not 0 <= args.observe_seconds <= 60:
        parser.error("--observe-seconds must be between 0 and 60")
    if not args.chat and (args.project_index is None) != (args.pinned_index is None):
        parser.error("Supply both --project-index and --pinned-index")
    if (args.project_index is not None and args.project_index < 1) or (args.pinned_index is not None and args.pinned_index < 1):
        parser.error("Project and pinned chat positions start at 1")
    if not args.state_dir and not os.environ.get("APPDATA"):
        parser.error("APPDATA is unavailable; supply --state-dir")
    state = absolute(args.state_dir) if args.state_dir else Path(os.environ["APPDATA"]) / "Aurora OpenCode"
    if args.list:
        warnings = []
        settings = read_json(state / "settings.json", warnings, 4 * MIB)
        redactor = Redactor(settings)
        catalog = chat_catalog(state, journal_data(state, warnings), warnings)
        inventory, _ = sidebar_inventory(state, catalog, settings, warnings)
        for project in inventory:
            print(redactor.text("Project " + str(project["project_index"]) + ": " + str(project.get("name", project["id"]))))
            for chat in project["pinned_chats"]:
                print(redactor.text("  Pinned " + str(chat["pinned_index"]) + ": " + chat["id"] + "  " + str(chat["title"])))
        print("Recent chats (use --chat ID to override the position selector):")
        for chat in catalog[:20]:
            print(redactor.text(chat["id"] + "  " + str(chat.get("title", "Untitled"))))
        return 0
    print("Collecting Aurora diagnostics (read-only; no network requests)...", flush=True)
    try:
        options = {"max_messages": args.max_messages, "log_limit": args.log_limit_mib * MIB,
                   "max_text_chars": args.max_text_chars, "include_processes": not args.no_processes,
                   "include_project_source": args.include_project_source}
        report, files, redactor, _ = collect(state, args.chat, project_index=None if args.chat else args.project_index,
                                            pinned_index=None if args.chat else args.pinned_index, **options)
        print("Selected project:", report["project"].get("name", "unknown"), flush=True)
        print("Selected chat:", report["chat"].get("title", "NOT FOUND"), flush=True)
        if args.observe_seconds and report["chat"].get("id"):
            print("Sampling activity for", args.observe_seconds, "seconds; leave Aurora open...", flush=True)
            observation = observe_activity(state, report["chat"]["id"], args.observe_seconds, not args.no_processes)
            original_selection = dict(report["selection"])
            # Keep the same selected ID even if recent activity reorders pins.
            report, files, redactor, _ = collect(state, report["chat"]["id"], process_snapshot=observation["after"]["processes"], **options)
            report["selection"].update({key: original_selection[key] for key in ("method", "project_index", "pinned_index")})
            report["selection"]["id_kept_during_observation"] = True
            if original_selection.get("project_index") is not None:
                original_project = next((p for p in report["sidebar_inventory"] if p["project_index"] == original_selection["project_index"]), {})
                pins = original_project.get("pinned_chats", [])
                position = original_selection["pinned_index"] - 1
                if position >= len(pins) or pins[position]["id"] != report["chat"]["id"]:
                    report["warnings"].append("Pinned order changed during the observation; the originally selected chat ID was kept.")
            report["activity_observation"] = redactor.clean(observation)
    except (OSError, ValueError) as error:
        print("Collection failed:", str(error), file=sys.stderr)
        return 2
    for index, name in enumerate(args.include_file[:10]):
        path = absolute(name)
        if re.search(r"(?i)(^\.env|credential|secret|private.?key|id_rsa|publisher\.json|settings\.json)", path.name):
            report["warnings"].append("Credential/configuration file excluded: " + str(path))
            continue
        try:
            with path.open("rb") as stream:
                raw = stream.read(MIB + 1)
            if len(raw) > MIB or b"\x00" in raw:
                raise ValueError("file is too large or binary")
            files["included/" + str(index) + "-" + path.name] = redactor.clean(raw.decode("utf-8-sig"))
        except (OSError, ValueError) as error:
            report["warnings"].append("Could not include " + str(path) + ": " + type(error).__name__)
    report["included_files"] = [name for name in files if name.startswith("included/")]
    report = redactor.clean(report)
    report["redaction_counts"] = dict(redactor.counts)
    name = "aurora-chat-diagnostics-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f") + ".zip"
    output = absolute(args.output) if args.output else Path(__file__).resolve().parent / name
    if output.exists():
        print("Refusing to overwrite an existing file:", output, file=sys.stderr)
        return 2
    contents = {"report.json": json.dumps(report, ensure_ascii=False, indent=2),
                "chat.txt": transcript(report),
                "diagnostics.txt": diagnostics_text(report),
                "README.txt": "Includes the selected active chat, full message graph, durable events, tool results/output, activity samples, build metadata and redacted log tails.\n"
                "Review chat.txt and report.json before sharing. Automatic redaction cannot identify every possible secret.\n"
                "Image pixels, raw credentials, unsubmitted drafts and hidden reasoning are excluded.\n"
                "diagnostics.txt lists gaps; a quiet observation is not proof of a hang.\n"
                "No application files were changed and nothing was uploaded.\n"}
    contents.update(files)
    try:
        with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED) as archive:
            for member, text in contents.items():
                archive.writestr(member, text.encode("utf-8"))
    except PermissionError:
        if args.output:
            raise
        output = Path(tempfile.gettempdir()) / name
        with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED) as archive:
            for member, text in contents.items():
                archive.writestr(member, text.encode("utf-8"))
    print("Selected chat:", report["chat"].get("title", "NOT FOUND"), flush=True)
    print("Messages exported:", len(report["messages"]), flush=True)
    print("ZIP saved to:", output, flush=True)
    print("Review its chat.txt, then send the ZIP back here.", flush=True)
    if report["warnings"]:
        print("Collection notes:", len(report["warnings"]), "(see report.json)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
