#!/usr/bin/env python3
"""Large game icons from the Nintendo eShop, for the iPad's game picker on a TV.

A game's own icon (control NCA, icon_<language>.dat) is 256 x 256: on a TV a picker tile is 700 to 1000 pixels across, so
it looks soft. The eShop shows the same art at 1024 x 1024; blawar/titledb lists its address (iconUrl) for each title ID.
nxn_merge.py --hd-icons puts the large one in the game library as games/<title ID>/dm/icon.jpg, which the picker and the
launcher read (GamePicker.swift gameIcon, Launcher.swift appIcon); a game with none found keeps its own.

    icon_hd.py <cache dir> <title ID>[=<name>] ...      fetch what is missing, print one line per game

The cache dir holds <title ID>.jpg, the titledb index (index-<region>.json, title ID -> names and icon addresses, built
once from the region's file and rebuilt after 30 days) and miss.json (games found nowhere, tried again after 7 days).
Standard library only. Nothing here stops a merge: a game whose icon cannot be fetched keeps its own.
"""
import json, os, re, sys, tempfile, time, unicodedata, urllib.request

TITLEDB = 'https://raw.githubusercontent.com/blawar/titledb/master/%s.json'
# Asked in this order, the next only for the games not found yet. US first: the 256-pixel icon the packer keeps is the
# AmericanEnglish one (icon_read.py), so the US eShop's is the same picture; the others for titles sold only there.
REGIONS = ('US.en', 'GB.en', 'JP.ja', 'HK.zh', 'KR.ko')
INDEX_DAYS, MISS_DAYS = 30, 7
MIN_SIDE = 512   # smaller is no better than the game's own
UA = {'User-Agent': 'SwitchPad-icons/1'}


def say(msg): print('icon_hd: ' + msg, flush=True)


def norm(name):
    """a name to compare: no ™ ® ©, no accents, no punctuation or spaces, lower case"""
    s = unicodedata.normalize('NFKD', name or '')
    s = ''.join(c for c in s if not unicodedata.combining(c))
    return re.sub(r'[\W_]+', '', s.replace('™', '').replace('®', '').replace('©', '')).lower()


def get(url, dest=None, timeout=60):
    """the body of url, or with dest, the body written to dest (through a temporary file next to it)"""
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if dest is None: return r.read()
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), suffix='.part')
        try:
            with os.fdopen(fd, 'wb') as f:
                while True:
                    b = r.read(1 << 20)
                    if not b: break
                    f.write(b)
            os.replace(tmp, dest)
        except BaseException:
            try: os.unlink(tmp)
            except OSError: pass
            raise


def parse_titledb(path):
    """{title ID: [[name, iconUrl], ...]} from a region file of titledb (nsuId -> entry). Read line by line, as the file is
    written (4-space indent, one key per line): a region file is about 90 MB, which json.load would hold as some 450 MB."""
    out = {}
    cur = {}
    def flush():
        tid, url = (cur.get('id') or '').upper(), cur.get('iconUrl')
        if re.fullmatch(r'[0-9A-F]{16}', tid) and url and url.startswith(('https://', 'http://')): out.setdefault(tid, []).append([cur.get('name') or '', url])
        cur.clear()
    key = re.compile(r'^ {8}"(id|iconUrl|name)": (null|"((?:[^"\\]|\\.)*)"),?\s*$')
    lines = 0
    with open(path, encoding='utf-8') as f:
        for line in f:
            lines += 1
            if line.startswith('    }'): flush(); continue
            m = key.match(line)
            if m and m.group(3) is not None:
                try: cur[m.group(1)] = json.loads('"%s"' % m.group(3))
                except ValueError: pass
    if not out and lines < 50:   # not written one key per line any more: read it whole
        with open(path, encoding='utf-8') as f: d = json.load(f)
        for e in d.values():
            if isinstance(e, dict):
                cur.update({k: e.get(k) for k in ('id', 'iconUrl', 'name')}); flush()
    return out


