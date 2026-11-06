# R1c/R1d tests-plan (tester, 2026-11-06)

Clone: `.toolchain/scratch/e5-r1cd/clone`. Three NEW test files, no lib file or existing test touched. All are pure (no Windows, no Process).

| File | Cmd (cwd) |
|---|---|
| `apps/libreshare_app/test/e5_paths_windows_test.dart` | `flock -o /tmp/libreshare-heavy.lock flutter test --no-pub --concurrency=1 test/e5_paths_windows_test.dart` (clone/apps/libreshare_app) |
| `apps/libreshare_app/test/e5_file_launcher_command_test.dart` | same, other file |
| `packages/libreshare_core/test/unit/path_within_windows_test.dart` | `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/path_within_windows_test.dart` (clone/packages/libreshare_core) |

## R1c parentDir (`lib/services/paths.dart`, API unchanged) - e5_paths_windows_test.dart, 26 tests
RED, rc=1, `+18 -8` (2026-11-06 11:52). The 8 real failures: `parentDir(C:\a)` gives `C:` (expected `C:\`), `C:\a.txt`, `C:/a`, `C:\` and `C:/`, `\\?\C:\a`, `\\?\C:\`, and `\\host\share` (share root must map to itself). Guards: `drive-root`, `unc-and-extended-prefix`. Already green (regression, keep): `\\host\share\x`, `\\host\share\x\y.txt`, `\\?\C:\a\b`, `\\?\UNC\host\share\x[\y]`, `C:\a\b[\c.txt]`, every POSIX case (guard `posix-unchanged`). Note: `\\host\share\x` already works today.
(An earlier run at 10:38 was killed by the Claude restart during the cnativeapi native-assets hook; the 11:52 run is the valid one.)

## R1c launcher quoting - e5_file_launcher_command_test.dart, 30 tests
SEAM NEEDED in `lib/services/file_launcher.dart` (orchestrator-visible API choice):
```dart
class LaunchCommand { const LaunchCommand(this.executable, this.arguments); final String executable; final List<String> arguments; }
LaunchCommand? openCommand(String path, {required String platform});         // platform = Platform.operatingSystem
LaunchCommand? showInFolderCommand(String path, {required String platform}); // null on android/ios/fuchsia
```
`SystemFileLauncher` must call these with `Platform.operatingSystem` and start the result. Windows contract (UNVERIFIED on a real Windows host, orchestrator to confirm): `/` becomes `\`; the path is one list element (spaces, `#`, `&`, `,`, `"`, `'`, `%`, non-ASCII `café über 日本語`, UNC `\\host\share\dir with space\f.bin` untouched); open = `rundll32 ['url.dll,FileProtocolHandler', path]`; show = `explorer.exe ['/select,', path]` (documented `/select, <path>` form, path separate so Dart quotes it). Linux/macOS regression: `xdg-open path`, `xdg-open parentDir(path)`, `open path`, `open -R path`; a backslash in a POSIX name is NOT converted; android/ios/fuchsia return null. Guards: `win-open-single-arg`, `win-select-not-fused`, `win-forward-slashes`, `linux-*`, `macos-*`, `posix-slashes-untouched`, `no-launcher-on-*`.
RED, rc=1 (2026-11-06 11:51): the test does not compile, `Method not found: 'openCommand'` / `'showInFolderCommand'` (the seam does not exist).

## R1d isPathWithin - path_within_windows_test.dart, 18 tests
SEAM NEEDED in `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart` (already exported by the barrel): `bool isPathWithin(String root, String candidate, {bool? windows})`, strict containment, `windows == null` means `Platform.isWindows`. With `windows: true`: `\\?\C:\x` == `C:\x`, `\\?\UNC\h\s\x` == `\\h\s\x`, `/` and `\` both separators, case-insensitive, `..` normalised (no escape), equal path is NOT within; `windows: false` is exactly `p.isWithin` (case-sensitive, `\` is a name char). `assertInsideDir` (line ~281) and `resolveTarget` (line ~360) must call it instead of `p.isWithin`. Guards: `prefix-mixed|both|unc|strict|sibling|other-drive|unc-other-share`, `case-insensitive`, `slash-equivalence`, `dotdot-escape|inside`, `posix-*`, `default-platform`.
RED, rc=1: does not compile, `Method not found: 'isPathWithin'`.
Satisfiability check (throwaway copy `.toolchain/scratch/e5-r1b/stubcheck`, not a deliverable) with a 12-line reference `isPathWithin` using `p.windows` after prefix/slash/case normalisation: `+18: All tests passed!` rc=0 (2026-11-06 11:56:29). That run caught one wrong expectation of mine (`/a\b` is a sibling of `/a` on POSIX), fixed before delivery.
Not covered by tests: that assertInsideDir/resolveTarget really use `isPathWithin` on Windows (needs Windows); the verifier should mutate by reverting the two call sites and confirm existing `filename_sanitizer`/`assert_inside_dir` suites still pass (they are Linux tests, so the swap must be behaviour-neutral there).

## Orchestrator decision on the launcher contract (2026-11-06 12:14:55 by `date`)
Accepted as the contract the coder implements: `LaunchCommand(executable, arguments)`, `openCommand` / `showInFolderCommand` (null for android/ios/fuchsia); Windows open = `rundll32 ['url.dll,FileProtocolHandler', path]`, show-in-folder = `explorer.exe ['/select,', path]`, `/` becomes `\`, the path stays ONE argument (no shell). **Unverified on a real Windows host**: it stays marked "unverified" in the report until a Windows run (Process.run on Windows quotes arguments with spaces itself; `explorer /select,` followed by a separate path argument is the documented-in-practice form but must be checked by hand).
