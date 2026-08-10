---
name: homebrew-release
description: Use when building, validating, publishing, or tap-rendering Homebrew formula tarball releases for this Swift project, including scripts/build-homebrew-release.sh, scripts/render-homebrew-formula.sh, and mise run build:homebrew or homebrew:formula commands.
---

# Homebrew Release

Use this skill for Formula releases installed with:

```bash
brew tap user/tap
brew install swift-s3-gateway
```

Use `.agents/skills/macos-cask-release/SKILL.md` for signed and notarized Cask
DMGs.

## Release Contract

1. Confirm `VERSION` is the intended release version.
2. Build and test the Swift package.
3. Build macOS Homebrew tarballs with `scripts/build-homebrew-release.sh`.
4. Publish the tarballs to a GitHub Release only when explicitly requested.
5. Render the formula only after all referenced archives and checksums exist.
6. Update and verify the tap formula from the tap checkout.

The default Swift formula contract is macOS-only:

| Homebrew platform | Release asset |
| --- | --- |
| macOS Apple Silicon | `swift-s3-gateway-<version>-darwin-arm64.tar.gz` |
| macOS Intel | `swift-s3-gateway-<version>-darwin-x64.tar.gz` |

Do not add Linux assets unless the project has a reviewed Swift Linux runtime
contract.

## Standard Commands

Build:

```bash
mise run build
mise run test
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render locally:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run homebrew:formula -- "$version"
```

Render into the default sibling tap:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run homebrew:tap-formula -- "$version"
```

For a custom tap path:

```bash
version="$(tr -d '[:space:]' < VERSION)"
scripts/render-homebrew-formula.sh "$version" /path/to/homebrew-tap/Formula/swift-s3-gateway.rb
```

## Publishing Notes

Before rendering a formula for public use, ensure the GitHub Release assets
exist:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release view "v${version}" --repo user/repo
```

If publishing is explicitly requested:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release upload "v${version}" \
  "dist/homebrew/swift-s3-gateway-${version}-darwin-arm64.tar.gz" \
  "dist/homebrew/swift-s3-gateway-${version}-darwin-x64.tar.gz" \
  --repo user/repo \
  --clobber
```

## Verification

From the tap checkout:

```bash
ruby -c Formula/swift-s3-gateway.rb
brew audit --strict swift-s3-gateway || brew audit --strict --formula swift-s3-gateway
brew install user/tap/swift-s3-gateway
swift-s3-gateway --version
brew test user/tap/swift-s3-gateway
```

If online audit fails because of local GitHub credentials or rate limits, run a
non-online audit and report the limitation.

## Tap API Metadata Gate

After pushing `Formula/swift-s3-gateway.rb`, require the tap's
`update-api-metadata.yml` workflow to succeed for that commit. Verify the
GitHub Raw `api/formula/swift-s3-gateway.json`: its `.versions.stable` must
equal the release version and its `.ruby_source_checksum.sha256` must equal the
SHA-256 of the committed Formula. Do not consider the release complete while
the endpoint is missing or stale.
