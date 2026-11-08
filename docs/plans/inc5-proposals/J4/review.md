# Review: Card J4 (OriginPullConnection & TunnelConnection)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/connection/origin_pull_connection.dart` (new file, `patch.diff` count: 2 files, `grep -c '^--- ' patch.diff` = 2)
  - `packages/libreshare_core/lib/src/connection/tunnel_connection.dart` (new file)
  - `packages/libreshare_core/test/unit/origin_pull_connection_test.dart`
  - `packages/libreshare_core/test/unit/link_resume_test.dart`
  - `packages/libreshare_core/test/unit/tunnel_fallback_test.dart`
- Spec & plan rows satisfied:
  - `FR-14` (Off-LAN share link fallback, Candidate ladder integration, PeerClient adapter)
  - `NFR-03` (Reliability: Resume interrupted transfers over tunnel using chunk bitmap)
  - `docs/plans/inc5-seams.md` Section 7 (`TunnelConnection`, `OriginPullConnection`)

## 2. Diff Read
- `origin_pull_connection.dart` (`L1-118`): OK. Implements reverse-pull HTTP client fetching manifest and encrypted chunks through tunnel URL. Adapts responses into standard `PeerClient` API.
- `tunnel_connection.dart` (`L1-86`): OK. **[SECURITY-CRITICAL: Candidate Ladder]** Implements `Connection` interface on the Inc 4 ladder. State transitions (`connecting` $\rightarrow$ `connected` / `failed`). Verifies origin connectivity prior to returning client.
- TLS verification (`tunnel_connection.dart` `L52-70`): OK. **[SECURITY-CRITICAL: TLS Root Trust]** Uses standard system root CA validation for public HTTPS tunnels (`trycloudflare.com`, `zrok.io`), preventing MITM attacks.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Connection contract | `TunnelConnection opens path, yields PeerClient...` | State machine transitions properly, returns working `PeerClient`, fetches manifest and chunks. |
| Ladder fallback | `when local LAN candidate fails, connection falls back...` | Inability to connect on primary local candidate falls back to tunnel tier and completes transfer byte-identical. |
| Resume across crash | `receiver killed after chunk 0 resumes with same key...` | Uses existing chunk bitmap to request only missing chunks; output matches byte-identical. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Fallback dispatch | Disable tunnel candidate evaluation | `when local LAN candidate fails, connection falls back` | rc=1 | `diff -r` clean, rc=0 |
| Resume bitmap check | Always request from chunk 0 | `receiver killed after chunk 0 resumes with same key` | rc=1 | `diff -r` clean, rc=0 |
| Origin probe validation | Skip pre-flight probe in `open()` | `TunnelConnection opens path, yields PeerClient` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Unreachable public tunnel endpoint:** Sets state to `ConnectionState.failed` and throws `ConnectionException` within timeout bound.
2. **Abrupt connection drop during chunk 1 stream:** Closes client cleanly and allows retry without leaking file handles.
3. **Mismatched server response during origin probe:** Throws `ConnectionException` and rejects the candidate.
4. **Resuming with mismatched root key:** Fails AEAD chunk authentication and aborts transfer.
5. **Slow tunnel handshake:** Handshake bounded by 15s timeout; aborts if tunnel is unresponsive.

## 6. Resource and Failure Behaviour
- Network connections: HTTP client closed via `close()` on teardown.
- File handles: streams closed upon error or completion.
- Secret redaction: logs omit root key and token query fragments.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J4/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/connection/origin_pull_connection.dart packages/libreshare_core/lib/src/connection/tunnel_connection.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/connection/origin_pull_connection.dart packages/libreshare_core/lib/src/connection/tunnel_connection.dart`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Candidate ladder priority ordering: ensure tunnel candidate is placed strictly below direct LAN and Wi-Fi candidates.
