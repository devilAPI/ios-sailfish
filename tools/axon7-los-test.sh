#!/bin/bash
# One unattended LineageOS boot test on the ZTE Axon 7 (triple boot), with
# the phone running postmarketOS (reachable over SSH) and on USB to this PC:
#
#   postmarketOS  save boot + the misc boot-menu block, reboot to TWRP
#   TWRP (adb)    system, vendor <- the build; los_boot <- its boot.img for
#                 the shim (axon7-androidimg.py); boot <- a test shim
#                 (LOS_TEST=1: one LineageOS boot, any reset after it
#                 goes to TWRP, a hang before the kernel's watchdog
#                 driver ends after 30 s); misc <- "LineageOS after 1 s"
#   LineageOS     if adb comes up (test builds: AXON7_ADB_KEYS): props,
#                 mounts, dmesg, logcat, a screenshot; then reboot recovery.
#                 Test builds restart a boot that hangs after 25 min
#                 (axon7-testguard.sh), the shim then goes to TWRP
#   TWRP          pstore (kernel log of the boot), boot and misc restored,
#                 reboot to postmarketOS
#
# userdata (iOS) and the microSD card (postmarketOS) are not written; the
# build must use los_data for /data (device tree fstab).
#
# Usage: PMOS_HOST=user@phone [PMOS_SUDO_PASS=..] [PMOS_SSH_OPTS=..] \
#        tools/axon7-los-test.sh OUTDIR NAME [IOS_KERNEL]
#   OUTDIR: boot.img, system.img, vendor.img of the build (sparse is fine)
#   IOS_KERNEL: kernel for the iOS slot of the test shim image (default:
#   the newest xnu/out-*/xnu-kernel/kernel.development.sweet); only the
#   shim matters for this test, the image is replaced afterwards.
#   LOS_WAIT (default 900): seconds to wait for LineageOS or TWRP.
#   LOS_HOLD=SECONDS: keep LineageOS up that long after boot_completed with
#   logcat streamed to logs/NAME-live.txt (catches a later shutdown/restart).
#   LOS_INSTALL=1: install instead of a test: system, vendor and los_boot
#   only (the installed boot image and its boot menu stay), then reboot.
#   LOS_BASE=research/axon7/OLDNAME: the phone has that run's images; only
#   the MiB blocks that differ are written (then the whole partition is
#   checked). LOS_SKIP_IMAGES=1: system and vendor are already the build's. A run that
#   stopped in TWRP goes on there when started again with the same NAME.
set -euo pipefail
src=$(realpath "$1") name=$2
cd "$(dirname "$0")/.."
kernel=${3:-$(ls -t xnu/out-*/xnu-kernel/kernel.development.sweet | head -1)}
host=${PMOS_HOST:?set PMOS_HOST=user@phone}
wait_s=${LOS_WAIT:-900}
out=research/axon7/$name
mkdir -p "$out" logs
read -r -a extra <<< "${PMOS_SSH_OPTS:-}"
sshopt=(-o ConnectTimeout=10 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new "${extra[@]}")
on() { ssh "${sshopt[@]}" "$host" "$@" </dev/null; }
root() { printf '%s\n' "${PMOS_SUDO_PASS:-}" | ssh "${sshopt[@]}" "$host" "sudo -S -p '' sh -c '$1'"; }
say() { echo "== $* ($(date +%T))"; }

say "images"
for f in boot system vendor; do [ -f "$src/$f.img" ] || { echo "no $src/$f.img" >&2; exit 1; }; done
for f in system vendor; do
	if [ "$(head -c 4 "$src/$f.img" | od -An -tx1 | tr -d ' ')" = 3aff26ed ]; then
		simg2img "$src/$f.img" "$out/$f.raw"
	else
		cp --reflink=auto "$src/$f.img" "$out/$f.raw"
	fi
done
python3 -I tools/axon7-androidimg.py convert "$src/boot.img" -o "$out/los-boot.img"
python3 -I tools/axon7-androidimg.py check "$out/los-boot.img"

resume=0
if [ "$(adb get-state 2>/dev/null)" = recovery ] && [ -s "$out/boot-before.img" ] && [ -s "$out/misc-before.bin" ] && [ -s "$out/misc-blocks" ]; then
	resume=1	# a run of this NAME stopped in TWRP: go on from there
elif [ "${LOS_INSTALL:-0}" = 1 ] && [ "$(adb get-state 2>/dev/null)" = recovery ]; then
	resume=1	# install from TWRP: boot and misc are not touched
	echo 0 > "$out/misc-blocks"
fi
if [ $resume = 1 ]; then
	say "resuming in TWRP with the saved boot and boot-menu block"
	misc_blocks=$(cat "$out/misc-blocks")
else
say "saving boot and the boot-menu block from postmarketOS"
on true || { echo "postmarketOS not reachable as $host" >&2; exit 1; }
root 'dd if=/dev/disk/by-partlabel/boot bs=1M 2>/dev/null' > "$out/boot-before.img"
python3 -I tools/axon7-dualboot.py extract "$out/boot-before.img" -o "$out/pmos.bundle" >/dev/null ||
	{ echo "no postmarketOS bundle in the boot partition: refusing" >&2; exit 1; }
