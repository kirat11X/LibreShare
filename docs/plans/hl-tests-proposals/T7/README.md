# Card T7: Windows Path & Semantics Verification on Linux

## Destination Path
When applied by the orchestrator:
- Copy `windows_semantics_test.dart` to `packages/libreshare_core/test/unit/windows_semantics_test.dart`.

## Scope & Specifications Tested
- **DOS & 8.3 Reserved Names:** Case-insensitive sanitization of `CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`, and Windows 10 superscripts `COM¹`..`COM³`, `LPT¹`..`LPT³` with/without arbitrary extensions (`CON.txt`, `aux.tar.gz`), ensuring safe `_` prefixing while preserving embedded substrings (`CONSULT.txt`).
- **Trailing Dots and Spaces:** Stripping trailing dots/spaces (`foo.`, `foo...   `) to prevent Win32 API truncation while safely handling empty/dot-only fallbacks to `unnamed`.
- **Drive Letters & Alternate Data Streams:** Neutralizing ADS colons (`stream:bar:$DATA` -> `streambar$DATA`) and stripping/re-rooting drive letters (`C:\Windows\System32` -> `['C', 'Windows', 'System32']`).
- **Slash vs Backslash Cross-Platform Equivalence:** Enforcing that `a\b\c` arriving from Windows manifests yields identical relative path segments on Linux as `a/b/c`.
- **Long Paths (> 260 MAX_PATH) & Extended-Length Prefixes:** Testing `isPathWithin` with `windows: true` across 300+ character paths with and without `\\?\` prefix.
- **Atomic Replace Semantics Simulation:** Verifying Windows-style staged file replacements, handling locked handles, and ensuring non-destructive atomic rename.
- **Windows Launcher Quoting:** Testing `quoteWindowsArg` compliance with `CommandLineToArgvW` and `cmd.exe` metacharacters (`&`, `^`, `%`, `"`).
