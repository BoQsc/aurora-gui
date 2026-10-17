#!/usr/bin/env python3
"""Pins what docs/rendering-status.md records about the real-site gaps closed on
2026-10-17: djangoproject.com's logo placement, the WOFF 1.0 webfont path and the
WOFF 2.0 webfont path its text faces need.

Every assertion quotes a measurement taken against an independent Edge frame, so
the record cannot silently drift back to the claims those measurements replaced
(the logo "19 rows" above its box, woff among "compressed formats" the engine
skips, a woff2 source "skipped" as a format gap).  The stale forms are asserted
absent as well.

Run:  python -u -B aurora-browser/tests/check-rendering-status.py
"""

import pathlib
import unittest

DOC = pathlib.Path(__file__).resolve().parents[1] / "docs" / "rendering-status.md"


class RenderingStatusRecord(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Whitespace is collapsed so a rewrap of the document cannot break the
        # quoted measurements; the words and numbers are what is pinned.
        cls.text = " ".join(DOC.read_text(encoding="utf-8").split())

    def test_logo_band_matches_edge(self):
        """The logo's painted ink band, measured page-only against Edge."""
        self.assertIn(
            "its ink occupies page y 20..55 x 61..164 against Edge's page y 20..55 x 63..166",
            self.text,
            "the logo's measured ink band against Edge is missing",
        )
        self.assertIn(
            "12, 12, 32, 87, 65, 65, 75, 12, 22, 8 against Edge's "
            "12, 12, 34, 87, 65, 66, 75, 12, 22, 9",
            self.text,
            "the row-for-row ink counts against Edge are missing",
        )
        self.assertIn("`a.logo` 104x36", self.text, "the logo's own box is missing")

    def test_logo_residues_recorded(self):
        """The two header residues that were measured and left open."""
        self.assertIn(
            "page y 31..46 where Edge's is 33..41",
            self.text,
            "the nav label band residue is missing",
        )
        self.assertIn(
            "x 383..1222 at page y 20",
            self.text,
            "the half-pixel nav ul edge residue is missing",
        )

    def test_woff_face_drawn_on_real_page(self):
        """The live-page evidence that the woff face is registered and drawn."""
        self.assertIn(
            "their ink columns match an independent Edge frame's within 1..4px, the heart",
            self.text,
            "the nav ink column comparison against Edge is missing",
        )
        self.assertIn(
            "icon at x 1071..1078 against Edge's 1074..1080.",
            self.text,
            "the FontAwesome heart measurement is missing",
        )
        self.assertIn(
            "unwraps a WOFF 1.0 one (`woff.d`, reached through `css.d`",
            self.text,
            "the woff decode path in css.d pickFontSrc is missing",
        )

    def test_woff2_decode_record_is_current(self):
        """The current wording: WOFF 1.0 unwrapped, WOFF 2.0 decoded."""
        self.assertIn(
            "`woff2.d`, over `brotli.d`, decodes the WOFF 2.0 container",
            self.text,
            "the woff2 decode path is missing from the record",
        )
        self.assertIn(
            "Its unittests cover compressed tables, tables stored verbatim, "
            "and a malformed container being rejected.",
            self.text,
            "the woff.d unittest coverage is missing",
        )
        self.assertIn(
            "candidate source is a woff is the fixture that would pin it",
            self.text,
            "the missing woff-only fixture should be recorded as a gap",
        )
        self.assertIn(
            "2772d27df0741ab3683a2f581c84edae744918d64249098eb2387db81c24bdbe",
            self.text,
            "the served Roboto-Light woff2 hash that pins the decode is missing",
        )

    def test_box_model_corpus_recorded(self):
        for required in ("aurora-browser/tests/reference/flex-geometry.html",
                         "aurora-browser/tests/reference/flex-geometry.edge.png",
                         "aurora-browser/tests/verify-flex-geometry.json",
                         "anonymous table row",
                         "38,404 mismatched of 816,640"):
            with self.subTest(required=required):
                self.assertIn(required, self.text)

    def test_no_stale_claims(self):
        for stale in ("19 rows", "next item to close", "compressed formats",
                      "`woff2` is the remaining format gap",
                      "and skips the woff2 ones"):
            with self.subTest(stale=stale):
                self.assertNotIn(stale, self.text, f"stale claim is back: {stale}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
