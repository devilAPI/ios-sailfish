#!/usr/bin/env python3
"""iOS + postmarketOS dual boot on the ZTE Axon 7: one boot.img for both.

The kernel slot keeps the iOS loader shim with its XNU payload (and the stock
DTBs ZTE LK picks and patches); the ramdisk slot carries a postmarketOS
bundle. Holding Volume Down at boot makes the shim start Linux from the
bundle (shim/pmos.c), otherwise it boots iOS as before.

Bundle (little-endian header, struct pmos_hdr in shim/pmos.h):
  0x0000  header, 4 KiB
  0x1000  DTB: mainline msm8996-zte-axon7 with /memory, /chosen bootargs and
          8-byte /chosen linux,initrd-start/end placeholders (fdtput)
  ...     initramfs (as built: Linux unpacks it), 4 KiB aligned
  ...     raw arm64 Image, 2 MiB aligned in the bundle, last (its BSS
          follows it in RAM)

  axon7-dualboot.py bundle --image vmlinuz|Image --dtb X.dtb --initrd F --cmdline S -o BUNDLE
  axon7-dualboot.py cmdline BOOT.img                      # bootargs of BOOT's bundle (exit 3 if none)
  axon7-dualboot.py combine BASE.img BUNDLE -o OUT.img    # BASE's kernel/second, BUNDLE as ramdisk
  axon7-dualboot.py extract BOOT.img -o BUNDLE            # exit 3 if BOOT has no bundle
  axon7-dualboot.py check BOOT.img                        # exit 0 only for a valid dual-boot image

Used on the PC (tools/axon7-cycle.sh keeps the phone's bundle when it writes
a new iOS kernel) and on the phone (postmarketOS's /boot trigger rebuilds
the bundle and keeps the iOS part). Needs fdtput (dtc) for `bundle`.
"""
import argparse, gzip, hashlib, os, struct, subprocess, sys, tempfile, zlib

PAGE = 4096
MAGIC = b'AX7PMOS1'
VERSION = 1
HDR_SIZE = 4096
HDR_FMT = '<8sII8Q64s'
SZ_2M = 2 << 20
RAMDISK_ADDR = 0x98000000      # clear of LK's scratch (0x91c00000 or 0xa0000000) and mainline reserved memory
BOOT_PART_MAX = 64 << 20       # sde12
SHIM_MARK = b'AXON7 SHIM: loader'
# Axon 7 A2017G RAM (docs/hardware.md): 2 GiB at 0x80000000, 0x7e4c0000 at 0x1_00000000
MEMORY_REG = ['0', '0x80000000', '0', '0x80000000', '1', '0', '0', '0x7e4c0000']


def die(msg, code=1):
    print(f'axon7-dualboot: {msg}', file=sys.stderr)
    sys.exit(code)


def up(n, a):
    return (n + a - 1) // a * a


# ---- Android boot image v0 -------------------------------------------------

def bootimg_parse(b):
    if b[:8] != b'ANDROID!':
        die('not an Android boot image')
    ks, ka, rs, ra, ss, sa, ta, page, hv = struct.unpack_from('<9I', b, 8)
    if hv != 0 or page != PAGE:
        die(f'unexpected boot image (header v{hv}, page {page})')
    o = page
    kernel = b[o:o + ks]
    o += up(ks, page)
    ramdisk = b[o:o + rs]
    o += up(rs, page)
    second = b[o:o + ss]
    if len(kernel) != ks or len(ramdisk) != rs or len(second) != ss:
        die('boot image truncated')
    return {'hdr': bytearray(b[:page]), 'kernel': kernel, 'ramdisk': ramdisk, 'second': second, 'ramdisk_addr': ra}


def bootimg_build(p, ramdisk, ramdisk_addr):
    h = bytearray(p['hdr'])
    struct.pack_into('<I', h, 16, len(ramdisk))
    struct.pack_into('<I', h, 20, ramdisk_addr)
    sha = hashlib.sha1()
    for part in (p['kernel'], ramdisk, p['second']):
        sha.update(part)
        sha.update(struct.pack('<I', len(part)))
    h[576:608] = sha.digest().ljust(32, b'\0')
    pad = lambda d: d + b'\0' * (up(len(d), PAGE) - len(d))
    return bytes(h) + pad(p['kernel']) + pad(ramdisk) + pad(p['second'])


def kernel_has_shim(kernel):
    """The kernel slot is Image.gz + appended DTBs; the shim string is in the Image."""
    try:
        d = zlib.decompressobj(31)
        img = d.decompress(kernel, 1 << 20)     # the shim text is in the first KiBs
    except zlib.error:
        return False
    return SHIM_MARK in img


