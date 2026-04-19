#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${TMPDIR:-/tmp}/appaloft-deploy-action-tests"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

failures=0

log() {
  printf '%s\n' "$*"
}

fail() {
  log "not ok - $1"
  failures=$((failures + 1))
}

pass() {
  log "ok - $1"
}

assert_file_exists() {
  local path="$1"
  local message="$2"
  [[ -f "$path" ]] || {
    fail "$message"
    return 1
  }
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || {
    fail "$message"
    return 1
  }
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" != *"$needle"* ]] || {
    fail "$message"
    return 1
  }
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

create_release_fixture() {
  local root="$1"
  local version="$2"
  local target="$3"
  local archive_base="appaloft-${version}-${target}"
  local bundle_dir="$root/${archive_base}"
  mkdir -p "$bundle_dir"
  cat >"$bundle_dir/appaloft" <<'SH'
#!/usr/bin/env bash
printf 'appaloft fixture %s\n' "$*"
SH
  chmod +x "$bundle_dir/appaloft"
  (cd "$root" && tar -czf "${archive_base}.tar.gz" "$archive_base")
  rm -rf "$bundle_dir"
  local archive="${root}/${archive_base}.tar.gz"
  printf '%s  %s\n' "$(file_sha256 "$archive")" "$(basename "$archive")" >"$root/checksums.txt"
}

run_fake_appaloft() {
  local workdir="$1"
  local argv_file="$2"
  local mode_file="$3"
  local bin_dir="$workdir/bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/appaloft" <<SH
#!/usr/bin/env bash
printf '%q ' "\$@" >"$argv_file"
printf '\n' >>"$argv_file"
key_file=""
previous=""
for arg in "\$@"; do
  if [[ "\$previous" == "--server-ssh-private-key-file" ]]; then
    key_file="\$arg"
  fi
  previous="\$arg"
done
if [[ -n "\$key_file" && -f "\$key_file" ]]; then
  if stat -c '%a' "\$key_file" >/dev/null 2>&1; then
    stat -c '%a' "\$key_file" >"$mode_file"
  else
    stat -f '%Lp' "\$key_file" >"$mode_file"
  fi
  printf '%s' "\$key_file" >"$workdir/key-path"
fi
SH
  chmod +x "$bin_dir/appaloft"
  printf '%s' "$bin_dir"
}

test_action_metadata_contract() {
  local name="[QUICK-DEPLOY-ENTRY-011] action metadata is a direct verified binary wrapper"
  local metadata
  metadata="$(cat "$repo_root/action.yml")"

  assert_contains "$metadata" "scripts/install-appaloft.sh" "$name missing install script" || return
  assert_contains "$metadata" "scripts/run-deploy.sh" "$name missing deploy script" || return
  assert_contains "$metadata" "ssh-host:" "$name missing ssh-host input" || return
  assert_contains "$metadata" "ssh-private-key:" "$name missing ssh-private-key input" || return
  assert_contains "$metadata" "state-backend:" "$name missing state-backend input" || return
  assert_not_contains "$metadata" "appaloft/setup-appaloft" "$name must not depend on setup-appaloft" || return

  pass "$name"
}

test_install_verifies_checksum() {
  local name="[CONFIG-FILE-ENTRY-009] install verifies checksum before adding CLI to PATH"
  local workdir="$tmp_root/install-ok"
  local release_dir="$workdir/release"
  local github_path="$workdir/github-path"
  mkdir -p "$release_dir"
  create_release_fixture "$release_dir" "v0.1.0" "linux-x64-gnu"

  APPALOFT_ACTION_RELEASE_DIR="$release_dir" \
    APPALOFT_ACTION_TARGET="linux-x64-gnu" \
    RUNNER_TEMP="$workdir/runner" \
    GITHUB_PATH="$github_path" \
    "$repo_root/scripts/install-appaloft.sh" "v0.1.0" >/dev/null

  local installed_dir
  installed_dir="$(tail -n 1 "$github_path")"
  assert_file_exists "$installed_dir/appaloft" "$name did not install appaloft" || return
  "$installed_dir/appaloft" doctor >/dev/null

  pass "$name"
}

test_install_rejects_checksum_mismatch() {
  local name="[CONFIG-FILE-ENTRY-009] install rejects checksum mismatch"
  local workdir="$tmp_root/install-bad"
  local release_dir="$workdir/release"
  mkdir -p "$release_dir"
  create_release_fixture "$release_dir" "v0.1.0" "linux-x64-gnu"
  printf '0000000000000000000000000000000000000000000000000000000000000000  appaloft-v0.1.0-linux-x64-gnu.tar.gz\n' >"$release_dir/checksums.txt"

  if APPALOFT_ACTION_RELEASE_DIR="$release_dir" \
    APPALOFT_ACTION_TARGET="linux-x64-gnu" \
    RUNNER_TEMP="$workdir/runner" \
    GITHUB_PATH="$workdir/github-path" \
    "$repo_root/scripts/install-appaloft.sh" "v0.1.0" >/dev/null 2>"$workdir/error.log"; then
    fail "$name accepted a mismatched checksum"
    return
  fi

  assert_contains "$(cat "$workdir/error.log")" "checksum" "$name did not report checksum" || return
  pass "$name"
}

