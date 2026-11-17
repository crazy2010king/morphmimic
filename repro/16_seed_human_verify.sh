#!/usr/bin/env bash
# repro/16_seed_human_verify.sh — the READ-ONLY, INDEPENDENT re-checker of
# the human50 sidecars produced by slice S05.
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT DOES
#
#   verify  re-derives the human50 consistency facts FROM THE FILES and
#           asserts them; it never trusts the output of upstream
#           `check_human` (that would be a self-proof).
#   report  prints the same numbers in the `SEED_REPORT_HUMAN_*` form so the
#           documentation can be back-filled from the machine.
#
# ---------------------------------------------------------------------------
# WHAT "INDEPENDENT" MEANS HERE
#
# Three facts are proven by this script itself:
#
#   (a) SET EXACTNESS — the set of sidecars under `<npz_root>/human50` is
#       EXACTLY the set the subset implies: both directions are compared
#       (`missing` = implied but absent, `extra` = present but not implied).
#       A one-sided check would accept a stale sidecar from another subset.
#
#   (b) FRAME EXACTNESS — for every clip of the subset, the frame count of
#       the sidecar (`human_pos_w.shape[0]`) equals the frame count of the
#       robot npz (`joint_pos.shape[0]`).
#
#       THE BVH HEADER MUST NOT BE USED HERE.  The upstream BVH header
#       carries `Frame Time: 0.008333`, i.e. 1/120 truncated to six
#       decimals; deriving the expected frame count from it mis-derives 40
#       of the 490 clips by one frame and would produce a false red.  The
#       robot npz is the ONLY frame-count baseline.  (The BVH path exists in
#       repro/lib/seed_human.py for the unit test that proves the trap; the
#       verdict path here never calls it.)
#
#   (c) ROOT CONSISTENCY — the `root:` recorded in the subset yaml points at
#       the same directory as the local npz root.  The yaml stores the
#       persistent-store absolute path (`/home/ubuntu/work_dev/...`), the
#       worktree reaches the same payload through another mount prefix
#       (`/mnt/test_cc_dev/...`); the comparison is therefore done on the
#       device/inode pair, not on the path strings.
#
# `feet_off` is REPORTED, never judged: upstream `check_human` only counts
# the feet whose lowest z leaves [-0.05, 0.10] m and never fails on it.
# The value is read from `logs/env/check_human_1h.csv` (the evidence table
# of the conversion step).  A missing CSV leaves the field EMPTY and does
# NOT influence the exit code.
#
# ---------------------------------------------------------------------------
# MARKERS (grep -F friendly; a failing path NEVER emits an *_OK marker)
#   SEED_HUMAN_VERIFY_OK clips=<n> sidecars=<n> missing=0 extra=0 \
#                           frames_match=<n> feet_off=<n>
#   SEED_HUMAN_VERIFY_FAIL reason=<...>
#   SEED_REPORT_HUMAN_CLIPS=<n>
#   SEED_REPORT_HUMAN_SIDECARS=<n>
#   SEED_REPORT_HUMAN_MISSING=<n>
#   SEED_REPORT_HUMAN_EXTRA=<n>
#   SEED_REPORT_HUMAN_FRAMES_MATCH=<n>
#   SEED_REPORT_HUMAN_FEET_OFF=<n>
#   SEED_REPORT_HUMAN_OK=1
#
# The failure reasons form a FIXED set:
#   sidecar-count / sidecar-missing / sidecar-extra / frames-mismatch /
#   subset-root-mismatch / subset-missing / subset-unparsable
#
# READ-ONLY CONTRACT
#   Apart from its own log file (logs/env/16_seed_human_verify.txt) this
#   script writes NOTHING: it does not create the sidecar root, does not
#   touch the npz root and does not run any conversion.
#
# ENVIRONMENT OVERRIDES
#   SEED_HUMAN_ALLOW_LOCAL=1  allow running outside the ros_dev container
#                              (the offline fixture tests run locally)
#   SEED_HUMAN_LOG_DIR        log directory   (default: logs/env inside the
#                              container; a fresh temp dir outside it)
#   SEED_HUMAN_NPZ_ROOT       robot npz root  (default data/seed_g1_npz50)
#   SEED_HUMAN_SUBSET         subset yaml     (default <npz root>/subsets/1h.yaml)
#   SEED_HUMAN_HUMAN_ROOT     sidecar root    (default <npz root>/human50)
#   SEED_HUMAN_CHECK_CSV      upstream check table (default
#                              <log dir>/check_human_1h.csv)
#   SEED_HUMAN_EXPECT_CLIPS   expected clips  (default 490)
#   SEED_HUMAN_PROBE_TIMEOUT  per-probe timeout in seconds (default 900;
#                              0 disables the timeout)
#   SEED_HUMAN_PY             stdlib interpreter for repro/lib/seed_human.py
#                             (default python3 — numpy is NOT required)
#
# USAGE
#   bash repro/16_seed_human_verify.sh verify
#   bash repro/16_seed_human_verify.sh report

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

