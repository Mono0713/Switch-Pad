"""Keep a game's RomFS out of the app, so re-signing only sends the small app.

The shell reads Documents/romfs before <App>/romfs (dm/ios/Sources/main.m, romfs_locate) and keeps Documents/romfs out
of backups, so a single-game IPA can be installed without its romfs/ folder once that folder sits in the app's Documents.
Documents survives a reinstall, so after the first install the free account's weekly re-sign moves tens of MB, not GB.

  romfs_data.py info <ipa>                 one JSON line: whether the IPA can go this way, the RomFS id and size
  romfs_data.py lite <ipa> <out.ipa>       the IPA without its romfs/ folder (stored, plumesign re-packs it anyway)
  romfs_data.py push <ipa> [--udid UDID] [--order order.json]
                                           copy those folders into the installed app's Documents, unless they are there already
                                           (--order: also put the game order PadSwitch keeps as Documents/game-order.json)
  romfs_data.py space <ipa> [--udid UDID]  one JSON line: the iPad's free and total bytes, whether the app is installed, what
                                           of its data is there; also written to $NXN_STATUS_DIR/ipad-space.json
  romfs_data.py prune <ipa> [--udid UDID]  delete the data of games no longer in this library from the iPad (before
                                           the app is signed and installed, so the install has room)
  romfs_data.py sizes <ipa>...             one JSON line: {ipa: bytes it puts on the iPad (its data folders, a RomFS left in
                                           the NSP counted at its size, plus the rest of the package)}

What moves: romfs/ always (every shell reads Documents/romfs first). With a shell that says so in its Info.plist
(DMDataInDocuments), also msl/ (the shader libraries, often as big as the RomFS), and for a package of several games each
game's games/<tid>/romfs and msl as Documents/games/<tid>/...; an older shell reads a package of several only from inside.
Each moved folder gets an id, a hash of its entries' names, sizes and CRCs, kept in Documents/.romfs-id (JSON) and
written for a folder only after all its files are in: a copy cut short is redone, and only folders whose id changed
are sent again (a new shell's shaders, a game added to a package). A game taken out of a package has its folders removed.

A game package nxn_pack.py made with --romfs-source has no romfs/ either: its romfs.source.json names the NSP files and
lists every file, and push extracts that RomFS from the NSP when the iPad needs it (FromNsp), so the RomFS is on the
computer only once, in the NSP. A package nxn_merge.py made with --link holds no game data: its zip comment records, for each folder, the game's own
package it comes from, the entries' prefix there and the folder's id. Such a package is already the app to sign (info
says "linked"), and push reads each folder it has to send from that game package. Files go over several AFC
connections at once (NXN_PUSH_CONN, default 4): a Unity game's shaders are tens of thousands of small files, and one
connection spends most of its time waiting for the iPad's answer to each open, write and close.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import os
import re
import shutil
import sys
import time
import zipfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipad_layout  # noqa: E402
import pc_layout  # noqa: E402

MIN_BYTES = 64 << 20       # below this a separate copy saves nothing worth the extra step (ANIMAL WELL's RomFS is one placeholder)
MARK = '.romfs-id'


def read_link(z):
    """nxn_merge.py --link's record of where the game data is: {'games/<tid>/romfs': {ipa, size, mtime, prefix, id, bytes, files}}"""
    c = z.comment or b''
    try:
        if c.startswith(b'NXNLINK1'): return json.loads(c[8:].decode('utf-8')).get('parts', {})
        if c.startswith(b'NXNLINKZ'): return json.loads(zlib.decompress(base64.b64decode(c[8:])).decode('utf-8')).get('parts', {})
    except Exception as e: raise SystemExit('the data record of %s cannot be read: %s' % (z.filename, e))
    return None


def layout(z):
    """(app folder, Info.plist, the folders that move as [(path in the package, path under Documents)], their files, several games?)"""
    import plistlib
    names = z.namelist()
    app = next((m.group(1) for n in names for m in [re.match(r'(Payload/[^/]+\.app/)Info\.plist$', n)] if m), None)
    if not app: raise SystemExit('not an app package: no Payload/*.app/Info.plist')
    pl = plistlib.loads(z.read(app + 'Info.plist'))
    new = bool(pl.get('DMDataInDocuments'))
    tids = sorted({m.group(1) for n in names for m in [re.match(re.escape(app) + r'games/([0-9A-Fa-f]{16})/', n)] if m})
    if tids:
        parts = [(app + 'games/%s/%s/' % (t, d), 'games/%s/%s' % (t, d)) for t in tids for d in ('romfs', 'msl')] if new else []
    else:
        parts = [(app + 'romfs/', 'romfs')] + ([(app + 'msl/', 'msl')] if new else [])
    files = [i for i in z.infolist() if not i.is_dir() and any(i.filename.startswith(p) for p, _ in parts)]
    return app, pl, parts, files, bool(tids)


def data_id(files):
    h = hashlib.sha1()
    for i in sorted(files, key=lambda i: i.filename):
        h.update(('%s\0%d\0%08x\n' % (i.filename, i.file_size, i.CRC)).encode())
    return h.hexdigest()[:16]


def game_names(z, app):
    """{title ID: name} from each game's game.json in a package of several (nxn_merge.py writes them)"""
    out = {}
    for n in z.namelist():
        m = re.match(re.escape(app) + r'games/([0-9A-Fa-f]{16})/game\.json$', n)
        if not m: continue
        try: out[m.group(1).upper()] = json.loads(z.read(n).decode('utf-8')).get('name') or m.group(1)
        except Exception: out[m.group(1).upper()] = m.group(1)
    return out


