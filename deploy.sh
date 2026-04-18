#!/usr/bin/env bash
set -euo pipefail

add_arg() {
  local option="$1"
  local value="${2:-}"

  if [[ -n "$value" ]]; then
    args+=("$option" "$value")
  fi
}

cleanup() {
  if [[ -n "${MATERIALIZED_TARGET_PRIVATE_KEY_FILE:-}" ]]; then
    rm -f "$MATERIALIZED_TARGET_PRIVATE_KEY_FILE"
  fi
}
trap cleanup EXIT

runner_temp="${RUNNER_TEMP:-/tmp}"
export APPALOFT_DATABASE_DRIVER="${APPALOFT_DATABASE_DRIVER:-pglite}"
export APPALOFT_DATA_DIR="${APPALOFT_DATA_DIR:-${runner_temp}/appaloft/data}"
export APPALOFT_PGLITE_DATA_DIR="${APPALOFT_PGLITE_DATA_DIR:-${APPALOFT_DATA_DIR}/pglite}"
mkdir -p "$APPALOFT_DATA_DIR" "$APPALOFT_PGLITE_DATA_DIR"

path_or_source="${INPUT_PATH_OR_SOURCE:-.}"
args=(deploy "$path_or_source")

add_arg "--config" "${INPUT_CONFIG:-}"
add_arg "--method" "${INPUT_METHOD:-}"
add_arg "--project" "${INPUT_PROJECT_ID:-}"
add_arg "--server" "${INPUT_SERVER_ID:-}"
add_arg "--destination" "${INPUT_DESTINATION_ID:-}"
add_arg "--environment" "${INPUT_ENVIRONMENT_ID:-}"
add_arg "--resource" "${INPUT_RESOURCE_ID:-}"
add_arg "--resource-name" "${INPUT_RESOURCE_NAME:-}"
add_arg "--resource-kind" "${INPUT_RESOURCE_KIND:-}"
add_arg "--resource-description" "${INPUT_RESOURCE_DESCRIPTION:-}"
add_arg "--install" "${INPUT_INSTALL:-}"
add_arg "--build" "${INPUT_BUILD:-}"
add_arg "--start" "${INPUT_START:-}"
add_arg "--publish-dir" "${INPUT_PUBLISH_DIR:-}"
add_arg "--port" "${INPUT_PORT:-}"
add_arg "--health-path" "${INPUT_HEALTH_PATH:-}"
add_arg "--app-log-lines" "${INPUT_APP_LOG_LINES:-3}"

target_private_key_file="${INPUT_TARGET_PRIVATE_KEY_FILE:-}"
if [[ -z "$target_private_key_file" && -n "${MATERIALIZED_TARGET_PRIVATE_KEY_FILE:-}" ]]; then
  target_private_key_file="$MATERIALIZED_TARGET_PRIVATE_KEY_FILE"
fi

target_requested=false
for target_value in \
  "${INPUT_TARGET_HOST:-}" \
  "${INPUT_TARGET_NAME:-}" \
  "${INPUT_TARGET_PROVIDER:-}" \
  "${INPUT_TARGET_PORT:-}" \
  "${INPUT_TARGET_PROXY_KIND:-}" \
  "${INPUT_TARGET_SSH_USERNAME:-}" \
  "${INPUT_TARGET_SSH_PUBLIC_KEY:-}" \
  "$target_private_key_file"; do
  if [[ -n "$target_value" ]]; then
    target_requested=true
    break
  fi
done

if [[ "$target_requested" == "true" ]]; then
  add_arg "--server-name" "${INPUT_TARGET_NAME:-}"
  add_arg "--server-host" "${INPUT_TARGET_HOST:-}"

  if [[ -n "${INPUT_TARGET_PROVIDER:-}" ]]; then
    add_arg "--server-provider" "$INPUT_TARGET_PROVIDER"
  elif [[ -n "${INPUT_TARGET_HOST:-}" ]]; then
    add_arg "--server-provider" "generic-ssh"
  fi

  add_arg "--server-port" "${INPUT_TARGET_PORT:-}"
  add_arg "--server-proxy-kind" "${INPUT_TARGET_PROXY_KIND:-}"
  add_arg "--server-ssh-username" "${INPUT_TARGET_SSH_USERNAME:-}"
  add_arg "--server-ssh-public-key" "${INPUT_TARGET_SSH_PUBLIC_KEY:-}"
  add_arg "--server-ssh-private-key-file" "$target_private_key_file"
fi

echo "Running appaloft ${args[*]}"
appaloft "${args[@]}"
