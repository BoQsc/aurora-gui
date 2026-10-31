"""Source contracts for a persistent goal surviving a sent message.

A send that interrupts the running turn (a promoted queued prompt, or an
edited prompt that is resent) must leave the goal active: the interruption
only frees the turn for the new prompt. An explicit Stop still pauses it.
"""
import unittest
from pathlib import Path

package = Path(__file__).resolve().parents[1]
appui = (package / "source" / "auroraopencode" / "appui.d").read_text(
    encoding="utf-8", errors="replace")
smoke = (package / "tests" / "goal_ui_smoke.d").read_text(
    encoding="utf-8", errors="replace")


def declaration(name):
    """Text of one private member function declaration."""
    start = appui.index(name)
    depth = 0
    opened = False
    for offset in range(start, len(appui)):
        if appui[offset] == "{":
            depth += 1
            opened = True
        elif appui[offset] == "}":
            depth -= 1
            if opened and depth == 0:
                return appui[start:offset + 1]
    raise AssertionError("unterminated declaration: " + name)


class GoalSendContracts(unittest.TestCase):
    def test_stop_active_turn_switches_the_goal_pause(self):
        self.assertIn(
            "private void stopActiveTurn(bool pauseGoal = true)",
            declaration("private void stopActiveTurn("),
            "stopActiveTurn cannot distinguish a Stop from a send")
        self.assertIn(
            "if (pauseGoal) pauseActiveGoal(*session);",
            declaration("private void stopActiveTurn("),
            "the goal pause is not gated by the caller's intent")

    def test_promoted_queued_message_keeps_the_goal(self):
        body = declaration("private void sendPendingPromptNow(")
        self.assertIn("stopActiveTurn(false)", body,
                      "Send now pauses the persistent goal")
        self.assertNotIn("stopActiveTurn();", body,
                         "Send now still uses the explicit-Stop path")

    def test_edited_prompt_sends_keep_the_goal(self):
        for name in ("private void editAndResend(",
                     "private void beginInlineMessageEdit("):
            self.assertIn("stopActiveTurn(false)", declaration(name),
                          name + " pauses the persistent goal")

    def test_explicit_stop_still_pauses_the_goal(self):
        button = appui.index("_sendButton.onClick = delegate()")
        body = appui[button:appui.index("};", button)]
        self.assertIn("if (turnIsBusy()) stopActiveTurn();", body,
                      "the Stop button no longer stops explicitly")
        pause_goal = declaration("private void pauseGoal(")
        self.assertIn("stopActiveTurn();", pause_goal,
                      "the goal bar Stop no longer stops the running turn")

    def test_goal_ui_smoke_asserts_the_contract(self):
        self.assertIn(
            "sending a queued message keeps the persistent goal active", smoke,
            "the goal UI smoke lost the send-keeps-goal regression assertion")


if __name__ == "__main__":
    unittest.main(verbosity=2)
