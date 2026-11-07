#!/bin/bash
# One iOS test boot of the ZTE Axon 7 driven from postmarketOS, without USB
# or anyone at the phone. The phone runs postmarketOS (boot menu default
# postmarketOS) and is reachable over SSH; TWRP does the flashing through
# OpenRecoveryScripts in /cache:
#
#   postmarketOS  save boot + the misc boot-menu block, put the test image,
#                 the old image and two scripts on /cache, reboot to TWRP
#   TWRP (1)      boot <- test image, misc <- "iOS after 1 s", queue script 2
#   iOS           the test; the kernel must end in a panic (e.g. boot-arg
#                 axon7bttest=SECS), whose path resets to recovery
#   TWRP (2)      pstore + the iOS log ring -> /cache, boot <- old image,
#                 misc <- old block, reboot
#   postmarketOS  the script fetches the logs into logs/NAME-*
#
# A test kernel that hangs without a panic leaves the phone in iOS: it needs
# a forced restart (Power + Volume Up) and TWRP then runs script 2 anyway.
#
# Usage: PMOS_HOST=user@phone [PMOS_SUDO_PASS=...] tools/axon7-remote-cycle.sh KERNEL NAME ["BOOT-ARGS"]
#   SSH authentication as usual (keys, agent or SSH_ASKPASS); sudo reads
#   PMOS_SUDO_PASS when set, PMOS_SSH_OPTS adds ssh options. TIMEOUT_SECS
#   (default 900) for the round trip.
set -euo pipefail
kernel=$(realpath "$1") name=$2
args=${3:-$(cat "$(dirname "$0")/axon7-bootargs.txt")}
host=${PMOS_HOST:?set PMOS_HOST=user@phone}
timeout_s=${TIMEOUT_SECS:-900}
cd "$(dirname "$0")/.."
out=research/axon7/$name
mkdir -p "$out" logs
# PMOS_SSH_OPTS: extra ssh options (e.g. "-o UserKnownHostsFile=/dev/null")
read -r -a extra <<< "${PMOS_SSH_OPTS:-}"
sshopt=(-o ConnectTimeout=10 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new "${extra[@]}")
on() { ssh "${sshopt[@]}" "$host" "$@" </dev/null; }
# sudo on the phone; the password (if any) goes through stdin, never the command line
root() { printf '%s\n' "${PMOS_SUDO_PASS:-}" | ssh "${sshopt[@]}" "$host" "sudo -S -p '' sh -c '$1'"; }
put() { scp -q "${sshopt[@]}" "$1" "$host:$2" </dev/null; }

on true || { echo "postmarketOS not reachable as $host" >&2; exit 1; }
echo "== saving the boot partition and the boot-menu block"
root 'dd if=/dev/disk/by-partlabel/boot bs=1M 2>/dev/null' > "$out/boot-before.img"
python3 -I tools/axon7-dualboot.py extract "$out/boot-before.img" -o "$out/pmos.bundle" >/dev/null ||
	{ echo "no postmarketOS bundle in the boot partition: refusing (the phone would not come back)" >&2; exit 1; }
misc_blocks=$(( $(root 'blockdev --getsize64 /dev/disk/by-partlabel/misc') / 4096 ))
data_blocks=$(( $(root 'blockdev --getsize64 /dev/disk/by-partlabel/userdata') / 4096 ))
root "dd if=/dev/disk/by-partlabel/misc bs=4096 skip=$((misc_blocks - 1)) count=1 2>/dev/null" > "$out/misc-before.bin"
[ "$(stat -c %s "$out/misc-before.bin")" = 4096 ] || { echo "could not read the misc block" >&2; exit 1; }
# the shim's boot setting (axon7.c boot_setting): "AX7BOOT1", entry 0 (iOS), 1 s, entry ^ 0xa5a5a5a5
python3 -I -c 'import struct,sys; sys.stdout.buffer.write((b"AX7BOOT1"+struct.pack("<III",0,1,0xa5a5a5a5)).ljust(4096,b"\0"))' > "$out/misc-ios.bin"

