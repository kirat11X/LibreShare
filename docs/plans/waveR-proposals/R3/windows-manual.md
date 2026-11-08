# Windows Manual Verification Checklist (Wave R3)

This checklist covers manual verification items that cannot be fully automated in CI runners (UI interactions, OS firewall prompts, sleep/wake, multi-device LAN discovery).

| ID | Category | Test Scenario | Steps / Expected Behavior | Status |
|---|---|---|---|---|
| WIN-01 | Firewall | First Launch & Inbound Connection | 1. Launch `libreshare.exe` on a fresh Windows 10/11 system.<br>2. Windows Defender Firewall popup appears requesting access on private networks.<br>3. Grant access.<br>4. App binds to port 53317 (or falls back in range 53317-53327). | PENDING_MANUAL |
| WIN-02 | Discovery | Cross-Platform mDNS | 1. Open LibreShare on Windows machine and Android / Linux device on the same Wi-Fi.<br>2. Verify each device appears in the other's "Nearby Devices" within 3 seconds.<br>3. Verify hostname, device type icon (desktop), and alias match. | PENDING_MANUAL |
| WIN-03 | File Transfer | Standard Send & Receive | 1. Select a 1 GB file on Windows.<br>2. Send to Android/Linux peer.<br>3. Accept on peer.<br>4. Compare SHA-256 hash on both devices; verify byte-identical. | PENDING_MANUAL |
| WIN-04 | UX / Shell | Drag & Drop | 1. Drag one or multiple files from Windows File Explorer onto the LibreShare app window.<br>2. Verify files are staged in the transfer queue with correct names and byte counts. | PENDING_MANUAL |
| WIN-05 | File System | Download Folder & UNC/Long Paths | 1. Set download directory to a nested path exceeding 260 characters (`\\?\` or NTFS long path enabled).<br>2. Set download directory to a network share (`\\server\share\downloads`).<br>3. Verify incoming transfers write without path truncation or access violations. | PENDING_MANUAL |
| WIN-06 | Tray / Background | Minimize to System Tray | 1. Minimize app while a transfer is in progress.<br>2. Verify transfer continues uninterrupted in background.<br>3. Click tray icon to restore window. | PENDING_MANUAL |
| WIN-07 | Network Fault | Wi-Fi Disconnect & Reconnect | 1. Start a multi-file transfer.<br>2. Toggle Windows Wi-Fi off for 3 seconds, then on.<br>3. Verify transfer resumes missing chunks without restarting from 0. | PENDING_MANUAL |
| WIN-08 | Power / Sleep | Modern Standby / Sleep Resume | 1. Put Windows device to sleep mid-transfer.<br>2. Wake machine within 30 seconds.<br>3. Verify app handles socket reconnect gracefully or reports connection timeout without crashing. | PENDING_MANUAL |
