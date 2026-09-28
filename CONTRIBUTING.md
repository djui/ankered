# Contributing

Thanks for looking at Ankered. The useful changes are protocol fixes for A2687 firmware, UI polish, and diagnostics that stay free of secrets.

## Build

You need macOS 14+ and Xcode 15+.

```sh
open AnkerPower.xcodeproj
```

Select the `AnkerPower` scheme and **My Mac**, then Run. Grant Bluetooth permission when asked.

For UI work without a charger, add `--demo` to the scheme's launch arguments. The app then runs on sample data and never touches Bluetooth, so it cannot interfere with a copy that is connected.

```sh
xcodebuild -project AnkerPower.xcodeproj -scheme AnkerPower \
  -destination 'platform=macOS' test
```

Disconnect the official Anker app before testing live BLE. Only one client can normally use the charger.

## Pull requests

- Keep changes focused. Protocol parsing and UI are easier to review separately.
- Add or update tests in `AnkerPowerTests` when you change framing, crypto, or TLV decoding.
- Do not include session keys, decrypted packet bodies, or personal charger serials in issues, logs, or screenshots.
- The A2687 protocol is unofficial and firmware-dependent. Call out the firmware version you tested if you have it.
- After UI changes, refresh the README and landing-page images with `./scripts/export-screenshots.sh`. It writes light and dark variants (`menu.png`, `menu-dark.png`, …). To review every popover state (searching, paused, Bluetooth off, fault) in both appearances, export elsewhere with `./scripts/export-screenshots.sh /tmp/anker-shots --all-states`.

## Releases

Maintainers cut GitHub releases with:

```sh
./scripts/release.sh --publish 1.0.0
```

Omit `--publish` to only archive and zip locally.
