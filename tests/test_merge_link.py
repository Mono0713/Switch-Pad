"""python3 tests/test_merge_link.py: nxn_merge.py --link and romfs_data.py on hand-made packages (no games, no device).

A linked merge must give every data folder the same id as a full merge (the iPad's Documents/.romfs-id keeps matching, so
nothing already there is sent again), carry its records through a merge of the linked IPA, and let push find each file.
"""
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
spec = importlib.util.spec_from_file_location('romfs_data', os.path.join(APP, 'romfs_data.py'))
rd = importlib.util.module_from_spec(spec); spec.loader.exec_module(rd)
MERGE = os.path.join(APP, 'nxn_merge.py')
DROP = os.path.join(APP, 'nxn_merge_drop.py')


def plist(d): return plistlib.dumps(d)


def game_ipa(path, tid, files, shell_sha='abc1234'):
    A = 'Payload/DmIOS.app/'
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(A + 'Info.plist', plist({'CFBundleIdentifier': 'org.nxnative.' + tid.lower(), 'CFBundleDisplayName': 'Game ' + tid[-4:],
                                            'CFBundleShortVersionString': '1.0', 'DMDataInDocuments': True}))
        z.writestr(A + 'DmIOS', b'shell')
        z.writestr(A + 'dm/shell_info.txt', 'MULTI=1\nSOURCE_SHA=%s\n' % shell_sha)
        z.writestr(A + 'dm/env.txt', 'DM_X=1\n')
        z.writestr(A + 'Frameworks/Guest.framework/Guest', b'guest-' + tid.encode())
        z.writestr(A + 'romfs/', b'')
        for n, data in files.items(): z.writestr(A + n, data)


def run(*args):
    r = subprocess.run([sys.executable, '-I'] + list(args), capture_output=True, text=True, encoding='utf-8')
    if r.returncode: raise AssertionError('%s failed: %s %s' % (args[:2], r.stdout, r.stderr))
    return r.stdout


class LinkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = self.tmp.name
        self.a = os.path.join(self.d, 'A-multi.ipa'); self.b = os.path.join(self.d, 'B, with comma-multi.ipa')
        game_ipa(self.a, '0100000000010000', {'romfs/data/a.bin': os.urandom(5000), 'romfs/b.txt': b'hello', 'msl/b-1/x.metallib': b'MTLB' + os.urandom(300)})
        game_ipa(self.b, '0100000000020000', {'romfs/c.bin': os.urandom(7000)})   # no msl: an empty folder record

    def tearDown(self): self.tmp.cleanup()

    def ids(self, ipa):
        with zipfile.ZipFile(ipa) as z:
            link = rd.read_link(z)
            if link is not None: return {d: r['id'] for d, r in link.items()}
            app, pl, parts, files, several = rd.layout(z)
            return {d: rd.data_id([i for i in files if i.filename.startswith(p)]) for p, d in parts}

    def test_link_matches_full(self):
        full, linked = os.path.join(self.d, 'full.ipa'), os.path.join(self.d, 'linked.ipa')
        run(MERGE, '-o', full, '--bundle-id', 'org.nxnative.games.library', self.a, self.b)
        run(MERGE, '-o', linked, '--bundle-id', 'org.nxnative.games.library', '--link', self.a, self.b)
        self.assertEqual(self.ids(full), self.ids(linked))
        with zipfile.ZipFile(linked) as z:
            names = z.namelist()
            self.assertFalse([n for n in names if '/romfs/' in n or '/msl/' in n])
            self.assertIn('Payload/DmIOS.app/games/0100000000010000/dm/env.txt', names)
            self.assertIn('Payload/DmIOS.app/Frameworks/Guest_0100000000020000.framework/Guest', names)
        info = json.loads(run(os.path.join(APP, 'romfs_data.py'), 'info', linked))
        self.assertTrue(info['linked'] and info['lite'])
        # push's file list: every data file of the full merge, under the same Documents path, same bytes
        with zipfile.ZipFile(linked) as z, zipfile.ZipFile(full) as f:
            link, app = rd.read_link(z), rd.layout(z)[0]
            srcs = rd.Sources()
            got = {dst: zz.read(i) for d in link for zz, i, dst in rd.linked_files(srcs, app, d, link[d])}
            fa, _, fparts, ffiles, _ = rd.layout(f)
            want = {rd.dest_of(fparts, i.filename): f.read(i) for i in ffiles}
            self.assertEqual(got, want)

    def test_relink_and_drop(self):
        lib, lib2, lib3 = (os.path.join(self.d, n) for n in ('lib.ipa', 'lib2.ipa', 'lib3.ipa'))
        run(MERGE, '-o', lib, '--link', self.a)
        out = run(MERGE, '-o', lib2, lib, self.b)   # the old library as an input: links by itself, carries A's record
        self.assertIn('links too', out)
        with zipfile.ZipFile(lib) as z1, zipfile.ZipFile(lib2) as z2:
            self.assertEqual(rd.read_link(z1)['games/0100000000010000/romfs'], rd.read_link(z2)['games/0100000000010000/romfs'])
        run(DROP, MERGE, '0100000000010000', '-o', lib3, lib2)
        self.assertEqual(set(self.ids(lib3)), {'games/0100000000020000/romfs', 'games/0100000000020000/msl'})

    def test_changed_source_is_refused(self):
        lib = os.path.join(self.d, 'lib.ipa')
        run(MERGE, '-o', lib, '--link', self.a, self.b)
        game_ipa(self.a, '0100000000010000', {'romfs/data/a.bin': b'other'})   # re-converted after the merge
        with zipfile.ZipFile(lib) as z:
            link, app = rd.read_link(z), rd.layout(z)[0]
            with self.assertRaises(SystemExit):
                rd.linked_files(rd.Sources(), app, 'games/0100000000010000/romfs', link['games/0100000000010000/romfs'])

    def test_lite_of_linked_is_a_copy(self):
        lib, lite = os.path.join(self.d, 'lib.ipa'), os.path.join(self.d, 'lite.ipa')
        run(MERGE, '-o', lib, '--link', self.a, self.b)
        run(os.path.join(APP, 'romfs_data.py'), 'lite', lib, lite)
        with open(lib, 'rb') as x, open(lite, 'rb') as y: self.assertEqual(x.read(), y.read())


if __name__ == '__main__':
    unittest.main()
