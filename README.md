# Anker Power

A native macOS menu-bar monitor for the Anker Prime Charger 160W with Smart Display (A2687).

The app connects locally over Bluetooth LE and displays:

- Total and per-port power
- Per-port voltage and current
- Per-port output shutdown and a shutdown timer
- All three port values directly in the menu-bar title
- Generic USB-C 1, 2, and 3 labels
- A rolling 24-hour charging-power graph and delivered-energy estimate
- A live connection-diagnostics window with copyable Bluetooth and protocol events

The charger does not report the name of a connected device, so port labels remain generic.

## Requirements

- macOS 14 or newer
- Xcode 15 or newer
- Anker Prime Charger 160W, model A2687

## Build and run

1. Open `AnkerPower.xcodeproj` in Xcode.
2. Select the `AnkerPower` scheme and **My Mac**.
3. Run the app.
4. Grant Bluetooth permission when macOS asks.
5. Disconnect the charger from the official Anker mobile app, because only one BLE client can normally use it at a time.

If connection fails, open **Diagnostics** from the menu-bar panel. It shows scanning, GATT discovery, handshake stages, command metadata, and errors. **Copy All** produces a report suitable for an issue without including session keys or decrypted packet bodies.

The application is an accessory app (`LSUIElement`) and therefore appears only in the menu bar.

From Terminal, compile and run tests with:

```sh
xcodebuild -project AnkerPower.xcodeproj -scheme AnkerPower \
  -destination 'platform=macOS' test
```

## Protocol status

This is an unofficial implementation. The A2687 BLE protocol is not a public Anker API and may change with charger firmware. The app first performs the current app-compatible, ephemeral P-256 ECDH/AES-GCM session and polls `0x020A`/`0x0200`. If that handshake does not answer, it falls back to the older AES-CBC flow and `0x4200` telemetry subscription documented by the MIT-licensed `T-REX-XP/Anker-BLE` proof of concept.

Port control uses the official minicharge commands `0x0207` (output on/off) and `0x0209` (shutdown timer in seconds). Those writes are available only on the AES-GCM session. Firmware-update commands are not included.

## Privacy

All charger telemetry and history remain on the Mac. Up to 24 hours of samples are stored in the app's Application Support container. The app makes no network requests.
