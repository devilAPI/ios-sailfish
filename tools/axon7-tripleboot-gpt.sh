#!/bin/sh
# Add the triple-boot partitions to the ZTE Axon 7's UFS LUN 0 (run as root
# on the phone, in postmarketOS: it has sfdisk; the partitions are not in
# use there). Changes only the partition table, no data is moved:
#
#   userdata (iOS root, same start)  52 GiB -> 20 GiB   (the iOS image is 16 GiB)
#   + los_boot      96 MiB   LineageOS boot image (the shim's LineageOS entry)
#   + los_metadata  16 MiB   LineageOS /metadata
#   + pmos_boot     64 MiB   postmarketOS bundle (writable while the phone runs)
#   + los_data      rest     LineageOS /data
#
# The GPT gets 16 entries instead of 12 (the entry array has room for that
# before the first partition). Refuses unless the table is the stock one
# (userdata the last partition, up to the end) and the iOS volume header is
# where it should be. Saves the old table first. Does nothing if the
# partitions exist already.
#
# Usage: axon7-tripleboot-gpt.sh [--dry-run] [DISK]     (default /dev/sda)
set -eu
dry=0
[ "${1:-}" = --dry-run ] && { dry=1; shift; }
disk=${1:-/dev/sda}
die() { echo "axon7-tripleboot-gpt: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v sfdisk >/dev/null || die "sfdisk missing"
[ -b "$disk" ] || die "$disk is not a block device"
dump=$(sfdisk -d "$disk") || die "cannot read the partition table of $disk"
field() { echo "$dump" | sed -n "s/^$1: *//p"; }

[ "$(field label)" = gpt ] || die "$disk has no GPT"
[ "$(field sector-size)" = 4096 ] || die "$disk: sector size is not 4096 (not the Axon 7's LUN 0?)"
if echo "$dump" | grep -q 'name="pmos_boot"'; then
	echo "axon7-tripleboot-gpt: $disk already has the triple-boot partitions, nothing to do"
	exit 0
fi

ud=$(echo "$dump" | grep 'name="userdata"') || die "no userdata partition on $disk"
[ "$(echo "$dump" | grep -c '^/dev')" -le 12 ] || die "more partitions than expected"
dev=${ud%% :*}
start=$(echo "$ud" | sed -n 's/.*start= *\([0-9]*\),.*/\1/p')
size=$(echo "$ud" | sed -n 's/.*size= *\([0-9]*\),.*/\1/p')
last=$(field last-lba)
[ -n "$start" ] && [ -n "$size" ] && [ -n "$last" ] || die "cannot parse userdata"
[ $((start + size - 1)) -eq "$last" ] || die "userdata does not reach the end of $disk: not the stock layout"

GiB=262144	# 4 KiB sectors
MiB=256
ud_new=$((20 * GiB))
los_boot=$((96 * MiB)); los_meta=$((16 * MiB)); pmos=$((64 * MiB))
s1=$((start + ud_new)); s2=$((s1 + los_boot)); s3=$((s2 + los_meta)); s4=$((s3 + pmos))
data=$((last - s4 + 1))
[ "$data" -gt $((4 * GiB)) ] || die "userdata too small for the layout"

# iOS root: HFS+ / HFSX volume header at byte 1024 of userdata
part=$(echo "$dev" | sed 's|^/dev/||')
sig=$(dd if="/dev/$part" bs=1024 skip=1 count=1 2>/dev/null | head -c 2)
case "$sig" in
H+|HX) ;;
*) die "no iOS (HFS+) volume at the start of userdata ($dev): install the iOS root first, or this is not the expected layout" ;;
esac

L=0FC63DAF-8483-4772-8E79-3D69D8477DE4	# Linux data, no special meaning to the bootloader
new=$(echo "$dump" | sed "s/^table-length: .*/table-length: 16/" |
	sed "s|^\($dev : start= *$start, size= *\)$size,|\1$ud_new,|" |
	sed '/^$/d')
echo "$new" | grep -q "^table-length: 16" || new=$(printf '%s\ntable-length: 16\n' "$new")
new=$(printf '%s\n%s\n%s\n%s\n%s\n' "$new" \
	"${disk}10 : start=$s1, size=$los_boot, type=$L, name=\"los_boot\"" \
	"${disk}11 : start=$s2, size=$los_meta, type=$L, name=\"los_metadata\"" \
	"${disk}12 : start=$s4, size=$data, type=$L, name=\"los_data\"" \
	"${disk}13 : start=$s3, size=$pmos, type=$L, name=\"pmos_boot\"")

echo "new table for $disk:"
echo "$new" | grep -E '^/dev|^table-length'
if [ $dry = 1 ]; then
	echo "(dry run, nothing written)"
	exit 0
fi

backup=/root/axon7-lun0-before-tripleboot-$(date +%Y%m%d-%H%M%S).sfdisk
echo "$dump" > "$backup"
echo "old table saved to $backup (copy it to your PC; restore: sfdisk $disk < FILE)"
echo "$new" | sfdisk --no-reread --wipe never "$disk" >/dev/null 2>&1 || true	# verified below
partx -u "$disk" 2>/dev/null || true
partx -a "$disk" 2>/dev/null || true
sfdisk -d "$disk" | grep -q 'name="pmos_boot"' || die "table write did not take, restore $backup"
dd if="/dev/$part" bs=1024 skip=1 count=1 2>/dev/null | head -c 2 | grep -q -E 'H\+|HX' || die "iOS volume header gone after the change, restore $backup NOW"
echo "done: los_boot, los_metadata, pmos_boot, los_data added; iOS volume untouched"
