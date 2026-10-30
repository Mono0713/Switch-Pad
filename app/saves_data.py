"""Back up and restore a game's saves on the iPad, through the app's Documents (the same route romfs_data.py sends game files).

The shell keeps a game's save in Documents/save and, for a game that also mounts device save data (Mario Kart 8 Deluxe),
Documents/save_device; a package of several games keeps each game's in save/<title ID> and save/<title ID>_device
(dm/ios/Sources/main.m, dm/host/hle_fs.c). The host commits a save by swapping in <dir>.new, and works in <dir>.work while the
game runs: those two are one session's uncommitted copy, so they are left out.

Idea from NX Play's Transfer Saves and NX2Apple's SaveTransfer (both MIT, see NOTICE): the save about to be replaced is
backed up first, so a copy in the wrong direction loses nothing.

  saves_data.py backup  <ipa> <backups folder> [--udid UDID] [--keep N] [--tag TEXT]
  saves_data.py restore <ipa> <one backup folder> <backups folder> [--udid UDID]
  saves_data.py migrate <library ipa> <backups folder> [--udid UDID] [--overwrite]

migrate moves saves from the apps made before the game library (one app per game, org.nxnative.<title ID>, and the merged
packages, org.nxnative.games[.p<hash>]) into the library app, in two halves so the old apps can be deleted before the library
is installed (a free Apple ID holds 3 apps): every old app still on the iPad is copied as it is to <backups folder>/舊App存檔/
<time>/; then, when the library is on the iPad, every copy made so far goes into it, a one-game app's save/ becoming the
library's save/<title ID>/. Only the library's games are written, the save changed last of each; a game that already has a
save in the library is left alone unless --overwrite. The library is backed up first.

A backup is <backups folder>/<yyyyMMdd-HHmmss>[-tag]/ holding save/ (and save_device/), plus a .digest of its files. A backup
whose files are the same as the newest one's is not kept again. Exit codes: 0 done (or nothing to back up), 3 the app is not
on the iPad, 1 anything else.
"""
import argparse
import asyncio
import contextlib
import datetime
import hashlib
import json
import os
import plistlib
import re
import shutil
import sys
import zipfile

FOLDERS = ('save', 'save_device')
DIGEST = '.digest'
NOT_INSTALLED = 3


def skipped(name):
    return name.endswith(('.work', '.new'))


def bundle_of(ipa):
    with zipfile.ZipFile(ipa) as z:
        plist = next((n for n in z.namelist() if re.match(r'Payload/[^/]+\.app/Info\.plist$', n)), None)
        if not plist: raise SystemExit('not an app package: no Payload/*.app/Info.plist')
        return plistlib.loads(z.read(plist)).get('CFBundleIdentifier', '')


def digest_of(folder):
    """A hash of every file's path and contents under folder (the .digest itself left out)."""
    h = hashlib.sha1()
    for root, dirs, files in os.walk(folder):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            rel = os.path.relpath(p, folder).replace(os.sep, '/')
            if rel == DIGEST: continue
            h.update(rel.encode() + b'\0')
            with open(p, 'rb') as fh:
                for b in iter(lambda: fh.read(1 << 20), b''): h.update(b)
            h.update(b'\0')
    return h.hexdigest()


def backups(root):
    """The finished backups in root, oldest first."""
    if not os.path.isdir(root): return []
    return sorted(d for d in os.listdir(root) if re.match(r'\d{8}-\d{6}', d) and not d.endswith('.part')
                  and os.path.isdir(os.path.join(root, d)))


def stamp_of(st):
    """A file's change time from AFC stat, in seconds (pymobiledevice3 gives a datetime; raw AFC gives nanoseconds)."""
    t = st.get('st_mtime', 0)
    if isinstance(t, datetime.datetime): return t.timestamp()
    t = float(t or 0)
    return t / 1e9 if t > 1e12 else t


async def pull_tree(afc, src, dest):
    """Copy the device folder src into dest; returns the number of files."""
    n = 0
    os.makedirs(dest, exist_ok=True)
    for name in await afc.listdir(src):
        if name in ('.', '..', '') or skipped(name): continue
        s, d = src + '/' + name, os.path.join(dest, name)
        if (await afc.stat(s)).get('st_ifmt') == 'S_IFDIR':
            n += await pull_tree(afc, s, d)
        else:
            with open(d, 'wb') as f: f.write(await afc.get_file_contents(s))
            t = stamp_of(await afc.stat(s))
            if t: os.utime(d, (t, t))
            n += 1
    return n


