---
name: macos-cask-release
description: Use when building, signing, notarizing, validating, publishing, or tap-rendering macOS Homebrew Cask DMG releases for this Swift project, including Apple Developer ID signing, scripts/build-homebrew-cask-release.sh, scripts/render-homebrew-cask.sh, and release:homebrew-cask-local.
---

# macOS Cask Release

Use this skill for Cask releases installed with:

```bash
brew tap user/tap
brew install --cask swift-s3-gateway
```

Use `.agents/skills/homebrew-release/SKILL.md` for unsigned Formula tarballs.

## Credential Policy

- Keep Apple certificate material local.
- Never print, paste, commit, or summarize Apple passwords, app-specific
  passwords, private keys, `.p12` contents, or password-manager secret values.
- It is safe to mention secret key names such as `APPLE_SIGNING_IDENTITY`,
  `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID`.
- Prefer `kinko exec --env ...` for commands that need secrets.

Required environment variables for real builds:

- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`

## Local Workflow

Check version alignment:

```bash
version="$(tr -d '[:space:]' < VERSION)"
swift run swift-s3-gateway --version | tail -n 1 | grep -Fx "$version"
```

Check the release plan:

```bash
task build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build signed, notarized, and stapled DMGs:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64
```

Expected outputs:

```text
dist/homebrew-cask/swift-s3-gateway-<version>-darwin-arm64.dmg
dist/homebrew-cask/swift-s3-gateway-<version>-darwin-x64.dmg
```

Validate:

```bash
version="$(tr -d '[:space:]' < VERSION)"
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate "dist/homebrew-cask/swift-s3-gateway-${version}-darwin-arm64.dmg"
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate "dist/homebrew-cask/swift-s3-gateway-${version}-darwin-x64.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/homebrew-cask/swift-s3-gateway-${version}-darwin-arm64.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/homebrew-cask/swift-s3-gateway-${version}-darwin-x64.dmg"
```

## Tagged Release

For a pushed `v<version>` tag:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v<version>
```

The wrapper checks the local and remote tag, verifies `VERSION`, uploads both
DMGs to `user/repo`, and renders
`../homebrew-tap/Casks/swift-s3-gateway.rb`.

After reviewing the rendered tap Cask:

```bash
cd ../homebrew-tap
git add Casks/swift-s3-gateway.rb README.md
git diff --staged --stat
git commit -m "chore: release swift-s3-gateway <version>"
git push origin main
```

## Tap Verification

```bash
brew fetch --cask user/tap/swift-s3-gateway
HOMEBREW_NO_GITHUB_API=1 brew audit --cask user/tap/swift-s3-gateway
```

If `brew audit --online` fails with local GitHub credential errors, use
`HOMEBREW_NO_GITHUB_API=1` and report that online audit was blocked by local
credentials, not the Cask syntax.
