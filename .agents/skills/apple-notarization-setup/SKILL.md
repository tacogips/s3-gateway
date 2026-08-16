---
name: apple-notarization-setup
description: Use when setting up or verifying Apple Developer ID signing credentials, app-specific passwords, kinko secret storage, local keychain identities, notarytool credentials, or macOS notarization readiness for this Swift Homebrew Cask workflow without exposing credential values.
---

# Apple Notarization Setup

Use this skill before local Homebrew Cask DMG release builds.

## Credential Safety

- Never print, paste, commit, or summarize actual Apple passwords,
  app-specific passwords, certificate passwords, private keys, `.p12` contents,
  or kinko secret values.
- It is acceptable to mention secret key names such as `APPLE_ID`,
  `APPLE_PASSWORD`, `APPLE_TEAM_ID`, and `APPLE_SIGNING_IDENTITY`.
- When private login, passkey, or 2FA input is needed, ask the user to enter it
  directly in the browser or system dialog.
- Use `kinko exec --env ...` for commands that need secrets. Do not run commands
  that echo secret values.

## Required Local Inputs

The Cask DMG path expects:

- A valid Developer ID Application certificate imported into the macOS login keychain.
- `APPLE_SIGNING_IDENTITY` stored in kinko or another local secret store.
- `APPLE_ID` stored in kinko or another local secret store.
- `APPLE_TEAM_ID` stored in kinko or another local secret store.
- `APPLE_PASSWORD` stored as an Apple app-specific password.

Check presence only:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- bash -lc '
for key in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  if [ -n "${!key:-}" ]; then echo "$key=present"; else echo "$key=missing"; fi
done
'
```

Check local certificates:

```bash
security find-identity -v -p codesigning
```

Expect a valid `Developer ID Application` identity matching the stored identity
name.

## Local Build

Build signed, notarized, and stapled Cask DMGs:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

For a tagged release:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v<version>
```

## Notarization Status

When `notarytool` submits notarization, record only submission ids and status.
To check status:

```bash
kinko exec --env APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- bash -lc '
/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool info <submission-id> \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID"
'
```

Look for `status: Accepted`. If a submission stays `In Progress`, do not claim
deployment is complete.

## Validation After Acceptance

```bash
version="$(tr -d '[:space:]' < VERSION)"
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate "dist/homebrew-cask/s3-gateway-${version}-darwin-arm64.dmg"
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate "dist/homebrew-cask/s3-gateway-${version}-darwin-x64.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/homebrew-cask/s3-gateway-${version}-darwin-arm64.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/homebrew-cask/s3-gateway-${version}-darwin-x64.dmg"
```

Setup is complete when the secrets are present, the matching Developer ID
Application identity exists, both DMGs build successfully, and stapler plus
Gatekeeper validation pass for both DMGs.
