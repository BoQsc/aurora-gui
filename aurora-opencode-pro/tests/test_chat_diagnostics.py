"""Contracts for selecting, recovering, and safely exporting a remote Aurora chat."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "tools/collect-latest-chat-diagnostics.py"
spec = importlib.util.spec_from_file_location("chat_diagnostics", SCRIPT)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def ticks(unix_seconds):
    return int((unix_seconds + 62135596800) * 10000000)


class ChatDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "Aurora OpenCode"
        self.state.mkdir()
        self.write("settings.json", {"apiKeys": ["custom-key-PRIVATE123"], "model": "test-model",
                                     "developerRequireLatestSource": True})
        self.enterContext(patch.object(collector, "processes", return_value=[]))
        self.enterContext(patch.object(collector.shutil, "which", return_value=None))

    def write(self, name, value):
        path = self.state / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        return path

    def index(self, sessions):
        self.write("threads.index.json", {"version": 2, "currentId": "old", "sessions": sessions})

    def messages(self, ident, messages):
        self.write("threads/" + ident + ".json", {"messages": messages})

    def journal(self, events, torn=False):
        path = self.state / "runtime-events.jsonl"
        path.write_text("\n".join(json.dumps(event) for event in events) +
                        ('\n{"sequence":999,' if torn else "\n"), encoding="utf-8")

    def event(self, sequence, thread, kind, payload, timestamp, item=None):
        event = {"schema": 1, "sequence": sequence, "threadId": thread, "type": kind,
                 "recordedAt": ticks(timestamp), "payload": payload}
        if item:
            event.update(itemId=item, itemKind="message")
        return event

    def collect(self, **kwargs):
        return collector.collect(self.state, include_processes=False, **kwargs)[0]

    def test_latest_nonempty_uses_activity_and_the_same_timestamp_clock(self):
        self.index([{"id": "old", "title": "Old", "updatedAt": 100},
                    {"id": "new", "title": "New", "updatedAt": 200},
                    {"id": "empty", "title": "Empty", "updatedAt": 300}])
        self.messages("old", [{"id": "a", "role": "user", "content": "Unrelated chat"}])
        self.messages("new", [{"id": "b", "role": "user", "content": "Current problem"}])
        self.journal([self.event(1, "old", "turn.completed", {}, 150)])
        report = self.collect()
        self.assertEqual(report["chat"]["id"], "new")
        self.assertEqual(report["messages"][0]["content"], "Current problem")
        self.assertNotIn("Unrelated chat", json.dumps(report))

    def test_split_snapshot_branch_and_unflushed_journal_recovery(self):
        self.index([{"id": "latest", "title": "Recovery", "activeLeaf": "alternate", "updatedAt": 100}])
        self.messages("latest", [
            {"id": "u", "role": "user", "content": "Problem"},
            {"id": "alternate", "parentId": "u", "role": "assistant", "content": "Abandoned branch"},
            {"id": "a", "parentId": "u", "role": "assistant", "content": "Partial"},
        ])
        self.journal([
            self.event(1, "latest", "thread.updated", {"title": "Recovered latest", "projectId": "p"}, 110),
            self.event(2, "latest", "item.added", {"role": "tool", "parentId": "a", "toolName": "run",
                                                      "content": "Partial result"}, 111, "tool"),
            self.event(3, "latest", "item.updated", json.dumps({"role": "tool", "content": "Final error",
                                                                   "failed": True, "error": "Access denied"}), 112, "tool"),
            self.event(4, "latest", "turn.failed", {"error": "Access denied"}, 113),
        ], torn=True)
        report = self.collect()
        self.assertEqual(report["chat"]["title"], "Recovered latest")
        self.assertEqual(report["chat"]["turnStatus"], "failed")
        self.assertEqual([m["id"] for m in report["messages"]], ["u", "a", "tool"])
        self.assertEqual(report["messages"][-1]["content"], "Final error")
        self.assertEqual(report["selection"]["all_branch_messages_available"], 4)
        self.assertEqual(report["failures"][0]["error"], "Access denied")
        self.assertTrue(any("invalid journal" in w for w in report["warnings"]))
        self.assertEqual(len(report["event_timeline"]), 4)

    def test_folded_journal_cannot_replace_newer_saved_branch_or_text(self):
        self.index([{"id": "t", "title": "Saved title", "updatedAt": 400, "activeLeaf": "right"}])
        self.messages("t", [{"id": "u", "role": "user", "content": "Original"},
                            {"id": "left", "parentId": "u", "role": "assistant", "content": "Old branch"},
                            {"id": "right", "parentId": "u", "role": "assistant", "content": "Saved final text"}])
        self.journal([
            self.event(1, "t", "thread.started", {"title": "Stale title"}, 100),
            self.event(2, "t", "item.updated", {"role": "assistant", "content": "Stale partial text"}, 110, "right"),
            self.event(3, "t", "item.added", {"role": "assistant", "parentId": "u", "content": "Old branch"}, 120, "left"),
        ])
        (self.state / "journal.folded").write_text("3 900\n")
        report = self.collect()
        self.assertEqual(report["chat"]["title"], "Saved title")
        self.assertEqual([m["id"] for m in report["messages"]], ["u", "right"])
        self.assertEqual(report["messages"][-1]["content"], "Saved final text")

    def test_legacy_backup_and_missing_graph_parent_remain_diagnosable(self):
        self.write("sessions.json.bak", {"sessions": [{"id": "legacy", "title": "Legacy", "updatedAt": 20,
                                                       "activeLeaf": "m", "messages": [{"id": "m", "parentId": "missing",
                                                       "role": "user", "content": "Still readable"}]}]})
        (self.state / "sessions.json").write_text("{torn")
        report = self.collect()
        self.assertEqual(report["messages"][0]["content"], "Still readable")
        self.assertTrue(any("backup snapshot" in w for w in report["warnings"]))
        self.assertTrue(any("missing parent" in w for w in report["warnings"]))

    def test_zip_is_read_only_and_redacts_chat_tool_arguments_and_logs(self):
        secrets = ["custom-key-PRIVATE123", "sk-abcdefgh1234567890", "ghp_abcdef1234567890",
                   "Bearer1234567890", "userpassword123", "QueryKey123", "JsonPassword123",
                   "XmlPassword123", "PlainToken123", "WebhookToken123"]
        text = (secrets[0] + " " + secrets[1] + " " + secrets[2] + " Authorization: Bearer " + secrets[3] +
                " https://user:" + secrets[4] + "@example.test/path?api_key=" + secrets[5] + "&q=ok\n" +
                '<property name="ServerPassword" value="' + secrets[7] + '"/>\n' +
                "BOT_TOKEN=" + secrets[8] + "\nhttps://discord.com/api/webhooks/12345/" + secrets[9])
        self.index([{"id": "latest", "title": "Проблема", "updatedAt": 300, "draft": "PRIVATE_DRAFT"}])
        self.messages("latest", [{"id": "u", "role": "user", "content": text, "reasoning": "PRIVATE_REASONING",
                                  "images": [{"base64Data": "PRIVATE_IMAGE"}],
                                  "toolArgs": json.dumps({"password": secrets[6], "file": "serverconfig.xml"})}])
        self.write("forge-publisher.json", {"key": "NEVER_INCLUDE_PUBLISHER"})
        logs = self.state / "logs"
        logs.mkdir()
        (logs / "errors.log").write_text(text, encoding="utf-8")
        before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.state.rglob("*") if p.is_file()}
        output = self.root / "report.zip"
        with redirect_stdout(io.StringIO()):
            result = collector.main(["--state-dir", str(self.state), "--output", str(output)])
        self.assertEqual(result, 0)
        with zipfile.ZipFile(output) as archive:
            all_text = "\n".join(archive.read(name).decode("utf-8") for name in archive.namelist())
            self.assertIn("chat.txt", archive.namelist())
            self.assertTrue(any(name.startswith("logs/") for name in archive.namelist()))
            self.assertIn("Проблема", all_text)
            self.assertIn("serverconfig.xml", all_text)
        for secret in secrets + ["PRIVATE_DRAFT", "PRIVATE_REASONING", "PRIVATE_IMAGE", "NEVER_INCLUDE_PUBLISHER"]:
            self.assertNotIn(secret, all_text, secret)
        after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.state.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(collector.main(["--state-dir", str(self.state), "--output", str(output)]), 2)

    def test_explicit_selection_and_limited_export_keep_initial_problem(self):
        self.index([{"id": "one", "title": "Server issue", "updatedAt": 10},
                    {"id": "two", "title": "Server issue again", "updatedAt": 20}])
        self.messages("one", [{"id": str(i), "role": "user" if i == 0 else "assistant", "content": str(i)}
                              for i in range(10)])
        self.messages("two", [{"id": "x", "role": "user", "content": "Wrong problem"}])
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.collect(chat_query="Server")
        report = self.collect(chat_query="one", max_messages=2)
        self.assertEqual([m["id"] for m in report["messages"]], ["0", "8", "9"])
        self.assertEqual(report["selection"]["active_messages_available"], 10)
        self.assertEqual(report["selection"]["messages_exported"], 3)

    def test_optional_text_file_is_redacted_and_secret_files_excluded(self):
        self.index([{"id": "t", "title": "Example", "updatedAt": 10}])
        self.messages("t", [{"id": "u", "role": "user", "content": "Test"}])
        file = self.root / "example.log"
        file.write_text("error: api_key=custom-key-PRIVATE123\nRetained diagnostic", encoding="utf-8")
        secret = self.root / ".env"
        secret.write_text("NEVER_EXPORT_ENV")
        output = self.root / "with-file.zip"
        with redirect_stdout(io.StringIO()):
            self.assertEqual(collector.main(["--state-dir", str(self.state), "--output", str(output),
                                             "--include-file", str(file), "--include-file", str(secret)]), 0)
        with zipfile.ZipFile(output) as archive:
            text = "\n".join(archive.read(name).decode() for name in archive.namelist())
        self.assertIn("Retained diagnostic", text)
        self.assertNotIn("custom-key-PRIVATE123", text)
        self.assertNotIn("NEVER_EXPORT_ENV", text)

    def test_partial_or_empty_state_returns_diagnostics_without_crashing(self):
        self.index([{"id": "malformed", "updatedAt": "invalid timestamp"}])
        self.write("threads/malformed.json", {"messages": None})
        self.write("projects.json", {"projects": None})
        report = self.collect()
        self.assertEqual(report["messages"], [])
        self.assertTrue(any("No nonempty chat" in w for w in report["warnings"]))

    def pinned_fixture(self):
        self.write("projects.json", {"projects": [{"id": "sandbox", "name": "sandbox 1"},
                    {"id": "project-two", "name": "Second project", "path": str(self.root)}]})
        self.index([{"id": "recent-pin", "title": "Target chat", "project": "project-two", "updatedAt": 300},
                    {"id": "new-pin", "title": "Newer-created chat", "project": "project-two", "updatedAt": 200},
                    {"id": "archived-pin", "title": "Hidden chat", "project": "project-two", "updatedAt": 900},
                    {"id": "other", "title": "Other project", "project": "sandbox", "updatedAt": 1000}])
        self.write("pins.json", ["new-pin", "other", "archived-pin", "recent-pin"])
        self.write("archived.json", ["archived-pin"])
        for ident in ("recent-pin", "new-pin", "archived-pin", "other"):
            self.messages(ident, [{"id": ident + "-u", "role": "user", "content": "Problem " + ident}])

    def test_project_and_pin_match_sidebar_recency_not_pin_file_order(self):
        self.pinned_fixture()
        report = self.collect(project_index=2, pinned_index=1)
        self.assertEqual(report["chat"]["id"], "recent-pin")
        self.assertEqual(report["project"]["name"], "Second project")
        self.assertEqual([c["id"] for c in report["sidebar_inventory"][1]["pinned_chats"]], ["recent-pin", "new-pin"])
        self.assertEqual(report["selection"]["method"], "project/pinned sidebar position")

    def test_creation_order_and_missing_sandbox_follow_project_rail(self):
        self.pinned_fixture()
        self.write("settings.json", {"sortSessionsByRecency": False})
        self.write("projects.json", {"projects": [{"id": "project-two", "name": "Second project"}]})
        report = self.collect(project_index=2, pinned_index=1)
        self.assertEqual(report["chat"]["id"], "new-pin")
        self.assertEqual(report["sidebar_inventory"][0]["id"], "sandbox")
        self.assertFalse(report["selection"]["sort_by_recency"])

    def test_missing_pin_does_not_silently_export_a_different_chat(self):
        self.pinned_fixture()
        with self.assertRaisesRegex(ValueError, "no other chat was substituted"):
            self.collect(project_index=2, pinned_index=3)
        with self.assertRaisesRegex(ValueError, "Project 3"):
            self.collect(project_index=3, pinned_index=1)

    def test_full_graph_pending_calls_and_complete_cached_output(self):
        self.index([{"id": "t", "title": "Stalled", "activeLeaf": "a", "turnStatus": "completed",
                     "taskSteps": [{"step": "Finish", "status": "pending"}]}])
        cached = self.state / "tool-output/123456789-1.txt"
        cached.parent.mkdir()
        cached.write_text("Prefix\n" + "x" * 120000 + "\nMiddle error: custom-key-PRIVATE123\nEnd", encoding="utf-8")
        self.messages("t", [{"id": "u", "role": "user", "content": "Original problem"},
            {"id": "old", "parentId": "u", "role": "assistant", "content": "Earlier branch"},
            {"id": "a", "parentId": "u", "role": "assistant", "content": "Full output saved to: " + str(cached),
             "toolCalls": [{"id": "pending-search", "name": "grep", "arguments": '{"path":"source","pattern":"needle"}'}]}])
        report, files, _, _ = collector.collect(self.state, include_processes=False)
        self.assertEqual(report["progress_diagnostics"]["pending_tool_calls"][0]["id"], "pending-search")
        self.assertTrue(report["progress_diagnostics"]["ended_with_unfinished_work"])
        self.assertEqual(len(json.loads(files["chat-graph.json"])["messages"]), 3)
        cached_text = next(text for name, text in files.items() if name.startswith("tool-output/"))
        self.assertIn("Middle error: [REDACTED]", cached_text)
        self.assertGreater(len(cached_text), 100000)
        self.assertTrue(any("in-memory" in gap for gap in report["diagnostic_gaps"]))

    def test_rotated_logs_and_build_records_are_redacted(self):
        self.index([{"id": "t", "title": "Example"}])
        self.messages("t", [{"id": "u", "role": "user", "content": "Problem"}])
        self.write("forge-publisher.json", {"key": "fsk_PRIVATEPUBLISHER0123456789"})
        log = self.state / "logs/errors.previous.log"
        log.parent.mkdir()
        log.write_text("Old fault fsk_PRIVATEPUBLISHER0123456789\n" + "x" * 150000, encoding="utf-8")
        self.write("rebuildstate.json", {"status": "failed", "errors": ["known fault"]})
        report, files, _, _ = collector.collect(self.state, include_processes=False)
        text = "\n".join(files.values())
        self.assertIn("Old fault [REDACTED]", text)
        self.assertNotIn("fsk_PRIVATEPUBLISHER0123456789", text)
        self.assertIn("state/rebuildstate.json", files)
        self.assertTrue(any(i["path"].endswith("errors.previous.log") for i in report["log_inventory"]))

    def test_observation_reports_deltas_without_claiming_a_hang(self):
        samples = [[{"pid": 123, "name": "aurora", "started_utc": "same", "cpu_100ns": 100,
                     "read_bytes": 10, "write_bytes": 20}],
                   [{"pid": 123, "name": "aurora", "started_utc": "same", "cpu_100ns": 10000100,
                     "read_bytes": 510, "write_bytes": 60}]]
        with patch.object(collector, "processes", side_effect=samples), patch.object(collector.time, "sleep"):
            observation = collector.observe_activity(self.state, "t", 10)
        self.assertEqual(observation["process_deltas"][0]["cpu_seconds"], 1)
        self.assertEqual(observation["process_deltas"][0]["read_bytes"], 500)
        self.assertIn("cannot prove a hang", observation["note"])

    def test_trace_log_media_payloads_are_omitted(self):
        redactor = collector.Redactor({})
        text = 'wire: {"base64Data":"PRIVATE_PIXELS","url":"data:image\\/png;base64,PRIVATE_MEDIA"}'
        cleaned = redactor.text(text)
        self.assertNotIn("PRIVATE_PIXELS", cleaned)
        self.assertNotIn("PRIVATE_MEDIA", cleaned)

    def test_reused_tool_id_cannot_hide_a_new_pending_call(self):
        call = {"id": "reused", "name": "grep", "arguments": "{}"}
        messages = [{"id": "a1", "role": "assistant", "toolCalls": [call]},
                    {"role": "tool", "toolCallId": "reused", "content": "Earlier result"},
                    {"id": "a2", "role": "assistant", "toolCalls": [call]}]
        diagnosis = collector.analyze_messages(messages, {})
        self.assertEqual(diagnosis["pending_tool_calls"][0]["assistant_message"], "a2")

    def test_portable_file_defaults_to_second_project_first_pin(self):
        self.pinned_fixture()
        portable = self.root / "collect-problem-chat-diagnostics.py"
        collector.write_problem_collector(portable)
        before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.state.rglob("*") if p.is_file()}
        output = self.root / "portable.zip"
        result = subprocess.run([sys.executable, "-B", str(portable), "--state-dir", str(self.state),
                                 "--output", str(output), "--observe-seconds", "0", "--no-processes"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(output) as archive:
            report = json.loads(archive.read("report.json"))
            self.assertEqual(report["chat"]["id"], "recent-pin")
            self.assertIn("diagnostics.txt", archive.namelist())
            self.assertIn("chat-graph.json", archive.namelist())
            self.assertIn("events.jsonl", archive.namelist())
        after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.state.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        with self.assertRaises(FileExistsError):
            collector.write_problem_collector(portable)

    def test_manual_id_overrides_portable_position_defaults(self):
        self.pinned_fixture()
        output = self.root / "override.zip"
        with redirect_stdout(io.StringIO()):
            result = collector.main(["--state-dir", str(self.state), "--output", str(output), "--chat", "other"],
                                    default_project_index=2, default_pinned_index=1)
        self.assertEqual(result, 0)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(json.loads(archive.read("report.json"))["chat"]["id"], "other")

    def test_sampling_keeps_selected_id_when_pinned_order_changes(self):
        self.pinned_fixture()
        def reorder(_):
            index = json.loads((self.state / "threads.index.json").read_text())
            next(s for s in index["sessions"] if s["id"] == "new-pin")["updatedAt"] = 500
            self.write("threads.index.json", index)
        output = self.root / "observed.zip"
        with patch.object(collector.time, "sleep", side_effect=reorder), redirect_stdout(io.StringIO()):
            result = collector.main(["--state-dir", str(self.state), "--output", str(output),
                                     "--observe-seconds", "10", "--no-processes"],
                                    default_project_index=2, default_pinned_index=1)
        self.assertEqual(result, 0)
        with zipfile.ZipFile(output) as archive:
            report = json.loads(archive.read("report.json"))
        self.assertEqual(report["chat"]["id"], "recent-pin")
        self.assertEqual(report["sidebar_inventory"][1]["pinned_chats"][0]["id"], "new-pin")
        self.assertTrue(report["selection"]["id_kept_during_observation"])
        self.assertTrue(any("Pinned order changed" in w for w in report["warnings"]))

    def test_recent_cached_outputs_take_priority_over_old_references(self):
        folder = self.state / "tool-output"
        folder.mkdir()
        messages = []
        for index in range(40):
            path = folder / (str(10000 + index) + "-1.txt")
            path.write_text(str(index), encoding="utf-8")
            messages.append({"content": str(path)})
        files = collector.cached_outputs(self.state, messages, collector.Redactor({}), [])
        self.assertEqual(len(files), 30)
        self.assertEqual(next(iter(files.values())), "39")
        self.assertNotIn("0", files.values())

    def test_project_source_snapshot_is_bounded_redacted_and_read_only(self):
        project = self.root / "project"
        (project / "source").mkdir(parents=True)
        (project / "build").mkdir()
        (project / "source/app.d").write_text('apiKey="custom-key-PRIVATE123"; void main() {}', encoding="utf-8")
        (project / "README.md").write_text("Current project", encoding="utf-8")
        (project / "build/old.d").write_text("Old generated source", encoding="utf-8")
        (project / "settings.json").write_text('{"apiKey":"HIDDEN"}', encoding="utf-8")
        before = {str(p): p.read_bytes() for p in project.rglob("*") if p.is_file()}
        files, inventory = collector.project_sources(project, collector.Redactor({"apiKey": "custom-key-PRIVATE123"}), [])
        self.assertEqual(set(files), {"project-source/source/app.d", "project-source/README.md"})
        self.assertNotIn("PRIVATE123", json.dumps(files))
        self.assertEqual(len(inventory), 2)
        self.assertEqual(before, {str(p): p.read_bytes() for p in project.rglob("*") if p.is_file()})

    def test_project_snapshot_does_not_follow_links_outside_project(self):
        project = self.root / "project"
        project.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "private.py").write_text("DO NOT EXPORT", encoding="utf-8")
        try:
            (project / "link").symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation unavailable")
        self.assertFalse(collector.project_sources(project, collector.Redactor({}), [])[0])

    def test_non_repository_does_not_run_diff_or_dump_git_usage(self):
        with patch.object(collector.shutil, "which", return_value="git"), \
                patch.object(collector, "run", return_value={"exit_code": 128, "output": "fatal: not a git repository"}) as run:
            result = collector.git_context(self.root)
        self.assertFalse(result["available"])
        self.assertEqual(run.call_count, 1)

    def test_scoped_context_settings_and_correlated_lifecycle_are_exported(self):
        self.index([{"id": "t", "title": "Example"}])
        self.messages("t", [{"id": "u", "role": "user", "content": "Problem"}])
        self.write("settings.json", {"contextBudgets": [{"endpoint": "http://localhost/v1", "model": "test", "tokens": 90000}],
                                     "contextCompactions": [{"endpoint": "http://localhost/v1", "model": "test"}]})
        logs = self.state / "logs"
        logs.mkdir()
        (logs / "errors.log").write_text('INFO agent-lifecycle {"thread":"t","request":4,"stage":"tool.started"}', encoding="utf-8")
        report = self.collect()
        self.assertEqual(report["settings"]["contextBudgets"][0]["tokens"], 90000)
        self.assertFalse(any("No correlated" in gap for gap in report["diagnostic_gaps"]))

    def test_old_unanswered_calls_and_old_plan_are_distinguished_from_current_work(self):
        messages = [{"id": "old-u", "role": "user", "content": "Old task"},
                    {"id": "old-a", "role": "assistant", "toolCalls": [{"id": "old", "name": "edit", "arguments": "{}"}]},
                    {"id": "plan", "role": "tool", "toolName": "update_plan"},
                    {"id": "new-u", "role": "user", "content": "It still fails"},
                    {"id": "new-a", "role": "assistant", "toolCalls": [{"id": "new", "name": "read", "arguments": "{}"}]}]
        result = collector.analyze_messages(messages, {"taskSteps": [{"status": "completed"}]})
        self.assertEqual(result["historical_pending_count"], 1)
        self.assertEqual([c["id"] for c in result["current_turn_pending_tool_calls"]], ["new"])
        self.assertTrue(result["plan_predates_latest_request"])


if __name__ == "__main__":
    unittest.main()
