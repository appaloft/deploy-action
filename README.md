# Appaloft Deploy Action

Install the Appaloft CLI in GitHub Actions and run the repository deployment workflow.

This action is a thin wrapper around the released `appaloft` binary. It does not create a hosted
control plane, does not add a new deployment command, and does not read Appaloft project, resource,
server, credential, or secret identity from committed `appaloft.yml`.

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
          ssh-host: ${{ secrets.APPALOFT_SSH_HOST }}
          ssh-user: ${{ secrets.APPALOFT_SSH_USER }}
          ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
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
    steps:
      - uses: actions/checkout@v4

      - uses: appaloft/deploy-action@v1
        with:
          command: preview-cleanup
          version: v0.9.0
          config: appaloft.preview.yml
          preview: pull-request
          preview-id: pr-${{ github.event.pull_request.number }}
          ssh-host: ${{ secrets.APPALOFT_SSH_HOST }}
          ssh-user: ${{ secrets.APPALOFT_SSH_USER }}
          ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
```

Cleanup is idempotent. It stops preview-owned runtime state when present, removes preview route
desired state, unlinks preview source identity, and preserves production deployments and ordinary
deployment history.

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
| `preview` | empty | Use `pull-request` for PR preview deploy or cleanup. |
| `preview-id` | empty | Trusted preview scope, for example `pr-123`. Required for pull request previews. |
| `preview-domain-template` | empty | Trusted preview hostname for deploy, for example `pr-123.preview.example.com`. |
| `preview-tls-mode` | empty | Preview TLS mode for `preview-domain-template`. |
| `require-preview-url` | `false` | Fail deploy if no public preview URL can be resolved. |
| `control-plane-mode` | `none` | Reserved for future Cloud/self-hosted control-plane mode. |
| `control-plane-url` | empty | Reserved for future control-plane endpoint. |
| `appaloft-token` | empty | Reserved for future control-plane token. |
| `use-oidc` | `false` | Reserved for future GitHub OIDC exchange. |

## Outputs

| Output | Purpose |
| --- | --- |
| `appaloft-version` | Installed CLI version. |
| `appaloft-target` | Selected release target. |
| `preview-id` | Preview id when preview mode is selected. |
| `preview-url` | Public preview URL when Appaloft resolves one during deploy. |

## Security Notes

- `ssh-private-key` is written to a runner temp file with mode `0600`; raw key material is not
  passed as a command-line argument.
- Do not commit SSH keys, tokens, database URLs, production secret values, or Appaloft identity
  selectors into `appaloft.yml`.
- The action defaults SSH deployments to server-owned `ssh-pglite` state when `ssh-host` is set and
  no control plane is selected.
- Control-plane inputs are reserved until the Appaloft CLI handshake is active; non-`none` values
  fail before mutation.

## Product-Grade Previews

This action supports workflow-file previews. Product-grade previews with GitHub App webhooks,
preview policy, comments/checks, cleanup retries, quotas, audit, and managed domain lifecycle are
future Appaloft Cloud or self-hosted control-plane features.
