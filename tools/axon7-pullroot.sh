#!/bin/bash
# Bring the local iOS root image up to date with what the Axon 7 holds after
# iOS has been running (it writes to its root), without reading 16 GB over
# the slow TWRP USB link: the phone hashes its userdata in 4 MiB chunks,
# the PC hashes the local image, and only the differing chunks come back,
# gzip-compressed. Afterwards IMG and IMG.onphone.img (reflink) both match
# the phone, so the root can be edited on the PC (sudo mount -t hfsplus -o
# loop,force IMG MNT) and written back with tools/axon7-flashroot.sh (delta).
#
# Refuses unless the volume was unmounted cleanly with an empty journal (a
# force-reset iOS can leave journal transactions that XNU would replay over
# edits made on Linux).
#
# --allow-dirty: copy the volume as it is even with a dirty journal (raw
# chunks only); then replay the journal on the PC (fsck.hfsplus -fy) and
# check it before editing or writing anything back.
#
# Usage: tools/axon7-pullroot.sh [--allow-dirty] [IMG]   (default research/axon7/ios16-root.img)
set -euo pipefail
cd "$(dirname "$0")/.."
dirty=0
[[ ${1:-} == --allow-dirty ]] && { dirty=1; shift; }
img=${1:-research/axon7/ios16-root.img}
rec=${img%.img}.onphone.img
dev=/dev/block/bootdevice/by-name/userdata
CH=4194304
[[ -f $img ]] || { echo "no $img" >&2; exit 1; }
[[ "$(adb get-state 2>/dev/null)" == recovery ]] || { echo "phone is not in TWRP" >&2; exit 1; }
adb shell 'umount /sdcard 2>/dev/null; umount /data 2>/dev/null; umount /data 2>/dev/null; true'
size=$(stat -c %s "$img")
n=$(( (size + CH - 1) / CH ))
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. HFS+ state on the phone: clean unmount bit and empty journal
adb exec-out "dd if=$dev bs=4096 count=1 2>/dev/null" > "$tmp/vh"
DIRTY=$dirty python3 -I - "$tmp/vh" <<'EOF' > "$tmp/jinfo"
import struct, sys
b = open(sys.argv[1], 'rb').read()[1024:1536]
sig, ver, attr, lmv, jib = struct.unpack('>2sHI4sI', b[:16])
bs = struct.unpack('>I', b[40:44])[0]
assert sig in (b'H+', b'HX'), f'no HFS+ volume header ({sig})'
import os
if not attr & 0x100:
    assert os.environ.get('DIRTY') == '1', 'volume was not unmounted cleanly'
    print('warning: volume not unmounted cleanly (--allow-dirty)', file=sys.stderr)
print(jib, bs)
EOF
read -r jib bs < "$tmp/jinfo"
adb exec-out "dd if=$dev bs=$bs skip=$jib count=1 2>/dev/null" > "$tmp/jib"
joff=$(python3 -I -c 'import struct,sys; print(struct.unpack(">Q", open(sys.argv[1],"rb").read()[36:44])[0])' "$tmp/jib")
adb exec-out "dd if=$dev bs=512 skip=$((joff / 512)) count=1 2>/dev/null" > "$tmp/jh"
DIRTY=$dirty python3 -I - "$tmp/jh" <<'EOF'
import os, struct, sys
h = open(sys.argv[1], 'rb').read()
fmt = '<' if struct.unpack('<I', h[:4])[0] == 0x4a4e4c78 else '>'
magic, endian, start, end = struct.unpack(fmt + 'IIQQ', h[:24])
assert magic == 0x4a4e4c78, 'no journal header'
if start != end:
    assert os.environ.get('DIRTY') == '1', f'journal has pending transactions ({start} != {end}): shut iOS down cleanly first'
    print(f'journal has pending transactions ({start} != {end}): copying raw (--allow-dirty)')
else:
    print('volume clean, journal empty')
EOF

# 2. hashes on both sides
t0=$(date +%s)
echo "hashing $n chunks on the phone..."
adb shell "i=0; while [ \$i -lt $n ]; do echo \"\$i \$(dd if=$dev bs=$CH skip=\$i count=1 2>/dev/null | md5sum | cut -d' ' -f1)\"; i=\$((i+1)); done" |
	tr -d '\r' > "$tmp/phone"
[[ $(wc -l < "$tmp/phone") == "$n" ]] || { echo "phone hash list incomplete" >&2; exit 1; }
python3 -I - "$img" "$tmp/phone" $CH <<'EOF' > "$tmp/runs"
import hashlib, sys
img, phone, ch = sys.argv[1], sys.argv[2], int(sys.argv[3])
want = dict(l.split() for l in open(phone))
diff = []
with open(img, 'rb') as f:
    i = 0
    while True:
        d = f.read(ch)
        if not d:
            break
        if hashlib.md5(d).hexdigest() != want[str(i)]:
            diff.append(i)
        i += 1
runs, start = [], None
for j, i in enumerate(diff):
    if start is None:
        start = prev = i
    elif i != prev + 1:
        runs.append((start, prev - start + 1)); start = i
    prev = i
if start is not None:
    runs.append((start, prev - start + 1))
for s, c in runs:
    print(s, c)
EOF
mapfile -t runs < "$tmp/runs"
total=0
for r in "${runs[@]}"; do total=$((total + ${r#* })); done
echo "phone differs in $total chunks of 4 MiB (${#runs[@]} runs)"

# 3. pull the differing runs into the local image
for r in "${runs[@]}"; do
	s=${r% *} c=${r#* }
	adb exec-out "dd if=$dev bs=$CH skip=$s count=$c 2>/dev/null | gzip -1" | gunzip -c |
		dd of="$img" bs=$CH seek="$s" conv=notrunc status=none
done
# 4. verify the pulled chunks
python3 -I - "$img" "$tmp/phone" "$tmp/runs" $CH <<'EOF'
import hashlib, sys
img, phone, runs, ch = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
want = dict(l.split() for l in open(phone))
bad = 0
with open(img, 'rb') as f:
    for line in open(runs):
        s, c = map(int, line.split())
        for i in range(s, s + c):
            f.seek(i * ch)
            bad += hashlib.md5(f.read(ch)).hexdigest() != want[str(i)]
assert not bad, f'{bad} chunks still differ'
EOF
cp --reflink=always "$img" "$rec"
echo "local image now matches the phone ($(( $(date +%s) - t0 )) s); recorded as $rec"
