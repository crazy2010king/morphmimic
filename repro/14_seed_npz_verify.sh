#!/usr/bin/env bash
# repro/14_seed_npz_verify.sh — READ-ONLY terminal reviewer of the G1 50 Hz
# npz conversion (slice S04).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS (and why it is split into verify / audit / report)
#
# The conversion itself is proven by repro/13_seed_convert.sh + its detached
# worker.  This script is the INDEPENDENT, read-only re-check that can be
# run at any time (a day later, from another machine, after a worktree
# rebuild) and that answers one question: "is the npz library on disk really
# the one the slice contract promised?".
#
#   verify  the fast gate.  Seconds.  Uses the manifest as the PRIMARY
#           evidence (one row per clip, 142,220 rows) and a deterministic
#           sample of the npz files as the SECONDARY evidence.  This is the
#           command that goes into the host verification gate.
#   audit   the slow, exhaustive count of the npz files on disk
#           (`find ... -name '*.npz' | wc -l` + the total byte count).  On the
#           NFS export this takes 1-3 minutes for 142,220 files, so it MUST
#           NOT be part of the fast gate (MEM052 lesson: a 68.7 GB sha256
#           re-check took 518 s and blew the 120 s host gate).
#   report  prints the verify/audit numbers as SEED_REPORT_NPZ_* lines, the
#           form that is pasted into docs/code_read/NPZ_CONVERSION.md.
#
# The script NEVER writes into the npz tree.  The only file it writes is its
# own log (logs/env/14_seed_npz_verify.txt).
#
# NOTE (S05): `human50/` under the npz root is the human50 SIDECAR root (the
# SMPL human50 sidecars produced by slice S05 with repro/15_seed_human.sh),
# NOT part of the robot npz library.  The audit counts ROBOT npz files only,
# so the sidecar root is pruned before counting; otherwise the "npz file
# count == manifest rows == 142,220" evidence of slice S04 would be inflated
# by the 490 sidecars (142,710).
#
# MARKERS (grep -F friendly)
#   SEED_NPZ_VERIFY_OK rows=142220 errors=<n> rate=<r> kept=<n> subsets=5 sampled=200
#   SEED_NPZ_VERIFY_FAIL reason=<...>
#   SEED_NPZ_FILES count=<n> bytes=<n>
#   SEED_REPORT_NPZ_* <key>=<value>
#
# The OK marker is BUFFERED and only flushed when EVERY check passed, so a
# failing run can never emit a single OK marker (the S03/MEM038 convention).
# The negative fixtures in repro/tests/test_seed_npz_verify.sh assert exactly
# that: a non-zero exit code AND no OK marker in the output.
#
# ENVIRONMENT OVERRIDES
#   SEED_NPZ_ALLOW_LOCAL=1   allow running outside the ros_dev container
#                             (the offline fixtures run locally)
#   SEED_NPZ_OUT_DIR         npz root      (default data/seed_g1_npz50)
#   SEED_NPZ_HUMAN_ROOT      human50 sidecar root, PRUNED from the audit
#                             count (default <npz root>/human50)
#   SEED_EXPECTED_ROWS       expected manifest rows (default 142220)
#   SEED_NPZ_SAMPLE          sample size   (default 200)
#   SEED_NPZ_LOG_DIR         log directory (default $LOG_DIR)
#   SEED_NPZ_PY              stdlib python used for parsing (default python3)
#   SEED_NPZ_NPZ_PY          python used to READ the npz files; must have
#                            numpy.  Default: try "uv run --frozen --no-sync
#                            python" (the project venv) and then "python3".
#
# USAGE
#   bash repro/14_seed_npz_verify.sh verify
#   bash repro/14_seed_npz_verify.sh audit
#   bash repro/14_seed_npz_verify.sh report

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/seed_npz.sh
source "$_SCRIPT_DIR/lib/seed_npz.sh"

