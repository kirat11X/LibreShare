#!/usr/bin/env bash
# LibreShare Android emulator smoke test: drives the REAL prototype APK on an emulator, in both
# directions, against the host CLI. Prints PASS/FAIL per check; exit 0 only if every check passes.
#
#   tools/android_emulator_smoke.sh [path/to/libreshare-*-android-x86_64.apk]
#
# Scenarios
#   A  Android -> Linux : Add device by IP 10.0.2.2:PORT, pick 2 files (1 KiB + N MiB) with the
#                         system picker, send; host `ls receive --auto-accept` gets them byte-identical.
#   B  Linux -> Android : Receive on, `adb forward`, host `ls send`, tap Accept in the Incoming dialog,
#                         `adb pull` the files and compare checksums.
#
# Needs (all project-local, no sudo; see docs/dev/android-toolchain.md and docs/test-reports/android-emulator.md):
#   - .toolchain/android-sdk with `emulator` and `system-images;android-35;google_apis;x86_64`
#     sdkmanager "emulator" "system-images;android-35;google_apis;x86_64"
#   - /dev/kvm accessible; python3; the x86_64 APK from tools/package_prototype.sh android
# Env knobs: LS_SMOKE_KEEP_WORK=1 (keep logs/test files), LS_SMOKE_SHOTS=dir (save screenshots), LS_EMU_GPU="host swangle_indirect"  (modes tried in order; `host` needs a working host GL/Vulkan,
#            swiftshader_indirect/swangle crashed on the dev box), LS_SMOKE_BIG_MB=20, LS_SMOKE_PORT=53318,
#            LS_SMOKE_SERIAL=emulator-5554, LS_SMOKE_KEEP_EMULATOR=1 (leave it running), LS_SMOKE_BOOT_TIMEOUT=300.
# The emulator's AVD (ls_test) lives in .toolchain/avd. If an emulator is already running it is reused and left running.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
# shellcheck source=env.sh
source tools/env.sh >/dev/null 2>&1

APK="${1:-$(ls "$ROOT"/dist/prototype/libreshare-*-android-x86_64.apk 2>/dev/null | head -1)}"
PORT="${LS_SMOKE_PORT:-53318}"
FWD_PORT=$((PORT + 100))
BIG_MB="${LS_SMOKE_BIG_MB:-20}"
SERIAL="${LS_SMOKE_SERIAL:-emulator-5554}"
GPU_MODES="${LS_EMU_GPU:-host swangle_indirect}"
BOOT_TIMEOUT="${LS_SMOKE_BOOT_TIMEOUT:-300}"
PKG=dev.libreshare.libreshare_app
AVD=ls_test
APP_DL=/storage/emulated/0/Android/data/$PKG/files/Download/LibreShare

# The emulator and avdmanager misbehave when the SDK path contains spaces (this repo's does).
# A symlink is not enough for the emulator (it resolves its own path), but the SDK-root variable is.
SDK_REAL="$(readlink -f "$ROOT/.toolchain/android-sdk")"
SDK="$SDK_REAL"
case "$SDK_REAL" in *" "*) SDK=/tmp/ls-android-sdk; ln -sfn "$SDK_REAL" "$SDK" ;; esac
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK" ANDROID_AVD_HOME="$ROOT/.toolchain/avd"
export PATH="$SDK/platform-tools:$SDK/emulator:$PATH"
export ADB="$SDK/platform-tools/adb" ANDROID_SERIAL="$SERIAL"

WORK="$(mktemp -d /tmp/ls-smoke.XXXXXX)"
EMU_PID=""; RX_PID=""; SEND_PID=""; STARTED_EMU=0
FAILS=0; CHECKS=0
log() { printf '[smoke %s] %s\n' "$(date +%T)" "$*"; }
pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

