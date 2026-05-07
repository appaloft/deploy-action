#!/usr/bin/env bash
set -euo pipefail

trim_quotes() {
  local value="$1"
  value="${value%%#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

read_yaml_control_plane_value() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[^[:space:]][^:]*:/ && $0 !~ /^controlPlane:[[:space:]]*$/ { in_block = 0 }
    /^controlPlane:[[:space:]]*$/ { in_block = 1; next }
    in_block == 1 {
      pattern = "^[[:space:]]+" key ":[[:space:]]*"
      if ($0 ~ pattern) {
        sub(pattern, "", $0)
        print $0
        exit
      }
    }
  ' "$file"
}

read_json_control_plane_value() {
  local file="$1"
  local key="$2"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const key = process.argv[2];
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    const value = parsed && parsed.controlPlane && parsed.controlPlane[key];
    if (typeof value === "string") process.stdout.write(value);
  ' "$file" "$key"
}

read_control_plane_value() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi

  normalized_file="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_file" in
    *.json)
      read_json_control_plane_value "$file" "$key"
      ;;
    *)
      trim_quotes "$(read_yaml_control_plane_value "$file" "$key")"
      ;;
  esac
}

normalize_url() {
  local value="$1"
  value="${value%/}"
  printf '%s' "$value"
}

config_path="${INPUT_CONFIG:-}"
if [ -z "$config_path" ] && [ -f "appaloft.yml" ]; then
  config_path="appaloft.yml"
fi

input_mode="${INPUT_CONTROL_PLANE_MODE:-}"
mode="$input_mode"
url="${INPUT_CONTROL_PLANE_URL:-}"

if [ -n "$config_path" ] && [ -f "$config_path" ]; then
  config_mode="$(read_control_plane_value "$config_path" mode)"
  config_url="$(read_control_plane_value "$config_path" url)"

  if [ -z "$mode" ] && [ -n "$config_mode" ]; then
    mode="$config_mode"
  fi

  if [ -z "$url" ] && [ -n "$config_url" ] && { { [ -z "$input_mode" ] && [ -n "$config_mode" ]; } || [ "$input_mode" = "self-hosted" ] || [ "$input_mode" = "cloud" ]; }; then
    url="$config_url"
  fi
fi

if [ -z "$mode" ]; then
  mode="none"
fi

if [ -n "$url" ]; then
  url="$(normalize_url "$url")"
fi

{
  echo "control-plane-mode=$mode"
  echo "control-plane-url=$url"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ -n "${APPALOFT_DEPLOY_ACTION_RESOLVE_OUTPUT:-}" ]; then
  {
    echo "control-plane-mode=$mode"
    echo "control-plane-url=$url"
  } > "$APPALOFT_DEPLOY_ACTION_RESOLVE_OUTPUT"
fi
