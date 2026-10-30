"""Check prod.keys against a game's files before packing, so a key that is too old says so in a second, not minutes in.

Ported from NX2Apple's KeyCheck.swift (LNPANDY/NX2Apple, MIT, see NOTICE): the first 0x400 bytes of each NCA in an NSP are
its header, encrypted with header_key (AES-128-XTS), and the header names the key generation the content needs. A key the
file lacks is named, never its value; key values are never printed or written anywhere.

  keys_check.py <prod.keys> <file.nsp> [<file.nsp> ...]

Prints one JSON line {"result": ..., "file": ..., "missing": ..., "generation": ..., "firmware": ...} and exits 0 when the keys
fit (or the file cannot be checked here: an XCI, an NSZ), 2 when they do not. Pure standard library, so it runs on the same
Python as the packer.
"""
import json
import os
import sys

# The firmware that brought each master key revision (hactool's table), for telling someone what to dump the keys from.
FIRMWARE = ['1.0.0', '3.0.0', '3.0.1', '4.0.0', '5.0.0', '6.0.0', '6.2.0', '7.0.0', '8.1.0', '9.0.0',
            '9.1.0', '12.1.0', '13.0.0', '14.0.0', '15.0.0', '16.0.0', '17.0.0', '18.0.0', '19.0.0', '20.0.0']
HEADER_BYTES = 0x400

# ---------------------------------------------------------------- AES-128 (only a few blocks per NCA, so plain Python is fast enough)
_SBOX = [0] * 256
_INV = [0] * 256


def _init_sbox():
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)          # p * 3
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xFF                 # q / 3
        if q & 0x80: q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) & 0xFF ^ ((q << 2) | (q >> 6)) & 0xFF ^ ((q << 3) | (q >> 5)) & 0xFF ^ ((q << 4) | (q >> 4)) & 0xFF
        x = (x ^ 0x63) & 0xFF
        _SBOX[p] = x; _INV[x] = p
        if p == 1: break
    _SBOX[0] = 0x63; _INV[0x63] = 0


_init_sbox()


def _xt(a): return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a = _xt(a); b >>= 1
    return r


