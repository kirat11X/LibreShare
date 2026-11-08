# Card R6 Apply Notes: Release Packaging Scripts

## Files Touched
- `tools/release/package-linux.sh` (new)
- `tools/release/package-android.sh` (new)
- `tools/release/package-windows.ps1` (new)

## Security & Credentials
- NO SIGNING KEYS ARE STORED IN REPOSITORY.
- Uses external CI secrets or local keystores passed via environment variables.
- Generates reproducible companion `.sha256` checksum files for every artifact.
