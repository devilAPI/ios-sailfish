#!/bin/bash
# Build axon7-libkrw0-plugin-stub: an empty package that Provides
# libkrw0-plugin. The Procursus bootstrap installs libkrw0, which depends on
# a plugin that an exploit-based jailbreak supplies (libkrw0-tfp0,
# libkrw0-dopamine). This port boots its own XNU, so there is none; with
# libkrw0's dependency unmet apt refuses every install ("unmet
# dependencies"), which Sileo shows as nearly everything needing libkrw.
# Tools that really use kernel read/write (golb, dimentio) still won't work.
# No dpkg-deb needed: debian-binary, control.tar.gz, data.tar.gz in an ar.
#
# Usage: tools/axon7-krw-stub.sh [OUT.deb]   (default research/jailbreak/axon7-libkrw0-plugin-stub.deb)
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(realpath -m "${1:-research/jailbreak/axon7-libkrw0-plugin-stub.deb}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/control" "$work/data" "$(dirname "$out")"
cat > "$work/control/control" <<'EOF'
Package: axon7-libkrw0-plugin-stub
Version: 1.0
Architecture: iphoneos-arm64
Maintainer: Axon 7 iOS port
Provides: libkrw0-plugin
Section: System
Priority: optional
Description: libkrw0-plugin placeholder for the Axon 7 iOS port
 The port boots its own XNU build, so there is no exploit-based kernel
 read/write for libkrw to use. This empty package satisfies libkrw0's
 dependency so that apt and Sileo can install packages again. Tools that
 really need kernel read/write (golb, dimentio) will not work.
EOF
printf '2.0\n' > "$work/debian-binary"
tar --owner=0 --group=0 --numeric-owner -C "$work/control" -czf "$work/control.tar.gz" ./control
tar --owner=0 --group=0 --numeric-owner -C "$work/data" -czf "$work/data.tar.gz" .
rm -f "$out"
(cd "$work" && ar rcD "$out" debian-binary control.tar.gz data.tar.gz)
echo "$out ($(stat -c %s "$out") bytes)"
