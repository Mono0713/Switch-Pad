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

try: sys.stdout.reconfigure(encoding='utf-8'); sys.stderr.reconfigure(encoding='utf-8')   # push prints Chinese (romfs_data main does this too)
except Exception: pass
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

    def test_preview_fingerprints_match_the_final_linked_library(self):
        linked = os.path.join(self.d, 'linked.ipa')
        run(MERGE, '-o', linked, '--bundle-id', 'org.nxnative.games.library', '--link', self.a, self.b)
        preview = {}
        for part in (self.a, self.b):
            preview.update(rd.package_parts_size(part)['parts'])
        with zipfile.ZipFile(linked) as z:
            actual = {key: {'id': row['id'], 'bytes': row['bytes']} for key, row in rd.read_link(z).items()}
        self.assertEqual(preview, actual)

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


def fake_nx(d, romfs_files):
    """an nx_extract stand-in: `nx keys base update out` writes out/RomFS with these files (and checks its arguments)"""
    src = os.path.join(d, 'nx_src'); os.makedirs(src, exist_ok=True)
    for n, data in romfs_files.items():
        p = os.path.join(src, *n.split('/')); os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f: f.write(data)
    nx = os.path.join(d, 'nx_extract.py')   # romfs_data runs a .py with this Python (Windows has no #! line)
    with open(nx, 'w') as f:
        f.write('import sys, shutil, os\nk, b, u, o = sys.argv[1:5]\nassert os.path.isfile(b) and os.path.isfile(k)\n'
                'shutil.copytree(%r, os.path.join(o, "RomFS"))\n' % src)
    return nx


def source_ipa(path, tid, romfs_files, nsp, nx, keys, extra=None):
    """a game package as nxn_pack.py --romfs-source writes it: no romfs/, a romfs.source.json instead"""
    import zlib
    listing = sorted([n, len(b), zlib.crc32(b)] for n, b in romfs_files.items())
    rec = {'v': 1, 'tid': tid, 'version': 'v0', 'base': {'path': nsp, 'name': os.path.basename(nsp), 'size': os.path.getsize(nsp)},
           'update': None, 'allow_damaged': False, 'nx': nx, 'keys': keys, 'files': len(listing), 'bytes': sum(x[1] for x in listing), 'list': listing}
    game_ipa(path, tid, dict(extra or {}, **{'romfs.source.json': json.dumps(rec)}))
    with zipfile.ZipFile(path) as z: names = z.namelist()
    # game_ipa adds an empty romfs/ folder entry; a --romfs-source package has none
    with zipfile.ZipFile(path) as z, zipfile.ZipFile(path + '.t', 'w', zipfile.ZIP_DEFLATED) as o:
        for i in z.infolist():
            if i.filename.endswith('/romfs/'): continue
            o.writestr(i, z.read(i))
    os.replace(path + '.t', path)


class FakeAfc:
    """the app's Documents as a dict, with the AFC calls push makes"""
    def __init__(self, fs): self.fs = fs
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def exists(self, p): return p == '/Documents' or p in self.fs or any(k.startswith(p + '/') for k in self.fs)
    async def get_file_contents(self, p): return self.fs[p]
    async def get_device_info(self): return {'FSFreeBytes': 8 << 30, 'FSTotalBytes': 128 << 30}
    async def set_file_contents(self, p, b): self.fs[p] = bytes(b)
    async def rm(self, p, force=False):
        for k in [k for k in self.fs if k == p or k.startswith(p + '/')]: del self.fs[k]
    async def makedirs(self, p): pass
    async def fopen(self, p, mode): self.fs[p] = b''; return p
    async def fwrite(self, h, b): self.fs[h] += bytes(b)
    async def fclose(self, h): pass


