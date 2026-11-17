"""python3 tests/test_icon_hd.py: icon_hd.py against a local stand-in for titledb and the eShop, and nxn_merge.py --hd-icons
putting the large icon in the game library (no network, no real games)."""
import http.server, importlib.util, json, os, plistlib, subprocess, sys, tempfile, threading, time, zipfile

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
spec = importlib.util.spec_from_file_location('icon_hd', os.path.join(APP, 'icon_hd.py'))
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)


def jpeg(side, fill=b'\x00' * 500):
    """a JPEG header with a baseline frame of side x side, enough for jpeg_size"""
    app0 = b'\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00'
    sof = b'\xff\xc0\x00\x11\x08' + side.to_bytes(2, 'big') + side.to_bytes(2, 'big') + b'\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01'
    return b'\xff\xd8' + app0 + sof + fill + b'\xff\xd9'


BIG, SMALL = jpeg(1024, b'\x11' * 900), jpeg(256)
TITLEDB = {
    '70010000000001': {'iconUrl': None, 'id': None, 'name': 'Some Demo'},
    '70010000000002': {'iconUrl': '/i/odyssey.jpg', 'id': '0100000000010000', 'name': 'Super Mario Odyssey™'},
    '70010000000003': {'iconUrl': '/i/unrailed-s2.jpg', 'id': '01006D00241E6000', 'name': 'Unrailed 2: Back on Track – Nintendo Switch™ 2 Edition'},
    '70010000000004': {'iconUrl': '/i/unrailed.jpg', 'id': '01006D00241E6000', 'name': 'Unrailed 2: Back on Track'},
    '70010000000005': {'iconUrl': '/i/small.jpg', 'id': '0100AAAA00000000', 'name': 'Tiny Icon'},
}
FILES = {'/i/odyssey.jpg': BIG, '/i/unrailed.jpg': BIG + b'u', '/i/unrailed-s2.jpg': BIG + b's2', '/i/small.jpg': SMALL}
hits = []


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        hits.append(self.path)
        if self.path == '/US.en.json':
            d = {k: dict(v, iconUrl=(base + v['iconUrl']) if v['iconUrl'] else None) for k, v in TITLEDB.items()}
            body = json.dumps(d, indent=4, sort_keys=True, ensure_ascii=False).encode('utf-8')
        elif self.path in FILES: body = FILES[self.path]
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
base = 'http://127.0.0.1:%d' % srv.server_port
threading.Thread(target=srv.serve_forever, daemon=True).start()
h.TITLEDB = base + '/%s.json'
h.REGIONS = ('US.en', 'XX.xx')   # the second is missing on the server: a region that cannot be fetched is skipped
h.UA = {}
fails = 0


def check(cond, what):
    global fails
    print(('ok   ' if cond else 'FAIL ') + what)
    fails += not cond


def test_fetch(tmp):
    cache = os.path.join(tmp, 'hd')
    r = h.fetch(cache, [('0100000000010000', 'SUPER MARIO ODYSSEY'), ('010593A5182E4000', 'Unrailed 2: Back on Track'),
                        ('0100AAAA00000000', 'Tiny Icon'), ('0100BBBB00000000', 'Not Listed')])
    check(r['0100000000010000'] == 'new' and h.cached(cache, '0100000000010000') == BIG, 'by title ID')
    check(r['010593A5182E4000'] == 'new' and h.cached(cache, '010593A5182E4000') == BIG + b'u', 'by name, not the Switch 2 Edition, when the title ID differs')
    check(r['0100AAAA00000000'].startswith('eShop icon not usable') and not os.path.exists(os.path.join(cache, '0100AAAA00000000.jpg')), 'a 256-pixel eShop icon is not taken')
    check(r['0100BBBB00000000'] == 'not on the eShop list', 'a game found nowhere')
    n = len(hits)
    r = h.fetch(cache, [('0100000000010000', ''), ('0100BBBB00000000', 'Not Listed')])
    check(r['0100000000010000'] == 'cached' and r['0100BBBB00000000'].endswith('(tried lately)') and len(hits) == n, 'second run: no downloads')
    check(not [f for f in os.listdir(cache) if f.startswith('titledb-') or f.endswith('.part')], 'no leftovers in the cache')
    idx = h.pick({'01006D00241E6000': [['Unrailed 2: Back on Track – Nintendo Switch™ 2 Edition', 'a'], ['Unrailed 2: Back on Track', 'b']]}, '01006D00241E6000', '')
    check(idx == 'b', 'the plain edition before the Switch 2 Edition')
    return cache


def ipa(path, tid, name, icon):
    """a single-game IPA as nxn_pack.py lays it out (only what nxn_merge.py reads)"""
    A = 'Payload/DmIOS.app/'
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr(A + 'Info.plist', plistlib.dumps({'CFBundleIdentifier': 'org.nxnative.' + tid.lower(), 'CFBundleDisplayName': name, 'CFBundleShortVersionString': '1.0'}))
        z.writestr(A + 'dm/shell_info.txt', 'MULTI=1\nSOURCE_SHA=abc\n')
        z.writestr(A + 'dm/icon.jpg', icon)
        z.writestr(A + 'dm/game.tsv', 'x')
        z.writestr(A + 'Frameworks/Guest.framework/Guest', b'guest')
        z.writestr(A + 'main', b'exe')


def test_merge(tmp, cache):
    a, b, out = (os.path.join(tmp, n) for n in ('a.ipa', 'b.ipa', 'lib.ipa'))
    ipa(a, '0100000000010000', 'SUPER MARIO ODYSSEY', SMALL)
    ipa(b, '0100BBBB00000000', 'Not Listed', SMALL + b'b')
    env = dict(os.environ, PYTHONPATH='')
    p = subprocess.run([sys.executable, '-I', os.path.join(APP, 'nxn_merge.py'), '-o', out, '--hd-icons', cache, a, b], capture_output=True, text=True, env=env)
    check(p.returncode == 0, 'merge runs (%s)' % (p.stdout + p.stderr).strip().replace('\n', ' | '))
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        g = 'Payload/DmIOS.app/games/%s/dm/icon.jpg'
        check(z.read(g % '0100000000010000') == BIG, 'the large icon is in the library')
        check(z.read(g % '0100BBBB00000000') == SMALL + b'b', 'a game with none keeps its own')
        check(len(names) == len(set(names)), 'no entry twice')
        check(z.testzip() is None, 'the library reads back')
    # a library merged again (adding a game) keeps the large icon
    out2 = os.path.join(tmp, 'lib2.ipa')
    p = subprocess.run([sys.executable, '-I', os.path.join(APP, 'nxn_merge.py'), '-o', out2, '--hd-icons', cache, out], capture_output=True, text=True, env=env)
    with zipfile.ZipFile(out2) as z: check(p.returncode == 0 and z.read(g % '0100000000010000') == BIG, 'merging the library again keeps it')
    # no network at all: the merge still goes through
    p = subprocess.run([sys.executable, '-I', os.path.join(APP, 'nxn_merge.py'), '-o', out, '--hd-icons', os.path.join(tmp, 'empty'), a, b],
                       capture_output=True, text=True, env=dict(env, HTTPS_PROXY='http://127.0.0.1:9', https_proxy='http://127.0.0.1:9', HTTP_PROXY='http://127.0.0.1:9'))
    check(p.returncode == 0, 'merge without the network still works')


with tempfile.TemporaryDirectory() as tmp:
    test_merge(tmp, test_fetch(tmp))
srv.shutdown()
sys.exit(1 if fails else 0)
