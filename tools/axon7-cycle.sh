#!/bin/bash
# One ZTE Axon 7 test cycle, run with the phone in TWRP (adb "recovery"):
# pack KERNEL + the Axon 7 ADT (+ firmware blobs) into a payload, wrap it in
# the loader shim, write it to the boot partition, reboot, wait for the
# shim/kernel to reset back into TWRP (IMEM restart reason "recovery"), and
# save the pmsg / console pstore zones to logs/.
# The ZTE LK has no `fastboot boot`, so the boot partition is used; restore
# Android with: adb push backup/stock-lineage-boot.img /tmp/ && adb shell dd
# if=/tmp/stock-lineage-boot.img of=/dev/block/bootdevice/by-name/boot
#
# Usage: tools/axon7-cycle.sh KERNEL NAME ["BOOT-ARGS"] [WAIT_SECS]
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
# the kernel wants the microcode without its 4-byte header
tail -c +5 $fw/gpu/a530_pm4.fw > "$out/pm4.bin"
tail -c +5 $fw/gpu/a530_pfp.fw > "$out/pfp.bin"
python3 -I tools/mkadt.py "$out/axon7.adt" --axon7
python3 -I tools/mkpayload.py "$kernel" "$out/axon7.adt" "$out/payload" --cmdline "$args" "${blobs[@]}"
size=$(stat -c %s "$out/payload")
# LK: Image at 0x80080000, DTB at 0x82400000 -> payload + shim < ~35 MiB
[ "$size" -lt $((35 * 1024 * 1024)) ] || { echo "payload $size bytes: too big for the LK load window" >&2; exit 1; }
WDT_SECS=${WDT_SECS:-120} shim/build-axon7.sh backup/stock-lineage-boot.img loader "$out/payload"
cp shim/out/axon7-loader.img "$out/boot.img"

[ "$(adb get-state 2>/dev/null)" = recovery ] || { echo "phone is not in TWRP (adb recovery)" >&2; exit 1; }
adb push "$out/boot.img" /tmp/axon7-boot.img >/dev/null
adb shell 'dd if=/tmp/axon7-boot.img of=/dev/block/bootdevice/by-name/boot bs=1M 2>&1 && sync' | grep -v tzdata
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
