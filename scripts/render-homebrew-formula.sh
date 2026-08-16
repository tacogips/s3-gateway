#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="s3-gateway"
product="s3-gateway"
repository_url="https://github.com/tacogips/s3-gateway"

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-formula.sh <version> [output-file]

Reads archive checksums from:
  dist/homebrew/$artifact_name-<version>-<target>.tar.gz.sha256

Environment:
  RELEASE_DIR       Directory containing archives and .sha256 files.
  RELEASE_BASE_URL  Release URL base. Defaults to GitHub v<version>.

Example:
  scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
  scripts/render-homebrew-formula.sh 0.1.0 Formula/$artifact_name.rb

This renderer expects Swift macOS release archives. Linux archives are
unsupported until the project defines a reviewed Swift Linux build contract.
EOF
}

sha_for_target() {
  local version target release_dir sha_file
  version="$1"
  target="$2"
  release_dir="$3"
  sha_file="$release_dir/$artifact_name-$version-$target.tar.gz.sha256"

  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi

  awk '{print $1}' "$sha_file"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi
  if [[ "${1:-}" == "" ]]; then
    usage
    return 2
  fi

  local version output release_dir release_base_url
  version="$1"
  output="${2:-$repo_root/Formula/$artifact_name.rb}"
  release_dir="${RELEASE_DIR:-$repo_root/dist/homebrew}"
  release_base_url="${RELEASE_BASE_URL:-$repository_url/releases/download/v$version}"

  local darwin_arm64_sha darwin_x64_sha
  darwin_arm64_sha="$(sha_for_target "$version" darwin-arm64 "$release_dir")"
  darwin_x64_sha="$(sha_for_target "$version" darwin-x64 "$release_dir")"

  mkdir -p "$(dirname "$output")"
  cat > "$output" <<EOF
class S3Gateway < Formula
  desc "Bounded SigV4-authenticated S3 gateway for POSIX and upstream S3 storage"
  homepage "$repository_url"
  version "$version"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "$release_base_url/$artifact_name-$version-darwin-arm64.tar.gz"
      sha256 "$darwin_arm64_sha"
    else
      url "$release_base_url/$artifact_name-$version-darwin-x64.tar.gz"
      sha256 "$darwin_x64_sha"
    end
  end

  def install
    bin.install "bin/$product"
  end

  test do
    assert_match "$version", shell_output("#{bin}/$product --version")
  end
end
EOF

  printf 'rendered %s\n' "$output"
}

main "$@"
