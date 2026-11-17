#!/usr/bin/env bash
# repro/26_deploy_verify.sh — the READ-ONLY, INDEPENDENT terminal reviewer
# of the deployment verification (slice S08, task T7).
#
# ---------------------------------------------------------------------------
# WHY A SEPARATE, READ-ONLY REVIEWER
#
# The orchestrators 21..25 judge their own step; if the slice accepted
# their self-reports, the acceptance would be a self-proof.  This reviewer
# never trusts what they claim: it re-derives EVERY fact from the artefacts
# on disk, i.e.
#
#   * assets/ holds the scene xml, the meshes and one non-empty npz per clip
#     of the sampled clip list (assets/clips_g1_amber.txt),
#   * runs/sim2sim/summary/*.json holds one summary per clip, each with a
#     non-empty result / joint_err_rms_rad / body_err_mean_m / end_drift_m,
#     and every clip has a non-empty runs/sim2sim/video/*.mp4,
#   * runs/eval/eval_motion_1h.csv and runs/eval/eval_human_full_1h.csv hold
#     one row per clip of the 1h subset (490), with a parsable `failed`
#     column (the completion is RECOMPUTED from it),
#   * runs/official/morphmimic_policy/ holds a non-empty policy.onnx and
#     g1_amber.json, and the SHA-256 digests are RECOMPUTED from the bytes
#     on disk (the reviewer's own digest, not the `sha256sum -c` self-report),
#   * runs/official/compare_self_vs_official.csv holds one row per compared
#     clip, with non-empty numbers on both sides and a concrete delta,
#   * runs/human/session.npz (PICO layout), runs/human/replay_summary.json
#     and a non-empty runs/human/replay.mp4.
#
# It is READ-ONLY: apart from its own log (logs/env/26_deploy_verify.txt)
# it never writes a single byte -- in particular it never touches assets/,
# runs/ or out/.
#
# The decision logic is NOT implemented here: it is delegated to the
# stdlib-only decision base repro/lib/deploy.py (through the thin wrapper
# repro/lib/deploy.sh), so that the orchestrators, this reviewer and the
# offline fixtures all speak the same verdict.  The fixed failure-reason
# set is deploy.py's REASONS (see the comment block of that file).
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   verify   the terminal gate.  Prints ONE OK MARKER line
#              DEPLOY_VERIFY_OK assets_clips=<n> sim_clips=<n>
#                eval_motion_rows=<n> eval_human_rows=<n>
#                official_sha_files=<n> compare_rows=<n> human_steps=<n>
#            or, on failure, ONE FAIL MARKER line
#              DEPLOY_VERIFY_FAIL reason=<fixed reason set>
#            and a non-zero exit code.  The OK marker is BUFFERED and flushed
#            only after every check passed (project convention P004): a
#            failing run NEVER prints an OK marker.
#
#   report   the same facts in the `DEPLOY_REPORT_*` form, for the
#            documentation back-fill (per-interface completion, the official
#            digest prefixes, the sim2sim and delta means, the artefact paths
#            and byte sizes).  The report NEVER prints the gate marker.
#
#   selftest the offline fixture battery (repro/tests/test_deploy_verify.sh).
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one exists so the offline fixture battery can
# drive the reviewer without the container and without the real artefacts)
#
#   DEPLOY_ALLOW_LOCAL=1      allow running outside the ros_dev container
#   DEPLOY_ASSETS_DIR         the exported assets   (default $REPO_ROOT/assets)
#   DEPLOY_CLIP_LIST          the sampled clip list (default
#                             $DEPLOY_ASSETS_DIR/clips_g1_amber.txt)
#   DEPLOY_SIM_DIR            the sim2sim replays   (default
#                             $REPO_ROOT/runs/sim2sim)
#   DEPLOY_EVAL_DIR           the eval tables      (default
#                             $REPO_ROOT/runs/eval)
#   DEPLOY_EVAL_EXPECT_ROWS   the expected row count of both eval CSVs
#                             (default: the clip count of DEPLOY_SUBSET_YAML)
#   DEPLOY_SUBSET_YAML        the subset yaml      (default
#                             $REPO_ROOT/data/seed_g1_npz50/subsets/1h.yaml)
#   DEPLOY_OFFICIAL_DIR       the official weights (default
#                             $REPO_ROOT/runs/official/morphmimic_policy)
#   DEPLOY_COMPARE_CSV        the comparison table (default
#                             $REPO_ROOT/runs/official/compare_self_vs_official.csv)
#   DEPLOY_HUMAN_DIR          the human artefacts  (default
#                             $REPO_ROOT/runs/human)
#   DEPLOY_LOG_DIR            log directory        (default $LOG_DIR)
#   DEPLOY_PY                 the decision-base interpreter (default python3)
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/deploy.sh
source "$_SCRIPT_DIR/lib/deploy.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 22_sim2sim.sh convention).
set +e