def name_of(names, d):
    """'games/<tid>/romfs' → 'Kirby Star Allies 遊戲資料'; 'romfs' → '遊戲資料'"""
    m = re.match(r'games/([0-9A-Fa-f]{16})/(\w+)', d)
    what = {'romfs': '遊戲資料', 'msl': '著色器'}.get(d.rsplit('/', 1)[-1], d.rsplit('/', 1)[-1])
    if not m: return what
    return '%s %s' % (names.get(m.group(1).upper(), m.group(1)), what)


def dest_of(parts, name):
    for p, d in parts:
        if name.startswith(p): return d + '/' + name[len(p):]


def cmd_info(a):
    with zipfile.ZipFile(a.ipa) as z:
        link = read_link(z)
        if link is not None:
            pl = layout(z)[1]
            ids = hashlib.sha1(json.dumps(sorted((d, r['id']) for d, r in link.items())).encode()).hexdigest()[:16]
            print(json.dumps({'lite': True, 'linked': True, 'several': True, 'id': ids, 'bytes': sum(r['bytes'] for r in link.values()),
                              'files': sum(r['files'] for r in link.values()), 'parts': sorted(link), 'bundle': pl.get('CFBundleIdentifier', '')}))
            return
        app, pl, parts, files, several = layout(z)
        size = sum(i.file_size for i in files)
        print(json.dumps({'lite': size >= MIN_BYTES, 'several': several, 'id': data_id(files), 'bytes': size, 'files': len(files),
                          'parts': [d for _, d in parts], 'bundle': pl.get('CFBundleIdentifier', '')}))


def cmd_lite(a):
    with zipfile.ZipFile(a.ipa) as z: linked = read_link(z) is not None
    if linked:   # already without its data
        shutil.copyfile(a.ipa, a.out); print('lite package written: %s (a linked package, copied as it is)' % a.out); return
    with zipfile.ZipFile(a.ipa) as z, zipfile.ZipFile(a.out, 'w', zipfile.ZIP_STORED, allowZip64=True) as o:
        app, pl, parts, files, several = layout(z)
        if not parts: raise SystemExit('this shell reads a package of several games only from inside')
        for i in z.infolist():
            if any(i.filename.startswith(p) for p, _ in parts): continue
            info = zipfile.ZipInfo(i.filename, i.date_time)
            info.external_attr, info.create_system, info.compress_type = i.external_attr, i.create_system, zipfile.ZIP_STORED
            if i.is_dir(): o.writestr(info, b''); continue
            with z.open(i) as src, o.open(info, 'w', force_zip64=i.file_size > 0x7fffffff) as dst:
                while True:
                    b = src.read(1 << 20)
                    if not b: break
                    dst.write(b)
    print('lite package written: %s' % a.out)


class Sources:
    """The zip files the data comes from, opened once each"""
    def __init__(self): self.open = {}
    def close(self):
        for z in self.open.values(): z.close()
        self.open = {}
    def get(self, path):
        if path not in self.open: self.open[path] = zipfile.ZipFile(path)
        return self.open[path]


def linked_files(srcs, app, d, r):
    """[(zip, ZipInfo, path under Documents)] of one linked folder, read from the game package nxn_merge.py recorded
    (a FromNsp for a RomFS that package left in the NSP)"""
    p = r['ipa'] = pc_layout.moved(r['ipa'])   # a game folder renamed or its package moved into 轉檔結果/ since the merge
    if not os.path.isfile(p):
        raise SystemExit('找不到遊戲包 %s（遊戲庫裡 %s 的資料在那裡）：請再按一次「轉檔」' % (p, d))
    z = srcs.get(p)
    if r.get('source'): return FromNsp(z, app, d, r)
    pre = r.get('prefix') or ''
    out = [(z, i, d + '/' + i.filename[len(pre):]) for i in z.infolist() if pre and i.filename.startswith(pre) and not i.is_dir()]
    h = hashlib.sha1()
    for n, size, crc in sorted((app + dst, i.file_size, i.CRC) for _, i, dst in out): h.update(('%s\0%d\0%08x\n' % (n, size, crc)).encode())
    got = h.hexdigest()[:16]
    if got != r['id']:
        raise SystemExit('遊戲包 %s 在合成遊戲庫之後改過了（%s 對不上）：請再按一次「轉檔」' % (os.path.basename(p), d))
    return out


class Mismatch(Exception):
    """a file extracted from the NSP that is not the one the game package listed (raised inside a send task, where a
    SystemExit would stop the event loop instead of the other tasks)"""


class DiskFile:
    """a file of an extracted RomFS, standing in for a ZipInfo in a send job"""
    def __init__(self, path, size, crc): self.path, self.file_size, self.crc = path, size, crc


class Disk:
    """standing in for a ZipFile in a send job: opens the extracted file"""
    @staticmethod
    def open(i): return open(i.path, 'rb')


DISK = Disk()


