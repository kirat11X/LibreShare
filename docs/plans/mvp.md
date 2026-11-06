# MVP cut (user decision 2026-11-05: "shrink it, so I can just show MVP, not the whole thing, for now")

**MVP = send files between my own devices (Android <-> Linux, and Windows) on the same Wi-Fi, encrypted and verified, with an app that is usable.** Everything else is deferred, not dropped: the roadmap and the specs stay as they are.

## IN (what the MVP contains)

| Part | State |
|---|---|
| Increments 1-2: protocol, transfer, discovery, Linux/Windows/Android app, tray, receive mode | done, emulator-verified for Android |
| Increment 3 core: TLS 1.3 + pinning, signed client proof, SAS verification code on first contact, consent prompt, optional PIN, key-change refusal, rate limits, signed goodbye, Contacts-only gate | building blocks done and independently reviewed; engine + CLI wiring (P6a) in progress |
| **MVP-App (new, small)**: incoming dialog shows the SAS digits, sender shows its digits while waiting, key-changed warning, PIN setting, "Your fingerprint" in Settings, contacts list (view/remove) | to do |
| **MVP-Android fixes (F3)**: public default download folder + working Open/Show in folder, real device name (no "localhost"), honest failure texts | to do |
| Packaging: Linux tarball, Android APKs (rebuilt with the secure code), Windows build (needs a Windows PC or a GitHub Actions run, see below), Docker headless node (optional) | to do after the app work |
| Demo guide + honest known-limits list | to do |

## OUT (deferred, kept in the roadmap)

- P9 Android background receive service (MVP: keep the app open; keep-screen-on is already in the APK).
- Notifications and notification actions.
- QR pairing screen and Contacts-only visibility toggle in the UI (the core and CLI support them; UI later).
- P10 extra Docker end-to-end scenarios (existing e2e must stay green).
- Windows secure key store (file store is used).
- Increment 4 (connection ladder, resume across channels, hashing speed), Increment 5 (internet tunnel, share link/QR), 5b, Increment 6 (free rendezvous), Increment 7 (BLE + hotspot), Polish.

## Demo script (what you can show)

1. Install on the phone and the PC. Both on the same Wi-Fi.
2. Phone sends a photo to the PC: both screens show the same 6-digit code, the PC user accepts, the file arrives byte-identical.
3. Send again: no code needed (the PC is now pinned).
4. Show the safety nets: wrong PIN is rejected; a device with a changed key is refused with a clear warning; a stranger gets nothing.
5. Same with Windows (if the Windows build exists).

## Effort left to the MVP (estimates, not measurements)

P6a finish + review about 2-3 days, MVP-App about 2, F3 about 1.5, packaging + emulator re-test about 1: roughly **6-8 person-days**, against about 170 for the full roadmap.

## Needs the user (not done on purpose)

The Windows app can only be built on a Windows PC or via GitHub Actions. I have not pushed anything (standing instruction). Say "create a private repo and run the Windows build" if you want it.
