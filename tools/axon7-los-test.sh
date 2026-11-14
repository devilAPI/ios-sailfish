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
#   OUTDIR: boot.img, system.img, vendor.img of the build (sparse is fine);
#   or boot.img + super.img (LineageOS 24: super goes to "system", the
#   start of los_metadata and los_data is zeroed)
#   IOS_KERNEL: kernel for the iOS slot of the test shim image (default:
#   the newest xnu/out-*/xnu-kernel/kernel.development.sweet); only the
#   shim matters for this test, the image is replaced afterwards.
#   LOS_WAIT (default 900): seconds to wait for LineageOS or TWRP.
#   LOS_RESTORE=1: phone in TWRP after a run of NAME (stopped by hand): only
#   restore its saved boot and boot menu, collect pstore, reboot (no boot test).
#   LOS_ACTIVE_HW=1: also buzz the vibrator and blink the torch (off by default:
#   tests stay quiet).
#   LOS_SETTLE=SECONDS (default 300): after boot_completed, wait up to that
#   long for the boot animation to stop and an activity to be resumed before
#   collecting (SwiftShader renders on the CPU: the first boot's boot
#   animation outlasted boot_completed, M1a run 14).
#   LOS_HOLD=SECONDS: keep LineageOS up that long after boot_completed with
#   logcat streamed to logs/NAME-live.txt (catches a later shutdown/restart).
#   LOS_INSTALL=1: install instead of a test: system, vendor and los_boot
#   only (the installed boot image and its boot menu stay), then reboot.
#   LOS_BASE=research/axon7/OLDNAME: the phone has that run's images; only
#   the MiB blocks that differ are written (then the whole partition is
#   checked). LOS_SKIP_IMAGES=1: system and vendor are already the build's. A run that
#   stopped in TWRP goes on there when started again with the same NAME.
#   LOS_SHIM=keep: no test shim; the boot partition's own shim (the normal
#   triple-boot one) starts LineageOS from the boot menu block. Needs no xnu
#   kernel or firmware blobs, and no postmarketOS when the phone is already in
#   TWRP (boot and misc are saved from there). As soon as LineageOS is on adb
#   the saved boot menu is written back from it, so a crash or reset later
#   ends in postmarketOS (no reset-to-TWRP of the test shim).
set -euo pipefail
src=$(realpath "$1") name=$2
cd "$(dirname "$0")/.."
keep=0; [ "${LOS_SHIM:-}" = keep ] && keep=1
[ $keep = 1 ] || kernel=${3:-$(ls -t xnu/out-*/xnu-kernel/kernel.development.sweet | head -1)}
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
# LineageOS 24 (lineageos-24-mainline): boot.img + super.img (dynamic
# partitions, written into the GPT partition "system"), no vendor.img
super=0; [ -f "$src/super.img" ] && [ ! -f "$src/system.img" ] && super=1
imgs="system vendor"; [ $super = 1 ] && imgs=
for f in boot $imgs; do [ -f "$src/$f.img" ] || { echo "no $src/$f.img" >&2; exit 1; }; done
for f in $imgs; do
	if [ "$(head -c 4 "$src/$f.img" | od -An -tx1 | tr -d ' ')" = 3aff26ed ]; then
		simg2img "$src/$f.img" "$out/$f.raw"
	else
		cp --reflink=auto "$src/$f.img" "$out/$f.raw"
	fi
done
python3 -I tools/axon7-androidimg.py convert "$src/boot.img" -o "$out/los-boot.img"
python3 -I tools/axon7-androidimg.py check "$out/los-boot.img"

if [ "${LOS_RESTORE:-0}" = 1 ]; then
	# LOS_RESTORE=1: the phone is in TWRP after a run of this NAME; only write back
	# its saved boot and boot-menu block, then reboot (never boots LineageOS)
	[ "$(adb get-state 2>/dev/null)" = recovery ] || { echo "LOS_RESTORE: phone not in TWRP" >&2; exit 1; }
	python3 -I tools/axon7-dualboot.py extract "$out/boot-before.img" -o "$out/pmos.bundle" >/dev/null ||
		{ echo "LOS_RESTORE: $out/boot-before.img has no postmarketOS bundle" >&2; exit 1; }
	misc_blocks=$(cat "$out/misc-blocks")
	LOS_RESTORE_ONLY=1
