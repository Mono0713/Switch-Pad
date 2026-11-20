"""PadSwitch's folders on the PC (ns2ios-shell docs/FOLDERS.zh-TW.md), and the one-time move from the old ones.

  遊戲/<game>/                 the player's game files (.nsp .nsz .xci; the packer reads only this folder's first level, so they stay
                               here) and what packing makes beside them: <title ID>_pack, <title ID>_shader_cache, *-multi-*.ipa
  遊戲/<game>/存檔/<save>/      the saves, the same folders as the iPad's 存檔/<game>/<save>/ (saves_data.py sync)
  遊戲/<game>/存檔備份/         this game's saves before they were replaced or deleted
  遊戲/<game>/著色器紀錄/        what the iPad recorded for the next pack (was 合包/GL著色器/<title ID>)
  遊戲庫/                      遊戲庫.ipa (was 合包/)
  備份/iPad存檔/                every save on the iPad before something changed them (was 合包/存檔備份/遊戲庫/)
  記錄/iPad記錄/, 記錄/問題回報/   (were 合包/iPad記錄/ and 問題回報/)
  程式/舊版/                    the program's backups before an update (were 程式/backup-before-*, _backup-*)

<game> is the game's name the way the iPad names its folders (ipad_layout.folder_name of game.json's name), so a game is
found under the same name on both. Anything else a person put in a game folder (a save from somewhere, a DLC folder, notes)
stays where it is.

  pc_layout.py plan    <Switch PAD folder>      what migrate would move, one line each
  pc_layout.py migrate <Switch PAD folder>      move it (refused while a pack or transfer runs: work/status)

Every move is a rename on the same disk (a game folder renamed to its game's name included). The moves are recorded in 程式/work/搬家紀錄.json, and moved() turns a path recorded
before the move (a game package's romfs.source.json naming its NSP, a library linked to its game packages) into where it is
now. Paths in 程式/work/app-settings.json, installed.json and pack-times.json are rewritten.
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ipad_layout  # noqa: E402

GAMES, SRC, SAVES, SAVE_BACKUPS, SHADERS, OUT = '遊戲', '原始檔', '存檔', '存檔備份', '著色器紀錄', '轉檔結果'
LIBRARY, BACKUPS, IPAD_SAVES, LOGS, IPAD_LOGS, REPORTS = '遊戲庫', '備份', os.path.join('備份', 'iPad存檔'), '記錄', os.path.join('記錄', 'iPad記錄'), os.path.join('記錄', '問題回報')
PROGRAM, OLD = '程式', os.path.join('程式', '舊版')
GAME_FILES = ('.nsp', '.nsz', '.xci', '.xcz', '.nup')
MOVES = os.path.join(PROGRAM, 'work', '搬家紀錄.json')
TID = re.compile(r'(?<![0-9A-Fa-f])(0[14][0-9A-Fa-f]{14})(?![0-9A-Fa-f])')


def root_of_program():
    """The Switch PAD folder: this file is in 程式/"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


_moves = None


def moved(path, root=None):
    """Where a path recorded before the move is now (itself when it exists, or no move covers it)"""
    global _moves
    if not path or os.path.exists(path): return path
    if _moves is None:
        _moves = []
        try:
            with open(os.path.join(root or root_of_program(), MOVES), encoding='utf-8') as f:
                _moves = [(os.path.normcase(os.path.normpath(a)), b) for a, b in json.load(f).get('moves', [])]
        except (OSError, ValueError): pass
        _moves.sort(key=lambda m: -len(m[0]))
    p = os.path.normcase(os.path.normpath(path))
    for _ in range(4):   # a game folder renamed, then its file moved into 原始檔/: follow each
        hit = next(((a, b) for a, b in _moves if p == a or p.startswith(a + os.sep)), None)
        if not hit: break
        p = os.path.normcase(os.path.normpath(hit[1] + p[len(hit[0]):]))
        if os.path.exists(p): return p
    return path


def game_tid(folder, tids=()):
    """The title ID a game folder is for: a <title ID>_pack folder, else the title ID in its game files' names (the base
    game's: ending in 000), else 存檔待傳.txt"""
    names = []
    for d in (folder, os.path.join(folder, OUT), os.path.join(folder, SRC)):
        try: names += os.listdir(d)
        except OSError: pass
    for n in names:
        m = re.match(r'([0-9A-Fa-f]{16})_pack$', n)
        if m: return m.group(1).upper()
    found = [m.group(1).upper() for n in names if n.lower().endswith(GAME_FILES) for m in TID.finditer(n)]
    for t in found:
        if tids and t in tids: return t
    base = sorted({t[:-3] + '000' for t in found if t.endswith(('000', '800'))})   # a DLC (…1001) says nothing about the base
    if base: return base[0]
    try:
        with open(os.path.join(folder, '存檔待傳.txt'), encoding='utf-8-sig') as f:
            t = f.readline().strip().upper()
            if re.fullmatch(r'[0-9A-F]{16}', t): return t
    except OSError: pass
    return None


