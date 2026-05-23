#!/usr/bin/with-bashio
# shellcheck shell=bash
# ---------------------------------------------------------------
# Config Sync (GitOps) — HA Supervisor Add-on
#
# Pulls HA configuration from a GitHub repo on a schedule,
# validates via the Supervisor API, reloads HA on success,
# and auto-rolls back on failure.
#
# All configuration is read from the HA add-on options GUI
# via bashio.  The Supervisor token is auto-injected by HA.
# ---------------------------------------------------------------
set -euo pipefail

# ── Read add-on options ──────────────────────────────────────────
REPO=$(bashio::config 'github_repo')
BRANCH=$(bashio::config 'branch')
INTERVAL=$(bashio::config 'check_interval')
PAT=$(bashio::config 'github_pat')

# ── Constants ────────────────────────────────────────────────────
REPO_DIR="/data/repo"
CONFIG_DIR="/config"
ROLLBACK_DIR="/data/.rollback"

# ── Helpers ──────────────────────────────────────────────────────

# Build the sync_paths allowlist from config.  Paths ending in /
# are treated as directory prefixes; everything else is exact match.
build_sync_filter() {
    local i=0
    SYNC_PATHS=()
    while bashio::config.exists "sync_paths[${i}]"; do
        SYNC_PATHS+=("$(bashio::config "sync_paths[${i}]")")
        i=$((i + 1))
    done
}

# Returns 0 if $1 matches any entry in SYNC_PATHS.
path_allowed() {
    local file="$1"
    for pattern in "${SYNC_PATHS[@]}"; do
        # Directory prefix: "packages/" matches "packages/lighting.yaml"
        if [[ "${pattern}" == */ ]] && [[ "${file}" == "${pattern}"* ]]; then
            return 0
        fi
        # Exact match
        if [[ "${file}" == "${pattern}" ]]; then
            return 0
        fi
    done
    return 1
}

# Call the Supervisor API.  $1 = method, $2 = endpoint.
supervisor_api() {
    local method="$1" endpoint="$2"
    curl -sf -X "${method}" \
        "http://supervisor${endpoint}" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        2>/dev/null
}

# ── Initial clone ────────────────────────────────────────────────
if [ ! -d "${REPO_DIR}/.git" ]; then
    bashio::log.info "First run — cloning ${REPO} (branch: ${BRANCH})"
    CLONE_URL="${REPO}"
    if [ -n "${PAT}" ]; then
        CLONE_URL=$(echo "${REPO}" | sed "s|https://|https://${PAT}@|")
    fi
    git clone --branch "${BRANCH}" --single-branch "${CLONE_URL}" "${REPO_DIR}"
    bashio::log.info "Clone complete"
fi

# If PAT is set, ensure the remote URL includes it (handles PAT
# rotation without re-cloning).
if [ -n "${PAT}" ]; then
    AUTH_URL=$(echo "${REPO}" | sed "s|https://|https://${PAT}@|")
    git -C "${REPO_DIR}" remote set-url origin "${AUTH_URL}"
else
    git -C "${REPO_DIR}" remote set-url origin "${REPO}"
fi

# Build the path allowlist once at startup.
build_sync_filter
bashio::log.info "Sync paths: ${SYNC_PATHS[*]}"
bashio::log.info "Starting sync loop — checking every ${INTERVAL}s"