cleanup() {
  [ -n "$SEND_PID" ] && kill "$SEND_PID" 2>/dev/null
  [ -n "$RX_PID" ] && kill "$RX_PID" 2>/dev/null
  "$ADB" forward --remove "tcp:$FWD_PORT" >/dev/null 2>&1
  if [ "$STARTED_EMU" = 1 ] && [ "${LS_SMOKE_KEEP_EMULATOR:-}" != 1 ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    for _ in $(seq 1 20); do kill -0 "$EMU_PID" 2>/dev/null || break; sleep 1; done
    kill "$EMU_PID" 2>/dev/null
  fi
  if [ "${LS_SMOKE_KEEP_WORK:-}" = 1 ]; then echo "work dir kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- UI helper (uiautomator over adb)
cat >"$WORK/ui.py" <<'PY'
import os, re, subprocess, sys, time, xml.etree.ElementTree as ET
ADB = os.environ.get("ADB", "adb")
def adb(*a):
    return subprocess.run([ADB, *a], capture_output=True, text=True)
def dump():
    for _ in range(4):
        out = adb("exec-out", "uiautomator", "dump", "/dev/tty").stdout
        i, j = out.find("<?xml"), out.rfind("</hierarchy>")
        if i >= 0 and j > i:
            try: return ET.fromstring(out[i:j + 12])
            except ET.ParseError: pass
        time.sleep(0.7)
    return None
def nodes(root):
    res = []
    for n in root.iter("node"):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            res.append(dict(t=n.get("text", ""), d=n.get("content-desc", ""), rid=n.get("resource-id", ""),
                            box=tuple(map(int, m.groups()))))
    return res
def match(ns, pat):
    rx = re.compile(pat, re.I | re.S)
    return [n for n in ns if rx.search(n["t"]) or rx.search(n["d"]) or rx.search(n["rid"])]
def centre(n):
    x1, y1, x2, y2 = n["box"]; return (x1 + x2) // 2, (y1 + y2) // 2
def main():
    cmd, pat = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
    if cmd == "field":  # tap the text field that sits right below the node matching PAT
        root = dump(); ms = match(nodes(root), pat) if root is not None else []
        if not ms: return 1
        x1, y1, x2, y2 = ms[0]["box"]
        adb("shell", "input", "tap", str((x1 + x2) // 2), str(y2 + 90)); return 0
    if cmd in ("wait", "gone"):
        end = time.time() + float(sys.argv[3] if len(sys.argv) > 3 else 20)
        while True:
            root = dump(); ms = match(nodes(root), pat) if root is not None else []
            if (cmd == "wait") == bool(ms): return 0
            if time.time() > end: return 1
            time.sleep(0.6)
    root = dump()
    if root is None: return 3
    ms = match(nodes(root), pat)
    if not ms: return 1
    if cmd == "find": print(ms[0]["t"] or ms[0]["d"]); return 0
    x, y = centre(ms[0])
    if cmd == "tap": adb("shell", "input", "tap", str(x), str(y)); return 0
    if cmd == "press": adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "900"); return 0
    return 2
sys.exit(main())
PY
ui() { python3 -I "$WORK/ui.py" "$@"; }
tap() { ui tap "$1" >/dev/null || { log "UI: could not tap /$1/"; return 1; }; }
waitui() { ui wait "$1" "${2:-20}"; }
shot() { [ -n "${LS_SMOKE_SHOTS:-}" ] && { mkdir -p "$LS_SMOKE_SHOTS"; "$ADB" exec-out screencap -p >"$LS_SMOKE_SHOTS/$1.png"; }; true; }

# ---------------------------------------------------------------- preflight
[ -n "$APK" ] && [ -f "$APK" ] || { echo "no x86_64 APK found (run tools/package_prototype.sh android)"; exit 2; }
[ -x "$SDK/emulator/emulator" ] || { echo "emulator not installed: sdkmanager --sdk_root=$SDK 'emulator' 'system-images;android-35;google_apis;x86_64'"; exit 2; }
[ -d "$SDK/system-images/android-35/google_apis/x86_64" ] || { echo "system image android-35 google_apis x86_64 missing"; exit 2; }
[ -w /dev/kvm ] || { echo "/dev/kvm not writable (add yourself to the kvm group)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
if ss -ltn "( sport = :$PORT )" 2>/dev/null | grep -q LISTEN; then echo "host port $PORT already in use (LS_SMOKE_PORT=...)"; exit 2; fi

make_avd() {
  mkdir -p "$ANDROID_AVD_HOME/$AVD.avd"
  # avdmanager cannot read the SDK when its path contains spaces, so the AVD is written by hand.
  printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/%s.avd\ntarget=android-35\n' "$ANDROID_AVD_HOME/$AVD.avd" "$AVD" >"$ANDROID_AVD_HOME/$AVD.ini"
  cat >"$ANDROID_AVD_HOME/$AVD.avd/config.ini" <<EOF
AvdId=$AVD
PlayStore.enabled=false
abi.type=x86_64
avd.ini.displayname=$AVD
avd.ini.encoding=UTF-8
disk.dataPartition.size=8G
fastboot.forceColdBoot=yes
hw.audioInput=no
hw.audioOutput=no
hw.battery=yes
hw.camera.back=none
hw.camera.front=none
hw.cpu.arch=x86_64
hw.cpu.ncore=4
hw.device.manufacturer=Google
hw.device.name=pixel_6
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.keyboard=yes
hw.lcd.density=420
hw.lcd.height=2400
hw.lcd.width=1080
hw.mainKeys=no
hw.ramSize=2048
hw.sdCard=yes
image.sysdir.1=system-images/android-35/google_apis/x86_64/
runtime.network.latency=none
runtime.network.speed=full
sdcard.size=1024M
showDeviceFrame=no
tag.display=Google APIs
tag.id=google_apis
vm.heapSize=256
EOF
}

boot_emulator() {
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL[[:space:]]*device"; then
    log "reusing running emulator $SERIAL (it will be left running)"; return 0
  fi
  [ -f "$ANDROID_AVD_HOME/$AVD.ini" ] || make_avd
  local mode
  for mode in $GPU_MODES; do
    log "booting AVD $AVD headless, -gpu $mode"
    "$ADB" kill-server >/dev/null 2>&1
    emulator -avd "$AVD" -no-window -no-audio -no-boot-anim -gpu "$mode" -no-snapshot -netdelay none -netspeed full -no-metrics \
      >"$WORK/emulator-$mode.log" 2>&1 &
    EMU_PID=$!; STARTED_EMU=1
    local t0=$SECONDS
    while [ $((SECONDS - t0)) -lt "$BOOT_TIMEOUT" ]; do
      kill -0 "$EMU_PID" 2>/dev/null || { log "emulator exited early with -gpu $mode"; break; }
      if [ "$(timeout 5 "$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
        log "booted in $((SECONDS - t0)) s"; return 0
      fi
      sleep 3
    done
    kill "$EMU_PID" 2>/dev/null; wait "$EMU_PID" 2>/dev/null
  done
  return 1
}

# ---------------------------------------------------------------- test data + host receiver
mkdir -p "$WORK/files" "$WORK/rx"
head -c 1024 /dev/urandom | base64 | head -c 1024 >"$WORK/files/smoke-small.txt"
head -c $((BIG_MB * 1024 * 1024)) /dev/urandom >"$WORK/files/smoke-big.bin"
head -c $((2 * 1024 * 1024)) /dev/urandom >"$WORK/files/linux-to-android.bin"
(cd "$WORK/files" && sha256sum ./* >"$WORK/files.sha256")

log "host receiver on 0.0.0.0:$PORT (alias smoke-host), SECURE profile (TLS 1.3 + verification code)"
# First contact asks "Do the codes match?" on stdin. This script is the human: it compares the digits on the
# emulator screen first and only then writes 'y' to the CLI (fd 8 = receiver, fd 9 = sender). EOF would mean "no".
mkfifo "$WORK/rx.in" "$WORK/tx.in"
exec 8<>"$WORK/rx.in" 9<>"$WORK/tx.in"
dart run packages/libreshare_cli/bin/ls.dart receive --port "$PORT" --dir "$WORK/rx" --auto-accept --alias smoke-host --no-discovery --identity-dir "$WORK/id-rx" \
  >"$WORK/rx.log" 2>&1 <"$WORK/rx.in" &
RX_PID=$!
for _ in $(seq 1 40); do grep -q '^LISTENING' "$WORK/rx.log" 2>/dev/null && break; sleep 0.5; done
check "host receiver is listening" grep -q '^LISTENING' "$WORK/rx.log"

boot_emulator || { fail "emulator boots"; echo "SMOKE FAILED ($FAILS/$CHECKS)"; exit 1; }
pass "emulator boots"
"$ADB" shell settings put global window_animation_scale 0
"$ADB" shell settings put global transition_animation_scale 0
"$ADB" shell settings put global animator_duration_scale 0
"$ADB" shell settings put system screen_off_timeout 600000 >/dev/null 2>&1

# ---------------------------------------------------------------- install + launch
"$ADB" uninstall "$PKG" >/dev/null 2>&1
# Uninstall can leave the app's external dir behind owned by the OLD uid (seen on the emulator); the new
# install then cannot write received files into it (sender sees PROTOCOL_ERROR). Remove it.
"$ADB" shell rm -rf "/storage/emulated/0/Android/data/$PKG" >/dev/null 2>&1
install_apk() { "$ADB" install -r "$APK" >/dev/null 2>&1; }
check "adb install $(basename "$APK")" install_apk
"$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
"$ADB" logcat -c
"$ADB" shell am start -W -n "$PKG/.MainActivity" >/dev/null
check "app shows Home (Nearby)" waitui '^Receive' 30
shot 01-home

# ---------------------------------------------------------------- scenario A: Android -> Linux
log "A: Android -> Linux"
"$ADB" push "$WORK/files/smoke-small.txt" "$WORK/files/smoke-big.bin" /sdcard/Download/ >/dev/null
tap '^Add device$'
waitui '^By IP address' 10 && ui field '^Enter the address shown' && sleep 0.5 && "$ADB" shell input text "10.0.2.2:$PORT"
"$ADB" shell input keyevent 4; sleep 0.5            # hide the keyboard
tap '^Look up'
check "A: Add-device lookup finds the host (confirm dialog)" waitui '^Add this device' 20
shot 02-add-confirm
tap '^Add$'
check "A: device card appears on Home" waitui '^smoke-host, Linux' 20

tap '^Send files$'
waitui '^Show roots' 20
if ! ui find '^Downloads$' >/dev/null 2>&1 || ! ui find 'breadcrumb_text' >/dev/null 2>&1; then
  tap '^Show roots$'; sleep 1; tap '^Downloads$'; sleep 1.5
fi
waitui '^smoke-big.bin$' 15
ui press '^smoke-big.bin$'; sleep 1; tap '^smoke-small.txt$'; sleep 0.8; tap '^Select$'
check "A: Send screen lists 2 selected files" waitui '^2 files selected' 30
shot 03-send-screen
RX_LINES=$(wc -l <"$WORK/rx.log")
T0=$SECONDS
tap '^smoke-host, Linux'
# D5: first contact. The host CLI prints "SAS 123 456 peer=..."; the app (sender) must show the SAME six digits.
for _ in $(seq 1 120); do grep -Eq '^SAS [0-9]{3} [0-9]{3} ' <(tail -n +$((RX_LINES + 1)) "$WORK/rx.log") 2>/dev/null && break; sleep 0.5; done
A_SAS="$(tail -n +$((RX_LINES + 1)) "$WORK/rx.log" | grep -Eo '^SAS [0-9]{3} [0-9]{3}' | head -1 | cut -c5-)"
if [ -n "$A_SAS" ]; then
  pass "A: host CLI printed a 6-digit verification code"
  check "A: app (sender) shows the SAME verification code as the host" waitui "Verification code $A_SAS" 40
  shot 03b-sas-sender
  echo y >&8   # the host user confirms: the codes match
else
  fail "A: host CLI printed no verification code (secure first contact)"
fi
check "A: app reports completion" waitui '^Sent 2 files to smoke-host' 180
echo "      A: transfer wall time ~$((SECONDS - T0)) s for $((BIG_MB)) MiB + 1 KiB (emulator NAT; not representative)"
shot 04-sent
check "A: host printed COMPLETED" grep -q '^COMPLETED' <(tail -n +$((RX_LINES + 1)) "$WORK/rx.log")
check "A: files byte-identical on host" bash -c "cd '$WORK' && cmp files/smoke-small.txt rx/smoke-small.txt && cmp files/smoke-big.bin rx/smoke-big.bin"
check "A: no .lspart leftovers on host" bash -c "! ls '$WORK'/rx | grep -q lspart"
tap '^Done$' >/dev/null 2>&1; sleep 1

# ---------------------------------------------------------------- scenario B: Linux -> Android
log "B: Linux -> Android"
tap '^Receive\n' || tap '^Receive'
# F3: the first Receive-on asks where received files go (one time); keep the default.
if waitui '^Keep default$' 6 >/dev/null 2>&1; then tap '^Keep default$'; fi
check "B: Receive turned on" waitui 'Visible to' 20
shot 05-receive-on
check "B: app listens on 53318 inside the emulator" bash -c "'$ADB' shell ss -ltn 2>/dev/null | grep -q ':53318 '"
"$ADB" forward "tcp:$FWD_PORT" tcp:53318 >/dev/null
dart run packages/libreshare_cli/bin/ls.dart send --to "127.0.0.1:$FWD_PORT" --identity-dir "$WORK/id-tx" "$WORK/files/linux-to-android.bin" "$WORK/files/smoke-small.txt" \
  >"$WORK/send.log" 2>&1 <"$WORK/tx.in" &
SEND_PID=$!
check "B: Incoming transfer dialog appears" waitui '^Incoming transfer' 40
shot 06-incoming
check "B: dialog marks the sender as a New device" waitui '^New device' 10
# D5: the host CLI prints "SAS 123 456 peer=..."; the app's dialog must show the SAME six digits before we accept.
for _ in $(seq 1 80); do grep -Eq '^SAS [0-9]{3} [0-9]{3} ' "$WORK/send.log" 2>/dev/null && break; sleep 0.5; done
B_SAS="$(grep -Eo '^SAS [0-9]{3} [0-9]{3}' "$WORK/send.log" | head -1 | cut -c5-)"
if [ -n "$B_SAS" ]; then
  pass "B: host CLI printed a 6-digit verification code"
  check "B: app (receiver dialog) shows the SAME verification code as the host" waitui "$B_SAS" 20
  echo y >&9   # the host user confirms: the codes match
else
  fail "B: host CLI printed no verification code (secure first contact)"
fi
tap '^Accept$'
for _ in $(seq 1 60); do grep -q '^COMPLETED\|^FAILED' "$WORK/send.log" 2>/dev/null && break; sleep 1; done
check "B: sender CLI reports COMPLETED" grep -q '^COMPLETED' "$WORK/send.log"
check "B: app shows 'Received 2 files'" waitui '^Received 2 files' 20
shot 07-received
mkdir -p "$WORK/pulled"
"$ADB" pull "$APP_DL/linux-to-android.bin" "$WORK/pulled/" >/dev/null 2>&1
"$ADB" pull "$APP_DL/smoke-small.txt" "$WORK/pulled/" >/dev/null 2>&1
check "B: pulled files byte-identical" bash -c "cd '$WORK' && cmp files/linux-to-android.bin pulled/linux-to-android.bin && cmp files/smoke-small.txt pulled/smoke-small.txt"

# ---------------------------------------------------------------- S7: protection of identity/secret files (modes only, never contents)
# The release APK is not debuggable (no run-as), but the google_apis emulator image allows `adb root`.
if "$ADB" root >/dev/null 2>&1; then
  "$ADB" wait-for-device; sleep 3
  SEC="/data/data/$PKG/files/security"
  s7_bad() { "$ADB" shell "for f in $SEC/*; do stat -c '%a %n' \$f; done" 2>/dev/null | tr -d '\r' | grep -v '^600 ' || true; }
  check "S7: security directory exists and is mode 700" test "$("$ADB" shell stat -c %a "$SEC" 2>/dev/null | tr -d '\r')" = 700
  check "S7: a *.secret identity key file exists" bash -c "'$ADB' shell ls '$SEC' 2>/dev/null | grep -q '\.secret\$'"
  if [ -z "$(s7_bad)" ]; then pass "S7: every file in the security directory is mode 600"; else fail "S7: files not mode 600 in the security directory"; fi
else
  log "S7 SKIPPED: adb root is not available on this emulator image"
fi

# ---------------------------------------------------------------- crash check
CRASH="$("$ADB" logcat -d -b crash 2>/dev/null | grep -c "$PKG")"
check "no app crash in logcat -b crash" test "$CRASH" -eq 0

echo
if [ "$FAILS" -eq 0 ]; then echo "SMOKE PASSED ($CHECKS checks)"; exit 0; fi
echo "SMOKE FAILED ($FAILS of $CHECKS checks failed). Re-run with LS_SMOKE_SHOTS=/tmp/shots to keep screenshots."
exit 1
