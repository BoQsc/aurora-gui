"""The live observer must not mistake a lagging disk snapshot for lost recovery."""
import unittest

from live_goal_resilience import recovery_is_current, recovery_markers


class RecoveryObservationTests(unittest.TestCase):
    def test_newer_runtime_directive_supersedes_saved_snapshot(self):
        old = "Agent output recovery: attempt=1 cause=unchanged_tool_results"
        new = "Agent output recovery: attempt=2 cause=unchanged_tool_results"
        self.assertTrue(recovery_is_current(old, [new]))
        self.assertFalse(recovery_is_current(new, [old]))
        self.assertFalse(recovery_is_current(old, [new.replace("unchanged_tool_results", "empty_output")]))
        self.assertFalse(recovery_is_current(old, []))

    def test_quoted_tool_content_is_not_a_live_directive(self):
        marker = "Execution recovery: attempt=1 cause=unfinished_outcome"
        request = {"messages": [{"role": "tool", "content": marker},
                                {"role": "system", "content": "Guidance\n" + marker + "\nNext action"}]}
        self.assertEqual(recovery_markers(request), [marker])


if __name__ == "__main__":
    unittest.main()
