"""Where things are in the game library's Documents on the iPad, for the tools that read and write it over AFC (romfs_data.py,
saves_data.py, PadSwitch's sync).

A shell whose dm/shell_info.txt says LAYOUT=2 (ns2ios-shell docs/FOLDERS.zh-TW.md, dm/ios/Sources/main.m layout_prepare) names
everything by game, so a person can find their way in the Files app:

  遊戲資料/<game>/romfs, msl          was games/<title ID>/
  存檔/<game>/<save name>/             was save/<title ID> (the save in use) and save/<title ID>.slots/<n>/save
  存檔/<game>/.裝置存檔/<save name>/    was save/<title ID>_device and .slots/<n>/device
  存檔/<game>/.存檔.json               {"active": "<save name>", "order": [...]}; was .slots/slots.json
  著色器紀錄/<game>/                   was gl_capture/, vk_capture/, glslc_capture/, shader_used/ <title ID>/
  記錄/                               was log.txt, log.prev.txt and logs/ (<title ID>.txt became <game>.txt)
  系統/                               temp/, pso/, .romfs-id, .romfs-files/, env.txt, game-order.json, folders.json, layout.txt

<game> is folder_name() of the game's name (game.json), recorded per title ID in 系統/folders.json. The shell moves an old
layout over at launch (renames only) and writes 系統/layout.txt; until then the iPad still has the old one, and these tools
use whichever the iPad has (IPad.load). A shell from before LAYOUT=2 being installed on an iPad that has the new layout (the
rollback to the previous shell) needs the old one back: to_old() moves everything back, again by renames only.
"""
import json
import posixpath
import re
import zipfile

DATA, SAVE, SHADERS, LOGS, SYS = '遊戲資料', '存檔', '著色器紀錄', '記錄', '系統'
DEVICE, STATE, TITLEID = '.裝置存檔', '.存檔.json', '.titleid'
CAPTURE_KINDS = (('gl_capture', ('.vert', '.frag')), ('vk_capture', ('.spv',)), ('shader_used', ('.keys',)), ('glslc_capture', ()))
SYS_FILES = ('temp', 'pso', '.romfs-id', '.romfs-files', 'env.txt', 'game-order.json')
TID = re.compile(r'^[0-9A-Fa-f]{16}$')


def folder_name(raw, fallback=''):
    """A name made a folder name that Windows takes as well (main.m shell_folder_name is the same rule): ™ ® © dropped, a colon
    and any character Windows refuses become a space, runs of white space one space, no dot or space at either end."""
    s = ''.join(' ' if (ord(c) < 0x20 or c in ':\\/*?"<>|') else c for c in raw if c not in '™®©')
    s = ' '.join(s.split()).strip('.').strip()
    return s or fallback


def shell_layout(ipa):
    """LAYOUT in the package's dm/shell_info.txt: 2 for a shell that names Documents by game, else 1"""
    try:
        with zipfile.ZipFile(ipa) as z:
            n = next((n for n in z.namelist() if re.match(r'Payload/[^/]+\.app/dm/shell_info\.txt$', n)), None)
            txt = z.read(n).decode('utf-8', 'replace') if n else ''
    except (OSError, zipfile.BadZipFile): return 1
    m = re.search(r'^LAYOUT=(\d+)', txt, re.M)
    return int(m.group(1)) if m else 1


def game_names(ipa):
    """{title ID: name} of the games in a package (games/<title ID>/game.json)"""
    out = {}
    with zipfile.ZipFile(ipa) as z:
        for n in z.namelist():
            m = re.match(r'Payload/[^/]+\.app/games/([0-9A-Fa-f]{16})/game\.json$', n)
            if not m: continue
            try: out[m.group(1).upper()] = str(json.loads(z.read(n).decode('utf-8')).get('name') or m.group(1))
            except ValueError: out[m.group(1).upper()] = m.group(1).upper()
    return out


async def _read_json(afc, p):
    try:
        if await afc.exists(p): return json.loads((await afc.get_file_contents(p)).decode('utf-8'))
    except (ValueError, UnicodeDecodeError): pass
    return None


async def _listdir(afc, p):
    try:
        if not await afc.exists(p): return []
        return [n for n in await afc.listdir(p) if n not in ('.', '..', '')]
    except Exception: return []


async def _isdir(afc, p):
    try: return (await afc.stat(p)).get('st_ifmt') == 'S_IFDIR'
    except Exception: return False