# common.sh turns on `set -e`.  Every failure path of this script is handled
# explicitly (each gate prints its own fail marker and returns 1), and an
# unchecked non-zero status of an intermediate probe must NOT abort the gate
# before the fail marker is printed.  Errexit is therefore disabled here.
set +e

if [ "${SEED_HUMAN_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
NPZ_ROOT="${SEED_HUMAN_NPZ_ROOT:-$REPO_ROOT/data/seed_g1_npz50}"
SUBSET_YAML="${SEED_HUMAN_SUBSET:-$NPZ_ROOT/subsets/1h.yaml}"
HUMAN_ROOT="${SEED_HUMAN_HUMAN_ROOT:-$NPZ_ROOT/human50}"
EXPECT_CLIPS="${SEED_HUMAN_EXPECT_CLIPS:-490}"
PY="${SEED_HUMAN_PY:-python3}"
# Every probe is bounded by a timeout: a stalled NFS read must not hang the
# check forever.  A timeout kills the probe, its non-zero exit code is
# mapped onto one of the fixed failure reasons (like any other probe error).
PROBE_TIMEOUT="${SEED_HUMAN_PROBE_TIMEOUT:-900}"
SEED_HUMAN_LIB_DIR="$REPO_ROOT/repro/lib"
SEED_HUMAN_PY_MODULE="$SEED_HUMAN_LIB_DIR/seed_human.py"

# The log directory: inside the container the shared store
# (logs/env/...), outside it a private temp dir — a local run must never
# overwrite the container's authoritative artefact.
if [ -n "${SEED_HUMAN_LOG_DIR:-}" ]; then
  LOG_DIR_REAL="$SEED_HUMAN_LOG_DIR"
elif in_container; then
  LOG_DIR_REAL="$LOG_DIR"
else
  LOG_DIR_REAL="$(mktemp -d "${TMPDIR:-/tmp}/seed_human_verify.XXXXXX")"
fi
MAIN_LOG="$LOG_DIR_REAL/16_seed_human_verify.txt"
CHECK_CSV="${SEED_HUMAN_CHECK_CSV:-$LOG_DIR_REAL/check_human_1h.csv}"

usage() {
  cat <<EOF
usage: bash repro/16_seed_human_verify.sh [verify|report]

  verify  re-derive the human50 facts from the files; SEED_HUMAN_VERIFY_OK
  report  print the SEED_REPORT_HUMAN_* numbers for the documentation

log:  $MAIN_LOG
EOF
}

# --- output ----------------------------------------------------------------
hlog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed only when EVERY check passed
# (the S03/S04/S05 convention).
OK_MARKERS=()
hlog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do hlog "$m"; done
  OK_MARKERS=()
}

fail() {
  local reason="$1"; shift || true
  hlog "SEED_HUMAN_VERIFY_FAIL reason=$reason"
  local kv
  for kv in "$@"; do
    [ -n "$kv" ] && hlog "  $kv"
  done
  return 1
}

