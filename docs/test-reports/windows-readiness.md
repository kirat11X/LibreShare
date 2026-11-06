# LibreShare Windows Readiness Audit

**Date:** 2026-11-05  
**Auditor:** Card A9 Auditor  
**Scope:** `packages/*/lib` (`packages/libreshare_core/lib`, `packages/libreshare_cli/lib`) and `apps/libreshare_app/lib`  
**Purpose:** Identify code patterns, system calls, path handling, and APIs that will break or present risks on Windows environments where no local Windows compiler/build is present.

---

## Executive Summary

| Category | Total Hits | OK | Risk | Needs Windows Test |
|---|---|---|---|---|
| 1. `Platform.is*` | 16 | 12 | 3 | 1 |
| 2. `chmod` | 8 | 8 | 0 | 0 |
| 3. `Process.run` / `Process.start` | 3 | 2 | 1 | 0 |
| 4. Hard-coded `/` path joins vs `package:path` | 15 | 4 | 4 | 7 |
| 5. `HOME` / `XDG_*` | 11 | 11 | 0 | 0 |
| 6. `USERPROFILE` / `APPDATA` | 2 | 2 | 0 | 0 |
| 7. `File.setLastModified` | 1 | 0 | 0 | 1 |
| 8. `FileMode.append` + `setPosition` | 3 | 1 | 2 | 0 |
| 9. `Link(` | 1 | 0 | 0 | 1 |
| 10. Reserved Windows filenames in `filename_sanitizer.dart` | 6 | 5 | 1 | 0 |
| 11. Long paths (>260 chars / MAX_PATH) | 2 | 1 | 1 | 0 |
| **Additional Windows Specific Findings** (Atomic `File.rename`) | 5 | 0 | 5 | 0 |

---

## 1. `Platform.isLinux | isWindows | isAndroid | isMacOS | isIOS`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_cli/lib/ls_cli.dart:197` | `if (Platform.isWindows)` | **ok** | Correctly switches config dir resolution to `%APPDATA%` / `%USERPROFILE%`. |
| `packages/libreshare_cli/lib/ls_cli.dart:306` | `if (!Platform.isWindows)` | **ok** | Excludes `ProcessSignal.sigterm.watch()`, which throws `UnsupportedError` on Windows in Dart. |
| `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:140` | `reusePort: !Platform.isWindows` | **ok** | Windows lacks `SO_REUSEPORT`; sets `reusePort: false` with retry fallback on bind. |
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1418` | `if (Platform.isWindows) return null;` | **risk** | Skips POSIX `df -Pk`. Causes upfront free space check to be bypassed completely on Windows; disk exhaustion fails mid-transfer rather than cleanly rejecting. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:256` | `if (Platform.isWindows) return;` | **needs Windows test** | Relies on `%APPDATA%` ACL to protect secrets. If a custom directory is used, permissions remain unmanaged. |
| `apps/libreshare_app/lib/platform/bonsoir_mdns_backend.dart:181` | `final hint = Platform.isLinux ? ...` | **ok** | Error diagnostic message string only. |
| `apps/libreshare_app/lib/platform/platform_factory.dart:49` | `if (Platform.isLinux) return PlatformKind.linux;` | **ok** | Platform enum mapping. |
| `apps/libreshare_app/lib/platform/platform_factory.dart:50` | `if (Platform.isWindows) return PlatformKind.windows;` | **ok** | Platform enum mapping. |
| `apps/libreshare_app/lib/platform/platform_factory.dart:51` | `if (Platform.isAndroid) return PlatformKind.android;` | **ok** | Platform enum mapping. |
| `apps/libreshare_app/lib/services/device_identity.dart:13` | `Platform.isAndroid \|\| Platform.isIOS ? 'mobile' : 'desktop'` | **ok** | Correctly maps Windows to `desktop`. |
| `apps/libreshare_app/lib/services/file_launcher.dart:25` | `if (Platform.isLinux) return _start('xdg-open', [path]);` | **ok** | Linux branch. |
| `apps/libreshare_app/lib/services/file_launcher.dart:26` | `if (Platform.isWindows) return _start('rundll32', ['url.dll,FileProtocolHandler', path]);` | **risk** | `rundll32 url.dll,FileProtocolHandler` fails on Windows if `path` contains spaces, `#`, `&`, commas, or non-ASCII characters. |
| `apps/libreshare_app/lib/services/file_launcher.dart:29` | `if (Platform.isMacOS) return _start('open', [path]);` | **ok** | macOS branch. |
| `apps/libreshare_app/lib/services/file_launcher.dart:35` | `if (Platform.isLinux) return _start('xdg-open', [parentDir(path)]);` | **ok** | Linux branch. |
| `apps/libreshare_app/lib/services/file_launcher.dart:36` | `if (Platform.isWindows) return _start('explorer.exe', ['/select,$path']);` | **risk** | `explorer.exe /select,$path` fails if path contains forward slashes, spaces, or if `parentDir` returns `C:` for drive roots. |
| `apps/libreshare_app/lib/services/file_launcher.dart:37` | `if (Platform.isMacOS) return _start('open', ['-R', path]);` | **ok** | macOS branch. |

