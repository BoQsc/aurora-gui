#!/usr/bin/env python3
"""Enforce the pixel-compatibility policy in docs/pixel-compatibility.md.

The policy says exactness is the default and that every reference comes from an
independent engine. This checker makes that mechanical instead of aspirational:

  * the policy's load-bearing sentences are pinned, so the rule cannot be edited
    away without failing a test;
  * every committed fixture is script-free, carries no inking text, and names its
    measured elements with data-rect;
  * every fixture's reference frame exists next to it;
  * every corpus recipe compares at channelTolerance 0 with
    maxDifferentPixels 0, and the rect corpus uses compare_rects --tolerance 0
    against a committed rect oracle;
  * every corpus recipe's input fingerprint names its fixture and its references,
    so a receipt cannot claim freshness over files it never hashed.

Run:  python -u -B aurora-browser/tests/check-pixel-compatibility.py
"""

import json
import pathlib
import re
import unittest

TESTS = pathlib.Path(__file__).resolve().parent
REPO = TESTS.parents[1]
DOC = REPO / "aurora-browser" / "docs" / "pixel-compatibility.md"
REFERENCE = TESTS / "reference"

# The corpora driven by a fixture plus a reference frame. Each entry is
# (recipe, fixture, extra committed references, recorded channel budget). The
# budget is 0 for every class A/B/C corpus. A class-D case - rasterisation the
# web does not specify to the unit - records the budget in the fixture itself
# and here, so it cannot spread to a second case or hide a geometry bug.
CORPORA = [
    ("verify-box-geometry.json", "box-geometry.html",
     ["box-geometry.edge.png", "box-geometry.edge.tsv"], 0),
    ("verify-flex-geometry.json", "flex-geometry.html",
     ["flex-geometry.edge.png"], 0),
    ("verify-flow-sizing.json", "flow-sizing.html",
     ["flow-sizing.edge.png"], 0),
    ("verify-article-panel.json", "article-panel.html",
     ["article-panel.edge.png"], 0),
    ("verify-linear-gradient.json", "linear-gradient.html",
     ["linear-gradient.edge.png"], 1),
]


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def inks_text(source):
    """Whether a fixture would paint text: comments, style, script and tags out."""
    body = re.sub(r"<!--.*?-->", " ", source, flags=re.S)
    body = re.sub(r"<(style|script)\b.*?</\1>", " ", body, flags=re.S | re.I)
    body = re.sub(r"<[^>]*>", " ", body)
    return bool(body.strip())


class PixelCompatibilityPolicy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = " ".join(DOC.read_text(encoding="utf-8").split())

    def test_policy_pins_the_classes_and_rules(self):
        for required in (
            "**0 differing pixels** at `channelTolerance 0`",
            "0 rect deltas** at `--tolerance 0`",
            "Never byte-exact across engines.",
            "No script.",
            "No text that inks.",
            "Solid rectangles.",
            "never a global tolerance that would hide a geometry bug",
            "A budget may never cover geometry:",
            "17,430 of the 57,600 ramp pixels differ by exactly 1 channel unit"
            " and none by more",
            "can never prove correctness",
            "keep it a **separate acquisition",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.text)

    def test_policy_records_the_current_corpora(self):
        for required in ("box-geometry.html", "flex-geometry.html",
                         "flow-sizing.html", "article-panel.html",
                         "linear-gradient.html", "0 of 819,200 pixels",
                         "AD21B644", "99A4A532", "6C33FC27", "13AB4D92",
                         "B702DDB2"):
            with self.subTest(required=required):
                self.assertIn(required, self.text)

    def test_fixtures_are_script_free_and_measure_by_name(self):
        fixtures = sorted(REFERENCE.glob("*.html"))
        self.assertTrue(fixtures, "no reference fixtures found")
        for fixture in fixtures:
            with self.subTest(fixture=fixture.name):
                source = fixture.read_text(encoding="utf-8")
                self.assertNotIn("<script", source.lower(),
                                 "a committed fixture carries a script")
                rect_oracle = REFERENCE / (fixture.stem + ".edge.tsv")
                if rect_oracle.is_file():
                    self.assertGreaterEqual(
                        len(re.findall(r'data-rect="', source)), 1,
                        "a fixture with a rect oracle measures nothing by name")
                    self.assertGreaterEqual(
                        len(rect_oracle.read_text(encoding="utf-8").splitlines()), 1,
                        "the rect oracle is empty")
                # No inking text: cases either hold no text at all or neutralise it.
                self.assertFalse(
                    inks_text(source) and "font-size: 0" not in source,
                    "a fixture paints text without neutralising it")

    def test_every_fixture_has_a_reference_frame(self):
        for fixture in sorted(REFERENCE.glob("*.html")):
            oracle = REFERENCE / (fixture.stem + ".edge.png")
            with self.subTest(fixture=fixture.name):
                self.assertTrue(oracle.is_file(),
                                "no committed reference frame for %s" % fixture.name)

    def test_corpus_recipes_compare_exactly(self):
        for recipe_name, fixture, committed, budget in CORPORA:
            recipe = load(TESTS / recipe_name)
            with self.subTest(recipe=recipe_name):
                inputs = recipe["inputs"]
                for wanted in [fixture] + committed:
                    self.assertTrue(
                        any(wanted in entry for entry in inputs),
                        "%s does not name %s in its input fingerprint"
                        % (recipe_name, wanted))
                renders = [s for s in recipe["steps"] if s.get("kind") == "render"]
                self.assertTrue(renders, "%s has no render step" % recipe_name)
                for step in renders:
                    self.assertEqual(step.get("channelTolerance"), budget,
                                     "%s does not use its recorded channel budget"
                                     % recipe_name)
                    self.assertEqual(step.get("maxDifferentPixels"), 0,
                                     "%s allows differing pixels" % recipe_name)
                if budget:
                    # A nonzero budget must be the smallest one that admits a
                    # rasteriser's rounding, and the case must say so itself.
                    self.assertEqual(budget, 1,
                                     "%s widened the recorded budget" % recipe_name)
                    source = (REFERENCE / fixture).read_text(encoding="utf-8")
                    self.assertIn("CLASS D", source,
                                  "%s budgets without declaring a class-D case"
                                  % recipe_name)
                    self.assertIn("budget", source,
                                  "%s budgets without recording its reason"
                                  % recipe_name)
                rects = [
                    s for s in recipe["steps"]
                    if s.get("kind") == "tests"
                    and "compare_rects.py" in json.dumps(s["command"]["args"])
                ]
                for step in rects:
                    args = step["command"]["args"]
                    self.assertIn("--tolerance", args)
                    self.assertEqual(args[args.index("--tolerance") + 1], "0",
                                     "%s loosened rect tolerance" % recipe_name)
                    self.assertIn(".tsv", " ".join(args),
                                  "%s compares no rect oracle" % recipe_name)

    def test_the_box_corpus_carries_no_ledger(self):
        recipe = load(TESTS / "verify-box-geometry.json")
        args = [json.dumps(s["command"]["args"]) for s in recipe["steps"]
                if s.get("kind") == "tests"]
        for blob in args:
            self.assertNotIn("--known-open", blob,
                             "a ledger is back in the rect comparison")


if __name__ == "__main__":
    unittest.main(verbosity=2)
