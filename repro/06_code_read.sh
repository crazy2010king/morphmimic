#!/usr/bin/env bash
# repro/06_code_read.sh — module coverage gate for the engineering read record.
#
# R005 asks for a complete read of the engineering with a written record
# ("every module's responsibility, key call chains, entry commands and its
# relation to this reproduction task"); R003 asks for that record to leave a
# re-runnable trace.  This script is the gate: it discovers the modules of the
# coverage set (see repro/lib/coderead.sh for the exact rules) and compares
# them with docs/code_read/CODE_MAP.md.
#
#   * every discovered module must appear in the record  -> else non-zero
#     exit and one "MISSING <path>" line per gap;
#   * every recorded module must carry a non-empty responsibility
#     -> else non-zero exit and one "EMPTY_DUTY <path>" line per gap;
#   * a record entry without a module on disk is only a warning ("STALE"),
#     because a deleted module does not invalidate the read record;
#   * when everything is covered the script prints CODE_READ_OK.
#
# The log lands in logs/env/06_code_read.txt and contains the counters
# MODULES_TOTAL_ / MODULES_RECORDED_ / MODULES_MISSING_ / MODULES_STALE_ /
# MODULES_EMPTY_DUTY_.
#
# The script is pure filesystem work: it needs neither the GPU, nor uv, nor
# the network, so it runs on the dev box AND in the container with the same
# result (it is part of the 00_env.sh one-shot orchestration).

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/coderead.sh
source "$_SCRIPT_DIR/lib/coderead.sh"

cd "$REPO_ROOT"

MAIN_LOG="${CODE_READ_LOG:-$LOG_DIR/06_code_read.txt}"
RECORD_FILE="${CODE_READ_RECORD:-$REPO_ROOT/docs/code_read/CODE_MAP.md}"

log() { echo "$*" | tee -a "$MAIN_LOG"; }

# a fresh log per run: the artefact must show ONE verdict, not the history of
# earlier attempts (idempotent re-runs).
: >"$MAIN_LOG"

log "=== 06_code_read.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "REPO_ROOT=$REPO_ROOT"
log "RECORD_FILE=$RECORD_FILE"

if [ ! -f "$RECORD_FILE" ]; then
  log "ERROR: the read record does not exist: $RECORD_FILE"
  log "CODE_READ_FAIL"
  echo "ERROR: the read record does not exist: $RECORD_FILE" >&2
  exit 1
fi

MODULES_FILE="$(mktemp "${TMPDIR:-/tmp}/coderead_modules.XXXXXX")"
trap 'rm -f "$MODULES_FILE"' EXIT

coderead_scan_modules "$REPO_ROOT" >"$MODULES_FILE"

log "--- module coverage ---"
set +e
COMPARE_OUT="$(coderead_compare "$MODULES_FILE" "$RECORD_FILE")"
RC=$?
set -e
printf '%s\n' "$COMPARE_OUT" | tee -a "$MAIN_LOG"

if [ "$RC" -ne 0 ]; then
  log "CODE_READ_FAIL"
  echo "ERROR: the read record does not cover every module (see $MAIN_LOG)" >&2
  exit 1
fi

log "CODE_READ_OK"
exit 0
