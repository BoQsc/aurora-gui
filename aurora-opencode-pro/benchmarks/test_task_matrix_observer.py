import unittest
import json

from task_matrix_runner import completion_loop
from task_matrix_project import expected, INPUT
from task_matrix_cases import check_research, diagnosis_audit, check_numerical_review


class MatrixObserverTests(unittest.TestCase):
    def test_numerical_values_preserve_exact_requested_decimal_text(self):
        check_numerical_review(None, '{"current":"44.10","required":"49.10","at_60_with_coupon":"54.00"}')
        check_numerical_review(None, '{"current":44.10,"required":49.10,"at_60_with_coupon":54.00}')
        for answer in ('{"current":44.1,"required":49.10,"at_60_with_coupon":54.00}',
                       '{"current":44.10,"required":48.60,"at_60_with_coupon":54.00}',
                       '{"current":4.410e1,"required":49.10,"at_60_with_coupon":54.00}',
                       '{"current":44.10,"required":49.10,"at_60_with_coupon":54}',
                       '{"current":44.10,"required":49.10,"at_60_with_coupon":54.00,"extra":0}'):
            with self.assertRaises(AssertionError):
                check_numerical_review(None, answer)

    def test_failing_reproducer_is_observed_even_when_wrapper_collects_its_result(self):
        output = "FAIL: test_cost (test_cost.CostTests.test_cost)\nAssertionError: 12 != 13\nRan 1 test in 0.001s\nFAILED (failures=1)\n"
        def message(args, text=output, failed=False):
            return {"role": "tool", "toolName": "run", "toolArgs": json.dumps({"program": "python", "args": args}),
                    "content": text, "failed": failed}
        for row in (message(["-B", "-m", "unittest", "test_cost"], failed=True),
                    message(["-B", "-c", "import unittest; unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromName('test_cost'))"])):
            self.assertTrue(diagnosis_audit(None, None, None, [row], None)["unittestFailureObserved"])
        for row in (message(["-m", "unittest"], "ModuleNotFoundError: test_cost", True),
                    message(["-c", "print('pretend failure')"]), message(["-m", "unittest"], "Ran 1 test\nOK")):
            with self.assertRaises(AssertionError):
                diagnosis_audit(None, None, None, [row], None)

    def test_redirect_citations_preserve_every_supported_url(self):
        fixture = {"base": "http://127.0.0.1:1234", "nonce": "DOC-test",
                   "requests": ["/current", "/current", "/current", "/old", "/archive"]}
        answer = {"release": "DOC-test", "page_limit": 240, "retries": True, "outdated_limit": 80}
        for paths in (("/current", "/old"), ("/current", "/archive"), ("/current", "/old", "/archive")):
            check_research(None, json.dumps({**answer, "sources": [fixture["base"] + p for p in paths]}), None, fixture)
        for bad in (["/old"], ["/current"], ["/current", "/unread"], ["/current", "/old", "/old"]):
            with self.assertRaises(AssertionError):
                check_research(None, json.dumps({**answer, "sources": [fixture["base"] + p for p in bad]}), None, fixture)
        with self.assertRaises(AssertionError):
            check_research(None, json.dumps({**answer, "page_limit": 80,
                "sources": [fixture["base"] + "/current", fixture["base"] + "/old"]}), None, fixture)
        with self.assertRaises(AssertionError):
            check_research(None, json.dumps({**answer, "sources": [fixture["base"] + "/current", fixture["base"] + "/old"]}),
                           None, {**fixture, "requests": ["/current"] * 3 + ["/archive"]})

    def test_no_progress_rejections_are_not_a_finished_task(self):
        message = {"role": "user", "internal": True,
                   "content": 'Execution recovery: {"fingerprint":"A"}\nAgent output recovery: attempt=1 cause=unfinished_outcome'}
        self.assertFalse(completion_loop([message, message]))
        self.assertTrue(completion_loop([message, message, message]))
        self.assertFalse(completion_loop([message, message, {"role": "tool"}, message]))
        self.assertFalse(completion_loop([{**message, "internal": False}] * 3))

    def test_exhaustive_project_oracle_matches_independently_calculated_routes(self):
        self.assertEqual(expected(INPUT), {"routes": [
            {"id": "back", "path": ["D", "A", "B"], "cost": 11},
            {"id": "lost", "path": [], "cost": None},
            {"id": "other", "path": ["E", "F"], "cost": 1},
            {"id": "same", "path": ["Q"], "cost": 0},
            {"id": "via", "path": ["A", "B", "D"], "cost": 5}]})


if __name__ == "__main__":
    unittest.main()
