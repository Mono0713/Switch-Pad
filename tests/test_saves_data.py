"""python3 tests/test_saves_data.py: saves_data.py's backup and restore against a stand-in for the iPad's AFC (a local folder)."""
import asyncio
import datetime
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest

# saves_data.py prints Chinese; run as a script it switches stdout to UTF-8 itself, imported here it does not (cp1252 on Windows)
sys.stdout.reconfigure(encoding='utf-8')

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
spec = importlib.util.spec_from_file_location('saves_data', os.path.join(APP, 'saves_data.py'))
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)


class FakeAfc:
    """The few AFC calls saves_data.py makes, on a local folder standing in for the app's container."""
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
        shutil.rmtree(q) if os.path.isdir(q) else os.remove(q)


def write(path, data=b'x'):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f: f.write(data)


def at(sec): return datetime.datetime(2026, 10, 30, 12, 0, sec)


class Saves(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dev = os.path.join(self.tmp, 'dev'); self.root = os.path.join(self.tmp, 'backups')
        self.docs = os.path.join(self.dev, 'Documents')
        write(os.path.join(self.docs, 'save', '0', 'progress.bin'), b'one')
        write(os.path.join(self.docs, 'save_device', 'common.bin'), b'dev')
        write(os.path.join(self.docs, 'save.work', 'scratch'), b'skip')
        write(os.path.join(self.docs, 'save', '0100000000010000.new', 'x'), b'skip')
        write(os.path.join(self.docs, 'romfs', 'big'), b'not a save')
        self.afc = FakeAfc(self.dev)

    def tearDown(self): shutil.rmtree(self.tmp)

    def run_(self, coro): return asyncio.run(coro)

    def test_backup_copies_saves_only(self):
        b = self.run_(sd.backup(self.afc, self.root, now=at(0)))
        self.assertEqual(os.path.basename(b), '20261030-120000')
        got = sorted(os.path.relpath(os.path.join(r, f), b).replace(os.sep, '/') for r, _, fs in os.walk(b) for f in fs)
        self.assertEqual(got, ['.digest', 'save/0/progress.bin', 'save_device/common.bin'])

    def test_unchanged_save_is_not_kept_twice(self):
        self.run_(sd.backup(self.afc, self.root, now=at(0)))
        self.assertIsNone(self.run_(sd.backup(self.afc, self.root, now=at(1))))
        write(os.path.join(self.docs, 'save', '0', 'progress.bin'), b'two')
        self.assertIsNotNone(self.run_(sd.backup(self.afc, self.root, now=at(2))))
        self.assertEqual(sd.backups(self.root), ['20261030-120000', '20261030-120002'])

    def test_keep_prunes_oldest(self):
        for i in range(4):
            write(os.path.join(self.docs, 'save', '0', 'progress.bin'), bytes([i]))
            self.run_(sd.backup(self.afc, self.root, keep=2, now=at(i)))
        self.assertEqual(sd.backups(self.root), ['20261030-120002', '20261030-120003'])

    def test_nothing_on_device(self):
        shutil.rmtree(os.path.join(self.docs, 'save')); shutil.rmtree(os.path.join(self.docs, 'save_device'))
        self.assertIsNone(self.run_(sd.backup(self.afc, self.root)))

    def test_restore_backs_up_first_and_replaces(self):
        first = self.run_(sd.backup(self.afc, self.root, now=at(0)))
        write(os.path.join(self.docs, 'save', '0', 'progress.bin'), b'newer')
        write(os.path.join(self.docs, 'save', '0', 'extra.bin'), b'gone after restore')
        self.run_(sd.restore(self.afc, first, self.root, now=at(5)))
        with open(os.path.join(self.docs, 'save', '0', 'progress.bin'), 'rb') as f: self.assertEqual(f.read(), b'one')
        self.assertFalse(os.path.exists(os.path.join(self.docs, 'save', '0', 'extra.bin')))
        self.assertFalse(os.path.exists(os.path.join(self.docs, 'save.work')))
        self.assertTrue(os.path.exists(os.path.join(self.docs, 'romfs', 'big')))
        before = os.path.join(self.root, '20261030-120005-before-restore', 'save', '0', 'progress.bin')
        with open(before, 'rb') as f: self.assertEqual(f.read(), b'newer')


A, B, C = '0100000000010000', '0100000000020000', '0100000000030000'


class Migrate(unittest.TestCase):
    """Old apps' saves collected to the computer, then put into the library's save/<title ID>/."""
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, 'backups')
        self.lib = os.path.join(self.tmp, 'lib', 'Documents')
        self.one = os.path.join(self.tmp, 'one', 'Documents')     # a one-game app of A
        self.pack = os.path.join(self.tmp, 'pack', 'Documents')   # a package of A, B and C
        write(os.path.join(self.one, 'save', '0', 'a.bin'), b'A from one')
        write(os.path.join(self.one, 'save_device', 'd.bin'), b'A device')
        write(os.path.join(self.pack, 'save', A, 'a.bin'), b'A from pack')
        write(os.path.join(self.pack, 'save', B, 'b.bin'), b'B from pack')
        write(os.path.join(self.pack, 'save', C, 'c.bin'), b'C not in library')
        os.makedirs(os.path.join(self.lib, 'save', B))   # made at the library's first start, still empty
        write(os.path.join(self.lib, 'save', 'FFFF000000000000', 'z.bin'), b'other game')

    def tearDown(self): shutil.rmtree(self.tmp)

    def age(self, path, sec):
        for r, _, fs in os.walk(path):
            for f in fs: os.utime(os.path.join(r, f), (sec, sec))

    def collect(self):
        olds = [('org.nxnative.' + A.lower(), 'Game A', A, FakeAfc(os.path.dirname(self.one))),
                ('org.nxnative.games', '合包', None, FakeAfc(os.path.dirname(self.pack)))]
        return asyncio.run(sd.collect(olds, self.root, now=at(0)))

    def place(self, overwrite=False):
        return asyncio.run(sd.place(FakeAfc(os.path.dirname(self.lib)), sd.collected(self.root), [A, B], self.root, overwrite, now=at(1)))

    def read(self, *p):
        with open(os.path.join(self.lib, *p), 'rb') as f: return f.read()

    def test_collect_then_place_after_old_apps_are_gone(self):
        self.age(self.pack, 1_000_000); self.age(self.one, 2_000_000)
        made = self.collect()
        self.assertEqual(len(made), 2)
        shutil.rmtree(os.path.dirname(self.one)); shutil.rmtree(os.path.dirname(self.pack))   # deleted from the iPad
        self.assertEqual(self.place(), [A, B])
        self.assertEqual(self.read('save', A, '0', 'a.bin'), b'A from one')     # changed last
        self.assertEqual(self.read('save', A + '_device', 'd.bin'), b'A device')
        self.assertEqual(self.read('save', B, 'b.bin'), b'B from pack')
        self.assertFalse(os.path.exists(os.path.join(self.lib, 'save', C)))
        self.assertEqual(self.read('save', 'FFFF000000000000', 'z.bin'), b'other game')
        self.assertTrue(os.path.isfile(os.path.join(made[1], 'save', C, 'c.bin')))   # kept on the computer
        self.assertTrue(os.path.isdir(os.path.join(self.root, '20261030-120001-before-migrate')))

    def test_pack_newer_wins(self):
        self.age(self.one, 1_000_000); self.age(self.pack, 2_000_000)
        self.collect(); self.place()
        self.assertEqual(self.read('save', A, 'a.bin'), b'A from pack')

    def test_library_save_kept_unless_overwrite(self):
        write(os.path.join(self.lib, 'save', A, 'mine.bin'), b'played in library')
        self.collect()
        self.assertEqual(self.place(), [B])
        self.assertEqual(self.read('save', A, 'mine.bin'), b'played in library')
        self.assertEqual(self.place(overwrite=True), [A, B])
        self.assertFalse(os.path.exists(os.path.join(self.lib, 'save', A, 'mine.bin')))

    def test_backups_list_ignores_collected(self):
        self.collect()
        self.assertEqual(sd.backups(self.root), [])

    def test_old_apps(self):
        apps = {'org.nxnative.games.library.T1': {}, 'org.nxnative.0100000000010000.T1': {'CFBundleDisplayName': 'Game A'},
                'org.nxnative.games.p1a2b3c4d.T1': {'CFBundleDisplayName': '合包'}, 'org.nxnative.games.T1': {}, 'com.other.app': {}}
        self.assertEqual(sd.old_apps(apps, 'org.nxnative.games.library'),
                         [('org.nxnative.0100000000010000.T1', 'Game A', A), ('org.nxnative.games.T1', 'org.nxnative.games.T1', None),
                          ('org.nxnative.games.p1a2b3c4d.T1', '合包', None)])


