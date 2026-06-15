# Security

Airlift runs entirely on-device. There is no server, no telemetry and no account
system — the only network traffic is the OAuth (PKCE) handshake and read-only
Google Health API calls to Google. The refresh token is stored in the iOS Keychain
with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it never leaves the
device and is excluded from backups and device transfers.

## Reporting a vulnerability

Please report security issues **privately** to **airlift@santekotturi.com** rather
than opening a public issue.

**In scope:** the OAuth/PKCE flow, Keychain token handling, and anything that could
move health data off the device or expose it to other apps.

**Out of scope:** issues in the pre-GA Google Health API itself (report those to
Google), and schema-mismatch bugs — those are ordinary bug reports.
