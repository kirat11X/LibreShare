<#
.SYNOPSIS
  LibreShare headless node: one-command Docker install for Windows (Docker Desktop, WSL2, Linux containers).

.DESCRIPTION
  Builds and starts the LibreShare "drop box" node with deploy/docker/compose.windows.yaml, waits until
  it is healthy and prints how other devices reach it.

  Docker Desktop runs containers behind a NAT, so LAN auto-discovery (multicast) does NOT reach the node.
  Other devices connect with a link or IP:port. This script finds this PC's LAN IPv4 address and prints a
  libreshare://peer link that carries it (the container only knows its internal 172.x address).

  PROTOTYPE: plain HTTP, no TLS/PIN yet, auto-accept on. Trusted private networks only.
  Windows *native* containers cannot run this Linux image: Docker Desktop must be in Linux-containers mode.
  Nothing is deleted without an explicit "delete" answer. The firewall rule is printed, never created.

  Windows PowerShell 5.1 and PowerShell 7+. If scripts are blocked on your PC, run it as:
    powershell -ExecutionPolicy Bypass -File deploy\install.ps1

.PARAMETER Status
  Show whether the node runs, its link and the received folder.
.PARAMETER Uninstall
  Stop the node, remove the container and the image; asks before deleting received files.
.PARAMETER KeepData
  With -Uninstall: keep received files without asking.
.PARAMETER DataDir
  Folder for received files (default: %USERPROFILE%\LibreShare).
.PARAMETER Port
  TCP/UDP port of the node (default 53318).
.PARAMETER Alias
  Name other devices see (default: libreshare-<COMPUTERNAME>).
.PARAMETER HostIp
  This PC's LAN IPv4 address, if the automatic detection picks the wrong one.
.PARAMETER Project
  Compose project name (default: libreshare).
.PARAMETER EnvFile
  Settings file (default: deploy\docker\.env).
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Uninstall,
    [switch]$KeepData,
    [string]$DataDir = '',
    [int]$Port = 0,
    [string]$Alias = '',
    [string]$HostIp = '',
    [string]$Project = 'libreshare',
    [string]$EnvFile = '',
    [int]$WaitSeconds = 120
)

$ErrorActionPreference = 'Continue'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $RepoRoot 'deploy\docker\compose.windows.yaml'
if ($EnvFile -eq '') { $EnvFile = Join-Path $RepoRoot 'deploy\docker\.env' }
$Image = 'libreshare/node:local'
$Service = 'libreshare'
$script:LastCode = 0

# ----------------------------------------------------------------- output helpers

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
function Write-Kv([string]$Key, [string]$Value) { Write-Host ('  {0,-15}: {1}' -f $Key, $Value) }
function Stop-Script([string]$Message, [int]$Code = 1) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}

# ----------------------------------------------------------------- docker helpers

# Runs docker, returns its combined stdout+stderr as one trimmed string (stdout only with -StdoutOnly:
# for values that are parsed); exit code in $script:LastCode.
function Get-DockerText {
    param([string[]]$DockerArgs, [switch]$StdoutOnly)
    if ($StdoutOnly) {
        $lines = & docker @DockerArgs 2>$null | ForEach-Object { "$_" }
    } else {
        $lines = & docker @DockerArgs 2>&1 | ForEach-Object { "$_" }
    }
    $script:LastCode = $LASTEXITCODE
    return (($lines | Out-String).Trim())
}

# Runs "docker compose" for this project with output shown; returns the exit code.
function Invoke-Compose {
    param([string[]]$More)
    $composeArgs = @('compose', '-p', $Project)
    if (Test-Path -LiteralPath $EnvFile) { $composeArgs += @('--env-file', $EnvFile) }
    $composeArgs += @('-f', $ComposeFile)
    $composeArgs += $More
    & docker @composeArgs | Out-Host
    return $LASTEXITCODE
}