def fake_device(fs, bundle):
    import types
    async def usbmux(serial=None):
        class Ld:
            async def __aenter__(s): return s
            async def __aexit__(s, *a): return False
            async def close(s): pass
        return Ld()
    class Ip:
        def __init__(s, lockdown=None): pass
        async def __aenter__(s): return s
        async def __aexit__(s, *a): return False
        async def get_apps(s, application_type=None): return {bundle + '.TEAM': {}}
    class Ha:
        @staticmethod
        async def create(lockdown=None, bundle_id=None, documents_only=True): return FakeAfc(fs)
    mods = {'pymobiledevice3': types.ModuleType('pymobiledevice3')}
    for name, attr, val in (('lockdown', 'create_using_usbmux', usbmux), ('services.installation_proxy', 'InstallationProxyService', Ip),
                            ('services.house_arrest', 'HouseArrestService', Ha), ('services', None, None)):
        m = mods.setdefault('pymobiledevice3.' + name, types.ModuleType('pymobiledevice3.' + name))
        if attr: setattr(m, attr, val)
    return mods


class CountingAfc(FakeAfc):
    opened = []
    async def fopen(self, p, mode): CountingAfc.opened.append(p); return await super().fopen(p, mode)


class FileDiffTest(unittest.TestCase):
    """a folder whose id changed gets only the files that differ (Documents/.romfs-files/<folder>.json)"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = self.tmp.name

    def tearDown(self): self.tmp.cleanup()

    def push(self, ipa, fs, force=False):
        import asyncio
        mods = fake_device(fs, 'org.nxnative.games.library')
        mods['pymobiledevice3.services.house_arrest'].HouseArrestService.create = staticmethod(
            lambda lockdown=None, bundle_id=None, documents_only=True: _ret(CountingAfc(fs)))
        saved = {k: sys.modules.get(k) for k in mods}
        sys.modules.update(mods)
        CountingAfc.opened = []
        try:
            class A: pass
            a = A(); a.ipa, a.udid, a.force = ipa, '', force
            asyncio.run(rd.push(a))
        finally:
            for k, v in saved.items():
                if v is None: sys.modules.pop(k, None)
                else: sys.modules[k] = v
        return [p for p in CountingAfc.opened if '/games/' in p]

    def lib(self, files, name):
        part = os.path.join(self.d, name + '-multi.ipa')
        game_ipa(part, '0100000000010000', files)
        out = os.path.join(self.d, name + '.ipa')
        run(MERGE, '-o', out, '--bundle-id', 'org.nxnative.games.library', '--link', part)
        return out

    def test_only_changed_files(self):
        v1 = {'romfs/a.bin': b'a' * 100, 'romfs/b.bin': b'b' * 100, 'msl/b-1/x_b.metallib': b'x1', 'msl/b-1/y_b.metallib': b'y1'}
        fs = {}
        sent = self.push(self.lib(v1, 'v1'), fs)
        self.assertEqual(len(sent), 4)
        v2 = {'romfs/a.bin': b'a' * 100, 'romfs/b.bin': b'b' * 100, 'msl/b-1/x_b.metallib': b'x2', 'msl/b-1/z_b.metallib': b'z'}
        sent = self.push(self.lib(v2, 'v2'), fs)
        G = '/Documents/games/0100000000010000/'
        self.assertEqual(sorted(sent), [G + 'msl/b-1/x_b.metallib', G + 'msl/b-1/z_b.metallib'])
        self.assertNotIn(G + 'msl/b-1/y_b.metallib', fs)
        self.assertEqual({k: v for k, v in fs.items() if k.startswith(G)}, {G + k: v for k, v in v2.items()})
        # --force: everything again
        self.assertEqual(len(self.push(self.lib(v2, 'v3'), fs, force=True)), 4)

    def test_low_space_leaves_the_existing_copy_untouched(self):
        from unittest.mock import AsyncMock, patch

        fs = {}
        v1 = self.lib({'romfs/old.bin': b'old', 'msl/shader': b'x'}, 'v1')
        self.push(v1, fs)
        before = dict(fs)
        v2 = self.lib({'romfs/new.bin': b'much larger data'}, 'v2')
        with patch.object(FakeAfc, 'get_device_info', AsyncMock(return_value={'FSFreeBytes': 0})):
            with self.assertRaises(SystemExit) as err:
                self.push(v2, fs)
        self.assertEqual(err.exception.code, 4)
        self.assertEqual(fs, before)
        self.assertEqual(CountingAfc.opened, [])

    def test_status_file(self):
        """push writes push-<pid>.json into NXN_STATUS_DIR for Switch Pad's 背景工作 card"""
        st = os.path.join(self.d, 'status')
        os.environ['NXN_STATUS_DIR'] = st
        try: self.push(self.lib({'romfs/a.bin': b'a' * 1000, 'msl/b-1/x_b.metallib': b'x'}, 's1'), {})
        finally: del os.environ['NXN_STATUS_DIR']
        with open(os.path.join(st, 'push-%d.json' % os.getpid()), encoding='utf-8') as f: j = json.load(f)
        self.assertEqual((j['kind'], j['state']), ('push', 'done'))
        self.assertEqual(j['sent'], j['total']); self.assertGreater(j['total'], 1000)
        self.assertEqual(sorted(os.listdir(st)), ['ipad-space.json', 'push-%d.json' % os.getpid()])

    def test_cut_short_is_redone(self):
        v1 = {'romfs/a.bin': b'a', 'msl/b-1/x_b.metallib': b'x1', 'msl/b-1/y_b.metallib': b'y1'}
        fs = {}
        self.push(self.lib(v1, 'v1'), fs)
        v2 = {'romfs/a.bin': b'a', 'msl/b-1/x_b.metallib': b'x2', 'msl/b-1/y_b.metallib': b'y2'}
        lib2 = self.lib(v2, 'v2')
        # the copy of v2 stops after its first file
        orig = FakeAfc.fclose
        n = [0]
        async def fclose(self, h):
            n[0] += 1
            if n[0] == 2: raise ValueError('cut')
        FakeAfc.fclose = fclose
        try:
            with self.assertRaises(ValueError): self.push(lib2, fs)
        finally: FakeAfc.fclose = orig
        # going back to v1 must not trust the half-written msl: both shaders are sent again
        G = '/Documents/games/0100000000010000/'
        sent = self.push(self.lib(v1, 'v1b'), fs)
        self.assertEqual(sorted(sent), [G + 'msl/b-1/x_b.metallib', G + 'msl/b-1/y_b.metallib'])
        self.assertEqual({k: v for k, v in fs.items() if k.startswith(G)}, {G + k: v for k, v in v1.items()})


