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

append_multiline_option() {
  local name="$1"
  local value="$2"
  local line

  if [ -z "$value" ]; then
    return
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      argv+=("$name" "$line")
    fi
  done <<< "$value"
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

normalized_url() {
  local value="$1"
  value="${value%/}"
  printf '%s' "$value"
}

trim_config_value() {
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

read_yaml_block_value() {
  local file="$1"
  local block="$2"
  local key="$3"
  awk -v block="$block" -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[^[:space:]][^:]*:/ {
      expected = "^" block ":[[:space:]]*$"
      in_block = ($0 ~ expected)
      next
    }
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

read_json_block_value() {
  local file="$1"
  local block="$2"
  local key="$3"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const block = process.argv[2];
    const key = process.argv[3];
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    const value = parsed && parsed[block] && parsed[block][key];
    if (typeof value === "string") process.stdout.write(value);
  ' "$file" "$block" "$key"
}

read_config_block_value() {
  local file="$1"
  local block="$2"
  local key="$3"
  if [ ! -f "$file" ]; then
    return 0
  fi

  normalized_file="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_file" in
    *.json)
      read_json_block_value "$file" "$block" "$key"
      ;;
    *)
      trim_config_value "$(read_yaml_block_value "$file" "$block" "$key")"
      ;;
  esac
}

read_control_plane_value() {
  read_config_block_value "$1" controlPlane "$2"
}

read_source_value() {
  read_config_block_value "$1" source "$2"
}

source_fingerprint_for_action() {
  local source_locator="$1"
  local selected_config_path="$2"
  local base_directory="$3"
  local selected_preview_id="${4:-}"

  node -e '
    const sourceLocator = process.argv[1] || ".";
    const configPath = process.argv[2] || "appaloft.yml";
    const baseDirectoryInput = process.argv[3] || ".";
    const previewId = process.argv[4] || "";
    const env = process.env;
    function normalizePathSeparators(value) {
      return String(value || "").trim().replaceAll("\\\\", "/").replace(/\/+/g, "/");
    }
    function stripWorkspacePrefix(value, workspaceRoot) {
      const normalized = normalizePathSeparators(value);
      const root = workspaceRoot ? normalizePathSeparators(workspaceRoot).replace(/\/+$/, "") : "";
      if (root && normalized === root) return ".";
      if (root && normalized.startsWith(`${root}/`)) return normalized.slice(root.length + 1);
      return normalized;
    }
    function normalizeSafeRelativePath(value, fallback, workspaceRoot) {
      const stripped = stripWorkspacePrefix(value || fallback, workspaceRoot)
        .replace(/^\.\//, "")
        .replace(/\/+$/, "");
      if (!stripped || stripped === ".") return fallback;
      if (stripped.startsWith("/")) return fallback;
      return stripped;
    }
    function stripGitSuffix(value) {
      return value.replace(/\.git$/i, "");
    }
    function normalizeRepositoryLocator(locator) {
      const raw = stripGitSuffix(String(locator || "").trim().replace(/\/+$/, ""));
      const sshMatch = /^git@([^:]+):(.+)$/.exec(raw);
      if (sshMatch) {
        const host = (sshMatch[1] || "unknown").toLowerCase();
        const path = stripGitSuffix(sshMatch[2] || "").replace(/^\/+/, "");
        return `${host}/${path.toLowerCase()}`;
      }
      try {
        const url = new URL(raw);
        const host = url.host.toLowerCase();
        const path = stripGitSuffix(url.pathname.replace(/^\/+/, "").replace(/\/+$/, ""));
        return `${host}/${host === "github.com" ? path.toLowerCase() : path}`;
      } catch {
        return raw.toLowerCase();
      }
    }
    function normalizeBranch(branch) {
      return String(branch || "").trim().replace(/^refs\/heads\//, "");
    }
    function pullRequestNumberFromPreviewId(value) {
      const normalized = String(value || "").trim().toLowerCase().replace(/^preview-/, "");
      if (/^\d+$/.test(normalized)) return normalized;
      const match = /^pr-(\d+)$/.exec(normalized);
      return match ? match[1] : "";
    }
    function scopeKey() {
      const explicitPreviewNumber = pullRequestNumberFromPreviewId(previewId);
      if (explicitPreviewNumber) return `preview:pr:${explicitPreviewNumber}`;
      const pullRequestMatch = /^refs\/pull\/(\d+)\/(?:merge|head)$/.exec(env.GITHUB_REF || "");
      if (pullRequestMatch) return `preview:pr:${pullRequestMatch[1]}`;
      if (env.GITHUB_HEAD_REF) return `preview:branch:${normalizeBranch(env.GITHUB_HEAD_REF)}`;
      if ((env.GITHUB_REF || "").startsWith("refs/heads/")) {
        return `branch:${normalizeBranch(env.GITHUB_REF)}`;
      }
      return "default";
    }
    const provider = env.GITHUB_REPOSITORY ? "github" : "local";
    const repositoryLocator = env.GITHUB_REPOSITORY
      ? `https://github.com/${env.GITHUB_REPOSITORY}`
      : sourceLocator;
    const repository = env.GITHUB_REPOSITORY_ID
      ? `provider-repository:${env.GITHUB_REPOSITORY_ID}`
      : normalizeRepositoryLocator(repositoryLocator);
    const workspaceRoot = env.GITHUB_WORKSPACE || process.cwd();
    const keyParts = [
      "source-fingerprint:v1",
      scopeKey(),
      provider,
      repository,
      normalizeSafeRelativePath(baseDirectoryInput, ".", workspaceRoot),
      normalizeSafeRelativePath(configPath, "appaloft.yml", workspaceRoot),
    ];
    process.stdout.write(keyParts.map(encodeURIComponent).join(":"));
  ' "$source_locator" "$selected_config_path" "$base_directory" "$selected_preview_id"
}

require_input() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    error "$name is required for self-hosted control-plane mode"
    exit 1
  fi
}

append_auth_header() {
  if [ -n "$appaloft_token" ]; then
    curl_args+=("-H" "Authorization: Bearer ${appaloft_token}")
  fi
}

deployment_console_url() {
  local base_url="$1"
  local deployment="$2"
  if [ -z "$base_url" ] || [ -z "$deployment" ]; then
    printf ''
    return 0
  fi

  printf '%s/deployments/%s' "${base_url%/}" "$deployment"
}

console_href_url() {
  local base_url="$1"
  local href="$2"
  if [ -z "$href" ]; then
    printf ''
    return 0
  fi

  case "$href" in
    http://*|https://*)
      printf '%s' "$href"
      ;;
    /*)
      printf '%s%s' "${base_url%/}" "$href"
      ;;
    *)
      printf '%s/%s' "${base_url%/}" "$href"
      ;;
  esac
}

version_supports_action_server_config_deploy() {
  node -e '
    const fs = require("fs");
    const input = fs.readFileSync(0, "utf8");
    const parsed = JSON.parse(input);
    const features = parsed && typeof parsed.features === "object" && parsed.features
      ? parsed.features
      : {};
    const supported =
      parsed.actionServerConfigDeploy === true ||
      features.actionServerConfigDeploy === true ||
      (
        (features.sourcePackage === true || features.sourcePackages === true) &&
        features.serverSideConfigBootstrap === true
      );
    process.exit(supported ? 0 : 1);
  '
}

source_package_payload_for_action() {
  local source_fingerprint="$1"
  local selected_config="$2"
  local source_root="$3"
  local payload

  payload="{\"sourceFingerprint\":\"$(json_escape "$source_fingerprint")\",\"configPath\":\"$(json_escape "$selected_config")\",\"sourceRoot\":\"$(json_escape "$source_root")\",\"sourcePackage\":{\"transport\":\"server-github-fetch\",\"sourceFingerprint\":\"$(json_escape "$source_fingerprint")\",\"configPath\":\"$(json_escape "$selected_config")\",\"sourceRoot\":\"$(json_escape "$source_root")\""
  if [ -n "${GITHUB_SHA:-}" ]; then
    payload="${payload},\"revision\":\"$(json_escape "$GITHUB_SHA")\""
  fi
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    payload="${payload},\"repositoryFullName\":\"$(json_escape "$GITHUB_REPOSITORY")\""
  fi
  if [ -n "${GITHUB_REPOSITORY_ID:-}" ]; then
    payload="${payload},\"repositoryId\":\"$(json_escape "$GITHUB_REPOSITORY_ID")\""
  fi
  payload="${payload}}"
  if [ -n "$project_id" ] || [ -n "$environment_id" ] || [ -n "$resource_id" ] || [ -n "$server_id" ] || [ -n "$destination_id" ] || [ -n "${GITHUB_REPOSITORY:-}" ] || [ -n "${GITHUB_REPOSITORY_ID:-}" ] || [ -n "${GITHUB_REF:-}" ] || [ -n "${GITHUB_SHA:-}" ]; then
    payload="${payload},\"trustedContext\":{"
    local separator=""
    if [ -n "$project_id" ]; then payload="${payload}${separator}\"projectId\":\"$(json_escape "$project_id")\""; separator=","; fi
    if [ -n "$environment_id" ]; then payload="${payload}${separator}\"environmentId\":\"$(json_escape "$environment_id")\""; separator=","; fi
    if [ -n "$resource_id" ]; then payload="${payload}${separator}\"resourceId\":\"$(json_escape "$resource_id")\""; separator=","; fi
    if [ -n "$server_id" ]; then payload="${payload}${separator}\"serverId\":\"$(json_escape "$server_id")\""; separator=","; fi
    if [ -n "$destination_id" ]; then payload="${payload}${separator}\"destinationId\":\"$(json_escape "$destination_id")\""; separator=","; fi
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then payload="${payload}${separator}\"repositoryFullName\":\"$(json_escape "$GITHUB_REPOSITORY")\""; separator=","; fi
    if [ -n "${GITHUB_REPOSITORY_ID:-}" ]; then payload="${payload}${separator}\"repositoryId\":\"$(json_escape "$GITHUB_REPOSITORY_ID")\""; separator=","; fi
    if [ -n "${GITHUB_REF:-}" ]; then payload="${payload}${separator}\"ref\":\"$(json_escape "$GITHUB_REF")\""; separator=","; fi
    if [ -n "${GITHUB_SHA:-}" ]; then payload="${payload}${separator}\"revision\":\"$(json_escape "$GITHUB_SHA")\""; fi
    payload="${payload}}"
  fi
  if [ "$preview" = "pull-request" ]; then
    payload="${payload},\"preview\":{\"kind\":\"pull-request\",\"previewId\":\"$(json_escape "$preview_id")\""
    local pr_number
    pr_number="$(pull_request_number_from_context)"
    if [ -n "$pr_number" ]; then
      payload="${payload},\"pullRequestNumber\":${pr_number}"
    fi
    if [ -n "${GITHUB_SHA:-}" ]; then
      payload="${payload},\"headSha\":\"$(json_escape "$GITHUB_SHA")\""
    fi
    if [ -n "${GITHUB_BASE_REF:-}" ]; then
      payload="${payload},\"baseRef\":\"$(json_escape "$GITHUB_BASE_REF")\""
    fi
    if [ -n "${GITHUB_HEAD_REF:-}" ]; then
      payload="${payload},\"headRef\":\"$(json_escape "$GITHUB_HEAD_REF")\""
    fi
    payload="${payload}}"
  fi
  payload="${payload}}"
  printf '%s' "$payload"
}

append_step_summary() {
  if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    return 0
  fi

  {
    case "$wrapper_command" in
      preview-cleanup)
        printf '### Appaloft preview cleanup\n\n'
        ;;
      install-console)
        printf '### Appaloft console install\n\n'
        ;;
      *)
        printf '### Appaloft deployment\n\n'
        ;;
    esac
    if [ -n "${control_plane_url:-}" ]; then
      printf -- '- Console: %s\n' "$control_plane_url"
    elif [ -n "${console_url:-}" ]; then
      printf -- '- Console: %s\n' "$console_url"
    fi
    if [ "$wrapper_command" = "install-console" ] && [ -n "${console_database:-}" ]; then
      printf -- '- Database: `%s`\n' "$console_database"
    fi
    if [ -n "${deployment_id:-}" ]; then
      if [ -n "${deployment_url:-}" ]; then
        printf -- '- Deployment: [%s](%s)\n' "$deployment_id" "$deployment_url"
      else
        printf -- '- Deployment: `%s`\n' "$deployment_id"
      fi
    fi
    if [ -n "${cleanup_status:-}" ]; then
      printf -- '- Cleanup status: `%s`\n' "$cleanup_status"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
}

console_installer_url_for_version() {
  local version="$1"
  local normalized_version

  if [ -n "${INPUT_CONSOLE_INSTALLER_URL:-}" ]; then
    printf '%s' "$INPUT_CONSOLE_INSTALLER_URL"
    return 0
  fi

  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    printf 'https://github.com/appaloft/appaloft/releases/latest/download/install.sh'
    return 0
  fi

  case "$version" in
    v*) normalized_version="$version" ;;
    *) normalized_version="v$version" ;;
  esac
  printf 'https://github.com/appaloft/appaloft/releases/download/%s/install.sh' "$normalized_version"
}

validate_console_install_inputs() {
  case "$console_database" in
    postgres|pglite)
      ;;
    *)
      error "console-database must be postgres or pglite"
      exit 1
      ;;
  esac

  case "$console_http_port" in
    ''|*[!0-9]*)
      error "console-http-port must be a positive integer"
      exit 1
      ;;
    *)
      if [ "$console_http_port" -le 0 ]; then
        error "console-http-port must be a positive integer"
        exit 1
      fi
      ;;
  esac
}

run_console_install() {
  local ssh_host="${INPUT_SSH_HOST:-}"
  local ssh_user="${INPUT_SSH_USER:-root}"
  local ssh_port="${INPUT_SSH_PORT:-22}"
  local installer_url
  local remote_command
  local install_args
  local ssh_args

  [ -n "$ssh_host" ] || { error "ssh-host is required for command=install-console"; exit 1; }

  case "$ssh_port" in
    ''|*[!0-9]*)
      error "ssh-port must be numeric for command=install-console"
      exit 1
      ;;
  esac

  validate_console_install_inputs

  if [ -z "$console_url" ]; then
    if [ -n "$console_domain" ]; then
      console_url="https://${console_domain}"
    else
      console_url="http://${ssh_host}:${console_http_port}"
    fi
  fi
  console_url="$(normalized_url "$console_url")"
  installer_url="$(console_installer_url_for_version "$input_version")"

  install_args="--version $(shell_quote "$input_version") --web-origin $(shell_quote "$console_url") --database $(shell_quote "$console_database") --host $(shell_quote "$console_http_host") --port $(shell_quote "$console_http_port") --image $(shell_quote "$console_image")"
  if [ -n "$console_install_dir" ]; then
    install_args="$install_args --home $(shell_quote "$console_install_dir")"
  fi
  if truthy "$console_skip_docker_install"; then
    install_args="$install_args --skip-docker-install"
  fi

  if truthy "${APPALOFT_DEPLOY_ACTION_DRY_RUN:-false}"; then
    if [ -n "${APPALOFT_DEPLOY_ACTION_ARGV_PATH:-}" ]; then
      {
        printf 'SSH %s@%s:%s\n' "$ssh_user" "$ssh_host" "$ssh_port"
        printf 'INSTALLER %s\n' "$installer_url"
        printf 'RUN sh /tmp/appaloft-install.sh %s\n' "$install_args"
        printf 'HEALTH %s/api/health\n' "$console_url"
      } > "$APPALOFT_DEPLOY_ACTION_ARGV_PATH"
    else
      printf 'SSH %s@%s:%s\n' "$ssh_user" "$ssh_host" "$ssh_port"
      printf 'INSTALLER %s\n' "$installer_url"
      printf 'RUN sh /tmp/appaloft-install.sh %s\n' "$install_args"
      printf 'HEALTH %s/api/health\n' "$console_url"
    fi
    echo "console-url=$console_url" >> "${GITHUB_OUTPUT:-/dev/null}"
    append_step_summary
    return 0
  fi

  ssh_args=(-p "$ssh_port" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
  if [ -n "$ssh_private_key_file" ]; then
    ssh_args=(-i "$ssh_private_key_file" "${ssh_args[@]}")
  fi

  remote_command="if command -v curl >/dev/null 2>&1; then curl -fsSL $(shell_quote "$installer_url") -o /tmp/appaloft-install.sh; elif command -v wget >/dev/null 2>&1; then wget -qO /tmp/appaloft-install.sh $(shell_quote "$installer_url"); else echo 'curl or wget is required to download Appaloft installer' >&2; exit 1; fi; chmod 700 /tmp/appaloft-install.sh; sh /tmp/appaloft-install.sh $install_args"

  ssh "${ssh_args[@]}" "$ssh_user@$ssh_host" "$remote_command"

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "$console_url/api/health" >/dev/null; then
      echo "console-url=$console_url" >> "${GITHUB_OUTPUT:-/dev/null}"
      append_step_summary
      return 0
    fi
    sleep 6
  done

  error "Appaloft console did not become healthy at $console_url/api/health"
  exit 1
}

pull_request_number_from_context() {
  local normalized_preview_id
  normalized_preview_id="$(printf '%s' "$preview_id" | tr '[:upper:]' '[:lower:]')"
  normalized_preview_id="${normalized_preview_id#preview-}"
  normalized_preview_id="${normalized_preview_id#pr-}"
  case "$normalized_preview_id" in
    ''|*[!0-9]*)
      ;;
    *)
      printf '%s' "$normalized_preview_id"
      return 0
      ;;
  esac

  case "${GITHUB_REF:-}" in
    refs/pull/*/merge|refs/pull/*/head)
      local without_prefix="${GITHUB_REF#refs/pull/}"
      printf '%s' "${without_prefix%%/*}"
      return 0
      ;;
  esac

  printf ''
}

github_api_url() {
  local path="$1"
  printf '%s%s' "${GITHUB_API_URL:-https://api.github.com}" "$path"
}

build_pr_comment_body() {
  node -e '
    const marker = process.argv[1];
    const command = process.argv[2];
    const previewId = process.argv[3];
    const consoleUrl = process.argv[4];
    const previewUrl = process.argv[5];
    const deploymentId = process.argv[6];
    const deploymentUrl = process.argv[7];
    const cleanupStatus = process.argv[8];
    const lines = [marker, "", command === "preview-cleanup" ? "### Appaloft preview cleanup" : "### Appaloft deployment", ""];
    if (previewId) lines.push(`- Preview: \`${previewId}\``);
    if (previewUrl) lines.push(`- Preview URL: ${previewUrl}`);
    if (consoleUrl) lines.push(`- Console: ${consoleUrl}`);
    if (deploymentUrl) {
      lines.push(`- Deployment: [${deploymentId || "Open deployment"}](${deploymentUrl})`);
    } else if (deploymentId) {
      lines.push(`- Deployment: \`${deploymentId}\``);
    }
    if (cleanupStatus) lines.push(`- Cleanup status: \`${cleanupStatus}\``);
    process.stdout.write(JSON.stringify({ body: `${lines.join("\n")}\n` }));
  ' "$1" "$wrapper_command" "$preview_id" "${control_plane_url:-}" "${preview_url:-}" "${deployment_id:-}" "${deployment_url:-}" "${cleanup_status:-}"
}

warn_pr_comment_skipped() {
  echo "::warning::Appaloft PR comment was not published: $1" >&2
}

maybe_publish_pr_comment() {
  if ! truthy "$pr_comment"; then
    return 0
  fi

  [ -n "${GITHUB_REPOSITORY:-}" ] || { error "pr-comment requires GITHUB_REPOSITORY"; exit 1; }
  github_token="${input_github_token:-${GITHUB_TOKEN:-}}"
  [ -n "$github_token" ] || { error "pr-comment requires github-token or GITHUB_TOKEN"; exit 1; }

  pr_number="$(pull_request_number_from_context)"
  [ -n "$pr_number" ] || { error "pr-comment requires preview-id like pr-123 or a pull_request GitHub ref"; exit 1; }

  comment_marker="<!-- appaloft-deploy-action:${pr_number} -->"
  comments_path="/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments"

  if truthy "${APPALOFT_DEPLOY_ACTION_DRY_RUN:-false}"; then
    if [ -n "${APPALOFT_DEPLOY_ACTION_ARGV_PATH:-}" ]; then
      printf 'COMMENT %s\n' "$(github_api_url "$comments_path")" >> "$APPALOFT_DEPLOY_ACTION_ARGV_PATH"
    else
      printf 'COMMENT %s\n' "$(github_api_url "$comments_path")"
    fi
    return 0
  fi

  comment_payload="$(build_pr_comment_body "$comment_marker")"
  if ! comments_response="$(curl -fsS \
    -H "Authorization: Bearer ${github_token}" \
    -H "Accept: application/vnd.github+json" \
    "$(github_api_url "${comments_path}?per_page=100")")"; then
    warn_pr_comment_skipped "could not list pull request comments"
    return 0
  fi
  comment_id="$(COMMENT_MARKER="$comment_marker" node -e '
    const fs = require("fs");
    const comments = JSON.parse(fs.readFileSync(0, "utf8"));
    const marker = process.env.COMMENT_MARKER;
    const match = Array.isArray(comments)
      ? comments.find((comment) => typeof comment.body === "string" && comment.body.includes(marker))
      : undefined;
    if (match && match.id !== undefined) process.stdout.write(String(match.id));
  ' <<EOF
$comments_response
EOF
)"

  if [ -n "$comment_id" ]; then
    if ! curl -fsS -X PATCH \
      -H "Authorization: Bearer ${github_token}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      --data "$comment_payload" \
      "$(github_api_url "/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}")" >/dev/null; then
      warn_pr_comment_skipped "could not update pull request comment"
      return 0
    fi
  else
    if ! curl -fsS -X POST \
      -H "Authorization: Bearer ${github_token}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      --data "$comment_payload" \
      "$(github_api_url "$comments_path")" >/dev/null; then
      warn_pr_comment_skipped "could not create pull request comment"
      return 0
    fi
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
input_version="${INPUT_VERSION:-latest}"
source_locator="${INPUT_SOURCE:-.}"
config_path="${INPUT_CONFIG:-}"
input_control_plane_mode="${INPUT_CONTROL_PLANE_MODE:-}"
control_plane_mode="$input_control_plane_mode"
control_plane_url="${INPUT_CONTROL_PLANE_URL:-}"
appaloft_token="${INPUT_APPALOFT_TOKEN:-}"
use_oidc="${INPUT_USE_OIDC:-false}"
server_config_deploy="${INPUT_SERVER_CONFIG_DEPLOY:-false}"
ssh_private_key="${INPUT_SSH_PRIVATE_KEY:-}"
ssh_private_key_file="${INPUT_SSH_PRIVATE_KEY_FILE:-}"
console_url="${INPUT_CONSOLE_URL:-}"
console_domain="${INPUT_CONSOLE_DOMAIN:-}"
console_database="${INPUT_CONSOLE_DATABASE:-pglite}"
console_http_host="${INPUT_CONSOLE_HTTP_HOST:-0.0.0.0}"
console_http_port="${INPUT_CONSOLE_HTTP_PORT:-3001}"
console_install_dir="${INPUT_CONSOLE_INSTALL_DIR:-}"
console_image="${INPUT_CONSOLE_IMAGE:-ghcr.io/appaloft/appaloft}"
console_skip_docker_install="${INPUT_CONSOLE_SKIP_DOCKER_INSTALL:-false}"
state_backend="${INPUT_STATE_BACKEND:-}"
environment_variables="${INPUT_ENVIRONMENT_VARIABLES:-}"
secret_variables="${INPUT_SECRET_VARIABLES:-}"
preview="${INPUT_PREVIEW:-}"
preview_id="${INPUT_PREVIEW_ID:-}"
preview_domain_template="${INPUT_PREVIEW_DOMAIN_TEMPLATE:-}"
preview_tls_mode="${INPUT_PREVIEW_TLS_MODE:-}"
require_preview_url="${INPUT_REQUIRE_PREVIEW_URL:-false}"
pr_comment="${INPUT_PR_COMMENT:-false}"
input_github_token="${INPUT_GITHUB_TOKEN:-}"
preview_output_file=""
project_id="${INPUT_PROJECT_ID:-}"
environment_id="${INPUT_ENVIRONMENT_ID:-}"
resource_id="${INPUT_RESOURCE_ID:-}"
server_id="${INPUT_SERVER_ID:-}"
destination_id="${INPUT_DESTINATION_ID:-}"

selected_config_path="$config_path"
if [ -z "$selected_config_path" ] && [ -f "appaloft.yml" ]; then
  selected_config_path="appaloft.yml"
fi

if [ -n "$selected_config_path" ] && [ -f "$selected_config_path" ]; then
  config_control_plane_mode="$(read_control_plane_value "$selected_config_path" mode)"
  config_control_plane_url="$(read_control_plane_value "$selected_config_path" url)"
  if [ -z "$control_plane_mode" ] && [ -n "$config_control_plane_mode" ]; then
    control_plane_mode="$config_control_plane_mode"
  fi
  if [ -z "$control_plane_url" ] && [ -n "$config_control_plane_url" ] && { { [ -z "$input_control_plane_mode" ] && [ -n "$config_control_plane_mode" ]; } || [ "$input_control_plane_mode" = "self-hosted" ] || [ "$input_control_plane_mode" = "cloud" ]; }; then
    control_plane_url="$config_control_plane_url"
  fi
  config_source_base_directory="$(read_source_value "$selected_config_path" baseDirectory)"
fi

if [ -z "$control_plane_mode" ]; then
  control_plane_mode="none"
fi

case "$wrapper_command" in
  ""|deploy)
    wrapper_command="deploy"
    ;;
  preview-cleanup)
    ;;
  install-console)
    ;;
  *)
    error "Unsupported deploy-action command: $wrapper_command"
    exit 1
    ;;
esac

if [ -n "$ssh_private_key" ] && [ -n "$ssh_private_key_file" ]; then
  error "ssh-private-key and ssh-private-key-file are mutually exclusive"
  exit 1
fi

if [ -n "$ssh_private_key" ]; then
  generated_key_file="$(mktemp "${RUNNER_TEMP:-/tmp}/appaloft-ssh-key.XXXXXX")"
  printf '%s\n' "$ssh_private_key" > "$generated_key_file"
  chmod 600 "$generated_key_file"
  ssh_private_key_file="$generated_key_file"
fi

if [ "$wrapper_command" = "install-console" ]; then
  run_console_install
  exit 0
fi

case "$control_plane_mode" in
  ""|none)
    ;;
  self-hosted)
    control_plane_mode="self-hosted"
    ;;
  cloud|auto)
    error "control-plane-mode=${control_plane_mode} is not supported by this deploy-action release"
    exit 1
    ;;
  *)
    error "Unsupported control-plane-mode: ${control_plane_mode}"
    exit 1
    ;;
esac

if [ "$control_plane_mode" = "none" ] && { [ -n "$control_plane_url" ] || [ -n "$appaloft_token" ] || truthy "$use_oidc"; }; then
  error "control-plane-url, appaloft-token, and use-oidc require control-plane-mode=self-hosted"
  exit 1
fi

if truthy "$use_oidc"; then
  error "use-oidc is reserved until GitHub OIDC token exchange is active"
  exit 1
fi

if truthy "$server_config_deploy" && { [ "$control_plane_mode" != "self-hosted" ] || [ "$wrapper_command" != "deploy" ]; }; then
  error "server-config-deploy requires control-plane-mode=self-hosted and command=deploy"
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

if [ "$control_plane_mode" = "self-hosted" ]; then
  require_input "control-plane-url" "$control_plane_url"
  has_explicit_deployment_context=false
  has_any_explicit_context=false
  if [ -n "$project_id" ] || [ -n "$environment_id" ] || [ -n "$resource_id" ] || [ -n "$server_id" ] || [ -n "$destination_id" ]; then
    has_any_explicit_context=true
  fi
  if [ "$wrapper_command" = "deploy" ] && $has_any_explicit_context; then
    has_explicit_deployment_context=true
    require_input "project-id" "$project_id"
    require_input "environment-id" "$environment_id"
    require_input "resource-id" "$resource_id"
    require_input "server-id" "$server_id"
  fi

  if [ "$wrapper_command" = "preview-cleanup" ] && $has_any_explicit_context; then
    error "self-hosted preview-cleanup resolves context from source-link state and must not receive project/resource/server ids"
    exit 1
  fi

  if [ -n "${INPUT_SSH_HOST:-}" ] || [ -n "${INPUT_SSH_USER:-}" ] || [ -n "${INPUT_SSH_PORT:-}" ] || [ -n "$ssh_private_key" ] || [ -n "$ssh_private_key_file" ] || [ -n "$state_backend" ]; then
    error "self-hosted control-plane mode must not receive ssh-* inputs or state-backend"
    exit 1
  fi

  if [ "$wrapper_command" = "deploy" ] && ! truthy "$server_config_deploy" && { [ "$source_locator" != "." ] || [ -n "${INPUT_RUNTIME_NAME:-}" ] || [ -n "$preview_domain_template" ] || [ -n "$preview_tls_mode" ] || truthy "$require_preview_url" || [ -n "$environment_variables" ] || [ -n "$secret_variables" ]; }; then
    error "self-hosted control-plane mode deploys an existing Appaloft resource profile; source, runtime/profile, environment, secret, and preview route inputs are not applied in this slice"
    exit 1
  fi

  if truthy "$server_config_deploy" && { [ -n "${INPUT_RUNTIME_NAME:-}" ] || [ -n "$preview_domain_template" ] || [ -n "$preview_tls_mode" ] || truthy "$require_preview_url" || [ -n "$environment_variables" ] || [ -n "$secret_variables" ]; }; then
    error "server-config-deploy hands source/config to the self-hosted server and does not accept runner-side profile, env, secret, or preview route inputs"
    exit 1
  fi

  if [ "$wrapper_command" = "preview-cleanup" ] && { [ -n "${INPUT_RUNTIME_NAME:-}" ] || [ -n "$preview_domain_template" ] || [ -n "$preview_tls_mode" ] || truthy "$require_preview_url"; }; then
    error "self-hosted preview-cleanup accepts source, config, preview, and preview-id only"
    exit 1
  fi

  control_plane_url="$(normalized_url "$control_plane_url")"
  curl_args=("-fsS")
  append_auth_header
  source_fingerprint="$(source_fingerprint_for_action "$source_locator" "${selected_config_path:-appaloft.yml}" "${config_source_base_directory:-.}" "$preview_id")"

  if truthy "${APPALOFT_DEPLOY_ACTION_DRY_RUN:-false}"; then
    if [ -n "${APPALOFT_DEPLOY_ACTION_ARGV_PATH:-}" ]; then
      {
        printf 'GET %s/api/version\n' "$control_plane_url"
        if [ "$wrapper_command" = "preview-cleanup" ]; then
          printf 'POST %s/api/deployments/cleanup-preview\n' "$control_plane_url"
        elif truthy "$server_config_deploy"; then
          printf 'POST %s/api/action/deployments/from-config-package\n' "$control_plane_url"
        else
          printf 'POST %s/api/action/deployments/from-source-link\n' "$control_plane_url"
        fi
      } > "$APPALOFT_DEPLOY_ACTION_ARGV_PATH"
    else
      printf 'GET %s/api/version\n' "$control_plane_url"
      if [ "$wrapper_command" = "preview-cleanup" ]; then
        printf 'POST %s/api/deployments/cleanup-preview\n' "$control_plane_url"
      elif truthy "$server_config_deploy"; then
        printf 'POST %s/api/action/deployments/from-config-package\n' "$control_plane_url"
      else
        printf 'POST %s/api/action/deployments/from-source-link\n' "$control_plane_url"
      fi
    fi
  else
    version_response="$(curl "${curl_args[@]}" "$control_plane_url/api/version")"
    if [[ "$version_response" != *'"apiVersion":"v1"'* && "$version_response" != *'"apiVersion": "v1"'* ]]; then
      error "self-hosted control-plane handshake failed: expected apiVersion v1"
      exit 1
    fi

    if truthy "$server_config_deploy" && ! printf '%s' "$version_response" | version_supports_action_server_config_deploy; then
      error "self-hosted control-plane does not support Action Server Config Deploy; missing sourcePackage/serverSideConfigBootstrap feature"
      exit 1
    fi

    payload="{\"sourceFingerprint\":\"$(json_escape "$source_fingerprint")\""
    if [ "$wrapper_command" = "deploy" ] && $has_explicit_deployment_context; then
      payload="${payload},\"projectId\":\"$(json_escape "$project_id")\",\"environmentId\":\"$(json_escape "$environment_id")\",\"resourceId\":\"$(json_escape "$resource_id")\",\"serverId\":\"$(json_escape "$server_id")\""
      if [ -n "$destination_id" ]; then
        payload="${payload},\"destinationId\":\"$(json_escape "$destination_id")\""
      fi
    fi
    payload="${payload}}"

    if [ "$wrapper_command" = "preview-cleanup" ]; then
      cleanup_endpoint="$control_plane_url/api/deployments/cleanup-preview"
      cleanup_response="$(curl "${curl_args[@]}" -X POST "$cleanup_endpoint" -H "Content-Type: application/json" --data "$payload")"
      cleanup_status="$(printf '%s\n' "$cleanup_response" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      if [ -z "$cleanup_status" ]; then
        error "self-hosted control-plane preview cleanup response did not include status"
        exit 1
      fi
      echo "preview-cleanup-status=$cleanup_status" >> "${GITHUB_OUTPUT:-/dev/null}"
    else
      if truthy "$server_config_deploy"; then
        deploy_endpoint="$control_plane_url/api/action/deployments/from-config-package"
        payload="$(source_package_payload_for_action "$source_fingerprint" "${selected_config_path:-appaloft.yml}" "${config_source_base_directory:-.}")"
      else
        deploy_endpoint="$control_plane_url/api/action/deployments/from-source-link"
      fi
      deploy_response="$(curl "${curl_args[@]}" -X POST "$deploy_endpoint" -H "Content-Type: application/json" --data "$payload")"
      deployment_id="$(printf '%s\n' "$deploy_response" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      if [ -z "$deployment_id" ]; then
        error "self-hosted control-plane deploy response did not include deployment id"
        exit 1
      fi
      deployment_url="$(printf '%s\n' "$deploy_response" | sed -n 's/.*"deploymentUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      deployment_href="$(printf '%s\n' "$deploy_response" | sed -n 's/.*"deploymentHref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      if [ -z "$deployment_url" ] && [ -n "$deployment_href" ]; then
        deployment_url="$(console_href_url "$control_plane_url" "$deployment_href")"
      fi
      if [ -z "$deployment_url" ]; then
        deployment_url="$(deployment_console_url "$control_plane_url" "$deployment_id")"
      fi
      echo "deployment-id=$deployment_id" >> "${GITHUB_OUTPUT:-/dev/null}"
      echo "deployment-url=$deployment_url" >> "${GITHUB_OUTPUT:-/dev/null}"
    fi
  fi

  if [ -n "$preview_id" ]; then
    echo "preview-id=$preview_id" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  echo "console-url=$control_plane_url" >> "${GITHUB_OUTPUT:-/dev/null}"
  append_step_summary
  maybe_publish_pr_comment
  exit 0
fi

if [ -n "${INPUT_SSH_HOST:-}" ] && [ -z "$state_backend" ]; then
  state_backend="ssh-pglite"
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
append_multiline_option "--env" "$environment_variables"
append_multiline_option "--secret" "$secret_variables"
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

maybe_publish_pr_comment