---

## 2. `chmod`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:68` | `/// Runs chmod <mode> <path>` | **ok** | Documentation comment. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:72` | `final r = await Process.run('chmod', [mode, path]);` | **ok** | Implementation of default `_systemChmod`. Never reached on Windows due to line 256. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:147` | `/// [chmod] is for tests` | **ok** | Documentation comment. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:148` | `FileSecretStore(..., {ChmodRunner? chmod})` | **ok** | Constructor parameter. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:149` | `: _chmod = chmod ?? _systemChmod;` | **ok** | Field assignment. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:155` | `final ChmodRunner _chmod;` | **ok** | Field declaration. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:259` | `code = await _chmod(mode, File(path).absolute.path);` | **ok** | Guarded by line 256 `if (Platform.isWindows) return;`. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:261` | `_log.warning('chmod unavailable: ${e.runtimeType}');` | **ok** | Fallback catch for non-Windows systems lacking chmod. |

---

## 3. `Process.run | Process.start`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1421` | `final r = await Process.run('df', ['-Pk', dir.path]);` | **ok** | Guarded by line 1418 `if (Platform.isWindows) return null;`. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:72` | `final r = await Process.run('chmod', [mode, path]);` | **ok** | Guarded by line 256 `if (Platform.isWindows) return;`. |
| `apps/libreshare_app/lib/services/file_launcher.dart:43` | `await Process.start(exe, args, mode: ProcessStartMode.detached);` | **risk** | Process spawning on Windows with `rundll32` / `explorer.exe`. Without Windows command-line quoting, paths containing spaces or punctuation fail to launch. |

---

