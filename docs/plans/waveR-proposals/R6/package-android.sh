#!/usr/bin/env bash
# tools/release/package-android.sh
# Builds Android release APK and SHA-256 checksum.
# Follows strict project safety rules: NO SIGNING KEYS IN THE REPO.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

cd "$REPO_ROOT/apps/libreshare_app"
flutter pub get

echo "=== Building LibreShare Android APK ==="
# Builds split APKs or universal fat APK
flutter build apk --release

APK_SRC="$REPO_ROOT/apps/libreshare_app/build/app/outputs/flutter-apk/app-release.apk"
APK_DEST="$DIST_DIR/libreshare-android.apk"

if [[ -f "$APK_SRC" ]]; then
  cp "$APK_SRC" "$APK_DEST"
  cd "$DIST_DIR"
  sha256sum "libreshare-android.apk" > "libreshare-android.apk.sha256"
  echo "Android APK packaged successfully: $APK_DEST"
  sha256sum -c "libreshare-android.apk.sha256"
else
  echo "Error: Release APK not found at $APK_SRC" >&2
  exit 1
fi
