#!/bin/bash
# Write the iOS root image to the Axon 7's userdata partition from TWRP,
# faster than a plain `adb exec-in dd` of the whole image (~11 MB/s: 25 min
# for 16 GB):
#   full   gzip -1 on the PC, gunzip | dd on the phone. Free space in the
#          image is zeros and most of iOS compresses well, so far fewer bytes
#          cross the USB link.
#   delta  when IMG.onphone.img (a copy of what the phone holds, kept as a
#          btrfs reflink, so free) exists: compare in 1 MiB chunks and send
#          only the changed runs, each compressed. A tweak to the root then
#          takes seconds.
# The phone must be in TWRP; /data and /sdcard get unmounted (they are the
# same partition). FULL=1 forces a full write.
#
# Usage: tools/axon7-flashroot.sh [IMG]   (default research/axon7/ios16-root.img)
set -euo pipefail
cd "$(dirname "$0")/.."
img=${1:-research/axon7/ios16-root.img}
rec=${img%.img}.onphone.img
dev=/dev/block/bootdevice/by-name/userdata
[[ -f $img ]] || { echo "no $img" >&2; exit 1; }
[[ "$(adb get-state 2>/dev/null)" == recovery ]] || { echo "phone is not in TWRP" >&2; exit 1; }
adb shell 'umount /sdcard 2>/dev/null; umount /data 2>/dev/null; umount /data 2>/dev/null; ! mount | grep -q " /data "' ||
	{ echo "could not unmount /data in TWRP" >&2; exit 1; }
# XNU refuses B-trees whose extents are not whole nodes (Linux hfsplus leaves
# those after big writes): fix or refuse before anything goes to the phone
python3 -I tools/hfs-btree-fix.py "$img" --fix || { echo "$img: B-tree layout XNU would refuse; not writing" >&2; exit 1; }
size=$(stat -c %s "$img")
part=$(adb shell "blockdev --getsize64 $dev" | tr -d '\r')
(( size <= part )) || { echo "$img ($size) is larger than userdata ($part)" >&2; exit 1; }

send() {	# send OFFSET_MIB COUNT_MIB: one compressed run
	dd if="$img" bs=1M skip="$1" count="$2" status=none | gzip -1 |
		adb exec-in "gunzip -c | dd of=$dev bs=1048576 seek=$1 conv=notrunc 2>/dev/null"
}

t0=$(date +%s)
if [[ ${FULL:-0} != 1 && -f $rec && $(stat -c %s "$rec") == "$size" ]]; then
	mapfile -t runs < <(python3 -I - "$rec" "$img" <<'EOF'
import sys
MIB = 1 << 20
a, b = (open(p, 'rb') for p in sys.argv[1:])
i, start = 0, None
while True:
    x, y = a.read(MIB), b.read(MIB)
    if not y:
        break
    if x != y:
        start = i if start is None else start
    elif start is not None:
        print(start, i - start); start = None
    i += 1
if start is not None:
    print(start, i - start)
EOF
	)
	total=0
	for r in "${runs[@]}"; do total=$((total + ${r#* })); done
	echo "delta: ${#runs[@]} changed runs, $total MiB of $((size >> 20)) MiB"
	for r in "${runs[@]}"; do send ${r% *} ${r#* }; done
else
	echo "full write: $((size >> 20)) MiB, compressed on the fly"
	gzip -1 -c "$img" | adb exec-in "gunzip -c | dd of=$dev bs=4194304 2>/dev/null"
fi
adb shell sync

# Spot check: the volume header and three 4 MiB samples must match the image.
for skip in 0 $((size / 4194304 / 2)) $((size / 4194304 - 1)); do
	a=$(adb shell "dd if=$dev bs=4194304 skip=$skip count=1 2>/dev/null | md5sum" | cut -d' ' -f1)
	b=$(dd if="$img" bs=4194304 skip=$skip count=1 status=none | md5sum | cut -d' ' -f1)
	[[ $a == "$b" ]] || { echo "MISMATCH at 4 MiB block $skip" >&2; exit 1; }
done
cp --reflink=always "$img" "$rec"
echo "done in $(( $(date +%s) - t0 )) s; phone copy recorded as $rec"
