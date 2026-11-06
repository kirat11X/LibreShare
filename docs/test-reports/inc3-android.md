# Increment 3 Real-Phone Test Checklist & Results

**Date:** 2026-11-06  
**Status:** PENDING REAL-PHONE RUNS (Container environment has no physical hardware)

## Test Environment
- Device Model: `[FILL]`
- Android Version: `[FILL]` (e.g. Android 13 / 14)
- Manufacturer / OEM: `[FILL]` (e.g. Samsung OneUI, Google Pixel, Xiaomi MIUI)

---

## 1. Foreground Receive Verification
- [ ] App launches and enables Receive toggle cleanly.
- [ ] Discovery over local Wi-Fi discovers peer in <= 3 seconds.
- [ ] 100 MiB transfer completes byte-identical in foreground.

---

## 2. Background Receive (Screen Off / Doze)
- [ ] `ReceiveService` starts with foreground notification visible.
- [ ] Screen turned off during active transfer.
- [ ] 100 MiB transfer completes byte-identical without stall or disconnect.
- [ ] Notification updates or dismisses cleanly upon completion.

---

## 3. OEM Battery Killer Behavior
- [ ] Screen off for 15 minutes before transfer initiated.
- [ ] Inbound connection wakes service / handles incoming consent.
- [ ] Battery saver enabled: guidance tile displays relevant system navigation.

---

## 4. Quick Settings Tile
- [ ] Quick Settings tile added to notification shade.
- [ ] Tap toggles service state between ACTIVE and INACTIVE.
- [ ] App UI reflects tile toggle state.
