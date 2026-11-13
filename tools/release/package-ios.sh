#!/usr/bin/env bash
# tools/release/package-ios.sh
# Builds iOS iPhone release bundle (.ipa unsigned) and SHA-256 checksum.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Error: xcodebuild is required to build for iOS." >&2
  echo "Please install Xcode from the Mac App Store or developer.apple.com and run:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

echo "=== Building LibreShare Flutter App for iOS (iPhone) ==="
cd "$REPO_ROOT/apps/libreshare_app"
flutter pub get
flutter build ios --no-codesign --release

APP_PATH="$REPO_ROOT/apps/libreshare_app/build/ios/iphoneos/Runner.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: Could not locate built Runner.app in build/ios/iphoneos/" >&2
  exit 1
fi

ARCHIVE_NAME="libreshare-ios.ipa"
echo "=== Packaging $ARCHIVE_NAME ==="
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -a "$APP_PATH" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$DIST_DIR/$ARCHIVE_NAME" Payload)
rm -rf "$STAGE"

echo "=== Generating SHA-256 Checksums ==="
cd "$DIST_DIR"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
else
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
fi

echo "iOS release package built successfully in $DIST_DIR:"
ls -lh "$DIST_DIR"/*ios*
