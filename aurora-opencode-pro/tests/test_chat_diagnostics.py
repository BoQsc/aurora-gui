"""Contracts for selecting, recovering, and safely exporting a remote Aurora chat."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
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


if __name__ == "__main__":
    unittest.main()
