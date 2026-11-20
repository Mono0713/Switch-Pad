"""python3 tests/test_layout.py: the iPad's Documents by game name (ipad_layout.py), the saves sync and backups in it
(saves_data.py), and the PC's folders (pc_layout.py), against a local folder standing in for the iPad's AFC."""
import asyncio
import datetime
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

sys.stdout.reconfigure(encoding='utf-8')
APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
sys.path.insert(0, APP)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(APP, name + '.py'))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


IL = load('ipad_layout')
sd = load('saves_data')
pcl = load('pc_layout')

T1, T2 = '0100000000010000', '010593A5182E4000'
NAMES = {T1: 'Super Mario Odyssey', T2: 'Unrailed 2: Back on Track'}


class FakeAfc:
    def __init__(self, root): self.root = root
    def _p(self, p): return os.path.join(self.root, p.lstrip('/'))
    async def exists(self, p): return os.path.exists(self._p(p))
    async def listdir(self, p): return sorted(os.listdir(self._p(p)))
    async def stat(self, p):
        q = self._p(p)
        return {'st_ifmt': 'S_IFDIR' if os.path.isdir(q) else 'S_IFREG', 'st_mtime': datetime.datetime.fromtimestamp(os.path.getmtime(q)), 'st_size': os.path.getsize(q)}
    async def get_file_contents(self, p):
        with open(self._p(p), 'rb') as f: return f.read()
    async def set_file_contents(self, p, data):
        with open(self._p(p), 'wb') as f: f.write(data)
    async def makedirs(self, p): os.makedirs(self._p(p), exist_ok=True)
    async def rm(self, p, force=False):
        q = self._p(p)
        if not os.path.exists(q): return
        shutil.rmtree(q) if os.path.isdir(q) else os.remove(q)
    async def rename(self, a, b): os.rename(self._p(a), self._p(b))


def write(path, data=b'x'):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f: f.write(data)


def read(path):
    with open(path, 'rb') as f: return f.read()


def library(path, layout=2):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('Payload/DmIOS.app/Info.plist', b'')
        z.writestr('Payload/DmIOS.app/dm/shell_info.txt', 'KIND=ios\nMULTI=1\nLAYOUT=%d\n' % layout)
        for t, n in NAMES.items(): z.writestr('Payload/DmIOS.app/games/%s/game.json' % t, json.dumps({'id': t, 'name': n}))
    return path


NOW = datetime.datetime(2026, 11, 20, 12, 0, 0)


class Names(unittest.TestCase):
    def test_folder_name(self):
        self.assertEqual(IL.folder_name('Unrailed 2: Back on Track'), 'Unrailed 2 Back on Track')
        self.assertEqual(IL.folder_name('Puyo Puyo™ Tetris® 2'), 'Puyo Puyo Tetris 2')
        self.assertEqual(IL.folder_name('The Legend of Zelda: Tears of the Kingdom'), 'The Legend of Zelda Tears of the Kingdom')
        self.assertEqual(IL.folder_name(' a/b?. '), 'a b?'.replace('?', ' ').strip())
        self.assertEqual(IL.folder_name('...', 'X'), 'X')

    def test_shell_layout(self):
        with tempfile.TemporaryDirectory() as t:
            self.assertEqual(IL.shell_layout(library(os.path.join(t, 'a.ipa'), 2)), 2)
            self.assertEqual(IL.shell_layout(library(os.path.join(t, 'b.ipa'), 1)), 1)
            self.assertEqual(IL.game_names(os.path.join(t, 'a.ipa'))[T2], NAMES[T2])


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dev = os.path.join(self.tmp, 'dev'); self.docs = os.path.join(self.dev, 'Documents')
        os.makedirs(self.docs)
        self.afc = FakeAfc(self.dev)
        self.ipa = library(os.path.join(self.tmp, '遊戲庫.ipa'))
        self.games = os.path.join(self.tmp, '遊戲'); self.root = os.path.join(self.tmp, '備份')
        self.g1 = os.path.join(self.games, 'Super Mario Odyssey'); os.makedirs(os.path.join(self.g1, T1 + '_pack'))
        write(os.path.join(self.docs, '系統', 'layout.txt'), b'2\n')
        write(os.path.join(self.docs, '系統', 'folders.json'), json.dumps({'games': {T1: 'Super Mario Odyssey'}}).encode())

    def tearDown(self): shutil.rmtree(self.tmp)
    def run_(self, c): return asyncio.run(c)
    def ipad(self, *p): return os.path.join(self.docs, '存檔', 'Super Mario Odyssey', *p)
    def pc(self, *p): return os.path.join(self.g1, '存檔', *p)
    def sync(self, now=NOW):
        return self.run_(sd.sync(self.afc, self.ipa, self.games, self.root, now=now))