misc_blocks=$(( $(root 'blockdev --getsize64 /dev/disk/by-partlabel/misc') / 4096 ))
root "dd if=/dev/disk/by-partlabel/misc bs=4096 skip=$((misc_blocks - 1)) count=1 2>/dev/null" > "$out/misc-before.bin"
[ "$(stat -c %s "$out/misc-before.bin")" = 4096 ] || { echo "could not read the misc block" >&2; exit 1; }
echo "$misc_blocks" > "$out/misc-blocks"
fi
python3 -I -c 'import struct,sys; sys.stdout.buffer.write((b"AX7BOOT1"+struct.pack("<III",2,1,2^0xa5a5a5a5)).ljust(4096,b"\0"))' > "$out/misc-los.bin"

install=${LOS_INSTALL:-0}
if [ "$install" != 1 ]; then
say "test shim image (LOS_TEST=1)"
LOS_TEST=1 WDT_SECS=0 BUILD_ONLY=1 PMOS_BUNDLE="$out/pmos.bundle" \
	tools/axon7-cycle.sh "$kernel" "$name" "$(cat tools/axon7-bootargs.txt)" >/dev/null
python3 -I tools/axon7-dualboot.py check "$out/boot.img" >/dev/null
fi

if [ $resume = 0 ]; then
	say "postmarketOS -> TWRP"
	root 'systemctl reboot --reboot-argument=recovery' >/dev/null 2>&1 || true
fi
waitfor() {	# adb state: recovery or device
	local want=$1 secs=$2 t=0
	while [ $t -lt "$secs" ]; do
		[ "$(adb get-state 2>/dev/null)" = "$want" ] && return 0
		sleep 5; t=$((t + 5))
	done
	return 1
}
waitfor recovery 300 || { echo "no TWRP on adb after 300 s" >&2; exit 3; }
sleep 5
# exec-in returns when this side is done sending, dd on the phone may still write
adb_settle() { adb shell 'while pidof dd >/dev/null; do sleep 1; done; sync' >/dev/null; }
# partitions by name (TWRP sometimes has no by-name links)
dev() { adb shell "for b in /sys/class/block/*; do grep -q '^PARTNAME=$1\$' \$b/uevent 2>/dev/null && echo /dev/block/\${b##*/}; done" | tr -d '\r' | head -1; }
put() {	# FILE PARTNAME: stream (or only the MiB blocks that differ from LOS_BASE), then compare
	local f=$1 d n base=
	case $2 in system|vendor) base=${LOS_BASE:+$LOS_BASE/$(basename "$1")} ;; esac	# only these hold the base run's data
	d=$(dev "$2"); [ -n "$d" ] || { echo "no partition $2" >&2; exit 1; }
	n=$(stat -c %s "$f")
	if [ -n "$base" ] && [ -f "$base" ] && [ "$(stat -c %s "$base")" = "$n" ]; then
		# LOS_BASE: a run whose images are on the phone; adb in TWRP manages ~3.4 MB/s
		python3 -I -c 'import sys
a,b=open(sys.argv[1],"rb"),open(sys.argv[2],"rb"); i=0
while True:
    x,y=a.read(1<<20),b.read(1<<20)
    if not x: break
    if x!=y: print(i)
    i+=1' "$f" "$base" > "$out/delta-$2"
		echo "   $2: $(wc -l < "$out/delta-$2") MiB differ from $base"
		while read -r i; do
			dd if="$f" bs=1048576 skip="$i" count=1 2>/dev/null |
				adb exec-in "dd of=$d bs=1048576 seek=$i conv=notrunc 2>/dev/null"	# no count: pipe reads come in pieces
		done < "$out/delta-$2"
	else
		adb exec-in "dd of=$d bs=1048576 2>/dev/null" < "$f"
	fi
	adb_settle
	local a b
	a=$(sha1sum < "$f" | cut -d' ' -f1)
	b=$(adb exec-out "head -c $n $d | sha1sum" | cut -d' ' -f1)
	[ "$a" = "$b" ] || { echo "$2 ($d) does not read back as written" >&2; exit 1; }
	echo "   $2 ($d): $n bytes written and verified"
}
putblk() {	# FILE: the last block of misc
	local d; d=$(dev misc)
	adb exec-in "dd of=$d bs=4096 seek=$((misc_blocks - 1)) 2>/dev/null" < "$1"
	adb_settle
	[ "$(adb exec-out "dd if=$d bs=4096 skip=$((misc_blocks - 1)) count=1 2>/dev/null" | sha1sum)" = "$(sha1sum < "$1")" ] ||
		{ echo "misc block does not read back" >&2; exit 1; }
}
say "TWRP: writing system, vendor, los_boot, test boot, boot menu"
if [ "${LOS_SKIP_IMAGES:-0}" != 1 ]; then	# LOS_SKIP_IMAGES=1: system and vendor are current
	put "$out/system.raw" system
	put "$out/vendor.raw" vendor