function Get-ContainerId {
    $composeArgs = @('compose', '-p', $Project)
    if (Test-Path -LiteralPath $EnvFile) { $composeArgs += @('--env-file', $EnvFile) }
    $composeArgs += @('-f', $ComposeFile, 'ps', '-a', '-q', $Service)
    $text = Get-DockerText -DockerArgs $composeArgs -StdoutOnly
    if ($script:LastCode -ne 0 -or $text -eq '') { return '' }
    return ($text -split "`r?`n")[0].Trim()
}

function Get-ContainerField([string]$Id, [string]$Format) {
    $text = Get-DockerText -DockerArgs @('inspect', '-f', $Format, $Id) -StdoutOnly
    if ($script:LastCode -ne 0) { return '' }
    return $text
}

function Test-Prerequisites {
    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host 'Docker is not installed (no "docker" on PATH).' -ForegroundColor Red
        Write-Host '  Install Docker Desktop for Windows (WSL2 backend): https://docs.docker.com/desktop/setup/install/windows-install/'
        Write-Host '  Then start it, wait for "Engine running", open a NEW PowerShell window and run this script again.'
        exit 1
    }
    $os = Get-DockerText -DockerArgs @('info', '--format', '{{.OSType}}') -StdoutOnly
    if ($script:LastCode -ne 0) {
        Write-Host 'Docker is installed, but its engine is not reachable.' -ForegroundColor Red
        Write-Host '  Start Docker Desktop and wait until it says "Engine running", then run this script again.'
        Write-Host '  If it never starts: enable WSL 2 / virtualization (BIOS) and run "wsl --update".'
        exit 1
    }
    if ($os -ne 'linux') {
        Write-Host "Docker Desktop is running $os containers; LibreShare needs LINUX containers." -ForegroundColor Red
        Write-Host '  Right-click the Docker whale in the system tray and choose "Switch to Linux containers...".'
        exit 1
    }
    $null = Get-DockerText -DockerArgs @('compose', 'version')
    if ($script:LastCode -ne 0) {
        Write-Host 'The Docker Compose v2 plugin ("docker compose") is missing.' -ForegroundColor Red
        Write-Host '  Update Docker Desktop to a current version; it includes Compose.'
        exit 1
    }
}

# ----------------------------------------------------------------- settings file (.env)

function Read-EnvMap {
    $map = @{}
    if (Test-Path -LiteralPath $EnvFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                $value = $Matches[2].Trim()
                if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                $map[$Matches[1]] = $value
            }
        }
    }
    return $map
}

# Writes the settings as UTF-8 WITHOUT a byte-order mark (Windows PowerShell 5.1 "Out-File -Encoding utf8"
# adds one, and docker compose then fails to read the first key).
function Write-EnvMap([hashtable]$Map) {
    $dir = Split-Path -Parent $EnvFile
    if ($dir -ne '' -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# Written by deploy/install.ps1. Safe to edit; see docs/dev/docker-install.md for all LS_* settings.')
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $value = [string]$Map[$key]
        if ($value.Contains("'")) { Stop-Script "$key must not contain a single quote" }
        if ($value -notmatch '^[A-Za-z0-9_./:@-]*$') { $value = "'" + $value + "'" }
        $out.Add("$key=$value")
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($EnvFile, (($out -join "`n") + "`n"), $utf8NoBom)
}

# ----------------------------------------------------------------- network helpers

function Test-PrivateIPv4([string]$Ip) {
    return ($Ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)')
}

$VirtualAdapterPattern = 'vEthernet|WSL|Hyper-V|VirtualBox|VMware|Docker|Loopback|Bluetooth|Tailscale|ZeroTier'

# This PC's primary private IPv4: the adapter that owns the default route, ignoring virtual adapters.
function Get-PrimaryLanIp {
    try {
        $configs = Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
            $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.InterfaceAlias -notmatch $VirtualAdapterPattern
        }
        foreach ($config in @($configs)) {
            foreach ($address in @($config.IPv4Address)) {
                if (Test-PrivateIPv4 $address.IPAddress) { return $address.IPAddress }
            }
        }
    } catch {
        # fall through to the next method
    }
    try {
        $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.InterfaceAlias -notmatch $VirtualAdapterPattern -and (Test-PrivateIPv4 $_.IPAddress)
        }
        foreach ($address in @($addresses)) { return $address.IPAddress }
    } catch {
        # nothing found
    }
    return ''
}

