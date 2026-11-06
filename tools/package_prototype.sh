#!/usr/bin/env bash
# Builds the release prototype for the platforms this host can build and collects the
# results in dist/prototype/ with SHA256SUMS.
#
#   tools/package_prototype.sh            # Linux (on a Linux host) + Android (if the SDK is present)
#   tools/package_prototype.sh linux      # only the Linux bundle
#   tools/package_prototype.sh android    # only the APKs
#
# Windows cannot be built from Linux (Flutter needs MSVC); the Windows zip comes from
# .github/workflows/prototype.yml (windows-latest runner) or from running this script's
# Windows branch on a Windows machine with Git Bash: `tools/package_prototype.sh windows`.
#
# Exit code is 0 only when every requested target built AND its artefact exists.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
# On GitHub runners (LS_CI=1) Flutter/Java/Android come from the workflow; tools/env.sh is the
# dev-box project-local toolchain and must not override them.
if [ -z "${LS_CI:-}" ]; then
  # shellcheck source=tools/env.sh
  source tools/env.sh >/dev/null 2>&1
fi

OUT="$ROOT/dist/prototype"
APP="$ROOT/apps/libreshare_app"
LOCK=/tmp/libreshare-flutter-build.lock
VERSION="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$APP/pubspec.yaml" | head -1)"
VERSION="${VERSION:-0.0.0}"

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  targets=(linux)
  if [ -d "${ANDROID_HOME:-/nonexistent}" ]; then targets+=(android); fi
fi

mkdir -p "$OUT"
failures=0

run_flutter() { # run_flutter <label> <args...>
  local label="$1"
  shift
  echo "==> $label"
  if command -v flock >/dev/null 2>&1; then
    (cd "$APP" && flock "$LOCK" flutter "$@")
  else
    (cd "$APP" && flutter "$@")
  fi
  local rc=$?
  echo "==> $label exit=$rc"
  return $rc
}

need() { # need <file> <what>
  if [ ! -s "$1" ]; then
    echo "MISSING artefact: $2 ($1)" >&2
    failures=$((failures + 1))
    return 1
  fi
}

build_linux() {
  run_flutter "flutter build linux --release" build linux --release || {
    failures=$((failures + 1))
    return
  }
  local bundle="$APP/build/linux/x64/release/bundle"
  local name="libreshare-$VERSION-linux-x64"
  local stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/$name"
  cp -a "$bundle/." "$stage/$name/"
  cat >"$stage/$name/README.txt" <<EOF
LibreShare $VERSION (prototype) - Linux x64
Run:  ./libreshare_app            (add --hidden to start in the tray)
Needs: GTK 3 (libgtk-3-0), libstdc++, glibc 2.31+; a tray needs an AppIndicator host
(GNOME: the "AppIndicator and KStatusNotifierItem Support" extension).
Firewall: allow UDP 53318 (discovery) and TCP 53317-53349 (transfers) on your private network.
Prototype: no encryption yet (Increment 3 adds it). Only use on a network you trust.
EOF
  tar -C "$stage" -czf "$OUT/$name.tar.gz" "$name"
  rm -rf "$stage"
  need "$OUT/$name.tar.gz" "Linux tarball"
}

build_android() {
  if [ ! -d "${ANDROID_HOME:-/nonexistent}" ]; then
    echo "ANDROID_HOME not set / missing: run tools/env.sh after installing the toolchain (docs/dev/android-toolchain.md)" >&2
    failures=$((failures + 1))
    return
  fi
  local apkdir="$APP/build/app/outputs/flutter-apk"
  # One universal APK (largest, installs anywhere) ...
  run_flutter "flutter build apk --release (universal)" build apk --release || {
    failures=$((failures + 1))
    return
  }
  cp "$apkdir/app-release.apk" "$OUT/libreshare-$VERSION-android-universal.apk"
  need "$OUT/libreshare-$VERSION-android-universal.apk" "universal APK"
  # ... and per-ABI APKs (about a third of the size each; arm64-v8a is what current phones need).
  run_flutter "flutter build apk --release --split-per-abi" build apk --release --split-per-abi || {
    failures=$((failures + 1))
    return
  }
  local abi
  for abi in arm64-v8a armeabi-v7a x86_64; do
    cp "$apkdir/app-$abi-release.apk" "$OUT/libreshare-$VERSION-android-$abi.apk" 2>/dev/null
    need "$OUT/libreshare-$VERSION-android-$abi.apk" "$abi APK"
  done
}

build_windows() {
  # Intended for a Windows host (Git Bash) or the windows-latest runner.
  run_flutter "flutter build windows --release" build windows --release || {
    failures=$((failures + 1))
    return
  }
  local rel="$APP/build/windows/x64/runner/Release"
  local name="libreshare-$VERSION-windows-x64"
  local zip="$OUT/$name.zip"
  rm -f "$zip"
  if command -v 7z >/dev/null 2>&1; then
    (cd "$rel" && 7z a -tzip "$zip" . >/dev/null)
  elif command -v zip >/dev/null 2>&1; then
    (cd "$rel" && zip -qr "$zip" .)
  else
    powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$rel")\\*' -DestinationPath '$(cygpath -w "$zip")' -Force"
  fi
  need "$zip" "Windows zip"
}

for t in "${targets[@]}"; do
  case "$t" in
    linux) build_linux ;;
    android) build_android ;;
    windows) build_windows ;;
    *) echo "unknown target: $t" >&2; failures=$((failures + 1)) ;;
  esac
done

(cd "$OUT" && : >SHA256SUMS && for f in *.tar.gz *.apk *.zip; do [ -f "$f" ] && sha256sum "$f" >>SHA256SUMS; done; true)
echo "---- $OUT"
ls -la "$OUT"
if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi
echo "OK"
exit 0