fi
put "$out/los-boot.img" los_boot
if [ "$install" = 1 ]; then
	adb reboot
	say "installed; the boot menu is as it was"
	exit 0
fi
put "$out/boot.img" boot
putblk "$out/misc-los.bin"
adb reboot

say "waiting for LineageOS (adb device), TWRP (adb recovery) or postmarketOS, up to $wait_s s"
pmos_up() {	# the test build's post-fs step points the boot menu at postmarketOS
	ping -c 1 -W 1 "${host#*@}" >/dev/null 2>&1 && on true 2>/dev/null
}
state=
for t in $(seq 0 5 "$wait_s"); do
	state=$(adb get-state 2>/dev/null || true)
	[ "$state" = device ] || [ "$state" = recovery ] && break
	if [ $((t % 30)) = 25 ] && pmos_up; then state=pmos; break; fi
	sleep 5
done
echo "   adb state: ${state:-none} after ${t}s"
if [ "$state" = device ]; then
	say "LineageOS is up"
	adb root >/dev/null 2>&1 || true
	sleep 5
	adb wait-for-device
	for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] && break; sleep 5; done
	if [ "${LOS_HOLD:-0}" -gt 0 ]; then
		say "keeping LineageOS up for ${LOS_HOLD} s, logcat streamed to logs/$name-live.txt"
		( while adb shell 'echo $(date +%T) backlight=$(cat /sys/class/leds/lcd-backlight/brightness) $(dumpsys power | grep -m1 -o "mWakefulness=[A-Za-z]*")' 2>&1 | tr -d '\r'; do sleep 30; done ) > "logs/$name-backlight.txt" &
		bl=$!
		timeout "$LOS_HOLD" adb logcat -b all -v threadtime > "logs/$name-live.txt" 2>&1 || true
		kill "$bl" 2>/dev/null || true
		state=$(adb get-state 2>/dev/null || true)
		echo "   adb state after the hold: ${state:-none}"
	fi
fi
if [ "$state" = device ] && [ "$(adb get-state 2>/dev/null || true)" != device ]; then
	say "LineageOS went away during the hold: waiting for TWRP or postmarketOS"
	state=
	for t in $(seq 0 10 1800); do
		[ "$(adb get-state 2>/dev/null || true)" = recovery ] && { state=recovery; break; }
		if [ $((t % 30)) = 0 ] && pmos_up; then state=pmos; break; fi
		sleep 10
	done
	echo "   then: ${state:-nothing} after ${t}s"
fi
if [ "$state" = device ]; then
	say "collecting"
	adb shell 'getprop' > "logs/$name-getprop.txt" 2>&1 || true
	adb shell 'cat /proc/cmdline; uname -a; mount; df -h; ls -l /dev/block/by-name/; echo backlight $(cat /sys/class/leds/lcd-backlight/brightness /sys/class/leds/lcd-backlight/max_brightness); dumpsys power | grep -m3 -iE "mWakefulness=|mScreenOn|Display Power"' > "logs/$name-system.txt" 2>&1 || true
	adb shell 'dmesg' > "logs/$name-dmesg.txt" 2>&1 || true
	adb logcat -d -b all > "logs/$name-logcat.txt" 2>&1 || true
	adb exec-out 'screencap -p' > "logs/$name-screen.png" 2>/dev/null || true
	echo "   boot_completed=$(adb shell getprop sys.boot_completed | tr -d '\r')"
	adb reboot recovery
	waitfor recovery 300 || { echo "LineageOS did not reboot to TWRP" >&2; exit 3; }
elif [ "$state" = pmos ]; then
	say "LineageOS restarted into postmarketOS: to TWRP for the logs and the restore"
	root 'systemctl reboot --reboot-argument=recovery' >/dev/null 2>&1 || true
	waitfor recovery 300 || { echo "no TWRP on adb after 300 s" >&2; exit 3; }
elif [ "$state" != recovery ]; then
	say "no adb from LineageOS: waiting for its time limit (25 min) and TWRP"
	waitfor recovery 1800 || { echo "neither LineageOS nor TWRP on adb: the phone needs a look" >&2; exit 3; }
fi
sleep 5
say "TWRP: kernel log of the LineageOS boot, restoring boot and the boot menu"
adb shell 'mount -t pstore pstore /sys/fs/pstore 2>/dev/null; ls -1 /sys/fs/pstore' | tr -d '\r' | while read -r f; do
	[ -n "$f" ] && adb exec-out "cat /sys/fs/pstore/$f" > "logs/$name-pstore-$f.txt"
done
# axon7-testlog.sh (test builds): props, dmesg, logcat of a boot that got to post-fs
md=$(dev los_metadata)
[ -n "$md" ] && adb exec-out "head -c 16777216 $md" | strings -n 4 > "logs/$name-testlog.txt"
put "$out/boot-before.img" boot
putblk "$out/misc-before.bin"
adb reboot
say "back to postmarketOS"
for i in $(seq 1 60); do on true 2>/dev/null && break; sleep 5; done
on 'uptime' || echo "postmarketOS not reachable yet" >&2
ls -la logs/"$name"-* 2>/dev/null
