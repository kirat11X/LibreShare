# LibreShare Windows Release Manual Verification Checklist

**Document Version:** 1.0.0  
**Target Platform:** Windows 10 (version 1809+ / build 17763+) and Windows 11 (all versions), 64-bit (x64)  
**Execution Frequency:** Once per release candidate (RC) and final release build  
**Shell Environment:** Windows PowerShell 5.1 (built into Windows 10/11) or PowerShell 7+  
**Reference Specification:** `docs/LIBRESHARE_BUILD_SPEC.md`, `docs/plans/post-mvp-plan.md` (Card R3)

---

## 1. Test Environment Record

Fill out this environment block prior to beginning the test execution.

| Property | Value | Notes |
|---|---|---|
| Test Date | | YYYY-MM-DD |
| Tester Name / Handle | | |
| Release Package Under Test | `libreshare-<version>-windows-x64.zip` | SHA256 recorded below |
| Windows OS Edition & Version | | e.g. Windows 11 Pro 23H2 (Build 22631.4317) |
| System Type / Architecture | | e.g. Physical PC or Hyper-V/VirtualBox VM, x64 |
| Network Environment | | e.g. Home Wi-Fi 802.11ax / Gigabit Ethernet |
| Network Profile Category | Private | (Public networks block LAN multicast) |
| Linux Peer Device & OS | | e.g. Ubuntu 24.04 LTS / Fedora 40 |
| Linux Peer IP Address | | e.g. 192.168.1.50 |
| Windows Host LAN IP Address | | e.g. 192.168.1.25 |

---

## 2. Master Verification Checklist

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| **WIN-01** | Package Integrity & Unblock | Archive SHA256 matches release manifest; `Unblock-File` clears Zone.Identifier | | |
| **WIN-02** | Zip Extraction | `Expand-Archive` unpacks files cleanly without path errors or missing DLLs | | |
| **WIN-03** | SmartScreen / Defender Inspection | SmartScreen warning handled via "More info" -> "Run anyway"; no false-positive quarantine | | |
| **WIN-04** | Windows Defender Firewall | Private network prompt accepted or PowerShell `New-NetFirewallRule` applied | | |
| **WIN-05** | First Launch & Window Display | App starts cleanly, renders desktop GUI, no missing runtime DLL errors | | |
| **WIN-06** | LAN Discovery (mDNS / Multicast) | Linux peer appears automatically in "Nearby" devices list within 5 seconds | | |
| **WIN-07** | Fallback Discovery (Subnet Scan / IP) | If multicast filtered, adding Linux peer by IP:port or link succeeds | | |
| **WIN-08** | Transfer: Windows to Linux | File sent from Windows arrives on Linux byte-identical (`certutil` vs `sha256sum`) | | |
| **WIN-09** | Transfer: Linux to Windows | File sent from Linux arrives in `%USERPROFILE%\Downloads\LibreShare` byte-identical | | |
| **WIN-10** | System Tray Icon & Tooltip | Tray icon appears in notification area; hover tooltip displays receive status | | |
| **WIN-11** | Minimize / Close to Tray | Clicking window "X" with Receive active hides window to tray without exiting | | |
| **WIN-12** | Tray Context Menu Actions | "Open LibreShare" restores window; "Quit" cleanly terminates the process | | |
| **WIN-13** | Autostart Registry Enable | Toggling "Start on login" creates `HKCU\...\Run` entry with `"<exe>" --hidden` | | |
| **WIN-14** | Headless Background Start | Launching with `--hidden` flag starts background process without flashing window | | |
| **WIN-15** | Autostart Registry Disable | Disabling "Start on login" removes `LibreShare` value from `Run` key | | |
| **WIN-16** | Special Filename Handling | File with spaces, `&`, `#`, `[ ]`, `,` transfers byte-identical | | |
| **WIN-17** | Received File "Open" Action | Clicking "Open" launches default Windows handler for file with spaces/symbols | | |
| **WIN-18** | Received File "Show in folder" | Clicking "Show in folder" opens Explorer with target file selected | | |
| **WIN-19** | Cleanup & Teardown | Test directories, firewall rules, and test files removed cleanly | | |

---

## 3. Detailed Step-by-Step Instructions

