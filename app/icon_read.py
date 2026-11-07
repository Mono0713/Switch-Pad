"""Read a game's icon straight out of its NSP / XCI / NSZ / XCZ, so a game dropped into Switch Pad shows its picture in a
second or two instead of after it has been unpacked.

Only the Control NCA is opened (it is small, a few hundred KB, and NSZ leaves it uncompressed): its header is decrypted with
header_key, its key comes from the key area or the ticket, and the icon_<language>.dat JPEG is read out of its RomFS.
Nothing else in the file is read, nothing is unpacked to disk, and key values are never printed or written anywhere.

  icon_read.py <prod.keys> <game file> <out.jpg>

Prints one JSON line {"result": "ok" | <reason>, ...} and exits 0 when out.jpg was written, 2 when it was not.
Uses pycryptodome or cryptography when one is installed (nsz brings pycryptodome) and keys_check.py's plain-Python AES when
not, so it runs on the packer's Python with nothing extra.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # keys_check.py sits next to this file (also under python -I)
import keys_check as kc  # noqa: E402

NCA_HEADER = 0xC00
CONTROL = 2
# The icon the Switch shows first for a US console; the rest in case a game has only some of them.
LANGS = ['AmericanEnglish', 'TraditionalChinese', 'Taiwanese', 'BritishEnglish', 'Japanese', 'SimplifiedChinese', 'Chinese',
         'French', 'German', 'Spanish', 'LatinAmericanSpanish', 'CanadianFrench', 'Italian', 'Dutch', 'Portuguese',
         'BrazilianPortuguese', 'Russian', 'Korean', 'Polish', 'Thai']


class Fail(Exception):
    pass

# ---------------------------------------------------------------- AES (a library when there is one, keys_check's otherwise)


def _lib():
    try:
        from Crypto.Cipher import AES as A
        return lambda k: A.new(k, A.MODE_ECB)
    except ImportError:
        pass
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        return None

    class _E:
        def __init__(self, k): self.k = k
        def encrypt(self, d): e = Cipher(algorithms.AES(self.k), modes.ECB()).encryptor(); return e.update(d) + e.finalize()
        def decrypt(self, d): e = Cipher(algorithms.AES(self.k), modes.ECB()).decryptor(); return e.update(d) + e.finalize()
    return _E


_ECB = _lib()


def ecb_decrypt(key, data):
    if _ECB: return _ECB(key).decrypt(data)
    rk = kc._expand(key)
    return b''.join(kc._decrypt(rk, data[o:o + 16]) for o in range(0, len(data), 16))


def ctr_crypt(key, ctr_hi, offset, data):
    """AES-CTR as NCAs use it: the counter is the section's 8 bytes then the byte offset in the NCA / 16, big-endian."""
    n = (len(data) + 15) // 16
    first = offset >> 4
    blocks = b''.join(ctr_hi + (first + i).to_bytes(8, 'big') for i in range(n))
    if _ECB: stream = _ECB(key).encrypt(blocks)
    else:
        rk = kc._expand(key)
        stream = b''.join(kc._encrypt(rk, blocks[o:o + 16]) for o in range(0, len(blocks), 16))
    return (int.from_bytes(data, 'big') ^ int.from_bytes(stream[:len(data)], 'big')).to_bytes(len(data), 'big')


def header_decrypt(key, data):
    if not _ECB: return kc.xts(data, key)
    dk, tk = _ECB(key[:16]), _ECB(key[16:32])
    out = bytearray()
    for s, o in enumerate(range(0, len(data), 0x200)):
        t = bytearray(tk.encrypt(s.to_bytes(16, 'big')))
        sec = data[o:o + 0x200]
        ts, x = [], bytearray()
        for b in range(0, len(sec), 16):
            ts.append(bytes(t)); x += bytes(a ^ c for a, c in zip(sec[b:b + 16], t))
            carry = 0
            for j in range(16):
                c = t[j] >> 7; t[j] = (t[j] << 1 | carry) & 0xFF; carry = c
            if carry: t[0] ^= 0x87
        y = dk.decrypt(bytes(x))
        for i, tw in enumerate(ts): out += bytes(a ^ c for a, c in zip(y[i * 16:i * 16 + 16], tw))
    return bytes(out)

# ---------------------------------------------------------------- keys


