#!/usr/bin/env bash
# Runs the Sakura Rally APK in the Android emulator the way a player would: launch it, tap the title
# hub (Time Attack, then Back, then New journey) with real `adb input tap` touches, and record
# screenshots, the Godot/Android log and whether the app is still alive at each step.
#   emulator_test.sh <apk> <out-dir>
set -u
APK="$1"
OUT="$2"
PKG=com.rishidev.sakurarally
mkdir -p "$OUT"
LOG="$OUT/steps.txt"
: > "$LOG"
step() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
shot() { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; step "shot $1 ($(stat -c %s "$OUT/$1.png" 2>/dev/null || echo 0) bytes)"; }
alive() { local p; p=$(adb shell pidof "$PKG" | tr -d '\r'); step "alive: ${p:-NO (process gone)}"; }

adb wait-for-device
step "device: $(adb shell getprop ro.product.model | tr -d '\r') API $(adb shell getprop ro.build.version.sdk | tr -d '\r') abi $(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
step "gpu: $(adb shell dumpsys SurfaceFlinger 2>/dev/null | grep -m1 -i 'GLES' | tr -d '\r')"
step "vulkan: $(adb shell cmd gpu vkjson 2>/dev/null | grep -m1 -o '"deviceName": *"[^"]*"' || echo n/a)"
step "install: $(adb install -r -g "$APK" 2>&1 | tail -1)"
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
step "launched"

# landscape screen size
read -r PW PH < <(adb shell wm size | tr -d '\r' | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)
W=$(( PW > PH ? PW : PH )); H=$(( PW > PH ? PH : PW ))
step "screen ${W}x${H} (landscape)"
tap() { local x=$(( W * $1 / 1000 )) y=$(( H * $2 / 1000 )); step "tap $3 at ${x},${y}"; adb shell input tap "$x" "$y"; }

for t in 30 60 90; do
  sleep 30
  shot "e1_title_${t}s"
  alive
done
adb logcat -d > "$OUT/logcat_boot.txt" 2>&1

# Title hub positions at 20:9 (from the CI render of the same layout): Time Attack, New journey.
tap 144 743 "Time Attack"
sleep 10
shot e2_after_time_attack_tap
alive
step "back key"
adb shell input keyevent 4
sleep 8
shot e3_after_back
alive
tap 156 627 "New journey"
sleep 30
shot e4_after_new_journey_30s
alive
sleep 45
shot e5_after_new_journey_75s
alive
step "gas (hold 3 s) at the GAS button"
adb shell input swipe $(( W - W * 195 / 2400 )) $(( H - H * 215 / 1080 )) $(( W - W * 195 / 2400 )) $(( H - H * 215 / 1080 )) 3000
shot e6_after_gas
alive

adb logcat -d > "$OUT/logcat_full.txt" 2>&1
grep -iE "godot|vulkan|opengl|shader|SCRIPT ERROR|ERROR:|USER ERROR|FATAL|AndroidRuntime|ANR|crash|lowmemory|killing" "$OUT/logcat_full.txt" \
  | grep -vE "chatty|ActivityManager: (Start|Displayed)" | head -n 400 > "$OUT/logcat_filtered.txt"
step "logcat: $(wc -l < "$OUT/logcat_full.txt") lines, filtered $(wc -l < "$OUT/logcat_filtered.txt")"
exit 0
