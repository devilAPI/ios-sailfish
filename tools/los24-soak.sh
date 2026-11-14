#!/bin/bash
# los24-soak.sh LABEL [MINUTES]: stability soak for LineageOS 24 on adb.
# Loops for MINUTES (default 30): start stock apps, scroll, rotate, screen
# off/on, a short monkey burst (system apps only, no settings changes that
# matter: monkey runs with --pct-syskeys 0 and without trackball/nav keys).
# Then reports, against the state at the start:
#   reboot (boot id changed), kernel WARN/BUG/Oops lines, tombstones, ANRs,
#   app crashes (logcat crash buffer), system_server restarts, lowmem kills,
#   memory (MemAvailable start/end), thermal max, battery.
# Output in logs/los24-soak-LABEL.txt; the summary line on stdout.
set -uo pipefail
L=${1:?label}; MIN=${2:-30}
cd "$(dirname "$0")/.."
out=logs/los24-soak-$L.txt
a() { timeout 120 adb shell "$@" 2>/dev/null | tr -d '\r'; }
a 'input keyevent KEYCODE_WAKEUP; svc power stayon true; wm dismiss-keyguard; logcat -c -b all' >/dev/null
boot0=$(a cat /proc/sys/kernel/random/boot_id)
ss0=$(a pidof system_server)
tomb0=$(a 'ls /data/tombstones 2>/dev/null | wc -l')
anr0=$(a 'ls /data/anr 2>/dev/null | wc -l')
mem0=$(a "awk '/MemAvailable/{print \$2}' /proc/meminfo")
kw0=$(a 'dmesg | grep -c -E "WARNING:|BUG:|Oops|Unable to handle|rcu_sched|hung_task"')
{
echo "== soak $L, $MIN min, start $(date -u +%FT%TZ)"
echo "boot_id $boot0 system_server $ss0 tombstones $tomb0 anr $anr0 MemAvailable ${mem0} kB kernel-warn $kw0"
} > "$out"
apps="com.android.settings/.Settings org.lineageos.jelly/.MainActivity com.android.contacts/.activities.PeopleActivity com.android.deskclock/.DeskClock com.android.messaging/.ui.conversationlist.ConversationListActivity com.android.documentsui/.LauncherActivity com.android.calculator2/.Calculator org.lineageos.glimpse/.MainActivity com.android.dialer/.main.impl.MainActivity"
end=$(( $(date +%s) + MIN * 60 )); it=0; tmax=0
while [ "$(date +%s)" -lt "$end" ]; do
	it=$((it + 1))
	if [ "$(timeout 10 adb get-state 2>/dev/null)" != device ]; then
		echo "iteration $it: adb gone at $(date +%T)" >> "$out"
		timeout 600 adb wait-for-device || break
	fi
	for c in $apps; do
		a "am start -W -n $c >/dev/null 2>&1; sleep 1.5; input swipe 700 1900 700 700 250; sleep 0.4; input swipe 700 700 700 1900 250; sleep 0.5"
	done
	a 'settings put system accelerometer_rotation 0; settings put system user_rotation 1; sleep 2; settings put system user_rotation 0; sleep 1
input keyevent KEYCODE_HOME; sleep 1; input keyevent KEYCODE_APP_SWITCH; sleep 1; input keyevent KEYCODE_HOME
input keyevent KEYCODE_SLEEP; sleep 3; input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard'
	a 'monkey -p com.android.settings -p com.android.calculator2 -p com.android.deskclock --pct-syskeys 0 --pct-nav 0 --pct-majornav 0 --pct-trackball 0 --throttle 100 -s '$it' 300 >/dev/null 2>&1; input keyevent KEYCODE_HOME'
	t=$(a 'for z in /sys/class/thermal/thermal_zone*/temp; do cat $z; done | sort -n | tail -1')
	[ -n "$t" ] && [ "$t" -gt "$tmax" ] 2>/dev/null && tmax=$t
done
boot1=$(a cat /proc/sys/kernel/random/boot_id)
ss1=$(a pidof system_server)
tomb1=$(a 'ls /data/tombstones 2>/dev/null | wc -l')
anr1=$(a 'ls /data/anr 2>/dev/null | wc -l')
mem1=$(a "awk '/MemAvailable/{print \$2}' /proc/meminfo")
kw1=$(a 'dmesg | grep -c -E "WARNING:|BUG:|Oops|Unable to handle|rcu_sched|hung_task"')
crashes=$(a 'logcat -d -b crash' | grep -c -E '^.*FATAL EXCEPTION|Fatal signal|>>> .* <<<')
lmk=$(a 'logcat -d -b events' | grep -c 'killinfo')
{
echo "== end $(date -u +%FT%TZ), $it iterations"
echo "boot_id $boot1 system_server $ss1 tombstones $tomb1 anr $anr1 MemAvailable ${mem1} kB kernel-warn $kw1"
echo "--- crash buffer"; a 'logcat -d -b crash' | grep -E 'FATAL EXCEPTION|Process:|Fatal signal|>>> .* <<<|Abort message' | head -40
echo "--- new kernel warnings"; a 'dmesg' | grep -E -A3 'WARNING:|BUG:|Oops|Unable to handle|rcu_sched|hung_task' | tail -40
echo "--- ANR files"; a 'ls -l /data/anr' | tail -5
echo "--- tombstones"; a 'ls -l /data/tombstones' | tail -5
echo "--- thermal max ${tmax}"; a 'dumpsys battery' | grep -E 'level|temperature'
} >> "$out"
rb=no; [ "$boot0" != "$boot1" ] && rb=YES
ssr=no; [ "$ss0" != "$ss1" ] && ssr=YES
echo "soak $L: ${it} iterations, reboot $rb, system_server restart $ssr, tombstones +$((tomb1 - tomb0)), anr +$((anr1 - anr0)), crashes $crashes, kernel warn +$((kw1 - kw0)), lmk $lmk, MemAvailable ${mem0}->${mem1} kB, thermal max ${tmax} | $out"