class FromNsp:
    """A linked RomFS that nxn_pack.py --romfs-source left in the NSP: its game package holds only romfs.source.json (the
    NSP files, the nx_extract and prod.keys that extracted it, and every file's name, size and CRC). It is extracted again
    when its turn to be sent comes, each file is checked against the list while it is sent, and the extraction is removed
    once the folder is on the iPad. Nothing is extracted when the iPad already has this RomFS (its id)."""
    def __init__(self, z, app, d, r):
        self.d = d
        try: self.rec = json.loads(z.read(r['source']).decode('utf-8'))
        except Exception as e: raise SystemExit('遊戲包 %s 裡的 RomFS 記錄讀不到（%s）：請再按一次「轉檔」' % (os.path.basename(z.filename), e))
        rec = self.rec
        h = hashlib.sha1()
        base = app + d + '/'
        for n, size, crc in sorted((base + f[0], f[1], f[2]) for f in rec['list']): h.update(('%s\0%d\0%08x\n' % (n, size, crc)).encode())
        if h.hexdigest()[:16] != r['id']:
            raise SystemExit('遊戲包 %s 在合成遊戲庫之後改過了（%s 對不上）：請再按一次「轉檔」' % (os.path.basename(z.filename), d))
        self.nsps = [x for x in (rec['base'], rec.get('update')) if x]
        for x in self.nsps:
            x['path'] = pc_layout.moved(x['path'])   # the NSP moved into 原始檔/ (pc_layout.py) since the pack
            if not os.path.isfile(x['path']):
                raise SystemExit('找不到 %s（%s 的 RomFS 要從它解出來）：遊戲檔搬走了的話，請再按一次「轉檔」' % (x['path'], d))
            if os.path.getsize(x['path']) != x['size']:
                raise SystemExit('%s 跟打包時不一樣了（大小不同）：請再按一次「轉檔」' % x['path'])
        self.file_size = rec['bytes']
        self.count = rec['files']
        self.only = None      # the files to send (a folder the iPad has an older copy of), or None for all
        self.status, self.name = None, ''   # push's Status and the game's name, for the progress PadSwitch shows
        self.tmp = None
        self.jobs = None

    def restrict(self, only):
        self.only = set(only)
        sel = [f for f in self.rec['list'] if self.d + '/' + f[0] in self.only]
        self.count, self.file_size = len(sel), sum(f[1] for f in sel)

    def get(self):
        """the send jobs, extracting the RomFS first"""
        if self.jobs is not None: return self.jobs
        if self.only is not None and not self.only: self.jobs = []; return self.jobs   # nothing of it changed: nothing to extract
        rec = self.rec
        nx = os.environ.get('NXN_NX') or rec['nx']
        keys = os.environ.get('NXN_KEYS') or rec['keys']
        for what, p in (('nx_extract', nx), ('prod.keys', keys)):
            if not os.path.isfile(p): raise SystemExit('找不到 %s（%s），解不出 %s 的 RomFS：請在 PadSwitch 按「安裝」後再試' % (what, p, self.d))
        where = os.path.dirname(rec['base']['path'])
        self.tmp = os.path.join(where, '_romfs_push_%s' % rec.get('tid', 'game'))
        shutil.rmtree(self.tmp, ignore_errors=True)
        free = shutil.disk_usage(where).free
        if free < rec['bytes'] + (1 << 30):
            raise SystemExit('電腦空間不夠從 NSP 解出 %s 的 RomFS：要 %.1f GB，%s 只剩 %.1f GB' % (self.d, rec['bytes'] / 2**30 + 1, where, free / 2**30))
        print('從 NSP 解出 %s 的 RomFS（%.1f GB，%d 個檔，約一兩分鐘）' % (self.name or self.d, rec['bytes'] / 2**30, rec['files']), flush=True)
        if self.status: self.status.extracting(self.name or self.d, rec['bytes'])
        t0 = time.time()
        cmd = ([sys.executable] if nx.endswith('.py') else []) + [nx, keys, rec['base']['path'], rec['update']['path'] if rec.get('update') else '-', self.tmp] + (['--allow-damaged'] if rec.get('allow_damaged') else [])
        import subprocess
        r = subprocess.run(cmd, capture_output=True, text=True, errors='replace')
        rom = os.path.join(self.tmp, 'RomFS')
        if r.returncode or not os.path.isdir(rom):
            tail = ' / '.join((r.stdout + r.stderr).strip().splitlines()[-3:])
            self.cleanup()
            raise SystemExit('從 NSP 解出 %s 的 RomFS 失敗（結束碼 %d）：%s' % (self.d, r.returncode, tail))
        jobs = []
        for f in rec['list']:
            p = os.path.join(rom, *f[0].split('/'))
            try: size = os.path.getsize(p)
            except OSError: size = -1
            if size != f[1]:
                self.cleanup()
                raise SystemExit('從 NSP 解出的 %s 跟打包時不一樣（%s %s）：遊戲檔換過了的話，請再按一次「轉檔」'
                                 % (self.d, f[0], '不見了' if size < 0 else '大小不同'))
            if self.only is None or self.d + '/' + f[0] in self.only: jobs.append((DISK, DiskFile(p, f[1], f[2]), self.d + '/' + f[0]))
        print('解好了（%.0f 秒）' % (time.time() - t0), flush=True)
        if self.status: self.status.extracted(rec['bytes'])
        self.jobs = jobs
        return jobs

    def pending(self, done):
        return [j for j in self.jobs if j[2] not in done] if self.jobs is not None else None

    def cleanup(self):
        if self.tmp: shutil.rmtree(self.tmp, ignore_errors=True); self.tmp = None


# Documents/.romfs-files/<folder>.json: every file of a folder that is on the iPad whole, with its size and CRC. A folder
# whose id changed (a game update, a repack that changed some shaders, Overcooked's recorded shaders added) then only gets
# the files that differ, and loses the ones that are gone, instead of being removed and sent again whole. Before a folder
# is touched its list drops every file about to be written or removed, so a copy cut short sends those again next time;
# the full list is written once the folder is complete. No list (an older PadSwitch sent it, or --force): sent whole.
LIST_DIR = '.romfs-files'


def listing_of(x):
    """{path under Documents: (size, CRC)} of a folder about to be sent, without extracting anything"""
    if isinstance(x, FromNsp): return {x.d + '/' + f[0]: (f[1], f[2]) for f in x.rec['list']}
    return {dst: (i.file_size, i.CRC) for _, i, dst in x}


def list_path(L, d): return '%s/%s.json' % (L.sys(LIST_DIR), d.replace('/', '~'))


