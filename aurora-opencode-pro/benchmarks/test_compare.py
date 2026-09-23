"""Offline checks for benchmark accounting and failure reporting."""

import json
import tempfile
import unittest
from pathlib import Path

from compare import aurora_usage, dashboard, original_usage


class BenchmarkTests(unittest.TestCase):
    def test_original_counts_cached_input_once(self):
        events = "\n".join([
            json.dumps({"type": "step_finish", "part": {
                "type": "step-finish", "tokens": {"input": 100,
                "output": 20, "cache": {"read": 50, "write": 2}}}}),
            json.dumps({"type": "tool_use", "part": {
                "type": "tool", "tool": "bash",
                "state": {"status": "error", "error": "command failed"}}}),
        ])
        usage = original_usage(events)
        self.assertEqual(usage["tokens"], 172)
        self.assertEqual(usage["cached_read"], 50)
        self.assertEqual(usage["tool_calls"], 1)
        self.assertEqual(usage["tool_failures"], 1)

    def test_aurora_counts_each_assistant_round(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "sessions.json").write_text(json.dumps({"sessions": [{
                "messages": [
                    {"role": "assistant", "promptTokens": 100,
                     "completionTokens": 20, "totalTokens": 120,
                     "toolCalls": [{"name": "read"}]},
                    {"role": "tool", "toolName": "read", "failed": True,
                     "content": "missing file"},
                    {"role": "assistant", "promptTokens": 200,
                     "completionTokens": 30, "totalTokens": 230},
                ]}]}), encoding="utf-8")
            usage = aurora_usage(state)
        self.assertEqual(usage["tokens"], 350)
        self.assertEqual(usage["rounds"], 2)
        self.assertEqual(usage["tool_failures"], 1)

    def test_dashboard_shows_failures_and_recovered_tool_errors(self):
        base = {"task": "sample", "attempt": 1, "seconds": 2.0,
                "tokens": 100, "rounds": 1, "tool_calls": 1,
                "cached_read": None, "cached_write": None}
        records = [
            {**base, "harness": "aurora", "passed": True, "failure": "",
             "verifier": "ok", "tool_failures": 1,
             "tool_error_details": ["read: <missing>"]},
            {**base, "harness": "original", "passed": False,
             "failure": "independent verifier failed", "verifier": "wrong value",
             "tool_failures": 0, "tool_error_details": []},
        ]
        data = {"created_at": "2026-09-23", "model": "test",
                "opencode_version": "test", "tasks": ["sample"], "runs": records}
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "index.html"
            dashboard(data, target)
            page = target.read_text(encoding="utf-8")
        self.assertIn("independent verifier failed", page)
        self.assertIn("recovered tool error", page)
        self.assertIn("&lt;missing&gt;", page)
        self.assertNotIn("<missing>", page)


if __name__ == "__main__":
    unittest.main()
