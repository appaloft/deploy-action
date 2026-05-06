#!/usr/bin/env bash
set -euo pipefail

error() {
  echo "::error::$*" >&2
}

truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_arg() {
  argv+=("$1")
}

append_option() {
  local name="$1"
  local value="$2"
  if [ -n "$value" ]; then
    argv+=("$name" "$value")
  fi
}

cleanup_key_file() {
  if [ -n "${generated_key_file:-}" ]; then
    rm -f "$generated_key_file"
  fi
  if [ -n "${generated_preview_output_file:-}" ]; then
    rm -f "$generated_preview_output_file"
  fi
}

trap cleanup_key_file EXIT

appaloft_bin="${APPALOFT_BIN:-appaloft}"
wrapper_command="${INPUT_COMMAND:-deploy}"
source_locator="${INPUT_SOURCE:-.}"
config_path="${INPUT_CONFIG:-}"
control_plane_mode="${INPUT_CONTROL_PLANE_MODE:-none}"
control_plane_url="${INPUT_CONTROL_PLANE_URL:-}"
appaloft_token="${INPUT_APPALOFT_TOKEN:-}"
use_oidc="${INPUT_USE_OIDC:-false}"
ssh_private_key="${INPUT_SSH_PRIVATE_KEY:-}"
ssh_private_key_file="${INPUT_SSH_PRIVATE_KEY_FILE:-}"
state_backend="${INPUT_STATE_BACKEND:-}"
preview="${INPUT_PREVIEW:-}"
preview_id="${INPUT_PREVIEW_ID:-}"
preview_domain_template="${INPUT_PREVIEW_DOMAIN_TEMPLATE:-}"
preview_tls_mode="${INPUT_PREVIEW_TLS_MODE:-}"
require_preview_url="${INPUT_REQUIRE_PREVIEW_URL:-false}"
preview_output_file=""

case "$wrapper_command" in
  ""|deploy)
    wrapper_command="deploy"
    ;;
  preview-cleanup)
    ;;
  *)
    error "Unsupported deploy-action command: $wrapper_command"
    exit 1
    ;;
esac

case "$control_plane_mode" in
  ""|none)
    ;;
  *)
    error "control-plane-mode=${control_plane_mode} is reserved until CLI control-plane handshakes are active"
    exit 1
    ;;
esac

if [ -n "$control_plane_url" ] || [ -n "$appaloft_token" ] || truthy "$use_oidc"; then
  error "control-plane-url, appaloft-token, and use-oidc are reserved until control-plane mode is active"
  exit 1
fi

if [ -n "$ssh_private_key" ] && [ -n "$ssh_private_key_file" ]; then
  error "ssh-private-key and ssh-private-key-file are mutually exclusive"
  exit 1
fi

if [ "$preview" = "pull-request" ] && [ -z "$preview_id" ]; then
  error "preview-id is required when preview=pull-request"
  exit 1
fi

if [ "$wrapper_command" = "preview-cleanup" ] && [ "$preview" != "pull-request" ]; then
  error "preview-cleanup requires preview=pull-request"
  exit 1
fi

if [ -n "$preview" ] && [ "$preview" != "pull-request" ]; then
  error "Unsupported preview mode: $preview"
  exit 1
fi

if [ -n "${INPUT_SSH_HOST:-}" ] && [ -z "$state_backend" ]; then
  state_backend="ssh-pglite"
fi

if [ -n "$ssh_private_key" ]; then
  generated_key_file="$(mktemp "${RUNNER_TEMP:-/tmp}/appaloft-ssh-key.XXXXXX")"
  printf '%s\n' "$ssh_private_key" > "$generated_key_file"
  chmod 600 "$generated_key_file"
  ssh_private_key_file="$generated_key_file"
fi

if [ -n "$preview" ] && [ "$wrapper_command" = "deploy" ]; then
  generated_preview_output_file="$(mktemp "${RUNNER_TEMP:-/tmp}/appaloft-preview-output.XXXXXX")"
  preview_output_file="$generated_preview_output_file"
fi

case "$wrapper_command" in
  deploy)
    argv=("$appaloft_bin" "deploy" "$source_locator")
    ;;
  preview-cleanup)
    argv=("$appaloft_bin" "preview" "cleanup" "$source_locator")
    ;;
esac

if [ -n "$config_path" ]; then
  append_option "--config" "$config_path"
elif [ -f "appaloft.yml" ]; then
  append_option "--config" "appaloft.yml"
fi

if [ "$wrapper_command" = "deploy" ]; then
  append_option "--runtime-name" "${INPUT_RUNTIME_NAME:-}"
fi
append_option "--server-host" "${INPUT_SSH_HOST:-}"
append_option "--server-ssh-username" "${INPUT_SSH_USER:-}"
append_option "--server-port" "${INPUT_SSH_PORT:-}"
append_option "--server-provider" "${INPUT_SERVER_PROVIDER:-generic-ssh}"
append_option "--server-proxy-kind" "${INPUT_SERVER_PROXY_KIND:-}"
append_option "--server-ssh-private-key-file" "$ssh_private_key_file"
append_option "--state-backend" "$state_backend"
append_option "--preview" "$preview"
append_option "--preview-id" "$preview_id"

if [ "$wrapper_command" = "deploy" ]; then
  append_option "--preview-domain-template" "$preview_domain_template"
  append_option "--preview-tls-mode" "$preview_tls_mode"
  append_option "--preview-output-file" "$preview_output_file"
fi

if [ "$wrapper_command" = "deploy" ] && truthy "$require_preview_url"; then
  append_arg "--require-preview-url"
fi

if truthy "${APPALOFT_DEPLOY_ACTION_DRY_RUN:-false}"; then
  if [ -n "${APPALOFT_DEPLOY_ACTION_ARGV_PATH:-}" ]; then
    printf '%s\n' "${argv[@]}" > "$APPALOFT_DEPLOY_ACTION_ARGV_PATH"
  else
    printf '%q ' "${argv[@]}"
    printf '\n'
  fi
else
  "${argv[@]}"
fi

preview_url=""
if [ -n "$preview_output_file" ] && [ -f "$preview_output_file" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      preview-id)
        if [ -z "$preview_id" ]; then
          preview_id="$value"
        fi
        ;;
      preview-url)
        preview_url="$value"
        ;;
    esac
  done < "$preview_output_file"
fi

if [ -n "$preview_id" ]; then
  echo "preview-id=$preview_id" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

if [ -z "$preview_url" ] && [ -n "$preview_domain_template" ]; then
  if [ "$preview_tls_mode" = "disabled" ]; then
    preview_url="http://${preview_domain_template}"
  else
    preview_url="https://${preview_domain_template}"
  fi
fi

if [ -n "$preview_url" ]; then
  echo "preview-url=$preview_url" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
