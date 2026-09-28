#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-"$ROOT/docs/screenshots"}"
DERIVED="$ROOT/build/screenshots"

mkdir -p "$DEST" "$DERIVED"
ENTITLEMENTS="$(mktemp "$DERIVED/export-entitlements.XXXXXX")"

cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
</dict>
</plist>
EOF

xcodebuild \
  -project "$ROOT/AnkerPower.xcodeproj" \
  -scheme AnkerPower \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  ENABLE_APP_SANDBOX=NO \
  build

APP="$DERIVED/Build/Products/Release/AnkerPower.app"
if [[ ! -d "$APP" ]]; then
  echo "error: expected app at $APP" >&2
  exit 1
fi

# Pass --all-states as a second argument to also render every popover state for review.
"$APP/Contents/MacOS/AnkerPower" --export-screenshots "$DEST" "${@:2}"

echo "Wrote screenshots to $DEST"
for name in menubar menu settings history diagnostics screensaver; do
  ls -l "$DEST/$name.png" "$DEST/$name-dark.png"
done
