# Config Sync (GitOps)

GitOps for Home Assistant. A Git repository is the source of truth for
`/config`: the add-on pulls each new commit, validates it with Home
Assistant's own config checker, reloads the right amount, verifies HA is
healthy afterwards, and rolls back if anything fails. With export enabled
it also commits UI-made changes back to the repository.

Contents: [How it works](#how-it-works) · [Configuration](#configuration) ·
[Paths](#paths) · [Reload strategy](#reload-strategy) ·
[Change handling and rollback](#change-handling-and-rollback) ·
[Backups](#backups) · [Security](#security) ·
[Observability](#observability) · [Troubleshooting](#troubleshooting) ·
[API and agent integration](#api-and-agent-integration) ·
[Upgrade notes](#upgrade-notes) · [Platforms](#platforms)

## How it works

### Import (GitHub → HA)

The add-on clones `github_repo` into `/data/repo` on first start, then
every `check_interval` seconds runs one import cycle:

```
 git fetch ──► new commit? ──no──► sleep
                  │ yes
                  ▼
 diff LOCAL..REMOTE (--no-renames), filter by sync_paths / exclude_paths
                  │
                  ▼
 guards ─ sync_paths gap ─ tracked symlinks ──fail──► abort, reset, notify
                  │ pass
                  ▼
 pre-sync HA backup  gitops-pre-<sha> ──fail──► abort, reset, retry next cycle
                  │
                  ▼
 snapshot affected files ─► copy A/M, delete D ─► reconcile missing tracked files
                  │
                  ▼
 check_config ──invalid──► restore snapshot, remove added files, reset, notify
                  │ valid
                  ▼
 reload_all │ + frontend.reload_themes │ core/restart   (see Reload strategy)
                  │
                  ▼
 settle, probe states/sun.sun and /core/api/ ──fail──► rollback as above
                  │ pass
                  ▼
 sensor.config_sync_status = success, dismiss notification, prune old backups
```

Only files that match the allowlist (`sync_paths` minus `exclude_paths`)
are ever touched; everything else in the commit is listed in the log as
skipped. A cycle with nothing syncable does no work and leaves no trace
beyond one log line.

Outbound calls are bounded: git transfers abort if they fall below
1 KB/s for 60 s; Supervisor API calls use a 5 s connect timeout and a
90 s overall timeout.

### Export (HA → GitHub)

With `export_enabled: true` the add-on runs an export on startup and then
every `export_interval` seconds (rounded to a whole number of import
cycles). Each export checks out `export_branch`, copies the allowlisted
files from `/config` into the working tree, and commits and pushes only
if `git diff --cached` shows a change. Commits are authored
`HA Config Sync <config-sync@homeassistant.local>` with the message
`<export_commit_message> (<timestamp>)` and the file list in the body.

Export copies only `*.yaml` / `*.yml` under directory entries (exact-file
entries are copied regardless of extension). Non-YAML assets such as
`www/` therefore flow repo → `/config` only; treat the repository as the
sole editor for those.

When `export_branch` differs from `branch`, exports never land on the
import branch by themselves — review them as a pull request. This is the
recommended bidirectional setup: the live `/config` is captured, but the
import branch only moves through review.

## Configuration

### Import options

| Option | Default | Description |
|---|---|---|
| `github_repo` | — (required) | HTTPS URL of the config repository. Its host must be in `allowed_repo_hosts`. |
| `branch` | `main` | Branch to import from. |
| `check_interval` | `300` | Seconds between import cycles (60–3600). |
| `sync_paths` | see [Paths](#paths) | Allowlist of files and directories that may move in either direction. |
| `exclude_paths` | `[]` | Paths subtracted from `sync_paths` in both directions (v1.7.0+). |
| `github_pat` | — | Personal access token. Needed for private repositories and for export. UI-masked. |
| `post_sync_settle_seconds` | `5` | Wait after the reload before running the verification probes (0–60). A core restart adds a fixed extra settle on top. |
| `restart_on_lovelace_change` | `true` | Use `homeassistant.restart` instead of `reload_all` when the diff touches the `lovelace:` key of `configuration.yaml`. |
| `notify_on_failure` | `true` | Raise an HA persistent notification on every failed sync; dismiss it on the next success. |
| `strict_sync_paths_check` | `true` | Abort the sync when `configuration.yaml` has `!include_dir_*` directives pointing outside `sync_paths` and the commit touches files there (v1.5.1+). |
| `allowed_repo_hosts` | `["github.com"]` | Hostnames `github_repo` may point at; suffix match, so `github.com` also admits its subdomains. An empty list falls back to the default (v1.6.0+). |
| `block_symlinks` | `true` | Abort the sync if any tracked file in `sync_paths` is a symlink (v1.6.0+). |
| `pre_sync_backup_retention` | `7` | Number of pre-sync backups to keep; `0` disables pruning (v1.5.2+). |
| `pre_sync_backup_name_prefix` | `gitops-pre-` | Name prefix for pre-sync backups. Pruning matches on this prefix, so backups made under an older prefix are left alone (v1.6.2+). |
| `pre_sync_backup_password` | — | Encrypt pre-sync backups with this password. Empty leaves them unencrypted. UI-masked (v1.7.1+). |

### Export options

| Option | Default | Description |
|---|---|---|
| `export_enabled` | `false` | Enable HA → GitHub export. Requires `github_pat`. |
| `export_interval` | `3600` | Seconds between export checks (300–86400). |
| `export_branch` | same as `branch` | Branch exports are committed and pushed to. |
| `export_commit_message` | `export: HA config snapshot` | Commit message prefix. |

### Permissions the add-on requests

| Permission | Used for |
|---|---|
| `homeassistant_api: true` | `check_config`, `reload_all`, `frontend.reload_themes`, `homeassistant.restart`, verification probes, persistent notifications, `sensor.config_sync_status` |
| `hassio_api: true` + `hassio_role: backup` | Create, list and delete backups (the least-privilege role that covers the backups API) |
| `map: config:rw` | Read and write `/config` directly |

No ports are opened. The add-on makes outbound HTTPS to the repository
host and HTTP to the Supervisor; nothing inbound.

## Paths

### sync_paths

An entry ending in `/` is a directory prefix; any other entry is an exact
file path relative to `/config`. The allowlist applies to import, export,
the reconcile pass and the symlink guard alike. Defaults:

```yaml
sync_paths:
  - configuration.yaml
  - automations.yaml
  - scripts.yaml
  - scenes.yaml
  - groups.yaml
  - customize.yaml
  - packages/
  - dashboards/
  - scripts/
```

Common additions: `themes/`, `lovelace/`, `custom_templates/`,
`blueprints/`, `esphome/`, `www/`.

If `configuration.yaml` contains an `!include_dir_*` directive pointing at
a directory that is not in `sync_paths`, HA will expect files the add-on
is not allowed to deliver. The add-on warns about every such directive at
startup, and with `strict_sync_paths_check` on it aborts any sync whose
commit touches files under such a directory, printing the `sync_paths`
entry to add.

### exclude_paths

Same syntax as `sync_paths`, evaluated first, and always wins: an excluded
path is never imported, exported, reconciled or symlink-checked. The
canonical use is tracking ESPHome device definitions without the secrets
file or build cache:

```yaml
sync_paths:
  - configuration.yaml
  - packages/
  - esphome/
exclude_paths:
  - esphome/secrets.yaml
  - esphome/.esphome/
  - esphome/trash/
```

## Reload strategy

After `check_config` passes, the add-on picks the smallest reload that
makes the change take effect:

| Change set | Action | Sensor `last_strategy` |
|---|---|---|
| Anything else | `homeassistant.reload_all` | `reload_all` |
| Any file under `themes/` | `reload_all` then `frontend.reload_themes` | `reload_all_plus_themes` |
| `configuration.yaml` changed and its diff touches `lovelace` (and `restart_on_lovelace_change` is on) | `homeassistant.restart` | `core_restart` |

`reload_all` does not re-register dashboards declared under
`lovelace.dashboards`, which is why that case restarts. The detection is
a text match on the diff, so a comment mentioning "lovelace" costs an
unnecessary restart rather than a missed one.

Home Assistant refuses to restart while a backup is being written. Before
a core restart the add-on therefore waits for the pre-sync backup it just
requested to appear in the backup list (polling every 5 s, up to 10 min),
then calls restart up to three times 15 s apart. If every attempt is
refused, it raises the persistent notification *Config Sync: HA restart
needed*; the files are already in place and a manual restart completes
the change.

Changes that `reload_all` cannot apply at all — recorder settings, new
integrations in `configuration.yaml` — still need a manual restart; the
log says `reload_all complete` because the call succeeded, not because
every change is live.

## Change handling and rollback

The change list for a cycle is `git diff --name-only --no-renames
LOCAL REMOTE`, filtered by the allowlist. Rename detection is off so that
a renamed file appears as a delete of the old path plus an add of the new
one; both are applied in the same cycle (v1.7.2+). The log tags every
path with its operation as seen from `/config` before the sync:

```
Import: syncing D:packages/old.yaml A:packages/new.yaml M:dashboards/main.yaml
Import: deleted packages/old.yaml
```

- **A** — new to `/config`: copied in.
- **M** — exists in both: overwritten.
- **D** — gone from the repository: deleted from `/config`.

After the copy, a reconcile pass walks every tracked file under the
allowlist and copies any that is missing from `/config` — this catches a
file that was in the repository before the add-on was installed and was
never part of a diff.

**Rollback.** Before copying, the add-on snapshots every affected file
that already exists in `/config` to `/data/.rollback/<sha>/` (the last
five snapshots are kept). If `check_config` rejects the result, the
Supervisor cannot be reached, or the post-reload probes fail, the add-on
restores the snapshot, removes the files the sync had added (they have no
pre-sync copy to restore), resets the repository clone to `LOCAL`, and
raises a notification. Because the clone is reset, the next cycle sees
the same commit again and retries — fix the configuration in the
repository and push; the retry picks it up.

The file-level snapshot is the fast path. The pre-sync HA backup is the
independent safety net for the case where HA itself is left unhealthy and
the best-effort re-reload after rollback does not recover it: restore it
from **Settings → System → Backups**; its name is in the notification and
in the sensor's `last_backup_name`.

## Backups

Before any file is touched, the add-on requests a partial HA backup of
the `homeassistant` folder — `/config` *and* `.storage`, which holds every
integration credential HA has. The backup is named
`<pre_sync_backup_name_prefix><short sha>` and is created in the
background so a large recorder database does not block the sync.

Set `pre_sync_backup_password` to the same password as your scheduled
backups so one restore flow covers both; the log and the per-sync event
carry `encrypted=true|false`. Backups whose name starts with the
configured prefix are pruned at the end of each sync down to
`pre_sync_backup_retention`; backups made under a different prefix are
never touched.

If the backup request fails, the sync aborts before touching `/config`,
the clone is reset, and the cycle retries next time. The log prints the
Supervisor's HTTP status and the usual causes.

## Security

### GitHub personal access token

A PAT is required to import from a private repository and to push
exports. Public-repository import works without one.

Use a **fine-grained token** scoped to the single config repository with
*Repository permissions → Contents: Read and write* — the minimum for
clone and push, and the real blast-radius control if the token leaks.
Give it an expiry and rotate by pasting the new value into the add-on
configuration. A classic token with the `repo` scope also works but
grants access to every repository you own.

At runtime the token lives only in the environment of the `run.sh`
process (`GH_CONFIG_SYNC_PAT`). Git is configured with an inline
credential helper that reads that variable at command time, so
`/data/repo/.git/config` holds the literal helper string and never the
token itself; the remote URL is the plain HTTPS form; and every captured
git or curl error passes through a scrubber before it reaches the add-on
log or the per-sync log files. Anyone with root in the running container
can still read the process environment — the point is that the token is
not on the persistent `/data` volume, in a backup, or in a log.

The Supervisor stores the option encrypted at rest and masks it in the
UI. Its options API still returns the value to admin-scoped callers, so
treat anything with Supervisor admin access as able to read the token.

### Repository host allowlist

Before any clone or fetch the add-on checks that the host in
`github_repo` matches `allowed_repo_hosts` (suffix match; default
`github.com`). A URL pointing anywhere else makes the add-on refuse to
start with a multi-line error naming the host and the option to change.
Without this guard a mistyped URL would present the PAT to an arbitrary
server on the first fetch. GitHub Enterprise users add their hostname to
the list.

### Tracked-symlink guard

Before the backup and copy steps, the add-on checks whether any tracked
file matching the allowlist is a symlink in the repository. If so the
sync aborts, listing each symlink and its target. A committed symlink is
a path-traversal vector in both directions: copying `automations.yaml →
/etc/passwd` would expose the target; copying over a symlink pointing at
`/data/sync_status.json` would overwrite it. Set `block_symlinks: false`
only if you use symlinks deliberately and accept that.

### sync_paths gap guard

See [Paths](#paths): a commit that touches files HA will look for but the
allowlist will not deliver is refused rather than half-applied.

## Observability

### sensor.config_sync_status

The add-on publishes a sensor through the HA REST API on startup and after
every cycle that does work. State: `idle`, `syncing`, `success`, `failed`.

| Attribute | Meaning |
|---|---|
| `last_sync_at` | UTC timestamp of the last state change |
| `last_sha_short` | First 8 characters of the commit being applied |
| `last_strategy` | `reload_all`, `reload_all_plus_themes` or `core_restart` (success only) |
| `last_error` | `[stage] message` on failure; empty otherwise. Stages: `pre_sync_backup`, `sync_paths_gap`, `tracked_symlinks`, `check_config_api`, `check_config_invalid`, `post_sync_verify` |
| `last_backup_name` | Pre-sync backup to restore if HA is unhealthy |
| `last_log_file` | Path of the per-sync log for this cycle |
| `sync_count` | Lifetime number of cycles that ended in `success` or `failed` |
| `failure_count` | Lifetime number of failed cycles |

The same payload is written to `/data/sync_status.json`, which is where
the lifetime counters persist across restarts and upgrades. The sensor is
state-only (no unique id), so it does not appear in the entity registry;
if HA restarts it reappears on the add-on's next write.

Dashboard tile:

```yaml
type: tile
entity: sensor.config_sync_status
```

Automation on failure:

```yaml
alias: Notify on Config Sync failure
triggers:
  - trigger: state
    entity_id: sensor.config_sync_status
    to: failed
actions:
  - action: notify.mobile_app_phone
    data:
      message: >
        Config Sync failed on {{ state_attr('sensor.config_sync_status', 'last_sha_short') }}:
        {{ state_attr('sensor.config_sync_status', 'last_error') }}.
        Backup: {{ state_attr('sensor.config_sync_status', 'last_backup_name') }}
```

### Persistent notification

With `notify_on_failure` on, every failed cycle creates the notification
`config_sync_failure` with the stage, commit and what to do next; the next
successful cycle dismisses it. The lovelace-restart path has its own
notification, *Config Sync: HA restart needed*, when all restart attempts
are refused.

### Add-on log

The rolling add-on log (Settings → Add-ons → Config Sync → Log) carries
one line per waypoint at INFO. Lines worth knowing:

```
Import: change detected (LOCAL -> REMOTE)
Import: skipped (not in sync_paths): ...
Import: syncing A:... M:... D:...
Import: deleted <path>
Pre-sync HA backup '<name>' triggered
Import: config valid — reloading Home Assistant
Import: <strategy> complete (LOCAL -> REMOTE)
Post-sync verify: both probes passed — sync verified healthy
Import: rollback removed added file <path>
Export (auto|initial): committed <files> / pushed to origin/<branch> / no changes to export
```

### Per-sync and per-export logs

Every cycle that does work writes a structured file under
`/data/logs/sync/<timestamp>-<sha>.log` (imports) or
`/data/logs/export/<timestamp>-export-<mode>.log` (exports); the last 20
of each are kept. One event per line:

```
<ISO timestamp> [LEVEL] event=<name> key=value ...
```

Import events, in pipeline order: `sync_start`, `files_changed`
(`count=`, `paths=`, `ops=` with `A:`/`M:`/`D:` tags), `sync_paths_gap`,
`tracked_symlinks`, `backup`, `backup_wait`, `reconcile`, `check_config`,
`reload`, `reload_call`, `verify` (one per probe), `backup_prune`,
`sync_end result=success|failure`. Export events: `export_start`,
`files_staged`, `commit`, `push`, `export_end`.

Read them from the add-on container (`docker exec -it
addon_<slug>_config-sync sh`) or by inspecting the add-on's `/data` from
a backup.

## Troubleshooting

| Symptom | Where to look | What it means / what to do |
|---|---|---|
| Add-on refuses to start: *github_repo host not in allowlist* | Add-on log | The URL host is not in `allowed_repo_hosts`. Fix the URL or add the host. |
| `Import: skipped (not in sync_paths)` for files you expected | Add-on log | Add the path to `sync_paths` (or remove it from `exclude_paths`). |
| Sync aborted: *sync_paths gap* | Log, notification, `last_error=[sync_paths_gap]` | `configuration.yaml` includes a directory the allowlist does not cover. Add the printed entry to `sync_paths`; the same commit retries next cycle. |
| Sync aborted: *tracked symlinks* | Log lists each symlink | Replace the symlinks in the repository with regular files, or set `block_symlinks: false`. |
| *Pre-sync backup failed* | Log shows the HTTP code | 401/403: the installed add-on lacks the backup permission (only on a stale install — update it). 5xx: the Supervisor is busy or the disk is full. `/config` was not touched; the same commit retries next cycle. |
| *check_config rejected the new config* | Notification carries HA's error text | Fix the YAML in the repository and push. `/config` was rolled back; nothing to do on the host. |
| *check_config API unreachable* | Log shows HTTP code | HA Core is down or restarting. The sync rolled back and retries next cycle. |
| *Post-sync verification failed* | Log, `last_backup_name` | HA did not answer after the reload. The add-on rolled the files back and re-reloaded; if HA is still unhealthy, restore the named backup. |
| *Config Sync: HA restart needed* | Notification | A lovelace change landed but HA refused to restart three times. Restart HA manually. |
| Dashboard/theme change synced but not visible | — | Hard-refresh the browser; for a new dashboard under `lovelace.dashboards` make sure `restart_on_lovelace_change` is on or restart HA. |
| Export: *no github_pat configured — cannot push* | Log | Add a PAT with Contents: read and write. The commit exists locally and is pushed on the next export. |
| Export commits things you did not change | `git diff` on the export branch | `/config` and the repository disagree — usually a file edited in the UI or a formatting difference. The export is telling you the truth; reconcile it in the repository. |
| Same commit retried every cycle | `last_error` | Any failure resets the clone to the previous commit on purpose. The retry stops as soon as the cause is fixed or a newer commit lands. |

## API and agent integration

Everything the add-on exposes is reachable through the Supervisor API, so
any agent or automation platform with a Supervisor token can:

- read sync state — `GET /core/api/states/sensor.config_sync_status`;
- read or change options — `GET`/`POST /addons/<slug>/options`, then
  restart the add-on to apply;
- start, stop or restart the add-on — `POST /addons/<slug>/{start,stop,restart}`;
- read the add-on log — `GET /addons/<slug>/logs`;
- read the add-on info including `version` and `update_available` —
  `GET /addons/<slug>/info`;
- update the add-on — `POST /addons/<slug>/update` (reload the store
  first with `POST /store/reload` if the new version is not yet listed).

The slug is `<repository hash>_config-sync`; `GET /addons` lists it. The
add-on itself writes nothing outside `/config`, `/data` and the sensor.

## Upgrade notes

- **1.7.2** — `armv7` and `i386` builds dropped; the add-on builds on
  Alpine 3.24 for `amd64` and `aarch64` only. Renames are now propagated
  and rollbacks remove added files; if you cleaned up after renames by
  hand, stop.
- **1.7.1** — `pre_sync_backup_password` added. Pre-sync backups made
  before this version are unencrypted and age out through retention.
- **1.7.0** — `exclude_paths` added.
- **1.6.5** — `github_pat` is masked in the UI. Export no longer disables
  itself after the first import.
- **1.6.1** — the PAT is no longer written to `.git/config`; the remote
  URL is rewritten to the plain HTTPS form on first start, no action
  needed.
- **1.6.0** — `allowed_repo_hosts` and `block_symlinks` added. GitHub
  Enterprise users must add their hostname before upgrading.

Full history: [CHANGELOG.md](CHANGELOG.md).

## Platforms

Home Assistant OS or Supervised on `amd64` or `aarch64`. The image is
built on the host from `build.yaml` at install and update time. 32-bit
platforms can run 1.7.1 but receive no further updates.