class Put(unittest.TestCase):
    """A save dropped on a game card replaces only that game's save, after a backup of the app's saves."""
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dev = os.path.join(self.tmp, 'dev'); self.root = os.path.join(self.tmp, 'backups')
        self.docs = os.path.join(self.dev, 'Documents')
        write(os.path.join(self.docs, 'save', '0100AAAA00000000', 'old.bin'), b'old')
        write(os.path.join(self.docs, 'save', '0100AAAA00000000.work', 'w'), b'w')
        write(os.path.join(self.docs, 'save', '0100BBBB00000000', 'other.bin'), b'keep')
        self.src = os.path.join(self.tmp, 'import')
        write(os.path.join(self.src, 'data', 'new.bin'), b'newnew'); write(os.path.join(self.src, 'top'), b't')
        self.afc = FakeAfc(self.dev)

    def tearDown(self): shutil.rmtree(self.tmp)

    def ipa(self, tids):
        import zipfile
        p = os.path.join(self.tmp, 'app.ipa')
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('Payload/A.app/Info.plist', b'')
            for t in tids: z.writestr('Payload/A.app/games/%s/game.json' % t, b'{}')
        return p

    def test_dest(self):
        self.assertEqual(sd.save_dest(self.ipa([]), ''), 'save')
        self.assertEqual(sd.save_dest(self.ipa(['0100aaaa00000000']), '0100AAAA00000000'), 'save/0100aaaa00000000')
        self.assertIsNone(sd.save_dest(self.ipa(['0100AAAA00000000']), '0100CCCC00000000'))

    def test_put_replaces_one_game(self):
        asyncio.run(sd.put(self.afc, self.src, self.root, 'save/0100AAAA00000000', now=at(0)))
        game = os.path.join(self.docs, 'save', '0100AAAA00000000')
        self.assertEqual(sorted(sd.local_files(game)), ['data/new.bin', 'top'])
        self.assertFalse(os.path.exists(game + '.work'))
        with open(os.path.join(self.docs, 'save', '0100BBBB00000000', 'other.bin'), 'rb') as f: self.assertEqual(f.read(), b'keep')
        b = os.path.join(self.root, sd.backups(self.root)[-1])
        self.assertTrue(b.endswith('-before-import'))
        self.assertTrue(os.path.isfile(os.path.join(b, 'save', '0100AAAA00000000', 'old.bin')))


