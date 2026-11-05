#!/bin/bash
# Copy files into the local iOS root image (uses sudo for the loop mount),
# then check the volume. Write the result to the phone with
# tools/axon7-flashroot.sh (delta: only the changed chunks). Run
# tools/axon7-pullroot.sh first if iOS has run since the last flash.
#
# Usage: tools/axon7-root-add.sh [-i IMG] SRC:/ios/path[:MODE] ...
#   e.g. tools/axon7-root-add.sh research/axon7/sweetgl.dylib:/usr/lib/sweetgl.dylib:755
# Files are owned by root:wheel (0:0); MODE defaults to 644.
set -euo pipefail
cd "$(dirname "$0")/.."
img=research/axon7/ios16-root.img
[[ ${1:-} == -i ]] && { img=$2; shift 2; }
(( $# )) || { sed -n '2,10p' "$0"; exit 2; }
for spec in "$@"; do
	src=${spec%%:*}
	[[ -f $src ]] || { echo "no file $src" >&2; exit 1; }
done
sudo -v
mnt=$(mktemp -d)
cleanup() { mountpoint -q "$mnt" && sudo umount "$mnt"; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount -t hfsplus -o loop,force "$img" "$mnt"
for spec in "$@"; do
	IFS=: read -r src dst mode <<< "$spec"
	mode=${mode:-644}
	sudo install -D -o 0 -g 0 -m "$mode" "$src" "$mnt$dst"
	echo "installed $dst ($mode, $(stat -c %s "$src") bytes)"
done
sudo umount "$mnt"
fsck.hfsplus -f -y "$img" | grep -E 'appears to be OK|repaired|corrupt' || true
fsck.hfsplus -f -y "$img" >/dev/null || true
echo "done: $img"