> **PowerShell Rules**:
> All scripts in this guide are strictly verified for standard **Windows PowerShell 5.1** (as well as PowerShell 7+):
> - No bash chaining (`&&` or `||`).
> - No PowerShell 7 operators (`?:` ternary or `??` null-coalescing).
> - Proper variable quoting with `Join-Path` and `& "executable"`.
> - External exit codes verified via `$LASTEXITCODE`.

---

### Step 1: Package Integrity, Unblock, and Extraction

#### Instructions
1. Download `libreshare-<version>-windows-x64.zip` and `SHA256SUMS` to your Downloads folder.
2. Open Windows PowerShell 5.1 (no administrator elevation required).
3. Set test variables, verify SHA256 checksum, unblock the archive (clearing Mark of the Web `Zone.Identifier`), and extract.

#### PowerShell Commands
```powershell
$ZipPath = Join-Path $env:USERPROFILE "Downloads\libreshare-1.0.0-windows-x64.zip"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\LibreShare"

Write-Host "Verifying archive path: $ZipPath"
if (-not (Test-Path -LiteralPath $ZipPath)) {
    Write-Error "Release archive not found at $ZipPath. Download it before proceeding."
}

# 1. Compute SHA256 using certutil.exe
certutil.exe -hashfile $ZipPath SHA256
if ($LASTEXITCODE -ne 0) {
    Write-Error "certutil failed with exit code $LASTEXITCODE"
}

# 2. Unblock file if downloaded from browser (Zone.Identifier)
Unblock-File -LiteralPath $ZipPath
Write-Host "Archive unblocked."

# 3. Create destination directory and extract
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Write-Host "Extracting to: $InstallDir ..."
Expand-Archive -LiteralPath $ZipPath -DestinationPath $InstallDir -Force
if ($?) {
    Write-Host "Extraction completed successfully."
} else {
    Write-Error "Extraction failed."
}

# 4. Verify critical bundle files exist
$ExePath = Join-Path $InstallDir "libreshare_app.exe"
$FlutterDll = Join-Path $InstallDir "flutter_windows.dll"
$DataDir = Join-Path $InstallDir "data"

Write-Host "Validating bundle contents:"
Write-Host "  Executable:    $(Test-Path -LiteralPath $ExePath)"
Write-Host "  Flutter DLL:   $(Test-Path -LiteralPath $FlutterDll)"
Write-Host "  Data folder:   $(Test-Path -LiteralPath $DataDir)"
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-01 | SHA256 Hash Verification | Hash matches release manifest | | |
| WIN-01b | Unblock-File Execution | Zone.Identifier stream removed | | |
| WIN-02 | Expand-Archive Extraction | Files extracted into `%LOCALAPPDATA%\Programs\LibreShare` without error | | |

---

### Step 2: Antivirus, SmartScreen, and Windows Defender Behavior

#### Instructions
1. Unsigned release binaries will trigger Microsoft Defender SmartScreen upon initial execution.
2. Verify that SmartScreen displays the expected warning ("Windows protected your PC / Microsoft Defender SmartScreen").
3. Click **More info**, confirm Publisher shows "Unknown publisher", and click **Run anyway**.
4. Run a Windows Defender Custom Scan on the extracted directory to ensure no false-positive heuristic flags (e.g., Trojan/Wacatac, ML-heuristics).

#### PowerShell Commands
```powershell
# 1. Query Windows Defender status
Get-MpComputerStatus | Select-Object -Property AntivirusEnabled, RealTimeProtectionEnabled, IoavProtectionEnabled

# 2. Scan extracted LibreShare folder with Windows Defender
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\LibreShare"
Write-Host "Running Windows Defender custom scan on $InstallDir ..."
Start-MpScan -ScanPath $InstallDir -ScanType CustomScan
if ($?) {
    Write-Host "Defender scan completed."
} else {
    Write-Warning "Start-MpScan failed or was skipped."
}

# 3. Check for any detected threats or quarantined files
$Detections = Get-MpThreatDetection
if ($null -ne $Detections) {
    Write-Warning "Threat detections reported by Defender:"
    $Detections | Format-Table -Property ThreatID, ThreatName, InitialDetectionTime, Resources
} else {
    Write-Host "No threats detected. Windows Defender reports clean."
}
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-03a | SmartScreen Dialog | Displays "Windows protected your PC" with "Unknown publisher" | | |
| WIN-03b | SmartScreen Bypass | Clicking "More info" -> "Run anyway" launches application | | |
| WIN-03c | Defender Threat Scan | Clean scan; no files quarantined or deleted by Real-Time Protection | | |