def library_ipa(root):
    for p in (os.path.join(root, LIBRARY, '遊戲庫.ipa'), os.path.join(root, '合包', '遊戲庫.ipa')):
        if os.path.isfile(p): return p
    return None


def known_names(root):
    """{title ID: game name} from the library and every game package"""
    names = {}
    pkgs = [library_ipa(root)]
    gd = os.path.join(root, GAMES)
    for g in sorted(os.listdir(gd)) if os.path.isdir(gd) else []:
        for d in (os.path.join(gd, g), os.path.join(gd, g, OUT)):
            try: pkgs += [os.path.join(d, n) for n in os.listdir(d) if n.lower().endswith('.ipa')]
            except OSError: pass
    for p in pkgs:
        if not p: continue
        try:
            for t, n in ipad_layout.game_names(p).items(): names.setdefault(t, n)
        except Exception: pass
    return names


def busy(root):
    """A pack, merge or transfer still running (work/status/*.json with state running and a live process)"""
    sd = os.path.join(root, PROGRAM, 'work', 'status')
    for n in os.listdir(sd) if os.path.isdir(sd) else []:
        if not n.endswith('.json'): continue
        try:
            with open(os.path.join(sd, n), encoding='utf-8-sig') as f: st = json.load(f)
        except (OSError, ValueError): continue
        if st.get('state') == 'running' and pid_alive(st.get('pid')): return n
    return None


def pid_alive(pid):
    try: pid = int(pid)
    except (TypeError, ValueError): return False
    if os.name == 'nt':
        import ctypes
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h: return False
        code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return bool(ok) and code.value == 259   # STILL_ACTIVE
    try: os.kill(pid, 0); return True
    except OSError: return False


def plan(root):
    """[(from, to)] of everything still in an old place"""
    moves = []
    j = lambda *p: os.path.join(root, *p)
    # top-level folders
    old = j('合包')
    if os.path.isdir(old):
        for n in os.listdir(old):
            if n == 'GL著色器': continue   # by game, below
            if n == 'iPad記錄': moves.append((j('合包', n), j(IPAD_LOGS)))
            elif n == '存檔備份':
                for m in os.listdir(j('合包', n)):
                    moves.append((j('合包', n, m), j(IPAD_SAVES) if m == '遊戲庫' else j(BACKUPS, m)))
            else: moves.append((j('合包', n), j(LIBRARY, n)))
    if os.path.isdir(j('問題回報')): moves.append((j('問題回報'), j(REPORTS)))
    for n in os.listdir(j(PROGRAM)) if os.path.isdir(j(PROGRAM)) else []:
        if re.match(r'_?backup-', n) and os.path.isdir(j(PROGRAM, n)): moves.append((j(PROGRAM, n), j(OLD, n)))
    for n in ('_icon', '_pr', '_tests', '__pycache__'):   # leftovers of early installs at the top
        if os.path.isdir(j(n)): moves.append((j(n), j(OLD, '頂層舊檔', n)))
    # each game
    names = known_names(root)
    gd = j(GAMES)
    taken = {n.lower() for n in os.listdir(gd)} if os.path.isdir(gd) else set()
    for g in sorted(os.listdir(gd)) if os.path.isdir(gd) else []:
        gp = os.path.join(gd, g)
        if not os.path.isdir(gp) or g.startswith(('.', '_')): continue
        tid = game_tid(gp, names)
        want = ipad_layout.folder_name(names[tid], g) if tid in names else g
        dest = gp
        if want != g and want.lower() not in taken:
            moves.append((gp, os.path.join(gd, want))); taken.add(want.lower()); dest = os.path.join(gd, want)
        if tid and os.path.isdir(j('合包', 'GL著色器', tid)):
            moves.append((j('合包', 'GL著色器', tid), os.path.join(dest, SHADERS)))
    return moves


def rewrite_paths(obj, moves):
    """Every string in a JSON value that names a moved path, pointing where it went"""
    if isinstance(obj, dict): return {k: rewrite_paths(v, moves) for k, v in obj.items()}
    if isinstance(obj, list): return [rewrite_paths(v, moves) for v in obj]
    if isinstance(obj, str):
        p = os.path.normcase(os.path.normpath(obj)) if (os.sep in obj or '/' in obj) else None
        if p:
            for a, b in moves:
                a2 = os.path.normcase(os.path.normpath(a))
                if p == a2 or p.startswith(a2 + os.sep): return b + obj[len(a):]
    return obj