async def read_list(afc, L, d):
    p = list_path(L, d)
    try:
        if not await afc.exists(p): return None
        return {k: tuple(v) for k, v in json.loads((await afc.get_file_contents(p)).decode('utf-8'))['files'].items()}
    except Exception: return None


async def write_list(afc, L, d, files):
    await afc.makedirs(L.sys(LIST_DIR))
    await afc.set_file_contents(list_path(L, d), json.dumps({'files': {k: list(v) for k, v in sorted(files.items())}},
                                                               separators=(',', ':')).encode('utf-8'))


async def drop_list(afc, L, d):
    try:
        if await afc.exists(list_path(L, d)): await afc.rm(list_path(L, d), force=True)
    except Exception: pass


def jobs_left(x, done):
    """(files, bytes) of a folder's send jobs not yet in done"""
    js = x.pending(done) if isinstance(x, FromNsp) else [j for j in x if j[2] not in done]
    if js is None: return x.count, x.file_size
    return len(js), sum(j[1].file_size for j in js)


def now_iso():
    import datetime
    return datetime.datetime.now().astimezone().isoformat(timespec='seconds')


class Status:
    """push-<pid>.json in NXN_STATUS_DIR (nxn.ps1 sets it to work/status): PadSwitch's 背景工作 card shows the transfer's
    percentage, GB and time left from it. Written at most once a second; a failure to write is ignored."""
    def __init__(self, ipa):
        self.dir = os.environ.get('NXN_STATUS_DIR', '')
        self.d = {'kind': 'push', 'pid': os.getpid(), 'job': os.environ.get('NXN_JOB', ''), 'ipa': os.path.basename(ipa), 'state': 'running',
                  'phase': '連接 iPad', 'game': '', 'sent': 0, 'total': 0, 'files': 0, 'removed': [], 'items': [],
                  'started': now_iso(), 'ended': '', 'message': ''}
        self.t0, self.sent0, self.last = time.time(), 0, 0.0
        self.paused, self.pause_at = 0.0, None    # time spent extracting a RomFS from its NSP: not part of the copy rate
        self.extract_left = 0                       # bytes of RomFS still to extract before they can be sent
        self.write(True)

    def begin(self, total, nfiles, items=(), extract=0):
        """items: [(folder, game name, bytes)] in the order they go"""
        self.d.update(total=total, files=nfiles, sent=0, phase='傳送中',
                      items=[{'dir': d, 'name': n, 'bytes': b, 'sent': 0, 'state': 'queued'} for d, n, b in items])
        self.t0, self.sent0, self.paused = time.time(), 0, 0.0
        self.extract_left = extract
        self.write(True)

    def item(self, d, state):
        for it in self.d['items']:
            if it['dir'] == d:
                it['state'] = state
                if state == 'done': it['sent'] = it['bytes']
                if state == 'running': self.d['game'] = it['name']
        self.write(True)

    def item_sent(self, d, n):
        for it in self.d['items']:
            if it['dir'] == d: it['sent'] = max(0, it['sent'] + n)

    def extracting(self, name, nbytes):
        self.pause_at = time.time()
        self.d['phase'] = '從 NSP 解出 %s 的遊戲資料' % name
        self.d['game'] = name
        self.estimate()
        self.write(True)

    def extracted(self, nbytes):
        if self.pause_at:
            took = time.time() - self.pause_at
            self.paused += took
            self.pause_at = None
            if took > 2 and nbytes: self.d['xrate'] = int(nbytes / took)
        self.extract_left = max(0, self.extract_left - nbytes)
        self.d['phase'] = '傳送中'
        self.write(True)

    def estimate(self):
        """time left: what is still to copy at the copy rate seen so far, plus the RomFS still to extract from NSPs"""
        el = time.time() - self.t0 - self.paused - ((time.time() - self.pause_at) if self.pause_at else 0)
        sent = self.d['sent']
        if el > 3 and sent > self.sent0:
            rate = (sent - self.sent0) / el
            self.d['rate'] = int(rate)
            left = max(self.d['total'] - sent, 0) / max(rate, 1) + self.extract_left / max(self.d.get('xrate') or (150 << 20), 1)
            if self.pause_at: left = max(0, left - (time.time() - self.pause_at))   # the extraction under way is partly done
            self.d['eta'] = int(left)

    def progress(self, sent):
        self.d['sent'] = sent
        self.d['phase'] = '傳送中'
        self.estimate()
        self.write()

    def end(self, ok, msg=''):
        self.d.update(state='done' if ok else 'failed', ended=now_iso(), message=msg)
        if ok:
            self.d['sent'] = self.d['total']
            for it in self.d['items']: it['state'], it['sent'] = 'done', it['bytes']
        self.d.pop('eta', None)
        self.write(True)

    def write(self, now=False):
        if not self.dir or (not now and time.time() - self.last < 1): return
        self.last = time.time()
        for _ in range(5 if now else 1):   # PadSwitch reading it at that moment keeps Windows from replacing it
            try:
                os.makedirs(self.dir, exist_ok=True)
                f = os.path.join(self.dir, 'push-%d.json' % os.getpid())
                with open(f + '.tmp', 'w', encoding='utf-8') as o: json.dump(self.d, o, ensure_ascii=False)
                os.replace(f + '.tmp', f)
                return
            except OSError: time.sleep(0.2)


async def push(a):
    opened = []
    a.status = Status(a.ipa)
    try:
        await _push(a, opened)
        a.status.end(True)
    except BaseException as e:
        a.status.end(False, str(e) or type(e).__name__)
        raise
    finally:
        for x in opened: x.close()   # Windows keeps an open file from being replaced or removed