class Paths(Base):
    def test_keys_map_to_game_names(self):
        L = self.run_(IL.IPad.load(self.afc, NAMES))
        self.assertTrue(L.v2)
        self.assertEqual(L.key('games/%s/romfs/a/b' % T1), '/Documents/遊戲資料/Super Mario Odyssey/romfs/a/b')
        self.assertEqual(L.key('games/%s/msl' % T2), '/Documents/遊戲資料/Unrailed 2 Back on Track/msl')   # a game new to the iPad
        self.assertEqual(L.sys('.romfs-id'), '/Documents/系統/.romfs-id')
        self.run_(L.save_folders())
        j = json.loads(read(os.path.join(self.docs, '系統', 'folders.json')))
        self.assertEqual(j['games'][T2], 'Unrailed 2 Back on Track')

    def test_old_layout_keeps_old_paths(self):
        shutil.rmtree(os.path.join(self.docs, '系統'))
        L = self.run_(IL.IPad.load(self.afc, NAMES))
        self.assertFalse(L.v2)
        self.assertEqual(L.key('games/%s/romfs' % T1), '/Documents/games/%s/romfs' % T1)
        self.assertEqual(L.sys('.romfs-id'), '/Documents/.romfs-id')

    def test_back_to_old_layout(self):
        write(os.path.join(self.docs, '遊戲資料', 'Super Mario Odyssey', 'romfs', 'f'), b'data')
        write(self.ipad('第一份', 'a.sav'), b'1'); write(self.ipad('第二份', 'a.sav'), b'2')
        write(self.ipad('.裝置存檔', '第二份', 'd'), b'dev')
        write(self.ipad('.存檔.json'), json.dumps({'active': '第二份', 'order': ['第一份', '第二份']}).encode())
        write(os.path.join(self.docs, '著色器紀錄', 'Super Mario Odyssey', 'aaaaaaaaaaaaaaaa.spv'), b's')
        write(os.path.join(self.docs, '記錄', 'log.txt'), b'l'); write(os.path.join(self.docs, '記錄', 'Super Mario Odyssey.crash.txt'), b'c')
        write(os.path.join(self.docs, '系統', '.romfs-id'), b'{}')
        self.run_(IL.to_old(self.afc))
        d = self.docs
        self.assertEqual(read(os.path.join(d, 'games', T1, 'romfs', 'f')), b'data')
        self.assertEqual(read(os.path.join(d, 'save', T1, 'a.sav')), b'2')            # the save in use where the old shell reads it
        self.assertEqual(read(os.path.join(d, 'save', T1 + '_device', 'd')), b'dev')
        self.assertEqual(read(os.path.join(d, 'save', T1 + '.slots', '2', 'save', 'a.sav')), b'1')
        slots = json.loads(read(os.path.join(d, 'save', T1 + '.slots', 'slots.json')))
        self.assertEqual([s['name'] for s in slots['slots']], ['第二份', '第一份'])
        self.assertTrue(os.path.isfile(os.path.join(d, 'vk_capture', T1, 'aaaaaaaaaaaaaaaa.spv')))
        self.assertTrue(os.path.isfile(os.path.join(d, 'logs', T1 + '.crash.txt')))
        self.assertTrue(os.path.isfile(os.path.join(d, 'log.txt')))
        self.assertTrue(os.path.isfile(os.path.join(d, '.romfs-id')))
        self.assertFalse(os.path.exists(os.path.join(d, '系統', 'layout.txt')))