def migrate(root, dry=False, out=print):
    root = os.path.abspath(root)
    b = busy(root)
    if b and not dry:
        out('有轉檔或傳送正在跑（%s），資料夾先不搬，等它結束再開一次 PadSwitch' % b)
        return 4
    moves = plan(root)
    if not moves:
        out('資料夾已經是新的樣子'); return 0
    done = []
    for a, b2 in moves:
        rel = lambda p: os.path.relpath(p, root)
        if not os.path.exists(a): continue
        if os.path.exists(b2):
            if os.path.isdir(a) and os.path.isdir(b2):   # 合包/X into an existing folder: its entries one by one
                for n in os.listdir(a):
                    if os.path.exists(os.path.join(b2, n)): out('沒搬（那裡已經有）：%s' % rel(os.path.join(a, n))); continue
                    if not dry: os.rename(os.path.join(a, n), os.path.join(b2, n))
                    done.append((os.path.join(a, n), os.path.join(b2, n)))
                if not dry:
                    try: os.rmdir(a)
                    except OSError: pass
                continue
            out('沒搬（那裡已經有）：%s → %s' % (rel(a), rel(b2))); continue
        out('%s → %s' % (rel(a), rel(b2)))
        if dry: continue
        os.makedirs(os.path.dirname(b2), exist_ok=True)
        try: os.rename(a, b2)
        except OSError as e: out('[x] 搬不動 %s：%s（可能有檔案開著）' % (rel(a), e)); continue
        done.append((a, b2))
    if dry: return 0
    old = os.path.join(root, '合包')   # what is left of it: empty folders only (anything else stays)
    for d, _, _ in sorted(os.walk(old), key=lambda w: -len(w[0])) if os.path.isdir(old) else []:
        try: os.rmdir(d)
        except OSError: pass
    for p in (os.path.join(root, LIBRARY), os.path.join(root, IPAD_SAVES), os.path.join(root, IPAD_LOGS)):
        os.makedirs(p, exist_ok=True)
    rec = os.path.join(root, MOVES)
    old = []
    try:
        with open(rec, encoding='utf-8') as f: old = json.load(f).get('moves', [])
    except (OSError, ValueError): pass
    os.makedirs(os.path.dirname(rec), exist_ok=True)
    with open(rec, 'w', encoding='utf-8') as f:
        json.dump({'updated': datetime.datetime.now().isoformat(timespec='seconds'), 'moves': old + [list(m) for m in done]}, f, ensure_ascii=False, indent=1)
    rewrite_settings(root, done)
    out('搬好了：%d 項（記錄在 %s）' % (len(done), MOVES))
    return 0


def rewrite_settings(root, moves):
    for n in ('app-settings.json', 'installed.json', 'pack-times.json'):
        p = os.path.join(root, PROGRAM, 'work', n)
        try:
            with open(p, encoding='utf-8-sig') as f: d = json.load(f)
        except (OSError, ValueError): continue
        d2 = rewrite_paths(d, moves)
        if isinstance(d2, dict) and n == 'installed.json': d2 = {rewrite_paths(k, moves): v for k, v in d2.items()}
        if d2 != d:
            with open(p + '.tmp', 'w', encoding='utf-8') as f: json.dump(d2, f, ensure_ascii=False, indent=2)
            os.replace(p + '.tmp', p)


def undo(root, out=print):
    """Put everything 搬家紀錄.json records back where it was, newest first (for going back to an older PadSwitch).
    A move whose old place is taken again, or whose new place is gone, is left as it is and named."""
    root = os.path.abspath(root)
    b = busy(root)
    if b:
        out('有轉檔或傳送正在跑（%s），等它結束再還原' % b); return 4
    rec = os.path.join(root, MOVES)
    try:
        with open(rec, encoding='utf-8') as f: moves = [tuple(m) for m in json.load(f).get('moves', [])]
    except (OSError, ValueError):
        out('沒有搬家紀錄，不用還原'); return 0
    back, left = [], []
    for a, b2 in reversed(moves):
        if not os.path.exists(b2) or os.path.exists(a):
            out('沒還原：%s → %s' % (os.path.relpath(b2, root), os.path.relpath(a, root))); left.append((a, b2)); continue
        os.makedirs(os.path.dirname(a), exist_ok=True)
        try: os.rename(b2, a)
        except OSError as e: out('[x] 搬不動 %s：%s（可能有檔案開著）' % (os.path.relpath(b2, root), e)); left.append((a, b2)); continue
        back.append((b2, a))
    for p in (os.path.join(root, IPAD_SAVES), os.path.join(root, IPAD_LOGS), os.path.join(root, LIBRARY)):
        for d, _, _ in sorted(os.walk(p), key=lambda w: -len(w[0])) if os.path.isdir(p) else []:
            try: os.rmdir(d)   # only the empty ones
            except OSError: pass
    rewrite_settings(root, back)
    with open(rec, 'w', encoding='utf-8') as f:
        json.dump({'updated': datetime.datetime.now().isoformat(timespec='seconds'), 'moves': [list(m) for m in reversed(left)]}, f, ensure_ascii=False, indent=1)
    out('還原好了：%d 項%s' % (len(back), '，%d 項沒還原' % len(left) if left else ''))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('plan', 'migrate', 'undo'): sub.add_parser(c).add_argument('root', nargs='?', default=root_of_program())
    a = ap.parse_args()
    if a.cmd == 'undo': sys.exit(undo(a.root))
    sys.exit(migrate(a.root, dry=a.cmd == 'plan'))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    main()