## 4. Hard-coded `/` Path Joins vs `package:path`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_cli/lib/ls_cli.dart:199` | `Directory('$app${sep}LibreShare')` | **needs Windows test** | Manual string concatenation using `Platform.pathSeparator`. If `%APPDATA%` ends with `\`, results in double backslash. |
| `packages/libreshare_cli/lib/ls_cli.dart:202` | `Directory('$xdg${sep}libreshare')` | **needs Windows test** | Manual string concatenation. |
| `packages/libreshare_cli/lib/ls_cli.dart:204` | `Directory('$h$sep.config${sep}libreshare')` | **needs Windows test** | Manual string concatenation. |
| `packages/libreshare_core/lib/src/storage/receive_settings_store.dart:56` | `File('${directory.path}${Platform.pathSeparator}$fileName')` | **needs Windows test** | String interpolation instead of `p.join`. If directory is root (e.g. `C:\`), produces `C:\\settings.json`. |
| `packages/libreshare_core/lib/src/storage/receive_settings_store.dart:58` | `File('${directory.path}${Platform.pathSeparator}$fileName.tmp')` | **needs Windows test** | Same root directory path separator risk. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:165` | `File('${directory.path}${Platform.pathSeparator}$hash.secret')` | **needs Windows test** | Same root directory path separator risk. |
| `packages/libreshare_core/lib/src/storage/device_registry.dart:227` | `File('${d.path}${Platform.pathSeparator}$fileName')` | **needs Windows test** | Same root directory path separator risk. |
| `packages/libreshare_core/lib/src/storage/credential_store.dart:142` | `File('${directory.path}${Platform.pathSeparator}$identityFileName')` | **needs Windows test** | Same root directory path separator risk. |
| `apps/libreshare_app/lib/services/paths.dart:8-19` | `joinPath(String first, [String? second, String? third])` | **risk** | Custom path join function instead of `package:path`. Strips leading `/` or `\` from second segment but does not recognize Windows drive roots or re-rooting. |
| `apps/libreshare_app/lib/services/paths.dart:22-27` | `parentDir(path)` | **risk** | Calls `path.substring(0, i)` on last separator. For `C:\Folder`, returns `C:`. In Windows, `C:` refers to current working directory on drive C, NOT root `C:\`. |
| `apps/libreshare_app/lib/services/paths.dart:30-33` | `baseName(path)` | **ok** | Correctly extracts filename component using regex `[/\\]`. |
| `apps/libreshare_app/lib/services/app_dirs.dart:33` | `Directory(joinPath(downloads.path, 'LibreShare'))` | **needs Windows test** | Depends on `joinPath` implementation. |
| `apps/libreshare_app/lib/services/app_settings_store.dart:74` | `File get file => File(joinPath(directory.path, fileName));` | **needs Windows test** | Depends on `joinPath` implementation. |
| `apps/libreshare_app/lib/platform/autostart/autostart_linux.dart:42, 50` | `'$home/.config'`, `'$home/autostart/$fileName'` | **ok** | Linux-only implementation file. |
| `apps/libreshare_app/lib/platform/tray/tray_service_impl.dart:21-22` | `'assets/tray/tray_idle.png'`, `'assets/tray/tray_active.png'` | **ok** | Flutter asset bundle paths always use `/`. |

---

## 5. `HOME | XDG_*`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_cli/lib/ls_cli.dart:52` | `--identity-dir DIR ... ($LS_HOME ...)` | **ok** | CLI help string. |
| `packages/libreshare_cli/lib/ls_cli.dart:194` | `final home = env['LS_HOME'];` | **ok** | Explicit cross-platform override env variable. |
| `packages/libreshare_cli/lib/ls_cli.dart:201` | `final xdg = env['XDG_CONFIG_HOME'];` | **ok** | Only evaluated when `!Platform.isWindows`. |
| `packages/libreshare_cli/lib/ls_cli.dart:203` | `final h = env['HOME'] ?? '.';` | **ok** | Only evaluated when `!Platform.isWindows`. |
| `apps/libreshare_app/lib/platform/autostart/autostart_linux.dart:3, 20, 36, 37, 39, 41, 85` | `XDG_CONFIG_HOME`, `HOME` | **ok** | Linux-only autostart service (`LinuxAutostart`). |

---

## 6. `USERPROFILE | APPDATA`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_cli/lib/ls_cli.dart:198` | `final app = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';` | **ok** | Correct standard Windows user data directory discovery with fallback. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:13` | `live in the user profile (%APPDATA%)` | **ok** | Documentation comment explaining security model on Windows. |

---

## 7. `File.setLastModified`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:859` | `await f.target.setLastModified(modified);` | **needs Windows test** | On Windows, setting file mtime can fail if another process (Windows Search Indexer, Defender) holds an open handle. Handled safely via `try / on FileSystemException / on ArgumentError` as best-effort. |

---

## 8. `FileMode.append` plus `setPosition` (Known Windows Risk)

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:702` | `raf = await f.partial.open(mode: FileMode.append);` | **risk** | Opened with `FileMode.append` for receiving chunks. |
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:713` | `await raf.setPosition(range.start + received);` | **risk** | **CRITICAL WINDOWS BUG:** On Windows Win32 file systems, files opened with `O_APPEND` / `FILE_APPEND_DATA` (`FileMode.append`) ignore `setPosition` for writes and force all bytes to EOF. Multi-chunk resume or out-of-order chunk writes will corrupt the file. Must use `FileMode.writeOnly` or `FileMode.readWrite`. |
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1312` | `final raf = await partial.open(mode: FileMode.append);` | **ok** | Only used for `_syncFile` (`await raf.flush()`); no `setPosition` is called. |

---

## 9. `Link(`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:409` | `final resolved = Link(linkPath).resolveSymbolicLinksSync();` | **needs Windows test** | In Windows, symbolic links require Developer Mode or elevated privileges. NTFS directory junctions may behave differently with `FileSystemEntityType.link`. Exceptions are caught and return `null`. |

---

## 10. Reserved Windows File Names in `filename_sanitizer.dart`

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:45-51` | `_kReserved = {'CON', 'PRN', 'AUX', 'NUL', 'COM1'..'COM9', 'LPT1'..'LPT9', ...}` | **ok** | Complete set of reserved DOS devices, including `CONIN$`, `CONOUT$`, and Windows 10+ superscript digits `COM¹..³`, `LPT¹..³`. |
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:76-86` | `_isForbidden`: `< > : " / \ \| ? *` | **ok** | All forbidden Windows characters are stripped. |
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:114-125` | `_trimTrailingDotsAndSpaces` | **ok** | Trims trailing dots and spaces, which Windows Win32 APIs discard or reject. |
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:170-174` | `_isReservedName`: checks base name before first dot | **ok** | Correctly catches `aux.txt`, `con.tar.gz`. |
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:184` | `s = _fitToBytes('_$s', maxBytes);` | **ok** | Sanitizes reserved names by prefixing `_` (`CON` -> `_CON`). |
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:276, 286, 330` | `Directory.resolveSymbolicLinksSync()` | **risk** | On Windows, `resolveSymbolicLinksSync()` prepends `\\?\` prefix. Comparing paths with `p.isWithin(rootReal, resolved)` at line 281 can falsely fail due to `\\?\` prefix mismatch or drive letter case differences. |

---

## 11. Long Paths (> 260 Characters / MAX_PATH)

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:29-37` | `kMaxNameBytes = 255`, `kTargetNameMaxBytes = 239` | **risk** | Only constrains individual path segment length (255 bytes). Does not constrain the cumulative path length. Deep directory structures (`folder/sub/sub2/.../file.ext`) exceeding 260 characters will fail on Windows without the `\\?\` prefix or registry `LongPathsEnabled`. |
| `apps/libreshare_app/lib/platform/autostart/autostart_windows.dart:36, 57` | `static const int maxCommandLength = 260;` | **ok** | Explicitly validates command length against Windows registry `Run` key limits. |

---

## 12. Additional Critical Windows Risk: `File.rename` Overwrites

In Dart on Windows, `File.rename` uses Win32 `MoveFileW`. Unlike POSIX, `MoveFileW` fails with `ERROR_ALREADY_EXISTS` if the destination file already exists.
Multiple core components use the atomic write pattern (`write to tmp -> rename over target`) without deleting the destination first:

| File:Line | Code Context | Verdict | Analysis |
|---|---|---|---|
| `packages/libreshare_core/lib/src/transfer/resume_store.dart:211` | `await tmp.rename(target.path);` | **risk** | **CRITICAL:** Updates sidecar file (`.lspart.json`). On Windows, this will throw `FileSystemException` on the second chunk because the target sidecar file already exists. |
| `packages/libreshare_core/lib/src/storage/receive_settings_store.dart:90` | `await tmp.rename(file.path);` | **risk** | **CRITICAL:** Saving updated receive settings will throw `FileSystemException` on Windows once the settings file exists. |
| `packages/libreshare_core/lib/src/storage/file_secret_store.dart:99` | `await tmp.rename(target.path);` | **risk** | Overwriting an existing secret file will fail on Windows. |
| `apps/libreshare_app/lib/services/app_settings_store.dart:113` | `await tmp.rename(file.path);` | **risk** | Updating app settings in the Flutter app will fail on Windows once settings exist. |
| `packages/libreshare_core/lib/src/transfer/file_receiver.dart:909` | `await f.partial.rename(f.target.path);` | **needs Windows test** | Handled by fallback copy-then-delete at line 917 if partial is on another drive, but if target file already exists, rename throws on Windows. |

---

## 13. Native Windows Plugins / GUI Integration

| File | Subsystem | Verdict | Analysis |
|---|---|---|---|
| `apps/libreshare_app/lib/platform/autostart/registry_access_win32.dart` | Windows Registry (`win32_registry`) | **needs Windows test** | Self-documented as unverified on real Windows. Uses `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run`. |
| `apps/libreshare_app/lib/platform/tray/native_tray_driver.dart` | System Tray (`tray_manager`) | **needs Windows test** | Native Windows C++ Flutter plugin binding needs validation. |
| `apps/libreshare_app/lib/platform/window/native_window_backend.dart` | Window Manager (`window_manager`) | **needs Windows test** | Native window minimize/restore/close hook needs Windows validation. |
| `apps/libreshare_app/lib/platform/bonsoir_mdns_backend.dart` | mDNS (`bonsoir`) | **needs Windows test** | Bonsoir requires system mDNS / Bonjour service on Windows. |

---

## Summary of Actionable "Risk" Items for Windows Porting

1. **`file_receiver.dart:702, 713`**: Replace `FileMode.append` with `FileMode.writeOnly` or `FileMode.readWrite` so `setPosition` works on Windows.
2. **`resume_store.dart:211`, `receive_settings_store.dart:90`, `file_secret_store.dart:99`, `app_settings_store.dart:113`**: In atomic rename helpers, delete existing destination file or catch and replace on Windows before `rename()`.
3. **`paths.dart:22-27` (`parentDir`)**: Fix root drive handling (`C:\`) so it does not truncate to relative `C:`.
4. **`file_launcher.dart:26, 36`**: Quote arguments and replace forward slashes before invoking `explorer.exe /select,path` and `rundll32`.
5. **`filename_sanitizer.dart:281` (`isWithin`)**: Normalize Windows `\\?\` prefix and case insensitivity from `resolveSymbolicLinksSync()`.
6. **`file_receiver.dart:1418` (`_dfFreeBytes`)**: Add Windows disk space check via `GetDiskFreeSpaceEx` (or FFI/CLI) instead of returning `null`.
7. **Long paths**: Check total path length against 260 characters or use `\\?\` prefix when creating directories and files on Windows.