async def _ret(x): return x


class RomfsSourceTest(unittest.TestCase):
    """nxn_pack.py --romfs-source: the RomFS stays in the NSP, and the library still gets it, with the same id"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = self.tmp.name
        self.files = {'data/a.bin': os.urandom(5000), 'b.txt': b'hello'}
        self.full = os.path.join(self.d, 'A-multi.ipa'); self.src = os.path.join(self.d, 'A2-multi.ipa')
        game_ipa(self.full, '0100000000010000', dict({'romfs/' + n: b for n, b in self.files.items()}, **{'msl/b-1/x.metallib': b'M'}))
        self.nsp = os.path.join(self.d, 'A [0100000000010000][v0].nsp')
        with open(self.nsp, 'wb') as f: f.write(b'PFS0 not really')
        self.keys = os.path.join(self.d, 'prod.keys')
        with open(self.keys, 'w') as f: f.write('k = 0\n')
        self.nx = fake_nx(self.d, self.files)
        source_ipa(self.src, '0100000000010000', self.files, self.nsp, self.nx, self.keys, {'msl/b-1/x.metallib': b'M'})

    def tearDown(self): self.tmp.cleanup()

    def lib(self, part, name):
        out = os.path.join(self.d, name)
        run(MERGE, '-o', out, '--bundle-id', 'org.nxnative.games.library', '--link', part)
        with zipfile.ZipFile(out) as z: return out, rd.read_link(z)

    def test_same_id_as_a_package_with_romfs(self):
        _, a = self.lib(self.full, 'full.ipa')
        lib, b = self.lib(self.src, 'src.ipa')
        self.assertEqual({d: r['id'] for d, r in a.items()}, {d: r['id'] for d, r in b.items()})
        self.assertTrue(b['games/0100000000010000/romfs'].get('source'))
        with zipfile.ZipFile(lib) as z: self.assertFalse([n for n in z.namelist() if 'romfs' in n])
        # and it is carried through a merge of the linked library
        lib2 = os.path.join(self.d, 'lib2.ipa')
        run(MERGE, '-o', lib2, lib)
        with zipfile.ZipFile(lib2) as z: self.assertEqual(rd.read_link(z), b)

    def test_merge_without_link_refuses(self):
        r = subprocess.run([sys.executable, '-I', MERGE, '-o', os.path.join(self.d, 'x.ipa'), self.src], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)

    def push(self, lib, fs):
        import asyncio
        saved = {k: sys.modules.get(k) for k in fake_device({}, '')}
        sys.modules.update(fake_device(fs, 'org.nxnative.games.library'))
        try:
            class A: pass
            a = A(); a.ipa, a.udid, a.force = lib, '', False
            asyncio.run(rd.push(a))
        finally:
            for k, v in saved.items():
                if v is None: sys.modules.pop(k, None)
                else: sys.modules[k] = v

    def test_push_extracts_checks_and_cleans_up(self):
        lib, link = self.lib(self.src, 'src.ipa')
        fs = {}
        self.push(lib, fs)
        for n, b in self.files.items(): self.assertEqual(fs['/Documents/games/0100000000010000/romfs/' + n], b)
        self.assertEqual(json.loads(fs['/Documents/.romfs-id']), {d: r['id'] for d, r in link.items()})
        self.assertFalse(os.path.exists(os.path.join(self.d, '_romfs_push_0100000000010000')))
        # an iPad that already has it (from a package with the RomFS inside): nothing is extracted or sent
        os.unlink(self.nx)
        before = dict(fs)
        self.push(lib, fs)
        self.assertEqual(fs, before)

    def test_push_refuses_a_changed_extraction(self):
        lib, _ = self.lib(self.src, 'src.ipa')
        fake_nx(os.path.join(self.d, 'other'), {'data/a.bin': os.urandom(5000), 'b.txt': b'hellO'})   # same names and sizes, other bytes
        os.replace(os.path.join(self.d, 'other', 'nx_extract.py'), self.nx)
        fs = {}
        with self.assertRaises(rd.Mismatch): self.push(lib, fs)
        self.assertNotIn('games/0100000000010000/romfs', json.loads(fs.get('/Documents/.romfs-id', b'{}')))
        self.assertFalse(os.path.exists(os.path.join(self.d, '_romfs_push_0100000000010000')))


class TransferSpaceTest(unittest.IsolatedAsyncioTestCase):
    async def test_mostly_replaced_folder_goes_whole(self):
        # 2026-11-20: 300,000 old shader files removed one request each took over an hour; most of a big folder
        # changing is now one request for the folder and a full copy
        from types import SimpleNamespace
        from unittest.mock import AsyncMock, patch
        r = rd
        folder = 'games/0100000000010000/msl'
        files = [(None, SimpleNamespace(file_size=10, CRC=i), '%s/new%d' % (folder, i)) for i in range(1000)]
        old = {'%s/old%d' % (folder, i): (10, i) for i in range(3000)}
        with patch.object(r, 'read_list', AsyncMock(return_value=old)):
            send, _, plan, _, growth, released = await r.transfer_changes(None, None, [folder], lambda _: files)
        self.assertIsNone(plan[folder])
        self.assertEqual(r.jobs_left(send[folder], ()), (1000, 10000))
        self.assertEqual(released, 30000)
        # a few removals in a big folder stay file by file
        old2 = dict(old); files2 = [(None, SimpleNamespace(file_size=10, CRC=i), '%s/old%d' % (folder, i)) for i in range(2990)]
        with patch.object(r, 'read_list', AsyncMock(return_value=old2)):
            _, _, plan2, _, _, _ = await r.transfer_changes(None, None, [folder], lambda _: files2)
        self.assertEqual(len(plan2[folder][2]), 10)

    async def test_rm_files_reports_progress(self):
        from types import SimpleNamespace
        r = rd
        gone = []
        async def rm_single(k, force=False): gone.append(k); return True
        st = SimpleNamespace(d={}, write=lambda now=False: None)
        await r.rm_files(SimpleNamespace(rm_single=rm_single), ['/a%d' % i for i in range(130)], st, 'X')
        self.assertEqual(len(gone), 130)
        self.assertEqual(st.d['phase'], '清掉被換掉的舊檔（X） 130／130')

    async def test_growth_keeps_unchanged_files_and_checks_before_deletion(self):
        from types import SimpleNamespace
        from unittest.mock import AsyncMock, patch

        r = rd
        folder = 'games/0100000000010000/romfs'
        make = lambda name, size, crc: (None, SimpleNamespace(file_size=size, CRC=crc), folder + '/' + name)
        files = [make('same', 100, 1), make('grow', 200, 2), make('shrink', 100, 3)]
        old = {folder + '/' + f: v for f, v in
               {'same': (100, 1), 'grow': (150, 9), 'shrink': (900, 9), 'removed': (32, 9)}.items()}
        with patch.object(r, 'read_list', AsyncMock(return_value=old)):
            send, _, plan, skipped, growth, released = await r.transfer_changes(None, None, [folder], lambda _: files)
        self.assertEqual(r.jobs_left(send[folder], ()), (2, 300))
        self.assertEqual(skipped, 1)
        self.assertEqual(growth, 50)
        self.assertEqual(released, 32)
        self.assertEqual(plan[folder][2], [folder + '/removed'])
        afc = SimpleNamespace(get_device_info=AsyncMock(return_value={'FSFreeBytes': (1 << 30) + 17}))
        with self.assertRaises(SystemExit) as err:
            await r.check_transfer_space(afc, 300, growth, released)
        self.assertEqual(err.exception.code, 4)
        afc.get_device_info.return_value['FSFreeBytes'] += 1
        await r.check_transfer_space(afc, 300, growth, released)
        afc.get_device_info.reset_mock()
        await r.check_transfer_space(afc, 0, 0)
        afc.get_device_info.assert_not_called()

    async def test_estimate_counts_a_legacy_size_only_when_the_installed_folder_exists(self):
        from types import SimpleNamespace
        from unittest.mock import AsyncMock, patch

        folder = 'games/0100000000010000/romfs'
        afc = SimpleNamespace(exists=AsyncMock(return_value=True))
        layout = SimpleNamespace(key=lambda folder: '/Documents/' + folder)
        with patch.object(rd, 'read_list', AsyncMock(return_value=None)):
            self.assertEqual(await rd.removable_bytes(afc, layout, {folder: 'old'}, {}, {folder: 1024}), 1024)
            afc.exists.return_value = False
            self.assertEqual(await rd.removable_bytes(afc, layout, {folder: 'old'}, {}, {folder: 1024}), 0)

    async def test_old_install_without_list_cannot_claim_space(self):
        from types import SimpleNamespace
        from unittest.mock import AsyncMock, patch

        r = rd
        folder = 'games/0100000000010000/msl'
        item = (None, SimpleNamespace(file_size=300, CRC=1), folder + '/shader')
        with patch.object(r, 'read_list', AsyncMock(return_value=None)):
            _, _, plan, _, growth, released = await r.transfer_changes(None, None, [folder], lambda _: [item])
            self.assertEqual(await r.removable_bytes(None, None, {folder: 'old'}, {}), 0)
        self.assertIsNone(plan[folder])
        self.assertEqual((growth, released), (300, 0))

    def test_split_package_parts_keep_deep_paths(self):
        import plistlib

        r = rd
        with tempfile.TemporaryDirectory() as tmp:
            file = os.path.join(tmp, 'lib.ipa')
            app = 'Payload/Test.app/'
            folder = 'games/0100000000010000/romfs'
            with zipfile.ZipFile(file, 'w') as z:
                z.writestr(app + 'Info.plist', plistlib.dumps({'DMDataInDocuments': True}))
                z.writestr(app + folder + '/folder/data', b'file')
            with zipfile.ZipFile(file) as z:
                want, jobs = r.transfer_parts(z, r.Sources())
                self.assertIn(folder, want)
                self.assertEqual([job[2] for job in jobs(folder)], [folder + '/folder/data'])


if __name__ == '__main__':
    unittest.main()