async def _push(a, opened):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.house_arrest import HouseArrestService

    z = zipfile.ZipFile(a.ipa)
    opened.append(z)
    link = read_link(z)
    app, pl, parts, files, several = layout(z)
    orig = pl.get('CFBundleIdentifier', '')
    names = game_names(z, app)
    srcs = Sources()
    opened.append(srcs)
    # each folder that moves (romfs, msl, or a game's in a package) has its own id, so a change sends only what changed:
    # a new shell's shaders without the game files, or a game added to a package without the games already there
    if link is not None:
        want = {d: r['id'] for d, r in link.items()}
        jobs_of = lambda d: linked_files(srcs, app, d, link[d])
    else:
        by_part = {d: [i for i in files if i.filename.startswith(p)] for p, d in parts}
        want = {d: data_id(fs) for d, fs in by_part.items()}
        jobs_of = lambda d: [(z, i, dest_of(parts, i.filename)) for i in by_part[d]]

    ld = await create_using_usbmux(serial=a.udid or None)
    async with ld:
        # plumesign signs the app as <id>.<team ID>, so look for the installed app by its prefix
        async with InstallationProxyService(lockdown=ld) as ip:
            apps = await ip.get_apps(application_type='User')
        ids = [b for b in apps if b == orig or b.startswith(orig + '.')]
        if not ids: raise SystemExit('the app (%s) is not on the iPad' % orig)
        bid = ids[0]
        print('app on the iPad: %s' % bid)
        async with await HouseArrestService.create(lockdown=ld, bundle_id=bid, documents_only=True) as afc:
            # the game library's Documents by game name (ipad_layout.py): data paths are kept as before in the records
            # (games/<title ID>/romfs), L.key() says where each is on this iPad now
            names = ipad_layout.game_names(a.ipa) if several else {}
            if several and ipad_layout.shell_layout(a.ipa) < 2:   # an older shell (退回上一版) only knows the old places
                for n in await ipad_layout.to_old(afc): print(n)
            L = await ipad_layout.IPad.load(afc, names)
            for t in names: L.folder(t)
            await L.save_folders()
            base = L.base
            mark = L.sys(MARK)
            have = {}
            if await afc.exists(mark):
                try:
                    raw = (await afc.get_file_contents(mark)).decode().strip()
                    have = json.loads(raw) if raw.startswith('{') else {}
                except Exception: have = {}
            todo = [d for d in want if a.force or have.get(d) != want[d]]
            # a game taken out of a package: its folders go too (they would only take space)
            # 先刪：拿掉的遊戲先清掉，騰出 iPad 空間再傳新的（同步通常已在簽章前用 prune 刪過，這裡是保險）
            if any(d not in want and d.startswith('games/') for d in have):
                a.status.d['phase'] = '先刪掉拿掉的遊戲，騰出 iPad 空間'; a.status.write(True)
            gone = await remove_gone(afc, L, have, want, names, a.status)
            if not todo:
                if gone: await afc.set_file_contents(mark, json.dumps(want).encode())
                await list_missing(afc, L, want, jobs_of)
                await put_order(afc, L, a)
                await note_space(afc, a, bid, {d: v for d, v in have.items() if d not in gone})
                print('game files already on the iPad')
                return
            send = {d: jobs_of(d) for d in todo}   # (a linked folder whose game package changed stops here, before anything is removed)
            lists = {d: listing_of(send[d]) for d in todo}
            # a folder the iPad has an older copy of (with its file list): only the files that differ
            plan, skipped = {}, 0
            for d in todo:
                old = None if a.force else await read_list(afc, L, d)
                if old is None: plan[d] = None; continue
                changed = {k for k, v in lists[d].items() if old.get(k) != v}
                plan[d] = (old, changed, [k for k in old if k not in lists[d]])
                skipped += len(lists[d]) - len(changed)
                if isinstance(send[d], FromNsp): send[d].restrict(changed)
                else: send[d] = [j for j in send[d] if j[2] in changed]
            total = sum(jobs_left(x, ())[1] for x in send.values())
            nfiles = sum(jobs_left(x, ())[0] for x in send.values())
            for d, x in send.items():
                if isinstance(x, FromNsp): x.status, x.name = a.status, name_of(names, d).rsplit(' ', 1)[0]
            a.status.begin(total, nfiles, [(d, name_of(names, d), jobs_left(send[d], ())[1]) for d in todo],
                           extract=sum(x.file_size for x in send.values() if isinstance(x, FromNsp) and x.jobs is None))
            print('copying to the iPad: %s (%d files, %d MB%s)' % (', '.join(todo), nfiles, total >> 20,
                  '; %d files already there unchanged' % skipped if skipped else ''))
            # forget the parts about to be replaced first, so a copy cut short is redone next time
            keep = {d: v for d, v in have.items() if d in want and d not in todo}
            await afc.set_file_contents(mark, json.dumps(keep).encode())
            for d in todo:
                if plan[d] is None:
                    await drop_list(afc, L, d)
                    if await afc.exists(L.key(d)): await afc.rm(L.key(d), force=True)
                    continue
                old, changed, removed = plan[d]
                await write_list(afc, L, d, {k: v for k, v in old.items() if k not in changed and k in lists[d]})
                for k in removed:
                    if await afc.exists(L.key(k)): await afc.rm(L.key(k), force=True)
                if removed: print('%s: removed %d files the new version no longer has' % (d, len(removed)))

            # 先刪後傳：拿掉的遊戲和要整個換掉的資料夾上面已經刪了，這時 iPad 剩的空間不夠就先停，不要傳到一半才失敗
            try: free = int((await afc.get_device_info()).get('FSFreeBytes', 0))
            except Exception: free = 0   # 問不到就照常傳
            # 只換部分檔的資料夾：被覆蓋的舊檔寫入時才放掉空間，所以先把它們算回去
            reuse = sum((old.get(k) or (0,))[0] for d in todo if plan[d] for old, changed, _ in [plan[d]] for k in changed)
            need = total - reuse
            if free and need + (1 << 30) > free:
                raise SystemExit('[x] iPad 空間不夠：這次要傳 %.1f GB 遊戲資料（%s），iPad 只剩 %.1f GB（已先刪掉移除的遊戲）。'
                                 '請在 iPad 上刪掉用不到的 App 或照片，或在 PadSwitch 把暫時不玩的遊戲按「移除」，再按一次「同步」。'
                                 % ((need + (1 << 30)) / 2**30, ', '.join(todo), free / 2**30))

            # The copy survives a dropped connection (2026-11-15: Smash's 18 GB stopped at 14% with WinError 64 and the game
            # then crashed reading past the end of a half-written data.arc): reconnect and carry on, skipping the files that
            # were already written whole. A file cut short is written again from its start.
            done = set()
            state = {'sent': 0, 'shown': -1}
            t0 = time.time()
            tries = max(1, int(os.environ.get('NXN_PUSH_TRIES', '6') or 6))
            nconn = 1
            try:
                for attempt in range(1, tries + 1):
                    try:
                        nconn = await send_round(ld if attempt == 1 else None, a, bid, L, mark, todo, send, keep, want, done, state, total, lists)
                        break
                    except Exception as e:
                        if attempt == tries or not is_disconnect(e): raise
                        left = sum(jobs_left(x, done)[0] for x in send.values())
                        a.status.d['phase'] = '連線中斷，重新連線中'; a.status.write(True)
                        print('連線中斷（%s），%d 秒後重新連線再傳，已完成的檔案不重傳（第 %d / %d 次重試，還剩 %d 個檔）'
                              % (type(e).__name__, 5 * attempt, attempt, tries - 1, left), flush=True)
                        state['sent'] = total - sum(jobs_left(x, done)[1] for x in send.values())
                        await asyncio.sleep(5 * attempt)
            finally:
                for x in send.values():
                    if isinstance(x, FromNsp): x.cleanup()

            await list_missing(afc, L, want, jobs_of, skip=todo)
            await put_order(afc, L, a)
            await note_space(afc, a, bid)
            el = max(time.time() - t0, 0.001)
            print('game files in place (%d files, %d MB in %.0f s over %d connections, %.1f MB/s)' % (nfiles, total >> 20, el, nconn, total / el / 2**20))