# ---- bundle ----------------------------------------------------------------

def bundle_parse(b):
    if len(b) < HDR_SIZE or b[:8] != MAGIC:
        return None
    f = struct.unpack_from(HDR_FMT, b, 0)
    keys = ('magic', 'version', 'hdr_size', 'dtb_off', 'dtb_size', 'initrd_off', 'initrd_size',
            'image_off', 'image_size', 'image_mem', 'total', 'note')
    h = dict(zip(keys, f))
    return h


def bundle_check(b):
    """Same checks as the shim (pmos.c) plus the Image's own header."""
    h = bundle_parse(b)
    if h is None:
        return 'no bundle magic'
    if h['version'] != VERSION or h['hdr_size'] < struct.calcsize(HDR_FMT) or h['total'] > len(b):
        return 'bad header (version, size or total)'
    for k in ('dtb', 'initrd', 'image'):
        if h[k + '_off'] + h[k + '_size'] > h['total']:
            return f'{k} outside the bundle'
    if h['dtb_off'] % 8 or h['image_off'] % SZ_2M:
        return 'misaligned DTB or Image'
    if b[h['dtb_off']:h['dtb_off'] + 4] != b'\xd0\x0d\xfe\xed':
        return 'DTB has no FDT magic'
    img = b[h['image_off']:h['image_off'] + 64]
    if img[56:60] != b'ARM\x64':
        return 'Image is not an arm64 Image'
    text_off, image_mem = struct.unpack_from('<QQ', img, 8)
    if text_off != 0 or h['image_mem'] < h['image_size']:
        return 'Image text_offset not 0 or image_mem too small'
    return None


def fdt(dtb, *args):
    try:
        subprocess.run(['fdtput', *args], check=True, capture_output=True, text=True)
    except FileNotFoundError:
        die('fdtput not found (dtc package)')
    except subprocess.CalledProcessError as e:
        die(f'fdtput {" ".join(args[1:4])}: {e.stderr.strip()}')


def prepare_dtb(src, cmdline):
    with tempfile.TemporaryDirectory() as t:
        p = os.path.join(t, 'x.dtb')
        with open(src, 'rb') as f:
            d = f.read()
        if d[:4] != b'\xd0\x0d\xfe\xed':
            die(f'{src}: not a DTB')
        with open(p, 'wb') as f:
            f.write(d)
        # room for the new properties, then the values (initrd: two cells = 8 bytes, filled by the shim)
        subprocess.run(['dtc', '-I', 'dtb', '-O', 'dtb', '-p', '4096', '-o', p, p], check=True, capture_output=True)
        fdt(p, '-t', 'x', p, '/memory@80000000', 'reg', *MEMORY_REG)
        fdt(p, '-t', 's', p, '/chosen', 'bootargs', cmdline)
        fdt(p, '-t', 'x', p, '/chosen', 'linux,initrd-start', '0', '0')
        fdt(p, '-t', 'x', p, '/chosen', 'linux,initrd-end', '0', '0')
        with open(p, 'rb') as f:
            return f.read()


def read_image(path):
    with open(path, 'rb') as f:
        d = f.read()
    if d[:2] == b'\x1f\x8b':
        d = gzip.decompress(d)
    if d[56:60] != b'ARM\x64':
        die(f'{path}: not an arm64 Image (or Image.gz)')
    return d


def cmd_bundle(a):
    image = read_image(a.image)
    with open(a.initrd, 'rb') as f:
        initrd = f.read()
    dtb = prepare_dtb(a.dtb, a.cmdline)
    text_off, image_mem = struct.unpack_from('<QQ', image, 8)
    image_mem = max(image_mem, len(image))
    dtb_off = HDR_SIZE
    initrd_off = up(dtb_off + len(dtb), PAGE)
    image_off = up(initrd_off + len(initrd), SZ_2M)
    total = image_off + len(image)
    note = a.cmdline.encode()[:63]
    hdr = struct.pack(HDR_FMT, MAGIC, VERSION, HDR_SIZE, dtb_off, len(dtb), initrd_off, len(initrd),
                      image_off, len(image), image_mem, total, note).ljust(HDR_SIZE, b'\0')
    out = bytearray(total)
    out[0:HDR_SIZE] = hdr
    out[dtb_off:dtb_off + len(dtb)] = dtb
    out[initrd_off:initrd_off + len(initrd)] = initrd
    out[image_off:image_off + len(image)] = image
    err = bundle_check(bytes(out))
    if err:
        die(f'built bundle fails its own check: {err}')
    with open(a.output, 'wb') as f:
        f.write(out)
    print(f'{a.output}: {total} bytes (DTB {len(dtb)}, initramfs {len(initrd)}, Image {len(image)}, '
          f'Image+BSS {image_mem})')


