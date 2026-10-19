"""Pin a real page's live heap and resident size, after the retention fix.

One load of boqsc.eu used to settle at ~904 MiB used / 1046 MiB resident while
the page was open, because every background layer that stacked into the page's
veils was rasterised into its own fresh RGBA buffer and `RgbaImage` (which
copies its buffer) on every paint generation: the body stacks about six layers
at 1280x2271, so a load kept hundreds of MB of dead layer buffers alive.

The fix renders the layers into one accumulating buffer and reuses the layer,
mask and mask-column scratch across boxes and generations. What this recipe
watches is the result, measured on the same page through the same probe:

    pre-fix   418.0 MiB used / 539.2 MiB resident after a collection
    now       180.1 MiB used / 308.8 MiB resident after a collection

The ceilings below sit well above the settled figures and well below the
pre-fix ones, so a reintroduced per-layer buffer, a retained mask layer or a
re-materialised art scratch fails here instead of on the user's machine. The
resident figure is the process's committed size, which the D runtime does not
decommit after a collection, so it is capped separately and more loosely.

The page is fetched from the live site, which the site-capture recipes already
do, and the probe prints exactly what it measured so a failure shows the number.

usage: python -u -B check-page-memory.py <pageperf.exe> [url] [width] [height]
"""
import re
import subprocess
import sys
import unittest

ARGS = [a for a in sys.argv[1:] if not a.startswith("-")]
PROBE = ARGS[0] if ARGS else ""
URL = ARGS[1] if len(ARGS) > 1 else "https://boqsc.eu/"
WIDTH = ARGS[2] if len(ARGS) > 2 else "1280"
HEIGHT = ARGS[3] if len(ARGS) > 3 else "900"

# Settled live heap and committed size after the load's last collection. The
# spread between runs is the page's own images and the passes the load needs:
# 21 images settle at 27 MiB of decoded pixels and 24 (the blog's photographs)
# at 40 MiB, and measured loads have settled between 162 and 274 MiB used. The
# ceilings sit above that spread and well below the pre-fix 418 MiB.
SETTLED_USED_MAX = 340.0
SETTLED_RESIDENT_MAX = 480.0
# The committed size reached while the page was being loaded and painted.
PEAK_RESIDENT_MAX = 520.0

PROBE_TIMEOUT_S = 240
_probe_output = None


def probe_output():
    """Run the page-load probe once and return its stdout."""
    global _probe_output
    if _probe_output is None:
        if not PROBE:
            raise AssertionError("pageperf probe path not given")
        _probe_output = subprocess.check_output(
            [PROBE, "--pageload", URL, WIDTH, HEIGHT],
            stderr=subprocess.STDOUT, text=True, timeout=PROBE_TIMEOUT_S)
    return _probe_output


def measured(label):
    """The `label: heap X MiB used / Y MiB free; resident Z MiB (peak W MiB)` row."""
    m = re.search(
        r"^ *" + re.escape(label) + r": heap ([\d.]+) MiB used / ([\d.]+) MiB free; "
        r"resident ([\d.]+) MiB \(peak ([\d.]+) MiB\)",
        probe_output(), re.MULTILINE)
    if not m:
        raise AssertionError("no %r measurement in the probe output:\n%s"
                             % (label, probe_output()))
    return tuple(float(g) for g in m.groups())


def load_summary():
    """Element count, layout count and peak resident of the load itself."""
    m = re.search(r"^load: [\d.]+ ms, (\d+) pass\(es\), (\d+) layout\(s\), "
                  r"(\d+) elements", probe_output(), re.MULTILINE)
    if not m:
        raise AssertionError("no load summary in the probe output:\n%s"
                             % probe_output())
    return tuple(int(g) for g in m.groups())


def decoded_pixels():
    """How many images the document decoded and how many bytes they hold."""
    m = re.search(r"decoded pixels: (\d+) image\(s\), ([\d.]+) MiB", probe_output())
    if not m:
        raise AssertionError("no decoded-pixels row in the probe output:\n%s"
                             % probe_output())
    return int(m.group(1)), float(m.group(2))


