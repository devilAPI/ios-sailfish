#!/bin/bash
# One ZTE Axon 7 test cycle, run with the phone in TWRP (adb "recovery"):
# pack KERNEL + the Axon 7 ADT (+ firmware blobs) into a payload, wrap it in
# the loader shim, write it to the boot partition, reboot, wait for the
# shim/kernel to reset back into TWRP (IMEM restart reason "recovery"), and
# save the pmsg / console pstore zones to logs/. A postmarketOS bundle on the
# boot partition is kept (dual boot, tools/axon7-dualboot.py).
# The ZTE LK has no `fastboot boot`, so the boot partition is used; restore
# Android with: adb push backup/stock-lineage-boot.img /tmp/ && adb shell dd
# if=/tmp/stock-lineage-boot.img of=/dev/block/bootdevice/by-name/boot
#
# Usage: tools/axon7-cycle.sh KERNEL NAME ["BOOT-ARGS"] [WAIT_SECS]   (WAIT_SECS 0: verify the write, reboot, do not wait)
set -euo pipefail
kernel=$(realpath "$1") name=$2
args=${3:-debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress rd=ufsroot0 wdt=-1 sweetclk=0 sweetcharge=0 sweetresetfb=0}
wait_s=${4:-240}
cd "$(dirname "$0")/.."
out=research/axon7/$name
mkdir -p "$out" logs
fw=research/firmware
blobs=()
[ -f $fw/gpu/a530_pm4.fw ] && blobs+=(--blob GPU-PM4="$out/pm4.bin" --blob GPU-PFP="$out/pfp.bin"
	--blob GPU-ZAP-MDT=$fw/gpu/a530_zap.mdt --blob GPU-ZAP-SEG=$fw/gpu/a530_zap.b02)
# Wi-Fi (sailfish_wlan.c, boot-arg sailfishwlan=1): firmware, OTP and every
# board file; the chip's OTP board id picks WLAN-BDF-<id>, else WLAN-BDF
w=$fw/wlan
if [ -f $w/qwlan30.bin ]; then
	blobs+=(--blob WLAN-OTP=$w/otp30.bin --blob WLAN-FW=$w/qwlan30.bin --blob WLAN-BDF=$w/bdwlan30.bin)
	for b in $w/bdwlan30.b[0-9a-f][0-9a-f]; do
		[ -f "$b" ] && blobs+=(--blob "WLAN-BDF-${b##*.b}=$b")
	done
fi
# Bluetooth (axon7_bt.c, boot-arg axon7bt=1): the QCA6174's rampatch and NVM
# (linux-firmware qca/*_00440302.bin, as postmarketOS) and the phone's own
# address (research/firmware/bt/bdaddr, from persist/.bt_nv.bin; never in git)
b=$fw/bt
if [ -f $b/rampatch_00440302.bin ] && [ -f $b/nvm_00440302.bin ]; then
	blobs+=(--blob BT-RAMPATCH=$b/rampatch_00440302.bin --blob BT-NVM=$b/nvm_00440302.bin)
	case " $args " in
	*" axon7bt=1 "*)
		case "$args" in *axon7btaddr=*) ;; *) [ -f $b/bdaddr ] && args="$args axon7btaddr=$(tr -d ' \n' < $b/bdaddr)" ;; esac ;;
	esac
fi
# the kernel wants the microcode without its 4-byte header
tail -c +5 $fw/gpu/a530_pm4.fw > "$out/pm4.bin"
tail -c +5 $fw/gpu/a530_pfp.fw > "$out/pfp.bin"
python3 -I tools/mkadt.py "$out/axon7.adt" --axon7
python3 -I tools/mkpayload.py "$kernel" "$out/axon7.adt" "$out/payload" --cmdline "$args" "${blobs[@]}"
size=$(stat -c %s "$out/payload")
# LK: Image at 0x80080000, DTB at 0x82400000 -> payload + shim < ~35 MiB
[ "$size" -lt $((35 * 1024 * 1024)) ] || { echo "payload $size bytes: too big for the LK load window" >&2; exit 1; }
# WDT_SECS: APSS watchdog for early-boot tests (32 s at most, clamped by the
# shim); 0 for anything that runs into the iOS userland
WDT_SECS=${WDT_SECS:-30} shim/build-axon7.sh backup/stock-lineage-boot.img loader "$out/payload"
cp shim/out/axon7-loader.img "$out/boot.img"