if [ "${DEPLOY_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${DEPLOY_LOG_DIR:-$LOG_DIR}"
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/26_deploy_verify.txt"

ASSETS_DIR="${DEPLOY_ASSETS_DIR:-$REPO_ROOT/assets}"
CLIP_LIST="${DEPLOY_CLIP_LIST:-$ASSETS_DIR/clips_g1_amber.txt}"
SIM_DIR="${DEPLOY_SIM_DIR:-$REPO_ROOT/runs/sim2sim}"
SIM_SUMMARY_DIR="$SIM_DIR/summary"
SIM_VIDEO_DIR="$SIM_DIR/video"
EVAL_DIR="${DEPLOY_EVAL_DIR:-$REPO_ROOT/runs/eval}"
EVAL_MOTION_CSV="${DEPLOY_EVAL_MOTION_CSV:-$EVAL_DIR/eval_motion_1h.csv}"
EVAL_HUMAN_CSV="${DEPLOY_EVAL_HUMAN_CSV:-$EVAL_DIR/eval_human_full_1h.csv}"
SUBSET_YAML="${DEPLOY_SUBSET_YAML:-$REPO_ROOT/data/seed_g1_npz50/subsets/1h.yaml}"
OFFICIAL_DIR="${DEPLOY_OFFICIAL_DIR:-$REPO_ROOT/runs/official/morphmimic_policy}"
COMPARE_CSV="${DEPLOY_COMPARE_CSV:-$REPO_ROOT/runs/official/compare_self_vs_official.csv}"
HUMAN_DIR="${DEPLOY_HUMAN_DIR:-$REPO_ROOT/runs/human}"
SESSION_NPZ="$HUMAN_DIR/session.npz"
REPLAY_SUMMARY="$HUMAN_DIR/replay_summary.json"
REPLAY_VIDEO="$HUMAN_DIR/replay.mp4"
ROBOT="${DEPLOY_ROBOT:-g1_amber}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/26_deploy_verify.sh <verify|report|selftest>

  verify    the terminal gate (DEPLOY_VERIFY_OK / DEPLOY_VERIFY_FAIL reason=...)
  report    the same facts as DEPLOY_REPORT_* lines (documentation back-fill)
  selftest  the offline fixture battery (repro/tests/test_deploy_verify.sh)

assets:    $ASSETS_DIR
clip list: $CLIP_LIST
sim2sim:   $SIM_SUMMARY_DIR
eval:      $EVAL_DIR
official:  $OFFICIAL_DIR
compare:   $COMPARE_CSV
human:     $HUMAN_DIR
subset:    $SUBSET_YAML
log:       $MAIN_LOG
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
# the decision (delegated to repro/lib/deploy.py -- no logic of its own here)
# ---------------------------------------------------------------------------

# expected_eval_rows
# The expected number of data rows of both eval CSVs.  It is read from the
# subset yaml (the clip count of the 1h subset) so that the reviewer never
# hardcodes a number; DEPLOY_EVAL_EXPECT_ROWS overrides it (the offline
# fixture battery drives a two-clip subset).
expected_eval_rows() {
  if [ -n "${DEPLOY_EVAL_EXPECT_ROWS:-}" ]; then
    printf '%s' "$DEPLOY_EVAL_EXPECT_ROWS"
    return 0
  fi
  if [ ! -f "$SUBSET_YAML" ]; then
    printf ''
    return 0
  fi
  local output
  output="$(deploy_run subset --path "$SUBSET_YAML" 2>/dev/null)"
  printf '%s' "$(printf '%s\n' "$output" | sed -n 's/.*clips=\([0-9][0-9]*\).*/\1/p' | head -n1)"
}

# reviewer_args — the argument list of the decision base.
reviewer_args() {
  printf '%s\n' \
    --assets-dir "$ASSETS_DIR" \
    --clip-list "$CLIP_LIST" \
    --sim-summary-dir "$SIM_SUMMARY_DIR" \
    --sim-video-dir "$SIM_VIDEO_DIR" \
    --eval-motion-csv "$EVAL_MOTION_CSV" \
    --eval-human-csv "$EVAL_HUMAN_CSV" \
    --official-dir "$OFFICIAL_DIR" \
    --compare-csv "$COMPARE_CSV" \
    --session "$SESSION_NPZ" \
    --replay-summary "$REPLAY_SUMMARY" \
    --human-video "$REPLAY_VIDEO" \
    --robot "$ROBOT"
}

# run_decision <verify-all|report-all> — prints the decision base output and
# returns its exit code.  The decision base owns the marker format.
run_decision() {
  local command="$1"
  local rows
  rows="$(expected_eval_rows)"
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=("$line")
  done < <(reviewer_args)
  if [ -n "$rows" ]; then
    args+=(--eval-expect-rows "$rows")
  fi
  deploy_run "$command" "${args[@]}"
}

# ---------------------------------------------------------------------------
# cmd_verify
# ---------------------------------------------------------------------------
cmd_verify() {
  elog "=== 26_deploy_verify.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "assets:    $ASSETS_DIR"
  elog "clip list: $CLIP_LIST"
  elog "sim2sim:   $SIM_SUMMARY_DIR"
  elog "eval:      $EVAL_MOTION_CSV $EVAL_HUMAN_CSV"
  elog "official:  $OFFICIAL_DIR"
  elog "compare:   $COMPARE_CSV"
  elog "human:     $HUMAN_DIR"

  local output rc
  output="$(run_decision verify-all 2>&1)"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    # A failing run prints the FAIL marker and NOTHING else that could be
    # mistaken for a success marker.
    local reason
    reason="$(printf '%s\n' "$output" | sed -n 's/^DEPLOY_VERIFY_FAIL reason=\([a-z-]*\).*$/\1/p' | head -n1)"
    if [ -z "$reason" ]; then
      # The decision base produced no verdict at all (e.g. the interpreter is
      # missing): fail closed on the first reason of the fixed set.
      reason="summary-parse-failed"
      elog "  the decision base produced no verdict:"
      printf '%s\n' "$output" | sed 's/^/      | /' >>"$MAIN_LOG" 2>/dev/null || true
    fi
    elog "DEPLOY_VERIFY_FAIL reason=$reason"
    return 1
  fi

  # rc == 0: the decision base printed exactly one OK marker line.
  local marker
  marker="$(printf '%s\n' "$output" | grep '^DEPLOY_VERIFY_OK ' | head -n1)"
  if [ -z "$marker" ]; then
    elog "  the decision base exited 0 without an OK marker"
    elog "DEPLOY_VERIFY_FAIL reason=summary-parse-failed"
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
  elog "=== 26_deploy_verify.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  local output rc
  output="$(run_decision report-all 2>&1)"
  rc=$?

  # The report prints the DEPLOY_REPORT_* lines only.  The gate marker
  # (DEPLOY_VERIFY_OK) belongs to `verify`; it is filtered out here so that
  # the log of a report run cannot be mistaken for a passed gate.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      DEPLOY_VERIFY_OK*) continue ;;
    esac
    elog "$line"
  done <<EOF
$output
EOF

  if [ "$rc" -ne 0 ]; then
    elog "DEPLOY_REPORT_OK=0"
    return 1
  fi

  # The RAW `sha256sum -c` transcript is kept as evidence.  It is NOT the
  # verdict (the reviewer recomputes the digests itself); it only shows the
  # upstream manifest next to the recomputed ones.
  if [ -f "$OFFICIAL_DIR/SHA256SUMS" ]; then
    elog "--- sha256sum -c $OFFICIAL_DIR/SHA256SUMS (raw transcript) ---"
    (cd "$OFFICIAL_DIR" && sha256sum -c SHA256SUMS 2>&1) | while IFS= read -r line; do
      elog "  $line"
    done
  fi

  elog "DEPLOY_REPORT_OK=1"
  return 0
}

# ---------------------------------------------------------------------------
# cmd_selftest
# ---------------------------------------------------------------------------
cmd_selftest() {
  elog "=== 26_deploy_verify.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  bash "$_SCRIPT_DIR/tests/test_deploy_verify.sh"
  return $?
}

case "${1:-}" in
  verify)   shift || true; cmd_verify "$@" ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/26_deploy_verify.sh <verify|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
