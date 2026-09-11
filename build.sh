#!/usr/bin/env bash
# Builds Lidfold.app from the SwiftPM package. No Xcode needed; the Metal
# shader compiles at runtime.
#
#   ./build.sh              build build/Lidfold.app (ad-hoc signed, arm64)
#   ./build.sh --universal  build for Apple silicon and Intel
#   ./build.sh --zip        also write build/Lidfold-<version>.zip for a release
#   ./build.sh --install    also copy to /Applications
#   ./build.sh --run        also (re)launch it
#
# Signs with a local "Lidfold Local Signing" identity, created on first run,
# so every build carries the same identity and macOS keeps the Screen
# Recording grant across rebuilds. Set SIGN_IDENTITY to use your own.
set -euo pipefail
cd "$(dirname "$0")"

# A stable identity keeps the Screen Recording grant across rebuilds. Ad-hoc
# signing changes identity every build and forces a fresh grant each time.
# scripts/make-signing-identity.sh creates the local one.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  security find-certificate -c "Lidfold Local Signing" >/dev/null 2>&1 || "$(dirname "$0")/scripts/make-signing-identity.sh"
  SIGN_IDENTITY="Lidfold Local Signing"
fi
APP="build/Lidfold.app"
INSTALL=false; RUN=false; ZIP=false
ARCH=()
for a in "$@"; do case "$a" in
  --install) INSTALL=true;; --run) RUN=true;; --zip) ZIP=true;;
  --universal) ARCH=(--arch arm64 --arch x86_64);;
  *) echo "unknown: $a" >&2; exit 1;; esac; done

# ${ARCH[@]+...} keeps bash 3.2 happy with an empty array under set -u.
swift build -c release --product Lidfold ${ARCH[@]+"${ARCH[@]}"}
BIN="$(swift build -c release --show-bin-path ${ARCH[@]+"${ARCH[@]}"})/Lidfold"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lidfold"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

TS=--timestamp; [[ "$SIGN_IDENTITY" == - ]] && TS=--timestamp=none
codesign --force --options runtime $TS --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if $ZIP; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  ditto -c -k --keepParent "$APP" "build/Lidfold-$VERSION.zip"
  echo "zipped build/Lidfold-$VERSION.zip"
fi

TARGET="$APP"
if $INSTALL; then
  pkill -x Lidfold 2>/dev/null || true
  rm -rf /Applications/Lidfold.app
  cp -R "$APP" /Applications/Lidfold.app
  # Ad-hoc signatures change per build, so the old Screen Recording grant no
  # longer matches. Clear it so the next grant attaches to this build.
  if [[ "$SIGN_IDENTITY" == - ]]; then
    tccutil reset ScreenCapture com.colehollander.lidfold >/dev/null 2>&1 || true
  fi
  TARGET=/Applications/Lidfold.app
  echo "installed $TARGET"
fi
if $RUN; then
  pkill -x Lidfold 2>/dev/null || true
  sleep 0.3
  open "$TARGET"
  echo "launched $TARGET"
fi
