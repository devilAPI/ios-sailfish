#!/bin/bash
# Build the ZTE Axon 7 (ailsa_ii) shim with clang/lld (no cross gcc needed),
# wrapped in the stock-style v0 boot.img by tools/mkboot-v0.sh.
# Usage: shim/build-axon7.sh STOCK_BOOT.img [probe|loader] [PAYLOAD]  -> shim/out/axon7-<kind>.img
set -euo pipefail
stock=$(realpath "$1") kind=${2:-probe}
payload=${3:+$(realpath "$3")}
cd "$(dirname "$0")"
CC="clang --target=aarch64-none-elf"
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra -DAXON7 -DWDT_SECS=${WDT_SECS:-120} -DLOS_TEST=${LOS_TEST:-0}"
O=out/axon7-$kind
mkdir -p $O
case $kind in
probe)  srcs="start.S axon7-probe.c" ;;
loader) srcs="start.S axon7.c pstore.c console.c fdt.c loader.c pmic.c pmos.c fdtw.c ufsr.c android.c" ;;
*) echo "unknown kind $kind" >&2; exit 2 ;;
esac
objs=
for f in $srcs; do
	$CC $CFLAGS -c $f -o $O/${f%.*}.o
	objs="$objs $O/${f%.*}.o"
done
abs=$(llvm-readelf -r $(echo $objs | tr ' ' '\n' | grep -v start.o) | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
ld.lld -static -T shim.ld --build-id=none -N $objs -o $O/shim.elf
llvm-objcopy -O binary $O/shim.elf $O/Image
size=$(llvm-nm $O/shim.elf | awk '$3=="_end"{print $1}')
truncate -s $((16#$size)) $O/Image
[ -z "$payload" ] || cat "$payload" >> $O/Image
CLEAR_CMDLINE=1 ../tools/mkboot-v0.sh "$stock" $O/Image out/axon7-$kind.img