test_latest_version_resolution() {
  local name="[CONFIG-FILE-ENTRY-011] latest resolves stable release tag"
  local workdir="$tmp_root/latest"
  local release_dir="$workdir/release"
  local github_path="$workdir/github-path"
  mkdir -p "$release_dir"
  create_release_fixture "$release_dir" "v0.2.0" "linux-x64-gnu"
  printf '{"tag_name":"v0.2.0","prerelease":false,"draft":false}\n' >"$release_dir/latest.json"

  APPALOFT_ACTION_RELEASE_DIR="$release_dir" \
    APPALOFT_ACTION_TARGET="linux-x64-gnu" \
    RUNNER_TEMP="$workdir/runner" \
    GITHUB_PATH="$github_path" \
    "$repo_root/scripts/install-appaloft.sh" "latest" >/dev/null

  assert_contains "$(tail -n 1 "$github_path")" "v0.2.0" "$name did not install latest fixture" || return
  pass "$name"
}

test_ssh_private_key_mapping() {
  local name="[CONFIG-FILE-ENTRY-010] deploy maps SSH private key through temp file only"
  local workdir="$tmp_root/ssh-key"
  local argv_file="$workdir/argv"
  local mode_file="$workdir/key-mode"
  mkdir -p "$workdir"
  local fake_path
  fake_path="$(run_fake_appaloft "$workdir" "$argv_file" "$mode_file")"

  PATH="$fake_path:$PATH" \
    RUNNER_TEMP="$workdir/runner" \
    INPUT_SOURCE="." \
    INPUT_CONFIG="appaloft.yml" \
    INPUT_SSH_HOST="107.173.15.220" \
    INPUT_SSH_USER="deploy" \
    INPUT_SSH_PRIVATE_KEY=$'-----BEGIN KEY-----\nsecret-private-key\n-----END KEY-----' \
    "$repo_root/scripts/run-deploy.sh"

  local argv
  argv="$(cat "$argv_file")"
  assert_contains "$argv" "--server-host 107.173.15.220" "$name missing server host" || return
  assert_contains "$argv" "--server-ssh-private-key-file" "$name missing key file flag" || return
  assert_not_contains "$argv" "secret-private-key" "$name leaked private key in argv" || return
  assert_contains "$(cat "$mode_file")" "600" "$name did not chmod key file to 600" || return

  local key_path
  key_path="$(cat "$workdir/key-path")"
  [[ ! -e "$key_path" ]] || {
    fail "$name did not remove temp key"
    return
  }

  pass "$name"
}

test_no_config_mode() {
  local name="[CONFIG-FILE-ENTRY-012] no-config deploy omits --config and keeps SSH remote-state path"
  local workdir="$tmp_root/no-config"
  local argv_file="$workdir/argv"
  local mode_file="$workdir/key-mode"
  mkdir -p "$workdir/workspace"
  local fake_path
  fake_path="$(run_fake_appaloft "$workdir" "$argv_file" "$mode_file")"

  (cd "$workdir/workspace" && PATH="$fake_path:$PATH" \
    RUNNER_TEMP="$workdir/runner" \
    INPUT_SOURCE="." \
    INPUT_CONFIG="appaloft.yml" \
    INPUT_SSH_HOST="107.173.15.220" \
    "$repo_root/scripts/run-deploy.sh")

  local argv
  argv="$(cat "$argv_file")"
  assert_contains "$argv" "deploy ." "$name missing deploy source" || return
  assert_not_contains "$argv" "--config" "$name passed missing default config" || return
  assert_contains "$argv" "--state-backend ssh-pglite" "$name did not make ssh-pglite explicit" || return

  pass "$name"
}

test_config_without_domain() {
  local name="[CONFIG-FILE-ENTRY-013] config without domains does not add custom route inputs"
  local workdir="$tmp_root/config-no-domain"
  local argv_file="$workdir/argv"
  local mode_file="$workdir/key-mode"
  mkdir -p "$workdir/workspace"
  cat >"$workdir/workspace/appaloft.yml" <<'YAML'
runtime:
  strategy: static
  publishDirectory: dist
network:
  internalPort: 80
YAML
  local fake_path
  fake_path="$(run_fake_appaloft "$workdir" "$argv_file" "$mode_file")"

  (cd "$workdir/workspace" && PATH="$fake_path:$PATH" \
    RUNNER_TEMP="$workdir/runner" \
    INPUT_SOURCE="." \
    INPUT_CONFIG="appaloft.yml" \
    INPUT_SSH_HOST="107.173.15.220" \
    "$repo_root/scripts/run-deploy.sh")

  local argv
  argv="$(cat "$argv_file")"
  assert_contains "$argv" "--config appaloft.yml" "$name missing config flag" || return
  assert_not_contains "$argv" "access.domains" "$name invented domain input" || return
  assert_not_contains "$argv" "--domain" "$name invented domain flag" || return

  pass "$name"
}

tests=(
  test_action_metadata_contract
  test_install_verifies_checksum
  test_install_rejects_checksum_mismatch
  test_latest_version_resolution
  test_ssh_private_key_mapping
  test_no_config_mode
  test_config_without_domain
)

for test_name in "${tests[@]}"; do
  if ! "$test_name"; then
    :
  fi
done

if [[ "$failures" -gt 0 ]]; then
  log "$failures test(s) failed"
  exit 1
fi

log "${#tests[@]} test(s) passed"