def cmd_combine(a):
    with open(a.base, 'rb') as f:
        p = bootimg_parse(f.read())
    if not kernel_has_shim(p['kernel']):
        die(f'{a.base}: kernel slot is not the iOS loader shim; refusing (would lose iOS)')
    with open(a.bundle, 'rb') as f:
        bundle = f.read()
    err = bundle_check(bundle)
    if err:
        die(f'{a.bundle}: {err}')
    img = bootimg_build(p, bundle, a.ramdisk_addr)
    if len(img) > a.max:
        die(f'combined image is {len(img)} bytes, more than the boot partition ({a.max})')
    with open(a.output, 'wb') as f:
        f.write(img)
    print(f'{a.output}: {len(img)} bytes (iOS kernel slot {len(p["kernel"])}, bundle {len(bundle)} at {a.ramdisk_addr:#x})')


def cmd_extract(a):
    with open(a.boot, 'rb') as f:
        p = bootimg_parse(f.read())
    if bundle_parse(p['ramdisk']) is None:
        print(f'{a.boot}: no postmarketOS bundle in the ramdisk', file=sys.stderr)
        sys.exit(3)
    err = bundle_check(p['ramdisk'])
    if err:
        die(f'{a.boot}: bundle is damaged: {err}')
    with open(a.output, 'wb') as f:
        f.write(p['ramdisk'])
    print(f'{a.output}: {len(p["ramdisk"])} bytes')


def bundle_bootargs(bundle):
    h = bundle_parse(bundle)
    dtb = bundle[h['dtb_off']:h['dtb_off'] + h['dtb_size']]
    with tempfile.TemporaryDirectory() as t:
        p = os.path.join(t, 'x.dtb')
        with open(p, 'wb') as f:
            f.write(dtb)
        r = subprocess.run(['fdtget', '-t', 's', p, '/chosen', 'bootargs'], capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None


def cmd_cmdline(a):
    with open(a.boot, 'rb') as f:
        p = bootimg_parse(f.read())
    if bundle_check(p['ramdisk']) is not None:
        sys.exit(3)
    c = bundle_bootargs(p['ramdisk'])
    if not c:
        sys.exit(3)
    print(c)


def cmd_check(a):
    with open(a.boot, 'rb') as f:
        b = f.read()
    p = bootimg_parse(b)
    ok = True
    shim = kernel_has_shim(p['kernel'])
    print(f'kernel slot: {len(p["kernel"])} bytes, iOS shim {"yes" if shim else "NO"}')
    ok &= shim
    err = bundle_check(p['ramdisk'])
    print(f'ramdisk: {len(p["ramdisk"])} bytes at {p["ramdisk_addr"]:#x}, postmarketOS bundle {err or "ok"}')
    ok &= err is None and p['ramdisk_addr'] % SZ_2M == 0
    h = bundle_parse(p['ramdisk'])
    if h:
        print(f'  cmdline: {h["note"].rstrip(bytes(1)).decode(errors="replace")}...')
    print(f'image: {len(b)} bytes of {BOOT_PART_MAX}')
    sys.exit(0 if ok and len(b) <= BOOT_PART_MAX else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('bundle')
    s.add_argument('--image', required=True)
    s.add_argument('--dtb', required=True)
    s.add_argument('--initrd', required=True)
    s.add_argument('--cmdline', required=True)
    s.add_argument('-o', '--output', required=True)
    s = sub.add_parser('combine')
    s.add_argument('base')
    s.add_argument('bundle')
    s.add_argument('-o', '--output', required=True)
    s.add_argument('--ramdisk-addr', type=lambda x: int(x, 0), default=RAMDISK_ADDR)
    s.add_argument('--max', type=int, default=BOOT_PART_MAX)
    s = sub.add_parser('extract')
    s.add_argument('boot')
    s.add_argument('-o', '--output', required=True)
    s = sub.add_parser('check')
    s.add_argument('boot')
    s = sub.add_parser('cmdline')
    s.add_argument('boot')
    a = ap.parse_args()
    {'bundle': cmd_bundle, 'combine': cmd_combine, 'extract': cmd_extract, 'check': cmd_check,
     'cmdline': cmd_cmdline}[a.cmd](a)


if __name__ == '__main__':
    main()
