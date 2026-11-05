#!/bin/bash
# Put a postmarketOS bundle next to the iOS loader on the Axon 7's boot
# partition (phone in TWRP), keeping the iOS half exactly as it is. With no
# BUNDLE argument the bundle is built from pmbootstrap's rootfs chroot
# (/boot: vmlinuz, initramfs, DTB; kernel command line from its boot.img).
# The previous boot partition is saved to research/axon7/boot-before-dualboot.img.
#
# Usage: tools/axon7-dualboot-flash.sh [BUNDLE]
set -euo pipefail
cd "$(dirname "$0")/.."
tool="python3 -I tools/axon7-dualboot.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bundle=${1:-}
if [ -z "$bundle" ]; then
	chroot_boot=$(ls -d ~/.local/var/pmbootstrap/chroot_rootfs_zte-axon7/boot)
	cmdline=$(python3 -I -c 'import sys; b = open(sys.argv[1], "rb").read(4096); print((b[64:576].split(b"\0")[0] + b[608:1632].split(b"\0")[0]).decode().strip())' "$chroot_boot/boot.img")
	case "$cmdline" in *pmos_root_uuid=*) ;; *) echo "no pmos_root_uuid in $chroot_boot/boot.img's cmdline" >&2; exit 1 ;; esac
	dtb=$chroot_boot/msm8996-zte-axon7.dtb
	[ -f "$dtb" ] || dtb=$chroot_boot/dtbs/qcom/msm8996-zte-axon7.dtb
	$tool bundle --image "$chroot_boot/vmlinuz" --dtb "$dtb" --initrd "$chroot_boot/initramfs" --cmdline "$cmdline" -o "$work/pmos.bundle"
	bundle=$work/pmos.bundle
fi
[ "$(adb get-state 2>/dev/null)" = recovery ] || { echo "phone is not in TWRP (adb recovery)" >&2; exit 1; }
adb exec-out 'dd if=/dev/block/bootdevice/by-name/boot bs=1M 2>/dev/null' > "$work/current.img"
cp "$work/current.img" research/axon7/boot-before-dualboot.img
$tool combine "$work/current.img" "$bundle" -o "$work/dual.img"
$tool check "$work/dual.img"
adb push "$work/dual.img" /tmp/axon7-dual.img >/dev/null
adb shell 'dd if=/tmp/axon7-dual.img of=/dev/block/bootdevice/by-name/boot bs=1M 2>&1 && sync && rm /tmp/axon7-dual.img' | grep -v tzdata
size=$(stat -c %s "$work/dual.img")
adb exec-out "dd if=/dev/block/bootdevice/by-name/boot bs=4096 count=$((size / 4096)) 2>/dev/null" | cmp - "$work/dual.img" && echo "boot partition verified: iOS + postmarketOS (hold Volume Down at boot for postmarketOS)"
