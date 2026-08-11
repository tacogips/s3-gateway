---
name: ios-ipados-app-deploy
description: Use when preparing, signing, exporting, uploading, or verifying an iPhone/iPad Swift app deployment through Xcode, Apple Developer signing, App Store Connect, and TestFlight, including bundle ID changes, Apple Distribution certificates, provisioning, physical device checks, IPA export, upload processing, export compliance, and non-secret release evidence.
---

# iOS/iPadOS App Deploy

Use this skill for iPhone/iPad deployment work that crosses local Xcode tooling,
Apple Developer signing, App Store Connect, TestFlight, and physical devices.

## Safety Rules

- Never print, paste, commit, or summarize Apple account passwords,
  app-specific passwords, session tokens, API keys, certificate private keys,
  `.p12` contents, provisioning profile contents, full UDIDs, serial numbers, or
  private tester/reviewer identifiers.
- It is acceptable to mention secret key names and presence-only status.
- Prefer `kinko exec --env ...` or the repo's established secret wrapper for
  commands that need Apple credentials.
- Do not overwrite a generic macOS signing key such as
  `APPLE_SIGNING_IDENTITY` with an iOS Distribution identity unless the repo
  explicitly uses that key for iOS. Prefer an app- or platform-specific key such
  as `IOS_DISTRIBUTION_SIGNING_IDENTITY` or a repo-prefixed variant.
- For browser or Xcode account actions that create, submit, or change external
  Apple state, get clear user confirmation before the final click.

## First Pass Audit

Identify the repo's actual names before acting:

```bash
find . -maxdepth 3 \( -name '*.xcodeproj' -o -name '*.xcworkspace' -o -name 'Package.swift' -o -name 'mise.toml' \) -print
rg -n 'PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|MARKETING_VERSION|CURRENT_PROJECT_VERSION|CFBundleDisplayName|CFBundleName|ITSAppUsesNonExemptEncryption' .
rg -n 'check:ios|archive:ios|export:ios|testflight|app-store|physical-device|APPLE_|SIGNING_IDENTITY|TEAM_ID' mise.toml scripts .github 2>/dev/null
```

Record:

- Xcode project/workspace, scheme, configuration, bundle ID, app version/build.
- Apple team source (`DEVELOPMENT_TEAM`, `APPLE_TEAM_ID`, Xcode account).
- Existing signing identities and whether they are macOS Developer ID,
  Apple Development, or Apple Distribution.
- Existing archive/export/readiness tasks and evidence paths.
- Connected physical iPhone/iPad status.

## Bundle ID And App Names

Keep these concepts separate:

- **Seller/provider name**: the Apple Developer Program account or team legal
  name shown as the app's provider. Changing it is account/business work, not a
  repo setting.
- **App Store Connect app name**: the public listing name. It must be unique
  enough for Apple. If the desired name is taken, choose a nearby available
  listing name and update local metadata drafts to match.
- **Bundle ID**: the reverse-DNS identifier used by signing, provisioning,
  entitlements, App ID, App Store Connect, CloudKit, and uploaded builds. Change
  it before creating irreversible App Store Connect/build state when possible.

When changing a bundle ID, update all repo-owned references consistently:

```bash
rg -n '<old.bundle.id>|iCloud\.<old.bundle.id>' . -g '!**/.git/**' -g '!**/.build/**'
```

Then check Xcode build settings, entitlements, export options, metadata drafts,
release checklists, CloudKit containers, and scripts. Re-run the search until no
old app identifier remains, excluding intentional historical notes.

## Signing Setup

Use Xcode Settings > Accounts to confirm:

- The Apple ID is signed in.
- The intended Apple Developer team is present and selectable.
- The app target uses the intended team.
- Automatic signing can create or refresh development provisioning.

Required local signing state:

- Apple Distribution certificate with private key in the login keychain.
- App ID/provisioning profile for the bundle ID.
- Physical iPhone/iPad trusted by the Mac for device builds and install checks.

When an App ID capability or container assignment changes, treat every affected
provisioning profile as stale. Regenerate, download, install, and inspect the
replacement profile before archiving. Fail closed if the app's signed
entitlements request a capability that the selected profile does not contain.
Keep profile contents, UUIDs, and downloaded profile files out of Git and
release evidence.

Check identities without exposing secrets:

