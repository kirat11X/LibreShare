#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/apps/libreshare_app"
BUILDS_DIR="$REPO_ROOT/builds"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "=== Verifying Xcode and CocoaPods ==="
xcodebuild -version
pod --version

echo "=== Building LibreShare for macOS ==="
cd "$APP_DIR"
flutter config --enable-macos-desktop
flutter pub get
flutter build macos --release

MACOS_APP=""
for candidate in \
  "$APP_DIR/build/macos/Build/Products/Release/LibreShare.app" \
  "$APP_DIR/build/macos/Build/Products/Release/libreshare_app.app"; do
  if [ -d "$candidate" ]; then
    MACOS_APP="$candidate"
    break
  fi
done

if [ -z "$MACOS_APP" ]; then
  echo "Error: macOS .app bundle not found" >&2
  exit 1
fi

echo "Packaging macOS release zip into builds/libreshare-1.0.0-macos.zip..."
rm -f "$BUILDS_DIR/libreshare-1.0.0-macos.zip"
(cd "$(dirname "$MACOS_APP")" && zip -qry "$BUILDS_DIR/libreshare-1.0.0-macos.zip" "$(basename "$MACOS_APP")")

echo "=== Building LibreShare for iOS (iPhone) ==="
cd "$APP_DIR"
flutter build ios --no-codesign --release

IOS_APP="$APP_DIR/build/ios/iphoneos/Runner.app"
if [ ! -d "$IOS_APP" ]; then
  echo "Error: iOS Runner.app not found at $IOS_APP" >&2
  exit 1
fi

echo "Packaging iOS release IPA into builds/libreshare-1.0.0-ios.ipa..."
rm -f "$BUILDS_DIR/libreshare-1.0.0-ios.ipa"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -a "$IOS_APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$BUILDS_DIR/libreshare-1.0.0-ios.ipa" Payload)
rm -rf "$STAGE"

echo "=== Updating SHA256SUMS in builds/ ==="
cd "$BUILDS_DIR"
# Regenerate checksums for all release archives
: > SHA256SUMS.tmp
for f in *.apk *.tar.gz *.zip *.ipa; do
  if [ -f "$f" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$f" >> SHA256SUMS.tmp
    else
      shasum -a 256 "$f" >> SHA256SUMS.tmp
    fi
  fi
done
mv SHA256SUMS.tmp SHA256SUMS

echo "=== Completed Apple Builds ==="
ls -lh "$BUILDS_DIR"/libreshare-1.0.0-macos.zip "$BUILDS_DIR"/libreshare-1.0.0-ios.ipa
