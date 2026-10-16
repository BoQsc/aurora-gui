"""Verify that cache directives are honoured across two loads in one process.

Usage: python cache_check.py <port> [<urlprobe.exe>]

For each sheet the server offers, this drives ONE urlprobe process that:

  1. loads /cache/checksheet?sheet=<name> (records the bar colour),
  2. asks the server to change what it serves (/cache-flip), then
  3. loads the same page again (records the bar colour).

The probe writes the first load's render to "<out>.first.ppm" and the second
load's render to "<out>", so the two loads of the SAME process are compared.
Comparing inside one process does not depend on server state left behind by an
earlier case (the flip is server-global and persists).

Expected, per RFC 9111:

  plain    (no directives) the two loads agree   (a cache may reuse it)
  maxage   (max-age=600)   the two loads agree   (still fresh)
  nostore  (no-store)      the two loads differ   (must not be reused)
  nocache  (no-cache)      the two loads differ   (not reused unvalidated)

The bar is a 60x20 div at (0,0) whose colour comes from the LINKED sheet, so a
reused byte range keeps the old colour and a refetch shows the new one.
"""
import pathlib
import subprocess
import sys

DEFAULT_PROBE = str(pathlib.Path(__file__).resolve().parent / 'urlprobe.exe')
REUSE = {
    'plain': True,
    'maxage': True,
    'nostore': False,
    'nocache': False,
}


def read_ppm_bar(path):
    data = pathlib.Path(path).read_bytes()
    parts = data.split(b"\n", 3)
    width = int(parts[1].split()[0])
    body = parts[3]
    o = (10 * width + 10) * 3
    return body[o:o + 3]


def main():
    port = int(sys.argv[1])
    probe = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_PROBE
    failures = 0
    for name in ('plain', 'maxage', 'nostore', 'nocache'):
        out = pathlib.Path(__file__).resolve().parent / ('cache_%s.ppm' % name)
        first = pathlib.Path(str(out) + '.first.ppm')
        url = 'http://127.0.0.1:%d/cache/checksheet?sheet=%s' % (port, name)
        flip = 'http://127.0.0.1:%d/cache-flip' % port
        cmd = [probe, url, '320', '240', str(out), flip]
        print('  cmd: %r' % (cmd,), flush=True)
        subprocess.run(cmd, check=True, timeout=120, capture_output=True)
        before = read_ppm_bar(first)
        after = read_ppm_bar(out)
        reused = before == after
        ok = reused == REUSE[name]
        print('%-8s before=%s after=%s reused=%-5s expect_reuse=%-5s %s'
              % (name, before.hex(), after.hex(), reused, REUSE[name],
                 'OK' if ok else 'FAIL'), flush=True)
        if not ok:
            failures += 1
        out.unlink()
        first.unlink()
    print('cache cases failing: %d of 4' % failures)
    return failures


if __name__ == '__main__':
    sys.exit(1 if main() else 0)