function Test-FirewallRule {
    try {
        $rules = Get-NetFirewallRule -DisplayName "LibreShare node $script:EffectivePort *" -ErrorAction Stop
        return (@($rules).Count -ge 2)
    } catch {
        return $false
    }
}

function Write-FirewallHelp([int]$PortNumber) {
    if (Test-FirewallRule) { return }
    Write-Host ''
    Write-Host 'Windows Defender Firewall:' -ForegroundColor Cyan
    Write-Host '  When Docker Desktop first publishes the port, Windows may ask whether to allow "Docker Desktop Backend".'
    Write-Host '  Choose "Private networks" (home/office Wi-Fi). Otherwise other devices cannot connect.'
    Write-Host '  Or allow TCP+UDP explicitly. This script does NOT do it for you; run in an ADMINISTRATOR PowerShell:'
    Write-Host ('  New-NetFirewallRule -DisplayName "LibreShare node {0} TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort {0} -Profile Private' -f $PortNumber)
    Write-Host ('  New-NetFirewallRule -DisplayName "LibreShare node {0} UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort {0} -Profile Private' -f $PortNumber)
    Write-Host '  (remove later with: Remove-NetFirewallRule -DisplayName "LibreShare node*")'
}

# ----------------------------------------------------------------- peer link

# The last PEER-LINK line the running node printed, or ''.
function Get-RawLink([string]$Id) {
    $text = Get-DockerText -DockerArgs @('logs', $Id) -StdoutOnly
    $match = ($text -split "`r?`n") | Where-Object { $_ -like 'PEER-LINK *' } | Select-Object -Last 1
    if ($null -eq $match) { return '' }
    return $match.Substring('PEER-LINK '.Length).Trim()
}

# Swaps the container-internal IP for this PC's LAN IP and drops the device id, so that the link survives
# restarts (the prototype CLI makes a new device id on every start; a link pinning the old one is refused).
function Get-PublicLink([string]$Raw, [string]$LanIp) {
    if ($Raw -eq '') { return '' }
    $link = $Raw
    if ($LanIp -ne '') { $link = $link -replace '([?&])ip=[^&]*', ('${1}ip=' + $LanIp) }
    return ($link -replace '&id=[^&]*', '')
}

# ----------------------------------------------------------------- data folder

function Get-DirSummary([string]$Path) {
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.libreshare-data' })
    $bytes = 0
    foreach ($f in $files) { $bytes += $f.Length }
    return ('{0} files, {1} MiB' -f $files.Count, [math]::Ceiling($bytes / 1MB))
}

function Test-HasContent([string]$Path) {
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.libreshare-data' })
    return ($items.Count -gt 0)
}

