#!/bin/bash
# Install (or update) the iOS kernel on the ZTE Axon 7, phone in TWRP:
# builds the boot image (loader shim with boot menu + this XNU kernel + the
# GPU/Wi-Fi firmware from research/firmware/, boot arguments from
# tools/axon7-bootargs.txt), keeps the postmarketOS bundle the boot
# partition already carries, writes and verifies it, and reboots.
#
# Usage: tools/axon7-flash-ios-kernel.sh KERNEL    (KERNEL: kernel.development.sweet from the xnu-kernel CI artifact)
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 KERNEL" >&2; exit 2; }
for f in research/firmware/gpu/a530_pm4.fw research/firmware/wlan/qwlan30.bin; do
	[ -f "$f" ] || { echo "missing $f: copy the firmware from your phone first (INSTALL.md, step 2)" >&2; exit 1; }
done
# no watchdog: XNU never pets the APSS watchdog, which would reset iOS after
# at most 32 s (it did after 24 s with the old default WDT_SECS=120)
WDT_SECS=0 exec tools/axon7-cycle.sh "$1" "install-$(date +%Y%m%d-%H%M%S)" "$(cat tools/axon7-bootargs.txt)" 0
