#!/usr/bin/env bash
# Assemble Prism.app from the SwiftPM build (macOS only).
#
# Usage: scripts/build_app.sh [--release] [--universal] [--version X.Y.Z] [--build N] [--out DIR]
#   --release    optimized build (default: debug — fastest for CI smoke tests)
#   --universal  arm64 + x86_64 (two builds merged with lipo)
#   --version    CFBundleShortVersionString (default 0.1.0 or $PRISM_VERSION)
#   --build      CFBundleVersion (default 0 or $PRISM_BUILD)
#   --out        output directory (default ./dist)
# Result: <out>/Prism.app, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
UNIVERSAL=0
VERSION="${PRISM_VERSION:-0.1.0}"
BUILD="${PRISM_BUILD:-0}"
OUT=dist
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --universal) UNIVERSAL=1 ;;
    --version) VERSION="$2"; shift ;;
    --build) BUILD="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "build_app.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname)" != "Darwin" ]]; then
  echo "build_app.sh must run on macOS" >&2
  exit 1
fi

APP="$OUT/Prism.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building Prism ($CONFIG, universal=$UNIVERSAL)"
if [[ $UNIVERSAL == 1 ]]; then
  bins=()
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build -c "$CONFIG" --product Prism --triple "$triple"
    bins+=("$(swift build -c "$CONFIG" --product Prism --triple "$triple" --show-bin-path)/Prism")
  done
  lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/Prism"
else
  swift build -c "$CONFIG" --product Prism
  cp "$(swift build -c "$CONFIG" --show-bin-path)/Prism" "$APP/Contents/MacOS/Prism"
fi
chmod +x "$APP/Contents/MacOS/Prism"

echo "==> Info.plist ($VERSION build $BUILD)"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Support/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Resources"
# Everything under Resources/ (fixture library, web remote, templates…) is looked up at
# runtime through AppResources (never Bundle.module).
ditto Resources "$APP/Contents/Resources"
find "$APP/Contents/Resources" \( -name '.DS_Store' -o -name 'node_modules' \) -prune -exec rm -rf {} +

ICON_SRC=Support/AppIcon.png
if [[ -f "$ICON_SRC" ]]; then
  echo "==> App icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
lipo -info "$APP/Contents/MacOS/Prism" || true
du -sh "$APP" | cut -f1
