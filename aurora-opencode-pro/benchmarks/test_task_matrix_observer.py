import unittest

from task_matrix_runner import completion_loop
from task_matrix_project import expected, INPUT


class MatrixObserverTests(unittest.TestCase):
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
