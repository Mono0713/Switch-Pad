"""python3 tests/test_icon_read.py: icon_read.py on hand-made NSP / XCI / NSZ files (no real keys or games involved)."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
sys.path.insert(0, APP)
spec = importlib.util.spec_from_file_location('icon_read', os.path.join(APP, 'icon_read.py'))
ir = importlib.util.module_from_spec(spec); spec.loader.exec_module(ir)
kc = ir.kc

HEADER_KEY = bytes(range(32))
KAK = bytes(range(0x40, 0x50))
TITLEKEK = bytes(range(0x60, 0x70))
CONTENT_KEY = bytes(range(0x80, 0x90))
RIGHTS = bytes.fromhex('0100000000001000' '0000000000000000')
JPG = b'\xff\xd8\xff\xe0' + os.urandom(3000) + b'\xff\xd9'
KEYS = 'header_key = %s\nkey_area_key_application_00 = %s\ntitlekek_00 = %s\n' % (HEADER_KEY.hex(), KAK.hex(), TITLEKEK.hex())


def p32(v): return v.to_bytes(4, 'little')
def p64(v): return v.to_bytes(8, 'little')


def ecb_encrypt(key, data):
    rk = kc._expand(key)
    return b''.join(kc._encrypt(rk, data[o:o + 16]) for o in range(0, len(data), 16))


def romfs(files):
    meta, blob = b'', b''
    for name, data in files:
        n = name.encode()
        e = p32(0) + p32(0xFFFFFFFF) + p64(len(blob)) + p64(len(data)) + p32(0xFFFFFFFF) + p32(len(n)) + n
        meta += e + bytes(-len(e) % 4)
        blob += data + bytes(-len(data) % 16)
    head_len = 0x50
    meta_off = head_len
    data_off = (meta_off + len(meta) + 15) & ~15
    h = p64(0x50) + p64(meta_off) + p64(0) + p64(meta_off) + p64(0) + p64(meta_off) + p64(0) + p64(meta_off) + p64(len(meta)) + p64(data_off)
    out = h + meta
    return out + bytes(data_off - len(out)) + blob


def control_nca(files=None, rights=False, ctype=2, gen=0):
    level5 = 0x200                       # the RomFS sits after some (fake) hash levels
    body = bytes(level5) + romfs(files or [('control.nacp', bytes(0x4000)), ('icon_AmericanEnglish.dat', JPG)])
    body += bytes(-len(body) % 0x200)
    start = 0x4000
    h = bytearray(0xC00)
    h[0x200:0x204] = b'NCA3'; h[0x205] = ctype; h[0x206] = gen; h[0x207] = 0
    h[0x240:0x244] = p32(start // 0x200); h[0x244:0x248] = p32((start + len(body)) // 0x200)
    fs = bytearray(0x200)
    fs[0:2] = (2).to_bytes(2, 'little'); fs[2] = 0; fs[3] = 3; fs[4] = 3
    fs[8:12] = b'IVFC'; fs[0x14:0x18] = p32(7)
    fs[0x18 + 5 * 0x18:0x18 + 5 * 0x18 + 8] = p64(level5)
    fs[0x140:0x148] = bytes.fromhex('0102030405060708')
    h[0x400:0x600] = fs
    if rights: h[0x230:0x240] = RIGHTS
    else: h[0x320:0x330] = ecb_encrypt(KAK, CONTENT_KEY)
    enc = ir.ctr_crypt(CONTENT_KEY, bytes(fs[0x140:0x148][::-1]), start, body)
    return kc.xts(bytes(h), HEADER_KEY, encrypt=True) + bytes(start - 0xC00) + enc


def other_nca(ctype):
    h = bytearray(0xC00); h[0x200:0x204] = b'NCA3'; h[0x205] = ctype
    return kc.xts(bytes(h), HEADER_KEY, encrypt=True) + bytes(0x200)


def ticket():
    t = bytearray(0x2C0)
    t[0x180:0x190] = ecb_encrypt(TITLEKEK, CONTENT_KEY)
    return bytes(t)


def pfs0(items):
    strtab, entries, data = b'', b'', b''
    for name, body in items:
        entries += p64(len(data)) + p64(len(body)) + p32(len(strtab)) + bytes(4)
        strtab += name.encode() + b'\0'; data += body
    strtab += bytes(-(0x10 + len(entries) + len(strtab)) % 0x20)
    return b'PFS0' + p32(len(items)) + p32(len(strtab)) + bytes(4) + entries + strtab + data


def hfs0(items, base=0):
    strtab, entries, data = b'', b'', b''
    for name, body in items:
        entries += p64(len(data)) + p64(len(body)) + p32(len(strtab)) + p32(0) + bytes(8) + bytes(32)
        strtab += name.encode() + b'\0'; data += body
    return b'HFS0' + p32(len(items)) + p32(len(strtab)) + bytes(4) + entries + strtab + data


def xci(items):
    secure = hfs0(items)
    root_off = 0xF000
    # the root HFS0 holds the secure partition; its data starts right after its own header
    root_head_len = len(hfs0([('secure', b'')]))
    root = hfs0([('secure', secure)])
    assert len(root) == root_head_len + len(secure)
    h = bytearray(root_off)
    h[0x100:0x104] = b'HEAD'; h[0x130:0x138] = p64(root_off)
    return bytes(h) + root


class Read(unittest.TestCase):
    def run_on(self, blob, keys=KEYS, ext='.nsp'):
        with tempfile.TemporaryDirectory() as d:
            game, kp, out = os.path.join(d, 'g' + ext), os.path.join(d, 'prod.keys'), os.path.join(d, 'icon.jpg')
            with open(game, 'wb') as f: f.write(blob)
            with open(kp, 'w') as f: f.write(keys)
            p = subprocess.run([sys.executable, '-I', os.path.join(APP, 'icon_read.py'), kp, game, out], capture_output=True, text=True)
            r = json.loads(p.stdout)
            got = None
            if os.path.exists(out):
                with open(out, 'rb') as f: got = f.read()
            self.assertEqual(p.returncode, 0 if r['result'] == 'ok' else 2)
            self.assertNotIn(HEADER_KEY.hex(), p.stdout + p.stderr)
            return r, got

    def test_nsp_key_area(self):
        r, got = self.run_on(pfs0([('a.nca', other_nca(0)), ('b.cnmt.nca', other_nca(1)), ('c.nca', control_nca())]))
        self.assertEqual(r['result'], 'ok'); self.assertEqual(got, JPG)

    def test_nsp_ticket(self):
        r, got = self.run_on(pfs0([('c.nca', control_nca(rights=True)), (RIGHTS.hex() + '.tik', ticket())]))
        self.assertEqual(r['result'], 'ok'); self.assertEqual(got, JPG)

    def test_xci(self):
        r, got = self.run_on(xci([('a.nca', other_nca(0)), ('c.nca', control_nca())]), ext='.xci')
        self.assertEqual(r['result'], 'ok'); self.assertEqual(got, JPG)

    def test_other_language(self):
        r, got = self.run_on(pfs0([('c.nca', control_nca([('icon_Japanese.dat', JPG)]))]))
        self.assertEqual(r['result'], 'ok'); self.assertEqual(got, JPG)

    def test_derived_titlekek(self):
        mk, src = bytes(range(0xA0, 0xB0)), bytes(range(0xB0, 0xC0))
        global TITLEKEK
        old = TITLEKEK
        TITLEKEK = ir.ecb_decrypt(mk, src)
        try:
            keys = 'header_key = %s\nmaster_key_00 = %s\ntitlekek_source = %s\n' % (HEADER_KEY.hex(), mk.hex(), src.hex())
            r, got = self.run_on(pfs0([('c.nca', control_nca(rights=True)), (RIGHTS.hex() + '.tik', ticket())]), keys)
        finally:
            TITLEKEK = old
        self.assertEqual(r['result'], 'ok'); self.assertEqual(got, JPG)

    def test_ncz_stored_blocks(self):
        nca = control_nca()
        plain = nca[:0x4000]
        rest = ir.ctr_crypt(CONTENT_KEY, bytes.fromhex('0807060504030201'), 0x4000, nca[0x4000:])   # NCZ keeps the data decrypted
        sect = b'NCZSECTN' + p64(1) + p64(0x4000) + p64(len(rest)) + p64(3) + p64(0) + CONTENT_KEY + bytes(16)
        exp = 14; bs = 1 << exp
        blocks = [rest[o:o + bs] for o in range(0, len(rest), bs)]
        blk = b'NCZBLOCK' + bytes([2, 1, 0, exp]) + p32(len(blocks)) + p64(len(rest)) + b''.join(p32(len(b)) for b in blocks) + b''.join(blocks)
        r, got = self.run_on(pfs0([('c.ncz', plain + sect + blk)]), ext='.nsz')
        self.assertEqual(r['result'], 'ok'); self.assertEqual(got, JPG)

    def test_wrong_header_key(self):
        r, got = self.run_on(pfs0([('c.nca', control_nca())]), 'header_key = %s\n' % bytes(32).hex())
        self.assertEqual(r['result'], 'wrong_header_key'); self.assertIsNone(got)

    def test_missing_key_named_not_valued(self):
        r, got = self.run_on(pfs0([('c.nca', control_nca(gen=5))]))
        self.assertEqual(r['result'], 'missing_key:key_area_key_application_04'); self.assertIsNone(got)

    def test_not_a_game(self):
        r, got = self.run_on(b'hello' * 100)
        self.assertEqual(r['result'], 'not_a_game_file')


class PlainPython(unittest.TestCase):
    """The same reads with keys_check's own AES, for a Python without pycryptodome or cryptography."""
    def setUp(self): self.saved, ir._ECB = ir._ECB, None
    def tearDown(self): ir._ECB = self.saved

    def read(self, blob):
        with tempfile.TemporaryDirectory() as d:
            g = os.path.join(d, 'g.nsp')
            with open(g, 'wb') as f: f.write(blob)
            return ir.read_icon(kc.parse_keys(KEYS), g)

    def test_key_area(self): self.assertEqual(self.read(pfs0([('c.nca', control_nca())])), JPG)
    def test_ticket(self): self.assertEqual(self.read(pfs0([('c.nca', control_nca(rights=True)), (RIGHTS.hex() + '.tik', ticket())])), JPG)


if __name__ == '__main__':
    unittest.main()
