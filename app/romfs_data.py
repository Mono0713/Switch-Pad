"""Keep a game's RomFS out of the app, so re-signing only sends the small app.

The shell reads Documents/romfs before <App>/romfs (dm/ios/Sources/main.m, romfs_locate) and keeps Documents/romfs out
of backups, so a single-game IPA can be installed without its romfs/ folder once that folder sits in the app's Documents.
Documents survives a reinstall, so after the first install the free account's weekly re-sign moves tens of MB, not GB.

  romfs_data.py info <ipa>                 one JSON line: whether the IPA can go this way, the RomFS id and size
  romfs_data.py lite <ipa> <out.ipa>       the IPA without its romfs/ folder (stored, plumesign re-packs it anyway)
  romfs_data.py push <ipa> [--udid UDID]   copy those folders into the installed app's Documents, unless they are there already

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
    p = r['ipa']
    if not os.path.isfile(p):
        raise SystemExit('找不到遊戲包 %s（遊戲庫裡 %s 的資料在那裡）：請再按一次「放進遊戲庫」' % (p, d))
    z = srcs.get(p)
    if r.get('source'): return FromNsp(z, app, d, r)
    pre = r.get('prefix') or ''
    out = [(z, i, d + '/' + i.filename[len(pre):]) for i in z.infolist() if pre and i.filename.startswith(pre) and not i.is_dir()]
    h = hashlib.sha1()
    for n, size, crc in sorted((app + dst, i.file_size, i.CRC) for _, i, dst in out): h.update(('%s\0%d\0%08x\n' % (n, size, crc)).encode())
    got = h.hexdigest()[:16]
    if got != r['id']:
        raise SystemExit('遊戲包 %s 在合成遊戲庫之後改過了（%s 對不上）：請再按一次「放進遊戲庫」' % (os.path.basename(p), d))
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
        except Exception as e: raise SystemExit('遊戲包 %s 裡的 RomFS 記錄讀不到（%s）：請再按一次「放進遊戲庫」' % (os.path.basename(z.filename), e))
        rec = self.rec
        h = hashlib.sha1()
        base = app + d + '/'
        for n, size, crc in sorted((base + f[0], f[1], f[2]) for f in rec['list']): h.update(('%s\0%d\0%08x\n' % (n, size, crc)).encode())
        if h.hexdigest()[:16] != r['id']:
            raise SystemExit('遊戲包 %s 在合成遊戲庫之後改過了（%s 對不上）：請再按一次「放進遊戲庫」' % (os.path.basename(z.filename), d))
        self.nsps = [x for x in (rec['base'], rec.get('update')) if x]
        for x in self.nsps:
            if not os.path.isfile(x['path']):
                raise SystemExit('找不到 %s（%s 的 RomFS 要從它解出來）：遊戲檔搬走了的話，請再按一次「放進遊戲庫」' % (x['path'], d))
            if os.path.getsize(x['path']) != x['size']:
                raise SystemExit('%s 跟打包時不一樣了（大小不同）：請再按一次「放進遊戲庫」' % x['path'])
        self.file_size = rec['bytes']
        self.count = rec['files']
        self.only = None      # the files to send (a folder the iPad has an older copy of), or None for all
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
            if not os.path.isfile(p): raise SystemExit('找不到 %s（%s），解不出 %s 的 RomFS：請在 Switch Pad 按「安裝」後再試' % (what, p, self.d))
        where = os.path.dirname(rec['base']['path'])
        self.tmp = os.path.join(where, '_romfs_push_%s' % rec.get('tid', 'game'))
        shutil.rmtree(self.tmp, ignore_errors=True)
        free = shutil.disk_usage(where).free
        if free < rec['bytes'] + (1 << 30):
            raise SystemExit('電腦空間不夠從 NSP 解出 %s 的 RomFS：要 %.1f GB，%s 只剩 %.1f GB' % (self.d, rec['bytes'] / 2**30 + 1, where, free / 2**30))
        print('從 NSP 解出 %s 的 RomFS（%.1f GB，%d 個檔，約一兩分鐘）' % (self.d, rec['bytes'] / 2**30, rec['files']), flush=True)
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
                raise SystemExit('從 NSP 解出的 %s 跟打包時不一樣（%s %s）：遊戲檔換過了的話，請再按一次「放進遊戲庫」'
                                 % (self.d, f[0], '不見了' if size < 0 else '大小不同'))
            if self.only is None or self.d + '/' + f[0] in self.only: jobs.append((DISK, DiskFile(p, f[1], f[2]), self.d + '/' + f[0]))
        print('解好了（%.0f 秒）' % (time.time() - t0), flush=True)
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
# the full list is written once the folder is complete. No list (an older Switch Pad sent it, or --force): sent whole.
LIST_DIR = '.romfs-files'


def listing_of(x):
    """{path under Documents: (size, CRC)} of a folder about to be sent, without extracting anything"""
    if isinstance(x, FromNsp): return {x.d + '/' + f[0]: (f[1], f[2]) for f in x.rec['list']}
    return {dst: (i.file_size, i.CRC) for _, i, dst in x}


def list_path(base, d): return '%s/%s/%s.json' % (base, LIST_DIR, d.replace('/', '~'))


async def read_list(afc, base, d):
    p = list_path(base, d)
    try:
        if not await afc.exists(p): return None
        return {k: tuple(v) for k, v in json.loads((await afc.get_file_contents(p)).decode('utf-8'))['files'].items()}
    except Exception: return None


async def write_list(afc, base, d, files):
    await afc.makedirs(base + '/' + LIST_DIR)
    await afc.set_file_contents(list_path(base, d), json.dumps({'files': {k: list(v) for k, v in sorted(files.items())}},
                                                               separators=(',', ':')).encode('utf-8'))


async def drop_list(afc, base, d):
    try:
        if await afc.exists(list_path(base, d)): await afc.rm(list_path(base, d), force=True)
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
    """push-<pid>.json in NXN_STATUS_DIR (nxn.ps1 sets it to work/status): Switch Pad's 背景工作 card shows the transfer's
    percentage, GB and time left from it. Written at most once a second; a failure to write is ignored."""
    def __init__(self, ipa):
        self.dir = os.environ.get('NXN_STATUS_DIR', '')
        self.d = {'kind': 'push', 'pid': os.getpid(), 'ipa': os.path.basename(ipa), 'state': 'running', 'phase': '連接 iPad',
                  'sent': 0, 'total': 0, 'files': 0, 'started': now_iso(), 'ended': '', 'message': ''}
        self.t0, self.sent0, self.last = time.time(), 0, 0.0
        self.write(True)

    def begin(self, total, nfiles):
        self.d.update(total=total, files=nfiles, sent=0, phase='傳送中')
        self.t0, self.sent0 = time.time(), 0
        self.write(True)

    def progress(self, sent):
        self.d['sent'] = sent
        self.d['phase'] = '傳送中'
        el = time.time() - self.t0
        if el > 3 and sent > self.sent0:
            rate = (sent - self.sent0) / el
            self.d['rate'] = int(rate)
            self.d['eta'] = int(max(self.d['total'] - sent, 0) / max(rate, 1))
        self.write()

    def end(self, ok, msg=''):
        self.d.update(state='done' if ok else 'failed', ended=now_iso(), message=msg)
        if ok: self.d['sent'] = self.d['total']
        self.d.pop('eta', None)
        self.write(True)

    def write(self, now=False):
        if not self.dir or (not now and time.time() - self.last < 1): return
        self.last = time.time()
        for _ in range(5 if now else 1):   # Switch Pad reading it at that moment keeps Windows from replacing it
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
            base = '/Documents' if await afc.exists('/Documents') else ''
            mark = base + '/' + MARK
            have = {}
            if await afc.exists(mark):
                try:
                    raw = (await afc.get_file_contents(mark)).decode().strip()
                    have = json.loads(raw) if raw.startswith('{') else {}
                except Exception: have = {}
            todo = [d for d in want if a.force or have.get(d) != want[d]]
            # a game taken out of a package: its folders go too (they would only take space)
            gone = [d for d in have if d not in want and d.startswith('games/')]
            for d in gone:
                if await afc.exists(base + '/' + d): await afc.rm(base + '/' + d, force=True)
                await drop_list(afc, base, d)
                print('removed %s (no longer in this package)' % d)
            if not todo:
                if gone: await afc.set_file_contents(mark, json.dumps(want).encode())
                await list_missing(afc, base, want, jobs_of)
                print('game files already on the iPad')
                return
            send = {d: jobs_of(d) for d in todo}   # (a linked folder whose game package changed stops here, before anything is removed)
            lists = {d: listing_of(send[d]) for d in todo}
            # a folder the iPad has an older copy of (with its file list): only the files that differ
            plan, skipped = {}, 0
            for d in todo:
                old = None if a.force else await read_list(afc, base, d)
                if old is None: plan[d] = None; continue
                changed = {k for k, v in lists[d].items() if old.get(k) != v}
                plan[d] = (old, changed, [k for k in old if k not in lists[d]])
                skipped += len(lists[d]) - len(changed)
                if isinstance(send[d], FromNsp): send[d].restrict(changed)
                else: send[d] = [j for j in send[d] if j[2] in changed]
            total = sum(jobs_left(x, ())[1] for x in send.values())
            nfiles = sum(jobs_left(x, ())[0] for x in send.values())
            a.status.begin(total, nfiles)
            print('copying to the iPad: %s (%d files, %d MB%s)' % (', '.join(todo), nfiles, total >> 20,
                  '; %d files already there unchanged' % skipped if skipped else ''))
            # forget the parts about to be replaced first, so a copy cut short is redone next time
            keep = {d: v for d, v in have.items() if d in want and d not in todo}
            await afc.set_file_contents(mark, json.dumps(keep).encode())
            for d in todo:
                if plan[d] is None:
                    await drop_list(afc, base, d)
                    if await afc.exists(base + '/' + d): await afc.rm(base + '/' + d, force=True)
                    continue
                old, changed, removed = plan[d]
                await write_list(afc, base, d, {k: v for k, v in old.items() if k not in changed and k in lists[d]})
                for k in removed:
                    if await afc.exists(base + '/' + k): await afc.rm(base + '/' + k, force=True)
                if removed: print('%s: removed %d files the new version no longer has' % (d, len(removed)))

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
                        nconn = await send_round(ld if attempt == 1 else None, a, bid, base, mark, todo, send, keep, want, done, state, total, lists)
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

            await list_missing(afc, base, want, jobs_of, skip=todo)
            el = max(time.time() - t0, 0.001)
            print('game files in place (%d files, %d MB in %.0f s over %d connections, %.1f MB/s)' % (nfiles, total >> 20, el, nconn, total / el / 2**20))


async def list_missing(afc, base, want, jobs_of, skip=()):
    """Write the file list of each folder the iPad has whole but no list for (sent by an older Switch Pad), so its next
    change sends only what changed. Best effort: a folder whose source cannot be read now is left without one."""
    for d in want:
        if d in skip: continue
        try:
            if await afc.exists(list_path(base, d)): continue
            await write_list(afc, base, d, listing_of(jobs_of(d)))
        except (Exception, SystemExit): pass


def is_disconnect(e):
    """A dropped link to the iPad (USB unplugged for a moment, the iPad locked, usbmuxd restarted), worth reconnecting for."""
    names = {type(x).__name__ for x in (e, e.__cause__, e.__context__) if x is not None}
    return bool(names & {'ConnectionTerminatedError', 'ConnectionResetError', 'ConnectionAbortedError', 'BrokenPipeError',
                         'ConnectionFailedError', 'ConnectionFailedToUsbmuxdError', 'NoDeviceConnectedError',
                         'DeviceNotFoundError', 'IncompleteReadError', 'TimeoutError', 'OSError'})


async def send_round(ld, a, bid, base, mark, todo, send, keep, want, done, state, total, lists):
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
                js = [j for j in (send[d].get() if isinstance(send[d], FromNsp) else send[d]) if j[2] not in done]
                for dd in sorted({(base + '/' + dst).rsplit('/', 1)[0] for _, _, dst in js}):
                    await afc.makedirs(dd)
                queue = asyncio.Queue()
                for job in sorted(js, key=lambda j: -j[1].file_size): queue.put_nowait(job)   # big files first, so none is left alone at the end

                async def worker(c):
                    while True:
                        try: zz, i, dst = queue.get_nowait()
                        except asyncio.QueueEmpty: return
                        h = await c.fopen(base + '/' + dst, 'w')
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
                                    a.status.progress(state['sent'])
                                    pct = state['sent'] * 100 // max(total, 1)
                                    if pct != state['shown'] and (pct % 2 == 0 or pct == 100):
                                        state['shown'] = pct
                                        print('傳送遊戲資料 %d%%（%d / %d MB）' % (pct, state['sent'] >> 20, total >> 20), flush=True)
                        except BaseException:
                            state['sent'] -= got   # counted again when it is sent again
                            raise
                        await c.fclose(h)
                        if check and crc != i.crc:
                            raise Mismatch('從 NSP 解出的 %s 內容跟打包時不一樣：遊戲檔換過了的話，請再按一次「放進遊戲庫」' % dst)
                        done.add(dst)
                tasks = [asyncio.ensure_future(worker(c)) for c in conns]
                try: await asyncio.gather(*tasks)
                except BaseException:
                    for t in tasks: t.cancel()   # one connection dropped: stop the others before reconnecting
                    await asyncio.gather(*tasks, return_exceptions=True)
                    raise
                await write_list(afc, base, d, lists[d])
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
    a = ap.parse_args()
    if a.cmd == 'info': cmd_info(a)
    elif a.cmd == 'lite': cmd_lite(a)
    else:
        try: import pymobiledevice3  # noqa: F401
        except ImportError: raise SystemExit('pymobiledevice3 is not installed')
        try: asyncio.run(push(a))
        except Mismatch as e: raise SystemExit(str(e))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    main()