class Sync(Base):
    def test_new_saves_both_ways_then_quiet(self):
        write(self.ipad('存檔 1', 'game.sav'), b'ipad')
        write(self.ipad('.存檔.json'), json.dumps({'active': '存檔 1'}).encode())
        write(self.pc('從朋友那邊', 'game.sav'), b'friend')
        self.assertEqual(self.sync(), 0)
        self.assertEqual(read(self.pc('存檔 1', 'game.sav')), b'ipad')
        self.assertEqual(read(self.ipad('從朋友那邊', 'game.sav')), b'friend')
        self.assertIn('從朋友那邊', json.loads(read(self.ipad('.存檔.json')))['order'])
        n = len(sd.backups(self.root))
        self.assertEqual(self.sync(NOW + datetime.timedelta(seconds=5)), 0)
        self.assertEqual(len(sd.backups(self.root)), n)   # nothing changed: no new backup

    def test_one_side_changed(self):
        write(self.ipad('A', 'x'), b'1'); self.sync()
        write(self.ipad('A', 'x'), b'2'); self.sync(NOW + datetime.timedelta(seconds=1))
        self.assertEqual(read(self.pc('A', 'x')), b'2')
        write(self.pc('A', 'x'), b'3'); self.sync(NOW + datetime.timedelta(seconds=2))
        self.assertEqual(read(self.ipad('A', 'x')), b'3')
        kept = [d for d in os.listdir(os.path.join(self.g1, '存檔備份')) if 'iPad版被取代前' in d]
        self.assertTrue(kept)   # the iPad's copy it replaced

    def test_both_changed_keeps_both(self):
        write(self.ipad('A', 'x'), b'1'); self.sync()
        write(self.ipad('A', 'x'), b'ipad'); write(self.pc('A', 'x'), b'pc')
        self.sync(NOW + datetime.timedelta(seconds=1))
        self.assertEqual(read(self.pc('A', 'x')), b'ipad')
        self.assertEqual(read(self.pc('A（電腦版）', 'x')), b'pc')
        self.assertEqual(read(self.ipad('A（電腦版）', 'x')), b'pc')

    def test_delete_follows_but_not_the_save_in_use(self):
        write(self.ipad('A', 'x'), b'1'); write(self.ipad('B', 'x'), b'2')
        write(self.ipad('.存檔.json'), json.dumps({'active': 'A'}).encode())
        self.sync()
        shutil.rmtree(self.pc('B'))
        self.sync(NOW + datetime.timedelta(seconds=1))
        self.assertFalse(os.path.exists(self.ipad('B')))          # deleted on the PC: deleted on the iPad
        write(self.pc('D', 'x'), b'4'); self.sync(NOW + datetime.timedelta(seconds=1, microseconds=5))
        shutil.rmtree(self.pc('A'))
        self.sync(NOW + datetime.timedelta(seconds=1, microseconds=9))
        self.assertTrue(os.path.isdir(self.ipad('A')))            # in use: kept, and back on the PC
        self.assertTrue(os.path.isdir(self.pc('A')))
        self.assertTrue(any('刪除前' in d for d in os.listdir(os.path.join(self.g1, '存檔備份'))))
        shutil.rmtree(self.ipad('A')); write(self.ipad('C', 'x'), b'3')
        write(self.ipad('.存檔.json'), json.dumps({'active': 'C'}).encode())
        self.sync(NOW + datetime.timedelta(seconds=2))
        self.assertFalse(os.path.exists(self.pc('A')))            # deleted on the iPad: moved to 存檔備份 on the PC
        self.assertTrue(any('iPad已刪除' in d for d in os.listdir(os.path.join(self.g1, '存檔備份'))))

    def test_rename_follows(self):
        write(self.ipad('A', 'x'), b'1'); write(self.ipad('.存檔.json'), json.dumps({'active': 'A'}).encode()); self.sync()
        os.rename(self.pc('A'), self.pc('主線'))
        self.sync(NOW + datetime.timedelta(seconds=1))
        self.assertTrue(os.path.isdir(self.ipad('主線'))); self.assertFalse(os.path.exists(self.ipad('A')))
        self.assertEqual(json.loads(read(self.ipad('.存檔.json')))['active'], '主線')
        os.rename(self.ipad('主線'), self.ipad('二周目'))
        write(self.ipad('.存檔.json'), json.dumps({'active': '二周目'}).encode())
        self.sync(NOW + datetime.timedelta(seconds=2))
        self.assertTrue(os.path.isdir(self.pc('二周目'))); self.assertFalse(os.path.exists(self.pc('主線')))

    def test_busy_save_is_not_replaced(self):
        write(self.ipad('A', 'x'), b'1'); write(self.ipad('.存檔.json'), json.dumps({'active': 'A'}).encode()); self.sync()
        write(self.pc('A', 'x'), b'pc'); write(self.ipad('A.work', 'x'), b'playing')
        self.assertEqual(self.sync(NOW + datetime.timedelta(seconds=1)), sd.SYNC_PARTIAL)
        self.assertEqual(read(self.ipad('A', 'x')), b'1')
        os.rename(self.ipad('A.work'), self.tmp + '/gone')
        self.sync(NOW + datetime.timedelta(seconds=2))
        self.assertEqual(read(self.ipad('A', 'x')), b'pc')

    def test_whole_side_lost_is_not_a_deletion(self):
        write(self.ipad('A', 'x'), b'1'); write(self.ipad('B', 'x'), b'2'); self.sync()
        shutil.rmtree(os.path.join(self.g1, '存檔'))
        self.sync(NOW + datetime.timedelta(seconds=1))
        self.assertTrue(os.path.isdir(self.ipad('B'))); self.assertTrue(os.path.isdir(self.pc('B')))

    def test_old_saves_waiting_for_the_shell(self):
        write(os.path.join(self.docs, 'save', T1, 'x'), b'old')
        self.assertEqual(self.sync(), sd.SYNC_PARTIAL)

    def test_status(self):
        write(self.ipad('A', 'x'), b'1'); self.sync()
        write(self.pc('A', 'x'), b'2'); write(self.ipad('B', 'x'), b'3')
        out = os.path.join(self.tmp, 's.json')
        self.run_(sd.status(self.afc, self.ipa, self.games, out))
        g = json.loads(read(out))[0]
        st = {s['name']: s['state'] for s in g['saves']}
        self.assertEqual(st, {'A': 'pc-newer', 'B': 'only-ipad'})
        self.assertEqual(g['game'], 'Super Mario Odyssey')


