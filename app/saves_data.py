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
  saves_data.py put     <ipa> <save folder> <backups folder> [--tid TITLEID] [--slot NAME] [--udid UDID]
  saves_data.py logs    <ipa> <logs folder> [--udid UDID]
  saves_data.py glsync  <ipa> <shaders folder> [--udid UDID]

put places one game's save from the PC (what Switch Pad takes when a save is dropped on a game card: an emulator's, JKSV's or
Checkpoint's export, which are the same plain tree the shell keeps) as that game's save: save/ in a one-game app, save/<title
ID> in the library or a package, which must have that game (exit 5 when it does not). The app's saves are backed up first, as
restore does, and only that one game's folder (and its .work / .new) is replaced. With --slot the save in use is not touched: the
save becomes a new save slot of that game, named NAME, which the player picks on the launcher (the shell's SaveSlots.swift).

Save slots: the shell keeps the save in use where it always was and every other slot of that game in <save folder>.slots/<n>/save
(and device), named in <save folder>.slots/slots.json ({"active": 1, "slots": [{"id": 1, "name": "..."}]}). In the library they
are inside save/, so backup and restore take them along with the rest; a one-game app's save.slots is one of FOLDERS for that.

glsync is for games whose shaders exist only while they run: an OpenGL game (Roof Rage) records each GLSL shader it
compiles to Documents/<DM_GL_CAPTURE>, an NVN game compiling GLSL with GLSLC (Unrailed 2) each output to <DM_GLSLC_CAPTURE> (gl_capture/<title ID>
or glslc_capture/<title ID>, set in the game's dm/env.txt). It makes those folders on
the iPad (the host only writes files into one that exists) and copies what was recorded to <shaders folder>/<title ID>/,
which the next pack of that game takes with --gl-capture (or --glslc-capture).

logs copies the app's own logs (Documents/log.txt, log.prev.txt, the other top-level .txt / .log files and each game's own
last two runs in Documents/logs/) to <logs folder>/<time>/ and prints what the host reported red, grouped: the system functions, services and NVN calls the shell
does not have yet are what a game stops on, and this is the list to implement next (Ryujinx's HLE, MIT, is the reference).

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

FOLDERS = ('save', 'save_device', 'save.slots')
DIGEST = '.digest'
NOT_INSTALLED = 3
NOT_IN_APP = 5


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


def save_dest(ipa, tid):
    """Where a game's save lives in the app's Documents: 'save' in a one-game app, 'save/<title ID as the package names it>' in a
    package, or None when the package does not have that game."""
    with zipfile.ZipFile(ipa) as z:
        folders = sorted({m.group(1) for n in z.namelist() for m in [re.match(r'Payload/[^/]+\.app/games/([0-9A-Fa-f]{16})/', n)] if m})
    if not folders: return 'save'
    hit = next((f for f in folders if f.upper() == (tid or '').upper()), None)
    return 'save/' + hit if hit else None


def local_files(folder):
    return sorted(os.path.relpath(os.path.join(r, f), folder).replace(os.sep, '/') for r, _, fs in os.walk(folder) for f in fs)


async def check_sizes(afc, src, p, files):
    """Read the sizes back: a save cut short is worse than none."""
    bad = []
    for rel in files:
        st = await afc.stat(p + '/' + rel)
        if 'st_size' in st and int(st['st_size']) != os.path.getsize(os.path.join(src, *rel.split('/'))): bad.append(rel)
    if bad: raise SystemExit('這些檔案沒有完整傳到：%s' % '、'.join(bad[:5]))


SLOTS = '.slots'
SLOTS_JSON = 'slots.json'


async def read_slots(afc, sd):
    """slots.json of one game's slots folder, or the one the shell starts from (one slot, in use) when there is none yet."""
    data = None
    if await afc.exists(sd + '/' + SLOTS_JSON):
        with contextlib.suppress(ValueError, UnicodeDecodeError):
            data = json.loads((await afc.get_file_contents(sd + '/' + SLOTS_JSON)).decode('utf-8'))
    if not isinstance(data, dict) or not isinstance(data.get('slots'), list) or not data['slots']:
        data = {'active': 1, 'slots': [{'id': 1, 'name': '存檔 1'}]}
    return data


def next_slot(data, names):
    """The number of a new slot: past every slot listed and every numbered folder there."""
    ids = [int(x['id']) for x in data['slots'] if isinstance(x, dict) and str(x.get('id', '')).isdigit()]
    ids += [int(n) for n in names if n.isdigit()]
    return max(ids + [int(data.get('active', 1) or 1)]) + 1


async def put(afc, src, root, dest, slot='', now=None):
    """Replace the save folder dest (relative to Documents) with the PC folder src, after backing up the app's saves; with slot,
    add src as a new save slot of that game named slot instead, leaving the save in use as it is."""
    files = local_files(src)
    if not files: raise SystemExit('這個資料夾裡沒有檔案：%s' % src)
    await backup(afc, root, keep=0, tag='before-import', now=now)
    base = await docs_base(afc)
    if slot:
        sd = base + '/' + dest + SLOTS
        data = await read_slots(afc, sd)
        names = [n for n in await afc.listdir(sd) if n not in ('.', '..', '')] if await afc.exists(sd) else []
        k = next_slot(data, names)
        p = '%s/%d/save' % (sd, k)
        n = await push_tree(afc, src, p)
        await check_sizes(afc, src, p, files)
        data['slots'].append({'id': k, 'name': slot})
        await afc.set_file_contents(sd + '/' + SLOTS_JSON, json.dumps(data, ensure_ascii=False, indent=2).encode('utf-8'))
        print('存檔放進 iPad 了：%d 個檔案 → %s 的新存檔「%s」（在遊戲開始前的設定畫面「存檔」裡切換）' % (n, dest, slot))
        return
    p = base + '/' + dest
    for leftover in (p, p + '.work', p + '.new'):
        if await afc.exists(leftover): await afc.rm(leftover, force=True)
    n = await push_tree(afc, src, p)
    await check_sizes(afc, src, p, files)
    print('存檔放進 iPad 了：%d 個檔案 → %s' % (n, dest))


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


def gl_games(ipa):
    """{title ID: Documents-relative folder} of the games in a package that record their shaders on the iPad: the GLSL an OpenGL
    game compiles (DM_GL_CAPTURE in dm/env.txt, Roof Rage) or the GLSLC outputs an NVN game compiles at run time
    (DM_GLSLC_CAPTURE, Unrailed 2). A game has one or the other, so both go to the same <shaders folder>/<title ID>."""
    out = {}
    with zipfile.ZipFile(ipa) as z:
        for n in z.namelist():
            m = re.match(r'Payload/[^/]+\.app/games/([0-9A-Fa-f]{16})/dm/env\.txt$', n)
            if not m: continue
            for line in z.read(n).decode('utf-8', 'replace').splitlines():
                k, _, v = line.partition('=')
                if k.strip() in ('DM_GL_CAPTURE', 'DM_GLSLC_CAPTURE') and v.strip() and not v.strip().startswith('/'): out[m.group(1).upper()] = v.strip()
    return out


SHADER_FILE = re.compile(r'[0-9a-f]{16}\.(vert|frag|glslc)')   # what the host writes: <key>.vert / .frag (hle_gl.m), <hash>.glslc (hle_glslc.c)


async def gl_sync(afc, games, root):
    """Make each recording folder on the iPad and copy the shaders not yet on the computer. Returns {title ID: total}."""
    base = await docs_base(afc)
    totals = {}
    for tid, rel in sorted(games.items()):
        d = base + '/' + rel
        await afc.makedirs(d)
        dest = os.path.join(root, tid)
        os.makedirs(dest, exist_ok=True)
        new = 0
        for name in await afc.listdir(d):
            if not SHADER_FILE.fullmatch(name) or os.path.isfile(os.path.join(dest, name)): continue
            with open(os.path.join(dest, name), 'wb') as f: f.write(await afc.get_file_contents(d + '/' + name))
            new += 1
        totals[tid] = len([n for n in os.listdir(dest) if SHADER_FILE.fullmatch(n)])
        print('%s：iPad 記下的著色器 %d 個（這次新拿回 %d 個）' % (tid, totals[tid], new) if totals[tid]
              else '%s：還沒記下著色器，在 iPad 上打開這款玩一下' % tid)
    return totals


LOG_FILES = re.compile(r'.+\.(txt|log)$', re.I)


def red_summary(text, top=40):
    """The [RED] lines of a host log, grouped by their wording with numbers and addresses taken out, most frequent first."""
    groups = {}
    for line in text.splitlines():
        i = line.find('[RED]')
        if i < 0: continue
        msg = line[i + 5:].strip()
        key = re.sub(r'0x[0-9a-fA-F]+|\b[0-9a-fA-F]{8,}\b|\d+', '#', msg)[:160]
        n, first = groups.get(key, (0, msg))
        groups[key] = (n + 1, first)
    return sorted(groups.values(), key=lambda g: -g[0])[:top], len(groups)


unreadable = []


async def fetch_log(afc, src, dst):
    """One log file from the iPad; a file that cannot be read is reported and skipped, never ends the pull (written only once its contents arrive)."""
    try: data = await afc.get_file_contents(src)
    except Exception as e:
        unreadable.append(src)
        print('讀不到 iPad 上的 %s（%s），跳過' % (src.split('/', 2)[-1] if src.startswith('/') else src, str(e)[:120]))
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'wb') as f: f.write(data)
    return True


async def pull_logs(afc, root, now=None):
    base = await docs_base(afc)
    dest = os.path.join(root, (now or datetime.datetime.now()).strftime('%Y%m%d-%H%M%S'))
    got = []
    for name in await afc.listdir(base or '/'):
        if not LOG_FILES.match(name): continue
        p = base + '/' + name
        if (await afc.stat(p)).get('st_ifmt') == 'S_IFDIR': continue
        if await fetch_log(afc, p, os.path.join(dest, name)): got.append(name)
    # each game's own last two runs (the shell keeps them in Documents/logs/<title ID>.txt / .prev.txt, so a crash is not lost when another game is opened)
    per_game = []
    try: names = await afc.listdir((base or '') + '/logs')
    except Exception: names = []
    for name in sorted(names):
        if not LOG_FILES.match(name): continue
        if await fetch_log(afc, (base or '') + '/logs/' + name, os.path.join(dest, 'logs', name)): per_game.append('logs/' + name)
    got += per_game
    if not got:
        print('iPad 上有記錄但一個都讀不到（見上面）' if unreadable else 'iPad 上還沒有記錄：先在 iPad 上打開遊戲一次')
        return None
    print('記錄存到 %s：%s' % (dest, '、'.join(got)))
    for name in ['log.txt', 'log.prev.txt'] + per_game:
        f = os.path.join(dest, name)
        if not os.path.isfile(f): continue
        with open(f, encoding='utf-8', errors='replace') as fh: text = fh.read()
        games = re.findall(r'boot: game (\S+) \(([^)]*)\)', text)
        groups, total = red_summary(text)
        print('\n== %s%s：%d 種紅字' % (name, '（%s）' % '、'.join(g[1] for g in games[-1:]) if games else '', total))
        for n, msg in groups: print('%5d  %s' % (n, msg[:200]))
        crash = [l for l in text.splitlines() if '[dm] CRASH' in l or 'watchdog: no progress' in l]
        if crash: print('  閃退：' + crash[0][:200])
    return dest


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
    p = sub.add_parser('logs'); p.add_argument('ipa'); p.add_argument('root')
    p = sub.add_parser('glsync'); p.add_argument('ipa'); p.add_argument('root')
    p = sub.add_parser('put'); p.add_argument('ipa'); p.add_argument('src'); p.add_argument('root'); p.add_argument('--tid', default=''); p.add_argument('--slot', default='')
    for p in sub.choices.values(): p.add_argument('--udid', default='')
    a = ap.parse_args()
    try: import pymobiledevice3  # noqa: F401
    except ImportError: raise SystemExit('pymobiledevice3 is not installed')
    if a.cmd == 'migrate': return asyncio.run(migrate_on_device(a))
    if a.cmd == 'glsync':
        games = gl_games(a.ipa)
        # an empty folder of a game that no longer records (Unrailed 2 once did, before its precompiled Godot shaders were read) would keep its card on
        # "到 iPad 上玩一下" and queue it on every library run (nxn-app.ps1 counts folders)
        if os.path.isdir(a.root):
            for n in os.listdir(a.root):
                d = os.path.join(a.root, n)
                if n.upper() not in games and os.path.isdir(d) and not os.listdir(d):
                    os.rmdir(d); print('%s：不用在 iPad 上記著色器了，拿掉空的記錄資料夾' % n)
        if not games: return 0
        work = lambda afc: gl_sync(afc, games, a.root)
    elif a.cmd == 'logs': work = lambda afc: pull_logs(afc, a.root)
    elif a.cmd == 'put':
        dest = save_dest(a.ipa, a.tid)
        if not dest:
            print('這個 App 裡沒有 %s 這款' % (a.tid or '這'))
            return NOT_IN_APP
        work = lambda afc: put(afc, a.src, a.root, dest, a.slot)
    elif a.cmd == 'backup': work = lambda afc: backup(afc, a.root, a.keep, a.tag)
    else: work = lambda afc: restore(afc, a.src, a.root)
    return asyncio.run(on_device(a, work))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    sys.exit(main())