```bash
security find-identity -v -p codesigning
```

Expect distinct identities for different signing domains, for example:

- `Developer ID Application` for macOS distribution/notarization.
- `Apple Development` for local device debug builds.
- `Apple Distribution` for App Store Connect archives/exports.

Store the iOS Distribution identity under an iOS-specific secret key if the repo
uses a secret store:

```bash
kinko set --shared IOS_DISTRIBUTION_SIGNING_IDENTITY
kinko get IOS_DISTRIBUTION_SIGNING_IDENTITY
```

The `get` output should be masked or presence-only.

## Local Build And Export

Prefer project-provided tasks. A good command path is:

```bash
mise run check:ios-signing
mise run archive:ios-app-signed
mise run export:ios-app
mise run check:testflight-readiness
```

If the repo uses signing secrets, wrap only the needed commands:

```bash
kinko exec --env IOS_DISTRIBUTION_SIGNING_IDENTITY,APPLE_TEAM_ID -- mise run check:ios-signing
kinko exec --env IOS_DISTRIBUTION_SIGNING_IDENTITY,APPLE_TEAM_ID -- mise run archive:ios-app-signed
kinko exec --env IOS_DISTRIBUTION_SIGNING_IDENTITY,APPLE_TEAM_ID -- mise run export:ios-app
```

If no task exists, use `xcodebuild` with automatic signing and avoid hardcoding
an incompatible certificate name:

```bash
xcodebuild \
  -project <App>.xcodeproj \
  -scheme <Scheme> \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .build/xcode-archives/<Scheme>.xcarchive \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  archive

xcodebuild -exportArchive \
  -archivePath .build/xcode-archives/<Scheme>.xcarchive \
  -exportPath .build/xcode-exports/<Scheme> \
  -exportOptionsPlist <ExportOptions>.plist \
  -allowProvisioningUpdates
```

Validate archive metadata with `plutil` and exported IPA presence. Do not record
team IDs, certificate serials, profile contents, or device identifiers in final
evidence.

## Physical iPhone/iPad Checks

Use a real trusted device before claiming deploy readiness:

```bash
xcrun devicectl list devices
xcodebuild -showdestinations -project <App>.xcodeproj -scheme <Scheme>
```

If a physical device build fails with Developer Mode or trust errors, report the
exact blocker and ask the user to enable Developer Mode or trust the Mac on the
device. After the device appears as available, run a device build/install check
through the repo task or `xcodebuild -destination 'platform=iOS,id=<device-id>'`.

Record only redacted model class and OS version in evidence. Do not record full
UDIDs or serial numbers.

## TestFlight Device Verification

Do not replace TestFlight install evidence with a local `devicectl install`.
Installing a local `.app` or `.ipa` can prove signing/launch diagnostics, but it
does not prove the build was installed through TestFlight.

After the user installs the processed TestFlight build from the TestFlight app
on a physical iPhone or iPad, automate the parts that are safe to automate:

```bash
xcrun devicectl list devices
xcrun devicectl device info apps \
  --device '<trusted device name>' \
  --bundle-id '<bundle.id>' \
  --json-output .build/testflight-device/apps.json
xcrun devicectl device process launch \
  --device '<trusted device name>' \
  '<bundle.id>' \
  --terminate-existing \
  --json-output .build/testflight-device/launch.json
```

Prefer a repo task if one exists, for example:

```bash
rg -n 'testflight.*device|device.*testflight|devicectl device info apps|devicectl device process launch' mise.toml scripts
mise run check:testflight-ipad-device -- '<trusted iPad name>'
```

A good automated check verifies:

- the expected bundle ID is installed on the trusted physical device;
- the installed app version/build matches the uploaded TestFlight build when
  available from `devicectl` app metadata;
- launching the app by bundle ID succeeds and writes JSON/log artifacts under
  `.build/` or the repo's diagnostic output directory;
- output and evidence redact full device identifiers, serials, Apple account
  emails, tester identifiers, and tokens.

Keep a manual gate for anything that requires seeing or touching the device UI:
accepting the TestFlight invitation, pressing Install in TestFlight, opening
camera permission prompts, granting camera access, and confirming the main UI is
visible. Record `devicectl` JSON/log paths as supporting evidence only after
the manual UI checks pass.

## App Store Connect And TestFlight