class IPad:
    """One app's Documents, in the layout it has now"""
    def __init__(self, afc, base, v2, folders, names=None):
        self.afc, self.base, self.v2, self.folders = afc, base, v2, folders
        self.names = names or {}   # title ID → game name, from the package (for a game the iPad has no folder for yet)
        self.dirty = False

    @classmethod
    async def load(cls, afc, names=None):
        base = '/Documents' if await afc.exists('/Documents') else ''
        v2 = await afc.exists(base + '/' + SYS + '/layout.txt')
        folders = {}
        if v2:
            j = await _read_json(afc, base + '/' + SYS + '/folders.json')
            if isinstance(j, dict) and isinstance(j.get('games'), dict):
                folders = {k.upper(): v for k, v in j['games'].items() if isinstance(v, str)}
        return cls(afc, base, v2, folders, names)

    def p(self, *parts): return '/'.join([self.base] + [x for x in parts if x])

    def folder(self, tid):
        """The folder name of a title ID: the one 系統/folders.json has, else a new one the way the shell makes it"""
        tid = tid.upper()
        if tid in self.folders: return self.folders[tid]
        base = folder_name(self.names.get(tid, tid), tid)
        taken = {v.lower() for v in self.folders.values()}
        name, k = base, 2
        while name.lower() in taken: name = '%s %d' % (base, k); k += 1
        self.folders[tid] = name
        self.dirty = True
        return name

    async def save_folders(self):
        """Write 系統/folders.json when a folder was named here (a game new to the iPad), so the shell names it the same"""
        if not (self.v2 and self.dirty): return
        await self.afc.makedirs(self.p(SYS))
        await self.afc.set_file_contents(self.p(SYS, 'folders.json'), json.dumps({'layout': 2, 'games': dict(sorted(self.folders.items()))},
                                                                                 ensure_ascii=False, indent=2).encode('utf-8'))
        self.dirty = False

    # ---- paths ----
    def sys(self, name):
        """A file of the shell or the computer that nobody needs to see (.romfs-id, .romfs-files, game-order.json, env.txt)"""
        return self.p(SYS, name) if self.v2 else self.p(name)

    def key(self, k):
        """A data path as romfs_data.py records it (games/<title ID>/romfs/..., romfs/..., msl/...) on the iPad"""
        m = re.match(r'games/([0-9A-Fa-f]{16})(/.*)?$', k)
        if self.v2 and m: return self.p(DATA, self.folder(m.group(1))) + (m.group(2) or '')
        return self.p(k)

    def data(self, tid): return self.key('games/%s' % tid.upper())
    def saves(self, tid): return self.p(SAVE, self.folder(tid)) if self.v2 else None
    def shaders(self, tid): return self.p(SHADERS, self.folder(tid)) if self.v2 else None
    def logs(self): return self.p(LOGS) if self.v2 else self.base
    def game_logs(self): return self.p(LOGS) if self.v2 else self.p('logs')
    def log_name(self, tid): return self.folder(tid) if self.v2 else tid.upper()

    async def tid_of_folder(self, top, name):
        """The title ID a game folder under 遊戲資料/ 存檔/ 著色器紀錄/ is for: folders.json, else its .titleid"""
        for t, n in self.folders.items():
            if n == name: return t
        try:
            t = (await self.afc.get_file_contents(self.p(top, name, TITLEID))).decode('utf-8').strip().upper()
            return t if TID.match(t) else None
        except Exception: return None


# ---- one game's saves, new layout ----
async def save_names(afc, g):
    """The saves of one game (存檔/<game>/): its folders, except hidden ones and a save in use's .work / .new; in the order
    .存檔.json has, then by name (main.m shell_save_names)"""
    out = []
    for n in await _listdir(afc, g):
        if n.startswith('.') or n.endswith(('.work', '.new')): continue
        if await _isdir(afc, g + '/' + n): out.append(n)
    st = await _read_json(afc, g + '/' + STATE) or {}
    order = st.get('order') if isinstance(st.get('order'), list) else []
    return sorted(out, key=lambda n: (order.index(n) if n in order else len(order), n.lower()))


async def save_in_use(afc, g):
    st = await _read_json(afc, g + '/' + STATE) or {}
    a = st.get('active') if isinstance(st.get('active'), str) else None
    names = await save_names(afc, g)
    return a if a in names else (names[0] if names else None)


