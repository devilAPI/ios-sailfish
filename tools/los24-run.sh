#!/bin/bash
# los24-run.sh N PREV: wait for the LineageOS 24 build on the build server
# (tmux session los24build), check that it succeeded and is new (super.img
# differs from build PREV), fetch boot.img + super.img as a delta of build
# PREV, then run axon7-los-test.sh on the phone (unattended, Nura -> TWRP ->
# LineageOS -> Nura).
#
# Needs: ssh root@compiler (home network or VPN), the phone in Nura on USB,
# PMOS_SUDO_PASS in the environment (Nura's sudo password; never in a file in
# the repo). Optional: SSH_ASKPASS for the Nura SSH password, LOS_HOLD,
# LOS_SKIP_IMAGES etc. pass through to axon7-los-test.sh, PROBE=script is
# started next to the test with logs/los24-m1a-N-perf.txt as argument (it
# waits for LineageOS itself, e.g. tools/los24-perfprobe.sh).
# Run from the ios checkout: tools/los24-run.sh 29 28
set -u
N=$1 P=$2
: "${PMOS_SUDO_PASS:=}"; [ -n "$PMOS_SUDO_PASS" ] || [ "${LOS_SHIM:-}" = keep ] ||
	{ echo "set PMOS_SUDO_PASS (Nura sudo password), or LOS_SHIM=keep with the phone in TWRP" >&2; exit 1; }
cd "$(dirname "$0")/.."
O=(-o ServerAliveInterval=30 -o ServerAliveCountMax=40 -o ConnectTimeout=30)
while :; do timeout 90 ssh "${O[@]}" root@compiler 'su - build -c "tmux has-session -t los24build" 2>/dev/null'; r=$?; [ $r = 1 ] && break; sleep 30; done
S=/srv/los24/lineage-24.0/out/target/product/axon7m
for i in 1 2 3 4 5; do
	timeout 120 ssh "${O[@]}" root@compiler "tr '\r' '\n' < /srv/los24/logs/build-latest.log | grep -E '^FAILED|#### ' | head -4 | cut -c1-300; cd $S && sha256sum boot.img super.img" > logs/los24-build$N-check.txt 2>&1 && break
	sleep 20
done
cat logs/los24-build$N-check.txt
grep -q "completed successfully" logs/los24-build$N-check.txt || { echo BUILD NOT OK; exit 2; }
# a failed chain leaves the previous build's log and images: refuse a rerun of PREV
new_super=$(grep -E ' super.img$' logs/los24-build$N-check.txt | cut -d' ' -f1)
old_super=$(grep -E ' super.img$' logs/los24-build$P-check.txt 2>/dev/null | cut -d' ' -f1)
[ -n "$new_super" ] && [ "$new_super" != "$old_super" ] || { echo "BUILD NOT NEW (super.img same as build $P)"; exit 4; }
R=research/los24-build-$N
mkdir -p $R
[ -f research/los24-build-$P/super.img ] && cp research/los24-build-$P/{boot,super}.img $R/
for i in 1 2 3; do
	rsync -e "ssh ${O[*]}" --inplace --no-whole-file root@compiler:$S/boot.img root@compiler:$S/super.img $R/ && break
	sleep 20
done
grep -E '^[0-9a-f]{64}  ' logs/los24-build$N-check.txt | (cd $R && sha256sum -c) || { echo CHECKSUM MISMATCH; exit 3; }
[ -n "${PROBE:-}" ] && { "$PROBE" logs/los24-m1a-$N-perf.txt & }
SSH_ASKPASS_REQUIRE=${SSH_ASKPASS:+force} PMOS_HOST=${PMOS_HOST:-user@172.16.42.1} \
	PMOS_SSH_OPTS="${PMOS_SSH_OPTS:--o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o LogLevel=ERROR}" \
	LOS_WAIT=${LOS_WAIT:-900} tools/axon7-los-test.sh $R los24-m1a-$N > logs/los24-m1a-$N-run.txt 2>&1
echo "exit $?" >> logs/los24-m1a-$N-run.txt
tr '\r' '\n' < logs/los24-m1a-$N-run.txt | grep -vE "^ *[0-9]+/[0-9]+ MiB$" | tail -20
