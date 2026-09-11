#!/usr/bin/env bash
# Installs the latest Lidfold release into /Applications and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/colehollander10-netizen/lidfold/main/install.sh | bash
#
# The app is not notarized, so this clears the quarantine flag that would
# otherwise make macOS refuse to open it. Read the script before running it;
# it is short.
set -euo pipefail
REPO="colehollander10-netizen/lidfold"
APP="/Applications/Lidfold.app"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Lidfold's release build is for Apple silicon MacBooks. On Intel, build from source: https://github.com/$REPO#build-from-source" >&2
  exit 1
fi

URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*Lidfold-[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[[ -n "$URL" ]] || { echo "could not find a release zip" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "downloading ${URL##*/}"
curl -fsSL "$URL" -o "$TMP/Lidfold.zip"
ditto -x -k "$TMP/Lidfold.zip" "$TMP/out"
[[ -d "$TMP/out/Lidfold.app" ]] || { echo "zip did not contain Lidfold.app" >&2; exit 1; }

pkill -x Lidfold 2>/dev/null || true
rm -rf "$APP"
ditto "$TMP/out/Lidfold.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"
echo "installed $APP and opened it. macOS will ask for Screen Recording once; turn Lidfold on and it relaunches itself."