fi
resume=0
if [ "${LOS_RESTORE_ONLY:-0}" = 1 ]; then
	resume=1	# restore only: nothing is saved again
elif [ "$(adb get-state 2>/dev/null)" = recovery ] && [ -s "$out/boot-before.img" ] && [ -s "$out/misc-before.bin" ] && [ -s "$out/misc-blocks" ]; then
	resume=1	# a run of this NAME stopped in TWRP: go on from there
elif [ "${LOS_INSTALL:-0}" = 1 ] && [ "$(adb get-state 2>/dev/null)" = recovery ]; then
	resume=1	# install from TWRP: boot and misc are not touched
	echo 0 > "$out/misc-blocks"
elif [ $keep = 1 ] && [ "$(adb get-state 2>/dev/null)" = recovery ]; then
	say "saving boot and the boot-menu block from TWRP"
	adb exec-out "dd if=$(adb shell "for b in /sys/class/block/*; do grep -q '^PARTNAME=boot\$' \$b/uevent 2>/dev/null && echo /dev/block/\${b##*/}; done" | tr -d '\r' | head -1) bs=1M 2>/dev/null" > "$out/boot-before.img"
	python3 -I tools/axon7-dualboot.py extract "$out/boot-before.img" -o "$out/pmos.bundle" >/dev/null ||
		{ echo "no postmarketOS bundle in the boot partition: refusing" >&2; exit 1; }
	md=$(adb shell "for b in /sys/class/block/*; do grep -q '^PARTNAME=misc\$' \$b/uevent 2>/dev/null && echo \${b##*/}; done" | tr -d '\r' | head -1)
	echo $(( $(adb shell cat /sys/class/block/$md/size | tr -d '\r') / 8 )) > "$out/misc-blocks"
	adb exec-out "dd if=/dev/block/$md bs=4096 skip=$(( $(cat "$out/misc-blocks") - 1 )) count=1 2>/dev/null" > "$out/misc-before.bin"
	[ "$(stat -c %s "$out/misc-before.bin")" = 4096 ] || { echo "could not read the misc block" >&2; exit 1; }
	resume=1
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
if [ $keep = 1 ]; then
	cp "$out/boot-before.img" "$out/boot.img"	# the phone's own shim stays
elif [ "$install" != 1 ] && [ "${LOS_RESTORE_ONLY:-0}" != 1 ]; then
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
if [ "${LOS_RESTORE_ONLY:-0}" != 1 ]; then
say "TWRP: writing system, vendor, los_boot, test boot, boot menu"
if [ "${LOS_SKIP_IMAGES:-0}" != 1 ] && [ $super = 1 ]; then
	# data chunks of the sparse super image only, each read back (sha1)
	d=$(dev system); [ -n "$d" ] || { echo "no partition system" >&2; exit 1; }
	# research/axon7/super-on-phone: the super.img last written and verified
	# (path, sha256); with it only the changed MiB are written (the full check
	# that follows catches a phone that holds something else, then rewrites all)
	rec=research/axon7/super-on-phone base=()
	if [ -s "$rec" ]; then
		read -r bpath bsum < "$rec"
		if [ -f "$bpath" ] && [ "$(sha256sum < "$bpath" | cut -d' ' -f1)" = "$bsum" ]; then
			base=(--base "$bpath")
		fi
	fi
	rm -f "$rec"
	python3 -I tools/axon7-simg-put.py "$src/super.img" "$d" "${base[@]}" ||
		{ echo "super.img -> $d failed" >&2; exit 1; }
	echo "$src/super.img $(sha256sum < "$src/super.img" | cut -d' ' -f1)" > "$rec"	# keep that file for the next run
	echo "   super.img -> system ($d) written and verified"
	# a new install: 22.2's (or an older 24's) metadata and FBE data are no use
	for p in los_metadata:16 los_data:64; do
		d=$(dev "${p%:*}"); [ -n "$d" ] || { echo "no partition ${p%:*}" >&2; exit 1; }
		adb shell "dd if=/dev/zero of=$d bs=1048576 count=${p#*:} 2>/dev/null; sync"
		echo "   ${p%:*} ($d): first ${p#*:} MiB zeroed"
	done
