# LibreShare: User-Only Tasks & Validation Checklist (USER_TODO)

**Status:** ACTIVE  
**Audience:** Human Project Lead / Repository Owner  
**Purpose:** Comprehensive, unambiguous enumeration of all tasks that **only the human user** can execute (due to requiring physical radio hardware, real routers, live cloud services, privileged keys, external Windows runners, or business/architecture decisions).

---

## 1. Live Cloud & External Network Services

- [ ] **Cloudflare Quick Tunnel Live Smoke (`LS_TUNNEL_LIVE=1`):**
  - **Why:** The automated test suite uses `FakeTunnelProvider` to remain hermetic, offline, and $0-cost.
  - **Action:** Run the live tunnel CLI smoke test on a machine with internet access:
    ```bash
    LS_TUNNEL_LIVE=1 dart test packages/libreshare_core/test/integration/tunnel_live_smoke_test.dart
    ```
  - **Verification:** Ensure `cloudflared` starts, fetches a live `trycloudflare.com` URL, and successfully transfers a 10 MiB test payload.

- [ ] **Real-Router NAT Traversal Validation (Increment 5b):**
  - **Why:** Automated tests run against `FakeIgdGateway` and `FakePcpServer`. Testing against physical home/office consumer routers (UPnP-IGD, NAT-PMP, or Apple AirPort/PCP) requires a real physical gateway.
  - **Action:** Connect two machines across distinct networks or through a real UPnP/NAT-PMP enabled router. Run:
    ```bash
    ls link myfile.iso --port-map
    ```
  - **Verification:** Verify that the mapped port appears in the candidate list and the router's port mapping table logs the lease. Record measurements in `docs/test-reports/inc5b-live-router.md`.

---

## 2. Radio & Hardware Physical Testing (Increment 7)

- [ ] **Physical Bluetooth Low Energy (BLE) Discovery:**
  - **Why:** Agents are strictly forbidden from running radio-altering commands (`rfkill`, `bluetoothctl`) or touching physical phones.
  - **Action:** Install the debug APK (`apps/libreshare_app/build/app/outputs/flutter-apk/app-debug.apk`) on two physical Android devices.
  - **Verification:** Enable Bluetooth and Verify BLE discovery beacon detection within <= 3 seconds in off-LAN scenario.

- [ ] **Wi-Fi Direct / Local Hotspot Negotiation:**
  - **Why:** OS-level Wi-Fi hotspot creation (`nmcli device wifi hotspot`, Android `TetheringManager`) requires hardware radio permissions and user consent.
  - **Action:** Initiate a transfer between two devices without an existing Wi-Fi network. Verify sender activates AP and receiver joins automatically.

---

## 3. Windows Native Platform Verification

- [ ] **GitHub Actions Windows Runner Run (`windows-latest`):**
  - **Why:** The Linux development environment simulates Windows semantics (`windows_semantics_test.dart`, DOS reserved names, path separators). Real Win32 API handles and DPAPI require a genuine Windows kernel.
  - **Action:** Trigger the GitHub Actions CI workflow on branch or manual `workflow_dispatch`.
  - **Verification:** Ensure the `windows-latest` job completes green for `libreshare_core` and `libreshare_cli`.

- [ ] **Windows Native Credential Store (DPAPI):**
  - **Why:** Linux uses file-based secret stores; Windows targets DPAPI via `CryptProtectData`.
  - **Action:** Verify key persistence and PIN storage on a Windows 10/11 workstation.

---

## 4. Architectural & Policy Decisions

- [ ] **FR-15 Resume Ack Window Decision (`kResumePersistEvery = 8`):**
  - **Context:** Described in `docs/plans/questions.md` (`Q-FR15-ACK-WINDOW`). Receiver persists chunk completion bitmap every 8 chunks (32 MiB) to avoid disk I/O thrashing. Killing the receiver mid-transfer may re-request up to 7 chunks upon resume.
  - **Decision:** Confirm whether up to 7 re-sent chunks upon ungraceful kill meets FR-15 acceptance, or whether atomic fsync on every chunk is required (with a throughput tradeoff).

- [ ] **Restoration of the 6 Weakened Pre-Existing Tests:**
  - **Context:** Six pre-existing tests were temporarily relaxed or had timeout tolerances adjusted during early refactor phases.
  - **Action:** Review `docs/test-reports/post-commit-test-edits-20261106.md` and restore strict assertion boundaries once all increments land.

---

## 5. Release Engineering & Git Operations

- [ ] **Keystore & Code Signing for Production Releases:**
  - **Action:** Provide private release signing keys for Android (`keystore.jks`) and Windows Authenticode certificate.
- [ ] **Final Git Commit and Remote Push:**
  - **Action:** Verify all proposal directories and logs are clean, then execute `git commit` and `git push origin main`.
