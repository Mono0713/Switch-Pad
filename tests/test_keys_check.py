"""python3 tests/test_keys_check.py: keys_check.py on hand-made NSPs (no real keys or games involved)."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
spec = importlib.util.spec_from_file_location('keys_check', os.path.join(APP, 'keys_check.py'))
kc = importlib.util.module_from_spec(spec); spec.loader.exec_module(kc)

HEADER_KEY = bytes(range(32))


def nca_header(gen, rights=False, area=0):
    h = bytearray(kc.HEADER_BYTES)
    h[0x200:0x204] = b'NCA3'
    h[0x206] = 0; h[0x207] = area; h[0x220] = gen
    if rights: h[0x230:0x240] = b'\x01' * 16
    return kc.xts(bytes(h), HEADER_KEY, encrypt=True)


def nsp(path, headers, names=None):
    names = names or ['%d.nca' % i for i in range(len(headers))]
    strtab, offs = b'', []
    for n in names: offs.append(len(strtab)); strtab += n.encode() + b'\0'
    data, entries = b'', b''
    for h, o in zip(headers, offs):
        body = h + bytes(0x100)
        entries += len(data).to_bytes(8, 'little') + len(body).to_bytes(8, 'little') + o.to_bytes(4, 'little') + bytes(4)
        data += body
    with open(path, 'wb') as f:
        f.write(b'PFS0' + len(headers).to_bytes(4, 'little') + len(strtab).to_bytes(4, 'little') + bytes(4) + entries + strtab + data)


class AES(unittest.TestCase):
    def test_fips197(self):
        rk = kc._expand(bytes(range(16)))
        self.assertEqual(kc._encrypt(rk, bytes.fromhex('00112233445566778899aabbccddeeff')).hex(), '69c4e0d86a7b0430d8cdb78070b4c55a')

    def test_ieee1619_vector1(self):
        self.assertEqual(kc.xts_sector(bytes(32), bytes(16), bytes(16), bytes(16), True).hex(),
                         '917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e')

    def test_against_cryptography(self):
        try:
            from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        except ImportError:
            self.skipTest('cryptography not installed')
        key, data = bytes(range(1, 33)), os.urandom(0x200)
        tweak = (5).to_bytes(16, 'big')
        e = Cipher(algorithms.AES(key), modes.XTS(tweak)).encryptor()
        self.assertEqual(kc.xts(data, key, sector=5, encrypt=True), e.update(data) + e.finalize())


class Check(unittest.TestCase):
    def run_on(self, keys_text, headers, names=None):
        with tempfile.TemporaryDirectory() as d:
            k, p = os.path.join(d, 'prod.keys'), os.path.join(d, 'game.nsp')
            with open(k, 'w') as f: f.write(keys_text)
            nsp(p, headers, names)
            r = subprocess.run([sys.executable, '-I', os.path.join(APP, 'keys_check.py'), k, p], capture_output=True, text=True)
            return r.returncode, json.loads(r.stdout)

    keys = 'header_key = %s\ntitlekek_00 = %s\nkey_area_key_application_00 = %s\nmaster_key_01 = %s\n' % (
        HEADER_KEY.hex(), '11' * 16, '22' * 16, '33' * 16)

    def test_fits(self):
        self.assertEqual(self.run_on(self.keys, [nca_header(0, True), nca_header(2)]), (0, {'result': 'fits'}))

    def test_master_key_counts(self):
        self.assertEqual(self.run_on(self.keys, [nca_header(2, True)])[1]['result'], 'fits')   # titlekek_01 from master_key_01

    def test_too_old(self):
        code, r = self.run_on(self.keys, [nca_header(0), nca_header(0x13, True)])
        self.assertEqual(code, 2)
        self.assertEqual(r, {'result': 'too_old', 'file': 'game.nsp', 'missing': 'titlekek_12', 'generation': 19, 'firmware': '19.0.0'})
        self.assertNotIn('33' * 16, json.dumps(r))

    def test_wrong_header_key(self):
        bad = self.keys.replace(HEADER_KEY.hex(), 'ab' * 32)
        self.assertEqual(self.run_on(bad, [nca_header(0)]), (2, {'result': 'wrong_header_key', 'file': 'game.nsp'}))

    def test_no_header_key(self):
        self.assertEqual(self.run_on('titlekek_00 = ' + '11' * 16, [nca_header(0)])[1]['result'], 'no_header_key')

    def test_ncz_and_xci_are_not_judged(self):
        self.assertEqual(self.run_on(self.keys.replace(HEADER_KEY.hex(), 'ab' * 32), [nca_header(0)], ['0.ncz'])[1]['result'], 'cannot_check')
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'cart.xci')
            with open(p, 'wb') as f: f.write(b'\0' * 0x200 + b'HEAD')
            self.assertEqual(kc.check(kc.parse_keys(self.keys), [('cart.xci', kc.nca_headers(p))]), {'result': 'cannot_check', 'file': 'cart.xci'})


if __name__ == '__main__':
    unittest.main()
