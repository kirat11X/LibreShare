# R1c/R1d verifier report (stage 3, different agent from tester and coder)

Verdict: **SAFE TO APPLY** (no HIGH finding; the MEDIUM is a pre-existing behaviour the patch does not worsen; LOW items are optional hardening). Windows behaviour of the launcher and of `isPathWithin(windows: true)` on a real Windows file system is UNVERIFIED (list at the end).

Work area: fresh clone `.toolchain/scratch/e5-r1cd-verify/clone/` (rsync of the real tree at 14:12), patch applied with `patch -p1` (rc 0), the three tester files copied in. Mutation copy: `.../mut/`. Logs: `.toolchain/scratch/e5-r1cd-verify/logs/*.log`, summary `gates.summary`, `mut.results`, `mutapp.results`.

## Process disclosure (my mistake, repaired)
At 14:11:35 an unquoted `cd` failed (path with spaces) and for about 15 s `dart pub get --offline` (rc 0) and `patch -p1 < patch.diff` (rc 0) ran in the REAL tree. At 14:11:50 I reverted with `patch -R -p1` (rc 0, no .orig/.rej left). Check: `patch -p1 --dry-run < patch.diff` on the real tree is rc 0 again (14:18 and 21:18), i.e. the three lib files are back at their pre-patch content. Their mtimes changed; `pubspec.lock` mtime unchanged. Nothing else in the real tree was touched. Please re-run your usual gate before applying anything.