async def push_tree(afc, src, dest):
    n = 0
    await afc.makedirs(dest)
    for name in sorted(os.listdir(src)):
        s, d = os.path.join(src, name), dest + '/' + name
        if os.path.isdir(s):
            n += await push_tree(afc, s, d)
        else:
            with open(s, 'rb') as f: await afc.set_file_contents(d, f.read())
            n += 1
    return n


async def docs_base(afc):
    return '/Documents' if await afc.exists('/Documents') else ''


async def backup(afc, root, keep=30, tag='', now=None):
    """Copy the app's saves into a new folder under root. Returns its path, or None when there was nothing new."""
    base = await docs_base(afc)
    present = [f for f in FOLDERS if await afc.exists(base + '/' + f)]
    if not present:
        print('iPad 上還沒有這款的存檔')
        return None
    stamp = (now or datetime.datetime.now()).strftime('%Y%m%d-%H%M%S') + ('-' + re.sub(r'[^\w-]', '_', tag) if tag else '')
    part = os.path.join(root, stamp + '.part')
    shutil.rmtree(part, ignore_errors=True)
    n = 0
    for f in present: n += await pull_tree(afc, base + '/' + f, os.path.join(part, f))
    dg = digest_of(part)
    old = backups(root)
    if old and os.path.isfile(os.path.join(root, old[-1], DIGEST)):
        with open(os.path.join(root, old[-1], DIGEST)) as fh:
            if fh.read().strip() == dg:
                shutil.rmtree(part, ignore_errors=True)
                print('存檔跟上一次備份一樣（%s），不另存' % old[-1])
                return None
    with open(os.path.join(part, DIGEST), 'w') as fh: fh.write(dg)
    final = os.path.join(root, stamp)
    k = 1
    while os.path.exists(final): k += 1; final = os.path.join(root, '%s-%d' % (stamp, k))
    os.replace(part, final)
    print('存檔備份好了：%s（%d 個檔案）' % (final, n))
    # keep the newest `keep`; a backup made before a restore is kept like any other
    for d in backups(root)[:-keep] if keep > 0 else []:
        shutil.rmtree(os.path.join(root, d), ignore_errors=True)
    return final


async def restore(afc, src, root, now=None):
    """Put the backup folder src back on the iPad, after backing up what is there now."""
    have = [f for f in FOLDERS if os.path.isdir(os.path.join(src, f))]
    if not have: raise SystemExit('這個資料夾裡沒有存檔（save\\）：%s' % src)
    await backup(afc, root, keep=0, tag='before-restore', now=now)
    base = await docs_base(afc)
    for f in FOLDERS:
        p = base + '/' + f
        for leftover in (p, p + '.work', p + '.new'):
            if await afc.exists(leftover): await afc.rm(leftover, force=True)
    n = 0
    for f in have: n += await push_tree(afc, os.path.join(src, f), base + '/' + f)
    print('存檔還原好了：%s（%d 個檔案）' % (os.path.basename(os.path.normpath(src)), n))


SINGLE = re.compile(r'org\.nxnative\.([0-9a-fA-F]{16})(?:\.|$)')
PACK = re.compile(r'org\.nxnative\.games(?:\.p[0-9a-f]+)?(?:\.|$)')
OLD_DIR = '舊App存檔'
APP_JSON = 'app.json'
LIBRARY = 'org.nxnative.games.library'


def library_tids(ipa):
    with zipfile.ZipFile(ipa) as z:
        return sorted({m.group(1).upper() for n in z.namelist() for m in [re.match(r'Payload/[^/]+\.app/games/([0-9A-Fa-f]{16})/', n)] if m})


def old_apps(apps, library):
    """[(installed bundle ID, its name, the title ID of a one-game app or None for a package)] of the apps made before the library."""
    out = []
    for b, info in sorted(apps.items()):
        if b == library or b.startswith(library + '.'): continue
        name = info.get('CFBundleDisplayName') or info.get('CFBundleName') or b
        m = SINGLE.match(b)
        if m: out.append((b, name, m.group(1).upper()))
        elif PACK.match(b): out.append((b, name, None))
    return out


