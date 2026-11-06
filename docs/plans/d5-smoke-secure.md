# D5 Smoke Secure: Proposed Post-D1 Hardening for `tools/android_emulator_smoke.sh`

This document drafts the changes to transition `tools/android_emulator_smoke.sh` from plaintext prototype testing to fully encrypted TLS 1.3 + SAS verification testing once Card D1 is verified and `APP_SECURE_WIRED: YES`.

Do **NOT** apply this script until Card D1 review is complete and the packaging artifacts have been updated via `tools/package_prototype.sh`.

---

## 1. Overview of Changes

1. **Drop `--insecure-plaintext` from Host Receiver (Scenario A)**:
   - Line 208: Remove `--insecure-plaintext`. The CLI host receiver defaults to secure profile with persistent/temporary credentials.
   - In Scenario A (Android -> Linux), Android app initiates TLS 1.3 handshake with host.

2. **Drop `--insecure-plaintext` from Host Sender (Scenario B)**:
   - Line 275: Remove `--insecure-plaintext`. The CLI host sender connects via TLS 1.3 to the Android app listening on forwarded port 53318.

3. **Verify SAS Verification Code (First Contact TOFU)**:
   - Both Android app and Host CLI start with empty trust stores in the test run.
   - Scenario B (Linux -> Android):
     - Host CLI `ls send` outputs: `Verification code: (\d{3} \d{3})` or `SAS (\d{3} \d{3})`.
     - Android app incoming transfer dialog displays:
       - Heading: `Verification code`
       - Code: `\d{3} \d{3}`
       - Subtitle: `Ask smoke-host to read the code on their screen. Accept only if it is the same.`
       - Badge: `New device`
     - Smoke script extracts the 6-digit SAS from `send.log` and asserts that the UI text on the emulator matches byte-for-byte before tapping `Accept`.

---

## 2. Proposed Diff against `tools/android_emulator_smoke.sh`

```diff
--- a/tools/android_emulator_smoke.sh
+++ b/tools/android_emulator_smoke.sh
@@ -205,8 +205,8 @@
 (cd "$WORK/files" && sha256sum ./* >"$WORK/files.sha256")
 
 log "host receiver on 0.0.0.0:$PORT (alias smoke-host)"
-dart run packages/libreshare_cli/bin/ls.dart receive --port "$PORT" --dir "$WORK/rx" --auto-accept --alias smoke-host --no-discovery --insecure-plaintext \
+dart run packages/libreshare_cli/bin/ls.dart receive --port "$PORT" --dir "$WORK/rx" --auto-accept --alias smoke-host --no-discovery \
   >"$WORK/rx.log" 2>&1 </dev/null &
 RX_PID=$!
 for _ in $(seq 1 40); do grep -q '^LISTENING' "$WORK/rx.log" 2>/dev/null && break; sleep 0.5; done
 check "host receiver is listening" grep -q '^LISTENING' "$WORK/rx.log"
@@ -272,11 +272,21 @@
 shot 05-receive-on
 check "B: app listens on 53318 inside the emulator" bash -c "'$ADB' shell ss -ltn 2>/dev/null | grep -q ':53318 '"
 "$ADB" forward "tcp:$FWD_PORT" tcp:53318 >/dev/null
-dart run packages/libreshare_cli/bin/ls.dart send --to "127.0.0.1:$FWD_PORT" --insecure-plaintext "$WORK/files/linux-to-android.bin" "$WORK/files/smoke-small.txt" \
+dart run packages/libreshare_cli/bin/ls.dart send --to "127.0.0.1:$FWD_PORT" "$WORK/files/linux-to-android.bin" "$WORK/files/smoke-small.txt" \
   >"$WORK/send.log" 2>&1 </dev/null &
 SEND_PID=$!
 check "B: Incoming transfer dialog appears" waitui '^Incoming transfer' 40
 shot 06-incoming
+
+# SAS Verification Code Assertion:
+# Extract the SAS code from CLI sender log (formatted as "Verification code: 123 456" or similar)
+for _ in $(seq 1 20); do grep -Eiq 'Verification code|SAS' "$WORK/send.log" 2>/dev/null && break; sleep 0.5; done
+HOST_SAS="$(grep -Eio '[0-9]{3} [0-9]{3}' "$WORK/send.log" | head -1)"
+if [ -n "$HOST_SAS" ]; then
+  check "B: emulator displays matching 6-digit verification code ($HOST_SAS)" waitui "$HOST_SAS" 15
+else
+  fail "B: host CLI output did not contain verification code"
+fi
+
 tap '^Accept$'
 for _ in $(seq 1 60); do grep -q '^COMPLETED\|^FAILED' "$WORK/send.log" 2>/dev/null && break; sleep 1; done
 check "B: sender CLI reports COMPLETED" grep -q '^COMPLETED' "$WORK/send.log"
```

---

## 3. Preconditions for Applying

1. Card D1 is verified green by the orchestrator.
2. `tools/package_prototype.sh linux android` has been executed under `flock -o /tmp/libreshare-heavy.lock` to produce the secure x86_64 APK.
3. Checksums match in `dist/prototype/SHA256SUMS`.
