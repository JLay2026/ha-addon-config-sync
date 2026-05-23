# Config Sync (GitOps)

Automatically sync your Home Assistant configuration from a GitHub repository.
Changes merged to your branch are pulled on a schedule, validated against
HA's config checker, and applied with an automatic reload. If validation
fails, the change is rolled back and the error is logged.

## How it works

1. The add-on clones your GitHub config repo on first start.
2. Every `check_interval` seconds it runs `git fetch` to check for new commits.
3. When new commits are found, it identifies which files changed.
4. Only files matching your `sync_paths` allowlist are copied to `/config`.
5. HA's config checker validates the result via the Supervisor API.
6. If valid, HA reloads automatically. If invalid, the files are rolled
   back to their previous state and the error is logged.

## Configuration

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `github_repo` | Yes | — | Full HTTPS URL of your config repo |
| `branch` | No | `main` | Branch to track |
| `check_interval` | No | `300` | Seconds between sync checks (60–3600) |
| `sync_paths` | No | See below | List of file/directory paths to sync |
| `github_pat` | No | — | GitHub Personal Access Token (only for private repos) |

### sync_paths

Controls which files from the repo are eligible to be copied into `/config`.
Paths ending in `/` are treated as directory prefixes (everything underneath
is included). All other entries are exact filename matches.

Default paths:

- `configuration.yaml`
- `automations.yaml`
- `scripts.yaml`
- `scenes.yaml`
- `groups.yaml`
- `customize.yaml`
- `packages/`
- `dashboards/`

Files in the repo that don't match any `sync_paths` entry are ignored
(e.g., `README.md`, `.github/`, `scripts/`). This prevents repo metadata
from being copied into your HA config directory.

### Private repos

If your config repo is private, create a GitHub Personal Access Token
(classic, with `repo` scope) and paste it into `github_pat`. The token
is stored encrypted in HA's add-on options. For public repos, leave this
field empty.

## Security

- **No manual tokens.** The add-on uses the auto-injected `$SUPERVISOR_TOKEN`
  to communicate with HA's API. No long-lived access token needed.
- **No Samba.** The add-on accesses `/config` directly via the Supervisor's
  `map: config:rw` mechanism — same trust level as File Editor or Studio
  Code Server.
- **No inbound ports.** The add-on only makes outbound HTTPS calls to GitHub.
- **Rollback on failure.** If a config change breaks validation, it's
  automatically reverted before HA tries to load it.
- **GitHub PAT** (if used) is stored in HA's encrypted add-on option store,
  never written to disk in the container.

## Logs

Check the **Log** tab in the add-on panel. Typical log entries:

```
[config-sync] First run — cloning https://github.com/user/repo (branch: main)
[config-sync] Clone complete
[config-sync] Starting sync loop — checking every 300s
[config-sync] Change detected: abc12345 -> def67890
[config-sync] Syncing: configuration.yaml automations.yaml
[config-sync] Config valid — reloading Home Assistant
[config-sync] Reload complete (abc12345 -> def67890)
```

On failure:

```
[config-sync] Config invalid: Integration 'nonexistent' not found
[config-sync] Rolling back to abc12345
```

## Workflow

The intended workflow for managing your HA config:

1. Edit config files in your GitHub repo (directly or via pull request).
2. Merge to the tracked branch.
3. Within `check_interval` seconds, the add-on pulls the change.
4. If valid, HA reloads with the new config.
5. If invalid, the change is rolled back — HA stays on the last good config.

## Agent integration

The add-on can be managed programmatically via the HA Supervisor API.
Any agent or automation platform that can call the HA REST API can:

- Read/change add-on options: `GET/POST /addons/config-sync/options`
- Start/stop/restart: `POST /addons/config-sync/{start,stop,restart}`
- Read logs: `GET /addons/config-sync/logs`
- Check status: `GET /addons/config-sync/info`

This makes it compatible with NanoClaw's `agent-homeops`, Home Assistant
automations, or any future agent platform.