async def write_state(afc, g, active=None, add=()):
    """Update 存檔/<game>/.存檔.json: the save in use, and new saves at the end of the order"""
    st = await _read_json(afc, g + '/' + STATE) or {}
    if not isinstance(st, dict): st = {}
    order = [n for n in st.get('order', []) if isinstance(n, str)] if isinstance(st.get('order'), list) else []
    for n in add:
        if n not in order: order.append(n)
    st['order'] = order
    if active: st['active'] = active
    await afc.makedirs(g)
    await afc.set_file_contents(g + '/' + STATE, json.dumps(st, ensure_ascii=False, indent=2).encode('utf-8'))


def free_name(want, taken):
    """A save name as a folder name no other save has (SaveSlots.swift freeName): ' (2)', ' (3)', ..."""
    base = folder_name(want, '存檔')[:60]
    low = {t.lower() for t in taken}
    n, k = base, 2
    while n.lower() in low: n = '%s (%d)' % (base, k); k += 1
    return n


# ---- back to the old layout (a shell from before LAYOUT=2 installed again) ----
async def _move(afc, a, b, notes):
    if not await afc.exists(a): return False
    if await afc.exists(b):
        notes.append('沒搬（目的地已有）：%s' % a); return False
    await afc.makedirs(posixpath.dirname(b))
    await afc.rename(a, b)
    return True


async def to_old(afc, notes=None):
    """Move the new layout back to the old one, for a shell that only knows the old (rollback). Renames only. Returns the notes."""
    notes = [] if notes is None else notes
    L = await IPad.load(afc)
    if not L.v2: return notes
    by_name = {v: k for k, v in L.folders.items()}
    async def tid(top, n):
        return by_name.get(n) or await L.tid_of_folder(top, n)
    for n in await _listdir(afc, L.p(DATA)):
        t = await tid(DATA, n)
        if t and await _move(afc, L.p(DATA, n), L.p('games', t), notes):
            if await afc.exists(L.p('games', t, TITLEID)): await afc.rm(L.p('games', t, TITLEID), force=True)
            notes.append('遊戲資料/%s → games/%s' % (n, t))
    for n in await _listdir(afc, L.p(SAVE)):
        t = await tid(SAVE, n)
        if not t: continue
        g = L.p(SAVE, n)
        names = await save_names(afc, g)
        act = await save_in_use(afc, g)
        slots = {'active': 1, 'slots': []}
        k = 1
        for s in ([act] if act else []) + [x for x in names if x != act]:
            if s == act:
                await _move(afc, g + '/' + s, L.p('save', t), notes)
                await _move(afc, g + '/' + DEVICE + '/' + s, L.p('save', t + '_device'), notes)
                slots['slots'].append({'id': 1, 'name': s})
            else:
                k += 1
                await _move(afc, g + '/' + s, L.p('save', t + '.slots', str(k), 'save'), notes)
                await _move(afc, g + '/' + DEVICE + '/' + s, L.p('save', t + '.slots', str(k), 'device'), notes)
                slots['slots'].append({'id': k, 'name': s})
        if len(slots['slots']) > 1:
            await afc.makedirs(L.p('save', t + '.slots'))
            await afc.set_file_contents(L.p('save', t + '.slots', 'slots.json'), json.dumps(slots, ensure_ascii=False, indent=2).encode('utf-8'))
        notes.append('存檔/%s → save/%s（%d 份）' % (n, t, len(slots['slots'])))
    for n in await _listdir(afc, L.p(SHADERS)):
        t = await tid(SHADERS, n)
        if not t: continue
        for f in await _listdir(afc, L.p(SHADERS, n)):
            if f.startswith('.'): continue
            kind = next((k for k, ext in CAPTURE_KINDS if f.endswith(ext) and ext), 'glslc_capture')
            await _move(afc, L.p(SHADERS, n, f), L.p(kind, t, f), notes)
    for f in await _listdir(afc, L.p(LOGS)):
        if f in ('log.txt', 'log.prev.txt'): await _move(afc, L.p(LOGS, f), L.p(f), notes); continue
        stem = next((by_name[v] + f[len(v):] for v in sorted(by_name, key=len, reverse=True) if f.startswith(v + '.')), f)
        await _move(afc, L.p(LOGS, f), L.p('logs', stem), notes)
    for f in SYS_FILES:
        await _move(afc, L.p(SYS, f), L.p(f), notes)
    await afc.rm(L.p(SYS, 'layout.txt'), force=True)
    notes.append('iPad 資料夾改回舊版殼看得懂的樣子')
    return notes
