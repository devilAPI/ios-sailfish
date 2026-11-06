#!/usr/bin/env python3
"""Android boot images for the Axon 7 shim's LineageOS entry (shim/android.c).

The shim boots an Android boot image from the `los_boot` partition the way
ZTE LK would, but with the MMU off it cannot afford to gunzip a kernel, so it
takes boot image header v2 with a raw arm64 Image as the kernel and the DTBs
in the v2 dtb section. This tool converts an LK-style image (header v0/v1,
Image.gz-dtb or Image-dtb: kernel with DTBs appended) to that format and
checks images.

  axon7-androidimg.py convert IN.img -o OUT.img [--cmdline-append S]
  axon7-androidimg.py check IMG            # exit 0 only if the shim can boot IMG

LineageOS builds for the shim produce this format directly (BoardConfig:
BOARD_BOOT_HEADER_VERSION 2, BOARD_KERNEL_IMAGE_NAME Image, DTB in boot.img).
"""
import argparse
import gzip
import struct
import sys
import zlib

MAGIC = b'ANDROID!'
FDT_MAGIC = b'\xd0\x0d\xfe\xed'
V2_HDR = 1660          # header_size of a v2 header
LOS_BOOT_MAX = 96 << 20  # los_boot partition


def die(msg):
    print(f'axon7-androidimg: {msg}', file=sys.stderr)
    sys.exit(1)


def up(n, page):
    return (n + page - 1) // page * page


def parse(b):
    if b[:8] != MAGIC:
        die('not an Android boot image')
    ks, ka, rs, ra, ss, sa, ta, page, hv = struct.unpack_from('<9I', b, 8)
    if hv > 2:
        die(f'header version {hv} not supported (only 0-2)')
    h = dict(ks=ks, ka=ka, rs=rs, ra=ra, ss=ss, sa=sa, ta=ta, page=page, hv=hv,
             osv=struct.unpack_from('<I', b, 44)[0], name=b[48:64], cmdline=b[64:576], id=b[576:608],
             extra=b[608:1632], dtbo_size=0, dtbo_off=0, dtb_size=0, dtb_addr=0)
    off = page
    h['kernel'] = b[off:off + ks]; off += up(ks, page)
    h['ramdisk'] = b[off:off + rs]; off += up(rs, page)
    h['second'] = b[off:off + ss]; off += up(ss, page)
    if hv >= 1:
        h['dtbo_size'], h['dtbo_off'], hdr_size = struct.unpack_from('<IQI', b, 1632)
        h['dtbo'] = b[off:off + h['dtbo_size']]; off += up(h['dtbo_size'], page)
    if hv == 2:
        h['dtb_size'], h['dtb_addr'] = struct.unpack_from('<IQ', b, 1648)
        h['dtb'] = b[off:off + h['dtb_size']]; off += up(h['dtb_size'], page)
    h['total'] = off
    return h


def split_dtbs(blob):
    """Concatenated DTBs -> list (each checked by its totalsize)."""
    out, o = [], 0
    while o < len(blob):
        if blob[o:o + 4] != FDT_MAGIC:
            die(f'DTB area: no FDT magic at +{o:#x}')
        n = struct.unpack_from('>I', blob, o + 4)[0]
        out.append(blob[o:o + n]); o += n
    return out


def kernel_and_dtbs(kernel):
    """Kernel slot of an LK image -> (raw Image, DTB blob)."""
    if kernel[:2] == b'\x1f\x8b':
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        image = d.decompress(kernel) + d.flush()
        dtbs = d.unused_data
    else:
        # Image-dtb: the DTB chain that ends exactly at the end of the slot
        image = dtbs = None
        o = kernel.find(FDT_MAGIC, 64)
        while o > 0:
            p = o
            while p < len(kernel) and kernel[p:p + 4] == FDT_MAGIC:
                p += struct.unpack_from('>I', kernel, p + 4)[0]
            if p == len(kernel):
                image, dtbs = kernel[:o], kernel[o:]
                break
            o = kernel.find(FDT_MAGIC, o + 4)
        if image is None:
            die('kernel slot has no appended DTBs')
    if image[56:60] != b'ARM\x64':
        die('kernel is not an arm64 Image')
    return image, dtbs


def build_v2(h, image, dtbs, cmdline_append=b''):
    page = h['page']
    cmd = h['cmdline'].split(b'\0')[0] + h['extra'].split(b'\0')[0]
    if cmdline_append:
        cmd = (cmd + b' ' + cmdline_append).strip()
    if len(cmd) > 512 + 1024 - 2:
        die('command line too long')
    c1, c2 = cmd[:511], cmd[511:]
    hdr = bytearray(page)
    struct.pack_into('<8s10I16s', hdr, 0, MAGIC, len(image), h['ka'], len(h['ramdisk']), h['ra'],
                     len(h['second']), h['sa'], h['ta'], page, 2, h['osv'], h['name'])
    hdr[64:64 + len(c1)] = c1
    hdr[608:608 + len(c2)] = c2
    struct.pack_into('<IQIIQ', hdr, 1632, 0, 0, V2_HDR, len(dtbs), 0)
    pad = lambda d: d + b'\0' * (up(len(d), page) - len(d))
    return bytes(hdr) + pad(image) + pad(h['ramdisk']) + pad(h['second']) + pad(dtbs)


def check(b):
    """The shim's checks (shim/android.c); returns an error string or None."""
    h = parse(b)
    if h['hv'] != 2:
        return f'header v{h["hv"]}: the shim needs v2 (convert it)'
    if h['page'] not in (2048, 4096):
        return f'page size {h["page"]}'
    k = h['kernel']
    if k[:2] == b'\x1f\x8b':
        return 'compressed kernel: the shim needs a raw Image'
    if len(k) < 64 or k[56:60] != b'ARM\x64':
        return 'kernel is not an arm64 Image'
    text_off, image_size = struct.unpack_from('<QQ', k, 8)
    if image_size == 0 or image_size < len(k):
        return 'Image header has no image_size'
    if 0x80000000 + text_off + image_size > 0x83400000:
        return 'Image too big for 0x80000000..0x83400000 (splash reserved above)'
    if not h['dtb_size']:
        return 'no DTB section'
    split_dtbs(h['dtb'])
    if h['total'] > LOS_BOOT_MAX:
        return f'{h["total"]} bytes: larger than los_boot'
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('convert'); c.add_argument('input'); c.add_argument('-o', '--output', required=True)
    c.add_argument('--cmdline-append', default='')
    k = sub.add_parser('check'); k.add_argument('image')
    a = ap.parse_args()
    if a.cmd == 'convert':
        b = open(a.input, 'rb').read()
        h = parse(b)
        if h['hv'] == 2 and h['kernel'][:2] != b'\x1f\x8b' and h['dtb_size']:
            image, dtbs = h['kernel'], h['dtb']
        else:
            image, dtbs = kernel_and_dtbs(h['kernel'])
            if h['dtb_size']:
                dtbs = h['dtb']
        out = build_v2(h, image, dtbs, a.cmdline_append.encode())
        err = check(out)
        if err:
            die(f'converted image fails its check: {err}')
        open(a.output, 'wb').write(out)
        n = len(split_dtbs(dtbs))
        print(f'{a.output}: {len(out)} bytes, v2, Image {len(image)}, ramdisk {len(h["ramdisk"])}, {n} DTB(s)')
    else:
        err = check(open(a.image, 'rb').read())
        if err:
            print(f'{a.image}: {err}'); sys.exit(1)
        print(f'{a.image}: ok for the shim (v2, raw Image, DTB section)')


if __name__ == '__main__':
    main()