echo "== building the test image"
# no watchdog (XNU does not pet it, it would reset the test after <= 32 s):
# the test kernel itself resets into TWRP (e.g. axon7bttest)
WDT_SECS=${WDT_SECS:-0} BUILD_ONLY=1 PMOS_BUNDLE="$out/pmos.bundle" tools/axon7-cycle.sh "$kernel" "$name" "$args"
python3 -I tools/axon7-dualboot.py check "$out/boot.img" >/dev/null

B=/dev/block/bootdevice/by-name C=/cache/axon7-cycle
cat > "$out/ors1" <<EOF
cmd dd if=$C/boot-test.img of=$B/boot bs=1048576
cmd dd if=$C/misc-ios.bin of=$B/misc bs=4096 seek=$((misc_blocks - 1))
cmd cp $C/ors2 /cache/recovery/openrecoveryscript
cmd sync
reboot
EOF
cat > "$out/ors2" <<EOF
cmd mkdir -p $C/out
cmd mount -t pstore pstore /sys/fs/pstore 2>/dev/null; true
cmd cp /sys/fs/pstore/* $C/out/
cmd dd if=$B/userdata of=$C/out/ioslog.bin bs=4096 skip=$((data_blocks - 1025)) count=1025
cmd dd if=$C/boot-before.img of=$B/boot bs=1048576
cmd dd if=$C/misc-before.bin of=$B/misc bs=4096 seek=$((misc_blocks - 1))
cmd sync
reboot
EOF

if [ "${DRY_RUN:-0}" = 1 ]; then
	echo "dry run: test image and scripts in $out, nothing written to the phone"
	exit 0
fi
echo "== staging on /cache"
for f in boot.img boot-before.img misc-ios.bin misc-before.bin ors1 ors2; do put "$out/$f" "/tmp/axon7-cycle-$f"; done
root "set -e; mkdir -p /mnt/axon7-cache; mount /dev/disk/by-partlabel/cache /mnt/axon7-cache
	rm -rf /mnt/axon7-cache/axon7-cycle; mkdir /mnt/axon7-cache/axon7-cycle
	cd /tmp; mv axon7-cycle-boot.img /mnt/axon7-cache/axon7-cycle/boot-test.img
	for f in boot-before.img misc-ios.bin misc-before.bin ors2; do mv axon7-cycle-\$f /mnt/axon7-cache/axon7-cycle/\$f; done
	mv axon7-cycle-ors1 /mnt/axon7-cache/recovery/openrecoveryscript
	sync; umount /mnt/axon7-cache"
boot0=$(on 'cat /proc/sys/kernel/random/boot_id')
echo "== rebooting to TWRP ($(date +%T))"
root 'systemctl reboot --reboot-argument=recovery' || true

start=$(date +%s)
while :; do
	sleep 20
	b=$(on 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
	[ -n "$b" ] && [ "$b" != "$boot0" ] && break
	if [ $(( $(date +%s) - start )) -gt "$timeout_s" ]; then
		echo "postmarketOS not back after ${timeout_s}s: the phone may hang in iOS or sit in TWRP" >&2
		exit 3
	fi
done
echo "== postmarketOS is back after $(( $(date +%s) - start ))s"
sleep 5
root "mkdir -p /mnt/axon7-cache; mount -o ro /dev/disk/by-partlabel/cache /mnt/axon7-cache; tar -C /mnt/axon7-cache/axon7-cycle -cf - out 2>/dev/null; umount /mnt/axon7-cache" > "$out/logs.tar"
tar -C "$out" -xf "$out/logs.tar"
cmp -s <(root 'dd if=/dev/disk/by-partlabel/boot bs=1M 2>/dev/null') "$out/boot-before.img" &&
	echo "boot partition restored" || echo "WARNING: the boot partition differs from before the test" >&2
for f in "$out"/out/*; do
	case $f in
	*/ioslog.bin) python3 -I tools/sweet-log.py "$f" "logs/$name-ios.txt" ;;
	*) cp "$f" "logs/$name-$(basename "$f").txt" ;;
	esac
done
ls -la logs/"$name"-* 2>/dev/null
