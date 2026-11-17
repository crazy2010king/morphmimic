#!/usr/bin/env bash
# repro/28_doc_verify.sh — the READ-ONLY verifier of the reproduction
# record (slice S09, task T2).
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT IS
#
# The reproduction record (docs/code_read/MorphMimic完整复现记录.md, the
# in-repo mirror of the user-facing docs/code_doc/ copy) claims that every
# one of its conclusions is traceable to a concrete command and to the
# output of that command.  Until now that claim was prose.  This script
# turns it into a verdict:
#
#   * the nine chapters are present,
#   * the front matter declares "流程复现，非数值等价复现",
#   * chapter 3 holds the deviation list, chapter 4 the three
#     "analysed but not executed" items,
#   * the evidence index table has one row per conclusion, every evidence
#     file exists relative to the repository root, and every key output
#     string is really greppable in that file,
#   * the SHA-256 digests of out/g1_amber and of the official policy
#     directory RECOMPUTE,
#   * both eval CSVs hold 490 rows and their completion RECOMPUTES from
#     the `failed` column (the document's self-report is never trusted),
#   * the comparison table holds 49 rows and the record quotes its
#     recomputed delta means,
#   * the training curve CSV covers the whole run,
#   * no plaintext token appears in the record.
#
# It is READ-ONLY: apart from its own log (logs/env/28_doc_verify.txt) it
# never writes a single byte -- in particular it never touches the record,
# docs/code_read/, docs/code_doc/, runs/ or out/.
#
# The DECISIONS are NOT implemented here: they live in the stdlib-only
# decision base repro/lib/doc.py (through the thin wrapper
# repro/lib/doc.sh), so that the host, the container and the offline
# fixtures all speak the same verdict.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   verify    the terminal gate.  Prints ONE OK MARKER line
#                DOC_VERIFY_OK sections=9 evidence_rows=<n> sha_ok=1
#                          eval_rows=490 compare_rows=49 curve_rows=<m>
#            or, on failure, ONE FAIL MARKER line
#                DOC_VERIFY_FAIL reason=<fixed reason set>
#            and a non-zero exit code.  The OK marker is BUFFERED and
#            flushed only after every check passed (project convention
#            P004): a failing run NEVER prints an OK marker.
#
#   mirror    the byte-identity of the in-repo record and its published
#            copy in docs/code_doc/.  Prints
#                DOC_MIRROR_OK mirror_match=1
#            or
#                DOC_MIRROR_FAIL reason=mirror-missing|mirror-mismatch
#
#   report    the facts the record has to quote (DOC_REPORT_* lines).
#            It NEVER prints the gate marker.
#
#   selftest  the offline fixture battery (repro/tests/test_doc_verify.sh).
#
# NOTE: `verify` NEVER depends on docs/code_doc/.  The docs/code_doc
# symlink is broken inside the ros_dev container (MEM023 / D009), so the
# container-side gate checks the in-repo mirror only.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SET (greppable, see repro/lib/doc.py REASONS)
#
#   doc-missing / doc-empty / section-missing
#   process-replication-missing / unexecuted-section-missing
#   deviation-section-missing
#   evidence-table-missing / evidence-table-malformed
#   evidence-row-invalid / evidence-path-missing / evidence-marker-missing
#   sha-missing / sha-mismatch
#   eval-csv-missing / eval-row-count-mismatch / completion-mismatch
#   compare-missing / compare-parse-failed / compare-row-count-mismatch
#   compare-delta-mismatch
#   curve-missing / curve-parse-failed / curve-step-missing
#   token-leaked
#   mirror-missing / mirror-mismatch
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one exists so the offline fixture battery
# can drive the verifier without the real artefacts)
#
#   DOC_ALLOW_LOCAL=1     allow running outside the ros_dev container
#                          (the verifier is read-only and pure-python, so
#                          it runs on the host as well)
#   DOC_REPO_ROOT         the repository root the evidence paths are
#                          resolved against (default $REPO_ROOT)
#   DOC_PATH              the record to verify (default
#                          $REPO_ROOT/docs/code_read/MorphMimic完整复现记录.md)
#   DOC_MIRROR_PATH       the published copy (default
#                          $REPO_ROOT/docs/code_doc/MorphMimic完整复现记录.md)
#   DOC_EVAL_MOTION_CSV   runs/eval/eval_motion_1h.csv
#   DOC_EVAL_HUMAN_CSV    runs/eval/eval_human_full_1h.csv
#   DOC_COMPARE_CSV       runs/official/compare_self_vs_official.csv
#   DOC_CURVE_CSV         runs/train_curves/g1_amber_1h_curves.csv
#   DOC_SELF_SHA_DIR      out/g1_amber
#   DOC_OFFICIAL_SHA_DIR  runs/official/morphmimic_policy
#   DOC_EXPECT_SECTIONS       default 9
#   DOC_EXPECT_EVAL_ROWS      default 490
#   DOC_EXPECT_COMPARE_ROWS   default 49
#   DOC_EXPECT_CURVE_MIN_STEP default 50
#   DOC_EXPECT_CURVE_MAX_STEP default 26413
#   DOC_EXPECT_COMPLETION     default 1.0
#   DOC_MIN_DEVIATIONS        default 20
#   DOC_LOG_DIR           log directory (default $LOG_DIR)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/doc.sh
source "$_SCRIPT_DIR/lib/doc.sh"