def key_for(keys, name):
    """A key from prod.keys, or derived from its master key the way LibHac does when only the sources are there."""
    k = keys.get(name)
    if k and len(k) == 16: return k
    rev = name.rsplit('_', 1)[-1]
    mk = keys.get('master_key_' + rev)
    if not mk or len(mk) != 16: return None
    if name.startswith('titlekek_'):
        src = keys.get('titlekek_source')
        return ecb_decrypt(mk, src) if src and len(src) == 16 else None
    if name.startswith('key_area_key_'):
        kind = name[len('key_area_key_'):].rsplit('_', 1)[0]
        kek_src, gen_src, src = keys.get('aes_kek_generation_source'), keys.get('aes_key_generation_source'), keys.get('key_area_key_%s_source' % kind)
        if not all(s and len(s) == 16 for s in (kek_src, gen_src, src)): return None
        return ecb_decrypt(ecb_decrypt(ecb_decrypt(mk, kek_src), src), gen_src)
    return None

# ---------------------------------------------------------------- containers: [(name, offset in the file, size)]


def u32(b, o): return int.from_bytes(b[o:o + 4], 'little')
def u64(b, o): return int.from_bytes(b[o:o + 8], 'little')


def pfs0(f, base):
    f.seek(base)
    head = f.read(0x10)
    if head[:4] != b'PFS0': return None
    count, names = u32(head, 4), u32(head, 8)
    if not 0 < count <= 4096 or names > 1 << 20: return None
    table = f.read(count * 0x18 + names)
    start = base + 0x10 + len(table)
    out = []
    for i in range(count):
        e = i * 0x18
        at = count * 0x18 + u32(table, e + 16)
        out.append((table[at:].split(b'\0', 1)[0].decode('utf-8', 'replace'), start + u64(table, e), u64(table, e + 8)))
    return out


def hfs0(f, base):
    f.seek(base)
    head = f.read(0x10)
    if head[:4] != b'HFS0': return None
    count, names = u32(head, 4), u32(head, 8)
    if not 0 < count <= 4096 or names > 1 << 20: return None
    table = f.read(count * 0x40 + names)
    start = base + 0x10 + len(table)
    out = []
    for i in range(count):
        e = i * 0x40
        at = count * 0x40 + u32(table, e + 16)
        out.append((table[at:].split(b'\0', 1)[0].decode('utf-8', 'replace'), start + u64(table, e), u64(table, e + 8)))
    return out


def entries(f):
    """The files an NSP / NSZ holds, or the secure partition of an XCI / XCZ (with or without the 0x1000 key area in front)."""
    e = pfs0(f, 0)
    if e is not None: return e
    for pre in (0, 0x1000):
        f.seek(pre + 0x100)
        h = f.read(0x100)
        if h[:4] != b'HEAD': continue
        root = hfs0(f, pre + u64(h, 0x30))
        if not root: break
        for name, off, _ in root:
            if name == 'secure':
                return hfs0(f, off) or []
        break
    raise Fail('not_a_game_file')

# ---------------------------------------------------------------- NCZ (an NSZ's compressed NCA): plain data from 0x4000 on


def _zstd():
    for mod in ('compression.zstd', 'zstandard', 'backports.zstd'):
        try:
            m = __import__(mod, fromlist=['x'])
        except ImportError:
            continue
        if hasattr(m, 'ZstdDecompressor') and hasattr(m.ZstdDecompressor(), 'decompressobj'):
            return lambda b: m.ZstdDecompressor().decompressobj().decompress(b)
        if hasattr(m, 'decompress'): return lambda b: m.decompress(b)
    raise Fail('ncz_needs_zstd')


def ncz_body(f, off, size):
    f.seek(off + 0x4000)
    raw = f.read(size - 0x4000)
    if raw[:8] != b'NCZSECTN': raise Fail('ncz_unknown')
    at = 0x10 + u64(raw, 8) * 0x40
    dec = lambda b: _zstd()(b)  # noqa: E731  (only looked up when a block really is compressed)
    if raw[at:at + 8] == b'NCZBLOCK':
        exp, count, total = raw[at + 11], u32(raw, at + 12), u64(raw, at + 16)
        bs, p, out = 1 << exp, at + 24 + count * 4, bytearray()
        for i in range(count):
            n = u32(raw, at + 24 + i * 4)
            want = min(bs, total - len(out))
            out += raw[p:p + n] if n >= want else dec(raw[p:p + n])
            p += n
        return bytes(out)
    return dec(raw[at:])

# ---------------------------------------------------------------- the Control NCA's RomFS


class Nca:
    def __init__(self, f, off, size, header, ncz):
        self.f, self.off, self.size, self.h = f, off, size, header
        self.body = ncz_body(f, off, size) if ncz else None

    def raw(self, at, n):
        self.f.seek(self.off + at)
        return self.f.read(n)

    def read(self, at, n, key, ctr_hi, enc):
        """n plain bytes at offset `at` of the NCA."""
        if self.body is not None and at >= 0x4000: return self.body[at - 0x4000:at - 0x4000 + n]
        lo = at & ~15
        data = self.raw(lo, (at + n - lo + 15) & ~15)
        if enc == 3: data = ctr_crypt(key, ctr_hi, lo, data)
        elif enc != 1: raise Fail('unsupported_encryption')
        return data[at - lo:at - lo + n]


