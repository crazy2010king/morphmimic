#!/usr/bin/env bash
# repro/20_export_verify.sh — the READ-ONLY, INDEPENDENT terminal reviewer
# of the g1_amber ONNX export (slice S07, task T2).
#
# ---------------------------------------------------------------------------
# WHY A SEPARATE, READ-ONLY REVIEWER
#
# If the exporter judged its own artefacts, the acceptance would be a
# self-proof.  This script never trusts what repro/19_export.sh claims: it
# re-derives EVERY fact from the artefacts on disk (out/g1_amber/), i.e.
#
#   * the four artefacts exist and are non-empty,
#   * MANIFEST.txt carries a parsable parity block for the robot,
#   * every interface parity is <= 1e-4 (the upstream tolerance),
#   * SHA256SUMS covers policy.onnx and <robot>.json and the digests are
#     RECOMPUTED from the bytes on disk and compared.
#
# It is READ-ONLY: apart from its own log (logs/env/20_export_verify.txt) it
# never writes a single byte -- in particular it never touches the export
# directory.  It never launches the export toolchain (no inference runtime, no
# GPU) and never touches the network.
#
# The decision logic is NOT implemented here: it is delegated to the
# stdlib-only decision base repro/lib/export.py (through the thin wrapper
# repro/lib/export.sh), so that the exporter, this reviewer and the offline
# fixtures all speak the same verdict.  The fixed failure-reason set is
# export.py's REASONS:
#
#   missing-file  empty-file  manifest-parse-failed  parity-over-tol
#   sha-missing   sha-mismatch  robot-mismatch
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   verify   the terminal gate.  Prints ONE OK MARKER line
#              EXPORT_VERIFY_OK files=4 parity_max=<v> sha_files=2 robot=<r>
#            or, on failure, ONE FAIL MARKER line
#              EXPORT_VERIFY_FAIL reason=<fixed reason set>
#            and a non-zero exit code.  The OK marker is BUFFERED and flushed
#            only after every check passed (project convention P004): a
#            failing run NEVER prints an OK marker.
#
#   report   the same facts in the `EXPORT_REPORT_*` form, for the
#            documentation back-fill (parity per interface, byte sizes,
#            SHA256SUMS coverage with the digest prefix, source checkpoint).
#            The report NEVER prints the gate marker (EXPORT_VERIFY_OK is
#            the verdict of `verify`, not of the report); a failing report
#            prints the EXPORT_VERIFY_FAIL line and exits non-zero.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one exists so the offline fixture battery can
# drive the reviewer without the container, without the export toolchain and
# without the real export)
#
#   EXPORT_ALLOW_LOCAL=1  allow running outside the ros_dev container
#   EXPORT_OUT_DIR        the export directory (default $REPO_ROOT/out/g1_amber)
#   EXPORT_ROBOT          the robot name      (default g1_amber)
#   EXPORT_ATOL           parity tolerance   (default 1e-4)
#   EXPORT_LOG_DIR        log directory       (default $LOG_DIR)
#   EXPORT_PY             the decision-base interpreter (default python3)
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/export.sh
source "$_SCRIPT_DIR/lib/export.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 18_train_verify.sh convention).
set +e

if [ "${EXPORT_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${EXPORT_LOG_DIR:-$LOG_DIR}"
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/20_export_verify.txt"
OUT_DIR="${EXPORT_OUT_DIR:-$REPO_ROOT/out/g1_amber}"
ROBOT="${EXPORT_ROBOT:-g1_amber}"
ATOL="${EXPORT_ATOL:-1e-4}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/20_export_verify.sh <verify|report>

  verify   the terminal gate (EXPORT_VERIFY_OK / EXPORT_VERIFY_FAIL reason=...)
  report   the same facts as EXPORT_REPORT_* lines (documentation back-fill)

out dir:  $OUT_DIR
robot:    $ROBOT
atol:     $ATOL
log:      $MAIN_LOG
EOF
}

# --- output ----------------------------------------------------------------
# Every marker is written to stdout AND appended to the log file, so the log
# file is greppable after the fact.
elog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK marker is buffered and flushed ONLY when every check passed
# (project convention P004: a failing run prints zero OK markers).
OK_MARKERS=()
elog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do elog "$m"; done
  OK_MARKERS=()
}

# ---------------------------------------------------------------------------
# the decision (delegated to repro/lib/export.py -- no logic of its own here)
# ---------------------------------------------------------------------------

# run_decision <verify|report> — prints the decision base output and returns
# its exit code.  The decision base owns the marker format.
run_decision() {
  export_run "$1" --out-dir "$OUT_DIR" --robot "$ROBOT" --atol "$ATOL"
}

# ---------------------------------------------------------------------------
# cmd_verify
# ---------------------------------------------------------------------------
cmd_verify() {
  elog "=== 20_export_verify.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "out dir: $OUT_DIR"
  elog "robot:   $ROBOT   atol: $ATOL"

  local output rc
  output="$(run_decision verify 2>&1)"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    # A failing run prints the FAIL marker and NOTHING else that could be
    # mistaken for a success marker.
    local reason
    reason="$(printf '%s\n' "$output" | sed -n 's/^EXPORT_VERIFY_FAIL reason=\([a-z-]*\).*$/\1/p' | head -n1)"
    if [ -z "$reason" ]; then
      # The decision base produced no verdict at all (e.g. the interpreter is
      # missing): fail closed on the first reason of the fixed set.
      reason="manifest-parse-failed"
      elog "  the decision base produced no verdict:"
      printf '%s\n' "$output" | sed 's/^/      | /' >>"$MAIN_LOG" 2>/dev/null || true
    fi
    elog "EXPORT_VERIFY_FAIL reason=$reason"
    return 1
  fi

  # rc == 0: the decision base printed exactly one OK marker line.
  local marker
  marker="$(printf '%s\n' "$output" | grep '^EXPORT_VERIFY_OK ' | head -n1)"
  if [ -z "$marker" ]; then
    elog "  the decision base exited 0 without an OK marker"
    elog "EXPORT_VERIFY_FAIL reason=manifest-parse-failed"
    return 1
  fi
  elog_ok "$marker"
  flush_ok_markers
  return 0
}

# ---------------------------------------------------------------------------
# cmd_report
# ---------------------------------------------------------------------------
cmd_report() {
  elog "=== 20_export_verify.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  local output rc
  output="$(run_decision report 2>&1)"
  rc=$?

  # The report prints the EXPORT_REPORT_* lines only.  The gate marker
  # (EXPORT_VERIFY_OK) belongs to `verify`; it is filtered out here so that
  # the log of a report run cannot be mistaken for a passed gate.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      EXPORT_VERIFY_OK*) continue ;;
    esac
    elog "$line"
  done <<EOF
$output
EOF

  if [ "$rc" -ne 0 ]; then
    elog "EXPORT_REPORT_OK=0"
    return 1
  fi
  elog "EXPORT_REPORT_OK=1"
  return 0
}

case "${1:-}" in
  verify) shift || true; cmd_verify "$@" ;;
  report) shift || true; cmd_report "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/20_export_verify.sh <verify|report>" >&2
    usage >&2
    exit 2
    ;;
esac
