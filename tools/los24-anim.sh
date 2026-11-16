#!/bin/bash
# los24-anim.sh: gfxinfo frame stats for animations on LineageOS 24 (ripple press, ripple + open/back in Settings, notification shade, launcher app drawer, app open/close to home). Needs ANDROID_SERIAL; setup wizard done.
export ANDROID_SERIAL=7e15695a
st() { # pkg label
 adb shell "dumpsys gfxinfo $1 | grep -E 'Total frames rendered|Janky frames:|^50th|^90th|^99th|Number Slow UI|Number Slow bitmap|Number Slow issue|Number Frame deadline missed|Number Missed Vsync|Number High input'" | tr -d '\r' | tr '\n' ' ' | sed "s/^/$2: /"; echo
}
adb shell 'input keyevent KEYCODE_WAKEUP; svc power stayon true; wm dismiss-keyguard; settings put global animator_duration_scale 1; settings put global transition_animation_scale 1; settings put global window_animation_scale 1' 
P=com.android.settings
# 1 ripple: long press-like taps on list items without opening (tap then back)
adb shell "am force-stop $P; am start -W -a android.settings.SETTINGS >/dev/null; sleep 4; dumpsys gfxinfo $P reset >/dev/null"
adb shell 'for i in 1 2 3 4 5 6; do input swipe 700 900 700 900 600; sleep 0.8; done'
st $P ripple-press
# 2 ripple + open subpage + back
adb shell "dumpsys gfxinfo $P reset >/dev/null; for i in 1 2 3 4; do input tap 700 900; sleep 1.2; input keyevent BACK; sleep 1.2; done"
st $P ripple-open-back
# 3 notification shade
L=com.android.systemui
adb shell "input keyevent HOME; sleep 2; dumpsys gfxinfo $L reset >/dev/null; for i in 1 2 3 4; do cmd statusbar expand-notifications; sleep 1; cmd statusbar collapse; sleep 1; cmd statusbar expand-settings; sleep 1; cmd statusbar collapse; sleep 1; done"
st $L shade
# 4 launcher: app drawer swipe + home
H=$(adb shell cmd package resolve-activity --brief -c android.intent.category.HOME -a android.intent.action.MAIN | tail -1 | cut -d/ -f1 | tr -d '\r')
adb shell "input keyevent HOME; sleep 2; dumpsys gfxinfo $H reset >/dev/null; for i in 1 2 3 4; do input swipe 700 2200 700 600 250; sleep 1.2; input keyevent HOME; sleep 1.2; done"
st $H launcher-drawer
# 5 app open/close transition (launcher + recents)
adb shell "dumpsys gfxinfo $H reset >/dev/null; for i in 1 2 3; do am start -a android.settings.SETTINGS >/dev/null; sleep 1.5; input keyevent HOME; sleep 1.5; done; input keyevent APP_SWITCH; sleep 1.5; input keyevent HOME; sleep 1"
st $H app-open-home
