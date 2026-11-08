#!/system/bin/sh
# Display register snapshot for the half-screen colour bug (both kernels:
# LineageOS 4.4 and TWRP's ZTE 3.18). Usage: sh regs.sh <mdss debugfs dir>
# Prints only non-zero lines. DSPP +0x1800..0x1fff is not read: reading
# DSPP0 0x56800 took the 4.4 kernel down (synchronous abort, los27). DSPP0 = left half, DSPP1 = right half;
# dsi0 = left, dsi1 = right.
d=${1:-/sys/kernel/debug/mdp}
f=mdp_; [ -e $d/mdp_off ] || f=
dump() { # file-prefix offset count(hex) label
	echo "$2 $3" > $d/${1}off 2>/dev/null || { echo "-- $4: refused"; return; }
	echo "-- $4"
	cat $d/${1}reg 2>&1 | grep -v ': 00000000 00000000 00000000 00000000$'
}
for b in 55000 57000; do
	o=$b
	while [ $((0x$o)) -lt $((0x$b + 0x1800)) ]; do
		dump "$f" $o 400 "dspp 0x$o"
		o=$(printf %x $((0x$o + 0x400)))
	done
done
for c in dsi0_ctrl dsi1_ctrl dsi0_phy dsi1_phy; do
	[ -e $d/${c}_off ] && dump ${c}_ 0 400 $c
done
# panel (over DSI0): power mode, MADCTL, pixel format, image mode, signal mode, self-diagnostic
if [ -e $d/panel_off ]; then
	for r in 0a 0b 0c 0d 0e 0f; do
		echo "$r 1" > $d/panel_off 2>/dev/null && echo "panel $r: $(cat $d/panel_reg 2>&1)"
	done
fi
