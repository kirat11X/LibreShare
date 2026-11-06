# source tools/env.sh  -- puts the project-local Flutter/Dart toolchain on PATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PUB_CACHE="$ROOT/.toolchain/pub-cache"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true CI=${CI:-}
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export no_proxy="*" NO_PROXY="*"

# --- Android toolchain (project-local, sudo-free; see docs/dev/android-toolchain.md) ---
# Temurin 17 (Flutter's Gradle needs 17-21; the system Java is too new), the Android SDK, and
# a project-local Gradle cache. Nothing here is written outside $ROOT/.toolchain, and
# `flutter config` is deliberately never used: Flutter finds the SDK/JDK through these variables.
export JAVA_HOME="$ROOT/.toolchain/jdk-17"
export ANDROID_HOME="$ROOT/.toolchain/android-sdk"
# `flutter doctor` flags an SDK path containing spaces as an error (NDK tools break on it), and
# this repo's directory name has spaces. Opt-in fix, created by the developer, not by this script:
#   ln -s "$PWD/.toolchain/android-sdk" "$HOME/.libreshare-android-sdk"
# If that symlink exists and points at the project SDK, use it as the SDK path.
_ls_sdk_link="${LS_ANDROID_SDK_LINK:-$HOME/.libreshare-android-sdk}"
if [ -L "$_ls_sdk_link" ] && [ "$(readlink -f "$_ls_sdk_link")" = "$(readlink -f "$ANDROID_HOME")" ]; then
  ANDROID_HOME="$_ls_sdk_link"
fi
unset _ls_sdk_link
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export GRADLE_USER_HOME="$ROOT/.toolchain/gradle"
# Prepend only if absent so re-sourcing this file does not grow PATH.
# Listed lowest priority first; Flutter/Dart end up first on PATH, as before.
for _ls_dir in \
  "$ANDROID_HOME/cmdline-tools/latest/bin" \
  "$ANDROID_HOME/platform-tools" \
  "$JAVA_HOME/bin" \
  "$ROOT/.toolchain/flutter/bin/cache/dart-sdk/bin" \
  "$ROOT/.toolchain/flutter/bin"; do
  case ":$PATH:" in
    *":$_ls_dir:"*) ;;
    *) PATH="$_ls_dir:$PATH" ;;
  esac
done
export PATH
unset _ls_dir
