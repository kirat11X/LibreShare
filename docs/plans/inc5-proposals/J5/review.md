# Review: Card J5 (Tunnel Providers)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/tunnel/binary_installer.dart` (new file, `patch.diff` count: 6 files, `grep -c '^--- ' patch.diff` = 6)
  - `packages/libreshare_core/lib/src/tunnel/cloudflared_provider.dart` (new file)
  - `packages/libreshare_core/lib/src/tunnel/cloudflared_versions.dart` (new file)
  - `packages/libreshare_core/lib/src/tunnel/manual_url_provider.dart` (new file)
  - `packages/libreshare_core/lib/src/tunnel/process_supervisor.dart` (new file)
  - `packages/libreshare_core/lib/src/tunnel/zrok_provider.dart` (new file)
  - `packages/libreshare_core/test/unit/binary_installer_test.dart`
  - `packages/libreshare_core/test/unit/process_supervisor_test.dart`
- Spec & plan rows satisfied:
  - `FR-14` (Off-LAN Internet sharing via Cloudflare Quick Tunnels, zrok, and user-provided manual reverse proxy URLs)
  - `NFR-04` (Helper binary security: pinned SHA-256 integrity verification, isolated temporary home directories, explicit prohibition of `--allowed-mail`)
  - `docs/plans/inc5-seams.md` Section 8 (`CloudflaredProvider`, `ZrokProvider`, `ManualUrlProvider`, `BinaryInstaller`)

## 2. Diff Read
- `binary_installer.dart` & `cloudflared_versions.dart` (`L1-160`): OK. **[SECURITY-CRITICAL: Binary Integrity]** Downloads pinned platform binaries (Linux x64/arm64, Windows x64, macOS). Validates raw SHA-256 checksum before setting executable bits (`chmod 755`). Deletes corrupt downloads immediately.
- `process_supervisor.dart` (`L1-220`): OK. **[SECURITY-CRITICAL: Subprocess & Argv]** Manages daemon lifecycle. Discovers public URL from stdout/stderr regex. Asserts that `--allowed-mail` is never included in argv. Isolates `HOME` to temporary directory. Terminates via SIGTERM followed by SIGKILL.
- `cloudflared_provider.dart` (`L1-95`): OK. Implements `TunnelProvider` for Cloudflare Quick Tunnels (`trycloudflare.com`).
- `zrok_provider.dart` (`L1-85`): OK. Implements `TunnelProvider` for OpenZiti zrok.
- `manual_url_provider.dart` (`L1-55`): OK. Validates user-supplied HTTPS base URLs.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Pinned checksums | `pinned cloudflared metadata contains valid SHA-256...` | Checksum table exists and adheres to 64-char hex format for all supported desktop architectures. |
| Checksum enforcement | `BinaryInstaller verifies SHA-256 and installs binary...` | Rejects tampered binary with `BinaryVerificationException`; sets executable bits on verified binary. |
| Manual URL parsing | `ManualUrlProvider accepts valid HTTPS URL...` | Confirms valid HTTPS URL yields operational `TunnelHandle`. |
| Manual URL validation | `ManualUrlProvider rejects non-HTTPS or invalid URLs` | Rejects `http://` or malformed URLs with `ArgumentError`. |
| Cloudflare daemon lifecycle | `CloudflaredProvider spawns supervisor, discovers URL...` | Captures public URL from daemon output and shuts down process cleanly. |
| zrok daemon lifecycle | `ZrokProvider spawns supervisor, discovers URL...` | Captures public URL from zrok daemon output and terminates cleanly. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Binary SHA-256 check | Skip checksum verification in `BinaryInstaller` | `BinaryInstaller verifies SHA-256` | rc=1 | `diff -r` clean, rc=0 |
| Cloudflare argv invariant | Append `--allowed-mail` to argv | `buildCloudflaredArgv assertion failure` | rc=1 | `diff -r` clean, rc=0 |
| Manual URL HTTPS check | Allow plaintext `http://` scheme | `ManualUrlProvider rejects non-HTTPS or invalid URLs` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Tampered helper binary download:** 1 byte modified in downloaded helper binary; caught by SHA-256 digest check, temp file removed, raises `BinaryVerificationException`.
2. **Daemon that fails to output public URL within timeout:** Times out cleanly after ready deadline, terminates child process with SIGKILL.
3. **Stale PID file from previous crashed run:** Reads PID file, probes process, terminates orphan process safely before starting new tunnel.
4. **Manual URL with embedded credentials (`https://user:pass@domain.com`):** Strips credentials and rejects userinfo.
5. **SIGTERM ignore:** Process that ignores SIGTERM is forcibly re-killed with SIGKILL after grace period.

## 6. Resource and Failure Behaviour
- Processes: managed by `ProcessSupervisor`. PIDs tracked and killed on `close()`.
- Temporary directories: temporary isolated `HOME` directories deleted on shutdown.
- Stale pid files unlinked on exit.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J5/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/tunnel/`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/tunnel/`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Ensure binary download URLs and SHA-256 digests in `cloudflared_versions.dart` match upstream Cloudflare official release artifacts.
- Verify that Android platform gracefully disables binary supervisor and routes through in-app providers or manual URLs.
