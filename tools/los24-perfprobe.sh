#!/bin/bash
# los24-perfprobe.sh OUT: wait for LineageOS on adb (boot completed + 75 s),
# then measure the display pipeline while scrolling with injected swipes:
# CPU/GPU clocks, SurfaceFlinger timestats (summarise with
# tools/los24-timestats.py OUT), the backlight, and DRM vblank events plus GPU
# job events from ftrace if the kernel has them (on the build-28 kernel the
# msm tracepoints were missing under events/msm). Use as PROBE= for
# tools/los24-run.sh with LOS_HOLD=420 or more.
O=$1
until [ "$(adb get-state 2>/dev/null)" = device ]; do sleep 3; done
until [ "$(timeout 10 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 5; done
sleep 75
timeout 300 adb shell '
input keyevent KEYCODE_WAKEUP; svc power stayon true; sleep 1
echo "== clocks"; for c in 0 2; do f=/sys/devices/system/cpu/cpu$c/cpufreq; echo "cpu$c $(cat $f/scaling_governor $f/scaling_cur_freq $f/scaling_max_freq | tr "\n" " ")"; done
for g in /sys/class/devfreq/*gpu*; do echo "gpu $(cat $g/governor $g/cur_freq $g/max_freq | tr "\n" " ")"; done
echo "== backlight"; ls -l /sys/class/backlight/*/brightness /sys/class/backlight/*/bl_power
settings put system screen_brightness_mode 0; settings put system screen_brightness 40; sleep 1; echo "setting 40: $(cat /sys/class/backlight/*/brightness)"
settings put system screen_brightness 160; sleep 1; echo "setting 160: $(cat /sys/class/backlight/*/brightness)"
echo "== composition"; dumpsys SurfaceFlinger | grep -iE "GLES:|HWC missed|Last HW vsync|activeMode="
am start -W -a android.settings.SETTINGS >/dev/null; sleep 3
T=/sys/kernel/tracing; [ -d $T/events ] || T=/sys/kernel/debug/tracing
echo "== trace events"; ls $T/events | grep -iE "msm|drm|gpu|dpu|fence" | tr "\n" " "; echo
echo 0 > $T/tracing_on; echo > $T/trace; echo 8192 > $T/buffer_size_kb
EV="drm/drm_vblank_event $(cd $T/events && ls -d msm*/msm_gpu_submit_flush msm*/msm_gpu_submit_retired 2>/dev/null | tr "\n" " ")"
for e in $EV; do echo 1 > $T/events/$e/enable; done
dumpsys SurfaceFlinger --timestats -clear -enable >/dev/null
echo 1 > $T/tracing_on
for i in 1 2 3 4 5; do input swipe 700 1800 700 600 400; input swipe 700 600 700 1800 400; done
echo 0 > $T/tracing_on
for e in $EV; do echo 0 > $T/events/$e/enable; done
echo "== timestats"; dumpsys SurfaceFlinger --timestats -dump -maxlayers 2; dumpsys SurfaceFlinger --timestats -disable >/dev/null
echo "== gfxinfo"; dumpsys gfxinfo com.android.settings | grep -E "Total frames|Janky|percentile|Slow|deadline" | head -16
echo "== ps"; ps -A -o PID,NAME | grep -E "surfaceflinger|settings|systemui|launcher|hwc"
echo "== trace"; grep -v "^#" $T/trace | grep -E "msm_gpu|drm_vblank" | head -6000
svc power stayon false
' > "$O" 2>&1
echo "== done $(date +%T)" >> "$O"