def _expand(key):
    w = list(key)
    rc = 1
    for i in range(16, 176, 4):
        t = w[i - 4:i]
        if i % 16 == 0:
            t = [_SBOX[t[1]] ^ rc, _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
            rc = _xt(rc)
        w += [w[i - 16 + j] ^ t[j] for j in range(4)]
    return [w[r * 16:r * 16 + 16] for r in range(11)]


def _encrypt(rk, b):
    s = [b[i] ^ rk[0][i] for i in range(16)]
    for r in range(1, 11):
        s = [_SBOX[x] for x in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]                # ShiftRows (column-major state)
        if r != 10:
            m = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                m += [_xt(a[0]) ^ _xt(a[1]) ^ a[1] ^ a[2] ^ a[3], a[0] ^ _xt(a[1]) ^ _xt(a[2]) ^ a[2] ^ a[3],
                      a[0] ^ a[1] ^ _xt(a[2]) ^ _xt(a[3]) ^ a[3], _xt(a[0]) ^ a[0] ^ a[1] ^ a[2] ^ _xt(a[3])]
            s = m
        s = [s[i] ^ rk[r][i] for i in range(16)]
    return bytes(s)


def _decrypt(rk, b):
    s = [b[i] ^ rk[10][i] for i in range(16)]
    for r in range(9, -1, -1):
        s = [s[(i - 4 * (i % 4)) % 16] for i in range(16)]                # InvShiftRows
        s = [_INV[x] for x in s]
        s = [s[i] ^ rk[r][i] for i in range(16)]
        if r:
            m = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                m += [_mul(a[0], 14) ^ _mul(a[1], 11) ^ _mul(a[2], 13) ^ _mul(a[3], 9),
                      _mul(a[0], 9) ^ _mul(a[1], 14) ^ _mul(a[2], 11) ^ _mul(a[3], 13),
                      _mul(a[0], 13) ^ _mul(a[1], 9) ^ _mul(a[2], 14) ^ _mul(a[3], 11),
                      _mul(a[0], 11) ^ _mul(a[1], 13) ^ _mul(a[2], 9) ^ _mul(a[3], 14)]
            s = m
    return bytes(s)


def xts_sector(data, data_key, tweak_key, tweak, encrypt=False):
    """One sector of AES-128-XTS with a given 16-byte tweak block."""
    dk, tk = _expand(data_key), _expand(tweak_key)
    t = bytearray(_encrypt(tk, tweak))
    out = bytearray()
    for o in range(0, len(data), 16):
        x = bytes(a ^ b for a, b in zip(data[o:o + 16], t))
        y = _encrypt(dk, x) if encrypt else _decrypt(dk, x)
        out += bytes(a ^ b for a, b in zip(y, t))
        carry = 0                                                          # multiply the tweak by x in GF(2^128), little-endian
        for j in range(16):
            c = t[j] >> 7; t[j] = (t[j] << 1 | carry) & 0xFF; carry = c
        if carry: t[0] ^= 0x87
    return bytes(out)


def xts(data, key, sector=0, sector_size=0x200, encrypt=False):
    """Nintendo's XTS for NCA headers: the 32-byte key is data key then tweak key, the tweak is the sector number big-endian."""
    out = bytearray()
    for i, o in enumerate(range(0, len(data), sector_size)):
        out += xts_sector(data[o:o + sector_size], key[:16], key[16:32], (sector + i).to_bytes(16, 'big'), encrypt)
    return bytes(out)

# ---------------------------------------------------------------- prod.keys and NCA headers


def parse_keys(text):
    """`name = hex` lines, names lowercased; comments, blank lines and values that are not hex are skipped."""
    keys = {}
    for line in text.splitlines():
        name, eq, value = line.partition('=')
        if not eq: continue
        try: keys[name.strip().lower()] = bytes.fromhex(value.strip())
        except ValueError: pass
    return keys


def has(key, keys):
    """A derived key counts when it is in the file or its master key is (LibHac derives titlekek and key area keys)."""
    if len(keys.get(key, b'')) == 16: return True
    return len(keys.get('master_key_' + key.rsplit('_', 1)[-1], b'')) == 16


def needs(h):
    """(master key revision, key name) a decrypted NCA header needs; None when it is not an NCA header (wrong key)."""
    if len(h) < HEADER_BYTES or h[0x200:0x204] not in (b'NCA3', b'NCA2'): return None
    gen = max(h[0x206], h[0x220])
    rev = gen - 1 if gen else 0
    if any(h[0x230:0x240]): return rev, 'titlekek_%02x' % rev               # a rights ID: the ticket's title key
    area = ('application', 'ocean', 'system')
    if h[0x207] >= len(area): return None
    return rev, 'key_area_key_%s_%02x' % (area[h[0x207]], rev)


def nca_headers(path):
    """The encrypted headers of an NSP's NCAs as [(header, is NCZ)]; None for anything that is not a PFS0 (XCI)."""
    try:
        with open(path, 'rb') as f:
            head = f.read(0x10)
            if len(head) < 0x10 or head[:4] != b'PFS0': return None
            count, names = int.from_bytes(head[4:8], 'little'), int.from_bytes(head[8:12], 'little')
            if not 0 < count <= 4096 or names > 1 << 20: return None
            table = f.read(count * 0x18 + names)
            start = 0x10 + len(table)
            out = []
            for i in range(count):
                e = i * 0x18
                off, size = int.from_bytes(table[e:e + 8], 'little'), int.from_bytes(table[e + 8:e + 16], 'little')
                at = count * 0x18 + int.from_bytes(table[e + 16:e + 20], 'little')
                if at >= len(table): continue
                name = table[at:].split(b'\0', 1)[0].decode('utf-8', 'replace').lower()
                if not name.endswith(('.nca', '.ncz')) or size < HEADER_BYTES: continue
                f.seek(start + off)
                h = f.read(HEADER_BYTES)
                if len(h) == HEADER_BYTES: out.append((h, name.endswith('.ncz')))
            return out
    except OSError:
        return None


def check(keys, files):
    """files = [(name, headers or None)]. The worst finding wins: a header key that opens nothing, then the newest missing
    generation, then a file that cannot be checked here."""
    hk = keys.get('header_key')
    if not hk: return {'result': 'no_header_key'}
    worst, unchecked = None, None
    for name, ncas in files:
        if not ncas: unchecked = unchecked or name; continue
        opened = [n for n in (needs(xts(h, hk)) if len(hk) == 32 else None for h, _ in ncas) if n]
        if not opened:
            if all(z for _, z in ncas): unchecked = unchecked or name; continue
            return {'result': 'wrong_header_key', 'file': name}
        for rev, key in opened:
            if not has(key, keys) and (worst is None or rev > worst[0]): worst = (rev, key, name)
    if worst:
        rev, key, name = worst
        r = {'result': 'too_old', 'file': name, 'missing': key, 'generation': rev + 1}
        if rev < len(FIRMWARE): r['firmware'] = FIRMWARE[rev]
        return r
    if unchecked: return {'result': 'cannot_check', 'file': unchecked}
    return {'result': 'fits'}


def main(argv):
    if len(argv) < 2: raise SystemExit(__doc__)
    try:
        with open(argv[0], 'rb') as f: raw = f.read()
    except OSError:
        r = {'result': 'unreadable_keys'}
    else:
        text = raw.decode('utf-8', 'replace')
        r = check(parse_keys(text), [(os.path.basename(p), nca_headers(p)) for p in argv[1:]])
    print(json.dumps(r, ensure_ascii=False))
    return 2 if r['result'] in ('too_old', 'wrong_header_key', 'no_header_key', 'unreadable_keys') else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