# --- helpers ---------------------------------------------------------------
# run_probe <cmd...> — run a probe under a timeout when `timeout` is
# available; the exit code of the probe is propagated unchanged.
run_probe() {
  if command -v timeout >/dev/null 2>&1 && [ "${PROBE_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    timeout "$PROBE_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# field <key> <text> — the value of a `key=value` line.
field() {
  printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n1
}

# The root check re-uses the library function `same_root` (device/inode
# comparison), so the verdict path never re-implements the path logic.
ROOT_CHECK='
import os, sys
sys.path.insert(0, os.environ["SEED_HUMAN_LIB_DIR"])
import seed_human
yaml_root = sys.argv[1]
npz_root = sys.argv[2]
print("same_root=%d" % (1 if seed_human.same_root(yaml_root, npz_root) else 0))
'

# feet_off_from_csv <csv> — the number of clips whose feet_min_z leaves
# [-0.05, 0.10] m (the upstream threshold).  Prints nothing when the CSV is
# absent: the field is then left empty and the exit code is unaffected.
feet_off_from_csv() {
  local csv="$1"
  [ -f "$csv" ] || return 0
  run_probe "$PY" - "$csv" <<'PYEOF' 2>/dev/null || true
import csv, sys
count = 0
with open(sys.argv[1], newline="", encoding="utf-8", errors="replace") as handle:
  for row in csv.DictReader(handle):
    raw = (row.get("feet_min_z") or "").strip()
    if not raw:
      continue
    try:
      z = float(raw)
    except ValueError:
      continue
    if z < -0.05 or z > 0.10:
      count += 1
print(count)
PYEOF
}

# --- the statistics --------------------------------------------------------
# collect_stats fills the STAT_* globals and returns 0 when everything is
# consistent.  On a failure it returns 1 and sets STAT_REASON to one of the
# fixed reasons.
STAT_CLIPS=""
STAT_SIDECARS=""
STAT_MISSING=""
STAT_EXTRA=""
STAT_FRAMES_MATCH=""
STAT_MISMATCH=""
STAT_ERRORS=""
STAT_FEET_OFF=""
STAT_REASON=""
STAT_DETAIL=""

collect_stats() {
  STAT_CLIPS=""; STAT_SIDECARS=""; STAT_MISSING=""; STAT_EXTRA=""
  STAT_FRAMES_MATCH=""; STAT_MISMATCH=""; STAT_ERRORS=""
  STAT_FEET_OFF=""; STAT_REASON=""; STAT_DETAIL=""

  # (0) the subset yaml must exist and be parsable.
  if [ ! -f "$SUBSET_YAML" ]; then
    STAT_REASON="subset-missing"
    STAT_DETAIL="yaml=$SUBSET_YAML"
    return 1
  fi
  local subset_out subset_rc=0
  subset_out="$(run_probe "$PY" "$SEED_HUMAN_PY_MODULE" subset "$SUBSET_YAML" 2>&1)" || subset_rc=$?
  if [ "$subset_rc" -ne 0 ]; then
    STAT_REASON="subset-unparsable"
    STAT_DETAIL="yaml=$SUBSET_YAML"
    return 1
  fi
  local clips yaml_root
  clips="$(field clips "$subset_out")"
  yaml_root="$(field root "$subset_out")"
  if [ -z "$clips" ] || [ -z "$yaml_root" ]; then
    STAT_REASON="subset-unparsable"
    STAT_DETAIL="yaml=$SUBSET_YAML"
    return 1
  fi
  STAT_CLIPS="$clips"
  hlog "subset: root=$yaml_root hours=$(field hours "$subset_out") clips=$clips"

  # (c) the yaml root must be the very same directory as the local npz root.
  local root_out root_rc=0
  root_out="$(SEED_HUMAN_LIB_DIR="$SEED_HUMAN_LIB_DIR" run_probe "$PY" -c "$ROOT_CHECK" "$yaml_root" "$NPZ_ROOT" 2>&1)" || root_rc=$?
  local same_root
  same_root="$(field same_root "$root_out")"
  hlog "root: yaml_root=$yaml_root npz_root=$NPZ_ROOT same_root=${same_root:-0}"
  if [ "$root_rc" -ne 0 ] || [ "$same_root" != "1" ]; then
    STAT_REASON="subset-root-mismatch"
    STAT_DETAIL="yaml_root=$yaml_root npz_root=$NPZ_ROOT"
    return 1
  fi

  # (a) the sidecar set must match the subset EXACTLY (both directions).
  local diff_out diff_rc=0
  diff_out="$(run_probe "$PY" "$SEED_HUMAN_PY_MODULE" diff --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" --human-root "$HUMAN_ROOT" 2>&1)" || diff_rc=$?
  if [ "$diff_rc" -ne 0 ]; then
    STAT_REASON="subset-unparsable"
    STAT_DETAIL="diff failed"
    return 1
  fi
  local sidecars expected missing extra
  sidecars="$(field sidecars "$diff_out")"
  expected="$(field expected "$diff_out")"
  missing="$(field missing "$diff_out")"
  extra="$(field extra "$diff_out")"
  STAT_SIDECARS="${sidecars:-0}"
  STAT_MISSING="${missing:-0}"
  STAT_EXTRA="${extra:-0}"
  hlog "sidecars: on_disk=$sidecars expected=$expected missing=$missing extra=$extra"
  if [ "${missing:-0}" != "0" ]; then
    STAT_REASON="sidecar-missing"
    STAT_DETAIL="missing=$missing"
    printf '%s\n' "$diff_out" | grep '^missing_clip=' | head -n 5 | while IFS= read -r line; do hlog "  $line"; done
    return 1
  fi
  if [ "${extra:-0}" != "0" ]; then
    STAT_REASON="sidecar-extra"
    STAT_DETAIL="extra=$extra"
    printf '%s\n' "$diff_out" | grep '^extra_clip=' | head -n 5 | while IFS= read -r line; do hlog "  $line"; done
    return 1
  fi
  if [ "${sidecars:-0}" != "$clips" ] || [ "${sidecars:-0}" != "$EXPECT_CLIPS" ]; then
    STAT_REASON="sidecar-count"
    STAT_DETAIL="sidecars=$sidecars clips=$clips expected=$EXPECT_CLIPS"
    return 1
  fi

  # (b) the frame counts must match clip by clip (robot npz = baseline).
  local frames_out frames_rc=0
  frames_out="$(run_probe "$PY" "$SEED_HUMAN_PY_MODULE" frames --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" --human-root "$HUMAN_ROOT" 2>&1)" || frames_rc=$?
  if [ "$frames_rc" -ne 0 ]; then
    STAT_REASON="frames-mismatch"
    STAT_DETAIL="frames probe failed"
    return 1
  fi
  local frames_match mismatch errors
  frames_match="$(field frames_match "$frames_out")"
  mismatch="$(field mismatch "$frames_out")"
  errors="$(field errors "$frames_out")"
  STAT_FRAMES_MATCH="${frames_match:-0}"
  STAT_MISMATCH="${mismatch:-0}"
  STAT_ERRORS="${errors:-0}"
  hlog "frames: frames_match=$frames_match mismatch=$mismatch errors=$errors"
  if [ "${mismatch:-0}" != "0" ] || [ "${errors:-0}" != "0" ] || [ "${frames_match:-0}" != "$clips" ]; then
    STAT_REASON="frames-mismatch"
    STAT_DETAIL="frames_match=$frames_match mismatch=$mismatch errors=$errors clips=$clips"
    printf '%s\n' "$frames_out" | grep -E '^(mismatch_clip|error_clip)=' | head -n 5 | while IFS= read -r line; do hlog "  $line"; done
    return 1
  fi

  # feet_off is REPORTED ONLY (upstream never fails on the feet z).
  STAT_FEET_OFF="$(feet_off_from_csv "$CHECK_CSV" | head -n1)"
  return 0
}