class Logs(unittest.TestCase):
    def test_pull_and_group(self):
        tmp = tempfile.mkdtemp()
        try:
            docs = os.path.join(tmp, 'dev', 'Documents')
            write(os.path.join(docs, 'log.txt'), ('boot: game 010088100DD42000 (Roof Rage) of the games in this package\n'
                  '[RED] sf: SendSyncRequest on 0x1f (24 bytes), not a host session\n'
                  '[RED] sf: SendSyncRequest on 0x2a (32 bytes), not a host session\n'
                  '[RED] NVN unimplemented function called: nvnFoo\nordinary line\n').encode())
            write(os.path.join(docs, 'save', 'x.bin'))
            dest = asyncio.run(sd.pull_logs(FakeAfc(os.path.join(tmp, 'dev')), os.path.join(tmp, 'out'), now=at(0)))
            self.assertEqual(os.listdir(dest), ['log.txt'])
            with open(os.path.join(dest, 'log.txt'), encoding='utf-8') as f: groups, total = sd.red_summary(f.read())
            self.assertEqual(total, 2)
            self.assertEqual(groups[0][0], 2)
            self.assertIn('SendSyncRequest', groups[0][1])
        finally:
            shutil.rmtree(tmp)


class GlSync(unittest.TestCase):
    def test_games_and_sync(self):
        import zipfile
        tmp = tempfile.mkdtemp()
        try:
            ipa = os.path.join(tmp, 'lib.ipa')
            with zipfile.ZipFile(ipa, 'w') as z:
                z.writestr('Payload/DmIOS.app/games/010088100DD42000/dm/env.txt', 'DM_MEM=1\nDM_GL_CAPTURE=gl_capture/010088100DD42000\n')
                z.writestr('Payload/DmIOS.app/games/0100000000010000/dm/env.txt', 'DM_MEM=1\n')
            games = sd.gl_games(ipa)
            self.assertEqual(games, {'010088100DD42000': 'gl_capture/010088100DD42000'})
            dev = os.path.join(tmp, 'dev'); os.makedirs(os.path.join(dev, 'Documents'))
            out = os.path.join(tmp, 'out')
            self.assertEqual(asyncio.run(sd.gl_sync(FakeAfc(dev), games, out)), {'010088100DD42000': 0})
            rec = os.path.join(dev, 'Documents', 'gl_capture', '010088100DD42000')
            self.assertTrue(os.path.isdir(rec))   # made for the host to write into
            write(os.path.join(rec, '0123456789abcdef.vert'), b'#version 330')
            write(os.path.join(rec, '0123456789abcdef.vert.12.tmp'), b'partial')
            self.assertEqual(asyncio.run(sd.gl_sync(FakeAfc(dev), games, out)), {'010088100DD42000': 1})
            self.assertEqual(os.listdir(os.path.join(out, '010088100DD42000')), ['0123456789abcdef.vert'])
        finally:
            shutil.rmtree(tmp)


if __name__ == '__main__':
    unittest.main()