---

### Step 3: Windows Defender Firewall Configuration

#### Context
LibreShare uses:
- **TCP Ports 53318-53327**: Inbound HTTP/HTTPS API transfer server (`ApiServer`).
- **UDP Port 53318**: Inbound LAN discovery datagrams (`224.0.0.168:53318` multicast and unicast announcements).

#### Instructions
- **Interactive Check**: Upon first launch (or when switching **Receive** ON), Windows Defender Firewall should pop up: *"Windows Defender Firewall has blocked some features of this app"*. Check **Private networks (such as home or work network)** and click **Allow access**.
- **Scripted Check (Administrator PowerShell)**: If configuring programmatically or verifying existing rules, run the commands below in an **Administrator** PowerShell session.

#### PowerShell Commands (Run in Administrator PowerShell)
```powershell
# 1. Verify current network connection is set to Private
Get-NetConnectionProfile | Format-Table -Property Name, InterfaceAlias, NetworkCategory, IPv4Address

# 2. Create inbound firewall rule for TCP Transfer Ports 53318-53327
New-NetFirewallRule -DisplayName "LibreShare Transfer (TCP 53318-53327)" `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 53318-53327 `
    -Profile Private

# 3. Create inbound firewall rule for UDP Discovery Port 53318
New-NetFirewallRule -DisplayName "LibreShare Discovery (UDP 53318)" `
    -Direction Inbound `
    -Action Allow `
    -Protocol UDP `
    -LocalPort 53318 `
    -Profile Private

# 4. Verify created rules
Get-NetFirewallRule -DisplayName "LibreShare*" | Format-Table -Property Name, DisplayName, Enabled, Direction, Action, Profile
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-04a | Network Profile Check | Network profile is "Private" | | |
| WIN-04b | Firewall Inbound TCP Rule | TCP 53318-53327 allowed on Private profile | | |
| WIN-04c | Firewall Inbound UDP Rule | UDP 53318 allowed on Private profile | | |

---

### Step 4: LAN Discovery with Linux Machine (mDNS / Subnet Scan)

#### Prerequisites
- A Linux machine running on the same local network subnet.
- On Linux, start the LibreShare desktop app with **Receive: ON**, or run the CLI receiver:
  ```bash
  dart run packages/libreshare_cli/bin/ls.dart receive --port 53318 --dir ~/rx --auto-accept
  ```
- Note the Linux IP address (e.g. `192.168.1.50`).

#### Instructions
1. Launch LibreShare on Windows:
   ```powershell
   $ExePath = Join-Path $env:LOCALAPPDATA "Programs\LibreShare\libreshare_app.exe"
   & $ExePath
   ```
2. Turn **Receive** switch to **ON** on Windows.
3. Observe the **Nearby** screen on Windows:
   - Does the Linux peer appear automatically within 5 seconds?
   - Does it display the correct device name, platform ("Linux"), and IP address?
4. Observe the Linux device:
   - Does the Windows machine appear in the Linux device list with platform ("Windows")?
5. **Fallback Test**:
   - If multicast is blocked by the Wi-Fi router (AP isolation):
     - Click **Add device** (top right icon) -> **By IP address**.
     - Enter the Linux IP and port: `192.168.1.50:53318`.
     - Click **Look up** -> **Add**.
     - Verify device card is added.

#### PowerShell Connectivity Probe
```powershell
# Test TCP reachability from Windows to Linux peer
$LinuxIp = "192.168.1.50"
$Port = 53318

Write-Host "Testing connectivity to Linux peer at ${LinuxIp}:${Port} ..."
Test-NetConnection -ComputerName $LinuxIp -Port $Port
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-06a | Windows sees Linux peer | Linux device automatically visible under Nearby | | |
| WIN-06b | Linux sees Windows peer | Windows device visible on Linux peer | | |
| WIN-07 | Manual IP Add / Subnet probe | Direct lookup by `IP:53318` successfully resolves peer | | |

---

### Step 5: Bidirectional Transfer & Byte-Identical Integrity

#### Test Payloads Preparation
Run this snippet on Windows to generate two deterministic test payloads:
1. `small_test.txt` (1 KiB text)
2. `payload_10mb.dat` (10 MiB pseudo-random binary)

```powershell
$TestDir = Join-Path $env:USERPROFILE "Downloads\LibreShare_Manual_Tests"
if (-not (Test-Path -LiteralPath $TestDir)) {
    New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
}

