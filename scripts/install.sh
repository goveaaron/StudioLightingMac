#!/usr/bin/env bash
# Prism installer for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/goveaaron/StudioLightingMac/main/scripts/install.sh | bash
#
# Downloads the latest release, checks it, installs it to /Applications (or ~/Applications when
# /Applications isn't writable) and opens it. Re-run any time to update; your projects and
# settings are kept (they live in ~/Library/Application Support/Prism).
#
# Environment overrides (mostly for testing):
#   PRISM_DOWNLOAD_URL   zip to install (default: the latest GitHub release)
#   PRISM_INSTALL_DIR    install folder (default: /Applications, else ~/Applications)
#   PRISM_NO_OPEN=1      don't open Prism after installing
set -euo pipefail

REPO="goveaaron/StudioLightingMac"
URL="${PRISM_DOWNLOAD_URL:-https://github.com/$REPO/releases/latest/download/Prism.zip}"

fail() { echo "✗ $*" >&2; exit 1; }

if [[ "$(uname)" != "Darwin" ]]; then
  fail "Prism is a macOS app — run this on your Mac."
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then
  fail "Prism needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading Prism…"
curl -fL --retry 3 --retry-delay 2 --progress-bar "$URL" -o "$TMP/Prism.zip" \
  || fail "Couldn't download Prism. Check your internet connection and try again."

# Every release publishes Prism.zip.sha256 next to the zip: verify it when it's available.
if curl -fsSL --retry 2 "$URL.sha256" -o "$TMP/Prism.zip.sha256" 2>/dev/null; then
  expected="$(awk '{print $1; exit}' "$TMP/Prism.zip.sha256")"
  actual="$(shasum -a 256 "$TMP/Prism.zip" | awk '{print $1}')"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    fail "The download looks damaged (checksum mismatch). Please run the installer again."
  fi
  echo "✓ Download verified"
fi

ditto -x -k "$TMP/Prism.zip" "$TMP/unpacked" || fail "Couldn't unpack the download — please try again."
if [[ ! -d "$TMP/unpacked/Prism.app" ]]; then
  fail "The download didn't contain Prism.app — please try again."
fi
# curl doesn't quarantine downloads, but strip the flag anyway so macOS never blocks the app.
xattr -dr com.apple.quarantine "$TMP/unpacked/Prism.app" 2>/dev/null || true

DEST="${PRISM_INSTALL_DIR:-/Applications}"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

if pgrep -x Prism >/dev/null 2>&1; then
  echo "→ Closing the running copy of Prism (your lights keep their current look)…"
  pkill -TERM -x Prism 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x Prism >/dev/null 2>&1 || break
    sleep 0.5
  done
  pkill -KILL -x Prism 2>/dev/null || true
fi

# Swap the new app in, keeping the old one until the new one is in place.
if [[ -e "$DEST/Prism.app" ]]; then
  mv "$DEST/Prism.app" "$TMP/Prism-previous.app" \
    || fail "Couldn't replace $DEST/Prism.app — quit Prism and run the installer again."
fi
if ! mv "$TMP/unpacked/Prism.app" "$DEST/Prism.app"; then
  [[ -e "$TMP/Prism-previous.app" ]] && mv "$TMP/Prism-previous.app" "$DEST/Prism.app"
  fail "Couldn't install to $DEST — your previous copy of Prism was kept."
fi

version="$(defaults read "$DEST/Prism.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
echo "✓ Installed Prism ${version} to $DEST/Prism.app"

if [[ "${PRISM_NO_OPEN:-0}" != "1" ]]; then
  open "$DEST/Prism.app"
fi