class BackupPut(Base):
    def test_backup_looks_like_the_ipad_and_restores(self):
        write(self.ipad('A', 'x'), b'1'); write(self.ipad('A.work', 'x'), b'skip')
        b = self.run_(sd.backup(self.afc, self.root, tag='before-sync', now=NOW))
        self.assertEqual(os.path.basename(b), '2026-11-20 12.00.00 同步前')
        self.assertEqual(read(os.path.join(b, 'Super Mario Odyssey', 'A', 'x')), b'1')
        self.assertFalse(os.path.exists(os.path.join(b, 'Super Mario Odyssey', 'A.work')))
        write(self.ipad('A', 'x'), b'2')
        self.run_(sd.restore(self.afc, b, self.root, now=NOW + datetime.timedelta(seconds=1)))
        self.assertEqual(read(self.ipad('A', 'x')), b'1')

    def test_put_as_new_save_and_replace(self):
        src = os.path.join(self.tmp, 'export'); write(os.path.join(src, 'x'), b'e')
        write(self.ipad('A', 'x'), b'1'); write(self.ipad('.存檔.json'), json.dumps({'active': 'A'}).encode())
        self.run_(sd.put(self.afc, src, self.root, 'save/' + T1, slot='朋友的', now=NOW, tid=T1, names=NAMES))
        self.assertEqual(read(self.ipad('朋友的', 'x')), b'e')
        self.assertEqual(read(self.ipad('A', 'x')), b'1')
        self.run_(sd.put(self.afc, src, self.root, 'save/' + T1, now=NOW + datetime.timedelta(seconds=1), tid=T1, names=NAMES))
        self.assertEqual(read(self.ipad('A', 'x')), b'e')


