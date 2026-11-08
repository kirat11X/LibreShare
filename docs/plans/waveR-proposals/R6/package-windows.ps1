# tools/release/package-windows.ps1
# Builds Windows x64 release zip archive and SHA-256 checksum.
# Run from repository root in PowerShell.
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $RepoRoot) { $RepoRoot = Get-Location }
$DistDir = Join-Path $RepoRoot "dist"
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

Write-Host "=== Building LibreShare CLI for Windows x64 ==="
Set-Location (Join-Path $RepoRoot "packages\libreshare_cli")
dart pub get
$CliExe = Join-Path $DistDir "libreshare-cli.exe"
dart compile exe bin\ls.dart -o $CliExe

Write-Host "=== Building LibreShare Flutter Desktop for Windows x64 ==="
Set-Location (Join-Path $RepoRoot "apps\libreshare_app")
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release

$BundleDir = Join-Path $RepoRoot "apps\libreshare_app\build\windows\x64\runner\Release"
$ArchiveName = "libreshare-windows-x64.zip"
$ZipPath = Join-Path $DistDir $ArchiveName

Write-Host "=== Packaging $ArchiveName ==="
Compress-Archive -Path "$BundleDir\*" -DestinationPath $ZipPath -Force

Write-Host "=== Generating SHA-256 Checksums ==="
Set-Location $DistDir
$ZipHash = (Get-FileHash -Algorithm SHA256 $ArchiveName).Hash
"$ZipHash  $ArchiveName" | Out-File -FilePath "$ArchiveName.sha256" -Encoding ascii

$CliHash = (Get-FileHash -Algorithm SHA256 "libreshare-cli.exe").Hash
"$CliHash  libreshare-cli.exe" | Out-File -FilePath "libreshare-cli.exe.sha256" -Encoding ascii

Write-Host "Windows release artifacts built successfully in $DistDir"
Get-ChildItem $DistDir
