# deploy-action

Deploy a repository with Appaloft from GitHub Actions.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: appaloft/deploy-action@v1
        with:
          version: latest
          config: appaloft.yml
          target-host: ${{ vars.APPALOFT_TARGET_HOST }}
          target-ssh-username: deploy
          target-private-key: ${{ secrets.APPALOFT_SSH_PRIVATE_KEY }}
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

## Repository Config

Keep app config in `appaloft.yml`, but do not commit project ids, server ids, or raw secret values.
For secrets, reference CI-provided environment variables:

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

The workflow maps GitHub secrets into runner environment variables:

```yaml
env:
  DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

## Stateless Default

The default GitHub Actions path is a one-shot binary workflow:

- installs `@appaloft/cli` through `appaloft/setup-appaloft@v1`;
- uses embedded PGlite for Appaloft's own temporary runtime state;
- does not require `DATABASE_URL` for Appaloft itself;
- does not require `APPALOFT_PROJECT_ID`;
- creates or reuses temporary project, environment, server, and resource records through normal
  Appaloft commands before dispatching an ids-only deployment.

Application secrets such as `DATABASE_URL` are still normal app runtime secrets and should be
provided through GitHub Actions `secrets` and `ci-env:` references.

## Stateful Mode

When a workflow should deploy against existing Appaloft state, pass explicit ids:

```yaml
- uses: appaloft/deploy-action@v1
  with:
    project-id: ${{ vars.APPALOFT_PROJECT_ID }}
    server-id: ${{ vars.APPALOFT_SERVER_ID }}
    environment-id: ${{ vars.APPALOFT_ENVIRONMENT_ID }}
    resource-id: ${{ vars.APPALOFT_RESOURCE_ID }}
```

That mode is for a hosted control plane, a self-hosted Appaloft service, or a durable local state
setup. It is not required for the default ephemeral GitHub Actions flow.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `latest` | Appaloft CLI version or npm dist-tag. |
| `config` | `appaloft.yml` | Path to the Appaloft deployment config file. |
| `path-or-source` | `.` | Local path, git source, image source, or remote source to deploy. |
| `method` | | Deployment method override. |
| `project-id` | | Existing project id for stateful deployments. |
| `server-id` | | Existing server id for stateful deployments. |
| `destination-id` | | Existing destination id. |
| `environment-id` | | Existing environment id for stateful deployments. |
| `resource-id` | | Existing resource id for stateful deployments. |
| `resource-name` | | Resource name to create or reuse when `resource-id` is not supplied. |
| `resource-kind` | | Resource kind to create when `resource-id` is not supplied. |
| `resource-description` | | Resource description to create when `resource-id` is not supplied. |
| `target-host` | | SSH host for first-run remote target bootstrap. |
| `target-name` | | SSH server name for first-run remote target bootstrap. |
| `target-provider` | | Server provider key. Defaults to `generic-ssh` when `target-host` is supplied. |
| `target-port` | | SSH port. The CLI defaults to `22` when omitted. |
| `target-proxy-kind` | | Edge proxy kind, for example `traefik`, `caddy`, or `none`. |
| `target-ssh-username` | | SSH username for the target server. |
| `target-ssh-public-key` | | Public key metadata for the SSH credential. |
| `target-private-key` | | SSH private key material from a GitHub secret. |
| `target-private-key-file` | | Path to an SSH private key file already present on the runner. |
| `install` | | Install command override. |
| `build` | | Build command override. |
| `start` | | Start command override. |
| `publish-dir` | | Static publish directory override. |
| `port` | | Application port override. |
| `health-path` | | Health check path override. |
| `app-log-lines` | `3` | Number of application log lines to print after deployment. |

## Release Model

This action is a thin wrapper around the Appaloft CLI. Normal Appaloft releases update the npm CLI
packages; workflows using `version: latest` pick those up without a deploy-action repo change.
Release this action only when the GitHub Actions wrapper behavior changes.