if [ "${SEED_NPZ_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

LOG_DIR_REAL="${SEED_NPZ_LOG_DIR:-$LOG_DIR}"
OUT_DIR="${SEED_NPZ_OUT_DIR:-$REPO_ROOT/data/seed_g1_npz50}"
MANIFEST="$OUT_DIR/manifest.csv"
SUBSET_DIR="$OUT_DIR/subsets"
MAIN_LOG="$LOG_DIR_REAL/14_seed_npz_verify.txt"
PY="${SEED_NPZ_PY:-python3}"
SEED_NPZ_PY_MODULE="$REPO_ROOT/repro/lib/seed_npz.py"

EXPECTED_ROWS="$(seed_npz_expected_rows)"
SAMPLE_N="${SEED_NPZ_SAMPLE:-200}"
REQUIRED_SUBSETS="tiny 1h all"
SUBSET_CHAIN="tiny 1h 7h 40h all"

# --- output -----------------------------------------------------------------
# vlog writes to stdout AND appends to the log file, so every marker is
# greppable in logs/env/14_seed_npz_verify.txt.
vlog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed only when every check passed.
OK_MARKERS=()
vlog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do vlog "$m"; done
  OK_MARKERS=()
}

# fail_verify <reason> [key=value ...]
# The ONLY failure exit of a check: it prints the fail marker and returns 1.
# It never prints an OK marker.
fail_verify() {
  local reason="$1"; shift || true
  vlog "SEED_NPZ_VERIFY_FAIL reason=$reason"
  local kv
  for kv in "$@"; do
    [ -n "$kv" ] && vlog "  $kv"
  done
  return 1
}

usage() {
  cat <<EOF
usage: bash repro/14_seed_npz_verify.sh [verify|audit|report]

  verify  fast, read-only terminal check (seconds); the OK marker is
          SEED_NPZ_VERIFY_OK
  audit   slow exhaustive npz file/byte count; the marker is SEED_NPZ_FILES
  report  prints the verify numbers as SEED_REPORT_NPZ_* lines

log: $MAIN_LOG
EOF
}

# --- helpers ----------------------------------------------------------------