def newest(folder):
    """(number of files, newest change time) under a local folder."""
    n, t = 0, 0.0
    for r, _, fs in os.walk(folder):
        for f in fs: n += 1; t = max(t, os.path.getmtime(os.path.join(r, f)))
    return n, t


async def collect(olds, root, now=None):
    """Copy every old app's saves, as they are, to <root>/舊App存檔/<time>/<n>-<name>/ with an app.json saying what the app
    was. olds = [(bundle ID, name, title ID of a one-game app or None, afc)]. Returns the folders made."""
    keep = os.path.join(root, OLD_DIR, (now or datetime.datetime.now()).strftime('%Y%m%d-%H%M%S'))
    made = []
    for i, (bundle, name, single, afc) in enumerate(olds):
        base = await docs_base(afc)
        here = os.path.join(keep, '%02d-%s' % (i + 1, re.sub(r'[\\/:*?"<>|]', '_', name)))
        n = 0
        for f in FOLDERS:
            if await afc.exists(base + '/' + f): n += await pull_tree(afc, base + '/' + f, os.path.join(here, f))
        if not n: print('「%s」裡沒有存檔' % name); continue
        with open(os.path.join(here, APP_JSON), 'w', encoding='utf-8') as fh:
            json.dump({'bundle': bundle, 'name': name, 'tid': single}, fh, ensure_ascii=False)
        print('「%s」的存檔存到電腦了（%d 個檔案）：%s' % (name, n, here))
        made.append(here)
    return made


def collected(root):
    """Every old app's saves collected so far, as [(name, local folder holding save/ and save_device/, title ID or None)]."""
    out = []
    top = os.path.join(root, OLD_DIR)
    for t in sorted(os.listdir(top)) if os.path.isdir(top) else []:
        for d in sorted(os.listdir(os.path.join(top, t))):
            meta = os.path.join(top, t, d, APP_JSON)
            if not os.path.isfile(meta): continue
            with open(meta, encoding='utf-8') as fh: j = json.load(fh)
            out.append((j.get('name') or d, os.path.join(top, t, d), j.get('tid')))
    return out


def game_saves(folder, tid, single):
    """{'save': local folder, 'save_device': ...} of one game in a collected app, only those holding files."""
    if single:
        paths = {'save': os.path.join(folder, 'save'), 'save_device': os.path.join(folder, 'save_device')}
    else:
        sd = os.path.join(folder, 'save')
        names = {x.upper(): x for x in (os.listdir(sd) if os.path.isdir(sd) else [])}
        paths = {k: os.path.join(sd, names[v]) for k, v in (('save', tid), ('save_device', tid + '_DEVICE')) if v in names}
    return {k: p for k, p in paths.items() if os.path.isdir(p) and newest(p)[0]}


async def place(lib_afc, sources, tids, root, overwrite=False, now=None):
    """Put collected saves into the library's save/<title ID>/: the save changed last of each game the library holds; a game
    that already has a save in the library is left alone unless overwrite. sources = collected(root). Returns the title IDs done."""
    found = {}    # title ID -> (newest change, app name, {'save': folder, 'save_device': folder})
    for name, folder, single in sources:
        for tid in [single] if single else tids:
            if tid not in tids: continue
            paths = game_saves(folder, tid, single)
            if not paths: continue
            t = max(newest(p)[1] for p in paths.values())
            if tid not in found or t > found[tid][0]: found[tid] = (t, name, paths)
    if not found:
        print('電腦上的舊 App 存檔裡，沒有遊戲庫這些遊戲的存檔')
        return []
    await backup(lib_afc, root, keep=0, tag='before-migrate', now=now)
    base = await docs_base(lib_afc)
    done = []
    for tid, (_, name, paths) in sorted(found.items()):
        dest = base + '/save/' + tid
        if not overwrite and await lib_afc.exists(dest) and await count_files(lib_afc, dest):
            print('%s 在遊戲庫裡已經有存檔，沒有蓋掉' % tid); continue
        for d in (dest, dest + '_device'):
            for leftover in (d, d + '.work', d + '.new'):
                if await lib_afc.exists(leftover): await lib_afc.rm(leftover, force=True)
        n = 0
        if 'save' in paths: n += await push_tree(lib_afc, paths['save'], dest)
        if 'save_device' in paths: n += await push_tree(lib_afc, paths['save_device'], dest + '_device')
        print('%s：用「%s」的存檔（%d 個檔案）' % (tid, name, n))
        done.append(tid)
    print('放進遊戲庫 %d 款' % len(done))
    return done