ORDER_FILE = 'game-order.json'


async def remove_gone(afc, L, have, want, names, status=None):
    """delete from the iPad the data folders of games no longer in the library (they only take space); returns them"""
    gone = [d for d in have if d not in want and d.startswith('games/')]
    for d in gone:
        if await afc.exists(L.key(d)): await afc.rm(L.key(d), force=True)
        await drop_list(afc, L, d)
        if status is not None: status.d['removed'].append(d)
        print('removed %s (no longer in this package)' % d)
    if gone: print('已刪掉拿掉的遊戲：%s' % '、'.join(sorted({name_of(names, d).rsplit(' ', 1)[0] for d in gone})))
    return gone


def wanted_folders(z):
    """the data folders (games/<tid>/romfs ...) this library package wants on the iPad, without reading any game data"""
    link = read_link(z)
    if link is not None: return set(link)
    return {d for _, d in layout(z)[2]}


async def installed_app(ld, orig, sizes=False):
    """(bundle id, the app's record) of the installed app plumesign signed as <id>.<team ID>, or (None, None)"""
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    async with InstallationProxyService(lockdown=ld) as ip:
        apps = None
        if sizes:
            try: apps = await ip.get_apps(application_type='User', calculate_sizes=True)
            except Exception: apps = None
        if apps is None: apps = await ip.get_apps(application_type='User')
    ids = [b for b in apps if b == orig or b.startswith(orig + '.')]
    return (ids[0], apps[ids[0]]) if ids else (None, None)


async def read_mark(afc, L):
    try:
        raw = (await afc.get_file_contents(L.sys(MARK))).decode().strip()
        return json.loads(raw) if raw.startswith('{') else {}
    except Exception: return {}


