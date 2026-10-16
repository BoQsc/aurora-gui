"""Serve crafted HTTP responses so loading behaviour can be judged against Edge.

Usage: python loading_server.py <port>

Routes (every page is text-free: a div's colour changes only when the response
was decoded correctly, so a pixel comparison is meaningful despite font
differences):

  /plain            control: plain UTF-8 HTML, blue bar
  /gzip             Content-Encoding: gzip
  /deflate          Content-Encoding: deflate (zlib wrapper)
  /rawdeflate       Content-Encoding: deflate (raw, no zlib wrapper)
  /chunked          Transfer-Encoding: chunked
  /redirect302      302 Found -> /plain
  /redirect301      301 Moved Permanently -> /plain
  /bom              UTF-8 BOM before the markup
  /cp1252-meta      cp1252 document declaring <meta charset>, UTF-8 stylesheet:
                    the bar is red only if BOTH were decoded by their own charset
  /cp1252-header    the same, with charset only in the Content-Type header
  /latin1-unlabelled cp1252 bytes with no charset anywhere (browsers default to
                    windows-1252)
  /css-charset-header  ASCII-only HTML whose class uses the numeric entity
                    &#233;, and a stylesheet served as text/css with
                    charset=windows-1252 whose selector holds the raw E9 byte.
                    Red only when the SUBRESOURCE's own charset is honoured.
  /css-charset-inherit a cp1252 document (encoding inherited from its own
                    charset) linking an UNLABELLED cp1252 stylesheet: per CSS
                    4.4 the sheet inherits the document's encoding, so the raw
                    E9 byte decodes to the same character as the document's.
  /data-css-charset  a `data:text/css;charset=windows-1252,...` stylesheet with
                    a percent-encoded E9 byte in its selector, linked from
                    ASCII-only markup. Red only when a data URL's own media type
                    parameters are honoured (RFC 2397).
  /notfound         404 with a body (the body is still rendered)
"""
import gzip
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# The sheet /cache/checksheet links to, chosen with `?sheet=<name>`; the colour it
# serves flips when /cache-flip is requested, so a stale cache reuse is visible.
_cache_sheet_name = 'plain'
_cache_flipped = False


def cache_sheet_name():
    return _cache_sheet_name.encode()


def flip_cache_sheet():
    global _cache_flipped
    # Toggle, so every cache case sees a genuine colour change: a load before
    # the flip and a load after it differ unless the earlier bytes were reused.
    _cache_flipped = not _cache_flipped


def cache_sheet(name):
    body = CACHE_SHEETS[name]
    return body.replace(b'#cc2244', b'#22aa44') if _cache_flipped else body

# The html is cp1252: "café" as the single byte E9. The stylesheet is UTF-8:
# "café" as C3 A9. Correct per-resource decoding makes them the same class name,
# so the rule matches and the bar is red; decoding everything as UTF-8 leaves the
# html's E9 undecodable and the bar keeps .bar's blue.
HTML_CP1252 = (b'<!doctype html><meta charset=windows-1252>'
               b'<link rel=stylesheet href="/cp1252.css">'
               b'<style>html,body{margin:0;background:#fff}'
               b'.bar{width:60px;height:20px;background:#2266cc}</style>'
               b'<div class="bar caf\xe9"></div>')
HTML_HEADER_CP1252 = (b'<!doctype html><link rel=stylesheet href="/cp1252.css">'
                      b'<style>html,body{margin:0;background:#fff}'
                      b'.bar{width:60px;height:20px;background:#2266cc}</style>'
                      b'<div class="bar caf\xe9"></div>')
CSS_UTF8 = ('.café{background:#cc2244}\n').encode('utf-8')

# Selector with the raw windows-1252 byte E9, and a two-class selector so it
# outranks the plain .bar rule whatever the source order.
CSS_CP1252 = b'.bar.caf\xe9{background:#cc2244}\n'

# ASCII-only markup: the class name reaches the DOM through the numeric entity,
# so the document decodes identically under any charset and only the stylesheet's
# own encoding can make this match.
HTML_ASCII_ENTITY = (b'<!doctype html><link rel=stylesheet href="/css-cp1252.css">'
                     b'<style>html,body{margin:0;background:#fff}'
                     b'.bar{width:60px;height:20px;background:#2266cc}</style>'
                     b'<div class="bar caf&#233;"></div>')

# cp1252 document (charset declared for itself) whose stylesheet is unlabelled.
HTML_CP1252_ENTITY = (b'<!doctype html><meta charset=windows-1252>'
                      b'<link rel=stylesheet href="/css-cp1252-unlabelled.css">'
                      b'<style>html,body{margin:0;background:#fff}'
                      b'.bar{width:60px;height:20px;background:#2266cc}</style>'
                      b'<div class="bar caf\xe9"></div>')

# The stylesheet travels as a data URL whose media type declares windows-1252 and
# whose selector holds a percent-encoded E9 byte. The document is ASCII-only, so
# only the data URL's own declaration can make the selector reach "café".
HTML_DATA_CSS = (
    b'<!doctype html>'
    b'<link rel=stylesheet href="data:text/css;charset=windows-1252,'
    b'.bar.caf%E9{background:%23cc2244}">'
    b'<style>html,body{margin:0;background:#fff}'
    b'.bar{width:60px;height:20px;background:#2266cc}</style>'
    b'<div class="bar caf&#233;"></div>')

