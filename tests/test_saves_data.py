"""python3 tests/test_saves_data.py: saves_data.py's backup and restore against a stand-in for the iPad's AFC (a local folder)."""
import asyncio
import datetime
import importlib.util
import os
import shutil
import tempfile
import unittest

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
spec = importlib.util.spec_from_file_location('saves_data', os.path.join(APP, 'saves_data.py'))
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)


class FakeAfc:
    """The few AFC calls saves_data.py makes, on a local folder standing in for the app's container."""
    def __init__(self, root): self.root = root
    def _p(self, p): return os.path.join(self.root, p.lstrip('/'))
    async def exists(self, p): return os.path.exists(self._p(p))
    async def listdir(self, p): return sorted(os.listdir(self._p(p)))
    async def stat(self, p): return {'st_ifmt': 'S_IFDIR' if os.path.isdir(self._p(p)) else 'S_IFREG'}
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


if __name__ == '__main__':
    unittest.main()
