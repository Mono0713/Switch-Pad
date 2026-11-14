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

A package nxn_merge.py made with --link holds no game data: its zip comment records, for each folder, the game's own
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
    def get(self, path):
        if path not in self.open: self.open[path] = zipfile.ZipFile(path)
        return self.open[path]


def linked_files(srcs, app, d, r):
    """[(zip, ZipInfo, path under Documents)] of one linked folder, read from the game package nxn_merge.py recorded"""
    p = r['ipa']
    if not os.path.isfile(p):
        raise SystemExit('找不到遊戲包 %s（遊戲庫裡 %s 的資料在那裡）：請再按一次「放進遊戲庫」' % (p, d))
    z = srcs.get(p)
    pre = r.get('prefix') or ''
    out = [(z, i, d + '/' + i.filename[len(pre):]) for i in z.infolist() if pre and i.filename.startswith(pre) and not i.is_dir()]
    h = hashlib.sha1()
    for n, size, crc in sorted((app + dst, i.file_size, i.CRC) for _, i, dst in out): h.update(('%s\0%d\0%08x\n' % (n, size, crc)).encode())
    got = h.hexdigest()[:16]
    if got != r['id']:
        raise SystemExit('遊戲包 %s 在合成遊戲庫之後改過了（%s 對不上）：請再按一次「放進遊戲庫」' % (os.path.basename(p), d))
    return out


async def push(a):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.house_arrest import HouseArrestService

    z = zipfile.ZipFile(a.ipa)
    link = read_link(z)
    app, pl, parts, files, several = layout(z)
    orig = pl.get('CFBundleIdentifier', '')
    srcs = Sources()
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
                print('removed %s (no longer in this package)' % d)
            if not todo:
                if gone: await afc.set_file_contents(mark, json.dumps(want).encode())
                print('game files already on the iPad')
                return
            send = {d: jobs_of(d) for d in todo}   # (a linked folder whose game package changed stops here, before anything is removed)
            total = sum(i.file_size for js in send.values() for _, i, _ in js)
            nfiles = sum(len(js) for js in send.values())
            print('copying to the iPad: %s (%d files, %d MB)' % (', '.join(todo), nfiles, total >> 20))
            # forget the parts about to be replaced first, so a copy cut short is redone next time
            keep = {d: v for d, v in have.items() if d in want and d not in todo}
            await afc.set_file_contents(mark, json.dumps(keep).encode())
            for d in todo:
                if await afc.exists(base + '/' + d): await afc.rm(base + '/' + d, force=True)

            # extra connections to the app's Documents: AFC answers one request at a time per connection
            want_conn = max(1, min(16, int(os.environ.get('NXN_PUSH_CONN', '4') or 4)))
            conns = [afc]
            for _ in range(want_conn - 1):
                try: conns.append(await (await HouseArrestService.create(lockdown=ld, bundle_id=bid, documents_only=True)).__aenter__())
                except Exception as e:
                    print('note: only %d connection(s) to the iPad (%s)' % (len(conns), e)); break
            t0 = time.time()
            state = {'sent': 0, 'shown': -1}
            try:
                for d in todo:
                    js = send[d]
                    for dd in sorted({(base + '/' + dst).rsplit('/', 1)[0] for _, _, dst in js}):
                        await afc.makedirs(dd)
                    queue = asyncio.Queue()
                    for job in sorted(js, key=lambda j: -j[1].file_size): queue.put_nowait(job)   # big files first, so none is left alone at the end

                    async def worker(c):
                        while True:
                            try: zz, i, dst = queue.get_nowait()
                            except asyncio.QueueEmpty: return
                            h = await c.fopen(base + '/' + dst, 'w')
                            try:
                                with zz.open(i) as src:
                                    while True:
                                        b = src.read(4 << 20) if i.file_size < (8 << 20) else await asyncio.to_thread(src.read, 4 << 20)
                                        if not b: break
                                        await c.fwrite(h, b)
                                        state['sent'] += len(b)
                                        pct = state['sent'] * 100 // max(total, 1)
                                        if pct != state['shown'] and (pct % 2 == 0 or pct == 100):
                                            state['shown'] = pct
                                            print('傳送遊戲資料 %d%%（%d / %d MB）' % (pct, state['sent'] >> 20, total >> 20), flush=True)
                            finally:
                                await c.fclose(h)
                    await asyncio.gather(*(worker(c) for c in conns))
                    keep[d] = want[d]
                    await afc.set_file_contents(mark, json.dumps(keep).encode())
            finally:
                for c in conns[1:]:
                    try: await c.__aexit__(None, None, None)
                    except Exception: pass
            el = max(time.time() - t0, 0.001)
            print('game files in place (%d files, %d MB in %.0f s over %d connections, %.1f MB/s)' % (nfiles, total >> 20, el, len(conns), total / el / 2**20))


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
        asyncio.run(push(a))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    main()