# 1. Generate text payload
$SmallFile = Join-Path $TestDir "small_test.txt"
"LibreShare Windows manual test - $(Get-Date -Format o)" | Out-File -FilePath $SmallFile -Encoding utf8

# 2. Generate 10 MiB binary payload
$BinFile = Join-Path $TestDir "payload_10mb.dat"
$Bytes = New-Object byte[] (10 * 1024 * 1024)
$Rng = New-Object System.Random(42)
$Rng.NextBytes($Bytes)
[System.IO.File]::WriteAllBytes($BinFile, $Bytes)
$Bytes = $null

Write-Host "Test payloads generated in $TestDir."
Write-Host "Computing original hashes with certutil:"
certutil.exe -hashfile $SmallFile SHA256
certutil.exe -hashfile $BinFile SHA256
```

#### Test 5A: Send Windows -> Linux
1. In the Windows app, click **Send files**.
2. Select `$TestDir\payload_10mb.dat`.
3. In **Choose a device**, tap the Linux device card to initiate sending.
4. On Linux, click **Accept** on the incoming transfer dialog.
5. Wait for transfer to reach 100% and show "Sent 1 file".
6. On the Linux peer, compute the checksum:
   ```bash
   sha256sum ~/Downloads/LibreShare/payload_10mb.dat
   ```
7. Compare with the Windows `certutil` output for `payload_10mb.dat`. Must be identical.

#### Test 5B: Send Linux -> Windows
1. On Linux, click **Send files**, select `payload_10mb.dat`.
2. Tap the Windows peer card.
3. On Windows, verify the **Incoming transfer** dialog appears:
   - Displays sender name and platform ("Linux").
   - Shows "1 file (10.0 MB)".
   - Shows 6-digit verification code / SAS.
4. Click **Accept**.
5. Observe progress bar reaching 100% and completion card showing "Received 1 file".
6. Verify file saved to `%USERPROFILE%\Downloads\LibreShare\payload_10mb.dat`.
7. Compute checksum on Windows:
```powershell
$RxFile = Join-Path $env:USERPROFILE "Downloads\LibreShare\payload_10mb.dat"
certutil.exe -hashfile $RxFile SHA256
if ($LASTEXITCODE -ne 0) {
    Write-Error "certutil failed with exit code $LASTEXITCODE"
}
```
8. Verify hash is identical to Linux original.

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-08a | Windows -> Linux Transfer | Transfer completes without stalls or disconnections | | |
| WIN-08b | Windows -> Linux Integrity | Linux `sha256sum` exactly matches Windows `certutil` | | |
| WIN-09a | Linux -> Windows Transfer | Transfer dialog prompts, accepts, and completes | | |
| WIN-09b | Linux -> Windows Integrity | Windows `certutil` exactly matches Linux `sha256sum` | | |

---

### Step 6: System Tray Icon & Minimize to Tray

#### Instructions
1. Check the Windows taskbar notification area (system tray, including the `^` overflow menu):
   - Is the LibreShare tray icon visible?
2. Hover over the tray icon:
   - Does the tooltip show receive status (e.g., "LibreShare - Receiving" or "Visible to everyone")?
3. Test **Minimize to Tray**:
   - Ensure **Receive** is **ON** in the app.
   - Click the window close button ("X" in top right corner).
   - Expected: The window closes / hides, but the application does **NOT** terminate. The tray icon remains active.
4. Right-click the tray icon to open the context menu:
   - Verify menu items: **Open LibreShare**, **Turn Receive on/off**, **Quit**.
   - Click **Open LibreShare**: The window restores and takes focus.
5. Test **Clean Exit**:
   - Right-click tray icon -> click **Quit**.
   - Verify process exits cleanly.

#### PowerShell Commands
```powershell
# 1. Verify process state while minimized to tray
$Proc = Get-Process -Name "libreshare_app" -ErrorAction SilentlyContinue
if ($null -ne $Proc) {
    Write-Host "Process is running (PID: $($Proc.Id), WorkingSet: $([math]::Round($Proc.WorkingSet64 / 1MB, 2)) MB)"
} else {
    Write-Warning "libreshare_app process is not running."
}

# 2. Check window visibility state via Win32 API
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