# BUILD_ONLY=1: stop after $out/boot.img (tools/axon7-remote-cycle.sh flashes it
# through TWRP without adb; it passes PMOS_BUNDLE or KEEP_PMOS=0)
build_only=${BUILD_ONLY:-0}
[ "$build_only" = 1 ] || [ "$(adb get-state 2>/dev/null)" = recovery ] || { echo "phone is not in TWRP (adb recovery)" >&2; exit 1; }
# Dual boot: keep the postmarketOS bundle the phone's boot partition carries
# (tools/axon7-dualboot.py; picked in the shim boot menu), or put in
# PMOS_BUNDLE=FILE; KEEP_PMOS=0 writes iOS alone.
bundle=${PMOS_BUNDLE:-}
if [ -z "$bundle" ] && [ "${KEEP_PMOS:-1}" = 1 ] && [ "$build_only" != 1 ]; then
	adb exec-out 'dd if=/dev/block/bootdevice/by-name/boot bs=1M 2>/dev/null' > "$out/boot-before.img"
	rc=0
	python3 -I tools/axon7-dualboot.py extract "$out/boot-before.img" -o "$out/pmos.bundle" 2>/dev/null || rc=$?
	case $rc in
	0) bundle=$out/pmos.bundle; echo "keeping the postmarketOS bundle from the boot partition" ;;
	3) echo "no postmarketOS bundle on the phone: iOS only" ;;
	*) echo "boot partition's postmarketOS bundle is damaged: iOS only (old image in $out/boot-before.img)" >&2 ;;
	esac
fi
if [ -n "$bundle" ]; then
	python3 -I tools/axon7-dualboot.py combine "$out/boot.img" "$bundle" -o "$out/boot-dual.img"
	python3 -I tools/axon7-dualboot.py check "$out/boot-dual.img" >/dev/null
	mv "$out/boot-dual.img" "$out/boot.img"
fi
if [ "$build_only" = 1 ]; then
	echo "built $out/boot.img ($(stat -c %s "$out/boot.img") bytes)"
	exit 0
fi
adb push "$out/boot.img" /tmp/axon7-boot.img >/dev/null
adb shell 'dd if=/tmp/axon7-boot.img of=/dev/block/bootdevice/by-name/boot bs=1M 2>&1 && sync' | grep -v tzdata
if [ "$wait_s" = 0 ]; then
	size=$(stat -c %s "$out/boot.img")
	adb exec-out "dd if=/dev/block/bootdevice/by-name/boot bs=4096 count=$((size / 4096)) 2>/dev/null" | cmp - "$out/boot.img" ||
		{ echo "boot partition does not read back as written: do not reboot, write it again" >&2; exit 1; }
	echo "boot partition written and verified ($name), rebooting"
	adb reboot
	exit 0
fi
echo "boot partition written ($name), rebooting; waiting up to ${wait_s}s for TWRP"
adb reboot
sleep 20
for _ in $(seq 1 $((wait_s / 2))); do
	[ "$(adb get-state 2>/dev/null)" = recovery ] && break
	sleep 2
done
if [ "$(adb get-state 2>/dev/null)" != recovery ]; then
	echo "no TWRP after ${wait_s}s: the phone may hang (hold power + volume up ~10 s to force TWRP)" >&2
	exit 3
fi
sleep 3
adb shell cat /sys/fs/pstore/pmsg-ramoops-0 > "logs/$name-pmsg.txt" 2>/dev/null || true
adb shell cat /sys/fs/pstore/console-ramoops > "logs/$name-console.txt" 2>/dev/null || true
wc -c "logs/$name-pmsg.txt" "logs/$name-console.txt"
tail -n 40 "logs/$name-pmsg.txt"
