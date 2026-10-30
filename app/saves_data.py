"""Back up and restore a game's saves on the iPad, through the app's Documents (the same route romfs_data.py sends game files).

The shell keeps a game's save in Documents/save and, for a game that also mounts device save data (Mario Kart 8 Deluxe),
Documents/save_device; a package of several games keeps each game's in save/<title ID> and save/<title ID>_device
(dm/ios/Sources/main.m, dm/host/hle_fs.c). The host commits a save by swapping in <dir>.new, and works in <dir>.work while the
game runs: those two are one session's uncommitted copy, so they are left out.

Idea from NX Play's Transfer Saves and NX2Apple's SaveTransfer (both MIT, see NOTICE): the save about to be replaced is
backed up first, so a copy in the wrong direction loses nothing.

  saves_data.py backup  <ipa> <backups folder> [--udid UDID] [--keep N] [--tag TEXT]
  saves_data.py restore <ipa> <one backup folder> <backups folder> [--udid UDID]

A backup is <backups folder>/<yyyyMMdd-HHmmss>[-tag]/ holding save/ (and save_device/), plus a .digest of its files. A backup
whose files are the same as the newest one's is not kept again. Exit codes: 0 done (or nothing to back up), 3 the app is not
on the iPad, 1 anything else.
"""
import argparse
import asyncio
import datetime
import hashlib
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
    for p in sub.choices.values(): p.add_argument('--udid', default='')
    a = ap.parse_args()
    try: import pymobiledevice3  # noqa: F401
    except ImportError: raise SystemExit('pymobiledevice3 is not installed')
    if a.cmd == 'backup': work = lambda afc: backup(afc, a.root, a.keep, a.tag)
    else: work = lambda afc: restore(afc, a.src, a.root)
    return asyncio.run(on_device(a, work))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    sys.exit(main())