def index(cache, region):
    """the region's index, from the cache when it is recent, else built again (None if titledb cannot be reached)"""
    p = os.path.join(cache, 'index-%s.json' % region)
    try:
        if time.time() - os.path.getmtime(p) < INDEX_DAYS * 86400:
            with open(p, encoding='utf-8') as f: return json.load(f)
    except (OSError, ValueError): pass
    say('downloading the eShop title list (%s, about 90 MB, once a month)' % region)
    raw = os.path.join(cache, 'titledb-%s.json' % region)
    try:
        t0 = time.time()
        get(TITLEDB % region, raw, timeout=120)
        idx = parse_titledb(raw)
        if not idx: raise ValueError('no titles with an icon in it')
        tmp = p + '.part'
        with open(tmp, 'w', encoding='utf-8') as f: json.dump(idx, f, ensure_ascii=False, separators=(',', ':'))
        os.replace(tmp, p)
        say('%s: %d titles (%.0f s)' % (region, len(idx), time.time() - t0))
        return idx
    except Exception as e:
        say('could not get the title list %s (%s)' % (region, e))
        try:   # an old index is better than none
            with open(p, encoding='utf-8') as f: return json.load(f)
        except (OSError, ValueError): return None
    finally:
        try: os.unlink(raw)
        except OSError: pass


def pick(idx, tid, name):
    """the icon address for a game: by its title ID (the entry whose name is closest to the game's own: one title ID can
    be listed as the Switch and the Switch 2 Edition), else by its name (a game whose files carry another title ID than
    the eShop's)"""
    want = norm(name)
    c = idx.get(tid)
    if c:
        def rank(e):
            n = norm(e[0])
            return (n != want, 'switch2' in n and 'switch2' not in want, len(n))
        return sorted(c, key=rank)[0][1]
    if len(want) >= 4:
        for t, es in idx.items():
            for n, url in es:
                if norm(n) == want: return url
    return None


def jpeg_size(b):
    """(width, height) of a JPEG, or None"""
    if b[:2] != b'\xff\xd8': return None
    i = 2
    while i + 9 < len(b):
        if b[i] != 0xFF: i += 1; continue
        m = b[i + 1]
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7: i += 2; continue
        ln = int.from_bytes(b[i + 2:i + 4], 'big')
        if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            return int.from_bytes(b[i + 7:i + 9], 'big'), int.from_bytes(b[i + 5:i + 7], 'big')
        i += 2 + ln
    return None


def usable(b):
    s = jpeg_size(b)
    return bool(s) and s[0] == s[1] and s[0] >= MIN_SIDE


def cached(cache, tid):
    """the large icon of a game if the cache has one"""
    p = os.path.join(cache, tid.upper() + '.jpg')
    try:
        with open(p, 'rb') as f: b = f.read()
        return b if usable(b) else None
    except OSError: return None


def fetch(cache, games):
    """games: [(title ID, name)]. Fetches the icons the cache does not have; returns {title ID: 'cached' | 'new' | why not}"""
    os.makedirs(cache, exist_ok=True)
    res, todo = {}, []
    mp = os.path.join(cache, 'miss.json')
    try:
        with open(mp, encoding='utf-8') as f: miss = json.load(f)
    except (OSError, ValueError): miss = {}
    for tid, name in games:
        tid = tid.upper()
        if cached(cache, tid): res[tid] = 'cached'
        elif time.time() - miss.get(tid, 0) < MISS_DAYS * 86400: res[tid] = 'not on the eShop list (tried lately)'
        else: todo.append((tid, name))
    for region in REGIONS:
        if not todo: break
        idx = index(cache, region)
        if idx is None: continue
        left = []
        for tid, name in todo:
            url = pick(idx, tid, name)
            if not url: left.append((tid, name)); continue
            try:
                b = get(url, timeout=30)
                if not usable(b): res[tid] = 'eShop icon not usable (%s)' % (jpeg_size(b),); continue
                p = os.path.join(cache, tid + '.jpg')
                with open(p + '.part', 'wb') as f: f.write(b)
                os.replace(p + '.part', p)
                res[tid] = 'new'; miss.pop(tid, None)
            except Exception as e: res[tid] = 'download failed (%s)' % e   # not a miss: try again next time
        todo = left
    for tid, name in todo:
        res[tid] = 'not on the eShop list'; miss[tid] = time.time()
    try:
        with open(mp, 'w', encoding='utf-8') as f: json.dump(miss, f)
    except OSError: pass
    return res


def main():
    if len(sys.argv) < 3: sys.exit(__doc__)
    for f in (sys.stdout, sys.stderr):
        try: f.reconfigure(errors='replace')
        except Exception: pass
    games = []
    for a in sys.argv[2:]:
        tid, _, name = a.partition('=')
        if not re.fullmatch(r'[0-9A-Fa-f]{16}', tid): sys.exit('not a title ID: %s' % tid)
        games.append((tid, name))
    for tid, r in fetch(sys.argv[1], games).items(): say('%s %s' % (tid, r))


if __name__ == '__main__': main()
