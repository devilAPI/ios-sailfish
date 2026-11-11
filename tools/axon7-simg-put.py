#!/usr/bin/env python3
"""Write an Android sparse image (e.g. super.img) to a block device on the
phone over adb, data only: RAW and FILL chunks are written, DONT_CARE chunks
(free space between the dynamic partitions) are skipped, so a 5.5 GiB super
device takes as long as its contents (TWRP's adb manages ~3.4 MB/s). Then
every written extent is read back and compared (sha1).

  simg-put.py SPARSE.img DEVICE [--adb "adb -s SERIAL"] [--dry-run] [--no-verify]
              [--base PREVIOUS.img]

--base: the device holds PREVIOUS.img (an earlier build written by this tool):
only the MiB that differ are written (typically 5-15 % of super), then every
data extent of SPARSE.img is checked as usual (sha1 on the phone, only the
hash crosses USB); if anything does not match, the whole image is written
again and checked once more.

DEVICE is the phone's block device (in TWRP: the sdX node of the partition,
see ios/tools/axon7-los-test.sh dev()); for LineageOS 24 the GPT partition
"system" (sde13 on this phone). Only the image's size is touched: the
device must be at least as large (checked).
"""
import argparse, hashlib, shlex, struct, subprocess, sys

MAGIC = 0xED26FF3A
RAW, FILL, DONT_CARE, CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
MAX_EXTENT = 64 << 20  # bytes per adb call


def extents(path):
    """yield (byte offset on the device, list of (kind, file offset or fill word, length))"""
    f = open(path, "rb")
    h = f.read(28)
    magic, major, _minor, fhs, chs, bs, nblocks, nchunks, _crc = struct.unpack("<IHHHHIIII", h)
    if magic != MAGIC or major != 1:
        sys.exit(f"{path}: not an Android sparse image")
    f.seek(fhs)
    extents.size, extents.bs = bs * nblocks, bs
    blk, cur, cur_start = 0, [], None
    for _ in range(nchunks):
        ctype, _r, cblocks, total = struct.unpack("<HHII", f.read(12))
        f.seek(chs - 12, 1)
        data_off, n = f.tell(), cblocks * bs
        if ctype == RAW:
            part = ("raw", data_off, n)
            f.seek(n, 1)
        elif ctype == FILL:
            part = ("fill", f.read(4), n)
        elif ctype in (DONT_CARE, CRC32):
            f.seek(total - chs, 1)
            part = None
        else:
            sys.exit(f"unknown chunk type {ctype:#x}")
        if part is None:
            if cur:
                yield cur_start, cur
            cur, cur_start = [], None
        else:
            if cur_start is None:
                cur_start = blk * bs
            cur.append(part)
        blk += cblocks if ctype != CRC32 else 0
    if cur:
        yield cur_start, cur
    if blk != nblocks:
        sys.exit(f"{path}: chunks cover {blk} blocks, header says {nblocks}")


def pieces(f, parts):
    """the bytes of an extent, in pieces of at most 1 MiB"""
    for kind, a, n in parts:
        if kind == "raw":
            f.seek(a)
            while n:
                b = f.read(min(n, 1 << 20))
                yield b
                n -= len(b)
        else:
            chunk = a * (1 << 18)  # 1 MiB of the fill word
            while n:
                yield chunk[: min(n, len(chunk))]
                n -= min(n, len(chunk))


def split(start, parts):
    """cut an extent into runs of at most MAX_EXTENT bytes"""
    run, run_start, run_len = [], start, 0
    for kind, a, n in parts:
        while n:
            take = min(n, MAX_EXTENT - run_len)
            run.append((kind, a, take))
            run_len += take
            n -= take
            if kind == "raw":
                a += take
            if run_len == MAX_EXTENT:
                yield run_start, run, run_len
                run_start += run_len
                run, run_len = [], 0
    if run:
        yield run_start, run, run_len


MIB = 1 << 20


