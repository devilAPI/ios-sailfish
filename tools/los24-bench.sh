#!/bin/bash
# los24-bench.sh [LABEL] [ROUNDS]: repeatable scroll benchmark for LineageOS 24
# on adb (phone awake, setup wizard done or not: Settings opens either way).
# Per round: Settings started fresh and settled, gfxinfo and SurfaceFlinger
# timestats reset, 8 fixed swipes (down/up, 300 ms each, 400 ms apart), then
#   app:  frames, janky %, 50/90/95/99th percentile frame time (gfxinfo)
#   sf:   present-to-present intervals at one vsync (16 ms) in %, and the mean
# The summary line is the median over the rounds. Compare runs with the same
# LABEL scheme, e.g. "gpu-ondemand" vs "gpu-perf".
L=${1:-bench} N=${2:-3}
P=com.android.settings
# test installs start in the setup wizard, which stays in front of Settings:
# mark the device provisioned and disable the wizard (fresh data every run)
adb shell 'input keyevent KEYCODE_WAKEUP; svc power stayon true; wm dismiss-keyguard
settings put global device_provisioned 1; settings put secure user_setup_complete 1
pm disable-user --user 0 org.lineageos.setupwizard >/dev/null 2>&1
am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; sleep 3' >/dev/null 2>&1
res=()
for r in $(seq 1 "$N"); do
	out=$(adb shell "
am force-stop $P; am start -W -a android.settings.SETTINGS >/dev/null; sleep 4
dumpsys gfxinfo $P reset >/dev/null
dumpsys SurfaceFlinger --timestats -clear -enable >/dev/null
for i in 1 2 3 4; do input swipe 700 1900 700 700 300; sleep 0.4; input swipe 700 700 700 1900 300; sleep 0.4; done
sleep 1
dumpsys SurfaceFlinger --timestats -dump -maxlayers 1 > /data/local/tmp/bench-ts.txt
dumpsys SurfaceFlinger --timestats -disable >/dev/null
dumpsys gfxinfo $P | grep -E 'Total frames rendered|Janky frames:|^50th|^90th|^95th|^99th' | head -6
grep -m1 -A1 'presentToPresent histogram' /data/local/tmp/bench-ts.txt | tail -1
" | tr -d '\r')
	line=$(python3 -I -c '
import re,sys
t=sys.stdin.read()
def g(p):
    m=re.search(p,t)
    return m.group(1) if m else "?"
h=dict((int(k),int(v)) for k,v in re.findall(r"(\d+)ms=(\d+)",t.strip().split("\n")[-1]))
n=sum(h.values()) or 1
one=sum(v for k,v in h.items() if k<=17)
mean=sum(k*v for k,v in h.items())/n
vals=dict(frames=g(r"Total frames rendered: (\d+)"), janky=g(r"Janky frames: \d+ \(([\d.]+)%\)"),
          p50=g(r"50th percentile: (\d+)ms"), p90=g(r"90th percentile: (\d+)ms"),
          p95=g(r"95th percentile: (\d+)ms"), p99=g(r"99th percentile: (\d+)ms"))
print("frames %(frames)s janky %(janky)s%% p50 %(p50)s p90 %(p90)s p95 %(p95)s p99 %(p99)s ms | " % vals
      + "sf 16ms %.0f%% mean %.1f ms" % (100*one/n, mean))' <<< "$out")
	echo "$L round $r: $line"
	res+=("$line")
done
printf '%s\n' "${res[@]}" | python3 -I -c '
import re,sys,statistics as st
rows=[l for l in sys.stdin.read().splitlines() if l]
def med(p):
    v=[float(m[1]) for l in rows if (m:=re.search(p,l)) and m[1]!="?"]
    return f"{st.median(v):g}" if v else "?"
print("'"$L"' median: janky "+med(r"janky ([\d.?]+)%")+"% p50 "+med(r"p50 (\S+)")+" p90 "+med(r"p90 (\S+)")+" p99 "+med(r"p99 (\S+)")+" ms | sf 16ms "+med(r"16ms (\d+)%")+"% mean "+med(r"mean ([\d.]+)")+" ms")'
