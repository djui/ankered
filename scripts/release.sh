#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUBLISH=0
VERSION=""

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--publish] [version]

  Archive AnkerPower.app, zip it, and write a SHA-256 checksum.
  With --publish, tag the current commit and create a GitHub Release.

Examples:
  scripts/release.sh
  scripts/release.sh 1.0.0
  scripts/release.sh --publish 1.0.0
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --publish)
      PUBLISH=1
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "error: unexpected argument: $arg" >&2
        usage >&2
        exit 1
      fi
      VERSION="$arg"
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\).*/\1/p' AnkerPower.xcodeproj/project.pbxproj | head -n 1)"
fi
if [[ -z "$VERSION" ]]; then
  echo "error: could not determine version (pass it as an argument)" >&2
  exit 1
fi

# Tag names are v1.0.0; MARKETING_VERSION may already be 1.0.
if [[ "$VERSION" == v* ]]; then
  TAG="$VERSION"
  VERSION="${VERSION#v}"
else
  TAG="v$VERSION"
fi

ARCHIVE_NAME="AnkerPower"
ZIP_NAME="AnkerPower-${VERSION}.zip"
OUT_DIR="$ROOT/release"
ARCHIVE_PATH="$OUT_DIR/$ARCHIVE_NAME.xcarchive"
APP_DIR="$OUT_DIR/$ARCHIVE_NAME.app"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
CHECKSUM_PATH="$ZIP_PATH.sha256"

if [[ "$PUBLISH" -eq 1 ]]; then
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: not a git repository" >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean; commit or stash before --publish" >&2
    git status --porcelain >&2
    exit 1
  fi
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Testing"
xcodebuild \
  -project AnkerPower.xcodeproj \
  -scheme AnkerPower \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  test

echo "==> Archiving $ARCHIVE_NAME $VERSION"
xcodebuild \
  -project AnkerPower.xcodeproj \
  -scheme AnkerPower \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  archive

if [[ ! -d "$ARCHIVE_PATH/Products/Applications/$ARCHIVE_NAME.app" ]]; then
  echo "error: archive did not contain $ARCHIVE_NAME.app" >&2
  find "$ARCHIVE_PATH" -maxdepth 4 -print >&2
  exit 1
fi

rm -rf "$APP_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/$ARCHIVE_NAME.app" "$APP_DIR"

echo "==> Ad-hoc signing with sandbox and Bluetooth entitlements"
# Archive with CODE_SIGNING_ALLOWED=NO only linker-signs the binary. That
# leaves Info.plist unbound and omits entitlements, so CoreBluetooth stays
# `.unauthorized` after the user accepts the Bluetooth prompt.
codesign --force --sign - \
  --entitlements "$ROOT/AnkerPower/AnkerPower.entitlements" \
  --options runtime \
  --identifier com.djui.AnkerPower \
  "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"

echo "==> Zipping $ZIP_NAME"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" | awk '{print $1 "  '"$ZIP_NAME"'"}' > "$CHECKSUM_PATH"

echo "Archive:  $ARCHIVE_PATH"
echo "App:      $APP_DIR"
echo "Zip:      $ZIP_PATH"
echo "Checksum: $(cat "$CHECKSUM_PATH")"

if [[ "$PUBLISH" -eq 0 ]]; then
  exit 0
fi

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
Native macOS menu-bar monitor for the Anker Prime Charger 160W (A2687).

## Included

- Live total and per-port power, voltage, and current over local Bluetooth LE
- Charging-mode picker and display settings (brightness, timeout, rotation, language)
- Port output on/off, shutdown timers, and Shortcuts
- Firmware, faults, device names, 24-hour history, charger curve, and CSV export
- Launch at login and optional idle-port notification
- About panel with app version and homepage link; Diagnostics opens from Settings
- Native macOS app icon for Finder, Spotlight, and app listings
- Current Anker-app handshake with AES-CBC fallback from [Anker-BLE](https://github.com/T-REX-XP/Anker-BLE)

## Changes

- About shows the version number and a link to the product page
- Diagnostics moved into Settings; History sits above Settings in the menus

## Not included

- Firmware updates, cloud protocol management, other Anker models
- iOS / Windows / Linux, Home Assistant, or notarized / App Store builds

## Install

Unzip \`AnkerPower-${VERSION}.zip\` and move \`AnkerPower.app\` to \`/Applications\`. The build is ad-hoc signed and not notarized: right-click the app and choose **Open** the first time.

Protocol work is derived from Anker-BLE (MIT). See \`THIRD_PARTY_NOTICES.md\`. Not affiliated with Anker Innovations.
EOF

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists" >&2
  exit 1
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Anker Power $VERSION"
git push origin HEAD
git push origin "$TAG"

echo "==> Creating GitHub Release $TAG"
gh release create "$TAG" \
  --title "Anker Power $VERSION" \
  --notes-file "$NOTES" \
  "$ZIP_PATH" \
  "$CHECKSUM_PATH"

echo "Published https://github.com/djui/ankered/releases/tag/$TAG"
