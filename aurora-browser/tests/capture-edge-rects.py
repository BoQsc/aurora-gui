#!/usr/bin/env python3
"""Capture the Edge side of the box-geometry corpus: element rects and a frame.

The corpus's oracle is Microsoft Edge, the same oracle the pixel corpora use.
This tool asks Edge two questions about one fixture through Edge's own headless
mode, at the engine's page viewport and 1x device scale:

  * ``--dump-dom``, after a measurement script has been injected into a *scratch
    copy* of the fixture, which reports ``getBoundingClientRect()`` for every
    element carrying a ``data-rect`` attribute. Those are the standard-coordinate
    numbers the recipe compares against the engine's own boxes.
  * ``--screenshot``, the pixel frame the recipe compares against the engine's PPM.

Only the scratch copy carries the script, so the committed fixture stays
script-free and the engine never runs measurement code.

The rect TSV this writes is committed next to the fixture and is the oracle the
recipe reads; re-run this tool to refresh it against a newer Edge. This file is
original work, released under CC0/0BSD with the rest of the corpus.

Usage:
  python capture-edge-rects.py --html <fixture.html> --tsv <out.tsv>
      [--png <out.png>] [--width 1280] [--height 638] [--edge <msedge.exe>]
      [--keep] [--quiet]
"""
import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile

EDGE_CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]

MEASURE = """<script>
(function () {
  var rows = [];
  var nodes = document.querySelectorAll('[data-rect]');
  for (var i = 0; i < nodes.length; i++) {
    var r = nodes[i].getBoundingClientRect();
    rows.push([nodes[i].getAttribute('data-rect'), r.left, r.top, r.width, r.height]);
  }
  var out = document.getElementById('rect-dump');
  if (!out) {
    out = document.createElement('pre');
    out.id = 'rect-dump';
    out.style.display = 'none';
    document.body.appendChild(out);
  }
  out.textContent = JSON.stringify(rows);
})();
</script>
"""


def fail(message):
    sys.stderr.write("capture-edge-rects: %s\n" % message)
    sys.exit(1)


def find_edge(explicit):
    if explicit:
        if not os.path.isfile(explicit):
            fail("no such Edge executable: %s" % explicit)
        return explicit
    for path in EDGE_CANDIDATES:
        if os.path.isfile(path):
            return path
    fail("Edge not found; pass --edge <msedge.exe>")


def num(value):
    """Format a rect component without inventing or hiding precision."""
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return "%.4f" % value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", required=True)
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--png")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=638)
    ap.add_argument("--edge")
    ap.add_argument("--keep", action="store_true",
                    help="keep the scratch directory and the injected copy")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    source = open(args.html, encoding="utf-8").read()
    if "data-rect" not in source:
        fail("%s carries no data-rect attributes" % args.html)

    scratch = tempfile.mkdtemp(prefix="aurora-edge-rects-")
    profile = os.path.join(scratch, "edge-profile")
    injected = os.path.join(scratch, os.path.basename(args.html))
    marker = "</body>"
    cut = source.lower().rfind(marker)
    if cut < 0:
        cut = len(source)
    open(injected, "w", encoding="utf-8").write(source[:cut] + MEASURE + source[cut:])

    edge = find_edge(args.edge)
    url = "file:///" + os.path.abspath(injected).replace("\\", "/")
    common = [edge, "--headless=new", "--force-device-scale-factor=1",
              "--window-size=%d,%d" % (args.width, args.height), "--hide-scrollbars",
              "--no-first-run", "--no-default-browser-check",
              "--user-data-dir=" + profile]

    dom_cmd = common + ["--dump-dom", url]
    if not args.quiet:
        print("EDGE: " + " ".join(dom_cmd))
    dom = subprocess.run(dom_cmd, capture_output=True, text=True, timeout=180)
    if dom.returncode != 0:
        fail("Edge --dump-dom failed (%d): %s" % (dom.returncode, dom.stderr.strip()))

    match = re.search(r'<pre id="rect-dump"[^>]*>(.*?)</pre>', dom.stdout, re.S)
    if match is None:
        snippet = " ".join(dom.stdout.split())[:400]
        fail("no rect dump in the DOM; Edge returned: %s" % snippet)
    try:
        rows = json.loads(html.unescape(match.group(1)))
    except ValueError as exc:
        fail("the rect dump is not JSON (%s)" % exc)
    if not rows:
        fail("the rect dump is empty")

    seen = set()
    lines = []
    for row in rows:
        if len(row) != 5:
            fail("bad rect row: %r" % (row,))
        name, values = row[0], row[1:]
        if name in seen:
            fail("duplicate data-rect name: %s" % name)
        seen.add(name)
        lines.append("\t".join([name] + [num(float(v)) for v in values]))
    open(args.tsv, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    if not args.quiet:
        print("captured %d rects -> %s" % (len(lines), args.tsv))

    if args.png:
        png_cmd = common + ["--screenshot=" + os.path.abspath(args.png), url]
        if not args.quiet:
            print("EDGE: " + " ".join(png_cmd))
        shot = subprocess.run(png_cmd, capture_output=True, text=True, timeout=180)
        if shot.returncode != 0:
            fail("Edge --screenshot failed (%d): %s" % (shot.returncode, shot.stderr.strip()))
        if not os.path.isfile(args.png):
            fail("Edge reported success but wrote no frame: %s" % args.png)
        if not args.quiet:
            print("wrote %s (%d bytes)" % (args.png, os.path.getsize(args.png)))

    if args.keep:
        print("scratch: %s" % scratch)
    else:
        import shutil
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
