# Changelog

## 1.7.1

Two field-discovered fixes to the pre-sync HA backup, from the
2026-10-05 `JLay2026/home-assistant-config` #83 deploy (a
`lovelace:` block change).

**The lovelace-change restart never happened.** `do_import()` requested
the background pre-sync backup and called `homeassistant.restart` two
seconds later. Home Assistant refuses to restart while a backup is being
created; the Supervisor proxy surfaced the refusal as `HTTP 500 Server got
itself in trouble`, the add-on logged "Manual HA restart may be needed"
and moved on — so the files were in place but the dashboard registration
change sat un-applied until a human restarted HA. The structured log said
`event=reload_call result=failed strategy=core_restart` and nothing else
flagged it.

- **Fix**: new `wait_for_pre_sync_backup()` polls `GET /backups` every 5 s
  until the just-requested backup is listed (Supervisor lists a backup
  only once its file is written), up to `BACKUP_WAIT_TIMEOUT` (600 s),
  before the restart path proceeds. `reload_all` is unaffected and does
  not wait.
- **Fix**: new `restart_core_with_retry()` tries `homeassistant.restart`
  up to 3 times, 15 s apart, instead of giving up on the first refusal.
  If all attempts fail, a persistent notification ("Config Sync: HA
  restart needed") is raised in addition to the log line, so the
  operator finds out without reading the add-on log.
- **Fix**: the `backup_name` used for the status sensor / per-sync log was
  hardcoded to `gitops-pre-` and ignored `pre_sync_backup_name_prefix`
  (v1.6.2). Now uses the configured prefix.

**Pre-sync backups were unencrypted.** They contain `/config` *and*
`.storage` — every cloud credential HA holds — and were written
`protected: false` even on installs whose scheduled backups are
encrypted.

- **Feature**: new option `pre_sync_backup_password` (`password?`,
  default empty = unchanged behaviour). When set, the Supervisor
  request carries `password` and the backup is encrypted. The request
  body is now built with `jq`, so any password characters are quoted
  safely, and the key is omitted entirely when unset — existing installs
  send a byte-identical request. Log line and `event=backup` carry
  `encrypted=true|false`.
- Use the same password as your scheduled backups so one restore flow
  covers both. Retention pruning is unaffected (it matches on name).

- **New options**: `pre_sync_backup_password: "password?"` (default `""`).
- **No permission changes** — `GET /backups` was already used by the
  v1.5.2 prune.

## 1.7.0

New option: **`exclude_paths`** — paths to leave out of sync even when
they fall inside a `sync_paths` entry. Same syntax as `sync_paths`
(trailing `/` = directory prefix, otherwise exact file). Exclusions
are evaluated before the allowlist and always win, in both directions:
import never copies an excluded file to `/config`, export never stages
one into the repo, and the reconcile pass and tracked-symlink guard
skip it.

Motivating case: tracking `esphome/` (device definitions are real
config worth reviewing) without ever committing `esphome/secrets.yaml`,
the `esphome/.esphome/` build cache, or `esphome/trash/`. Prior to
this release the directory pattern in `stage_config_to_repo()` would
have exported every `*.yaml` under the directory, secrets included.

- **Feature**: `exclude_paths: list[str]` (default `[]`). Read at
  startup next to the other list options; logged as `Exclude paths:`
  when non-empty.
- **Change**: `path_allowed()` checks `EXCLUDE_PATHS` first and returns
  1 on a match. Every caller (import filter, reconcile, symlink guard,
  sync_paths-gap probe) inherits the behaviour.
- **Change**: `stage_config_to_repo()` now runs each candidate through
  `path_allowed()` — both the directory `find` loop and the exact-file
  branch — so export honours exclusions too.
- **Minor bump** because it adds a schema key. Existing installs get
  `exclude_paths: []` on update; no behaviour change until set.
- **No permission changes.**

## 1.6.5

Field-discovered fix: **export was permanently dead after the first
import.** `do_export()` skipped the cycle whenever `/data/.last-import`
held the same SHA as `HEAD` — but `do_import()` wrote `HEAD` into that
marker on every successful import, and nothing except an export commit
ever moved `HEAD`. So after the first import the guard fired on every
cycle, forever. The skip was logged at DEBUG, so at the default log
level the add-on printed "Export enabled — running initial export" and
then nothing — indistinguishable from "no changes".

- **Fix**: remove the marker-SHA guard. It was redundant as well as
  broken: an import copies repo → `/config`, so the `git diff --cached
  --quiet` check that follows already sees no delta and the cycle is a
  no-op. That diff check is now the sole authority. Stale
  `/data/.last-import` files from earlier versions are deleted once at
  startup.
- **Change**: the "no changes to export" line is now INFO (was DEBUG) —
  at most one line per `export_interval` — so operators can see the
  export cycle actually ran.
- **Change**: `github_pat` schema type `str?` → `password?` so the
  Supervisor UI masks the token in the add-on Configuration tab. UI
  masking only; the Supervisor options API still returns it to
  admin-scoped callers. Use a fine-grained PAT scoped to the config
  repo (DOCS.md) to bound blast radius.
- **Field incident**: `JLay2026/home-assistant-config` — last export
  before the last import was 2026-07-14 (merge of PR #71). Every
  HA-side edit since then stayed on the box; discovered 2026-10-03
  while investigating repo/`/config` drift.
- **No new options**; schema type change only (existing value is
  preserved on update); no permission changes.

## 1.6.4

Field-discovered fix: the pre-sync HA backup step aborted **every** sync on
installs with a large recorder database. `ha_backup_pre_sync()` requests a
compressed backup of the `homeassistant` folder (covers `/config` + `.storage`),
and current Supervisor (2026.06.x) returns from `POST /backups/new/partial`
only *after* the backup file is written — not when the job is accepted, as the
code assumed. Compressing a multi-GB `/config` (dominated by
`home-assistant_v2.db`) exceeded the 30s `SUPERVISOR_API_TIMEOUT`, so
`supervisor_api()` returned `HTTP 000` and the sync was (correctly) aborted and
rolled back — retrying and failing identically every cycle.

- **Fix**: add `"background": true` to the `/backups/new/partial` request body
  so Supervisor returns as soon as it ACCEPTS the job (matching the function's
  original async assumption), regardless of backup size. The endpoint still
  returns HTTP 2xx on accept, so no response-parsing change is needed.
- **Fix**: raise `SUPERVISOR_API_TIMEOUT` 30 → 90 as headroom for job-accept
  and the per-cycle check_config/health probes; still bounded so a hung
  Supervisor cannot wedge the single-threaded loop.
- **Field incident**: 2026-07-13, `JLay2026/home-assistant-config` deploy
  (merge `116b9e0c`). Recorder DB ~9.8 GB; every 5-min cycle logged
  `Pre-sync HA backup API failed — REFUSING to sync (no response)` and rolled
  back to the prior SHA. Disk (~111 GB free), backup manager (idle), and
  Supervisor health were all fine — the sole cause was the 30s cap vs the
  synchronous compressed backup.
- **No new options**; no schema changes; no permission changes. Existing
  deployments get the fix automatically on update.

## 1.6.3

Field-discovered regression fix: diff-sync was silently dropping file
deletions. PRs that delete a file (or rename one, which git represents
as add+delete) propagated the add to `/config` but left the deleted
file on disk. The orphaned file kept failing config validation at
every reload, producing repeating ERROR log entries even though the
upstream repo was clean.

- **Fix**: The copy loop in `do_import()` now handles three cases:
  added/modified files are copied from `${REPO_DIR}` (existing
  behavior), and deleted files are removed from `${CONFIG_DIR}` via
  `rm -f` (new). The existing backup loop already snapshots the
  about-to-be-deleted file from `${CONFIG_DIR}` (it copies whenever
  the file exists locally, regardless of operation type), so the
  existing rollback path restores it correctly if validation fails.

- **Reproduction**: PR that adds `packages/foo.yaml` and deletes
  `packages/_foo.yaml` in a single commit. Pre-fix: `_foo.yaml`
  remained on disk and continued failing the package slug validator.
  Post-fix: both operations propagate; `_foo.yaml` is removed on the
  next sync.

- **Field incident**: 2026-05-30, observed in
  `JLay2026/home-assistant-config#43` (rename of `_shared_alert_macros.yaml`
  to `shared_alert_macros.yaml`). The rename PR merged cleanly upstream
  and the new file synced to `/config/packages/` at 18:23:05 UTC, but
  the old underscored file remained — producing
  `Setup of package '_shared_alert_macros' ... invalid slug` errors at
  every subsequent reload (~20s cadence via the addon's sync loop).
  Manually deleting the orphaned file from `/config/packages/` cleared
  the error.

- **No new options**; no schema changes; no permission changes; no
  behavior change for adds or modifies. Backup and rollback paths
  unchanged.

## 1.6.2

Sprint 6 housekeeping release from the 2026-05-25 code-and-security
review — closes the remaining LOW-severity items that warrant action
(L12, L16, L18, L19). No new MEDIUMs in this sprint; **M8** (commit
signature verification) remains deferred per the review's "Backlog
(when warranted)" classification. **L17** (git release tags) is an
out-of-tree operator action documented separately.

- **Fix (Review L12)**: every `cp` call that moves config content now
  passes `-p` to preserve timestamps. Lets operators correlate
  `ls -l /config` mtimes against GitHub commit authorship times.
  Cosmetic but useful for forensics.

- **Fix (Review L16)**: `/tmp/.sup_resp_body` and `/tmp/.sup_resp_code`
  are now created via `mktemp` with unique per-PID suffixes; a `trap
  ... EXIT` cleans them up on add-on stop. Today's single-threaded
  loop wouldn't have raced, but a future feature (background export,
  parallel agent calls) would have collided on the shared paths.
  Future-proofing with no behavior change for current code.

- **Feature (Review L18)**: New optional config `pre_sync_backup_name_prefix`
  (default `"gitops-pre-"`, backward compatible). Operators who keep
  their own manual `gitops-pre-*` HA backups can pick a different
  prefix to avoid collision with the add-on's retention prune. WARNING
  in DOCS: changing the prefix abandons any backups taken under the
  prior prefix — they look like operator backups and are never pruned.

- **Fix (Review L19)**: Defensive INFO log in `prune_pre_sync_backups()`
  when Supervisor returns an empty backup list AND lifetime sync_count
  is ≥ 5. Surfaces the case where a future HA major-version renames
  `.data.backups` and the jq filter silently no-ops. Threshold filters
  out false positives from brand-new installs.

- **New options**: `pre_sync_backup_name_prefix: "str?"` (default
  `"gitops-pre-"`).

- **No permission changes**; no behavior change for operators using
  default settings; no new dependencies.

## 1.6.1

Sprint 5 P2 from the 2026-05-25 code-and-security review — closes the
M3 finding (PAT written to `.git/config` on disk inside the persistent
`/data/` volume). PAT is now passed to git via an inline credential
helper that reads from a process env var at git-command time, so the
PAT never lands on disk.

- **Fix (Review M3)**: PAT no longer written to `.git/config`. New
  pattern:
  1. Top of `run.sh` exports `GH_CONFIG_SYNC_PAT="${PAT}"` into the
     process environment along with `GIT_TERMINAL_PROMPT=0`.
  2. A credential helper is configured as an inline shell function:
     `!f() { echo username=x-access-token; echo "password=${GH_CONFIG_SYNC_PAT}"; }; f`
     The literal string `${GH_CONFIG_SYNC_PAT}` is what `git config`
     stores in `.git/config` — bash expands it at git-command time,
     not at config-write time. The PAT itself is never written to
     disk.
  3. The initial clone uses `git -c credential.helper=...` inline so
     the very first authentication needs no on-disk credential.
  4. After clone (or on every startup for existing repos),
     `git remote set-url origin "${REPO}"` is run to ensure the
     remote URL is the plain HTTPS form with NO PAT embedded. This
     idempotently cleans any PAT-in-URL config left from v1.5.x or
     v1.6.0 on first v1.6.1 startup.

- **Upgrade behavior**: existing v1.5.x / v1.6.0 deployments with
  PATs already in `.git/config` get cleaned on first start of v1.6.1
  — the `remote set-url origin "${REPO}"` and `git config
  credential.helper ...` calls overwrite the prior PAT-embedded URL
  and (for set-url) write a clean URL back. No operator action
  required.

- **Threat model improvement**: prior versions left the PAT in
  `/data/repo/.git/config` (persistent across container restart) and
  in `git remote -v` output (live, only when add-on is running, but
  still visible to anyone with `docker exec`). v1.6.1 leaves the PAT
  only in `/proc/<pid>/environ` of the running `run.sh` process and
  its `git` subprocesses — ephemeral, gone on add-on stop.

- **No new options**; no schema changes; no permission changes; no
  behavior change in the happy path. The credential helper pattern
  is functionally equivalent to URL-embedded credentials from git's
  authentication-protocol perspective.

- **No new config option for `GH_CONFIG_SYNC_PAT`** — the env-var
  name is an internal implementation detail, not an operator-tunable.
  Operators continue to set `github_pat` in the add-on UI exactly as
  before.

## 1.6.0

Sprint 5 P1 from the 2026-05-25 code-and-security review. Two
structural defenses against repo-trust threats, plus the addition of
CI (shellcheck + docker build smoke test). Minor version bump because
the `allowed_repo_hosts` default is a soft-breaking change for any
GitHub Enterprise operator.

- **Feature (Review M7)**: New `check_repo_host_allowed()` startup
  guard validates `github_repo` host against the new
  `allowed_repo_hosts` config option (default `["github.com"]`).
  Subdomain matches are allowed via suffix-match — `"github.com"`
  permits `api.github.com`, `raw.githubusercontent.com`, etc. Refuses
  to start with a multi-line ERROR if the URL points outside the
  allowlist.

  Defends against the case where a misconfigured or social-engineered
  `github_repo` URL would silently embed the PAT and send it on first
  clone/fetch — prior versions trusted whatever the operator pasted
  into the option.

  **Breaking change for GitHub Enterprise operators**: GHE users must
  add their hostname to `allowed_repo_hosts` before upgrading to
  v1.6.0, or the add-on will refuse to start. The ERROR message in the
  log is explicit and tells the operator exactly what to fix.

- **Feature (Review M6)**: New `check_no_tracked_symlinks()` sync-time
  guard. Runs in `do_import()` after `check_sync_paths_gap` and
  before pre-sync backup. Aborts the sync if any tracked file matching
  `sync_paths` is a symlink in `/data/repo/`.

  Defends against the case where a malicious commit turns
  `automations.yaml` into a symlink to `/etc/passwd` (info disclosure
  on the subsequent cp) or to `/data/sync_status.json` (overwrite
  with commit content). New config option `block_symlinks` (default
  `true`) lets operators with intentional symlink use revert to the
  v1.5.x behavior.

  ERROR block lists the symlinks with their targets (truncated to 10
  entries) and a copy-paste fix recipe.

- **Feature (Review L11)**: New `.github/workflows/ci.yml` runs on
  every push to main and on every PR:
  - `shellcheck config-sync/run.sh` (excludes SC1091 + SC2012 which
    are accepted info-level findings; everything else must pass)
  - `docker build` smoke test for amd64 against the
    `ghcr.io/home-assistant/amd64-base:3.21` base image used in
    `build.yaml`

  Closes the L11 review finding (zero CI / zero tests). Doesn't add
  bats-style unit tests yet (those would be Sprint 6 if anyone asks).

- **New options**:
  - `allowed_repo_hosts: list[str]` (default `["github.com"]`)
  - `block_symlinks: bool` (default `true`)

- **All failure-path signals wired up for both new guards**: per-sync
  structured log emits `event=tracked_symlinks result=abort` (host
  failure is at startup, before any sync, so no per-sync log); HA
  persistent_notification raised with a clear title; status sensor
  updates to `failed` with `last_error: "[tracked_symlinks] ..."`;
  git reset to LOCAL on abort so the next cycle retries the same SHA
  once the operator has fixed the issue.

- **No new permissions**. Both guards operate on local state
  (config option + filesystem stat), no Supervisor or GitHub API
  calls needed.

## 1.5.4

Sprint 5 P0 from the 2026-05-25 code-and-security review. Fixes the
two HIGH findings (no network timeouts — a hung curl or git would
wedge the entire single-threaded sync loop) and the related MEDIUM/LOW
findings about credential-handling fragility. No new config options;
no behavior change in the happy path.

- **Fix (Review H1)**: `supervisor_api()` now passes `--max-time 30
  --connect-timeout 5` to every `curl` call. Without these, a hung
  Supervisor would block indefinitely; the single-threaded sync loop
  has no concurrent recovery path. New constants `SUPERVISOR_API_TIMEOUT`
  (default 30s) and `SUPERVISOR_API_CONNECT_TIMEOUT` (default 5s).
  Timeouts surface as `HTTP 000` in the existing diagnostic path — the
  log line distinguishes "unreachable" from "timed out".
- **Fix (Review H2)**: Script top now exports `GIT_HTTP_LOW_SPEED_LIMIT=1000`
  and `GIT_HTTP_LOW_SPEED_TIMEOUT=60`. Same shape as H1 but for
  `git fetch` / `git push` / `git clone` — a flaky GitHub connection
  no longer hangs the loop. Git aborts the operation if throughput stays
  below 1 KB/s for 60 seconds.
- **Fix (Review M4)**: Replaced sed-based PAT URL substitution
  with bash parameter expansion (`${REPO/https:\/\//https:\/\/${PAT}@}`).
  The sed form was fragile to `|`, `&`, or `/` in the PAT — silently
  produces a broken URL on those characters. Two locations.
- **Fix (Review M5)**: `sanitize_output()` now quotes the search side
  of its pattern substitution: `${text//"${PAT}"/***}`. Forces
  literal-string matching so glob chars (`*`, `?`, `[`, `]`) in a PAT
  don't silently bypass the scrub.
- **Fix (Review L13)**: `rel="${src#"${CONFIG_DIR}"/}"` — quote the
  inner expansion in the parameter-substitution pattern. Resolves
  shellcheck SC2295.
- **Diagnostic improvement**: `log_supervisor_error()` distinguishes
  "unreachable" from "timed out after Ns" in its no-response branch.
- **No new config options**; no schema changes; no permission changes.
  Existing deployments get all five fixes automatically on update.

## 1.5.3

Sprint 4 P3 from the hardening plan (see issue #9) — the final item.
Export-side per-cycle structured log parity with the v1.4.1 import-
side log. Closes Sprint 4.

- **Feature (Sprint 4 P3)**: Each `do_export()` cycle that has real
  changes to push writes a dedicated log file under
  `/data/logs/export/` named `<UTC-timestamp>-export-<mode>.log`
  (mode = `initial` or `auto`). Captures the export waypoints as
  structured `event=` lines.
- **New helpers**: `export_log_open(mode)`, `export_log(level, msg)`,
  `export_log_close(result)` mirror the `sync_log_*` shape. Share the
  same `SYNC_LOG_MAX_FILES` (20) retention constant.
- **Separate subdir** (`/data/logs/export/`) keeps import and export
  log streams from intermixing.
- **PAT scrubbing on push failures** via the existing `sanitize_output()`.
- **Sprint 4 complete with this release**.

## 1.5.2

Sprint 4 P2 from the hardening plan (issue #9): bound the number
of `gitops-pre-*` HA backups the add-on accumulates.

- **Feature**: `prune_pre_sync_backups()` enumerates HA backups via
  `GET /backups`, filters to `gitops-pre-*` by name, sorts by date desc,
  and deletes everything past the Nth most recent via `DELETE /backups/<slug>`.
- **New option**: `pre_sync_backup_retention: int(0,50)` (default `7`).
  `0` disables pruning entirely.
- **Just-created backup never deleted in same cycle**.
- **Best-effort throughout**: list/delete failures log WARN, never propagate.
- **No new permissions**: `hassio_role: backup` already covers list+delete.

## 1.5.1

Sprint 4 P1: enforce the sync_paths gap at sync time so a PR can't slip
through between add-on restarts. Structurally prevents the 2026-05-25
incident class.

- **Feature**: `check_sync_paths_gap()` runs early in `do_import()`.
  Aborts the sync if configuration.yaml has `!include_dir_*` directives
  targeting directories not in `sync_paths` AND the current diff has
  files under those directories.
- **New option**: `strict_sync_paths_check: bool` (default `true`).
- Complements v1.1.7's startup audit.

## 1.5.0

Sprint 4 P0: expose sync state as a first-class HA sensor entity.

- **Feature**: `sensor.config_sync_status` published via
  `POST /core/api/states/sensor.config_sync_status` after every cycle.
  States: `idle` -> `syncing` -> `success` | `failed`.
- **Attributes**: friendly_name, icon, last_sync_at, last_sha_short,
  last_strategy, last_error (with [stage] prefix), last_backup_name,
  last_log_file, sync_count, failure_count.
- **Mirror snapshot** at `/data/sync_status.json` for headless tooling
  and lifetime-counter persistence across restart.
- **No new permissions**; no new config options; no schema changes.

## 1.4.1

Sprint 3 P1: per-sync structured log under `/data/logs/sync/`.

- Each sync cycle with changes writes `<UTC-timestamp>-<short-sha>.log`.
- Captures `event=` keys for every major waypoint.
- Hardcoded retention of 20 files.
- Best-effort — logging failures never block a sync.

## 1.4.0

Sprint 3 P0: reload-strategy heuristic to prevent the 2026-05-25 incident.

- Three-way strategy in `do_import()`:
  - `/core/restart` when configuration.yaml lovelace block changed
  - `reload_all + frontend.reload_themes` when themes/ files changed
  - `reload_all` otherwise (default)
- **New option**: `restart_on_lovelace_change: bool` (default `true`).
- Adaptive post-sync settle window: +25s for restart strategy.

## 1.3.1

Sprint 2 P1: persistent_notification in HA UI on sync failure.

- Singleton notification (id `config_sync_failure`) updates on failure,
  auto-dismisses on next healthy sync.
- **New option**: `notify_on_failure: bool` (default `true`).

## 1.3.0

Sprint 2: eliminate silent failures across do_import/do_export.

- **Fix (closes #2)**: `reconcile_tracked_files()` copies tracked-
  but-missing files to /config on every sync with changes.
- **Fix**: `find | while` subshell race in `stage_config_to_repo()`
  replaced with process substitution. Function now correctly returns 1
  when any file changed.
- **Fix**: `reload_all` API failures captured + logged with HTTP code
  + response body.
- **Fix**: `git checkout` failures in `do_export()` captured + logged
  with PAT-scrubbed stderr.

## 1.2.1

- **Fix (P0)**: Grant `hassio_api: true` + `hassio_role: backup` so the
  v1.2.0 pre-sync HA backup actually succeeds.
- **Fix (P0)**: `supervisor_api()` captures HTTP code + body via temp
  files for diagnostic-quality error reporting (survives subshells).
- **New helper**: `log_supervisor_error()`.

## 1.2.0

- **Feature**: Pre-sync HA backup via `POST /backups/new/partial`
  before any /config write.
- **Feature**: Post-sync verification probes against /core/api/.
- **New option**: `post_sync_settle_seconds: int(0,60)` (default 5).

## 1.1.7

- **Feature**: Startup audit for `!include_dir_*` directives pointing
  outside sync_paths (emits WARNING per gap).

## 1.1.6

- **Fix**: Log actual git push/fetch error messages instead of
  swallowing stderr.
- Added `sanitize_output()` helper to strip PAT from log output.

## 1.1.5

- **Feature**: Add `scripts/` directory to default `sync_paths`.

## 1.1.4

- **Fix**: Add `homeassistant_api: true` to config.yaml.

## 1.1.3

- **Fix**: Use `#!/usr/bin/with-contenv bash` shebang.
- **Fix**: Set `$HOME` before `git config --global`.

## 1.1.2

- **Fix**: Replace `#!/usr/bin/with-bashio` shebang.

## 1.1.1

- **Fix**: Update base images from Alpine 3.20 to 3.21.

## 1.1.0

- **Bidirectional sync**: export HA-side config changes back to GitHub.
- New options: `export_enabled`, `export_interval`, `export_branch`,
  `export_commit_message`.

## 1.0.0

- Initial release.
- GitOps sync from GitHub to HA /config.
- Supervisor API validation (check-config) before reload.
- Automatic rollback on invalid config.
- Configurable `sync_paths` allowlist.
- Private repo support via GitHub PAT.
- Multi-arch: amd64, aarch64, armv7, i386.
