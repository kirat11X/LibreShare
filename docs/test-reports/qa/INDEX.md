# LibreShare QA Campaign: Bug Index

Running index of all bugs identified during QA Campaign (Waves A–G) per `docs/plans/GEMINI_QA_PROMPT.md`.

| Bug ID | Severity | Status | Title | Found By | Proposed Fix |
| :--- | :--- | :--- | :--- | :--- | :--- |
| *(None)* | - | - | *No open S0/S1 blockers identified in applied tree* | - | - |

---

### Known Non-Bugs / Documented Exceptions (Not Logged as Bugs)
1. **FR-15 Resume Ack Window:** `kResumePersistEvery = 8` (`Q-FR15-ACK-WINDOW`, user decision pending).
2. **Weakened Test Decoupling:** 6 test assertions decoupled from implementation details per user decision.
3. **Hardware / Radio Features:** Windows bcrypt path, BLE/hotspot hardware, real router/tunnel live runs marked `UNVERIFIED` by design.
4. **Inc 4b:** Multi-isolate pipeline parked.
5. **Load Flakes Under Parallel Contention:** 6 known load flakes documented with root causes in `docs/test-reports/flake-analysis.md` (port collisions, socket TIME_WAIT, CPU scheduling jitter).
