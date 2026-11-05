#!/usr/bin/env python3
"""Replay the journal of an HFS+ (journaled, journal inside the volume) image
the way XNU does at mount (bsd/vfs/vfs_journal.c replay_journal), then mark
the journal empty.

  hfs-journal-replay.py IMG [--dry-run]

Linux fsck.hfsplus (hfsprogs 540.1) does not replay journals: it marks the
volume clean and leaves the transactions, which XNU would later replay over
any change made on Linux. Run this first on an image pulled from a
force-reset iOS, then fsck.hfsplus -fy.

Every header and block list checksum is verified before anything is
written; any surprise aborts with nothing changed.
"""
import struct, sys

JMAGIC = 0x4a4e4c78
ENDIAN = 0x12345678
BLHDR_CHECK_CHECKSUMS = 1


def calc_checksum(data):
    ck = 0
    for b in data:
        ck = ((ck << 8) ^ (ck + b)) & 0xffffffff
    return (~ck) & 0xffffffff


def main():
    path = sys.argv[1]
    dry = '--dry-run' in sys.argv
    f = open(path, 'rb' if dry else 'r+b')
    f.seek(1024)
    vh = f.read(512)
    sig, ver, attr, lmv, jib = struct.unpack('>2sHI4sI', vh[:16])
    bs = struct.unpack('>I', vh[40:44])[0]
    assert sig in (b'H+', b'HX'), f'no HFS+ volume header: {sig}'
    assert attr & 0x2000, 'volume is not journaled'
    f.seek(jib * bs)
    jinfo = f.read(512)
    jflags = struct.unpack('>I', jinfo[:4])[0]
    joff, jsize = struct.unpack('>QQ', jinfo[36:52])
    assert jflags & 1, 'journal is not inside the volume (kJIJournalInFSMask)'

    f.seek(joff)
    raw = f.read(512)
    e = '<' if struct.unpack('<I', raw[:4])[0] == JMAGIC else '>'
    magic, endian, start, end, size, blhdr_size, cksum, jhdr_size = struct.unpack(e + 'IIQQQIII', raw[:44])
    assert magic == JMAGIC and endian == ENDIAN, 'bad journal header magic'
    assert size == jsize, f'journal size {size} != info block {jsize}'
    hdr0 = bytearray(raw[:44])
    struct.pack_into(e + 'I', hdr0, 36, 0)
    assert calc_checksum(hdr0) == cksum, 'journal header checksum mismatch (format not understood)'
    print(f'journal at {joff:#x}, size {size}, jhdr_size {jhdr_size}, blhdr_size {blhdr_size}, start {start} end {end}')
    if start == end:
        print('journal is empty: nothing to replay')
        return

    def jread(off, n):
        """n bytes of the circular journal buffer at offset off (wraps past size)."""
        out = b''
        while n:
            if off >= size:
                off = jhdr_size + (off - size)
            k = min(n, size - off)
            f.seek(joff + off)
            out += f.read(k)
            off += k
            n -= k
        return out

    def wrap(off):
        return jhdr_size + (off - size) if off >= size else off

    writes = []   # (byte offset in volume, data), applied in order after all checks
    off, ntx = start, 0
    while off != end:
        hdr = jread(off, blhdr_size)
        # block_list_header: max_blocks, num_blocks, bytes_used, checksum, flags,
        # then block_info binfo[] (bnum u64, bsize u32, cksum/seq u32); binfo[0]
        # belongs to the header itself, the logged blocks are binfo[1..]
        max_blocks, num_blocks, bytes_used, bcksum, flags = struct.unpack(e + 'HHIII', hdr[:16])
        assert 1 <= num_blocks <= max_blocks + 1 and blhdr_size <= bytes_used <= size, \
            f'bad block list header at {off}: num {num_blocks} max {max_blocks} used {bytes_used}'
        if flags & BLHDR_CHECK_CHECKSUMS:
            h = bytearray(hdr[:32])
            struct.pack_into(e + 'I', h, 8, 0)
            assert calc_checksum(h) == bcksum, f'block list header checksum mismatch at {off}'
        data_off = wrap(off + blhdr_size)
        for i in range(1, num_blocks):
            bnum, bsize, _ = struct.unpack(e + 'QII', hdr[16 + 16 * i:32 + 16 * i])
            assert bsize % jhdr_size == 0 and 0 < bsize <= 1 << 20, f'odd block size {bsize}'
            data = jread(data_off, bsize)
            data_off = wrap(data_off + bsize)
            if bnum == 0xffffffffffffffff:
                continue   # killed block
            writes.append((bnum * jhdr_size, data))
        off = wrap(off + bytes_used)
        ntx += 1
        assert ntx < 100000, 'runaway: journal walk does not reach end'
    print(f'{ntx} block lists, {len(writes)} blocks, {sum(len(d) for _, d in writes)} bytes to replay')
    # sanity check of the units: the volume header (byte 1024) is journaled in
    # almost every transaction; its logged copy must carry the HFS+ signature
    vh_copies = [d[1024 - p:1024 - p + 2] for p, d in writes if p <= 1024 < p + len(d)]
    print(f'volume header logged {len(vh_copies)} times, signatures {set(vh_copies)}')
    assert vh_copies and all(v in (b'H+', b'HX') for v in vh_copies), 'units check failed: not writing'
    vsize = f.seek(0, 2)
    assert all(p + len(d) <= vsize for p, d in writes), 'a block lands past the end of the image'
    if dry:
        print('dry run: nothing written')
        return
    for pos, data in writes:
        f.seek(pos)
        f.write(data)
    # journal empty: start = end, new checksum
    hdr = bytearray(raw)
    struct.pack_into(e + 'Q', hdr, 8, end)
    struct.pack_into(e + 'I', hdr, 36, 0)
    struct.pack_into(e + 'I', hdr, 36, calc_checksum(hdr[:44]))
    f.seek(joff)
    f.write(hdr)
    f.flush()
    print('replayed; journal now empty')


if __name__ == '__main__':
    main()
