#!/bin/bash
# Build the iOS 16.7.16 (iPhone 8, 20H392) root image for the ZTE Axon 7 on
# Linux, in one go (uses sudo; needs apfs-fuse, hfsprogs, rsync, lzfse):
#   1. tools/mkiosroot.sh: HFS+ image with the OS root and both cryptexes
#   2. tools/sweet-root-tweaks.py: the userland changes the port needs
#   3. stock apps from /private/var/staged_system_apps into /Applications
#      (iOS's own first-boot install of them fails on code signing here)
# The wallpaper HEIC -> PNG step (tools/wallpaper-heic2png.sh) needs macOS
# `sips` and is skipped: the stock wallpapers then show only their gradient.
#
# Usage: tools/axon7-mkroot.sh [OUT.img] [SIZE]   (default research/axon7/ios16-root.img, 16G)
set -euo pipefail
cd "$(dirname "$0")/.."
ipsw=research/ipsw-8
out=${1:-research/axon7/ios16-root.img}
size=${2:-16G}
os=$ipsw/087-86684-044.dmg      # OS
sysos=$ipsw/087-86580-047.dmg   # Cryptex1,SystemOS
appos=$ipsw/087-86715-047.dmg   # Cryptex1,AppOS
for f in "$os" "$sysos" "$appos"; do
	[[ -f $f ]] || { echo "missing $f (BuildManifest roles: OS, Cryptex1,SystemOS, Cryptex1,AppOS)" >&2; exit 1; }
done
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
sudo -v

tools/mkiosroot.sh "$os" "$sysos" "$appos" "$out" "$size"

mnt=$(mktemp -d)
cleanup() { mountpoint -q "$mnt" && sudo umount "$mnt"; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount -t hfsplus -o loop,force "$out" "$mnt"

sudo python3 -I tools/sweet-root-tweaks.py "$mnt"

staged="$mnt/private/var/staged_system_apps"
if sudo test -d "$staged"; then
	n=0
	while IFS= read -r -d '' app; do
		name=${app##*/}
		if sudo test -e "$mnt/Applications/$name"; then
			echo "kept existing /Applications/$name"
		else
			sudo mv "$app" "$mnt/Applications/$name"
			n=$((n + 1))
		fi
	done < <(sudo find "$staged" -mindepth 1 -maxdepth 1 -name '*.app' -print0)
	echo "moved $n staged system apps into /Applications"
fi

df -h "$mnt"
sudo umount "$mnt"
fsck.hfsplus -f -y "$out" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$out"
echo "done: $out"
