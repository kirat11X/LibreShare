#!/usr/bin/env bash
# tools/release/package-macos.sh
# Builds macOS release bundle (.app in .zip) and SHA-256 checksum.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Error: xcodebuild is required to build for macOS." >&2
  echo "Please install Xcode from the Mac App Store or developer.apple.com and run:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

echo "=== Building LibreShare CLI for macOS ==="
cd "$REPO_ROOT/packages/libreshare_cli"
dart pub get
dart compile exe bin/ls.dart -o "$DIST_DIR/libreshare-cli-macos"

echo "=== Building LibreShare Flutter Desktop for macOS ==="
cd "$REPO_ROOT/apps/libreshare_app"
flutter config --enable-macos-desktop
flutter pub get
flutter build macos --release

APP_PATH=""
for candidate in \
  "$REPO_ROOT/apps/libreshare_app/build/macos/Build/Products/Release/LibreShare.app" \
  "$REPO_ROOT/apps/libreshare_app/build/macos/Build/Products/Release/libreshare_app.app"; do
  if [ -d "$candidate" ]; then
    APP_PATH="$candidate"
    break
  fi
done

if [ -z "$APP_PATH" ]; then
  echo "Error: Could not locate built .app bundle in build/macos/Build/Products/Release/" >&2
  exit 1
fi

ARCHIVE_NAME="libreshare-macos.zip"
echo "=== Packaging $ARCHIVE_NAME from $(basename "$APP_PATH") ==="
(cd "$(dirname "$APP_PATH")" && zip -qry "$DIST_DIR/$ARCHIVE_NAME" "$(basename "$APP_PATH")")

echo "=== Generating SHA-256 Checksums ==="
cd "$DIST_DIR"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
  sha256sum "libreshare-cli-macos" > "libreshare-cli-macos.sha256"
else
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
  shasum -a 256 "libreshare-cli-macos" > "libreshare-cli-macos.sha256"
fi

echo "Release artifacts built successfully in $DIST_DIR:"
ls -lh "$DIST_DIR"/*macos*
