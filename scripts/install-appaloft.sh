#!/usr/bin/env bash
set -euo pipefail

repository="appaloft/appaloft"
version="${INPUT_VERSION:-latest}"
runner_temp="${RUNNER_TEMP:-/tmp}"
install_root="${runner_temp%/}/appaloft-deploy-action"
mkdir -p "$install_root"

error() {
  echo "::error::$*" >&2
}

detect_target() {
  local os
  local arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin)
      os="darwin"
      ;;
    Linux)
      os="linux"
      ;;
    *)
      error "Unsupported runner OS: $os"
      exit 1
      ;;
  esac

  case "$arch" in
    arm64|aarch64)
      arch="arm64"
      ;;
    x86_64|amd64)
      arch="x64"
      ;;
    *)
      error "Unsupported runner architecture: $arch"
      exit 1
      ;;
  esac

  if [ "$os" = "linux" ]; then
    if ldd --version 2>&1 | grep -qi musl; then
      printf '%s-%s-musl\n' "$os" "$arch"
    else
      printf '%s-%s-gnu\n' "$os" "$arch"
    fi
    return
  fi

  printf '%s-%s\n' "$os" "$arch"
}

resolve_latest_version() {
  local headers=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl -fsSL "${headers[@]}" "https://api.github.com/repos/${repository}/releases/latest" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

if [ "$version" = "latest" ]; then
  version="$(resolve_latest_version)"
fi

if [ -z "$version" ]; then
  error "Unable to resolve Appaloft release version"
  exit 1
fi

case "$version" in
  v*)
    version_tag="$version"
    version_number="${version#v}"
    ;;
  *)
    version_tag="v${version}"
    version_number="$version"
    ;;
esac

target="$(detect_target)"
archive_name="appaloft-v${version_number}-${target}.tar.gz"
release_base_url="https://github.com/${repository}/releases/download/${version_tag}"
archive_path="${install_root}/${archive_name}"
checksums_path="${install_root}/checksums.txt"
extract_dir="${install_root}/appaloft-v${version_number}-${target}"

curl -fsSL "${release_base_url}/${archive_name}" -o "$archive_path"
curl -fsSL "${release_base_url}/checksums.txt" -o "$checksums_path"

expected_checksum="$(
  awk -v asset="$archive_name" '$2 == asset { print $1 }' "$checksums_path"
)"

if [ -z "$expected_checksum" ]; then
  error "checksums.txt does not contain ${archive_name}"
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum="$(sha256sum "$archive_path" | awk '{ print $1 }')"
else
  actual_checksum="$(shasum -a 256 "$archive_path" | awk '{ print $1 }')"
fi

if [ "$actual_checksum" != "$expected_checksum" ]; then
  error "Checksum mismatch for ${archive_name}"
  exit 1
fi

rm -rf "$extract_dir"
mkdir -p "$extract_dir"
tar -xzf "$archive_path" -C "$extract_dir"

appaloft_bin="$(find "$extract_dir" -type f -name appaloft -print | head -n 1)"
if [ -z "$appaloft_bin" ]; then
  error "Extracted archive did not contain an appaloft binary"
  exit 1
fi

chmod +x "$appaloft_bin"
appaloft_bin_dir="$(dirname "$appaloft_bin")"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$appaloft_bin_dir" >> "$GITHUB_PATH"
fi

{
  echo "appaloft-bin=$appaloft_bin"
  echo "appaloft-version=$version_tag"
  echo "appaloft-target=$target"
} >> "${GITHUB_OUTPUT:-/dev/null}"

echo "Installed Appaloft ${version_tag} for ${target}"
