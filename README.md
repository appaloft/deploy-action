# Appaloft Deploy Action

Run Appaloft deployments from GitHub Actions.

The default mode is a thin wrapper around the released `appaloft` binary for pure SSH deployments.
Self-hosted server API mode is available for repositories that already have their project,
environment, resource, and deployment target registered in an Appaloft server. In both modes, the
action does not read Appaloft project, resource, server, credential, or secret identity from
committed `appaloft.yml`.

## Basic Deploy

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: appaloft/deploy-action@v1
        with:
          version: v0.9.0
          config: appaloft.yml
          ssh-host: ${{ secrets.APPALOFT_SSH_HOST }}
          ssh-user: ${{ secrets.APPALOFT_SSH_USER }}
          ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
```

Pin `version` to an Appaloft CLI release for production workflows. `version: latest` is useful for
quick experiments, but it trades repeatability for convenience.

Minimal `appaloft.yml`:

```yaml
runtime:
  strategy: workspace-commands
  buildCommand: bun install && bun run build
  startCommand: bun run start
network:
  internalPort: 3000
```

Application secrets should be mapped by the workflow and referenced from config, not committed as
values:

```yaml
secrets:
  DATABASE_URL:
    from: ci-env:DATABASE_URL
```

## Pull Request Preview

Action-only pull request previews require a workflow file. The action does not install a webhook or
make GitHub run previews on its own.

```yaml
name: Appaloft Preview

on:
  pull_request:
    types: [opened, reopened, synchronize]

jobs:
  preview:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    environment:
      name: preview-pr-${{ github.event.pull_request.number }}
      url: ${{ steps.deploy.outputs.preview-url }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}

      - uses: appaloft/deploy-action@v1
        id: deploy
        with:
          version: v0.9.0
          config: appaloft.preview.yml
          preview: pull-request
          preview-id: pr-${{ github.event.pull_request.number }}
          preview-domain-template: pr-${{ github.event.pull_request.number }}.preview.example.com
          preview-tls-mode: disabled
          require-preview-url: true
          pr-comment: true
          github-token: ${{ github.token }}
          ssh-host: ${{ secrets.APPALOFT_SSH_HOST }}
          ssh-user: ${{ secrets.APPALOFT_SSH_USER }}
          ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
          environment-variables: |
            HOST=0.0.0.0
            PORT=3000
          secret-variables: |
            DATABASE_URL=ci-env:DATABASE_URL
```

The default example skips fork pull requests before deployment credentials are exposed. Fork
previews need an explicit reduced-credential policy.

Use `appaloft.preview.yml` when the root config is production-oriented. Preview route intent should
come from generated/default access, this trusted `preview-domain-template`, or an explicitly
selected preview config file. Production `access.domains[]` should not be reinterpreted as pull
request preview hostnames.

## Preview Cleanup

Add a separate close-event workflow so preview runtime and route state are cleaned when the pull
request closes:

```yaml
name: Appaloft Preview Cleanup

on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - uses: appaloft/deploy-action@v1
        with:
          command: preview-cleanup
          version: v0.9.0
          config: appaloft.preview.yml
          preview: pull-request
          preview-id: pr-${{ github.event.pull_request.number }}
          pr-comment: true
          github-token: ${{ github.token }}
          ssh-host: ${{ secrets.APPALOFT_SSH_HOST }}
          ssh-user: ${{ secrets.APPALOFT_SSH_USER }}
          ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
```

Cleanup is idempotent. It stops preview-owned runtime state when present, removes preview route
desired state, unlinks preview source identity, and preserves production deployments and ordinary
deployment history.

## Self-Hosted Server API Mode

Use this mode when a self-hosted Appaloft server owns deployment state and the repository should
only trigger a deployment through the server API. The resource profile must already exist in the
server; this first slice does not apply `appaloft.yml`, upload a source archive, create resources,
or apply preview route/profile inputs from the runner.

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    environment:
      name: production
      url: ${{ steps.deploy.outputs.console-url }}
    steps:
      - uses: appaloft/deploy-action@v1
        id: deploy
        with:
          control-plane-mode: self-hosted
          control-plane-url: https://console.example.com
          appaloft-token: ${{ secrets.APPALOFT_TOKEN }}
          project-id: ${{ secrets.APPALOFT_PROJECT_ID }}
          environment-id: ${{ secrets.APPALOFT_ENVIRONMENT_ID }}
          resource-id: ${{ secrets.APPALOFT_RESOURCE_ID }}
          server-id: ${{ secrets.APPALOFT_SERVER_ID }}
```

