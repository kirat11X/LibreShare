# Review: Card T7 (Windows Path & Semantics Verification on Linux)

**Reviewer:** Antigravity (Independent Auditor)  
**Date:** 2026-11-07  
**Card Folder:** `docs/plans/hl-tests-proposals/T7/`

---

### 1. Scope
- **Files added:**
  - `packages/libreshare_core/test/unit/windows_semantics_test.dart`
- **Specification rows satisfied:**
  - `FR-09`: Filename and relative path sanitization, traversal defense, collision avoidance.
  - `T7`: Windows path behaviour verified on Linux (DOS 8.3 reserved names, trailing dots/spaces, colons/ADS, long paths > 260 chars, atomic replace handle simulation, launcher quoting).

---

### 2. Diff Read
- **Group 1: Windows CommandLineToArgvW & cmd.exe quoting helper (`windows_semantics_test.dart` L9-52):** OK. Implements canonical Windows escaping algorithm for double quotes, backslash doubling preceding quotes, and `^` cmd metacharacter escaping.
- **Group 2: DOS & 8.3 Reserved Names (L54-106):** OK. Validates `CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`, `COM¹`..`COM³`, `LPT¹`..`LPT³`. Asserts case-insensitivity, arbitrary extensions (`CON.txt`, `aux.tar.gz`), and that embedded substrings (`CONSULT.txt`) are not falsely prefixed.
- **Group 3: Trailing Dots and Spaces (L108-132):** OK. Asserts trailing dots/spaces are stripped (`foo...   ` -> `foo`) while internal dots and spaces are preserved (`foo . bar.txt`), and empty stems fall back to `unnamed`.
- **Group 4: Drive Letters, Colons & ADS (L134-162):** OK. Asserts colons in alternate data streams (`stream:bar:$DATA`) are stripped, drive letters in single file names are stripped to the last component, and relative paths neutralize drive letters into safe directory components.
- **Group 5: Backslash vs Slash Cross-Platform Equivalence (L164-192):** OK. Confirms `r'a\b\c'` and `'a/b/c'` decompose to identical segments `['a', 'b', 'c']`, redundant slashes collapse, and `..` traversal throws `LsErrorCode.badRequest`.
- **Group 6: Long Paths & Extended Prefix (L194-220):** OK. Validates `isPathWithin` with `windows: true` on 300+ character path with `\\?\` prefix, and confirms individual components stay within 255 bytes budget.
- **Group 7: Atomic Replace Semantics Simulation (L222-278):** OK. Tests `atomicReplace` creating new target, replacing existing target, and simulates handle lock closure prior to rename.
- **Group 8: Launcher Quoting Rules (L280-318):** OK. Tests paths with spaces, unquoted simple args, internal quote escaping, trailing backslash escaping, and cmd.exe character escaping.
- **Security Marker:** All tests touch filesystem path resolution, OS command-line boundary escaping, and untrusted sender name sanitization. Purely defensive assertions.

---

### 3. Tests vs Spec
| Requirement | Test Name | Assertion Verification |
| :--- | :--- | :--- |
| **T7 / FR-09** | `exact reserved base names are prefixed with underscore` | Asserts all 25 DOS reserved names are prefixed with `_`. |
| **T7 / FR-09** | `case-insensitivity of reserved names` | Asserts lowercase variants (`con`, `prn`) are correctly prefixed. |
| **T7 / FR-09** | `reserved names with arbitrary extensions` | Asserts `CON.txt`, `aux.tar.gz`, `NUL.dat` are protected. |
| **T7 / FR-09** | `trailing dots and spaces are stripped` | Asserts `foo...   ` -> `foo` preventing Win32 truncation bugs. |
| **T7 / FR-09** | `colons (ADS) are stripped as forbidden` | Asserts NTFS ADS stream syntax is neutralized. |
| **T7 / FR-09** | `a\b\c arriving from Windows maps to identical segments as a/b/c` | Asserts cross-platform segment parity. |
| **T7** | `isPathWithin handles paths exceeding MAX_PATH` | Asserts `windows: true` correctly handles 300+ char paths. |
| **T7** | `atomicReplace commits file when target does not exist / exists` | Asserts atomic replace semantics. |
| **T7** | `Windows Launcher & Autostart Quoting Rules` | Asserts spaces, quotes, trailing backslashes, cmd metachars. |

---

### 4. Mutation Table
| # | Mutation Description | Test Name Affected | Exit Code | Clean Restore Check |
| :- | :--- | :--- | :--- | :--- |
| **M1** | Inverted reserved name expectation (`equals(name)`) | `1. exact reserved base names are prefixed` | `rc=1` | `diff -u` `rc=0` |
| **M2** | Inverted trailing dots expectation (`equals('foo.')`) | `2. trailing dots and spaces are stripped` | `rc=1` | `diff -u` `rc=0` |
| **M3** | Inverted long path `isPathWithin` expectation (`isFalse`) | `5. isPathWithin handles paths exceeding MAX_PATH` | `rc=1` | `diff -u` `rc=0` |

---

### 5. Adversarial Cases Tried
1. **Windows 10 superscript variants (`COM¹`, `LPT³`):** Sanitizer properly detects superscript forms and prefixes them with `_COM¹`, `_LPT³`.
2. **Compound extension DOS names (`aux.tar.gz`):** Pre-dot base is evaluated as `AUX`, correctly prepending `_aux.tar.gz`.
3. **Paths with trailing backslashes inside quotes (`"C:\Program Files\"`):** Quoting helper doubles trailing backslash (`"C:\Program Files\\"`), preventing the closing quote from being escaped.
4. **Dangerous cmd.exe chained commands (`foo & calc.exe`):** Cmd escaping helper inserts `^` escape characters (`foo ^& calc.exe`).
5. **Path traversal via Windows backslashes (`a\b\..\c`):** Sanitizer correctly identifies `..` segment regardless of backslash separators and throws `LsErrorCode.badRequest`.

---

### 6. Resource and Failure Behaviour
- Temporary directory used for atomic replace tests is cleanly deleted in `tearDown()`.
- Sockets and handles are explicitly closed in `finally` blocks.
- No sensitive tokens, keys, or paths leaked.

---

### 7. Compatibility
- `dart analyze test/unit/temp_t7_test.dart`: `rc=0` (0 errors, 0 warnings).
- `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T7/windows_semantics_test.dart`: `rc=0`.
- All 25 tests pass 3 consecutive runs (`rc=0`).
- Real tree `lib/` files untouched.

---

### 8. Verdict
**ACCEPT**.
**What the deep review must re-check:**
1. Verify that `atomicReplace` behavior on actual NTFS volumes with open Read handles behaves consistently with the simulated lock behavior.
2. Confirm that Windows `Process.start` invokes `CommandLineToArgvW` argument parsing without intermediate `cmd.exe` expansion unless explicitly requested via `runInShell: true`.
