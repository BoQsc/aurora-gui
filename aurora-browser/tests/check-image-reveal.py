"""Pin the engine's answer to a page that waits for an image to settle.

boqsc.eu fades its hero photograph in only after the image reports itself
loaded:

    if (img.complete && img.naturalWidth > 0) reveal();
    else img.addEventListener('load', reveal);

The engine decoded and painted such an image but never told the page, so the
photograph stayed at `opacity: 0`. The fixture holds that exact pattern around
a red 120x120 `data:` PNG, and what it measures is whether the page was *told*:
the reveal class, and the image's own laid-out box next to it.

Painting is deliberately not measured here. A loaded document is drawn inside
the probe's window chrome, so this fixture's pixels are covered by the site
capture that compares against the Edge oracle instead.

The probe has to LOAD the fixture, not `--fixture` it: `--fixture` parses and
lays out a document without running its scripts, and the whole point of this
page is the script. Loading the file URL is the path that runs it.

usage: python -u -B check-image-reveal.py <probe.exe> [fixture.html] [out.ppm]
"""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FIXTURE = os.path.join(HERE, "fixtures", "image-reveal.html")
DEFAULT_OUT = os.path.join(os.environ.get("TEMP", "."), "aurora-image-reveal.ppm")

ARGS = [a for a in sys.argv[1:] if not a.startswith("-")]
PROBE = ARGS[0] if ARGS else ""
FIXTURE = ARGS[1] if len(ARGS) > 1 else DEFAULT_FIXTURE
OUT_PPM = ARGS[2] if len(ARGS) > 2 else DEFAULT_OUT

_probe_output = None


def fixture_url():
    """The fixture as a file URL, which is what makes the engine run its script."""
    return "file:///" + os.path.abspath(FIXTURE).replace("\\", "/")


def probe_output():
    """Run the capture probe once and return its stdout."""
    global _probe_output
    if _probe_output is None:
        if not PROBE or not os.path.exists(PROBE):
            raise AssertionError("probe executable not found: %r" % PROBE)
        _probe_output = subprocess.check_output(
            [PROBE, fixture_url(), "400", "400", OUT_PPM, "4", "AFTER",
             "is-loaded"],
            stderr=subprocess.STDOUT, text=True)
    return _probe_output


def read_ppm(path):
    """Width, height and RGB bytes of a binary PPM (P6)."""
    with open(path, "rb") as handle:
        data = handle.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while pos < len(data) and data[pos:pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1
    if fields[0] != b"P6":
        raise AssertionError("expected a binary PPM, got %r" % fields[0])
    return int(fields[1]), int(fields[2]), data[pos:]


def run_top(output, text):
    """The `layoutY` of the probe's laid-out run whose data is exactly `text`."""
    for line in output.splitlines():
        if not line.lstrip().startswith("run:") or not line.rstrip().endswith("'" + text + "'"):
            continue
        for token in line.split():
            if token.startswith("layoutY="):
                return int(token.split("=", 1)[1])
    return None


class ImageLoadedState(unittest.TestCase):
    def test_the_engine_reports_the_image_settled(self):
        output = probe_output()
        self.assertIn("subtree probe: 1", output, output)
        self.assertIn("is-loaded", output, output)

    def test_the_photo_keeps_its_laid_out_box(self):
        output = probe_output()
        self.assertIn("is-loaded box=(0,0 120x120)", output, output)

    def test_the_fixture_keeps_the_boqsc_reveal_pattern(self):
        with open(FIXTURE, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn("opacity: 0", source)
        self.assertIn("img.complete && img.naturalWidth > 0", source)
        self.assertIn("addEventListener('load'", source)
        # The binding-less `catch` has to stay: it is the construct whose
        # absence made the fixture's script - and boqsc.eu's - never run.
        self.assertIn("catch { }", source)


class LateImageLayout(unittest.TestCase):
    def test_the_tall_photograph_pushes_the_marker_below_it(self):
        """A photograph that settles after the first layout still moves the page.

        The figure above the marker is 80px wide with `height: auto` and holds a
        120x90 image, so its height is 80 * 90 / 120 = 60px and exists only once
        the image has decoded. Its own box (measured elsewhere) can be right
        while the surrounding flow is frozen at the pre-image geometry - that is
        the state boqsc.eu's hero was left in: the figure stayed zero rows tall,
        the photograph was painted into a zero-height clip, and the article text
        sat a whole image too high. The marker is about 180px from the top when
        the flow follows the image and about 120px when it does not (the 120px
        figure above it plus a line).
        """
        output = probe_output()
        top = run_top(output, "AFTER")
        self.assertIsNotNone(top, "the fixture's AFTER marker must be laid out:\n" + output)
        self.assertGreaterEqual(top, 160,
            "the marker must sit below the 80x60 photograph, got layoutY=%r:\n%s"
            % (top, output))


if __name__ == "__main__":
    result = unittest.main(argv=[sys.argv[0]], exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)