function Test-SafeToDelete([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $protected = @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:PUBLIC, (Split-Path -Parent $env:USERPROFILE))
    foreach ($p in $protected) {
        if ($p -and ($full.TrimEnd('\') -ieq $p.TrimEnd('\'))) { return $false }
    }
    if ($full.Length -le 3) { return $false }                       # a drive root such as C:
    if ($RepoRoot.StartsWith($full, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path '.libreshare-data'))
}

# ----------------------------------------------------------------- actions

function Show-Summary([string]$Id, [int]$PortNumber, [string]$Data, [string]$AliasName, [string]$LanIp) {
    $link = Get-PublicLink (Get-RawLink $Id) $LanIp
    $name = (Get-ContainerField $Id '{{.Name}}').TrimStart('/')
    Write-Host ''
    Write-Host 'LibreShare node is running.' -ForegroundColor Green
    Write-Kv 'Alias' $AliasName
    Write-Kv 'Address' ('{0}:{1}   (TCP+UDP; project ''{2}'', container {3})' -f $LanIp, $PortNumber, $Project, $name)
    Write-Kv 'Received files' $Data
    if ($link -ne '') {
        Write-Kv 'Peer link' $link
        Write-Host '                   (in the app: Add device by link / QR; CLI: libreshare send --device "<link>" FILE)'
    } else {
        Write-Kv 'Peer link' '(not printed yet; run: deploy\install.ps1 -Status)'
    }
    Write-Host ''
    Write-Host 'Docker Desktop runs the node behind a NAT: LAN auto-discovery (multicast) does NOT reach it.'
    Write-Host "Other devices must use the link above or ${LanIp}:${PortNumber}. Your own PC can use 127.0.0.1:${PortNumber}."
    Write-FirewallHelp $PortNumber
    Write-Host ''
    Write-Warn 'LibreShare prototype: transfers are NOT encrypted or authenticated and anyone on this network can drop files into the received folder. Use only on a trusted private network (Increment 3 adds TLS/PIN).'
    Write-Host ''
    Write-Host "Status: deploy\install.ps1 -Status      Uninstall: deploy\install.ps1 -Uninstall      Logs: docker logs -f $name"
}

function Invoke-Install {
    Test-Prerequisites
    $settings = Read-EnvMap

    $data = $DataDir
    if ($data -eq '' -and $settings.ContainsKey('LS_DATA_DIR')) { $data = $settings['LS_DATA_DIR'] }
    if ($data -eq '') { $data = Join-Path $env:USERPROFILE 'LibreShare' }
    $data = [System.IO.Path]::GetFullPath($data).TrimEnd('\')

    $portNumber = $Port
    if ($portNumber -eq 0 -and $settings.ContainsKey('LS_PORT')) { $portNumber = [int]$settings['LS_PORT'] }
    if ($portNumber -eq 0) { $portNumber = 53318 }
    if ($portNumber -lt 1 -or $portNumber -gt 65535) { Stop-Script "port must be 1..65535, got $portNumber" }
    $script:EffectivePort = $portNumber

    $aliasName = $Alias
    if ($aliasName -eq '' -and $settings.ContainsKey('LS_ALIAS')) { $aliasName = $settings['LS_ALIAS'] }
    if ($aliasName -eq '') { $aliasName = 'libreshare-' + $env:COMPUTERNAME }

    $lanIp = $HostIp
    if ($lanIp -eq '') { $lanIp = Get-PrimaryLanIp }
    if ($lanIp -eq '') {
        Stop-Script 'cannot work out this PC''s LAN IPv4 address. Pass it: deploy\install.ps1 -HostIp 192.168.x.y  (run "ipconfig" to see it)'
    }
    if ($lanIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Stop-Script "-HostIp must be an IPv4 address, got '$lanIp'" }

    # Port taken by something else? (our own running node is fine: re-running updates it)
    if ((Get-ContainerId) -eq '') {
        $busy = @(Get-NetTCPConnection -State Listen -LocalPort $portNumber -ErrorAction SilentlyContinue)
        if ($busy.Count -gt 0) {
            Stop-Script "TCP port $portNumber is already in use on this PC (the LibreShare desktop app? another node?). Pick another: deploy\install.ps1 -Port $($portNumber + 1)"
        }
    }

    # Received-files folder, created by you (not by Docker as root).
    $createdHere = $false
    if (-not (Test-Path -LiteralPath $data)) {
        $null = New-Item -ItemType Directory -Path $data -Force
        $createdHere = $true
    } elseif (-not (Test-HasContent $data)) {
        $createdHere = $true
    }
    if ($createdHere) { $null = New-Item -ItemType File -Path (Join-Path $data '.libreshare-data') -Force }

    $settings['LS_PORT'] = [string]$portNumber
    $settings['LS_ALIAS'] = $aliasName
    $settings['LS_DATA_DIR'] = ($data -replace '\\', '/')
    $settings['LS_HOST_IP'] = $lanIp
    Write-EnvMap $settings

    Write-Step "Building and starting LibreShare (project '$Project'). The first build takes a few minutes."
    $code = Invoke-Compose -More @('up', '-d', '--build')
    if ($code -ne 0) { Stop-Script 'docker compose failed (see the output above). Your files were not touched.' }

    Write-Step "Waiting for the node to become healthy (up to $WaitSeconds s)"
    $id = ''
    $state = ''
    $health = ''
    $waited = 0
    while ($waited -lt $WaitSeconds) {
        $id = Get-ContainerId
        if ($id -ne '') {
            $state = Get-ContainerField $id '{{.State.Status}}'
            $health = Get-ContainerField $id '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
            if ($health -eq 'healthy') { break }
            if ($state -eq 'exited' -or $state -eq 'dead' -or $state -eq 'restarting' -or $health -eq 'unhealthy') { break }
        }
        Start-Sleep -Seconds 1
        $waited++
    }
    if ($health -ne 'healthy') {
        Write-Host ''
        Write-Host "The node did not become healthy (state=$state, health=$health). Last log lines:" -ForegroundColor Red
        if ($id -ne '') {
            $tail = Get-DockerText -DockerArgs @('logs', '--tail', '25', $id)
            ($tail -split "`r?`n") | ForEach-Object { Write-Host "  | $_" }
        }
        Write-Host ''
        Write-Host "Hints: port $portNumber busy; the received folder not writable; see docs/dev/docker-install.md (Troubleshooting)."
        exit 1
    }
    Show-Summary $id $portNumber $data $aliasName $lanIp
}

function Invoke-Status {
    Test-Prerequisites
    $settings = Read-EnvMap
    $portNumber = 53318
    if ($settings.ContainsKey('LS_PORT')) { $portNumber = [int]$settings['LS_PORT'] }
    $script:EffectivePort = $portNumber
    $data = ''
    if ($settings.ContainsKey('LS_DATA_DIR')) { $data = $settings['LS_DATA_DIR'] }
    $aliasName = '?'
    if ($settings.ContainsKey('LS_ALIAS')) { $aliasName = $settings['LS_ALIAS'] }
    $lanIp = $HostIp
    if ($lanIp -eq '') { $lanIp = Get-PrimaryLanIp }
    if ($lanIp -eq '' -and $settings.ContainsKey('LS_HOST_IP')) { $lanIp = $settings['LS_HOST_IP'] }

    Write-Kv 'Project' "$Project (Docker Desktop, published ports)"
    $id = Get-ContainerId
    if ($id -eq '') {
        Write-Kv 'Container' 'not installed or removed (run: deploy\install.ps1)'
        exit 3
    }
    $state = Get-ContainerField $id '{{.State.Status}}'
    $health = Get-ContainerField $id '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
    Write-Kv 'Container' ('{0}  state={1} health={2}' -f (Get-ContainerField $id '{{.Name}}').TrimStart('/'), $state, $health)
    Write-Kv 'Started' (Get-ContainerField $id '{{.State.StartedAt}}')
    Write-Kv 'Image' (Get-ContainerField $id '{{.Config.Image}}')
    Write-Kv 'Alias / port' ('{0} / {1}' -f $aliasName, $portNumber)
    $link = Get-PublicLink (Get-RawLink $id) $lanIp
    if ($link -ne '') { Write-Kv 'Peer link' $link }
    if ($data -ne '' -and (Test-Path -LiteralPath $data)) {
        Write-Kv 'Received files' ('{0}  ({1})' -f $data, (Get-DirSummary $data))
    } else {
        Write-Kv 'Received files' "$data (folder missing)"
    }
    Write-FirewallHelp $portNumber
    if ($health -eq 'healthy') { exit 0 }
    Write-Host 'The node is not healthy. Last log lines:' -ForegroundColor Red
    $tail = Get-DockerText -DockerArgs @('logs', '--tail', '15', $id)
    ($tail -split "`r?`n") | ForEach-Object { Write-Host "  | $_" }
    exit 1
}

function Invoke-Uninstall {
    Test-Prerequisites
    $settings = Read-EnvMap
    $data = ''
    if ($settings.ContainsKey('LS_DATA_DIR')) { $data = ($settings['LS_DATA_DIR'] -replace '/', '\') }
    $configVolume = "${Project}_config"

    Write-Step "Stopping and removing the LibreShare container (project '$Project')"
    $code = Invoke-Compose -More @('down', '--remove-orphans')
    if ($code -ne 0) { Write-Warn 'docker compose down reported a problem (see above)' }

    $null = Get-DockerText -DockerArgs @('image', 'inspect', $Image)
    if ($script:LastCode -eq 0) {
        Write-Step "Removing image $Image"
        $null = Get-DockerText -DockerArgs @('image', 'rm', $Image)
        if ($script:LastCode -ne 0) { Write-Warn "could not remove $Image (still used by another LibreShare project?)" }
    }

    $delete = $false
    if ($data -ne '' -and (Test-Path -LiteralPath $data)) {
        if ($KeepData) {
            Write-Host ('Keeping received files: {0} ({1})' -f $data, (Get-DirSummary $data))
        } elseif (-not (Test-HasContent $data)) {
            $delete = $true   # nothing but our marker: nothing to lose
        } else {
            Write-Host ''
            Write-Host ('Received files are in: {0}  ({1})' -f $data, (Get-DirSummary $data))
            $answer = ''
            try { $answer = Read-Host "Type 'delete' to PERMANENTLY delete that folder, anything else keeps it [keep]" } catch { $answer = '' }
            if ($answer -ceq 'delete') { $delete = $true } else { Write-Host "Keeping $data" }
        }
        if ($delete) {
            if (Test-SafeToDelete $data) {
                Remove-Item -LiteralPath $data -Recurse -Force
                Write-Host "Deleted $data"
            } else {
                Write-Warn "not deleting ${data}: it was not created by this installer (no .libreshare-data marker) or it is a protected location. Remove it yourself if you want."
                $delete = $false
            }
        }
    }

    $null = Get-DockerText -DockerArgs @('volume', 'inspect', $configVolume)
    if ($script:LastCode -eq 0) {
        if ($delete) {
            $null = Get-DockerText -DockerArgs @('volume', 'rm', $configVolume)
            Write-Host "Removed state volume $configVolume"
        } else {
            Write-Host "Kept state volume $configVolume (empty in the prototype; it will hold the device identity later). Remove: docker volume rm $configVolume"
        }
    }
    if (Test-Path -LiteralPath $EnvFile) { Write-Host "Kept settings file $EnvFile (delete it for a fresh start)." }
    Write-Host 'Shared base images (dart, debian) and the build cache are left alone: docker image prune / docker builder prune.'
    Write-Host 'The firewall rules, if you created them, are yours to remove: Remove-NetFirewallRule -DisplayName "LibreShare node*"'
    Write-Host 'LibreShare uninstalled.' -ForegroundColor Green
}

# ----------------------------------------------------------------- main

if (-not (Test-Path -LiteralPath $ComposeFile)) {
    Stop-Script "missing $ComposeFile (run this script from a full checkout of the repository)"
}
$script:EffectivePort = 53318
if ($Status) {
    Invoke-Status
} elseif ($Uninstall) {
    Invoke-Uninstall
} else {
    Invoke-Install
}