# realpath_of <path> — canonical absolute path (symlinks resolved), stdlib only.
realpath_of() {
  "$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

# npz_python_candidates — the commands that may READ the npz files.
# The container's system python3 has no numpy, so the project venv comes
# first; a plain python3 with numpy (the offline fixtures) is the fallback.
npz_python_candidates() {
  if [ -n "${SEED_NPZ_NPZ_PY:-}" ]; then
    printf '%s\n' "$SEED_NPZ_NPZ_PY"
    return 0
  fi
  if command -v uv >/dev/null 2>&1 && [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    printf '%s\n' "uv run --frozen --no-sync python"
  fi
  printf '%s\n' "python3"
}

# probe_npz_fps <root> <rel-path>...
# Reads every sampled npz with numpy and asserts fps == 50.
# Returns 0 when every file was readable and had fps == 50, 1 otherwise.
probe_npz_fps() {
  local root="$1"; shift
  local -a paths=("$@")
  local cand
  local out rc=0
  local -a parts
  local last_out=""
  local any=0
  # Every candidate is tried: a candidate that cannot even start (no numpy, a
  # broken venv) must not mask a candidate that can read the data, and a data
  # problem makes EVERY candidate fail anyway.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    read -r -a parts <<<"$cand"
    [ "${#parts[@]}" -gt 0 ] || continue
    rc=0
    out="$(cd "$REPO_ROOT" && "${parts[@]}" - "$root" "${paths[@]}" <<'PYEOF' 2>&1)" || rc=$?
    vlog "npz probe [$cand] rc=$rc"
    printf '%s\n' "$out"
    last_out="$out"
    if [ "$rc" -eq 0 ]; then
      any=1
      break
    fi
  done < <(npz_python_candidates)
  if [ "$any" -eq 1 ]; then
    return 0
  fi
  vlog "no python with numpy could read the sampled npz files"
  [ -n "$last_out" ] || true
  return 1
}

# --- the checks -------------------------------------------------------------
# Rows/values collected by check_library; used by both verify and report.
ROWS=""; ERRORS=""; RATE=""; KEPT=""; TOTAL_HOURS=""
ALL_CLIPS=""; ONEH_CLIPS=""; ONEH_HOURS=""; SUBSETS_FOUND=""; SAMPLED_OK=""

# check_library performs every read-only check of the terminal state.
# On success it returns 0 and fills the globals above.
check_library() {
  local stats rows errors rate ok kept
  local root npz_root

  # (a) the manifest must exist and be parsable
  if [ ! -f "$MANIFEST" ]; then
    fail_verify "manifest-missing" "PATH=$MANIFEST"
    return 1
  fi
  stats="$("$PY" "$SEED_NPZ_PY_MODULE" stats "$MANIFEST" 2>&1)" || {
    vlog "manifest stats failed:"
    printf '%s\n' "$stats" | while IFS= read -r l; do vlog "  $l"; done
    fail_verify "manifest-unparsable" "PATH=$MANIFEST"
    return 1
  }
  while IFS= read -r l; do vlog "manifest: $l"; done <<<"$stats"
  rows="$(printf '%s\n' "$stats" | sed -n 's/^rows=//p' | head -n1)"
  errors="$(printf '%s\n' "$stats" | sed -n 's/^errors=//p' | head -n1)"
  rate="$(printf '%s\n' "$stats" | sed -n 's/^error_rate=//p' | head -n1)"
  ok="$(printf '%s\n' "$stats" | sed -n 's/^error_rate_ok=//p' | head -n1)"
  kept="$(printf '%s\n' "$stats" | sed -n 's/^kept=//p' | head -n1)"
  ROWS="$rows"; ERRORS="$errors"; RATE="$rate"; KEPT="$kept"

  # (a) the row count: one row per converted clip (S03's SEED_EXTRACT_FILES
  #     evidence says the G1 CSV set holds 142,220 clips).  The npz files
  #     themselves are counted by the `audit` subcommand (too slow for the
  #     fast gate).
  if [ "$rows" != "$EXPECTED_ROWS" ]; then
    fail_verify "row-count" "ROWS=$rows" "EXPECTED=$EXPECTED_ROWS"
    return 1
  fi

  # (b) the error rate: a broken environment produced a manifest with 142,220
  #     rows and a 100% error rate — a "successful" run that converted
  #     nothing.  The limit is inclusive (exactly 1% passes).
  if [ "$ok" != "1" ]; then
    fail_verify "error-rate" "ERRORS=$errors" "RATE=$rate" "LIMIT=0.01"
    return 1
  fi

  # (d) the subset yamls: the three REQUIRED ones (tiny / 1h / all) and the
  #     full chain of five (the chain is what S05/S06/S08 consume).
  local name missing=""
  SUBSETS_FOUND=0
  for name in $SUBSET_CHAIN; do
    if [ ! -s "$SUBSET_DIR/$name.yaml" ]; then
      missing="$missing $name"
    else
      SUBSETS_FOUND=$((SUBSETS_FOUND + 1))
    fi
  done
  if [ -n "$missing" ]; then
    fail_verify "subsets-missing" "MISSING=$missing" "DIR=$SUBSET_DIR"
    return 1
  fi
  for name in $REQUIRED_SUBSETS; do
    if [ ! -s "$SUBSET_DIR/$name.yaml" ]; then
      fail_verify "subset-missing" "NAME=$name" "PATH=$SUBSET_DIR/$name.yaml"
      return 1
    fi
  done

  # (d) the chain must be nested: tiny ⊆ 1h ⊆ 7h ⊆ 40h ⊆ all
  local -a nested_args=()
  for name in $SUBSET_CHAIN; do
    nested_args+=("$name=$SUBSET_DIR/$name.yaml")
  done
  if ! "$PY" "$SEED_NPZ_PY_MODULE" nested "${nested_args[@]}" >/dev/null 2>&1; then
    fail_verify "subset-not-nested" "CHAIN=$SUBSET_CHAIN"
    return 1
  fi

  # (c) the kept clips must be exactly the clips of subsets/all.yaml
  #     (upstream `filtered()`: name_reject == "" AND feas_reject == "")
  local all_spec oneh_spec
  all_spec="$("$PY" "$SEED_NPZ_PY_MODULE" subset-spec "$SUBSET_DIR/all.yaml" 2>&1)" || {
    fail_verify "subset-unparsable" "NAME=all" "PATH=$SUBSET_DIR/all.yaml"
    return 1
  }
  oneh_spec="$("$PY" "$SEED_NPZ_PY_MODULE" subset-spec "$SUBSET_DIR/1h.yaml" 2>&1)" || {
    fail_verify "subset-unparsable" "NAME=1h" "PATH=$SUBSET_DIR/1h.yaml"
    return 1
  }
  ALL_CLIPS="$(printf '%s\n' "$all_spec" | sed -n 's/^clips=//p' | head -n1)"
  ONEH_CLIPS="$(printf '%s\n' "$oneh_spec" | sed -n 's/^clips=//p' | head -n1)"
  ONEH_HOURS="$(printf '%s\n' "$oneh_spec" | sed -n 's/^hours=//p' | head -n1)"
  if [ "$ALL_CLIPS" != "$kept" ]; then
    fail_verify "kept-mismatch" "KEPT=$kept" "ALL_CLIPS=$ALL_CLIPS"
    return 1
  fi

  # (d) the npz root: the subset yaml stores the ABSOLUTE npz root; it must
  #     be the directory that holds the manifest.
  root="$(printf '%s\n' "$oneh_spec" | sed -n 's/^root=//p' | head -n1)"
  npz_root="$(realpath_of "$OUT_DIR" || true)"
  local root_real
  root_real="$(realpath_of "$root" || true)"
  if [ -z "$root_real" ] || [ "$root_real" != "$npz_root" ]; then
    fail_verify "subset-root-mismatch" "YAML_ROOT=$root" "RESOLVED=$root_real" "NPZ_ROOT=$npz_root"
    return 1
  fi

  # (e) the sample: n evenly spaced manifest paths, each npz must exist,
  #     be non-empty and carry fps == 50.
  local -a sampled=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && sampled+=("$p")
  done < <(seed_npz_sample_paths "$MANIFEST" "$SAMPLE_N")
  if [ "${#sampled[@]}" -eq 0 ]; then
    fail_verify "sample-empty" "MANIFEST=$MANIFEST"
    return 1
  fi
  for p in "${sampled[@]}"; do
    if [ ! -f "$npz_root/$p" ]; then
      fail_verify "sample-missing" "PATH=$p"
      return 1
    fi
    if [ ! -s "$npz_root/$p" ]; then
      fail_verify "sample-empty-file" "PATH=$p"
      return 1
    fi
  done
  if ! probe_npz_fps "$npz_root" "${sampled[@]}"; then
    fail_verify "sample-fps" "SAMPLED=${#sampled[@]}"
    return 1
  fi
  SAMPLED_OK="${#sampled[@]}"

  vlog "checks passed: rows=$ROWS errors=$ERRORS rate=$RATE kept=$KEPT subsets=$SUBSETS_FOUND sampled=$SAMPLED_OK"
  return 0
}

# --- verify -----------------------------------------------------------------
cmd_verify() {
  vlog "=== 14_seed_npz_verify.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
  if ! check_library; then
    return 1
  fi
  vlog_ok "SEED_NPZ_VERIFY_OK rows=$ROWS errors=$ERRORS rate=$RATE kept=$KEPT subsets=$SUBSETS_FOUND sampled=$SAMPLED_OK"
  flush_ok_markers
  return 0
}

# --- audit ------------------------------------------------------------------
# The exhaustive count.  Slow on NFS (1-3 min), so it is NOT part of the fast
# verification gate.
cmd_audit() {
  vlog "=== 14_seed_npz_verify.sh audit $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
  if [ ! -d "$OUT_DIR" ]; then
    fail_verify "out-dir-missing" "DIR=$OUT_DIR"
    return 1
  fi
  local count bytes
  # Prune the S05 human50 sidecar root: it holds .npz files too, but they are
  # NOT robot npz clips, so they must not be counted here.
  # The -path match is a plain string match against the paths find prints, so
  # the root is normalized (no trailing slash) to make it exact.
  local audit_root human_root
  audit_root="$OUT_DIR"
  while [ "${audit_root%/}" != "$audit_root" ]; do audit_root="${audit_root%/}"; done
  human_root="${SEED_NPZ_HUMAN_ROOT:-$audit_root/human50}"
  while [ "${human_root%/}" != "$human_root" ]; do human_root="${human_root%/}"; done
  count="$(find "$audit_root" -path "$human_root" -prune -o -type f -name '*.npz' -print | wc -l | tr -d ' ')"
  # "%.0f" and not "%d": the total is ~1.5e11 bytes for the full library and
  # awk's %d conversion saturates at INT_MAX (2147483647), which silently
  # reported the byte total as a bogus 2 GiB.
  bytes="$(find "$audit_root" -path "$human_root" -prune -o -type f -name '*.npz' -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s+0}')"
  vlog_ok "SEED_NPZ_FILES count=$count bytes=$bytes"
  flush_ok_markers
  return 0
}

# --- report -----------------------------------------------------------------
# The numbers in the form that is pasted into the documentation.
cmd_report() {
  vlog "=== 14_seed_npz_verify.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
  if ! check_library; then
    return 1
  fi
  printf 'SEED_REPORT_NPZ_ROWS=%s\n' "$ROWS"
  printf 'SEED_REPORT_NPZ_ERRORS=%s\n' "$ERRORS"
  printf 'SEED_REPORT_NPZ_ERROR_RATE=%s\n' "$RATE"
  printf 'SEED_REPORT_NPZ_KEPT=%s\n' "$KEPT"
  printf 'SEED_REPORT_NPZ_SUBSETS=%s\n' "$SUBSETS_FOUND"
  printf 'SEED_REPORT_NPZ_SAMPLED=%s\n' "$SAMPLED_OK"
  printf 'SEED_REPORT_NPZ_ALL_CLIPS=%s\n' "$ALL_CLIPS"
  printf 'SEED_REPORT_NPZ_1H_CLIPS=%s\n' "$ONEH_CLIPS"
  printf 'SEED_REPORT_NPZ_1H_HOURS=%s\n' "$ONEH_HOURS"
  printf 'SEED_REPORT_NPZ_OK=1\n'
  local line
  while IFS= read -r line; do vlog "$line"; done <<EOF
SEED_REPORT_NPZ_ROWS=$ROWS
SEED_REPORT_NPZ_ERRORS=$ERRORS
SEED_REPORT_NPZ_ERROR_RATE=$RATE
SEED_REPORT_NPZ_KEPT=$KEPT
SEED_REPORT_NPZ_SUBSETS=$SUBSETS_FOUND
SEED_REPORT_NPZ_SAMPLED=$SAMPLED_OK
SEED_REPORT_NPZ_ALL_CLIPS=$ALL_CLIPS
SEED_REPORT_NPZ_1H_CLIPS=$ONEH_CLIPS
SEED_REPORT_NPZ_1H_HOURS=$ONEH_HOURS
SEED_REPORT_NPZ_OK=1
EOF
  return 0
}

case "${1:-verify}" in
  verify) shift || true; cmd_verify "$@" ;;
  audit)  shift || true; cmd_audit "$@" ;;
  report) shift || true; cmd_report "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
