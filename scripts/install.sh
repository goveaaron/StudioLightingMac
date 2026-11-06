#!/usr/bin/env bash
# Prism installer for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/goveaaron/StudioLightingMac/main/scripts/install.sh | bash
#
# Downloads the latest release, installs it to /Applications (or ~/Applications when
# /Applications isn't writable) and opens it. Re-run any time to update; your projects and
# settings are kept (they live in ~/Library/Application Support/Prism).
set -euo pipefail

REPO="goveaaron/StudioLightingMac"
URL="${PRISM_DOWNLOAD_URL:-https://github.com/$REPO/releases/latest/download/Prism.zip}"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Prism is a macOS app — run this on your Mac." >&2
  exit 1
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then
  echo "Prism needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading Prism…"
curl -fL --progress-bar "$URL" -o "$TMP/Prism.zip"
ditto -x -k "$TMP/Prism.zip" "$TMP/unpacked"
if [[ ! -d "$TMP/unpacked/Prism.app" ]]; then
  echo "The download didn't contain Prism.app — please try again." >&2
  exit 1
fi

DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

if pgrep -x Prism >/dev/null 2>&1; then
  echo "→ Closing the running copy of Prism (your lights keep their current look)…"
  pkill -TERM -x Prism || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Prism >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

rm -rf "$DEST/Prism.app"
mv "$TMP/unpacked/Prism.app" "$DEST/Prism.app"
echo "✓ Installed $(defaults read "$DEST/Prism.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '') to $DEST/Prism.app"
open "$DEST/Prism.app"
