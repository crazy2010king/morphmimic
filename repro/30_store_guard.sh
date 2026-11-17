#!/usr/bin/env bash
# repro/30_store_guard.sh — health check and repair for the persistent store.
#
# WHY
#   Every heavy artefact of this project (68.8 GB of BONES-SEED, 88.5 GiB of
#   50 Hz npz, the training checkpoints, the exported ONNX, the replay videos
#   and the delivered record) lives in ONE persistent store OUTSIDE any git
#   worktree, and the worktree only carries relative symlinks into it.
#
#   GSD deletes milestone worktrees that are "not registered with git", and a
#   recursive deletion takes every untracked file with it.  Two losses were
#   caused by exactly that:
#     * 2026-11-11 23.5 GB of g1.tar.gz + the metadata CSV (before the store
#       existed);
#     * 2026-11-11 the whole tool-chain probe output (logs/toolchain/**:
#       cloned third-party repos, isolated venvs, the pybind11 build) —
#       because the probe wrote into the worktree's plain logs/ directory.
#
#   This script makes that class of loss DETECTABLE and REPAIRABLE:
#     check    structural + payload invariants, fail closed
#     migrate  move a diverged worktree directory into the store and re-link
#     manifest write <store>/MANIFEST.txt — the inventory used to notice a
#              deletion that happened while nobody was looking
#
#   usage: bash repro/30_store_guard.sh [check|migrate|manifest|doc|doctor]
#
# The verdict is expressed as a machine-greppable marker:
#   STORE_GUARD_OK            everything is in place
#   STORE_GUARD_FAIL reason=… something is wrong (the reason set is fixed)

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/seed_store.sh
source "$_SCRIPT_DIR/lib/seed_store.sh"

cd "$REPO_ROOT"

CMD="${1:-check}"
LOG="$LOG_DIR/30_store_guard.txt"

usage() {
  echo "usage: bash repro/30_store_guard.sh [check|migrate|manifest|doctor]" >&2
  exit 2
}

case "$CMD" in
  check|migrate|manifest|doc|doctor) ;;
  *) usage ;;
esac

{
  echo "=== 30_store_guard.sh $CMD ==="
  echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "REPO_ROOT=$REPO_ROOT"
  echo "SEED_STORE_ROOT=$SEED_STORE_ROOT"
  echo
} >>"$LOG"

run_and_log() {
  local rc=0
  "$@" 2>&1 | tee -a "$LOG" || rc=$?
  return "$rc"
}

case "$CMD" in
  check)
    rc=0
    run_and_log seed_store_check_impl || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "STORE_GUARD_OK" | tee -a "$LOG"
    else
      echo "STORE_GUARD_FAIL reason=store-incomplete" | tee -a "$LOG"
    fi
    exit "$rc"
    ;;
  migrate)
    rc=0
    run_and_log seed_store_migrate_impl || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "STORE_GUARD_FAIL reason=migrate-failed" | tee -a "$LOG"
      exit "$rc"
    fi
    run_and_log seed_store_check_impl || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "STORE_GUARD_OK" | tee -a "$LOG"
    else
      echo "STORE_GUARD_FAIL reason=store-incomplete" | tee -a "$LOG"
    fi
    exit "$rc"
    ;;
  manifest)
    run_and_log seed_store_manifest_impl
    echo "STORE_GUARD_OK" | tee -a "$LOG"
    ;;
  doc)
    rc=0
    run_and_log seed_store_sync_doc_impl || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "STORE_GUARD_FAIL reason=document-copies-differ" | tee -a "$LOG"
      exit "$rc"
    fi
    echo "STORE_GUARD_OK" | tee -a "$LOG"
    ;;
  doctor)
    rc=0
    run_and_log seed_store_check_impl || rc=$?
    run_and_log seed_store_check_doc_impl || rc=$?
    run_and_log seed_store_manifest_impl || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "STORE_GUARD_OK" | tee -a "$LOG"
    else
      echo "STORE_GUARD_FAIL reason=store-incomplete" | tee -a "$LOG"
    fi
    exit "$rc"
    ;;
esac