Server API mode performs a lightweight compatibility check against `/api/version`, derives a safe
source fingerprint from GitHub repository context and config path, and calls
`POST /api/action/deployments/from-source-link`. When trusted ids are supplied, the server can use
them to bootstrap a missing source link before later runs omit ids. When ids are omitted, the server
resolves project, environment, resource, and target from existing source-link state. It does not
install or invoke the Appaloft CLI, open SSH, or read or write SSH-server PGlite state.

For `preview: pull-request`, server API mode derives a preview-scoped source fingerprint and calls
the same deployment endpoint. It writes `preview-id`, `deployment-id`, `deployment-url`, and
`console-url` outputs, but it does not apply `preview-domain-template`, `preview-tls-mode`,
`require-preview-url`, `runtime-name`, `environment-variables`, or `secret-variables` in server
mode.

```yaml
- uses: appaloft/deploy-action@v1
  id: deploy
  with:
    control-plane-mode: self-hosted
    control-plane-url: https://console.example.com
    appaloft-token: ${{ secrets.APPALOFT_TOKEN }}
    preview: pull-request
    preview-id: pr-${{ github.event.pull_request.number }}
    project-id: ${{ secrets.APPALOFT_PROJECT_ID }}
    environment-id: ${{ secrets.APPALOFT_PREVIEW_ENVIRONMENT_ID }}
    resource-id: ${{ secrets.APPALOFT_PREVIEW_RESOURCE_ID }}
    server-id: ${{ secrets.APPALOFT_SERVER_ID }}
```

For `command: preview-cleanup`, server API mode derives the preview-scoped source fingerprint from
the trusted `preview` and `preview-id` inputs and calls `POST /api/deployments/cleanup-preview`.
Cleanup context is resolved from source-link state; project/resource/server ids are not accepted for
server-mode preview cleanup.

Server API mode writes the console URL and deployment detail URL to the GitHub step summary when
GitHub provides `GITHUB_STEP_SUMMARY`. When the server response includes a deployment href or URL,
the action uses that server-provided console target; otherwise it falls back to the standard
`/deployments/{deploymentId}` console route. For cleanup it writes the console URL and cleanup
status. Workflows can also use the `console-url` or `deployment-url` output for environment URLs or
PR comments.

When `pr-comment: true`, the action posts or updates one stable pull request comment with the
preview URL, console URL, deployment detail URL, or cleanup status that is available for the
selected mode.
The workflow must pass `github-token: ${{ github.token }}` and grant `pull-requests: write` or
`issues: write`. This is entrypoint feedback only; product-grade GitHub App comments/checks remain
control-plane features. Comment publishing is best-effort: GitHub API permission failures are
reported as warnings and do not fail an otherwise successful deployment or cleanup.

The control-plane connection policy can live in `appaloft.yml`:

```yaml
controlPlane:
  mode: self-hosted
  url: https://console.example.com
```

Explicit action inputs override config values. Project, environment, resource, server, token, SSH,
and database identity still come from trusted workflow inputs, variables, secrets, existing
source-link state, or the Appaloft server, not from committed config.

## Inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `command` | `deploy` | `deploy` or `preview-cleanup`. |
| `version` | `latest` | Appaloft CLI release tag such as `v0.9.0`. |
| `config` | empty | Optional Appaloft config path. If omitted, `appaloft.yml` is used only when present. |
| `source` | `.` | Source path or locator passed to the CLI. |
| `runtime-name` | empty | Trusted runtime name override for deploy. |
| `ssh-host` | empty | SSH target host for pure SSH deployments. |
| `ssh-user` | empty | SSH username. |
| `ssh-port` | empty | SSH port. |
| `ssh-private-key` | empty | SSH private key value, written to a temp file before invoking Appaloft. |
| `ssh-private-key-file` | empty | Existing runner-local private key path. Mutually exclusive with `ssh-private-key`. |
| `server-provider` | `generic-ssh` | Server provider key. |
| `server-proxy-kind` | empty | Server proxy kind such as `traefik` or `caddy`. |
| `state-backend` | empty | Explicit state backend. SSH targets default to `ssh-pglite`. |
| `environment-variables` | empty | Newline-separated values passed as repeated CLI `--env` flags in pure SSH CLI mode. |
| `secret-variables` | empty | Newline-separated values passed as repeated CLI `--secret` flags in pure SSH CLI mode. Prefer `ci-env:` references over raw secret values. |
| `preview` | empty | Use `pull-request` for PR preview deploy or cleanup. |
| `preview-id` | empty | Trusted preview scope, for example `pr-123`. Required for pull request previews. |
| `preview-domain-template` | empty | Trusted preview hostname for deploy, for example `pr-123.preview.example.com`. |
| `preview-tls-mode` | empty | Preview TLS mode for `preview-domain-template`. |
| `require-preview-url` | `false` | Fail deploy if no public preview URL can be resolved. |
| `pr-comment` | `false` | Post or update one pull request comment with preview, deployment, cleanup, and console feedback. |
| `github-token` | empty | GitHub token used only when `pr-comment` is true. |
| `control-plane-mode` | empty | Use `none` for pure SSH CLI mode or `self-hosted` for server API mode. When empty, `controlPlane.mode` from config may select the mode; otherwise the effective default is `none`. |
| `control-plane-url` | empty | Self-hosted Appaloft server endpoint for server API mode. When empty, `controlPlane.url` from config may supply the endpoint. |
| `appaloft-token` | empty | Optional bearer token for server API mode. |
| `use-oidc` | `false` | Reserved for future GitHub OIDC exchange. |
| `project-id` | empty | Optional trusted project id for server API mode. When supplied with environment/resource/server ids, the server may bootstrap a missing source link. When omitted with the other ids, the server resolves context from source-link state. |
| `environment-id` | empty | Optional trusted environment id for server API mode. Required only when any explicit deployment id is supplied. |
| `resource-id` | empty | Optional trusted resource id for server API mode. Required only when any explicit deployment id is supplied. |
| `server-id` | empty | Optional trusted deployment target id for server API mode. Required only when any explicit deployment id is supplied. |
| `destination-id` | empty | Optional trusted destination id for server API mode. |

## Outputs

| Output | Purpose |
| --- | --- |
| `appaloft-version` | Installed CLI version. |
| `appaloft-target` | Selected release target. |
| `preview-id` | Preview id when preview mode is selected. |
| `preview-url` | Public preview URL when Appaloft resolves one during deploy. |
| `deployment-id` | Deployment id accepted by Appaloft. |
| `deployment-url` | Self-hosted Appaloft console deployment detail URL when available. |
| `console-url` | Self-hosted Appaloft console URL used by server API mode. |
| `preview-cleanup-status` | Cleanup status returned by server API mode for `command: preview-cleanup`. |

## Security Notes

- `ssh-private-key` is written to a runner temp file with mode `0600`; raw key material is not
  passed as a command-line argument.
- Do not commit SSH keys, tokens, database URLs, production secret values, or Appaloft identity
  selectors into `appaloft.yml`.
- The action defaults SSH deployments to server-owned `ssh-pglite` state when `ssh-host` is set and
  no control plane is selected.
- `control-plane-mode: self-hosted` does not accept SSH keys or `state-backend`; the action calls
  the Appaloft server API and leaves state ownership with the server.
- In self-hosted server API mode, preview deploy accepts trusted `preview` and `preview-id` inputs
  only for source fingerprinting and feedback outputs. Preview route/profile inputs remain
  rejected until the server owns that policy. `command: preview-cleanup` accepts only source/config
  and trusted preview scope inputs. Deployment target ids are intentionally ignored/rejected for
  cleanup because cleanup resolves from server-owned source-link state.
- `pr-comment` requires explicit workflow permission and token wiring. The action updates the same
  marker comment for the PR instead of creating a new comment on each run. Comment API failures are
  warnings so they do not mask a successful deployment.

## Product-Grade Previews

This action supports workflow-file previews. Product-grade previews with GitHub App webhooks,
preview policy, comments/checks, cleanup retries, quotas, audit, and managed domain lifecycle are
future Appaloft Cloud or self-hosted control-plane features.
