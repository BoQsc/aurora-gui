#!/usr/bin/env python3
"""Compare the engine's element rects with the Edge oracle's, row by row.

Both files are TSV: ``name  x  y  width  height``, one row per element carrying a
``data-rect`` attribute. The reference is the committed Edge capture of the same
fixture (``reference/box-geometry.edge.tsv``); the actual is what the engine probe
wrote for the same viewport. A row whose components differ by more than
``--tolerance`` fails the run, so the two renderers are held to the same numbers
rather than to the same pixels.

``--known-open`` names rows that are recorded gaps: they are reported but do not
fail the run. A known-open row that starts matching is reported too, so the ledger
cannot quietly keep a name it no longer needs. Names in the reference that the
actual is missing (or the other way round) always fail.

Exit code 0 when every row matches within the tolerance, 1 otherwise. This file is
original work, released under CC0/0BSD with the rest of the corpus.

Usage:
  python compare_rects.py <reference.tsv> <actual.tsv> [--tolerance 0]
      [--known-open name,name]
"""
import argparse
import sys


def fail(message):
    sys.stderr.write("compare_rects: %s\n" % message)
    sys.exit(1)


def read_tsv(path):
    rows = []
    for lineno, line in enumerate(open(path, encoding="utf-8"), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            fail("%s line %d is not `name x y width height`: %r" % (path, lineno, line))
        try:
            values = [float(v) for v in parts[1:]]
        except ValueError:
            fail("%s line %d has a non-numeric rect: %r" % (path, lineno, line))
        rows.append((parts[0], values))
    if not rows:
        fail("%s holds no rows" % path)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("actual")
    ap.add_argument("--tolerance", type=float, default=0.0)
    ap.add_argument("--known-open", default="")
    args = ap.parse_args()

    reference = read_tsv(args.reference)
    actual = read_tsv(args.actual)
    ref = dict(reference)
    act = dict(actual)
    if len(ref) != len(reference):
        fail("%s repeats a name" % args.reference)
    if len(act) != len(actual):
        fail("%s repeats a name" % args.actual)
    known_open = set(n for n in args.known_open.split(",") if n)

    failures = 0
    for name in [n for n in ref if n not in act]:
        print("MISSING  %s: the reference names it, the engine's dump does not" % name)
        failures += 1
    for name in [n for n in act if n not in ref]:
        print("EXTRA    %s: the engine's dump names it, the reference does not" % name)
        failures += 1
    if [n for n, _ in reference] != [n for n, _ in actual]:
        print("NOTE     row order differs from the reference (compared by name)")

    compared = 0
    mismatched = 0
    for name, want in reference:
        if name not in act:
            continue
        got = act[name]
        compared += 1
        deltas = [g - w for w, g in zip(want, got)]
        if all(abs(d) <= args.tolerance for d in deltas):
            if name in known_open:
                print("CLOSED   %s now matches (%s) - drop it from --known-open"
                      % (name, " ".join(str(v) for v in got)))
            continue
        mismatched += 1
        line = "%s: Edge %s, engine %s, delta %s" % (
            name,
            " ".join(str(v) for v in want),
            " ".join(str(v) for v in got),
            " ".join("%+g" % d for d in deltas),
        )
        if name in known_open:
            print("OPEN     %s" % line)
        else:
            print("DIFF     %s" % line)
            failures += 1
    for name in sorted(known_open - set(n for n, _ in reference)):
        print("NOTE     --known-open names %s, which the reference does not hold" % name)

    print("rects: %d compared, %d mismatched (%d known open)"
          % (compared, mismatched, len(known_open & set(n for n, _ in reference))))
    if failures:
        print("rects: FAILED")
        return 1
    print("rects: ALL MATCH")
    return 0


if __name__ == "__main__":
    sys.exit(main())
