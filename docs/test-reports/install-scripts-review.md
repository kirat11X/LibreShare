# Static Review of LibreShare Install Scripts

**Date:** 2026-11-05  
**Auditor:** Card A7 Auditor  
**Scope:** `deploy/install.ps1`, `deploy/install.sh`, `tools/*.sh`, `tools/docker/*.sh`, `deploy/docker/entrypoint.sh`  
**Purpose:** Static analysis and line-by-line review of install and helper scripts, specifically auditing `deploy/install.ps1` against production Windows PowerShell standards since `pwsh` is not installed in this environment.

---

## 1. Shell Script Syntax Check (Step 1)

Command executed:
```bash
bash -n deploy/install.sh tools/*.sh tools/docker/*.sh deploy/docker/entrypoint.sh
```
Exit code: **`rc=0`**

### Files Checked:
- `deploy/install.sh`
- `tools/android_emulator_smoke.sh`
- `tools/env.sh`
- `tools/loopback_smoke.sh`
- `tools/package_prototype.sh`
- `tools/docker/carol.sh`
- `tools/docker/e2e.sh`
- `tools/docker/run_local.sh`
- `deploy/docker/entrypoint.sh`

**Result:** All 9 shell scripts passed syntax parsing with zero errors.

---

## 2. Checklist for `deploy/install.ps1` (Step 2)

