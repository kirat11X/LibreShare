#!/usr/bin/env bash
# tools/release/package-linux.sh
# Builds Linux x86_64 release tarball and SHA-256 checksum.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

echo "=== Building LibreShare CLI for Linux x64 ==="
cd "$REPO_ROOT/packages/libreshare_cli"
dart pub get
dart compile exe bin/ls.dart -o "$DIST_DIR/libreshare-cli"

echo "=== Building LibreShare Flutter Desktop for Linux x64 ==="
cd "$REPO_ROOT/apps/libreshare_app"
flutter config --enable-linux-desktop
flutter pub get
flutter build linux --release

BUNDLE_DIR="$REPO_ROOT/apps/libreshare_app/build/linux/x64/release/bundle"
ARCHIVE_NAME="libreshare-linux-x64.tar.gz"
echo "=== Packaging $ARCHIVE_NAME ==="
tar -czf "$DIST_DIR/$ARCHIVE_NAME" -C "$BUNDLE_DIR" .

echo "=== Generating SHA-256 Checksums ==="
cd "$DIST_DIR"
sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
sha256sum "libreshare-cli" > "libreshare-cli.sha256"

echo "Release artifacts built successfully in $DIST_DIR:"
ls -lh "$DIST_DIR"/*