def mib_hashes(path):
    """sha1 per MiB of the device over the data (RAW/FILL) blocks of a sparse image"""
    hs = {}
    for start, parts in extents(path):
        off = start
        with open(path, "rb") as f:
            for kind, a, n in parts:
                if kind == "raw":
                    f.seek(a)
                    left = n
                    while left:
                        take = min(left, MIB - off % MIB)
                        hs.setdefault(off // MIB, hashlib.sha1()).update(off.to_bytes(8, "little") + f.read(take))
                        off += take
                        left -= take
                else:
                    left = n
                    while left:
                        take = min(left, MIB - off % MIB)
                        hs.setdefault(off // MIB, hashlib.sha1()).update(off.to_bytes(8, "little") + a * (take // 4))
                        off += take
                        left -= take
    return {k: v.digest() for k, v in hs.items()}


def sub_parts(parts, skip, length):
    """the parts of an extent from byte SKIP, LENGTH bytes long"""
    out = []
    for kind, a, n in parts:
        if skip >= n:
            skip -= n
            continue
        take = min(n - skip, length)
        out.append((kind, a + skip if kind == "raw" else a, take))
        length -= take
        skip = 0
        if not length:
            break
    return out


def delta_runs(runs, changed):
    """cut runs down to the MiB pieces listed in CHANGED (merged where adjacent)"""
    out = []
    for s, parts, n in runs:
        pos = 0
        cur_start = cur_len = None
        while pos < n:
            off = s + pos
            take = min(n - pos, MIB - off % MIB)
            if off // MIB in changed:
                if cur_start is None:
                    cur_start, cur_len = pos, 0
                cur_len += take
            elif cur_start is not None:
                out.append((s + cur_start, sub_parts(parts, cur_start, cur_len), cur_len))
                cur_start = None
            pos += take
        if cur_start is not None:
            out.append((s + cur_start, sub_parts(parts, cur_start, cur_len), cur_len))
    return out


def write(adb, dev, bs, f, runs):
    total = sum(n for _, _, n in runs)
    done = 0
    for s, parts, n in runs:
        cmd = f"dd of={dev} bs={bs} seek={s // bs} conv=notrunc 2>/dev/null"
        p = subprocess.Popen(adb + ["exec-in", cmd], stdin=subprocess.PIPE)
        for b in pieces(f, parts):
            p.stdin.write(b)
        p.stdin.close()
        if p.wait():
            sys.exit(f"adb exec-in failed at {s:#x}")
        done += n
        print(f"\r  {done / 2**20:.0f}/{total / 2**20:.0f} MiB", end="", flush=True)
    print()
    # exec-in returns when this side has sent everything; let dd finish
    subprocess.run(adb + ["shell", "while pidof dd >/dev/null; do sleep 1; done; sync"], check=True)


def verify(adb, dev, bs, f, runs):
    bad = 0
    for s, parts, n in runs:
        want = hashlib.sha1()
        for b in pieces(f, parts):
            want.update(b)
        got = subprocess.run(adb + ["exec-out", f"dd if={dev} bs={bs} skip={s // bs} count={n // bs} "
                                    f"2>/dev/null | sha1sum"], capture_output=True, text=True).stdout.split()
        if not got or got[0] != want.hexdigest():
            print(f"  MISMATCH at {s:#x} +{n:#x}")
            bad += 1
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image"), ap.add_argument("device")
    ap.add_argument("--adb", default="adb")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-verify", action="store_true")
    ap.add_argument("--base", help="the image the device holds now (written earlier by this tool)")
    a = ap.parse_args()
    adb = shlex.split(a.adb)
    dev = shlex.quote(a.device)
    runs = []
    for start, parts in extents(a.image):
        runs.extend(split(start, parts))
    bs, size = extents.bs, extents.size
    total = sum(n for _, _, n in runs)
    print(f"{a.image}: {size} bytes ({size / 2**30:.2f} GiB), {total / 2**20:.0f} MiB of data "
          f"in {len(runs)} runs to {a.device}")
    todo = runs
    if a.base:
        new, old = mib_hashes(a.image), mib_hashes(a.base)
        changed = {k for k, v in new.items() if old.get(k) != v}
        todo = delta_runs(runs, changed)
        print(f"  base {a.base}: {len(changed)} of {len(new)} MiB differ, "
              f"{sum(n for _, _, n in todo) / 2**20:.0f} MiB to write in {len(todo)} runs")
    if a.dry_run:
        for s, _, n in todo:
            print(f"  {s:#014x} +{n:#x}")
        return
    devsize = subprocess.run(adb + ["shell", f"blockdev --getsize64 {dev}"], capture_output=True,
                             text=True).stdout.strip()
    if not devsize.isdigit() or int(devsize) < size:
        sys.exit(f"{a.device}: size {devsize!r}, image needs {size}")
    f = open(a.image, "rb")
    write(adb, dev, bs, f, todo)
    if a.no_verify:
        return
    bad = verify(adb, dev, bs, f, runs)
    if bad and a.base:
        print(f"  {bad} runs differ after the delta write: the device did not hold the base; "
              f"writing the whole image")
        write(adb, dev, bs, f, runs)
        bad = verify(adb, dev, bs, f, runs)
    if bad:
        sys.exit(f"{bad} of {len(runs)} runs do not read back as written")
    print(f"verified: {len(runs)} runs, {total} bytes")


if __name__ == "__main__":
    main()