| # | Checklist Item | Status | Line Numbers | Summary Analysis |
|---|---|---|---|---|
| 1 | `Set-StrictMode` / `$ErrorActionPreference` | **FAIL** | Line 53 | `Set-StrictMode` is never configured. `$ErrorActionPreference` is set to `'Continue'`, allowing filesystem cmdlet failures (`New-Item`, `Remove-Item`) to proceed silently without halting. |
| 2 | Every external command's exit code checked (`$LASTEXITCODE`) | **PARTIAL** | Lines 79–83, 95, 103, 109, 121, 133, 233, 351, 436, 439, 467, 469 | Most `docker` invocations capture `$LASTEXITCODE` via `$script:LastCode`. However, Line 469 (`docker volume rm`) fails to check `$script:LastCode` before reporting success. Line 233 (`docker logs`) also ignores exit code. |
| 3 | Paths with spaces quoted | **PASS** | Lines 91, 144, 162, 168, 251, 258, 270, 335, 411, 443, 457, 475, 483 | Cmdlets use `-LiteralPath`. `Write-EnvMap` quotes values containing spaces for `.env`. PowerShell array splatting (`@composeArgs`) automatically quotes elements with spaces when invoking `docker.exe`. |
| 4 | `Join-Path` used | **PASS** | Lines 56, 57, 270, 305, 341 | Paths are joined using `Join-Path` rather than manual string concatenation with `\`. |
| 5 | No Linux-only commands | **PASS** | Throughout | No calls to `grep`, `sed`, `awk`, `cat`, `rm`, `ls`, `uname`, `which`, `chmod`, `sudo`, `curl`, `wget`, `nc`, or `bash`. Uses built-in PS cmdlets, Windows NetTCPIP/NetSecurity modules, and .NET APIs. |
| 6 | Docker Desktop in Linux-container mode check | **PASS** | Lines 120–131 | Queries `{{.OSType}}` via `docker info`. If `$os -ne 'linux'`, halts with an error explaining how to switch to Linux containers via the Docker Desktop tray. |
| 7 | Firewall commands printed but never run | **PASS** | Lines 220–226, 477 | `New-NetFirewallRule` and `Remove-NetFirewallRule` are only printed as guidance in `Write-Host`. The script only reads rules via `Get-NetFirewallRule` (line 210). |
| 8 | Uninstall only deletes data folder after typing `delete` and marker exists | **PARTIAL** | Lines 262–271, 446–454, 456–462 | Marker `.libreshare-data` is strictly verified (`Test-SafeToDelete`, line 270). If user files exist, prompt requires exact `'delete'`. However, if data folder has 0 user files, line 447 bypasses the prompt and sets `$delete = $true` automatically. Additionally, line 457 does not verify `Remove-Item` succeeded. |
| 9 | No secrets printed | **PASS** | Lines 13, 232–246, 283–288 | No passwords, tokens, PINs, or private keys exist or are logged. `Get-PublicLink` strips `&id=...` to avoid stale ephemeral ID persistence. |
| 10 | Works in Windows PowerShell 5.1 (no `??`, no `&&`/`||`, no ternary) | **PASS** | Lines 1–493 | Verified zero occurrences of PowerShell 7+ syntax: no `??`, no `??=`, no `&&`/`||` pipeline chains, and no `? :` ternary expressions. Uses PS 5.1 compatible .NET types and cmdlets. |

---

## 3. Findings by Severity (Step 3)

### High Severity
*None.* The script safely isolates state, verifies safe deletion boundaries before removing files, and checks Docker availability.

---

### Medium Severity

#### Finding 1: Unchecked exit code on volume removal during uninstall
- **File:** `deploy/install.ps1`
- **Line Number:** 469
- **Code:**
  ```powershell
  $null = Get-DockerText -DockerArgs @('volume', 'rm', $configVolume)
  Write-Host "Removed state volume $configVolume"
  ```
- **Issue:** Unlike line 439 where `$script:LastCode` is checked after `docker image rm`, line 469 unconditionally prints `"Removed state volume $configVolume"`. If the volume is currently referenced by another container or Docker fails, `$script:LastCode -ne 0` is ignored and the script falsely informs the user that the volume was removed.
- **Recommended Fix:**
  ```powershell
  $null = Get-DockerText -DockerArgs @('volume', 'rm', $configVolume)
  if ($script:LastCode -eq 0) {
      Write-Host "Removed state volume $configVolume"
  } else {
      Write-Warn "could not remove state volume $configVolume (still in use?)"
  }
  ```

#### Finding 2: Missing `Set-StrictMode` and relaxed `$ErrorActionPreference` causes silent filesystem failures
- **File:** `deploy/install.ps1`
- **Line Numbers:** 53, 336, 341, 457–458
- **Code:**
  ```powershell
  $ErrorActionPreference = 'Continue'
  ...
  $null = New-Item -ItemType Directory -Path $data -Force
  ...
  Remove-Item -LiteralPath $data -Recurse -Force
  Write-Host "Deleted $data"
  ```
- **Issue:**
  1. `Set-StrictMode -Version Latest` is omitted, meaning references to uninitialized variables or missing properties will evaluate to `$null` rather than throwing errors.
  2. With `$ErrorActionPreference = 'Continue'`, if `New-Item` fails on lines 336 or 341 due to permissions or invalid drive letters, execution continues into `Invoke-Compose`.
  3. On uninstall (line 457), Windows file locking frequently prevents directory deletion. If `Remove-Item` fails, line 458 still prints `"Deleted $data"`, and execution continues to volume removal with `$delete = $true`.
- **Recommended Fix:**
  Add `Set-StrictMode -Version 2.0` (or `Latest`). Wrap directory creation and deletion in `try { ... } catch` blocks with `-ErrorAction Stop`, or verify `Test-Path` before declaring success:
  ```powershell
  try {
      Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction Stop
      Write-Host "Deleted $data"
  } catch {
      Write-Warn "could not fully delete $data: $_"
      $delete = $false
  }
  ```

---

### Low / Informational Findings

#### Finding 3: Empty received folder bypasses the `delete` prompt on uninstall
- **File:** `deploy/install.ps1`
- **Line Numbers:** 446–447
- **Code:**
  ```powershell
  } elseif (-not (Test-HasContent $data)) {
      $delete = $true   # nothing but our marker: nothing to lose
  }
  ```
- **Issue:** If the user has received no files (or only `.libreshare-data`), uninstall deletes the folder immediately without asking the user to type `'delete'`. While this matches `deploy/install.sh` line 450, it is an automated deletion without interactive confirmation.

#### Finding 4: Substring prefix check in `Test-SafeToDelete` matches non-ancestor directory names
- **File:** `deploy/install.ps1`
- **Line Number:** 269
- **Code:**
  ```powershell
  if ($RepoRoot.StartsWith($full, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  ```
- **Issue:** If `$data` is `C:\code\Lib` and `$RepoRoot` is `C:\code\LibreShare`, `$RepoRoot.StartsWith($full)` evaluates to `$true` despite `C:\code\Lib` not being a parent directory of `$RepoRoot`. In `install.sh`, this is checked with `case "$ROOT" in "$real" | "$real"/*) return 1 ;; esac`.
- **Recommended Fix:** Check equality or require path delimiter:
  ```powershell
  if ($full -ieq $RepoRoot -or $RepoRoot.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  ```

#### Finding 5: User profile paths containing apostrophes fail installation
- **File:** `deploy/install.ps1`
- **Line Number:** 167
- **Code:**
  ```powershell
  if ($value.Contains("'")) { Stop-Script "$key must not contain a single quote" }
  ```
- **Issue:** If a user account contains an apostrophe (e.g., `C:\Users\O'Connor`), the default `DataDir` (`$env:USERPROFILE\LibreShare`) triggers this guard and aborts installation.

#### Finding 6: Exit code ignored in `Get-RawLink` and log diagnostic dumps
- **File:** `deploy/install.ps1`
- **Line Numbers:** 233, 373, 419
- **Code:**
  ```powershell
  $text = Get-DockerText -DockerArgs @('logs', $Id) -StdoutOnly
  ```
- **Issue:** `Get-RawLink` does not check `$script:LastCode` if `docker logs` fails.

#### Finding 7: Forward slashes displayed in `Invoke-Status`
- **File:** `deploy/install.ps1`
- **Line Number:** 390
- **Code:**
  ```powershell
  if ($settings.ContainsKey('LS_DATA_DIR')) { $data = $settings['LS_DATA_DIR'] }
  ```
- **Issue:** `Invoke-Uninstall` (line 428) converts forward slashes to Windows backslashes (`-replace '/', '\'`), but `Invoke-Status` prints the path directly from `.env` using forward slashes (`C:/Users/.../LibreShare`).

#### Finding 8: Double quotes not stripped by `Read-EnvMap`
- **File:** `deploy/install.ps1`
- **Line Numbers:** 148–150
- **Issue:** Only single quotes are stripped from `.env` values. Manual edits using double quotes (`LS_ALIAS="node"`) retain quotes and get re-quoted on write.

---

## 4. Conclusion

`deploy/install.ps1` is well-constructed, adheres strictly to Windows PowerShell 5.1 compatibility, avoids dangerous native commands, properly validates Linux container mode in Docker Desktop, and protects sensitive system paths against unintended deletion.

The only two **Medium** severity findings are:
1. Omitting `$script:LastCode` check on line 469 (`docker volume rm`).
2. Missing `Set-StrictMode` and error handling on filesystem operations under `$ErrorActionPreference = 'Continue'` (lines 53, 336, 457).
