# Security

Ankered talks to an Anker Prime 160W charger over Bluetooth LE using an unofficial, reverse-engineered protocol. It does not send telemetry off the Mac.

## Reporting a vulnerability

Please use [GitHub security advisories](https://github.com/djui/ankered/security/advisories/new) for anything that could expose session material, allow unexpected charger commands, or leak data from the Mac.

If that form is unavailable, open a [private report](https://github.com/djui/ankered/issues/new) without attaching packet captures that contain keys or decrypted payloads.

## What not to file publicly

- Session keys, nonces, or decrypted BLE payloads
- Full diagnostic dumps that include those fields
- Personal charger serial numbers unless you have already redacted them

Diagnostics in the app omit session keys and decrypted packet bodies on purpose. Keep issue reports the same way.
