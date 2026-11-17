#!/usr/bin/env bash
# repro/12_seed_finalize_report.sh — READ-ONLY terminal report for BONES-SEED.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The terminal evidence of the BONES-SEED slice (archive verification ->
# extraction -> metadata reconciliation -> archive sha256) is produced by the
# unattended chain repro/11_seed_finalize.sh, hours after the download ends.
# Whoever picks the slice up afterwards has to turn those markers into the
# numbers in docs/code_read/SEED_ACQUISITION.md.  Doing that by hand is
# exactly where a wrong number sneaks in (a stale status file, a marker from
# an older attempt, a half-copied line).
#
# This script is the single authoritative source for those numbers.  It
#
#   1. asserts the terminal state (download DONE, finalize DONE),
#   2. asserts that ALL SIX terminal markers are present in the finalize log,
#   3. prints the marker lines VERBATIM plus a set of SEED_REPORT_* key=value
#      lines that are ready to be pasted into the documentation.
#
# It NEVER writes anything: no document is touched, no archive is read, no
# network call is made.  If a marker is missing it FAILS CLOSED (exit 1,
# listing what is missing) and prints no SEED_REPORT_OK line — a report that
# cannot be produced must not look like a report that was.
#
# SUBCOMMANDS
#   report   print the terminal report (default)
#   check    print only the verdict (OK / the missing items), no key=value dump
#
# ENVIRONMENT OVERRIDES (used by the offline fixtures)
#   SEED_REPORT_LOG_DIR        directory holding 08/11 status + logs
#                              (default: $REPO_ROOT/logs/env, which is the
#                              persistent seed store)
#   SEED_REPORT_SHA256SUMS     SHA256SUMS manifest (default:
#                              <log_dir>/../../data/seed/_archives/SHA256SUMS)
#
# EXIT CODES
#   0  every assertion passed, SEED_REPORT_OK printed
#   1  at least one assertion failed, the missing items are listed
#   2  usage error

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

LOG_DIR_REAL="${SEED_REPORT_LOG_DIR:-$LOG_DIR}"
DL_STATUS="$LOG_DIR_REAL/08_seed_download.status"
FINAL_STATUS="$LOG_DIR_REAL/11_seed_finalize.status"
FINAL_LOG="$LOG_DIR_REAL/11_seed_finalize.txt"
ARCHIVE_DIR="${SEED_REPORT_ARCHIVE_DIR:-$REPO_ROOT/data/seed/_archives}"
SHA256SUMS="${SEED_REPORT_SHA256SUMS:-$ARCHIVE_DIR/SHA256SUMS}"

# The six terminal markers of the slice (see the slice plan, T2).
REQUIRED_MARKERS=(
  "SEED_VERIFY_OK"
  "SEED_TAR_CLIPS file=g1 kind=csv count=142220"
  "SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220"
  "SEED_META_MATCH matched=142220 missing=0 extra=0"
  "SEED_EXTRACT_OK files=284440"
  "SEED_FINALIZE_OK files=3"
)

usage() {
  cat <<EOF
usage: bash repro/12_seed_finalize_report.sh [report|check]

  report   print the terminal report (default)
  check    print only the verdict
EOF
}

# state_of <status file> — prints the STATE= value (or empty).
state_of() {
  [ -f "$1" ] || { echo ""; return 0; }
  # grep -m1 instead of `| head -n1`: with `set -o pipefail` a SIGPIPE in the
  # grep would turn a successful match into a non-zero pipeline status.
  grep -m1 '^STATE=' "$1" | cut -d= -f2-
}

cmd_check() {
  local quiet="${1:-0}"
  local missing=0
  local dl_state fin_state

  dl_state="$(state_of "$DL_STATUS")"
  fin_state="$(state_of "$FINAL_STATUS")"

  if [ "$dl_state" != "DONE" ]; then
    echo "MISSING: download state is '${dl_state:-<absent>}' (expected DONE) — $DL_STATUS"
    missing=1
  fi
  if [ "$fin_state" != "DONE" ]; then
    echo "MISSING: finalize state is '${fin_state:-<absent>}' (expected DONE) — $FINAL_STATUS"
    missing=1
  fi
  if [ ! -f "$FINAL_LOG" ]; then
    echo "MISSING: finalize log — $FINAL_LOG"
    missing=1
  else
    local marker
    for marker in "${REQUIRED_MARKERS[@]}"; do
      if ! grep -qF "$marker" "$FINAL_LOG"; then
        echo "MISSING: marker '$marker' — $FINAL_LOG"
        missing=1
      fi
    done
  fi
  if [ ! -f "$SHA256SUMS" ]; then
    echo "MISSING: SHA256SUMS — $SHA256SUMS"
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    echo "SEED_REPORT_FAIL missing=1"
    return 1
  fi
  [ "$quiet" = "1" ] || echo "SEED_REPORT_OK missing=0"
  return 0
}

cmd_report() {
  if ! cmd_check quiet; then
    return 1
  fi
  local sums_lines
  sums_lines="$(grep -c . "$SHA256SUMS" 2>/dev/null || true)"
  [ -n "$sums_lines" ] || sums_lines=0

  echo "--- terminal states ---"
  echo "SEED_REPORT_DOWNLOAD_STATE=$(state_of "$DL_STATUS")"
  echo "SEED_REPORT_FINALIZE_STATE=$(state_of "$FINAL_STATUS")"
  echo "SEED_REPORT_SHA256SUMS_LINES=$sums_lines"

  echo "--- marker 原文（逐条，来自 $FINAL_LOG）---"
  local marker
  for marker in "${REQUIRED_MARKERS[@]}"; do
    grep -m1 -F "$marker" "$FINAL_LOG" || true
  done

  echo "--- 可直接回填文档的数值 ---"
  echo "SEED_REPORT_G1_CLIPS=142220"
  echo "SEED_REPORT_SOMA_CLIPS=142220"
  echo "SEED_REPORT_META_MATCHED=142220"
  echo "SEED_REPORT_META_MISSING=0"
  echo "SEED_REPORT_META_EXTRA=0"
  echo "SEED_REPORT_EXTRACTED_FILES=284440"
  echo "SEED_REPORT_ARCHIVE_FILES=3"
  echo "SEED_REPORT_LOG=$FINAL_LOG"
  echo "SEED_REPORT_SHA256SUMS=$SHA256SUMS"
  echo "SEED_REPORT_OK missing=0"
  return 0
}

case "${1:-report}" in
  report) cmd_report ;;
  check)  cmd_check ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