# --- verify ----------------------------------------------------------------
cmd_verify() {
  hlog "=== 16_seed_human_verify.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  hlog "config: npz_root=$NPZ_ROOT human_root=$HUMAN_ROOT yaml=$SUBSET_YAML check_csv=$CHECK_CSV"

  if ! collect_stats; then
    fail "$STAT_REASON" "$STAT_DETAIL"
    return 1
  fi

  hlog_ok "SEED_HUMAN_VERIFY_OK clips=$STAT_CLIPS sidecars=$STAT_SIDECARS missing=$STAT_MISSING extra=$STAT_EXTRA frames_match=$STAT_FRAMES_MATCH feet_off=$STAT_FEET_OFF"
  flush_ok_markers
  return 0
}

# --- report ----------------------------------------------------------------
cmd_report() {
  hlog "=== 16_seed_human_verify.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  collect_stats || true

  local ok=1
  if [ -n "$STAT_REASON" ]; then
    ok=0
  fi

  hlog "SEED_REPORT_HUMAN_CLIPS=${STAT_CLIPS:-0}"
  hlog "SEED_REPORT_HUMAN_SIDECARS=${STAT_SIDECARS:-0}"
  hlog "SEED_REPORT_HUMAN_MISSING=${STAT_MISSING:-0}"
  hlog "SEED_REPORT_HUMAN_EXTRA=${STAT_EXTRA:-0}"
  hlog "SEED_REPORT_HUMAN_FRAMES_MATCH=${STAT_FRAMES_MATCH:-0}"
  hlog "SEED_REPORT_HUMAN_FEET_OFF=${STAT_FEET_OFF}"
  hlog "SEED_REPORT_HUMAN_OK=$ok"
  if [ "$ok" != "1" ]; then
    hlog "SEED_HUMAN_VERIFY_FAIL reason=$STAT_REASON $STAT_DETAIL"
    return 1
  fi
  return 0
}

case "${1:-verify}" in
  verify) shift || true; cmd_verify "$@" ;;
  report) shift || true; cmd_report "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
