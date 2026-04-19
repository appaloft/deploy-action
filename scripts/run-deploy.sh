#!/usr/bin/env bash
set -euo pipefail

add_arg() {
  local option="$1"
  local value="${2:-}"

  if [[ -n "$value" ]]; then
    args+=("$option" "$value")
  fi
}

first_non_empty() {
  local value

  for value in "$@"; do
    if [[ -n "$value" ]]; then
      echo "$value"
      return
    fi
  done
}

cleanup() {
  if [[ -n "${materialized_ssh_private_key_file:-}" ]]; then
    rm -f "$materialized_ssh_private_key_file"
  fi
}
trap cleanup EXIT

runner_temp="${RUNNER_TEMP:-/tmp}"
source_value="$(first_non_empty "${INPUT_SOURCE:-}" "${INPUT_PATH_OR_SOURCE:-}" ".")"
config_value="${INPUT_CONFIG:-appaloft.yml}"

args=(deploy "$source_value")

if [[ -n "$config_value" ]]; then
  if [[ -f "$config_value" ]]; then
    add_arg "--config" "$config_value"
  elif [[ "$config_value" != "appaloft.yml" ]]; then
    add_arg "--config" "$config_value"
  fi
fi

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

ssh_host="$(first_non_empty "${INPUT_SSH_HOST:-}" "${INPUT_TARGET_HOST:-}")"
ssh_user="$(first_non_empty "${INPUT_SSH_USER:-}" "${INPUT_TARGET_SSH_USERNAME:-}")"
ssh_port="$(first_non_empty "${INPUT_SSH_PORT:-}" "${INPUT_TARGET_PORT:-}")"
ssh_private_key="$(first_non_empty "${INPUT_SSH_PRIVATE_KEY:-}" "${INPUT_TARGET_PRIVATE_KEY:-}")"
ssh_private_key_file="$(first_non_empty "${INPUT_SSH_PRIVATE_KEY_FILE:-}" "${INPUT_TARGET_PRIVATE_KEY_FILE:-}")"
server_proxy_kind="$(first_non_empty "${INPUT_SERVER_PROXY_KIND:-}" "${INPUT_TARGET_PROXY_KIND:-}")"
server_name="${INPUT_TARGET_NAME:-}"
server_provider="${INPUT_TARGET_PROVIDER:-}"
ssh_public_key="${INPUT_TARGET_SSH_PUBLIC_KEY:-}"
state_backend="${INPUT_STATE_BACKEND:-}"

materialized_ssh_private_key_file=""
if [[ -z "$ssh_private_key_file" && -n "$ssh_private_key" ]]; then
  mkdir -p "${runner_temp}/appaloft-deploy-action"
  materialized_ssh_private_key_file="${runner_temp}/appaloft-deploy-action/ssh-key-${$}"
  umask 077
  printf '%s\n' "$ssh_private_key" >"$materialized_ssh_private_key_file"
  chmod 600 "$materialized_ssh_private_key_file"
  ssh_private_key_file="$materialized_ssh_private_key_file"
fi

target_requested=false
for target_value in \
  "$ssh_host" \
  "$ssh_user" \
  "$ssh_port" \
  "$ssh_private_key_file" \
  "$server_proxy_kind" \
  "$server_name" \
  "$server_provider" \
  "$ssh_public_key"; do
  if [[ -n "$target_value" ]]; then
    target_requested=true
    break
  fi
done

if [[ "$target_requested" == "true" ]]; then
  add_arg "--server-name" "$server_name"
  add_arg "--server-host" "$ssh_host"

  if [[ -n "$server_provider" ]]; then
    add_arg "--server-provider" "$server_provider"
  elif [[ -n "$ssh_host" ]]; then
    add_arg "--server-provider" "generic-ssh"
  fi

  add_arg "--server-port" "$ssh_port"
  add_arg "--server-proxy-kind" "$server_proxy_kind"
  add_arg "--server-ssh-username" "$ssh_user"
  add_arg "--server-ssh-public-key" "$ssh_public_key"
  add_arg "--server-ssh-private-key-file" "$ssh_private_key_file"
fi

if [[ -n "$state_backend" ]]; then
  add_arg "--state-backend" "$state_backend"
elif [[ -n "$ssh_host" ]]; then
  add_arg "--state-backend" "ssh-pglite"
fi

if [[ -n "${INPUT_ARGS:-}" ]]; then
  read -r -a extra_args <<<"${INPUT_ARGS}"
  args+=("${extra_args[@]}")
fi

echo "Running appaloft ${args[*]}"
appaloft "${args[@]}"