# Cache-directive fixtures. /cache/checksheet links to /cache/<name>, whose sheet
# flips colour after /cache-flip, so an unwise cache reuse shows the old colour.
CACHE_SHEETS = {
    'plain': b'.bar{width:60px;height:20px;background:#cc2244}\n',
    'maxage': b'.bar{width:60px;height:20px;background:#cc2244}\n',
    'nostore': b'.bar{width:60px;height:20px;background:#cc2244}\n',
    'nocache': b'.bar{width:60px;height:20px;background:#cc2244}\n',
}
CACHE_DIRECTIVES = {
    'plain': None,
    'maxage': 'public, max-age=600',
    'nostore': 'no-store',
    'nocache': 'no-cache',
}
# The bar's size and colour both come from the LINKED sheet, so the cache
# decision is what the sampled pixel reflects. An inline `.bar` rule of equal
# specificity would win by source order (verified against Edge), masking the
# linked sheet entirely.
HTML_CACHE = (b'<!doctype html><link rel=stylesheet href="/cache/%(name)s">'
              b'<style>html,body{margin:0;background:#fff}</style>'
              b'<div class="bar"></div>')

PLAIN = (b'<!doctype html><style>html,body{margin:0;background:#fff}'
         b'.bar{width:60px;height:20px;background:#2266cc}</style>'
         b'<div class="bar"></div>')


def chunked(data, size=16):
    out = b''
    for i in range(0, len(data), size):
        piece = data[i:i + size]
        out += b'%x\r\n' % len(piece) + piece + b'\r\n'
    return out + b'0\r\n\r\n'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send(self, status, body, headers=()):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        global _cache_sheet_name
        if path == '/cache/checksheet':
            query = parse_qs(urlsplit(self.path).query)
            _cache_sheet_name = (query.get('sheet') or ['plain'])[0]
        if path == '/plain':
            self.send(200, PLAIN, [('Content-Type', 'text/html')])
        elif path == '/gzip':
            self.send(200, gzip.compress(PLAIN),
                      [('Content-Type', 'text/html'), ('Content-Encoding', 'gzip')])
        elif path == '/deflate':
            self.send(200, zlib.compress(PLAIN),
                      [('Content-Type', 'text/html'), ('Content-Encoding', 'deflate')])
        elif path == '/rawdeflate':
            compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
            body = compressor.compress(PLAIN) + compressor.flush()
            self.send(200, body,
                      [('Content-Type', 'text/html'), ('Content-Encoding', 'deflate')])
        elif path == '/chunked':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            self.wfile.write(chunked(PLAIN))
        elif path == '/redirect302':
            self.send(302, b'', [('Location', '/plain')])
        elif path == '/redirect301':
            self.send(301, b'', [('Location', '/plain')])
        elif path == '/bom':
            self.send(200, b'\xef\xbb\xbf' + PLAIN, [('Content-Type', 'text/html')])
        elif path == '/cp1252-meta':
            self.send(200, HTML_CP1252, [('Content-Type', 'text/html')])
        elif path == '/cp1252-header':
            self.send(200, HTML_HEADER_CP1252,
                      [('Content-Type', 'text/html; charset=windows-1252')])
        elif path == '/cp1252.css':
            self.send(200, CSS_UTF8,
                      [('Content-Type', 'text/css; charset=utf-8')])
        elif path == '/css-cp1252.css':
            self.send(200, CSS_CP1252,
                      [('Content-Type', 'text/css; charset=windows-1252')])
        elif path == '/css-cp1252-unlabelled.css':
            self.send(200, CSS_CP1252, [('Content-Type', 'text/css')])
        elif path == '/css-charset-header':
            self.send(200, HTML_ASCII_ENTITY, [('Content-Type', 'text/html')])
        elif path == '/css-charset-inherit':
            self.send(200, HTML_CP1252_ENTITY, [('Content-Type', 'text/html')])
        elif path == '/data-css-charset':
            self.send(200, HTML_DATA_CSS, [('Content-Type', 'text/html')])
        elif path == '/cache/checksheet':
            self.send(200, HTML_CACHE % {b'name': cache_sheet_name()},
                      [('Content-Type', 'text/html')])
        elif path.startswith('/cache/'):
            name = path[len('/cache/'):]
            if name not in CACHE_SHEETS:
                self.send(404, b'no route', [('Content-Type', 'text/plain')])
                return
            headers = [('Content-Type', 'text/css')]
            directive = CACHE_DIRECTIVES[name]
            if directive is not None:
                headers.append(('Cache-Control', directive))
            self.send(200, cache_sheet(name), headers)
        elif path == '/cache-flip':
            flip_cache_sheet()
            self.send(200, b'flipped', [('Content-Type', 'text/plain')])
        elif path == '/latin1-unlabelled':
            self.send(200, HTML_CP1252.replace(b'<meta charset=windows-1252>', b''),
                      [('Content-Type', 'text/html')])
        elif path == '/notfound':
            self.send(404, PLAIN, [('Content-Type', 'text/html')])
        else:
            self.send(404, b'no route', [('Content-Type', 'text/plain')])


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8731
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print('PORT %d' % server.server_address[1], flush=True)
    server.serve_forever()