async def cmd_prune(a):
    """Before the app is signed and installed: delete the data of games taken out of the library, so the iPad has the
    room the install needs (2026-11-20: 2.4 GB left, the app did not fit while a removed game's data still sat there)."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    with zipfile.ZipFile(a.ipa) as z:
        app, pl, parts, files, several = layout(z)
        orig = pl.get('CFBundleIdentifier', '')
        want = wanted_folders(z)
        names_all = game_names(z, app)
    ld = await create_using_usbmux(serial=a.udid or None)
    async with ld:
        bid, _ = await installed_app(ld, orig)
        if not bid: print('App 還沒裝在 iPad 上，沒有要先刪的'); return
        async with await HouseArrestService.create(lockdown=ld, bundle_id=bid, documents_only=True) as afc:
            L = await ipad_layout.IPad.load(afc, ipad_layout.game_names(a.ipa) if several else {})
            have = await read_mark(afc, L)
            try: free0 = int((await afc.get_device_info()).get('FSFreeBytes', 0))
            except Exception: free0 = 0
            gone = await remove_gone(afc, L, have, want, names_all)
            if not gone:
                print('iPad 上沒有已拿掉的遊戲資料')
                await note_space(afc, a, bid, have)
                return
            have = {d: v for d, v in have.items() if d not in gone}
            await afc.set_file_contents(L.sys(MARK), json.dumps(have).encode())
            d = await note_space(afc, a, bid, have) or {}
            if free0 and d.get('free'): print('騰出 %.1f GB，iPad 現在剩 %.1f GB' % ((d['free'] - free0) / 2**30, d['free'] / 2**30))


async def put_order(afc, L, a):
    """--order: PadSwitch's game order (a JSON list of title IDs) as Documents/game-order.json; the game picker shows the
    games in that order (the ones it does not list after them, by name). Best effort."""
    if not getattr(a, 'order', ''): return
    try:
        with open(a.order, encoding='utf-8-sig') as f: order = [str(t).upper() for t in json.load(f) if re.fullmatch(r'[0-9A-Fa-f]{16}', str(t))]
        where = L.sys(ORDER_FILE)   # 系統/game-order.json in the iPad's new layout (ipad_layout.py)
        await afc.set_file_contents(where, json.dumps(order).encode())
        print('遊戲順序放好了（%d 款，iPad 上照 PadSwitch 的順序排）' % len(order))
    except Exception as e: print('遊戲順序沒放進 iPad（%s）' % e)


def write_space(d):
    sd = os.environ.get('NXN_STATUS_DIR', '')
    if not sd: return
    try:
        os.makedirs(sd, exist_ok=True)
        f = os.path.join(sd, 'ipad-space.json')
        # push/prune only know the free space: keep what space read before (each data folder's size on the iPad, the
        # app's size), dropping the folders that are no longer there, so PadSwitch can still tell what is already on it
        if 'data' not in d and d.get('installed'):
            try:
                with open(f, encoding='utf-8') as i: old = json.load(i)
                if old.get('bundle') == d.get('bundle'):
                    have = d.get('have')
                    if isinstance(old.get('data'), dict): d['data'] = {k: v for k, v in old['data'].items() if have is None or k in have}
                    if old.get('app'): d['app'] = old['app']
                    if old.get('device') and not d.get('device'): d['device'] = old['device']
            except (OSError, ValueError): pass
        with open(f + '.tmp', 'w', encoding='utf-8') as o: json.dump(d, o, ensure_ascii=False)
        os.replace(f + '.tmp', f)
    except OSError: pass


async def note_space(afc, a, bid, have=None):
    """the iPad's free and total space, for PadSwitch's space bar (ipad-space.json); best effort"""
    try:
        info = await afc.get_device_info()
        d = {'free': int(info.get('FSFreeBytes', 0)), 'total': int(info.get('FSTotalBytes', 0)), 'bundle': bid, 'installed': True,
             'ipa': os.path.basename(a.ipa), 'at': now_iso()}
        if have is not None: d['have'] = have
        write_space(d)
        return d
    except Exception: return None


async def cmd_space(a):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.house_arrest import HouseArrestService
    with zipfile.ZipFile(a.ipa) as z: orig = layout(z)[1].get('CFBundleIdentifier', '')
    ld = await create_using_usbmux(serial=a.udid or None)
    async with ld:
        try: name = await ld.get_value(key='DeviceName')
        except Exception: name = ''
        bid, rec = await installed_app(ld, orig, sizes=True)
        ids = [bid] if bid else []
        if not ids:
            d = {'installed': False, 'bundle': orig, 'device': name, 'at': now_iso()}
            try:
                du = await ld.get_value(domain='com.apple.disk_usage')
                d.update(free=int(du.get('AmountDataAvailable') or du.get('TotalDataAvailable') or 0), total=int(du.get('TotalDataCapacity') or du.get('TotalDiskCapacity') or 0))
            except Exception: pass
            write_space(d); print(json.dumps(d, ensure_ascii=False)); return
        async with await HouseArrestService.create(lockdown=ld, bundle_id=ids[0], documents_only=True) as afc:
            L = await ipad_layout.IPad.load(afc)
            have = {}
            try:
                raw = (await afc.get_file_contents(L.sys(MARK))).decode().strip()
                have = json.loads(raw) if raw.startswith('{') else {}
            except Exception: pass
            # each data folder's size on the iPad, from the file list push wrote for it (no walk over the iPad)
            onpad = {}
            for k in have:
                lst = await read_list(afc, L, k)
                if lst is not None: onpad[k] = sum(v[0] for v in lst.values())
            d = await note_space(afc, a, ids[0], have) or {'installed': True, 'bundle': ids[0]}
            d['device'] = name
            d['data'] = onpad
            try:
                if rec: d['app'] = int(rec.get('StaticDiskUsage') or 0) + int(rec.get('DynamicDiskUsage') or 0)
            except Exception: pass
            write_space(d)
            print(json.dumps(d, ensure_ascii=False))


def package_bytes(path):
    """what one package puts on the iPad: every entry's size (its data folders included), with a RomFS left in the NSP
    (romfs.source.json) counted at the size it extracts to"""
    with zipfile.ZipFile(path) as z:
        n = 0
        for i in z.infolist():
            if i.is_dir(): continue
            n += i.file_size
            if i.filename.endswith('/' + 'romfs.source.json') and i.filename.count('/') <= 3:
                try: n += int(json.loads(z.read(i).decode('utf-8')).get('bytes') or 0)
                except Exception: pass
        return n


def cmd_sizes(a):
    out = {}
    for p in a.ipa:
        try: out[p] = package_bytes(p)
        except Exception: out[p] = -1
    print(json.dumps(out, ensure_ascii=False))


async def list_missing(afc, L, want, jobs_of, skip=()):
    """Write the file list of each folder the iPad has whole but no list for (sent by an older PadSwitch), so its next
    change sends only what changed. Best effort: a folder whose source cannot be read now is left without one."""
    for d in want:
        if d in skip: continue
        try:
            if await afc.exists(list_path(L, d)): continue
            await write_list(afc, L, d, listing_of(jobs_of(d)))
        except (Exception, SystemExit): pass


def is_disconnect(e):
    """A dropped link to the iPad (USB unplugged for a moment, the iPad locked, usbmuxd restarted), worth reconnecting for."""
    names = {type(x).__name__ for x in (e, e.__cause__, e.__context__) if x is not None}
    return bool(names & {'ConnectionTerminatedError', 'ConnectionResetError', 'ConnectionAbortedError', 'BrokenPipeError',
                         'ConnectionFailedError', 'ConnectionFailedToUsbmuxdError', 'NoDeviceConnectedError',
                         'DeviceNotFoundError', 'IncompleteReadError', 'TimeoutError', 'OSError'})


async def send_round(ld, a, bid, L, mark, todo, send, keep, want, done, state, total, lists):
    """One pass over the files not yet in `done`, over fresh connections when `ld` is None (after a drop). Returns the number
    of connections used."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    own = ld is None
    if own:
        for _ in range(12):   # the iPad may take a while to come back (re-plugged, unlocked)
            try: ld = await create_using_usbmux(serial=a.udid or None); break
            except Exception as e:
                if not is_disconnect(e): raise
                await asyncio.sleep(5)
        else:
            ld = await create_using_usbmux(serial=a.udid or None)
    try:
        # extra connections to the app's Documents: AFC answers one request at a time per connection
        want_conn = max(1, min(16, int(os.environ.get('NXN_PUSH_CONN', '4') or 4)))
        conns = []
        for _ in range(want_conn):
            try: conns.append(await (await HouseArrestService.create(lockdown=ld, bundle_id=bid, documents_only=True)).__aenter__())
            except Exception as e:
                if not conns: raise
                print('note: only %d connection(s) to the iPad (%s)' % (len(conns), e)); break
        afc = conns[0]
        try:
            for d in todo:
                if keep.get(d) == want[d]: continue
                a.status.item(d, 'running')
                state['cur'] = d
                js = [j for j in (send[d].get() if isinstance(send[d], FromNsp) else send[d]) if j[2] not in done]
                for dd in sorted({L.key(dst).rsplit('/', 1)[0] for _, _, dst in js}):
                    await afc.makedirs(dd)
                queue = asyncio.Queue()
                for job in sorted(js, key=lambda j: -j[1].file_size): queue.put_nowait(job)   # big files first, so none is left alone at the end

                async def worker(c):
                    while True:
                        try: zz, i, dst = queue.get_nowait()
                        except asyncio.QueueEmpty: return
                        h = await c.fopen(L.key(dst), 'w')
                        got = 0
                        crc = 0
                        check = isinstance(i, DiskFile)   # a file extracted from the NSP: its CRC must be the one the list has
                        try:
                            with zz.open(i) as src:
                                while True:
                                    b = src.read(4 << 20) if i.file_size < (8 << 20) else await asyncio.to_thread(src.read, 4 << 20)
                                    if not b: break
                                    if check: crc = zlib.crc32(b, crc)
                                    await c.fwrite(h, b)
                                    got += len(b)
                                    state['sent'] += len(b)
                                    a.status.item_sent(d, len(b))
                                    a.status.progress(state['sent'])
                                    pct = state['sent'] * 100 // max(total, 1)
                                    if pct != state['shown'] and (pct % 2 == 0 or pct == 100):
                                        state['shown'] = pct
                                        print('傳送遊戲資料 %d%%（%d / %d MB）' % (pct, state['sent'] >> 20, total >> 20), flush=True)
                        except BaseException:
                            state['sent'] -= got   # counted again when it is sent again
                            a.status.item_sent(d, -got)
                            raise
                        await c.fclose(h)
                        if check and crc != i.crc:
                            raise Mismatch('從 NSP 解出的 %s 內容跟打包時不一樣：遊戲檔換過了的話，請再按一次「轉檔」' % dst)
                        done.add(dst)
                tasks = [asyncio.ensure_future(worker(c)) for c in conns]
                try: await asyncio.gather(*tasks)
                except BaseException:
                    for t in tasks: t.cancel()   # one connection dropped: stop the others before reconnecting
                    await asyncio.gather(*tasks, return_exceptions=True)
                    raise
                await write_list(afc, L, d, lists[d])
                a.status.item(d, 'done')
                keep[d] = want[d]
                await afc.set_file_contents(mark, json.dumps(keep).encode())
                if isinstance(send[d], FromNsp): send[d].cleanup()   # on the iPad now: the extraction can go
            return len(conns)
        finally:
            for c in conns:
                try: await c.__aexit__(None, None, None)
                except Exception: pass
    finally:
        if own:
            try: await ld.close()
            except Exception: pass


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('info'); p.add_argument('ipa')
    p = sub.add_parser('lite'); p.add_argument('ipa'); p.add_argument('out')
    p = sub.add_parser('push'); p.add_argument('ipa'); p.add_argument('--udid', default=''); p.add_argument('--force', action='store_true')
    p.add_argument('--order', default='')
    p = sub.add_parser('space'); p.add_argument('ipa'); p.add_argument('--udid', default='')
    p = sub.add_parser('sizes'); p.add_argument('ipa', nargs='+')
    p = sub.add_parser('prune'); p.add_argument('ipa'); p.add_argument('--udid', default='')
    a = ap.parse_args()
    if a.cmd == 'info': cmd_info(a)
    elif a.cmd == 'lite': cmd_lite(a)
    elif a.cmd == 'sizes': cmd_sizes(a)
    else:
        try: import pymobiledevice3  # noqa: F401
        except ImportError: raise SystemExit('pymobiledevice3 is not installed')
        if a.cmd == 'space': asyncio.run(cmd_space(a)); return
        if a.cmd == 'prune': asyncio.run(cmd_prune(a)); return
        try: asyncio.run(push(a))
        except Mismatch as e: raise SystemExit(str(e))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    main()
