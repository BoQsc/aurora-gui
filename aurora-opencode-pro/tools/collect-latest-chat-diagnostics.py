"""Collect the latest nonempty Aurora chat for diagnosis; Python standard library only.

Run: python collect-latest-chat-diagnostics.py
Optional: --list, --chat "chat title or id", --state-dir PATH, --include-file PATH
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
                 "developerRequireLatestSource", "contextBudgetTokens", "maxToolRounds")
SKIP_FIELDS = {"images", "attachments", "reasoning", "reasoningContent", "draft"}


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
            (r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,})\b", "[TOKEN REDACTED]"),
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
            (r"data:(?:image|audio|video)/[^\s\"']+", "[MEDIA DATA OMITTED]"),
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
            return [self.clean(child, depth + 1) for child in value[:2000]]
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
    catalog = {item["id"]: dict(item) for item in sessions
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
        item = catalog.setdefault(ident, {"id": ident})
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


def chat_messages(state, chat, events, warnings):
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
        by_id[ident].update({key: payload[key] for key in MESSAGE_KEYS if key in payload})
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


def processes():
    powershell = shutil.which("powershell.exe")
    if os.name != "nt" or not powershell:
        return []
    command = "$ErrorActionPreference='SilentlyContinue'; @(Get-Process | Where-Object {$_.ProcessName -like '*aurora*'} | ForEach-Object { [PSCustomObject]@{name=$_.ProcessName;pid=$_.Id;exe=$_.Path;responding=$_.Responding} }) | ConvertTo-Json -Compress"
    result = run([powershell, "-NoProfile", "-NonInteractive", "-Command", command])
    try:
        value = json.loads(result.get("output", "[]") or "[]")
        return value if isinstance(value, list) else [value]
    except ValueError:
        return []


def git_context(folder):
    git = shutil.which("git")
    if not git or not folder or not Path(folder).is_dir():
        return {"available": False}
    prefix = [git, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false", "-C", str(folder)]
    return {name: run(prefix + args) for name, args in {
        "head": ["rev-parse", "HEAD"], "branch": ["branch", "--show-current"],
        "status": ["status", "--short"], "changes_summary": ["diff", "--no-ext-diff", "--no-textconv", "--stat"],
        "staged_summary": ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--stat"],
    }.items()}


def collect(state, chat_query=None, max_messages=1000, include_processes=True):
    warnings = []
    settings = read_json(state / "settings.json", warnings, 4 * MIB)
    redactor = Redactor(settings)
    events = journal_data(state, warnings)
    catalog = chat_catalog(state, events, warnings)
    if chat_query:
        exact = [item for item in catalog if chat_query.casefold() in
                 (item["id"].casefold(), str(item.get("title", "")).casefold())]
        choices = exact or [item for item in catalog if chat_query.casefold() in str(item.get("title", "")).casefold()]
        if len(choices) != 1:
            raise ValueError("Chat selection is missing or ambiguous. Run --list, then use --chat with its exact ID.")
    else:
        choices = catalog
    chat, messages, graph_count = {}, [], 0
    for candidate in choices:
        candidate_messages, count = chat_messages(state, candidate, events, warnings)
        if candidate_messages or chat_query:
            chat, messages, graph_count = candidate, candidate_messages, count
            break
    if not chat:
        warnings.append("No nonempty chat was found. Check --state-dir and save/close Aurora before retrying.")
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
    running = processes() if include_processes else []
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
    log_paths = [state / "logs" / name for name in ("errors.log", "native-crash.log", "emergency.log")]
    log_paths += [state / "rebuild.log", state / "unexpected-exits.log"]
    log_paths += [folder / name for folder in sources for name in ("build.log", "rebuild-report.txt")]
    files = {}
    for index, path in enumerate(dict.fromkeys(log_paths)):
        if path.is_file():
            try:
                text, truncated = tail_bytes(path, 128 * 1024)
                files["logs/" + str(index) + "-" + path.name] = redactor.clean(text)
                if truncated:
                    warnings.append("Log tail only: " + str(path))
            except OSError as error:
                warnings.append(type(error).__name__ + " reading log " + str(path))
    selected_events = [event for event in events if event["threadId"] == chat.get("id")]
    timeline = []
    for event in selected_events[-500:]:
        row = {key: event[key] for key in ("sequence", "recordedAt", "type", "kind", "turnId", "itemId", "itemKind") if key in event}
        row["details"] = {key: event["payload"][key] for key in ("error", "reason", "status") if key in event["payload"]}
        timeline.append(row)
    report = {
        "report_version": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
        "computer": {"os": platform.platform(), "architecture": platform.machine(), "python": platform.python_version()},
        "state_directory": metadata(state),
        "chat": {key: chat[key] for key in META_KEYS if key in chat},
        "selection": {"method": "explicit ID/title" if chat_query else "most recent nonempty chat by activity",
                      "active_messages_available": total, "all_branch_messages_available": graph_count,
                      "messages_exported": len(exported)},
        "messages": exported, "event_timeline": timeline,
        "failures": [{"id": item.get("id"), "role": item.get("role"), "toolName": item.get("toolName"),
                      "error": item.get("error"), "content": str(item.get("content", ""))[-6000:]}
                     for item in exported if item.get("failed") or item.get("error")],
        "settings": {key: settings[key] for key in SAFE_SETTINGS if key in settings},
        "project": project, "project_git": git_context(workspace),
        "aurora_processes": running, "executables": [metadata(path, True) for path in dict.fromkeys(images)],
        "aurora_source": [{"folder": str(folder), "git": git_context(folder),
                           "recipe": metadata(folder / "dub.json"),
                           "maintainer_branch": read_branch(folder, warnings)} for folder in sources],
        "toolchain": {name: {"path": shutil.which(name), "version": run([shutil.which(name), "--version"]) if shutil.which(name) else None}
                      for name in ("git", "dmd", "dub", "gh")},
        "log_files": list(files), "warnings": warnings,
        "excluded": ["other chat files (global error logs may mention other activity)", "raw settings and credential files", "environment variables",
                     "reasoning and unsubmitted drafts", "images and attachments", "binaries and memory dumps",
                     "project file contents unless explicitly added with --include-file"],
    }
    report = redactor.clean(report)
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", help="Override %%APPDATA%%/Aurora OpenCode")
    parser.add_argument("--chat", help="Exact chat ID/title, or an unambiguous title fragment")
    parser.add_argument("--list", action="store_true", help="List recent chats without exporting")
    parser.add_argument("--output", help="ZIP output path")
    parser.add_argument("--max-messages", type=int, default=1000)
    parser.add_argument("--include-file", action="append", default=[], help="Explicitly add a relevant text file (up to 1 MiB)")
    args = parser.parse_args(argv)
    if not 1 <= args.max_messages <= 10000:
        parser.error("--max-messages must be between 1 and 10000")
    if not args.state_dir and not os.environ.get("APPDATA"):
        parser.error("APPDATA is unavailable; supply --state-dir")
    state = absolute(args.state_dir) if args.state_dir else Path(os.environ["APPDATA"]) / "Aurora OpenCode"
    if args.list:
        warnings = []
        for chat in chat_catalog(state, journal_data(state, warnings), warnings)[:20]:
            print(chat["id"] + "  " + str(chat.get("title", "Untitled")))
        return 0
    print("Collecting the latest Aurora chat (read-only; no network requests)...", flush=True)
    try:
        report, files, redactor, _ = collect(state, args.chat, args.max_messages)
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
                "README.txt": "Includes the selected chat, tool results, diagnostic metadata and redacted log tails.\n"
                "Review chat.txt and report.json before sharing. Automatic redaction cannot identify every possible secret.\n"
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