class PcFolders(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(); r = self.r = os.path.join(self.tmp, 'Switch PAD')
        os.makedirs(os.path.join(r, '程式', 'work')); os.makedirs(os.path.join(r, '合包'))
        library(os.path.join(r, '合包', '遊戲庫.ipa'))
        write(os.path.join(r, '合包', 'GL著色器', T2, 'k.keys'))
        write(os.path.join(r, '合包', '存檔備份', '遊戲庫', '20261101-012757', 'save', T1, 'x'))
        write(os.path.join(r, '合包', 'iPad記錄', '20261101-000000', 'log.txt'))
        os.makedirs(os.path.join(r, '程式', 'backup-before-abc'))
        g = os.path.join(r, '遊戲', 'Unrailed 2 Back on Track')
        write(os.path.join(g, 'Unrailed 2 [010593A5182E4000] [v1.0.0].xci'), b'game')
        write(os.path.join(g, 'Unrailed 2 Back on Track-multi-f1.ipa'))
        os.makedirs(os.path.join(g, T2 + '_pack', 'logs')); os.makedirs(os.path.join(g, T2 + '_shader_cache'))
        write(os.path.join(g, '存檔', '存檔 1', 'x'))
        write(os.path.join(g, '我的筆記.txt'))
        o = os.path.join(r, '遊戲', 'Mario Odyssey')
        write(os.path.join(o, 'Super Mario Odyssey [0100000000010000][v0].nsp'), b'smo')
        write(os.path.join(o, 'Super Mario Odyssey [0100000000010800][v262144].nsp'))
        write(os.path.join(o, 'NSZ原檔', 'a.nsz'))
        self.old_nsp = os.path.join(o, 'Super Mario Odyssey [0100000000010000][v0].nsp')
        with open(os.path.join(r, '程式', 'work', 'app-settings.json'), 'w', encoding='utf-8') as f:
            json.dump({'Want': [o, g]}, f, ensure_ascii=False)
        pcl._moves = None

    def tearDown(self): shutil.rmtree(self.tmp)

    def test_migrate(self):
        r = self.r
        self.assertEqual(pcl.migrate(r, out=lambda *_: None), 0)
        j = lambda *p: os.path.join(r, *p)
        self.assertTrue(os.path.isfile(j('遊戲庫', '遊戲庫.ipa')))
        self.assertTrue(os.path.isfile(j('備份', 'iPad存檔', '20261101-012757', 'save', T1, 'x')))
        self.assertTrue(os.path.isfile(j('記錄', 'iPad記錄', '20261101-000000', 'log.txt')))
        self.assertTrue(os.path.isdir(j('程式', '舊版', 'backup-before-abc')))
        u = j('遊戲', 'Unrailed 2 Back on Track')
        self.assertTrue(os.path.isfile(os.path.join(u, 'Unrailed 2 [010593A5182E4000] [v1.0.0].xci')))
        self.assertTrue(os.path.isfile(os.path.join(u, 'Unrailed 2 Back on Track-multi-f1.ipa')))
        self.assertTrue(os.path.isdir(os.path.join(u, T2 + '_pack')))
        self.assertTrue(os.path.isfile(os.path.join(u, '著色器紀錄', 'k.keys')))
        self.assertTrue(os.path.isfile(os.path.join(u, '我的筆記.txt')))          # a person's own file stays
        self.assertTrue(os.path.isfile(os.path.join(u, '存檔', '存檔 1', 'x')))
        s = j('遊戲', 'Super Mario Odyssey')                                       # renamed to the game's name
        self.assertTrue(os.path.isfile(os.path.join(s, 'NSZ原檔', 'a.nsz')))
        self.assertFalse(os.path.exists(j('合包')))
        with open(j('程式', 'work', 'app-settings.json'), encoding='utf-8') as f: want = json.load(f)['Want']
        self.assertEqual(want[0], s)
        # a path recorded before (a package's romfs.source.json) is found where it went
        self.assertEqual(pcl.moved(self.old_nsp, r), os.path.normcase(os.path.join(s, os.path.basename(self.old_nsp))))
        self.assertEqual(pcl.plan(r), [])   # done once

    def test_undo(self):
        r = self.r; j = lambda *p: os.path.join(r, *p)
        with open(j('程式', 'work', 'app-settings.json'), encoding='utf-8') as f: before = json.load(f)
        pcl.migrate(r, out=lambda *_: None)
        self.assertEqual(pcl.undo(r, out=lambda *_: None), 0)
        self.assertTrue(os.path.isfile(j('合包', '遊戲庫.ipa')))
        self.assertTrue(os.path.isfile(j('合包', 'GL著色器', T2, 'k.keys')))
        self.assertTrue(os.path.isfile(j('合包', '存檔備份', '遊戲庫', '20261101-012757', 'save', T1, 'x')))
        self.assertTrue(os.path.isfile(self.old_nsp))
        self.assertTrue(os.path.isdir(j('程式', 'backup-before-abc')))
        self.assertFalse(os.path.exists(j('遊戲庫')))
        with open(j('程式', 'work', 'app-settings.json'), encoding='utf-8') as f: self.assertEqual(json.load(f), before)

    def test_busy_waits(self):
        write(os.path.join(self.r, '程式', 'work', 'status', 'run-1.json'), json.dumps({'state': 'running', 'pid': os.getpid()}).encode())
        self.assertEqual(pcl.migrate(self.r, out=lambda *_: None), 4)
        self.assertTrue(os.path.isdir(os.path.join(self.r, '合包')))


class DesktopInbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(); r = os.path.join(self.tmp, 'Switch PAD')
        self.g1 = os.path.join(r, '遊戲', 'Super Mario Odyssey'); self.g2 = os.path.join(r, '遊戲', 'Unrailed 2 Back on Track')
        write(os.path.join(self.g1, 'smo [0100000000010000][v0].nsp')); write(os.path.join(self.g2, 'u [010593A5182E4000].xci'))
        write(os.path.join(self.g1, '存檔', '存檔 1', 'f'), b'old')
        self.pairs = [(T1, self.g1), (T2, self.g2)]
        self.inbox = os.path.join(self.tmp, '存檔'); self.seen = os.path.join(r, '程式', 'work', sd.INBOX_SEEN)

    def tearDown(self): shutil.rmtree(self.tmp)

    def run_(self):
        return sd.import_inbox(self.inbox, self.pairs, NAMES, self.seen, out=lambda *_: None)

    def test_sorts_by_name_and_title_id(self):
        i = self.inbox
        write(os.path.join(i, 'Super Mario Odyssey', 'game.bin'), b'a')                # the save itself, named by game
        write(os.path.join(i, 'JKSV', 'Unrailed 2', 'user - 2026', 'save.dat'), b'b')   # JKSV: <game>/<save>/
        write(os.path.join(i, '0100000000010000', '0', 'x.bin'), b'c')                 # Ryujinx-like: <title ID>/0/
        write(os.path.join(i, '不知道哪款', 'x'), b'd')
        n, unknown = self.run_()
        self.assertEqual(n, 3)
        got = {n: sorted(os.listdir(os.path.join(self.g1, '存檔', n))) for n in os.listdir(os.path.join(self.g1, '存檔'))}
        self.assertEqual(sorted(got.values()), [['f'], ['game.bin'], ['x.bin']])
        self.assertEqual(sorted(got), ['存檔 1', '桌面存檔', '桌面存檔 (2)'])
        self.assertEqual(read(os.path.join(self.g2, '存檔', 'user - 2026', 'save.dat')), b'b')
        self.assertEqual(unknown, ['不知道哪款'])
        self.assertEqual(read(os.path.join(self.g1, '存檔', '存檔 1', 'f')), b'old')     # nothing replaced

    def test_real_desktop_folder(self):
        names = {'0100000000010000': 'Super Mario Galaxy', '010099C022B96000': 'Super Mario Galaxy 2', '01004D300C5AE000': 'Kirby and the Forgotten Land',
                 '01007E3006DDA000': 'Kirby Star Allies', '01006A800016E000': 'Super Smash Bros. Ultimate', '0100F2C0115B6000': 'The Legend of Zelda: Tears of the Kingdom'}
        r = os.path.join(self.tmp, 'Switch PAD', '遊戲')
        pairs = [(t, os.path.join(r, IL.folder_name(n))) for t, n in names.items()]
        i = self.inbox
        for f in ('file0', 'file1', 'system'): write(os.path.join(i, 'Kirby and the Forgotten Land', f))
        write(os.path.join(i, 'Kirby Star Allies True Files', 'savedata.dat'))
        write(os.path.join(i, 'New Super Mario Bros. U Deluxe', 'rp_savedata.dat'))
        for g in ('Super Mario Galaxy', 'Super Mario Galaxy 2'):
            write(os.path.join(i, g, 'MarioGalaxy', 'GameData.bin'), g.encode()); write(os.path.join(i, g, '.dbi_save_info.ini')); write(os.path.join(i, g, '.dbi_save_extra'))
        write(os.path.join(i, 'Super Smash Bros. Ultimate', 'system_data.bin')); write(os.path.join(i, 'Super Smash Bros. Ultimate', 'mii', 'a'))
        z = os.path.join(i, 'The Legend of Zelda  Tears of the Kingdom')
        write(os.path.join(z, 'option.sav')); write(os.path.join(z, 'slot_00', 'progress.sav')); write(os.path.join(z, 'album', 'a'))
        b = os.path.join(i, 'The Legend of Zelda Breath of the Wild')
        write(os.path.join(b, 'option.sav')); write(os.path.join(b, '0', 'game_data.sav')); write(os.path.join(b, 'edizon_save_metadata.json'))
        n, unknown = sd.import_inbox(i, pairs, names, self.seen, out=lambda *_: None)
        self.assertEqual(sorted(unknown), ['New Super Mario Bros. U Deluxe', 'The Legend of Zelda Breath of the Wild'])
        self.assertEqual(n, 6)
        g = dict(pairs)
        def save(t): d = os.path.join(g[t], '存檔'); return {x: sorted(sd.clean_files(os.path.join(d, x))) for x in os.listdir(d)}
        self.assertEqual(save('0100000000010000'), {'桌面存檔': ['MarioGalaxy/GameData.bin']})
        self.assertEqual(read(os.path.join(g['010099C022B96000'], '存檔', '桌面存檔', 'MarioGalaxy', 'GameData.bin')), b'Super Mario Galaxy 2')
        self.assertFalse(os.path.exists(os.path.join(g['0100000000010000'], '存檔', '桌面存檔', '.dbi_save_info.ini')))
        self.assertEqual(save('01007E3006DDA000'), {'Kirby Star Allies True Files': ['savedata.dat']})
        self.assertEqual(save('01006A800016E000'), {'桌面存檔': ['mii/a', 'system_data.bin']})
        self.assertEqual(save('0100F2C0115B6000'), {'桌面存檔': ['album/a', 'option.sav', 'slot_00/progress.sav']})
        self.assertEqual(save('01004D300C5AE000'), {'桌面存檔': ['file0', 'file1', 'system']})

    def test_once_only(self):
        write(os.path.join(self.inbox, 'Super Mario Odyssey', 'game.bin'), b'a')
        self.assertEqual(self.run_()[0], 1)
        shutil.rmtree(os.path.join(self.g1, '存檔', '桌面存檔'))   # deleted later (on the iPad, then by the sync)
        self.assertEqual(self.run_()[0], 0)

    def test_same_files_already_there(self):
        write(os.path.join(self.inbox, 'Super Mario Odyssey', 'f'), b'old')
        self.assertEqual(self.run_()[0], 0)


if __name__ == '__main__':
    unittest.main()