async def count_files(afc, path):
    n = 0
    for name in await afc.listdir(path):
        if name in ('.', '..', '') or skipped(name): continue
        p = path + '/' + name
        n += await count_files(afc, p) if (await afc.stat(p)).get('st_ifmt') == 'S_IFDIR' else 1
    return n


async def migrate_on_device(a):
    """Collect the old apps' saves to the computer; when the library is on the iPad, put every collected save into it."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.house_arrest import HouseArrestService

    lib = bundle_of(a.ipa) if os.path.isfile(a.ipa) else LIBRARY   # not made yet: the old saves can still be collected
    ld = await create_using_usbmux(serial=a.udid or None)
    async with ld:
        async with InstallationProxyService(lockdown=ld) as ip:
            apps = await ip.get_apps(application_type='User')
        ids = [b for b in apps if b == lib or b.startswith(lib + '.')]
        olds = old_apps(apps, lib)
        async with contextlib.AsyncExitStack() as stack:
            async def afc(b): return await stack.enter_async_context(await HouseArrestService.create(lockdown=ld, bundle_id=b, documents_only=True))
            if olds:
                print('iPad 上的舊 App：' + '、'.join(n for _, n, _ in olds))
                await collect([(b, n, t, await afc(b)) for b, n, t in olds], a.root)
            else:
                print('iPad 上沒有舊的單款 App 或合包')
            if not ids:
                print('遊戲庫還沒裝到 iPad：舊存檔都在電腦上了，可以從 iPad 刪掉舊 App。裝好遊戲庫後再按一次「搬舊 App 存檔」放進去')
                return 0
            sources = collected(a.root)
            if not sources:
                print('電腦上還沒有舊 App 的存檔')
                return 0
            if not os.path.isfile(a.ipa) or not library_tids(a.ipa): raise SystemExit('讀不到遊戲庫裡有哪些遊戲：%s' % a.ipa)
            await place(await afc(ids[0]), sources, library_tids(a.ipa), a.root, a.overwrite)
    return 0


async def on_device(a, work):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.house_arrest import HouseArrestService

    orig = bundle_of(a.ipa)
    ld = await create_using_usbmux(serial=a.udid or None)
    async with ld:
        # plumesign signs the app as <id>.<team ID>, so look for the installed app by its prefix (as romfs_data.py does)
        async with InstallationProxyService(lockdown=ld) as ip:
            apps = await ip.get_apps(application_type='User')
        ids = [b for b in apps if b == orig or b.startswith(orig + '.')]
        if not ids:
            print('iPad 上沒有這個 App（%s），沒有存檔可以備份' % orig)
            return NOT_INSTALLED
        async with await HouseArrestService.create(lockdown=ld, bundle_id=ids[0], documents_only=True) as afc:
            await work(afc)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('backup'); p.add_argument('ipa'); p.add_argument('root')
    p.add_argument('--keep', type=int, default=30); p.add_argument('--tag', default='')
    p = sub.add_parser('restore'); p.add_argument('ipa'); p.add_argument('src'); p.add_argument('root')
    p = sub.add_parser('migrate'); p.add_argument('ipa'); p.add_argument('root'); p.add_argument('--overwrite', action='store_true')
    for p in sub.choices.values(): p.add_argument('--udid', default='')
    a = ap.parse_args()
    try: import pymobiledevice3  # noqa: F401
    except ImportError: raise SystemExit('pymobiledevice3 is not installed')
    if a.cmd == 'migrate': return asyncio.run(migrate_on_device(a))
    if a.cmd == 'backup': work = lambda afc: backup(afc, a.root, a.keep, a.tag)
    else: work = lambda afc: restore(afc, a.src, a.root)
    return asyncio.run(on_device(a, work))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    sys.exit(main())