Create the App Store Connect record only after the bundle ID and team are
settled. Use:

- Platform: iOS.
- Name: the intended public listing name, or an available variant if Apple
  reports the name is already used.
- Primary language: the repo metadata's primary locale.
- Bundle ID: the exact bundle ID from the signed archive.
- SKU: a stable non-secret SKU from metadata or repo convention.
- Access: full access unless the user asks for limited access.

After the app record exists, validate and upload the IPA using the repo's
preferred uploader, Xcode Organizer, Transporter, or an App Store Connect API
key workflow. Do not use deprecated `altool` as the primary release path;
retain it only for repositories that still require it for comparison or
transport diagnosis:

```bash
kinko exec --env APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- bash -lc '
xcrun altool --validate-app \
  -f .build/xcode-exports/<Scheme>/<Scheme>.ipa \
  -u "$APPLE_ID" \
  -p @env:APPLE_PASSWORD \
  --type ios \
  --team-id "$APPLE_TEAM_ID"
'

kinko exec --env APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- bash -lc '
xcrun altool --upload-app \
  -f .build/xcode-exports/<Scheme>/<Scheme>.ipa \
  -u "$APPLE_ID" \
  -p @env:APPLE_PASSWORD \
  --type ios \
  --team-id "$APPLE_TEAM_ID"
'
```

If validation says it cannot determine the app from the bundle ID, verify that
the App Store Connect app record exists for that bundle ID and team.

An upload command returning successfully proves only that delivery was
submitted unless it explicitly waits for processing. For deploy-to-TestFlight
requests, require all of these outcomes for the exact version and build:

- package and binary upload completed;
- App Store Connect processing completed successfully;
- the build was assigned to the intended internal group, or automatic internal
  distribution made it available;
- the processed version/build is newer than every previously uploaded build.

If App Store Connect reports that a bundle version must be higher, consider the
rejected number consumed even when it is not visible in TestFlight. Increment
the project build number, rebuild and re-export the IPA, and upload the new
artifact. Do not repeatedly retry the consumed build number.

After upload:

- Wait for App Store Connect processing.
- Resolve `Missing Compliance` by answering export-compliance questions from
  the app's actual crypto behavior.
- Create or select an internal TestFlight group before claiming that testers can
  install the build. When creating a new internal group, check whether
  **Enable automatic distribution** is selected. App Store Connect warns that
  this setting cannot be updated later, so confirm the user's intent before
  pressing Create. Leave it enabled only when future uploaded builds should be
  automatically delivered to everyone in that internal group.
- Add the processed build to the intended internal group if automatic
  distribution did not already make it available.
- If the app does not implement or use non-exempt encryption beyond Apple's OS
  services, add this to Info.plist for future builds:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Do not submit for public App Review unless the user explicitly asks. Internal
developer-only TestFlight distribution is a separate step from public release.

## Manual Gates And Evidence

Keep readiness tasks honest. A task may pass local prerequisites while still
exiting nonzero for manual gates. Do not force success env vars until real
evidence exists.

Common open gates:

- signing/export: Apple Distribution signing and IPA export evidence.
- TestFlight install: processed build, internal distribution, install on iPhone
  and iPad, launch, camera or permission flows as applicable.
- physical feature checks: real camera/OCR, provider API E2E, accessibility,
  iCloud/CloudKit sync, or other app-specific gates.
- App Store Connect: metadata, privacy answers, screenshots, review notes,
  processed build attachment, internal distribution state.

When the repo has `design-docs/release-evidence/`, write non-secret evidence
there using templates if present. Evidence should include:

- Gate name and PASS/TODO/BLOCKED.
- Exact verification time and timezone.
- Version/build and redacted device model/OS where applicable.
- Archive/export/upload status and non-secret delivery/build reference.
- Remaining manual blockers.

Never include credentials, private keys, provisioning profile contents, full
device IDs, or private account identifiers in evidence.

## Completion Criteria

For a deploy-through-TestFlight task, report:

- Bundle ID and App Store Connect listing name.
- Archive path, IPA path, version/build.
- Validation/upload result and processing/compliance status.
- Whether TestFlight internal distribution and device installs are complete.
- Which readiness tasks passed and which manual gates remain.
- Files changed for signing scripts, metadata, Info.plist, and evidence.
