#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="s3-gateway"
github_repository="user/repo"

usage() {
  cat <<EOF
Usage:
  scripts/release-homebrew-cask-local.sh v<version> [tap-cask-file]

Required local environment variables:
  APPLE_SIGNING_IDENTITY  Developer ID Application identity for the executable.
  APPLE_ID                Apple ID email for notarization.
  APPLE_PASSWORD          Apple app-specific password for notarization.
  APPLE_TEAM_ID           Apple Developer Team ID for notarization.

The signing certificate must already be installed in the local macOS keychain.
Use kinko or another local password-manager workflow to provide the environment.
Do not commit Apple credential values.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    return 1
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

release_tag="${1:-}"
tap_cask_file="${2:-$repo_root/../homebrew-tap/Casks/$artifact_name.rb}"
if [[ -z "$release_tag" ]]; then
  usage >&2
  exit 1
fi

case "$release_tag" in
  v*) ;;
  *)
    printf 'error: release tag must start with v, for example v0.1.0\n' >&2
    exit 1
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'error: Homebrew Cask release signing must run on macOS\n' >&2
  exit 1
fi

require_command gh
require_command git
require_command shasum

version="${release_tag#v}"
if [[ "$(tr -d '[:space:]' < "$repo_root/VERSION")" != "$version" ]]; then
  printf 'error: VERSION does not match release tag %s\n' "$release_tag" >&2
  exit 1
fi

cd "$repo_root"

if ! git rev-parse -q --verify "refs/tags/$release_tag" >/dev/null; then
  printf 'error: local git tag does not exist: %s\n' "$release_tag" >&2
  exit 1
fi

if ! git ls-remote --exit-code --tags origin "refs/tags/$release_tag" >/dev/null; then
  printf 'error: git tag has not been pushed to origin: %s\n' "$release_tag" >&2
  exit 1
fi

scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64

release_dir="${CASK_RELEASE_DIR:-$repo_root/dist/homebrew-cask}"
arm_dmg="$release_dir/$artifact_name-$version-darwin-arm64.dmg"
x64_dmg="$release_dir/$artifact_name-$version-darwin-x64.dmg"
test -f "$arm_dmg"
test -f "$x64_dmg"

release_notes="Signed, notarized, and stapled macOS DMG archives for the Homebrew Cask release."
if ! gh release view "$release_tag" --repo "$github_repository" >/dev/null 2>&1; then
  gh release create "$release_tag" \
    --repo "$github_repository" \
    --title "s3-gateway $release_tag" \
    --notes "$release_notes"
fi

gh release upload "$release_tag" "$arm_dmg" "$x64_dmg" --repo "$github_repository" --clobber

scripts/render-homebrew-cask.sh "$version" "$tap_cask_file"

printf '\nRendered tap cask: %s\n' "$tap_cask_file"
printf 'Review, commit, and push the tap change from the tap repository.\n'
printf 'Then install with:\n'
printf '  brew tap user/tap\n'
printf '  brew install --cask s3-gateway\n'