# common.sh turns on `set -e`; every failure path below is handled
# explicitly, so errexit is disabled here (the 16_seed_human_verify.sh
# convention).
set +e

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${DOC_LOG_DIR:-$LOG_DIR}"
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/28_doc_verify.txt"

DOC_ROOT="${DOC_REPO_ROOT:-$REPO_ROOT}"
DOC_PATH="${DOC_PATH:-$DOC_ROOT/docs/code_read/MorphMimic完整复现记录.md}"
DOC_MIRROR_PATH="${DOC_MIRROR_PATH:-$DOC_ROOT/docs/code_doc/MorphMimic完整复现记录.md}"
DOC_EVAL_MOTION_CSV="${DOC_EVAL_MOTION_CSV:-$DOC_ROOT/runs/eval/eval_motion_1h.csv}"
DOC_EVAL_HUMAN_CSV="${DOC_EVAL_HUMAN_CSV:-$DOC_ROOT/runs/eval/eval_human_full_1h.csv}"
DOC_COMPARE_CSV="${DOC_COMPARE_CSV:-$DOC_ROOT/runs/official/compare_self_vs_official.csv}"
DOC_CURVE_CSV="${DOC_CURVE_CSV:-$DOC_ROOT/runs/train_curves/g1_amber_1h_curves.csv}"
DOC_SELF_SHA_DIR="${DOC_SELF_SHA_DIR:-$DOC_ROOT/out/g1_amber}"
DOC_OFFICIAL_SHA_DIR="${DOC_OFFICIAL_SHA_DIR:-$DOC_ROOT/runs/official/morphmimic_policy}"
DOC_EXPECT_SECTIONS="${DOC_EXPECT_SECTIONS:-9}"
DOC_EXPECT_EVAL_ROWS="${DOC_EXPECT_EVAL_ROWS:-490}"
DOC_EXPECT_COMPARE_ROWS="${DOC_EXPECT_COMPARE_ROWS:-49}"
DOC_EXPECT_CURVE_MIN_STEP="${DOC_EXPECT_CURVE_MIN_STEP:-50}"
DOC_EXPECT_CURVE_MAX_STEP="${DOC_EXPECT_CURVE_MAX_STEP:-26413}"
DOC_EXPECT_COMPLETION="${DOC_EXPECT_COMPLETION:-1.0}"
DOC_MIN_DEVIATIONS="${DOC_MIN_DEVIATIONS:-20}"
DOC_PY_BIN="${DOC_PY:-python3}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/28_doc_verify.sh <verify|mirror|report|selftest>

  verify    the terminal gate (DOC_VERIFY_OK / DOC_VERIFY_FAIL reason=...)
  mirror    the byte identity of the record and its published copy
            (DOC_MIRROR_OK / DOC_MIRROR_FAIL reason=...)
  report    the facts the record has to quote (DOC_REPORT_*)
  selftest  the offline fixture battery (repro/tests/test_doc_verify.sh)