## Gate table (each run alone under `flock -o /tmp/libreshare-heavy.lock`; flutter also under the flutter lock)
| Gate | Result | rc | Time (date) |
|---|---|---|---|
| core `path_within_windows_test.dart` x3 | +18 each, All passed | 0,0,0 | 14:38, 15:16, 15:16 |
| app `e5_paths_windows_test.dart` x3 | +26 each | 0,0,0 | 15:46 |
| app `e5_file_launcher_command_test.dart` x3 | +30 each | 0,0,0 | 15:46 |
| existing sanitizer set (`path_traversal_secure_test`, `sanitizer_fuzz_test`, `filename_sanitizer_test`; the grep list) | +114 All passed | 0 | 15:16 |
| core `dart test -j 1` (full) | +2639 ~1 (= 2607 baseline + 18 + 14 verifier tests); 1 skipped | 0 | 20:49 |
| cli `dart test -j 1` | +76 -1; the one red is `loopback_smoke_secure_test` (known, unrelated). No other failure | 1 (expected) | 20:58 |
| app `flutter test --no-pub --concurrency=2 --timeout 60s` | +538 (= 478 + 56 + 4 verifier) All passed | 0 | 21:01 |
| `dart analyze --fatal-infos` at clone root | No issues (first run found 1 lint in MY verifier file, fixed, re-run clean) | 0 | 20:55 |
| `dart format --output=none --set-exit-if-changed .` at clone root | rc 1 only because of `docs/plans/e-proposals/r4c/contacts_greeting_retry_test.dart` (another agent's proposal, not in this patch) | 1 | 20:46 |
| same on `packages apps tools` | clean | 0 | 20:55 |
| `grep -rn "package:flutter\|dart:ui" packages/libreshare_core/lib` | no match | 1 (expected) | 21:01 |
| verifier tests: core `path_within_verifier_test.dart` | +14 | 0 | 15:03 |
| verifier tests: app `e5_r1cd_verifier_test.dart` | +4 | 0 | 15:46 |

Coder's note "CLI +75": I measured +76 -1 (the red one is the known smoke test). Not a regression.

## 1. isPathWithin analysis
Rules (code read line by line): `windows ?? Platform.isWindows` is the only decision. A Linux/Android/macOS host can reach the Windows branch only if a caller passes `windows: true` (no caller does; `assertInsideDir` and `resolveTarget` pass nothing). Windows branch: `/`->`\`, `\\?\UNC\`->`\\`, `\\?\`->"", then `p.windows.isWithin` (case-insensitive, separator-insensitive, normalises `.`/`..`). Equal path is NOT within (same as `p.isWithin`); a candidate with a trailing separator equal to the root is not within; common-prefix sibling `C:\ab` vs `C:\a` is not within.

Differential (`verifier-tests/path_within_verifier_test.dart`, seed fixed): 250,000 random pairs (segments a, b, c, `..`, `.`, empty, space, unicode, `ä/Ä/A`, `a\b`, `...`, `?`, `C:`, `\\?\`, trailing slashes, double slashes), `windows` unset AND `false` vs `p.isWithin`:
- both-absolute or both-relative without a leading `..` : 171,386 pairs (71,341 true): **0 differences**.
- 78,614 cwd-dependent pairs (absolute vs relative, or a relative path normalising to a leading `..`): 6,646 differences, **0 of them where the new code is more permissive** (new says false where `p.isWithin` said true). Cause: the new code calls `p.posix.isWithin`, whose context has `current = '.'`, whereas `p.isWithin` uses the process cwd (`p.isWithin('/', 'a')` is true, `p.posix.isWithin('/', 'a')` is false). Production inputs are always absolute (`root.absolute`, `resolveSymbolicLinksSync`, `p.join(curReal, ...)`), so no behaviour change there. See finding L1.

Windows soundness (same file, independent reference model of documented Win32 resolution: prefix strip incl. case-insensitive `\\?\unc\`, `\\.\`, separators, `.`/`..`, case folding): 300,000 pairs, 123,997 "within", **0 cases where windows:true says within and the model says outside**.

Probe results (`probe.dart`, `probe.out`; `windows: true`, root `C:\a` unless noted):
- within: `C:\a\b`, `c:\A\B`, `C:/a/b`, `C:\a\..\a\b`, `\\?\C:\a\b`, `\\?\c:\a` vs `C:\A\b`, `\\?\UNC\h\s` vs `\\h\s\x` (both directions), `//?/C:/a/b`, `\\?\UNC` mixed case root vs `\\H\S\D\x`, ADS `C:\a\f.txt:s` and `:$DATA` (same directory on Windows: correct), trailing dot `C:\a\b.` (Windows strips it: C:\a\b, correct), names `CON`, `NUL.txt` (inside the folder as names; the sanitizer prefixes `_`).
- outside (correct): equal root, `C:\a\`, `C:\ab`, `C:\ab\x`, `C:\a\..\b`, `C:\a\b\..\..\x`, `\\?\C:\a\..\b`, `//?/C:/a/../b`, `D:\a\b`, drive-relative `C:x` and `C:a\b`, `\a\b`, `\\a\b`, `a\b`, other UNC share `\\h\s2\d`, share-prefix sibling `\\h\s\dd`, `\\.\CON`, `C:\` vs `C:\` (equal), `\\?\UNC\h\s` vs itself.
- root equal to candidate: "within" is FALSE (strict), same as `p.isWithin`.
- Conservative (false negatives, safe direction): lower-case `\\?\unc\...` prefix, `\\?\\C:\`, `\\.\C:\a\b` vs `C:\a\b` are not recognised, so they come out "outside" (see L2).

Sanitizer context: `sanitizeFileName` removes `:`, trailing dots/spaces and maps `..`/`...`/`.. ` to `unnamed`; `sanitizeRelativePath` throws on `..` segments (probe2.dart). So the exotic names above cannot reach `isPathWithin`; it is the second layer after the sanitizer.

## 2. Launcher analysis
Exact argv (from `e5_r1cd_verifier_test.dart`, printed in `logs/app_verifier.log`):
| platform | open | show in folder |
|---|---|---|
| windows | `rundll32 ['url.dll,FileProtocolHandler', 'C:\Users\Me\a b.txt']` | `explorer.exe ['/select,', 'C:\Users\Me\a b.txt']` |
| linux | `xdg-open ['/h/a b.txt']` | `xdg-open ['/h']` |
| macos | `open ['/h/a b.txt']` | `open ['-R', '/h/a b.txt']` |
| android, ios, fuchsia | null | null |

- The path is always ONE list element (20,000 random names x 3 platforms checked: only literals `url.dll,FileProtocolHandler`, `/select,`, `-R` appear besides the path; never more than 2 elements; executable never cmd/sh/bash/powershell). `Process.start` is called with an argv list and no `runInShell`, so no shell and no `cmd /c`.
- Names starting with `-` or `/`: on Linux, `xdg-open --version` prints its version and exits (checked), so a FIRST argument starting with `-` IS parsed as an option. Not reachable: the path passed is `downloadDir.absolute` + sanitized name (`resolveTarget`), so it starts with `/` (Linux) or a drive/UNC root (Windows), and the sanitizer strips `/ \ : ...` from names. (Not verified end to end in a running app.) UNVERIFIED on Windows: how `explorer.exe /select,` and `rundll32 ...FileProtocolHandler` treat a quoted path containing `,`, `%`, `&`, `#`, `'`, `"`; the contract (path in its own argv element, Dart quotes it) is the documented form, but it needs the manual check at step 8 of `docs/test-reports/windows-manual.md`.
- Before the patch: Windows show was `['/select,$path']` (fused into one quoted argument, which Explorer does not parse as `/select,` + path) and `/` was not converted. After: separate element and backslashes. Open on Windows/Linux/macOS is the same command as before, except `/` -> `\` on Windows.

## 3. Mutation table (one at a time in `mut/`, restore + `diff -r` of both lib trees rc 0 each time)
Tester = the three delivered files; Verifier = my two added files.
| # | Mutation | Result |
|---|---|---|
| a | windows branch case-sensitive | RED: tester `case-insensitive: drive letter and folders` |
| b | no `..` normalisation | RED: tester `prefix-strict`, `dotdot-escape`; verifier soundness + probes |
| c | no `\\?\` stripping | RED: tester `prefix-mixed` x2, `prefix-unc` |
| d | no separator unification | **SURVIVED the tester set** (p.windows treats `/` itself). RED by verifier `forward-slash verbatim forms` (`//?/C:/a/b`) |
| e | common-prefix sibling "within" | RED: tester `prefix-strict`, `prefix-sibling`, `dotdot-escape` |
| f | `windows ?? true` default | **SURVIVED the tester set** (`default-platform` is vacuous: `/a` vs `/a/b` is true in both branches). RED by verifier differential + `default (null) on a POSIX host` |
| g | `assertInsideDir` back to `p.isWithin` | **SURVIVED the tester set** (behaviour-neutral on Linux). RED by verifier source guard |
| h | `resolveTarget` site 1 back | SURVIVED tester; RED by verifier source guard |
| i | `resolveTarget` site 2 back | SURVIVED tester; RED by verifier source guard |
| j | parentDir truncates `C:\` | RED: `drive-root` (8 tests) |
| k | UNC share root truncated | RED: `unc-and-extended-prefix: parentDir(\\host\share)` (1 test) |
| l1 | show: path fused into `/select,` | RED: `win-select-not-fused` (12) |
| l2 | open: path fused into option | RED: `win-open-single-arg` (12) |
| m1 | open: `/` not converted | RED: `win-forward-slashes` x2 + verifier argv test |
| m2 | show: `/` not converted | RED: `win-forward-slashes` + verifier argv test |
| n1, n2 | android returns a command | RED: `no-launcher-on-android` |
Survivors after adding the verifier tests: none. Note the g/h/i guard is a source-text test (necessary because the swap cannot be observed on Linux); it fails if the call sites are renamed, which is the intended tripwire.

## Findings
**HIGH: none.** No input found where `windows: true` says within and the file would land outside the root (0 / 300,000 against an independent model; hand probes above).

**MEDIUM M1 (pre-existing, unchanged by the patch): Open runs executables.** `rundll32 url.dll,FileProtocolHandler <received file>` is ShellExecute "open": a received `.exe/.bat/.cmd/.scr/.lnk/.hta/.js/.vbs/.msi/.jar` is executed; on Linux `xdg-open` and macOS `open` (`.command`, `.terminal`, `.app` inside archives are opened by their handler) similarly follow the file association. The "Open" button (`transfer_screen.dart:548`) has no confirmation, and the receiver writes no Mark-of-the-Web (`Zone.Identifier`), so SmartScreen/Office Protected View do not apply. The patch keeps the same command, so risk is equal to before. Suggested fix (separate sub-item): a confirmation dialog for a list of executable/script extensions (and "Show in folder" as the default action for them); on Windows also write a `Zone.Identifier` ADS (`ZoneId=3`) on received files.

**LOW L1: `windows: false`/null on POSIX is `p.posix.isWithin`, not `p.isWithin`.** Differs from the test-file comment ("exactly p.isWithin") for absolute-vs-relative and leading-`..` inputs (p.posix has `current='.'`); only ever stricter. Production inputs are absolute. Suggested fix: `if (windows == null && !Platform.isWindows) return p.isWithin(root, candidate); if (windows == false) return p.posix.isWithin(root, candidate);` or document the deviation.

**LOW L2: prefix matching is case-sensitive/limited.** `\\?\unc\`, `\\?\\`, `\\.\` forms are not stripped, giving false "outside" (safe, but could reject a legitimate write if the OS ever returned them; `resolveSymbolicLinksSync` returns upper-case `\\?\UNC\`). Suggested fix: compare the prefix case-insensitively (`t.toUpperCase().startsWith(r'\\?\UNC\')`) and also strip `\\.\`.

**LOW L3: Win32 trimming quirks are not modelled** (`C:\a\.. \x`, `C:\a\...\x` are "within" for `p.windows`; real Windows resolution of such segments is UNVERIFIED). Unreachable today because the sanitizer maps these names to `unnamed` and throws on `..` segments; same as the pre-patch `p.isWithin` on Windows.

**LOW L4: `openCommand` does not assert an absolute path.** A leading `-` would be parsed as an option by `xdg-open` (shown with `--version`). Unreachable today (absolute paths). Suggested fix: in `openCommand`/`showInFolderCommand` prefix a relative path with `./` or return null.

**LOW L5: test gaps in the delivered tester set** (mutations d, f, g, h, i survived). Suggested: adopt `verifier-tests/path_within_verifier_test.dart` (14 tests, runs ~2 s) and optionally `e5_r1cd_verifier_test.dart` (4 tests). Neither edits any tester file.

**LOW L6:** root `dart format --set-exit-if-changed .` is red because of `docs/plans/e-proposals/r4c/contacts_greeting_retry_test.dart` (another proposal), not this patch.

## Could NOT be verified without a Windows host
1. That `Process.start('explorer.exe', ['/select,', path])` selects the file for paths with spaces, `,`, `&`, `#`, `%`, `'`, non-ASCII, UNC (Dart's Windows argv quoting + Explorer parsing).
2. That `rundll32 url.dll,FileProtocolHandler <quoted path>` opens the same set of names, and its handling of a path ending in a backslash or containing `"`.
3. That `Directory.resolveSymbolicLinksSync()` really returns `\\?\C:\...` for one side (the case R1d targets) and which exact forms (case of `UNC`, `\\?\Volume{...}`).
4. Real Win32 normalisation of trailing dots/spaces, `.. ` segments, ADS and device names against the `p.windows` result (L3); case-insensitivity on case-sensitive directories (WSL flag).
5. The wiring of `assertInsideDir`/`resolveTarget` on a real Windows receive (only a source-text guard exists on Linux).

## Files
- `docs/plans/e-proposals/r1cd/verifier-tests/`: `path_within_verifier_test.dart` (copy to `packages/libreshare_core/test/unit/`), `e5_r1cd_verifier_test.dart` (copy to `apps/libreshare_app/test/`), `probe.dart`, `probe2.dart`, `probe3.dart` (throwaway probes, run with `dart run` inside the core package).
- Scripts/logs: `.toolchain/scratch/e5-r1cd-verify/` (`grp.sh`, `mutcore.sh`, `mutapp.sh`, `mutate.py`, `logs/`).