if ($null -ne $Proc -and $Proc.MainWindowHandle -ne [IntPtr]::Zero) {
    $Visible = [WindowHelper]::IsWindowVisible($Proc.MainWindowHandle)
    Write-Host "Main window handle: $($Proc.MainWindowHandle), IsVisible: $Visible"
}
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-10a | Tray Icon Present | Icon visible in system tray / notification overflow | | |
| WIN-10b | Tray Tooltip | Hover text shows application & receive status | | |
| WIN-11 | Close-to-Tray | Clicking "X" hides window to tray while Receive is ON | | |
| WIN-12a | Restore from Tray | "Open LibreShare" restores and focuses main window | | |
| WIN-12b | Clean Quit | "Quit" from tray menu terminates `libreshare_app.exe` | | |

---

### Step 7: Autostart Registry Configuration (`HKCU\...\Run`)

#### Context
LibreShare Windows autostart writes directly to:
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`  
Value Name: `LibreShare`  
Value Data: `"C:\...\libreshare_app.exe" --hidden`

#### Instructions
1. In LibreShare, navigate to **Settings**.
2. Find **Start on login** (or **Start at boot**) toggle.
3. Switch toggle to **ON**.
4. Run PowerShell command to verify the registry value.
5. Test simulated autostart launch with `--hidden`:
   - Kill any running app instance.
   - Run the command registered in the registry.
   - Verify app starts in background without showing a window flash, and tray icon appears.
6. Return to **Settings** and switch toggle to **OFF**.
7. Run PowerShell command to verify the registry entry is deleted.

#### PowerShell Commands
```powershell
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$ValueName = "LibreShare"

# 1. Check registry entry when toggle is ON
$Entry = Get-ItemProperty -Path $RunKey -Name $ValueName -ErrorAction SilentlyContinue
if ($null -ne $Entry) {
    $Command = $Entry.$ValueName
    Write-Host "Autostart entry detected:"
    Write-Host "  Key:     $RunKey"
    Write-Host "  Name:    $ValueName"
    Write-Host "  Command: $Command"
    Write-Host "  Length:  $($Command.Length) characters"

    if ($Command -match '--hidden') {
        Write-Host "PASS: Command includes --hidden flag."
    } else {
        Write-Warning "FAIL: Command is missing --hidden flag."
    }

    if ($Command.Length -le 260) {
        Write-Host "PASS: Command length is <= 260 character limit ($($Command.Length) chars)."
    } else {
        Write-Warning "FAIL: Command exceeds Windows 260 character limit."
    }
} else {
    Write-Host "Autostart entry is NOT present in registry."
}

# 2. Test execution with --hidden flag
Write-Host "Testing background execution with --hidden ..."
$AppExe = Join-Path $env:LOCALAPPDATA "Programs\LibreShare\libreshare_app.exe"
$Proc = Start-Process -FilePath $AppExe -ArgumentList "--hidden" -PassThru
Start-Sleep -Seconds 3

# Check if running and if a window is visible
if (-not $Proc.HasExited) {
    Write-Host "Process running with PID: $($Proc.Id). Window should remain unmapped."
} else {
    Write-Warning "Process exited unexpectedly."
}

# Clean up process after test
Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue

# 3. Check registry entry after toggle is turned OFF
$EntryAfterOff = Get-ItemProperty -Path $RunKey -Name $ValueName -ErrorAction SilentlyContinue
if ($null -eq $EntryAfterOff) {
    Write-Host "PASS: Autostart entry successfully deleted after toggle OFF."
} else {
    Write-Warning "FAIL: Registry entry still exists after toggle OFF: $($EntryAfterOff.$ValueName)"
}
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-13a | Registry Entry Created | `LibreShare` value exists in `HKCU\...\Run` | | |
| WIN-13b | Autostart Flags & Quoting | Value is properly quoted path followed by `--hidden` | | |
| WIN-13c | Command Length Check | Total command string <= 260 characters | | |
| WIN-14 | Headless Launch | `--hidden` launch displays no window flash; icon docks in tray | | |
| WIN-15 | Registry Entry Removed | Toggling OFF deletes `LibreShare` value from registry | | |

---

### Step 8: Received File "Open" & "Show in Folder" with Spaces and Special Characters

#### Context
Windows path handling risks identified in `docs/test-reports/windows-readiness.md`:
- `explorer.exe /select,"<path>"` can fail or open default Documents if paths contain spaces, `#`, `&`, commas, or non-ASCII characters without proper argument quoting.
- `rundll32 url.dll,FileProtocolHandler "<path>"` can misparse commas or URL characters.