class PageMemoryBudget(unittest.TestCase):
    def test_the_page_actually_loaded(self):
        """A budget that measures an empty page would pass for the wrong reason."""
        passes, layouts, elements = load_summary()
        images, pixels = decoded_pixels()
        print("load: %d pass(es), %d layout(s), %d elements, %d image(s) = %.1f MiB"
              % (passes, layouts, elements, images, pixels))
        self.assertGreaterEqual(elements, 300,
                                "boqsc.eu lays out ~328 elements")
        self.assertGreaterEqual(images, 10,
                                "the page's icons and photographs decode")
        self.assertGreaterEqual(pixels, 10.0,
                                "decoded pixels are retained for the document")

    def test_settled_live_heap_stays_under_the_budget(self):
        used, _free, resident, _peak = measured("after a collection")
        print("settled: %.1f MiB used / %.1f MiB resident" % (used, resident))
        self.assertLessEqual(
            used, SETTLED_USED_MAX,
            "settled live heap %.1f MiB exceeds %.1f MiB: a buffer that the "
            "load no longer needs is still reachable" % (used, SETTLED_USED_MAX))

    def test_settled_resident_stays_under_the_budget(self):
        _used, _free, resident, _peak = measured("after a collection")
        self.assertLessEqual(
            resident, SETTLED_RESIDENT_MAX,
            "settled resident %.1f MiB exceeds %.1f MiB" % (resident, SETTLED_RESIDENT_MAX))

    def test_loading_does_not_peak_at_the_retained_size(self):
        """The pre-fix peak was the retained size itself: buffers never freed."""
        _used, _free, resident, peak = measured("after load")
        print("peak while loading: %.1f MiB resident" % peak)
        self.assertLessEqual(
            peak, PEAK_RESIDENT_MAX,
            "loading peaked at %.1f MiB resident, above %.1f MiB: the paint pass "
            "is allocating whole-page buffers again" % (peak, PEAK_RESIDENT_MAX))

    def test_dropping_the_page_does_not_leave_more_behind(self):
        """Tearing the page down must not add state the load did not have.

        The probe reads this after a collection with the page still alive and
        again after dropping it. A conservative collector can keep the dropped
        page reachable through a stale pointer, so a large drop here is not
        something to rely on; what is checked is that the drop never *grows* the
        heap, which is where a teardown that publishes into a cache would show.
        """
        before = measured("after a collection")[0]
        after = measured("after dropping the page")[0]
        print("dropped: %.1f MiB used (was %.1f MiB)" % (after, before))
        self.assertLessEqual(
            after, before + 8.0,
            "dropping the page raised the live heap from %.1f MiB to %.1f MiB"
            % (before, after))


    def test_navigating_again_does_not_carry_the_previous_page(self):
        """Four loads in one process: the settled heap must stop rising.

        Each page is dropped when its loading frame returns and the free pools
        are returned, so a page still held by an engine cache or a module-level
        map shows up as a step up in the next settled figure. What this test
        pins is the shape, not the level: one boqsc.eu load settles at ~200 MiB
        and each further one at ~240 MiB, which is one page's own document and
        its decoded images - and it stays there. Before the retention fixes this
        figure rose with every load until the process held gigabytes.
        """
        second = measured("second after a collection")[0]
        third = measured("third after a collection")[0]
        fourth = measured("fourth after a collection")[0]
        print("loads 2..4: %.1f / %.1f / %.1f MiB used" % (second, third, fourth))
        self.assertLessEqual(
            fourth, second + 20.0,
            "the fourth load settled at %.1f MiB used against %.1f MiB for the "
            "second: every load is leaving its document behind"
            % (fourth, second))


if __name__ == "__main__":
    result = unittest.main(argv=[sys.argv[0]], exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