# ── Main loop ────────────────────────────────────────────────────
while true; do
    cd "${REPO_DIR}"

    # ── Fetch ────────────────────────────────────────────────────
    if ! git fetch origin "${BRANCH}" --quiet 2>/dev/null; then
        bashio::log.error "git fetch failed — will retry next cycle"
        sleep "${INTERVAL}"
        continue
    fi

    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/${BRANCH}")

    if [ "${LOCAL}" = "${REMOTE}" ]; then
        sleep "${INTERVAL}"
        continue
    fi

    bashio::log.info "Change detected: ${LOCAL:0:8} -> ${REMOTE:0:8}"

    # ── Fast-forward merge ───────────────────────────────────────
    if ! git merge "origin/${BRANCH}" --ff-only --quiet 2>/dev/null; then
        bashio::log.error "Fast-forward merge failed — local divergence?"
        bashio::log.warning "Resetting to origin/${BRANCH}"
        git reset --hard "origin/${BRANCH}"
    fi

    # ── Identify changed files that pass the sync filter ─────────
    CHANGED_ALL=$(git diff --name-only "${LOCAL}" "${REMOTE}" || true)
    CHANGED=""
    SKIPPED=""

    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if path_allowed "${f}"; then
            CHANGED="${CHANGED}${CHANGED:+$'\n'}${f}"
        else
            SKIPPED="${SKIPPED}${SKIPPED:+, }${f}"
        fi
    done <<< "${CHANGED_ALL}"

    if [ -n "${SKIPPED}" ]; then
        bashio::log.info "Skipped (not in sync_paths): ${SKIPPED}"
    fi

    if [ -z "${CHANGED}" ]; then
        bashio::log.info "No syncable config files changed"
        sleep "${INTERVAL}"
        continue
    fi

    bashio::log.info "Syncing: $(echo "${CHANGED}" | tr '\n' ' ')"

    # ── Backup affected files ────────────────────────────────────
    BACKUP="${ROLLBACK_DIR}/${LOCAL:0:8}"
    rm -rf "${BACKUP}"
    mkdir -p "${BACKUP}"

    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if [ -f "${CONFIG_DIR}/${f}" ]; then
            mkdir -p "${BACKUP}/$(dirname "${f}")"
            cp "${CONFIG_DIR}/${f}" "${BACKUP}/${f}"
        fi
    done <<< "${CHANGED}"

    # ── Copy changed files to /config ────────────────────────────
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if [ -f "${REPO_DIR}/${f}" ]; then
            mkdir -p "${CONFIG_DIR}/$(dirname "${f}")"
            cp "${REPO_DIR}/${f}" "${CONFIG_DIR}/${f}"
            bashio::log.debug "Copied: ${f}"
        fi
    done <<< "${CHANGED}"

    # Brief pause for HA to notice file changes
    sleep 2

    # ── Validate config via Supervisor API ───────────────────────
    CHECK_RESULT=$(supervisor_api POST "/core/api/config/core/check_config") || {
        bashio::log.error "check-config API unreachable — rolling back"
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            [ -f "${BACKUP}/${f}" ] && cp "${BACKUP}/${f}" "${CONFIG_DIR}/${f}"
        done <<< "${CHANGED}"
        git reset --hard "${LOCAL}"
        rm -rf "${BACKUP}"
        sleep "${INTERVAL}"
        continue
    }

    VALID=$(echo "${CHECK_RESULT}" | jq -r '.result // empty' 2>/dev/null)

    if [ "${VALID}" = "valid" ]; then
        bashio::log.info "Config valid — reloading Home Assistant"
        supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null 2>&1 || true
        bashio::log.info "Reload complete (${LOCAL:0:8} -> ${REMOTE:0:8})"
        rm -rf "${BACKUP}"
    else
        ERROR_MSG=$(echo "${CHECK_RESULT}" | jq -r '.errors // .message // "unknown error"' 2>/dev/null)
        bashio::log.error "Config invalid: ${ERROR_MSG}"
        bashio::log.warning "Rolling back to ${LOCAL:0:8}"
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            [ -f "${BACKUP}/${f}" ] && cp "${BACKUP}/${f}" "${CONFIG_DIR}/${f}"
        done <<< "${CHANGED}"
        git reset --hard "${LOCAL}"
        rm -rf "${BACKUP}"
    fi

    # Clean old rollback dirs (keep last 5)
    if [ -d "${ROLLBACK_DIR}" ]; then
        ls -1t "${ROLLBACK_DIR}" 2>/dev/null | tail -n +6 | while read -r old; do
            rm -rf "${ROLLBACK_DIR:?}/${old}"
        done
    fi

    sleep "${INTERVAL}"
done
