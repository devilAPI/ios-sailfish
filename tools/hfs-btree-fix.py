#!/usr/bin/env python3
"""Check (and fix) that the HFS+ B-tree files of an image satisfy XNU's
NodesAreContiguous rule, which Linux's hfsplus driver and fsck do not know.

  hfs-btree-fix.py IMG [--fix]

On a journaled volume XNU's BTOpenPath (BTree.c) refuses a B-tree whose
extents are not each a whole number of nodes (fsBTInvalidNodeErr -> EIO:
"hfs_mounthfsplus: BTOpenPath returned (5) getting catalog BT", root not
mounted). Linux hfsplus grows the catalog by odd numbers of 4 KiB blocks
when 8 KiB nodes are used (e.g. extracting thousands of files). XNU only
notices once it has stamped the volume HFSJ (mounted with the journal on).

--fix handles the case Linux leaves behind: only the LAST extent is odd and
the fork holds more blocks than the B-tree's nodes (totalNodes * nodeSize)
need. The surplus trailing blocks are dropped from the fork, freed in the
allocation bitmap and counted in the volume's free blocks. Anything else is
reported and left alone. Run fsck.hfsplus -fn afterwards.
"""
import struct, sys

FORKS = (('extents', 0xc0, 3), ('catalog', 0x110, 4), ('attributes', 0x160, 8))
ALLOC_FORK = 0x70


def read_fork(vh, off):
    lsize, clump, tblocks = struct.unpack('>QII', vh[off:off + 16])
    ext = [list(struct.unpack('>II', vh[off + 16 + 8 * i:off + 24 + 8 * i])) for i in range(8)]
    return lsize, tblocks, ext


def main():
    path, fix = sys.argv[1], '--fix' in sys.argv
    f = open(path, 'r+b' if fix else 'rb')
    f.seek(1024)
    vh = bytearray(f.read(512))
    assert vh[:2] in (b'H+', b'HX'), 'no HFS+ volume header'
    bs = struct.unpack('>I', vh[40:44])[0]
    journaled = bool(struct.unpack('>I', vh[4:8])[0] & 0x2000)
    problems = changed = 0
    for name, off, fid in FORKS:
        lsize, tblocks, ext = read_fork(vh, off)
        used = [e for e in ext if e[1]]
        if not used:
            continue
        f.seek(used[0][0] * bs)
        node = f.read(512)
        nodesize, total = struct.unpack('>HxxI', node[14 + 18:14 + 26])[0], struct.unpack('>I', node[14 + 22:14 + 26])[0]
        per = nodesize // bs if nodesize > bs else 1
        need = total * nodesize // bs
        odd = [i for i, e in enumerate(used) if e[1] % per]
        overflow = sum(e[1] for e in used) < tblocks
        state = 'ok' if not odd else f'extents {odd} not a multiple of {per} blocks'
        print(f'{name:10} nodeSize {nodesize} totalNodes {total} -> {need} blocks; fork {tblocks} blocks in '
              f'{len(used)} extents{" + overflow" if overflow else ""}: {state}')
        if not odd:
            continue
        problems += 1
        last = len(used) - 1
        surplus = tblocks - need
        if overflow or odd != [last] or not (0 < surplus < used[last][1]) or surplus % per != used[last][1] % per:
            print(f'  cannot fix automatically (odd inner extent, overflow extents or no surplus)')
            continue
        start = used[last][0] + used[last][1] - surplus
        print(f'  drop {surplus} trailing block(s) {start}..{start + surplus - 1}: fork {tblocks} -> {need} blocks')
        if not fix:
            continue
        used[last][1] -= surplus
        struct.pack_into('>QII', vh, off, need * bs, struct.unpack('>I', vh[off + 8:off + 12])[0], need)
        for i, e in enumerate(ext):
            struct.pack_into('>II', vh, off + 16 + 8 * i, *e)
        # free the blocks in the allocation bitmap (bit = block, MSB first)
        alsize, altb, alext = read_fork(vh, ALLOC_FORK)
        for b in range(start, start + surplus):
            byte, bit = divmod(b, 8)
            fb = byte // bs                 # block of the bitmap file holding this byte
            for es, ec in alext:
                if fb < ec:
                    pos = (es + fb) * bs + byte % bs
                    break
                fb -= ec
            else:
                raise SystemExit('bitmap block not in the allocation file extents')
            f.seek(pos)
            v = f.read(1)[0]
            assert v & (0x80 >> bit), f'block {b} is not marked allocated: not touching it'
            f.seek(pos)
            f.write(bytes([v & ~(0x80 >> bit) & 0xff]))
        free = struct.unpack('>I', vh[48:52])[0]
        struct.pack_into('>I', vh, 48, free + surplus)
        changed += 1
    if changed:
        f.seek(1024)
        f.write(vh)
        # the alternate volume header (1024 bytes before the end) mirrors the primary
        end = f.seek(0, 2)
        f.seek(end - 1024)
        if f.read(2) in (b'H+', b'HX'):
            f.seek(end - 1024)
            f.write(vh)
        f.flush()
        print(f'fixed {changed} B-tree file(s)')
    elif problems:
        print(f'{problems} problem(s); journaled={journaled}: XNU will refuse this volume' + ('' if fix else ' (run with --fix)'))
    sys.exit(1 if problems and not changed else 0)


if __name__ == '__main__':
    main()