elif [ "${LOS_SKIP_IMAGES:-0}" != 1 ]; then	# LOS_SKIP_IMAGES=1: system and vendor are current
	put "$out/system.raw" system
	put "$out/vendor.raw" vendor
fi
put "$out/los-boot.img" los_boot
if [ "$install" = 1 ]; then
	adb reboot
	say "installed; the boot menu is as it was"
	exit 0
fi
[ $keep = 1 ] || put "$out/boot.img" boot
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
	timeout 30 adb root >/dev/null 2>&1 || true
	sleep 5
	# a panic right after boot (hard reset, the test shim's TWRP mark is lost)
	# ends in postmarketOS: never wait for adb without a limit
	timeout 120 adb wait-for-device || true
	if [ $keep = 1 ]; then	# normal shim: put the boot menu back now, a reset must not loop into LineageOS
		timeout 60 adb wait-for-device || true; sleep 3	# adbd restarts after adb root
		md=$(timeout 20 adb shell "for b in /sys/class/block/*; do grep -q '^PARTNAME=misc\$' \$b/uevent 2>/dev/null && echo /dev/block/\${b##*/}; done" | tr -d '\r' | head -1) || true
		[ -n "$md" ] && timeout 30 adb push "$out/misc-before.bin" /data/local/tmp/misc-before.bin >/dev/null &&
		timeout 30 adb shell "dd if=/data/local/tmp/misc-before.bin of=$md bs=4096 seek=$(( misc_blocks - 1 )) conv=notrunc 2>/dev/null; sync" &&
		[ "$(timeout 30 adb exec-out "dd if=$md bs=4096 skip=$(( misc_blocks - 1 )) count=1 2>/dev/null" | sha1sum)" = "$(sha1sum < "$out/misc-before.bin")" ] &&
			echo "   boot menu restored from LineageOS" || echo "   could not restore the boot menu from LineageOS (TWRP does it later)" >&2
	fi
	for i in $(seq 1 60); do [ "$(timeout 20 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; [ "$(adb get-state 2>/dev/null || true)" = device ] || break; sleep 5; done
	settle=${LOS_SETTLE:-300} t0=$SECONDS
	while [ $((SECONDS - t0)) -lt "$settle" ]; do
		[ "$(adb get-state 2>/dev/null || true)" = device ] || break
		[ "$(timeout 20 adb shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')" = running ] || \
			{ timeout 20 adb shell dumpsys activity activities 2>/dev/null | grep -q 'mResumedActivity\|ResumedActivity:' && break; }
		sleep 10
	done
	sleep 15	# let the first frame of the resumed activity reach the screen
	say "settled after $((SECONDS - t0)) s: $(timeout 20 adb shell dumpsys activity activities 2>/dev/null | grep -m1 -o 'ResumedActivity:.*' | tr -d '\r')"
	if [ "${LOS_HOLD:-0}" -gt 0 ]; then
		say "keeping LineageOS up for ${LOS_HOLD} s, logcat streamed to logs/$name-live.txt"
		( while adb shell 'echo $(date +%T) backlight=$(cat /sys/class/leds/lcd-backlight/brightness) $(dumpsys power | grep -m1 -o "mWakefulness=[A-Za-z]*")' 2>&1 | tr -d '\r'; do sleep 30; done ) > "logs/$name-backlight.txt" &
		bl=$!
		# sleep/wake cycles after 1 min (power key events): wake-up time in the live
		# log; with root, both DSPPs' (0x55000, 0x57000; PCC +0x1700) and the AD
		# blocks' registers before sleep, after a wake, and after a wake without
		# ppd (display post-processing) go to logs/NAME-dspp.txt
		cat > "$out/dspp.sh" <<'DSPP'
d=/sys/kernel/debug/mdp; [ -d $d ] || d=/sys/kernel/debug/mdss_mdp
echo "== $1 $(date +%T) wake=$(dumpsys power | grep -m1 -o 'mWakefulness=[A-Za-z]*') ppd=$(getprop init.svc.ppd) dir=$d"
sh /data/local/tmp/regs.sh $d
DSPP
		adb push "$out/dspp.sh" /data/local/tmp/dspp.sh >/dev/null 2>&1 || true
		adb push tools/axon7-mdss-regs.sh /data/local/tmp/regs.sh >/dev/null 2>&1 || true
		# which input device sends KEY_POWER (phantom power key presses)
		( timeout "$LOS_HOLD" adb shell 'getevent -lt' > "logs/$name-getevent.txt" 2>&1 ) &
		( sleep 60
		  adb shell 'sh /data/local/tmp/dspp.sh before; input keyevent KEYCODE_SLEEP; sleep 15; input keyevent KEYCODE_WAKEUP; sleep 10; sh /data/local/tmp/dspp.sh after-wake; setprop ctl.stop ppd; sleep 3; input keyevent KEYCODE_SLEEP; sleep 15; input keyevent KEYCODE_WAKEUP; sleep 10; sh /data/local/tmp/dspp.sh after-wake-no-ppd; setprop ctl.start ppd; sleep 5; input keyevent KEYCODE_SLEEP; sleep 15; input keyevent KEYCODE_WAKEUP; sleep 10; sh /data/local/tmp/dspp.sh after-wake-ppd-again' > "logs/$name-dspp.txt" 2>&1 ) &
		wk=$!
		timeout "$LOS_HOLD" adb logcat -b all -v threadtime > "logs/$name-live.txt" 2>&1 || true
		kill "$bl" "$wk" 2>/dev/null || true
		adb shell 'dmesg' > "logs/$name-dmesg-hold.txt" 2>&1 || true
		# state stays "device": if adb is gone now, the next block waits for
		# TWRP or postmarketOS (a test-build panic resets into postmarketOS)
		echo "   adb state after the hold: $(adb get-state 2>/dev/null || echo none)"
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
	timeout 120 adb shell 'getprop' > "logs/$name-getprop.txt" 2>&1 || true
	timeout 120 adb shell 'cat /proc/cmdline; uname -a; mount; df -h; ls -l /dev/block/by-name/; echo backlight $(cat /sys/class/leds/lcd-backlight/brightness /sys/class/leds/lcd-backlight/max_brightness); dumpsys power | grep -m3 -iE "mWakefulness=|mScreenOn|Display Power"' > "logs/$name-system.txt" 2>&1 || true
	timeout 120 adb shell 'dmesg' > "logs/$name-dmesg.txt" 2>&1 || true
	timeout 600 adb logcat -d -b all > "logs/$name-logcat.txt" 2>&1 || true
	timeout 120 adb exec-out 'screencap -p' > "logs/$name-screen.png" 2>/dev/null || true
	# hardware: modem (no SIM needed: baseband, IMEI, radio power, emergency-only
	# registration, signal), GPS, camera, fingerprint, Wi-Fi, sensors, audio
	# research/axon7/bin/sensread from lineageos-24-mainline/tools/sensread.c
	[ -x research/axon7/bin/sensread ] && timeout 30 adb push research/axon7/bin/sensread /data/local/tmp/ > /dev/null 2>&1
	timeout 300 adb shell '
		echo "== modem subsystem"; for s in /sys/bus/msm_subsys/devices/*; do echo "$(cat $s/name 2>/dev/null) $(cat $s/state 2>/dev/null)"; done
		echo "== radio props"; getprop | grep -E "gsm\.|ril\.|vendor.radio|persist.radio.multisim|baseband"
		echo "== rild"; ps -A -o PID,NAME | grep -E "rild|qmuxd|pm-service|per_mgr|netmgrd|cnd|ims"
		echo "== radio services"; service list | grep -iE "radio|ims|telephony" | head -40
		echo "== telephony.registry"; dumpsys telephony.registry | grep -E "mServiceState|mSignalStrength|mDataConnectionState|mCallState|mPhoneCapability" | head -20
		echo "== phone"; dumpsys phone | grep -iE "imei|baseband|mRadioState|RadioPowerState|isRadioOn|mServiceState" | head -20
		echo "== imei"; service call iphonesubinfo 1 s16 com.android.shell 2>&1 | head -5
		echo "== gnss"; dumpsys location | grep -iE "gnss|gps" | head -15
		echo "== camera"; dumpsys media.camera | grep -iE "Number of camera|Camera [0-9]|facing|error|Device [0-9]" | head -15
		echo "== fingerprint"; dumpsys fingerprint | head -15
		echo "== wifi"; dumpsys wifi | grep -iE "Wi-Fi is|mWifiState|supplicant state|interface" | head -10; ip link | grep -E "wlan|p2p"
		echo "== wifi scan"; cmd wifi set-wifi-enabled enabled 2>&1; sleep 10; cmd wifi status 2>&1 | head -4; cmd wifi start-scan 2>&1; sleep 10; cmd wifi list-scan-results 2>&1 | head -8
		echo "== bluetooth"; dumpsys bluetooth_manager | grep -iE "enabled|state:|name:" | head -6
		echo "== sensors"; dumpsys sensorservice | grep -E "^[0-9a-fx]+\)|Total [0-9]+ h/w sensors" | head -30
		echo "== sensors kernel"; dmesg | grep -E "axon7m-sns-reg|axon7m-slpi-kick|smgr" | tail -8; for d in /sys/bus/iio/devices/iio:device*; do echo "$d $(cat $d/name)"; done; logcat -d -s axon7m-sensors | tail -8
		echo "== sensor values"; [ -x /data/local/tmp/sensread ] && timeout 30 /data/local/tmp/sensread 2 2>&1
		echo "== audio"; dumpsys media.audio_flinger | grep -iE "Output thread|Input thread|HAL|hw module|primary" | head -10
		echo "== nfc"; dumpsys nfc 2>&1 | grep -iE "mState|state=|enabled|mIsNfc|NfcService" | head -8
		echo "== sound cards"; cat /proc/asound/cards; ls /dev/snd | head -40 | tr "\n" " "; echo
		echo "== asoc"; for f in platforms codecs dais; do echo "-- $f"; cat /sys/kernel/debug/asoc/$f 2>&1 | tr "\n" " "; echo; done
		echo "== vibrator"; dumpsys vibrator_manager 2>&1 | grep -iE "hal|capabilit|vibrator id|isVibrating" | head -6; dmesg | grep -iE "haptic|vibrat" | tail -4
		if [ "'"${LOS_ACTIVE_HW:-0}"'" = 1 ]; then	# vibration and torch only on request (quiet tests)
		echo "== vibrator buzz"; cmd vibrator_manager synced -f oneshot 150 2>&1 | head -2
		echo "== torch"; cmd media.camera 2>/dev/null | head -1; for t in /sys/class/leds/torch-light0 /sys/class/leds/led:torch_0; do [ -e $t/brightness ] && { echo 50 > $t/brightness; sleep 1; echo "$t $(cat $t/brightness)"; echo 0 > $t/brightness; }; done
		fi
		echo "== failing services"; getprop | grep -E "init.svc.*\[(restarting|stopped)\]"
		echo "== sysfs paths"; ls -l /sys/class/rfkill/ /sys/class/power_supply/ /sys/class/leds/ 2>&1 | grep -- "->"; ls -Z /sys/class/rfkill/*/state /sys/class/power_supply/*/type 2>&1
	' > "logs/$name-hw.txt" 2>&1 || true
	# audio, silent: mixer routes and a 3 s recording from the built-in mics
	# (hw:0,0, level only; nothing is played)
	timeout 120 adb shell '
		echo "== audio routes"; dmesg | grep "axon7m-audio"
		for c in "SLIMBUS_0_RX Audio Mixer MultiMedia2" "MultiMedia1 Mixer SLIMBUS_0_TX" "Bottom Speaker Switch" "Top Speaker Switch" "SDTO2 Source Selector" "SBO1L Source Selector" "Mic_1L input Selector" "Mic_1R input Selector"; do tinymix "$c" 2>&1 | head -1; done
		echo "== mic capture"; rm -f /data/local/tmp/axon7-mic.wav; tinycap /data/local/tmp/axon7-mic.wav -D 0 -d 0 -c 2 -r 48000 -b 16 -p 960 -n 4 -T 3 2>&1 | tail -2; ls -l /data/local/tmp/axon7-mic.wav
	' > "logs/$name-audio.txt" 2>&1 || true
	timeout 60 adb pull /data/local/tmp/axon7-mic.wav "logs/$name-mic.wav" > /dev/null 2>&1 || true
	# Android capture path (AAudio -> audioserver -> HAL), recording only:
	# research/axon7/bin/aarec from lineageos-24-mainline/tools/aarec.c
	if [ -x research/axon7/bin/aarec ]; then
		timeout 30 adb push research/axon7/bin/aarec /data/local/tmp/ > /dev/null 2>&1
		timeout 60 adb shell 'timeout 20 /data/local/tmp/aarec 2 2>&1' >> "logs/$name-audio.txt" 2>&1 || true
	fi
	# per-device mixer routes of the HAL (hardware/interfaces patch 0002) and the jack
	timeout 120 adb shell '
		echo "== HAL routes"; logcat -d -b all | grep -E "applyMixerRoute|mixerRoutes|populateConnectedDevicePort" | tail -12
		for c in "QUAT_MI2S_RX Audio Mixer MultiMedia2" "SLIMBUS_0_RX Audio Mixer MultiMedia2" "Speaker Top Receiver Switch" "Top Speaker Switch" "Bottom Speaker Switch"; do tinymix "$c" 2>&1 | head -1; done
		echo "== jack"; getevent -pl 2>/dev/null | grep -A6 "Headset Jack" | grep -E "name|SW_"; dumpsys audio | grep -iE "wired|headset|DevInputEvent" | head -8
	' >> "logs/$name-audio.txt" 2>&1 || true
	# camera: open the camera app for a preview (screenshot) and keep the HAL log of it
	timeout 120 adb shell 'svc power stayon true; input keyevent KEYCODE_WAKEUP; sleep 2; wm dismiss-keyguard; sleep 1; logcat -b all -c; am start -W -n org.lineageos.aperture/.CameraLauncher 2>&1 || am start -W -a android.media.action.STILL_IMAGE_CAMERA 2>&1; sleep 12; dumpsys activity activities | grep -m3 -E "mResumedActivity|topResumedActivity"' > "logs/$name-camera-start.txt" 2>&1 || true
	timeout 120 adb exec-out 'screencap -p' > "logs/$name-camera-preview.png" 2>/dev/null || true
	timeout 120 adb shell 'dumpsys media.camera' > "logs/$name-camera-dump.txt" 2>&1 || true
	timeout 600 adb shell 'logcat -d -b all -v threadtime | grep -vE "avc:  denied" | grep -iE "QCamera|CameraDevice|Camera3-|CameraService|mm-camera|aperture|CameraProvider|AndroidRuntime" | tail -200; input keyevent KEYCODE_HOME; svc power stayon false' > "logs/$name-camera-open.txt" 2>&1 || true
	# camera: restart the daemon and the provider with HAL debug logging (root)
	timeout 300 adb shell '
		setprop persist.camera.hal.debug 4; setprop persist.camera.global.debug 4; setprop persist.camera.mct.debug 4
		setprop persist.camera.sensor.debug 4; setprop persist.camera.eeprom.debug 4; setprop persist.camera.isp.debug 2
		setprop persist.vendor.camera.hal.debug 4; setprop persist.vendor.camera.global.debug 4; setprop persist.vendor.camera.sensor.debug 4
		logcat -c
		stop vendor.camera-provider-2-4; stop qcamerasvr; sleep 1; start qcamerasvr; sleep 3; start vendor.camera-provider-2-4; sleep 8
		dumpsys media.camera | grep -iE "Number of camera|Camera [0-9]" 
		logcat -d -b all -v threadtime | grep -vE "avc:  denied|print_matrix|pdafgain" | grep -iE "camera|mm-qcamera|mct|sensor|eeprom|QCamera|cam_|chromatix" > /data/local/tmp/camdbg.txt; wc -l /data/local/tmp/camdbg.txt; head -1500 /data/local/tmp/camdbg.txt
		echo "== sensor kernel"; dmesg | grep -iE "msm_sensor|sensor_config|s5k2t8|ov8856|power_up|power_down|cci" | tail -60
		dmesg | grep -iE "msm_sensor|eeprom|actuator|cci|camera|cam_|csid|csiphy|ispif|vfe|cpp" | tail -80
		echo "== camera nodes"; ls -lZ /dev/media* /dev/video* /dev/v4l-subdev* 2>&1 | head -60
		for v in /sys/class/video4linux/*; do echo "$v $(cat $v/name)"; done
		p=$(pidof android.hardware.camera.provider@2.4-service_64 android.hardware.camera.provider@2.4-service | head -1)
		echo "== provider pid $p"; grep -E "camera|mmcamera|mm-camera" /proc/$p/maps 2>/dev/null | awk "{print \$6}" | sort -u
		echo "== provider log"; logcat -d -b all -v threadtime --pid=$p | tail -150
		echo "== cameraserver"; logcat -d -b all -v threadtime | grep -iE "CameraProviderManager|CameraService|HidlProviderInfo" | tail -40
	' > "logs/$name-camera.txt" 2>&1 || true
	echo "   boot_completed=$(adb shell getprop sys.boot_completed | tr -d '\r')"
	adb reboot recovery
	waitfor recovery 300 || { echo "LineageOS did not reboot to TWRP" >&2; exit 3; }
elif [ "$state" = pmos ]; then
	say "LineageOS restarted into postmarketOS: to TWRP for the logs and the restore"
	# a panic restart is a hard reset into postmarketOS; its systemd-pstore has
	# moved the LineageOS crash record (dmesg-ramoops-*) to /var/lib/systemd/pstore
	for f in $(root 'ls -1 /var/lib/systemd/pstore' 2>/dev/null); do
		root "cat /var/lib/systemd/pstore/$f" > "logs/$name-pmos-pstore-$f.txt" 2>/dev/null || true
	done
	root 'rm -f /var/lib/systemd/pstore/*' >/dev/null 2>&1 || true
	root 'systemctl reboot --reboot-argument=recovery' >/dev/null 2>&1 || true
	waitfor recovery 300 || { echo "no TWRP on adb after 300 s" >&2; exit 3; }
elif [ "$state" != recovery ]; then
	say "no adb from LineageOS: waiting for its time limit (25 min) and TWRP"
	waitfor recovery 1800 || { echo "neither LineageOS nor TWRP on adb: the phone needs a look" >&2; exit 3; }
fi
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
# reference: the same display registers on TWRP's ZTE 3.18 kernel (after the restore: should
# TWRP crash, the phone boots the normal menu; its
# wake-up does not show the half-screen colour bug), before and after a blank
adb push tools/axon7-mdss-regs.sh /tmp/regs.sh >/dev/null 2>&1 && adb shell '
	mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
	d=/sys/kernel/debug/mdp; [ -d $d ] || d=/sys/kernel/debug/mdss_mdp
	echo "== twrp-before"; sh /tmp/regs.sh $d
	echo 1 > /sys/class/graphics/fb0/blank; sleep 3; echo 0 > /sys/class/graphics/fb0/blank; sleep 3
	echo "== twrp-after-unblank"; sh /tmp/regs.sh $d' > "logs/$name-twrp-regs.txt" 2>&1 || true
adb reboot
say "back to postmarketOS"
for i in $(seq 1 60); do on true 2>/dev/null && break; sleep 5; done
on 'uptime' || echo "postmarketOS not reachable yet" >&2
ls -la logs/"$name"-* 2>/dev/null