record:     $DOC_PATH
mirror:     $DOC_MIRROR_PATH
repo root:  $DOC_ROOT
eval:       $DOC_EVAL_MOTION_CSV $DOC_EVAL_HUMAN_CSV
compare:    $DOC_COMPARE_CSV
curve:      $DOC_CURVE_CSV
sha dirs:   $DOC_SELF_SHA_DIR $DOC_OFFICIAL_SHA_DIR
log:        $MAIN_LOG
EOF
}

# --- output -----------------------------------------------------------------
# Every marker is written to stdout AND appended to the log file, so the log
# file is greppable after the fact.
elog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed ONLY when every check passed
# (project convention P004: a failing run prints zero OK markers).
OK_MARKERS=()
elog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do elog "$m"; done
  OK_MARKERS=()
}

# rel_path <path> — the path relative to the repository root (the marker
# must stay stable between the host and the container).
rel_path() {
  local path="$1"
  case "$path" in
    "$DOC_ROOT"/*) printf '%s' "${path#"$DOC_ROOT"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

# verify_args — the argument list of the decision base.
verify_args() {
  printf '%s\n' \
    --doc "$DOC_PATH" \
    --repo-root "$DOC_ROOT" \
    --eval-motion-csv "$DOC_EVAL_MOTION_CSV" \
    --eval-human-csv "$DOC_EVAL_HUMAN_CSV" \
    --compare-csv "$DOC_COMPARE_CSV" \
    --curve-csv "$DOC_CURVE_CSV" \
    --self-sha-dir "$DOC_SELF_SHA_DIR" \
    --official-sha-dir "$DOC_OFFICIAL_SHA_DIR" \
    --expect-sections "$DOC_EXPECT_SECTIONS" \
    --expect-eval-rows "$DOC_EXPECT_EVAL_ROWS" \
    --expect-compare-rows "$DOC_EXPECT_COMPARE_ROWS" \
    --expect-curve-min-step "$DOC_EXPECT_CURVE_MIN_STEP" \
    --expect-curve-max-step "$DOC_EXPECT_CURVE_MAX_STEP" \
    --expect-completion "$DOC_EXPECT_COMPLETION" \
    --min-deviations "$DOC_MIN_DEVIATIONS"
}

# run_decision <verify|report> — prints the decision base output and
# returns its exit code.  The decision base owns the marker format.
run_decision() {
  local command="$1"
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=("$line")
  done < <(verify_args)
  doc_run "$command" "${args[@]}"
}

# fail_with <reason> — the single failure line of the gate.
fail_with() {
  elog "DOC_VERIFY_FAIL reason=$1"
  return 1
}

# ---------------------------------------------------------------------------
# cmd_verify
# ---------------------------------------------------------------------------
cmd_verify() {
  elog "=== 28_doc_verify.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "record:    $(rel_path "$DOC_PATH")"
  elog "repo root: $DOC_ROOT"
  elog "eval:      $(rel_path "$DOC_EVAL_MOTION_CSV") $(rel_path "$DOC_EVAL_HUMAN_CSV")"
  elog "compare:   $(rel_path "$DOC_COMPARE_CSV")"
  elog "curve:     $(rel_path "$DOC_CURVE_CSV")"
  elog "sha dirs:  $(rel_path "$DOC_SELF_SHA_DIR") $(rel_path "$DOC_OFFICIAL_SHA_DIR")"

  # The evidence files this document cites live in the PERSISTENT STORE, so
  # a broken store would make every evidence row unreadable.  Say so
  # explicitly instead of failing later with a confusing "path missing".
  #
  # The check runs in a SUBPROCESS on purpose: sourcing repro/lib/seed_store.sh
  # into this script would change this script's shell options.
  if [ -f "$REPO_ROOT/repro/lib/seed_store.sh" ]; then
    local store_out
    store_out="$(bash -c '
      set -uo pipefail
      REPO_ROOT="$1"
      source "$1/repro/lib/seed_store.sh" >/dev/null 2>&1 || true
      if declare -F seed_store_check_impl >/dev/null 2>&1; then
        seed_store_check_impl
      else
        echo "SEED_STORE_SKIP reason=library-unavailable"
      fi
    ' _ "$REPO_ROOT" 2>&1)" || true
    printf '%s\n' "$store_out" | grep -aE '^(SEED_STORE_|FAIL )' | while IFS= read -r line; do
      elog "  store: $line"
    done
    if printf '%s\n' "$store_out" | grep -q 'SEED_STORE_FAIL'; then
      fail_with "evidence-path-missing"
      return 1
    fi
  fi

  local output rc
  output="$(run_decision verify 2>&1)"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    local reason
    reason="$(printf '%s\n' "$output" | sed -n 's/^DOC_VERIFY_FAIL reason=\([a-z-]*\).*$/\1/p' | head -n1)"
    if [ -z "$reason" ]; then
      # The decision base produced no verdict at all (e.g. the interpreter
      # is missing): fail closed on the first reason of the fixed set.
      reason="evidence-table-missing"
      elog "  the decision base produced no verdict:"
      printf '%s\n' "$output" | sed 's/^/      | /' >>"$MAIN_LOG" 2>/dev/null || true
    fi
    fail_with "$reason"
    return 1
  fi

  # rc == 0: the decision base printed exactly one OK marker line.
  local marker
  marker="$(printf '%s\n' "$output" | grep '^DOC_VERIFY_OK ' | head -n1)"
  if [ -z "$marker" ]; then
    elog "  the decision base exited 0 without an OK marker"
    fail_with "evidence-table-missing"
    return 1
  fi
  elog_ok "$marker"
  flush_ok_markers
  return 0
}

# ---------------------------------------------------------------------------
# cmd_mirror
# ---------------------------------------------------------------------------
cmd_mirror() {
  elog "=== 28_doc_verify.sh mirror $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "record: $(rel_path "$DOC_PATH")"
  elog "mirror: $(rel_path "$DOC_MIRROR_PATH")"

  local output rc
  output="$(doc_run mirror --doc "$DOC_PATH" --mirror "$DOC_MIRROR_PATH" 2>&1)"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    local reason
    reason="$(printf '%s\n' "$output" | sed -n 's/^DOC_MIRROR_FAIL reason=\([a-z-]*\).*$/\1/p' | head -n1)"
    if [ -z "$reason" ]; then
      reason="mirror-missing"
      elog "  the decision base produced no verdict:"
      printf '%s\n' "$output" | sed 's/^/      | /' >>"$MAIN_LOG" 2>/dev/null || true
    fi
    elog "DOC_MIRROR_FAIL reason=$reason"
    return 1
  fi

  local marker
  marker="$(printf '%s\n' "$output" | grep '^DOC_MIRROR_OK ' | head -n1)"
  if [ -z "$marker" ]; then
    elog "  the decision base exited 0 without an OK marker"
    elog "DOC_MIRROR_FAIL reason=mirror-missing"
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
  elog "=== 28_doc_verify.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  local output rc
  output="$(run_decision report 2>&1)"
  rc=$?

  # The report prints the DOC_REPORT_* lines only.  The gate marker
  # (DOC_VERIFY_OK) belongs to `verify`; it is filtered out here so that
  # the log of a report run cannot be mistaken for a passed gate.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      DOC_VERIFY_OK*) continue ;;
    esac
    elog "$line"
  done <<EOF
$output
EOF

  if [ "$rc" -ne 0 ]; then
    elog "DOC_REPORT_OK=0"
    return 1
  fi
  elog "DOC_REPORT_OK=1"
  return 0
}

# ---------------------------------------------------------------------------
# cmd_selftest
# ---------------------------------------------------------------------------
cmd_selftest() {
  local test_file="$REPO_ROOT/repro/tests/test_doc_verify.sh"
  if [ ! -f "$test_file" ]; then
    elog "DOC_VERIFY_SELFTEST_FAIL reason=test-missing"
    return 1
  fi
  bash "$test_file"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    elog "DOC_VERIFY_SELFTEST_FAIL reason=selftest-failed"
    return 1
  fi
  elog "DOC_VERIFY_SELFTEST_OK cases=1"
  return 0
}

case "${1:-}" in
  verify) shift || true; cmd_verify "$@" ;;
  mirror) shift || true; cmd_mirror "$@" ;;
  report) shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/28_doc_verify.sh <verify|mirror|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
