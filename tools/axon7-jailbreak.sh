#!/bin/bash
# Make the local iOS root image "pre-jailbroken" (rootless, like Dopamine /
# palera1n on iOS 15-16): the Procursus bootstrap for iOS 16 (CF 1900) in
# /var/jb, Sileo's package next to it, and a launchd job that finishes the
# setup on the phone's next boot (tools/axon7-jbinit.sh: prep_bootstrap,
# dpkg -i Sileo, uicache). Uses sudo for the loop mount.
#
# Code signing is permissive on this port (cs_enforcement_disable, built-in
# AMFI policy) and the root is writable, so nothing else is needed.
#
# Then write the image back with tools/axon7-flashroot.sh (delta).
#
# Usage: tools/axon7-jailbreak.sh [IMG]   (default research/axon7/ios16-root.img)
set -euo pipefail
cd "$(dirname "$0")/.."
img=${1:-research/axon7/ios16-root.img}
jb=research/jailbreak
boot=$jb/bootstrap-1900.tar.zst
deb=$jb/sileo-arm64.deb
for f in "$img" "$boot" "$deb" tools/axon7-jbinit.sh; do
	[[ -f $f ]] || { echo "missing $f" >&2; exit 1; }
done
sudo -v
mnt=$(mktemp -d)
cleanup() { mountpoint -q "$mnt" && sudo umount "$mnt"; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount -t hfsplus -o loop,force "$img" "$mnt"
if sudo test -e "$mnt/private/var/jb"; then
	echo "/var/jb already exists in the image: not extracting the bootstrap again" >&2
else
	# tar paths are ./var/jb/...; /var is a symlink to private/var on iOS
	zstd -dc "$boot" | sudo tar --numeric-owner --no-overwrite-dir -xpf - -C "$mnt/private"
	echo "bootstrap extracted to /private/var/jb"
fi
sudo install -d -o 0 -g 0 -m 755 "$mnt/private/var/jb/var/axon7"
sudo install -o 0 -g 0 -m 644 "$deb" "$mnt/private/var/jb/var/axon7/sileo.deb"
sudo install -o 0 -g 0 -m 755 tools/axon7-jbinit.sh "$mnt/private/var/jb/usr/libexec/axon7-jbinit.sh"

# launchd job (launchd_unsecure_cache=1 reads /System/Library/xpc/launchd.plist)
sudo python3 -I - "$mnt/System/Library/xpc/launchd.plist" <<'EOF'
import os, plistlib, sys
path = sys.argv[1]
st = os.stat(path)
with open(path, 'rb') as f:
    plist = plistlib.load(f)
plist['LaunchDaemons']['/System/Library/LaunchDaemons/com.axon7.jbinit.plist'] = {
    'Label': 'com.axon7.jbinit',
    'ProgramArguments': ['/var/jb/bin/sh', '/var/jb/usr/libexec/axon7-jbinit.sh'],
    'RunAtLoad': True,
    'KeepAlive': False,
    'UserName': 'root',
    'POSIXSpawnType': 'Interactive',
    'EnablePressuredExit': False,
}
with open(path, 'wb') as f:
    plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
os.chown(path, st.st_uid, st.st_gid)
os.chmod(path, st.st_mode & 0o7777)
print('launchd.plist: job com.axon7.jbinit added')
EOF

sudo du -sh "$mnt/private/var/jb"
sudo umount "$mnt"
fsck.hfsplus -f -y "$img" | grep -E 'appears to be OK|repaired|corrupt' || true
fsck.hfsplus -f -y "$img" >/dev/null || true
echo "done: $img (jailbreak finishes on the next boot; see /var/jb/var/log/axon7-jbinit.log)"