#### Instructions
1. On the Linux peer, create a file with challenging characters:
   ```bash
   echo "Special path test" > ~/"Test Document & Report #1, [Final] - 2026.txt"
   ```
2. Send this file from Linux to Windows.
3. On Windows, accept the file.
4. On the completed transfer card:
   - Click **Open**:
     - Verify default Windows text viewer (e.g. Notepad) opens the file without error.
   - Click **Show in folder**:
     - Verify Windows Explorer opens with the exact file **highlighted / selected** (not just the root folder).

#### PowerShell Verification
```powershell
$SpecialName = "Test Document & Report #1, [Final] - 2026.txt"
$RxSpecialFile = Join-Path $env:USERPROFILE "Downloads\LibreShare\$SpecialName"

Write-Host "Checking received file with special characters:"
Write-Host "  Target path: $RxSpecialFile"

if (Test-Path -LiteralPath $RxSpecialFile) {
    Write-Host "PASS: File exists on disk."
    certutil.exe -hashfile $RxSpecialFile SHA256
    if ($LASTEXITCODE -ne 0) {
        Write-Error "certutil failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Warning "FAIL: File not found. Verify sanitization did not alter name unexpectedly."
}
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-16 | Special File Received | File arrives intact with spaces, commas, `#`, `&`, `[ ]` preserved | | |
| WIN-17 | "Open" Action | Default app launches and displays file contents | | |
| WIN-18 | "Show in Folder" Action | Explorer opens and selects/highlights target file | | |

---

### Step 9: Teardown and Cleanup

#### Instructions
Clean up all temporary files, firewall rules, and test configurations created during verification.

#### PowerShell Commands (Run in Administrator PowerShell if removing firewall rules)
```powershell
# 1. Stop any running LibreShare instances
$Proc = Get-Process -Name "libreshare_app" -ErrorAction SilentlyContinue
if ($null -ne $Proc) {
    Stop-Process -InputObject $Proc -Force
    Write-Host "Stopped LibreShare process."
}

# 2. Remove generated test payloads
$TestDir = Join-Path $env:USERPROFILE "Downloads\LibreShare_Manual_Tests"
if (Test-Path -LiteralPath $TestDir) {
    Remove-Item -LiteralPath $TestDir -Recurse -Force
    Write-Host "Removed test directory: $TestDir"
}

# 3. Clean received test files from LibreShare download folder
$RxDir = Join-Path $env:USERPROFILE "Downloads\LibreShare"
$TestFiles = @(
    "small_test.txt",
    "payload_10mb.dat",
    "Test Document & Report #1, [Final] - 2026.txt"
)
foreach ($File in $TestFiles) {
    $Target = Join-Path $RxDir $File
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Force
        Write-Host "Removed test file: $Target"
    }
}

# 4. Remove firewall rules created for the test
Remove-NetFirewallRule -DisplayName "LibreShare*" -ErrorAction SilentlyContinue
Write-Host "LibreShare firewall rules removed."

# 5. Ensure autostart registry entry is removed
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Remove-ItemProperty -Path $RunKey -Name "LibreShare" -ErrorAction SilentlyContinue
Write-Host "LibreShare autostart registry entry cleared."
```

| Step | Description | Expected | Result (PASS/FAIL) | Notes |
|---|---|---|---|---|
| WIN-19a | Process Teardown | `libreshare_app` terminated cleanly | | |
| WIN-19b | Test File Cleanup | Test files removed from `%USERPROFILE%\Downloads` | | |
| WIN-19c | Firewall Teardown | `LibreShare*` firewall rules deleted | | |
| WIN-19d | Registry Teardown | `LibreShare` autostart value removed | | |

---

## 4. Release Gate Verdict & Sign-Off

| Metric | Threshold | Actual | Status |
|---|---|---|---|
| Critical Test Steps (WIN-01 through WIN-18) | 100% PASS | | |
| Data Integrity (Byte-Identical SHA256) | Both directions PASS | | |
| SmartScreen / AV False Positives | 0 Unresolvable blocks | | |
| Final Release Gate Recommendation | **GO / NO-GO** | | |

### Tester Sign-Off
- **Tester Signature:** ___________________________
- **Date Completed:** ___________________________
- **Overall Verdict:** `[ ] PASS   [ ] FAIL   [ ] BLOCKED`
- **Defects / Issues Filed:**
  1. 
  2. 
