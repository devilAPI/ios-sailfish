#!/bin/bash
# los24-perfprobe.sh OUT: wait for LineageOS on adb (boot completed + 75 s),
# then measure the display pipeline while scrolling with injected swipes:
# CPU/GPU clocks, SurfaceFlinger timestats (summarise with
# tools/los24-timestats.py OUT), the backlight, and DRM vblank events plus GPU
# job events from ftrace if the kernel has them . Use as PROBE= for
# tools/los24-run.sh with LOS_HOLD=420 or more. Mainline names the trace
# systems drm_msm_gpu, drm_msm_atomic and dpu (not msm*), so events are
# matched in any directory. atrace gfx/view markers (HWUI dequeueBuffer,
# queueBuffer, DrawFrame; SF commit/composite) land in the same buffer;
# summarise with tools/los24-gputrace.py OUT.
O=$1
until [ "$(adb get-state 2>/dev/null)" = device ]; do sleep 3; done
until [ "$(timeout 10 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 5; done
sleep 75
timeout 400 adb shell LOUD=${LOUD:-0} '
input keyevent KEYCODE_WAKEUP; svc power stayon true; sleep 1
echo "== clocks"; for c in 0 2; do f=/sys/devices/system/cpu/cpu$c/cpufreq; echo "cpu$c $(cat $f/scaling_governor $f/scaling_cur_freq $f/scaling_max_freq | tr "\n" " ")"; done
for g in /sys/class/devfreq/*gpu*; do echo "gpu $(cat $g/governor $g/cur_freq $g/max_freq | tr "\n" " ")"; done
echo "== backlight"; ls -l /sys/class/backlight/*/brightness /sys/class/backlight/*/bl_power
settings put system screen_brightness_mode 0; settings put system screen_brightness 40; sleep 1; echo "setting 40: $(cat /sys/class/backlight/*/brightness)"
settings put system screen_brightness 160; sleep 1; echo "setting 160: $(cat /sys/class/backlight/*/brightness)"
for f in /sys/class/backlight/*/*; do [ -f $f ] && [ -r $f ] && case ${f##*/} in brightness|actual_brightness|max_brightness|scale|type|bl_power) echo "$f: $(cat $f)";; esac; done
cmd display set-brightness 0.1; sleep 1; echo "cmd display 0.1: $(cat /sys/class/backlight/*/brightness)"
cmd display set-brightness 0.9; sleep 1; echo "cmd display 0.9: $(cat /sys/class/backlight/*/brightness)"
cmd display reset-brightness-configuration >/dev/null 2>&1
dumpsys display | grep -iE "brightness|mBacklight|supportsBrightness" | head -20
logcat -d -b all | grep -iE "backlight|brightness|lights" | grep -viE "Settings|InputReader" | tail -20
echo "== composition"; dumpsys SurfaceFlinger | grep -iE "GLES:|HWC missed|Last HW vsync|activeMode="
am start -W -a android.settings.SETTINGS >/dev/null; sleep 3
T=/sys/kernel/tracing; [ -d $T/events ] || T=/sys/kernel/debug/tracing
echo "== trace events"; ls $T/events | grep -iE "msm|drm|gpu|dpu|fence" | tr "\n" " "; echo
AT=$(command -v atrace)
[ -n "$AT" ] && atrace --async_start -b 16384 gfx view >/dev/null 2>&1
echo 0 > $T/tracing_on; echo > $T/trace; [ -n "$AT" ] || echo 16384 > $T/buffer_size_kb
EV="drm/drm_vblank_event $(cd $T/events && ls -d */msm_gpu_submit_flush */msm_gpu_submit_retired */msm_atomic_commit_tail_start */msm_atomic_commit_tail_finish */msm_atomic_wait_flush_start */msm_atomic_wait_flush_finish */dpu_enc_trigger_flush */dpu_enc_phys_cmd_pp_tx_done */dpu_enc_phys_cmd_pdone_timeout */dpu_enc_wait_event_timeout 2>/dev/null | tr "\n" " ")"
echo "== enabled events: $EV"
for e in $EV; do echo 1 > $T/events/$e/enable; done
dumpsys SurfaceFlinger --timestats -clear -enable >/dev/null
echo 1 > $T/tracing_on
for i in 1 2 3 4 5; do input swipe 700 1800 700 600 400; input swipe 700 600 700 1800 400; done
echo 0 > $T/tracing_on
for e in $EV; do echo 0 > $T/events/$e/enable; done
echo "== timestats"; dumpsys SurfaceFlinger --timestats -dump -maxlayers 2; dumpsys SurfaceFlinger --timestats -disable >/dev/null
echo "== gfxinfo"; dumpsys gfxinfo com.android.settings | grep -E "Total frames|Janky|percentile|Slow|deadline" | head -16
echo "== ps"; ps -A -o PID,NAME | grep -E "surfaceflinger|settings|systemui|launcher|hwc"
echo "== trace"; grep -v "^#" $T/trace | grep -E "msm_|dpu_|drm_vblank|tracing_mark_write: [BE]" | head -40000
[ -n "$AT" ] && atrace --async_stop >/dev/null 2>&1
echo "== codecs"; logcat -d -b all | grep -iE "MediaCodecList|Codec2Client|CCodec|Codec2InfoBuilder|IComponentStore|swcodec|C2Store" | grep -v avc | head -40
if [ "${LOUD:-0}" = 1 ]; then
echo "== alarm (speaker -> mic)"; logcat -c
am start -a android.intent.action.SET_TIMER --ei android.intent.extra.alarm.LENGTH 1 --ez android.intent.extra.alarm.SKIP_UI true >/dev/null 2>&1
sleep 7; timeout 6 tinycap /data/local/tmp/alarm.wav -D 0 -d 0 -c 1 -r 48000 -b 16 >/dev/null 2>&1
dumpsys media.audio_flinger | grep -E "Standby:|Tracks" | head -6; am force-stop com.android.deskclock
logcat -d -b all | grep -iE "Klaxon|NuPlayer|MediaCodec|CCodec|Codec2|decoder|applyMixerRoute|tinyalsa|pcm_|AHAL|StreamOut" | grep -v avc | head -60
fi
svc power stayon false
' > "$O" 2>&1
echo "== done $(date +%T)" >> "$O"
