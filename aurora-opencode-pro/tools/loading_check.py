"""Compare Edge and Aurora on crafted HTTP responses.

Usage: python loading_check.py <port> [<edge.exe>] [<urlprobe.exe>]

For each route it screenshots the URL in Edge (headless, 320x240, hidden
scrollbars, device scale factor 1) and renders it through urlprobe.exe, then
reports the sampled bar colour from both, the mismatch count and the bounding
box. The bar is a 60x20 div at (0,0); blue means the page loaded at all, red
means the per-resource charsets decoded so the cp1252 class name matched the
UTF-8 stylesheet's selector.

Build the probe first, from the repository root:

  dmd -m64 -i -Iaurora-web/source -Ivendor/aurora-d-0.4.5/source \
      -of=<dir>/urlprobe.exe aurora-opencode-pro/tools/urlprobe.d \
      -Luser32.lib -Lgdi32.lib -Lshell32.lib -Lws2_32.lib -Ladvapi32.lib -Lole32.lib

and start the server in another terminal:

  python aurora-opencode-pro/tools/loading_server.py 8731
"""
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


def read_png(path):
    """Decode a non-interlaced 8-bit RGB/RGBA PNG to (width, height, rgb)."""
    data = pathlib.Path(path).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG: ' + str(path)
    pos = 8
    width = height = color = None
    idat = b''
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b'IHDR':
            (width, height, depth, color, _comp, _filt, interlace) = \
                struct.unpack('>IIBBBBB', body)
            assert depth == 8 and interlace == 0, (depth, interlace)
        elif kind == b'IDAT':
            idat += body
        elif kind == b'IEND':
            break
    assert color in (2, 6), 'unsupported PNG colour type %r' % (color,)
    channels = 3 if color == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray(width * height * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        filt = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pred = a + b - c
                pa, pb, pc = abs(pred - a), abs(pred - b), abs(pred - c)
                best = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + best) & 0xFF
        base = y * width * 3
        for x in range(width):
            out[base + x * 3:base + x * 3 + 3] = line[x * channels:x * channels + 3]
        prev = line
    return width, height, bytes(out)

EDGE = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
DEFAULT_PROBE = str(pathlib.Path(__file__).resolve().parent / 'urlprobe.exe')
CASES = ['plain', 'gzip', 'deflate', 'rawdeflate', 'chunked', 'redirect302',
         'redirect301', 'bom', 'cp1252-meta', 'cp1252-header',
         'latin1-unlabelled', 'css-charset-header', 'css-charset-inherit',
         'data-css-charset', 'notfound']


def read_ppm(path):
    data = pathlib.Path(path).read_bytes()
    parts = data.split(b"\n", 3)
    w, h = (int(x) for x in parts[1].split())
    return w, h, parts[3]


def sample(w, buf, x, y):
    o = (y * w + x) * 3
    return '%02X%02X%02X' % (buf[o], buf[o + 1], buf[o + 2])


def edge_shot(edge, url, out):
    subprocess.run([edge, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                    '--force-device-scale-factor=1', '--window-size=320,240',
                    '--user-data-dir=' + tempfile.mkdtemp(prefix='edgeprof'),
                    '--screenshot=' + out, url],
                   check=True, timeout=120, capture_output=True)


def main():
    port = int(sys.argv[1])
    edge = sys.argv[2] if len(sys.argv) > 2 else EDGE
    probe = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_PROBE
    failures = 0
    for case in CASES:
        url = 'http://127.0.0.1:%d/%s' % (port, case)
        png = str(pathlib.Path(tempfile.mkdtemp(prefix='loadshot')) / (case + '.png'))
        ppm = str(pathlib.Path(tempfile.mkdtemp(prefix='loadshot')) / (case + '.ppm'))
        try:
            edge_shot(edge, url, png)
            subprocess.run([probe, url, '320', '240', ppm], check=True,
                           timeout=120, capture_output=True)
            rw, rh, ref = read_png(png)
            aw, ah, act = read_ppm(ppm)
        except Exception as exc:                     # noqa: BLE001
            print('%-20s ERROR: %s' % (case, str(exc)[:160]), flush=True)
            failures += 1
            continue
        diff = 0
        minx, maxx, miny, maxy = rw, -1, rh, -1
        for y in range(rh):
            for x in range(rw):
                o = (y * rw + x) * 3
                if ref[o:o + 3] != act[o:o + 3]:
                    diff += 1
                    minx = min(minx, x); maxx = max(maxx, x)
                    miny = min(miny, y); maxy = max(maxy, y)
        box = '' if not diff else ' bbox x=%d..%d y=%d..%d' % (minx, maxx, miny, maxy)
        verdict = 'OK  ' if diff == 0 else 'DIFF'
        print('%-20s %s edge=%s aurora=%s mismatched=%d%s'
              % (case, verdict, sample(rw, ref, 10, 10), sample(aw, act, 10, 10),
                 diff, box), flush=True)
        if diff:
            failures += 1
    print('cases failing: %d of %d' % (failures, len(CASES)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
