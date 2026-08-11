#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
product="swift-s3-gateway"
artifact_name="swift-s3-gateway"

usage() {
  cat <<EOF
Usage:
  scripts/build-homebrew-release.sh [--dry-run] [target ...]

Targets:
  darwin-arm64  darwin-x64

Environment:
  RELEASE_VERSION       Override package version used in archive names.
  RELEASE_DIR           Output directory. Defaults to dist/homebrew.
  SWIFT_BIN             Swift executable. Defaults to Xcode's Swift toolchain on macOS, then PATH.
  SWIFT_DEVELOPER_DIR   Defaults to /Applications/Xcode.app/Contents/Developer on macOS.
  SWIFT_SDKROOT         Defaults to Xcode's macOS SDK path on macOS.

Examples:
  scripts/build-homebrew-release.sh
  scripts/build-homebrew-release.sh --dry-run darwin-arm64 darwin-x64
  scripts/build-homebrew-release.sh darwin-arm64 darwin-x64

This builder stages Swift macOS archives for a Homebrew formula. It does not
publish release assets, mutate a tap, render a formula, or push commits.
EOF
}

detect_target() {
  local kernel arch
  kernel="$(uname -s)"
  arch="$(uname -m)"

  case "$kernel:$arch" in
    Darwin:arm64) printf '%s\n' "darwin-arm64" ;;
    Darwin:x86_64) printf '%s\n' "darwin-x64" ;;
    *)
      printf 'unsupported Swift Homebrew host platform: %s/%s\n' "$kernel" "$arch" >&2
      return 1
      ;;
  esac
}

validate_target() {
  case "$1" in
    darwin-arm64 | darwin-x64) ;;
    *)
      printf 'unsupported Swift Homebrew target: %s\n' "$1" >&2
      printf 'Linux Homebrew archives are unsupported until the project defines a reviewed Swift Linux build contract.\n' >&2
      usage >&2
      return 1
      ;;
  esac
}

validate_version() {
  local version
  version="$1"

  if [[ "$version" == *..* || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe release version: %s\n' "$version" >&2
    printf 'expected archive-safe semver-like value without path separators or parent traversal\n' >&2
    return 1
  fi
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$repo_root" "$1" ;;
  esac
}

validate_release_dir() {
  local path part
  local -a parts
  path="$1"

  if [[ -z "$path" ]]; then
    printf 'unsafe release directory: empty path\n' >&2
    return 1
  fi

  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    if [[ "$part" == "." || "$part" == ".." ]]; then
      printf 'unsafe release directory: %s\n' "$path" >&2
      printf 'release directory must not contain . or .. path components\n' >&2
      return 1
    fi
  done
}

assert_child_path() {
  local root child
  root="${1%/}"
  child="$2"

  if [[ -z "$root" || "$root" == "/" || "$child" != "$root"/* ]]; then
    printf 'unsafe path outside release directory: %s\n' "$child" >&2
    return 1
  fi
}

swift_triple_for_target() {
  case "$1" in
    darwin-arm64) printf '%s\n' "arm64-apple-macosx" ;;
    darwin-x64) printf '%s\n' "x86_64-apple-macosx" ;;
  esac
}

write_sha256() {
  local file dir base
  file="$1"
  dir="$(dirname "$file")"
  base="$(basename "$file")"

  if command -v shasum >/dev/null 2>&1; then
    ( cd "$dir" && shasum -a 256 "$base" )
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$dir" && sha256sum "$base" )
    return
  fi

  printf 'missing checksum tool: expected shasum or sha256sum\n' >&2
  return 1
}

package_version() {
  if [[ -n "${RELEASE_VERSION:-}" ]]; then
    printf '%s\n' "$RELEASE_VERSION"
    return
  fi

  tr -d '[:space:]' < "$repo_root/VERSION"
}

swift_bin() {
  if [[ -n "${SWIFT_BIN:-}" ]]; then
    printf '%s\n' "$SWIFT_BIN"
    return
  fi
  if [[ -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift ]]; then
    printf '%s\n' "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    return
  fi
  command -v swift
}

swift_release_bin_path() {
  local target swift_exe developer_dir sdkroot triple
  target="$1"
  swift_exe="$(swift_bin)"
  developer_dir="${SWIFT_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  sdkroot="${SWIFT_SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
  triple="$(swift_triple_for_target "$target")"

  (
    cd "$repo_root"
    DEVELOPER_DIR="$developer_dir" SDKROOT="$sdkroot" \
      "$swift_exe" build -c release --product "$product" --triple "$triple" >/dev/null
    DEVELOPER_DIR="$developer_dir" SDKROOT="$sdkroot" \
      "$swift_exe" build -c release --product "$product" --triple "$triple" --show-bin-path
  )
}

print_plan() {
  local version target release_dir work_dir archive binary triple
  version="$1"
  target="$2"
  release_dir="$3"
  work_dir="$release_dir/work/$artifact_name-$version-$target"
  archive="$release_dir/$artifact_name-$version-$target.tar.gz"
  binary="$work_dir/bin/$product"
  triple="$(swift_triple_for_target "$target")"

  assert_child_path "$release_dir" "$work_dir"
  assert_child_path "$release_dir" "$archive"

  printf 'Swift Homebrew archive plan\n'
  printf '  product: %s\n' "$product"
  printf '  target: %s\n' "$target"
  printf '  swift triple: %s\n' "$triple"
  printf '  release bin path command: swift build -c release --product %s --triple %s --show-bin-path\n' "$product" "$triple"
  printf '  staged binary: %s\n' "$binary"
  printf '  archive: %s\n' "$archive"
  printf '  checksum: %s.sha256\n' "$archive"
  printf '  publish side effects: false\n'
}

build_target() {
  local version target release_dir bin_path work_dir archive binary
  version="$1"
  target="$2"
  release_dir="$3"
  work_dir="$release_dir/work/$artifact_name-$version-$target"
  archive="$release_dir/$artifact_name-$version-$target.tar.gz"
  binary="$work_dir/bin/$product"

  assert_child_path "$release_dir" "$work_dir"
  assert_child_path "$release_dir" "$archive"

  rm -rf "$work_dir" "$archive" "$archive.sha256"
  mkdir -p "$work_dir/bin"

  bin_path="$(swift_release_bin_path "$target" | tail -n 1)"
  cp "$bin_path/$product" "$binary"
  chmod 0755 "$binary"
  cp "$repo_root/README.md" "$work_dir/README.md"

  tar -C "$work_dir" -czf "$archive" .
  write_sha256 "$archive" > "$archive.sha256"

  printf 'built %s\n' "$archive"
  cat "$archive.sha256"
}

main() {
  local dry_run
  dry_run=false

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi

  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
  fi

  local version release_dir
  version="$(package_version)"
  validate_version "$version"
  release_dir="$(absolute_path "${RELEASE_DIR:-dist/homebrew}")"
  validate_release_dir "$release_dir"

  local -a targets
  if [[ "$#" -eq 0 ]]; then
    targets=("$(detect_target)")
  else
    targets=("$@")
  fi

  local target
  for target in "${targets[@]}"; do
    validate_target "$target"
    if [[ "$dry_run" == true ]]; then
      print_plan "$version" "$target" "$release_dir"
    else
      mkdir -p "$release_dir"
      build_target "$version" "$target" "$release_dir"
    fi
  done

  printf '\nRender a formula after all platform archives exist:\n'
  printf '  scripts/render-homebrew-formula.sh %s\n' "$version"
}

main "$@"
