# deploy-action

Deploy a repository with Appaloft from GitHub Actions.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: appaloft/deploy-action@v0
        with:
          version: latest
          config: appaloft.yml
          ssh-host: ${{ vars.APPALOFT_SSH_HOST }}
          ssh-user: deploy
          ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

## Repository Config

Keep deployment intent in `appaloft.yml`, but do not commit raw secret values or trusted hosted
control-plane ids.

```yaml
runtime:
  build: npm run build
  start: npm run start

network:
  port: 3000

secrets:
  DATABASE_URL:
    from: ci-env:DATABASE_URL
```

GitHub Actions supplies application secrets through normal workflow environment variables:

```yaml
env:
  DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

## Remote State Default

This action is a thin, checked binary wrapper around the Appaloft CLI:

- downloads an Appaloft CLI release asset from GitHub Releases;
- verifies the asset with `checksums.txt` before adding it to `PATH`;
- writes `ssh-private-key` to a temporary `0600` file and passes only the file path to the CLI;
- invokes `appaloft deploy` with the same config-file flow used by the CLI;
- defaults Appaloft's own state to `ssh-pglite` when `ssh-host` is provided.

The GitHub runner is not the durable Appaloft state store in the default SSH path. Application
secrets such as `DATABASE_URL` are separate from Appaloft's own state and should be provided through
GitHub Actions `secrets` plus `ci-env:` references in `appaloft.yml`.

## No Config

If `config` is omitted and `appaloft.yml` does not exist, the action does not pass `--config`.
Deployment can still run from direct action inputs and CLI detection:

```yaml
- uses: appaloft/deploy-action@v0
  with:
    source: .
    ssh-host: ${{ vars.APPALOFT_SSH_HOST }}
    ssh-user: deploy
    ssh-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
```

If `appaloft.yml` exists, the action passes `--config appaloft.yml`. A config file without
`access.domains[]` does not bind a custom domain; provider-local TLS diagnostics can still run for
the provider default route.

## Hosted Or Self-Hosted Control Plane

The first public path does not require `APPALOFT_PROJECT_ID`. Trusted ids are advanced overrides for
a hosted Appaloft service or self-hosted control plane:

```yaml
- uses: appaloft/deploy-action@v0
  with:
    project-id: ${{ vars.APPALOFT_PROJECT_ID }}
    server-id: ${{ vars.APPALOFT_SERVER_ID }}
    environment-id: ${{ vars.APPALOFT_ENVIRONMENT_ID }}
    resource-id: ${{ vars.APPALOFT_RESOURCE_ID }}
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `latest` | Appaloft CLI GitHub Release tag, or `latest`. |
| `config` | `appaloft.yml` | Path to `appaloft.yml`. The default is passed only when the file exists. |
| `source` | `.` | Local path, git source, image source, or remote source to deploy. |
| `method` | | Deployment method override. |
| `ssh-host` | | SSH host for remote Appaloft state and deployment execution. |
| `ssh-user` | | SSH username for the target server. |
| `ssh-port` | | SSH port. The CLI defaults to `22` when omitted. |
| `ssh-private-key` | | SSH private key material from a GitHub secret. |
| `ssh-private-key-file` | | Path to an SSH private key file already present on the runner. |
| `server-proxy-kind` | | Edge proxy kind, for example `traefik`, `caddy`, or `none`. |
| `state-backend` | `ssh-pglite` when `ssh-host` is set | Appaloft state backend override. |
| `args` | | Additional Appaloft CLI arguments appended after translated inputs. |
| `project-id` | | Advanced trusted project id override. |
| `server-id` | | Advanced trusted server id override. |
| `destination-id` | | Advanced trusted destination id override. |
| `environment-id` | | Advanced trusted environment id override. |
| `resource-id` | | Advanced trusted resource id override. |
| `resource-name` | | Resource name to create or reuse when `resource-id` is not supplied. |
| `resource-kind` | | Resource kind to create when `resource-id` is not supplied. |
| `resource-description` | | Resource description to create when `resource-id` is not supplied. |
| `install` | | Install command override. |
| `build` | | Build command override. |
| `start` | | Start command override. |
| `publish-dir` | | Static publish directory override. |
| `port` | | Application port override. |
| `health-path` | | Health check path override. |
| `app-log-lines` | `3` | Number of application log lines to print after deployment. |

Legacy `target-*` and `path-or-source` inputs remain accepted as aliases for older workflows.

## Release Model

This repo is released only when the GitHub Actions wrapper changes. CLI changes ship from the main
Appaloft repo as GitHub Release assets. Workflows using `version: latest` pick up the newest CLI
release without requiring a deploy-action repo release.

## License

Apache-2.0.
