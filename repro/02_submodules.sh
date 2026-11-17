#!/usr/bin/env bash
# repro/02_submodules.sh — land the locked submodules and archive the
# "GMR missing -> uv sync fails" failure path.
#
# Why this script exists (and why it lands by SHA instead of `git submodule`):
#   * pyproject.toml declares general-motion-retargeting as a workspace editable
#     source at third_party/GMR, so `uv sync` cannot resolve the lockfile while
#     that member is missing -> the submodule must exist first.
#   * This worktree is a *linked* worktree whose .git file points at a
#     host-local path, so `git submodule update --init` is not usable here
#     ("git-submodule cannot be used without a working tree"). We therefore
#     reproduce the pinned state by cloning the exact .gitmodules SHA.
#
# The proxy is inlined into this process only (see repro/lib/common.sh).

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
require_container
# shellcheck source=lib/submodules.sh
source "$_SCRIPT_DIR/lib/submodules.sh"

# Work relative to the repository root (the submodule paths are repo-relative).
cd "$REPO_ROOT"

MAIN_LOG="$LOG_DIR/02_submodules.txt"
FAILURE_LOG="$LOG_DIR/02_uv_sync_without_gmr.txt"

# GMR_PATH / GMR_SHA / SDK_PATH / SDK_SHA and the land_submodule /
# verify_submodule helpers come from repro/lib/submodules.sh (so they can be
# unit tested against a throwaway remote, see repro/tests/test_submodules.sh).

log() { echo "$*" | tee -a "$MAIN_LOG"; }

: >"$MAIN_LOG"
log "=== 02_submodules.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "REPO_ROOT=$REPO_ROOT"
log "proxy(inline, process-scoped)=$PROXY"

# ---------------------------------------------------------------------------
# 1) FAILURE PATH EVIDENCE: what does uv do without third_party/GMR?
#
#    Measured fact (uv 0.12.6, container): the DEFAULT dependency groups do not
#    pull general-motion-retargeting, so `uv sync --frozen` succeeds even with
#    GMR absent. The blocking consumer is the `teleop` group, which declares
#    general-motion-retargeting with `workspace = true` -> that sync fails.
#    Both commands are captured so the difference is on record.
#
#    The evidence is captured by temporarily stashing third_party/GMR, so it is
#    reproducible on every run; the stash is always restored (trap).
# ---------------------------------------------------------------------------
GMR_STASH=""

restore_gmr() {
  if [ -n "$GMR_STASH" ] && [ -d "$GMR_STASH" ] && [ ! -e "$GMR_PATH" ]; then
    mv "$GMR_STASH" "$GMR_PATH" || true
    log "    restored $GMR_PATH from stash"
  fi
  GMR_STASH=""
}
trap restore_gmr EXIT

capture_failure_path() {
  local out="$1"
  {
    echo "=== uv sync WITHOUT third_party/GMR (failure-path evidence) ==="
    echo "collected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repo_root: $REPO_ROOT"
    echo "uv_version: $(uv --version 2>&1)"
    echo
    echo "--- command A: uv sync --frozen --dry-run (default groups) ---"
  } >"$out"

  local rc
  set +e
  ( cd "$REPO_ROOT" && uv sync --frozen --dry-run ) >>"$out" 2>&1
  rc=$?
  set -e
  { echo "--- exit code A: $rc ---"; echo; } >>"$out"

  {
    echo "--- command B: uv sync --frozen --group teleop --dry-run (needs GMR) ---"
  } >>"$out"
  set +e
  ( cd "$REPO_ROOT" && uv sync --frozen --group teleop --dry-run ) >>"$out" 2>&1
  rc=$?
  set -e
  { echo "--- exit code B: $rc ---"; } >>"$out"
  echo "$rc"
}

if [ -s "$FAILURE_LOG" ] && grep -q "exit code B" "$FAILURE_LOG"; then
  log "failure-path evidence: archived ($FAILURE_LOG kept from first collection)"
else
  log "failure-path evidence: collecting (GMR temporarily stashed)"
  if [ -d "$GMR_PATH" ]; then
    GMR_STASH="$REPO_ROOT/third_party/.GMR.stash.$$"
    mv "$GMR_PATH" "$GMR_STASH"
    log "    stashed $GMR_PATH -> $GMR_STASH"
  else
    log "    $GMR_PATH already absent"
  fi
  b_rc="$(capture_failure_path "$FAILURE_LOG" | tail -n 1)"
  restore_gmr
  if [ "${b_rc:-1}" -ne 0 ]; then
    log "failure-path evidence: collected (teleop-group sync failed with exit $b_rc as expected without GMR)"
  else
    log "WARNING: teleop-group sync unexpectedly succeeded without GMR"
    log "failure-path evidence: collected (unexpected success)"
  fi
  log "failure-path evidence written to: $FAILURE_LOG"
fi

# ---------------------------------------------------------------------------
# 2) Land each submodule at its pinned SHA (helpers in repro/lib/submodules.sh).
# ---------------------------------------------------------------------------

# GMR is blocking: without it `uv sync` cannot resolve the workspace.
if ! land_submodule "$GMR_PATH" "$GMR_URL" "$GMR_SHA" log; then
  log "ERROR: failed to land $GMR_PATH (blocking)"
  exit 1
fi

# unitree SDK is best-effort for this slice: a failure is recorded, not fatal.
if ! land_submodule "$SDK_PATH" "$SDK_URL" "$SDK_SHA" log; then
  log "WARNING: failed to land $SDK_PATH (best-effort, non-blocking for this slice)"
  log "         reason recorded above; continuing"
fi

# ---------------------------------------------------------------------------
# 3) Verification of the landed state.
# ---------------------------------------------------------------------------
log "--- verification ---"
# GMR is the blocking member: a SHA mismatch / dirty tree must fail the run.
if ! verify_submodule "$GMR_PATH" "$GMR_SHA" log; then
  log "ERROR: $GMR_PATH is not at the pinned SHA $GMR_SHA (blocking)"
  exit 1
fi
# The unitree SDK is best-effort: a mismatch is recorded, not fatal.
if ! verify_submodule "$SDK_PATH" "$SDK_SHA" log; then
  log "WARNING: $SDK_PATH is not at the pinned SHA $SDK_SHA (best-effort, non-blocking for this slice)"
fi

if [ ! -f "$GMR_PATH/pyproject.toml" ]; then
  log "ERROR: $GMR_PATH/pyproject.toml missing"
  exit 1
fi
log "    $GMR_PATH/pyproject.toml present"

log "SUBMODULES_OK"