def title_key(f, files, h, keys):
    rid = h[0x230:0x240]
    rev = max(h[0x206], h[0x220]); rev = rev - 1 if rev else 0
    if any(rid):
        want = rid.hex() + '.tik'
        tik = next(((o, s) for n, o, s in files if n.lower() == want), None)
        if not tik: raise Fail('no_ticket')
        f.seek(tik[0] + 0x180)
        block = f.read(16)
        kek = key_for(keys, 'titlekek_%02x' % rev)
        if not kek: raise Fail('missing_key:titlekek_%02x' % rev)
        return ecb_decrypt(kek, block)
    area = ('application', 'ocean', 'system')
    if h[0x207] >= len(area): raise Fail('bad_header')
    name = 'key_area_key_%s_%02x' % (area[h[0x207]], rev)
    kak = key_for(keys, name)
    if not kak: raise Fail('missing_key:' + name)
    return ecb_decrypt(kak, h[0x300 + 0x20:0x300 + 0x30])


def icon_from(nca, key):
    h = nca.h
    for i in range(4):
        start, end = u32(h, 0x240 + i * 0x10) * 0x200, u32(h, 0x244 + i * 0x10) * 0x200
        fs = h[0x400 + i * 0x200:0x600 + i * 0x200]
        if not end or fs[2] != 0 or fs[3] != 3 or fs[8:12] != b'IVFC': continue   # a RomFS with IVFC hashes
        enc, ctr_hi = fs[4], fs[0x140:0x148][::-1]
        levels = u32(fs, 0x8 + 0xC)
        data = u64(fs, 0x8 + 0x10 + (max(levels, 2) - 2) * 0x18)      # the last level is the RomFS itself
        rd = lambda at, n: nca.read(start + data + at, n, key, ctr_hi, enc)  # noqa: E731
        rh = rd(0, 0x50)
        if u64(rh, 0) != 0x50: raise Fail('bad_romfs')
        meta_off, meta_size, file_data = u64(rh, 0x38), u64(rh, 0x40), u64(rh, 0x48)
        if meta_size > 1 << 24: raise Fail('bad_romfs')
        meta = rd(meta_off, meta_size)
        found, p = {}, 0
        while p + 0x20 <= len(meta):
            foff, fsize, nlen = u64(meta, p + 8), u64(meta, p + 16), u32(meta, p + 28)
            name = meta[p + 32:p + 32 + nlen].decode('utf-8', 'replace')
            if name.startswith('icon_') and name.endswith('.dat') and 0 < fsize < 1 << 22: found[name[5:-4]] = (foff, fsize)
            p += (32 + nlen + 3) & ~3
        for lang in LANGS + sorted(found):
            if lang in found:
                foff, fsize = found[lang]
                jpg = rd(file_data + foff, fsize)
                if jpg[:2] == b'\xff\xd8': return jpg
        raise Fail('no_icon')
    raise Fail('no_romfs')


def read_icon(keys, path):
    hk = keys.get('header_key')
    if not hk or len(hk) != 32: raise Fail('no_header_key')
    with open(path, 'rb') as f:
        files = entries(f)
        opened = False
        for name, off, size in files:
            low = name.lower()
            if not low.endswith(('.nca', '.ncz')) or size < NCA_HEADER: continue
            h = header_decrypt(hk, Nca(f, off, size, b'', False).raw(0, NCA_HEADER))
            if h[0x200:0x204] != b'NCA3': continue
            opened = True
            if h[0x205] != CONTROL: continue
            nca = Nca(f, off, size, h, low.endswith('.ncz'))
            return icon_from(nca, title_key(f, files, h, keys))
        raise Fail('no_control' if opened else 'wrong_header_key')


def main(argv):
    if len(argv) != 3: raise SystemExit(__doc__)
    keys_path, game, out = argv
    try:
        with open(keys_path, 'rb') as f: keys = kc.parse_keys(f.read().decode('utf-8', 'replace'))
        jpg = read_icon(keys, game)
        tmp = out + '.part'
        with open(tmp, 'wb') as f: f.write(jpg)
        os.replace(tmp, out)
        r = {'result': 'ok', 'bytes': len(jpg)}
    except Fail as e:
        r = {'result': str(e)}
    except (OSError, ValueError, IndexError) as e:
        r = {'result': 'error', 'detail': type(e).__name__}
    print(json.dumps(r))
    return 0 if r['result'] == 'ok' else 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
