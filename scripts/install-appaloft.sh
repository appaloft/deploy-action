#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "appaloft deploy-action: $*" >&2
  exit 1
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

json_tag_name() {
  sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

sha256_file() {
  local file="$1"

  if has_command sha256sum; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi

  if has_command shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi

  fail "sha256sum or shasum is required to verify Appaloft release assets"
}

detect_target() {
  local os="${RUNNER_OS:-}"
  local machine
  machine="$(uname -m)"

  if [[ -z "$os" ]]; then
    case "$(uname -s)" in
      Darwin) os="macOS" ;;
      Linux) os="Linux" ;;
      MINGW* | MSYS* | CYGWIN*) os="Windows" ;;
      *) fail "unsupported runner OS: $(uname -s)" ;;
    esac
  fi

  case "$machine" in
    x86_64 | amd64) machine="x64" ;;
    arm64 | aarch64) machine="arm64" ;;
    *) fail "unsupported runner architecture: $machine" ;;
  esac

  case "$os" in
    Linux) echo "linux-${machine}-gnu" ;;
    macOS) echo "darwin-${machine}" ;;
    Windows) echo "win32-${machine}" ;;
    *) fail "unsupported runner OS: $os" ;;
  esac
}

download() {
  local url="$1"
  local output="$2"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url" -o "$output"
  else
    curl -fsSL "$url" -o "$output"
  fi
}

resolve_latest_tag() {
  local repo="$1"
  local release_dir="$2"
  local latest_json

  if [[ -n "$release_dir" ]]; then
    latest_json="${release_dir}/latest.json"
    [[ -f "$latest_json" ]] || fail "latest.json is required when APPALOFT_ACTION_RELEASE_DIR is used with version latest"
    json_tag_name <"$latest_json"
    return
  fi

  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api_url" | json_tag_name
  else
    curl -fsSL "$api_url" | json_tag_name
  fi
}

version="${1:-${INPUT_VERSION:-latest}}"
repo="${APPALOFT_ACTION_REPOSITORY:-appaloft/appaloft}"
release_dir="${APPALOFT_ACTION_RELEASE_DIR:-}"
target="${APPALOFT_ACTION_TARGET:-$(detect_target)}"
runner_temp="${RUNNER_TEMP:-/tmp}"
work_dir="${runner_temp}/appaloft-deploy-action/install"

mkdir -p "$work_dir"

if [[ "$version" == "latest" ]]; then
  tag="$(resolve_latest_tag "$repo" "$release_dir")"
  [[ -n "$tag" ]] || fail "could not resolve latest Appaloft release"
else
  tag="$version"
fi

if [[ "$tag" != v* ]]; then
  tag="v${tag}"
fi

case "$target" in
  win32-*) extension="zip" ;;
  *) extension="tar.gz" ;;
esac

asset_name="appaloft-${tag}-${target}.${extension}"
archive_path="${work_dir}/${asset_name}"
checksums_path="${work_dir}/checksums.txt"

if [[ -n "$release_dir" ]]; then
  [[ -f "${release_dir}/${asset_name}" ]] || fail "release asset not found: ${release_dir}/${asset_name}"
  [[ -f "${release_dir}/checksums.txt" ]] || fail "checksums.txt not found in ${release_dir}"
  cp "${release_dir}/${asset_name}" "$archive_path"
  cp "${release_dir}/checksums.txt" "$checksums_path"
else
  base_url="https://github.com/${repo}/releases/download/${tag}"
  download "${base_url}/${asset_name}" "$archive_path"
  download "${base_url}/checksums.txt" "$checksums_path"
fi

expected_checksum="$(awk -v file="$asset_name" '$2 == file {print $1}' "$checksums_path" | head -n 1)"
[[ -n "$expected_checksum" ]] || fail "checksum for ${asset_name} was not found in checksums.txt"

actual_checksum="$(sha256_file "$archive_path")"
if [[ "$actual_checksum" != "$expected_checksum" ]]; then
  fail "checksum mismatch for ${asset_name}: expected ${expected_checksum}, got ${actual_checksum}"
fi

extract_dir="${work_dir}/${tag}-${target}/extract"
bin_dir="${work_dir}/${tag}-${target}/bin"
rm -rf "$extract_dir" "$bin_dir"
mkdir -p "$extract_dir" "$bin_dir"

case "$extension" in
  zip)
    has_command unzip || fail "unzip is required to extract ${asset_name}"
    unzip -q "$archive_path" -d "$extract_dir"
    binary_path="$(find "$extract_dir" -type f \( -name appaloft -o -name appaloft.exe \) | head -n 1)"
    binary_name="appaloft.exe"
    ;;
  tar.gz)
    tar -xzf "$archive_path" -C "$extract_dir"
    binary_path="$(find "$extract_dir" -type f -name appaloft | head -n 1)"
    binary_name="appaloft"
    ;;
  *) fail "unsupported archive extension: ${extension}" ;;
esac

[[ -n "${binary_path:-}" ]] || fail "Appaloft CLI binary was not found in ${asset_name}"

cp "$binary_path" "${bin_dir}/${binary_name}"
chmod +x "${bin_dir}/${binary_name}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >>"$GITHUB_PATH"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "appaloft-version=${tag}"
    echo "appaloft-target=${target}"
    echo "appaloft-bin-dir=${bin_dir}"
  } >>"$GITHUB_OUTPUT"
fi

echo "Installed Appaloft CLI ${tag} for ${target}"
