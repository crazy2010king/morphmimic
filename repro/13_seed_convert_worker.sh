#!/usr/bin/env bash
# repro/13_seed_convert_worker.sh — the DETACHED conversion body of S04.
#
# Why a separate worker: the conversion of 142,220 clips takes tens of minutes
# (CPU side) and writes ~150-160 GB over NFS.  A foreground conversion inside
# one ssh call dies with the session, and the upstream converter only writes
# `manifest.csv` AFTER every clip is done — a crash in the middle leaves no
# manifest at all.  So the conversion runs detached (setsid + nohup, started by
# repro/13_seed_convert.sh) and the caller only ever runs short, read-only
# commands against the status file.
#
# The worker is IDEMPOTENT by construction: the upstream converter reuses an
# existing npz instead of reconverting it (no --overwrite), so a restart after
# a crash only redoes what is missing.
#
# Order:
#   1. the environment gate (repro/13_seed_convert.sh env) — a broken torch
#      would turn all 142,220 clips into `feas_reject="error: ..."` while the
#      manifest still looks "successful"
#   2. the space gate (>= SEED_MIN_FREE_GB GiB free on the target filesystem)
#   3. the upstream conversion (morphmimic.scripts.convert_seed)
#   4. the upstream subset build (morphmimic.scripts.build_subsets)
#   5. the terminal markers + the status file
#
# MARKERS (a failing path NEVER emits an *_OK marker):
#   SEED_NPZ_START clips=<n> workers=<n>
#   SEED_NPZ_PROGRESS done=<n> rate=<n/s>
#   SEED_NPZ_CONVERT_OK clips=<n> rows=<n> errors=<n> error_rate=<r> elapsed_s=<n>
#   SEED_SUBSET_OK name=<subset> clips=<n> hours=<h>
#   SEED_SUBSET_NESTED ok
#   SEED_NPZ_FAIL reason=<...>

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/seed_npz.sh
source "$_SCRIPT_DIR/lib/seed_npz.sh"

LOG_DIR_REAL="${SEED_NPZ_LOG_DIR:-$LOG_DIR}"
OUT_DIR="${SEED_NPZ_OUT_DIR:-$REPO_ROOT/data/seed_g1_npz50}"
CSV_DIR="${SEED_NPZ_CSV_DIR:-$REPO_ROOT/data/seed/g1/csv}"
METADATA="${SEED_NPZ_METADATA:-$REPO_ROOT/data/seed/metadata/seed_metadata_v004.csv}"
WORKERS="${SEED_NPZ_WORKERS:-28}"
# Empty by default: the production run converts EVERY clip.  A non-empty value
# adds `--limit <n>` and exists only for the offline rehearsal of this worker
# (a small clip count into a scratch out dir), never for the real run.
CONVERT_LIMIT="${SEED_NPZ_CONVERT_LIMIT:-}"
MAIN_LOG="$LOG_DIR_REAL/13_seed_convert.txt"
STATUS_FILE="$LOG_DIR_REAL/13_seed_convert.status"
WORKER_LOG="$LOG_DIR_REAL/13_seed_convert_worker.log"
CONVERT_OUT="$LOG_DIR_REAL/13_seed_convert_convert.out"
CONVERT_ERR="$LOG_DIR_REAL/13_seed_convert_convert.err"
ORCHESTRATOR="$REPO_ROOT/repro/13_seed_convert.sh"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export SEED_STARTED_AT="$STARTED_AT"
T_START="$(date +%s)"

# wlog writes to stdout (the detached runner redirects it into the worker log)
# AND appends to the main log, so every marker is greppable in both.
wlog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# OK_MARKERS are buffered and only flushed when EVERY step passed.
OK_MARKERS=()
wlog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do wlog "$m"; done
  OK_MARKERS=()
}

# status_write <state> <rc> [key=value ...] — atomic status file write.
status_write() {
  local state="$1" rc="$2"; shift 2 || true
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
  local extra=()
  local kv
  for kv in "$@"; do
    [ -n "$kv" ] && extra+=("$kv")
  done
  seed_npz_write_status "$STATUS_FILE" "$state" "$rc" "${extra[@]+"${extra[@]}"}"
}

fail() {
  # fail <reason> [key=value ...] — the only failure exit of this worker.
  local reason="$1"; shift || true
  wlog "SEED_NPZ_FAIL reason=$reason"
  status_write FAILED 1 "PID=$$" "REASON=$reason" "$@"
  exit 1
}

# --- helpers ----------------------------------------------------------------

# The tqdm progress parser lives in the shared shell library
# (repro/lib/seed_npz.sh: seed_npz_parse_progress), so it can be unit-tested
# offline without a conversion run.

# --- step 1: environment gate ----------------------------------------------
wlog "=== 13_seed_convert_worker.sh start $STARTED_AT ==="
status_write RUNNING 0 "PID=$$" "PHASE=env"

if [ ! -f "$ORCHESTRATOR" ]; then
  fail "orchestrator-missing" "PATH=$ORCHESTRATOR"
fi
if ! bash "$ORCHESTRATOR" env; then
  fail "env-gate-failed" "PHASE=env"
fi
wlog "env gate passed"

# --- step 2: space gate -----------------------------------------------------
mkdir -p "$OUT_DIR"
if ! seed_npz_space_gate "$OUT_DIR"; then
  fail "space-gate-failed" "PHASE=space" "DIR=$OUT_DIR"
fi

# --- step 3: the upstream conversion ----------------------------------------
EXPECTED_CLIPS="$(seed_npz_expected_rows)"
wlog "SEED_NPZ_START clips=$EXPECTED_CLIPS workers=$WORKERS"
status_write RUNNING 0 "PID=$$" "PHASE=convert" "CLIPS=$EXPECTED_CLIPS" "WORKERS=$WORKERS"

rm -f "$CONVERT_OUT" "$CONVERT_ERR"
LIMIT_ARGS=()
if [ -n "$CONVERT_LIMIT" ]; then
  LIMIT_ARGS=(--limit "$CONVERT_LIMIT")
  wlog "worker rehearsal: --limit $CONVERT_LIMIT (out dir $OUT_DIR)"
fi
( cd "$REPO_ROOT" && uv run --frozen --no-sync python -m morphmimic.scripts.convert_seed \
    --csv-dir "$CSV_DIR" \
    --metadata "$METADATA" \
    --out-dir "$OUT_DIR" \
    --workers "$WORKERS" "${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"}" ) >"$CONVERT_OUT" 2>"$CONVERT_ERR" &
CONVERT_PID=$!

LAST_DONE=0
while kill -0 "$CONVERT_PID" 2>/dev/null; do
  sleep 10
  line="$(seed_npz_parse_progress "$CONVERT_ERR")"
  done_n="${line%% *}"
  rest="${line#* }"
  total="${rest%% *}"
  rate="${rest#* }"
  case "$done_n" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$done_n" -ge $((LAST_DONE + 200)) ]; then
    LAST_DONE="$done_n"
    wlog "SEED_NPZ_PROGRESS done=$done_n rate=$rate"
    status_write RUNNING 0 "PID=$$" "PHASE=convert" "DONE=$done_n" "TOTAL=${total:-0}"
  fi
done
wait "$CONVERT_PID"
CONVERT_RC=$?
if [ "$CONVERT_RC" -ne 0 ]; then
  wlog "--- upstream conversion output (tail) ---"
  tail -n 40 "$CONVERT_OUT" 2>/dev/null | while IFS= read -r l; do wlog "$l"; done
  tail -n 20 "$CONVERT_ERR" 2>/dev/null | while IFS= read -r l; do wlog "$l"; done
  fail "convert-failed" "PHASE=convert" "RC=$CONVERT_RC"
fi
ELAPSED=$(( $(date +%s) - T_START ))
wlog "upstream conversion finished in ${ELAPSED}s"

# --- the manifest gate ------------------------------------------------------
MANIFEST="$OUT_DIR/manifest.csv"
if [ ! -f "$MANIFEST" ]; then
  fail "manifest-missing" "PHASE=manifest" "PATH=$MANIFEST"
fi
STATS="$(python3 "$REPO_ROOT/repro/lib/seed_npz.py" stats "$MANIFEST" 2>&1)"
if [ -z "$STATS" ]; then
  fail "manifest-unparsable" "PHASE=manifest" "PATH=$MANIFEST"
fi
while IFS= read -r l; do wlog "manifest: $l"; done <<<"$STATS"
ROWS="$(printf '%s\n' "$STATS" | sed -n 's/^rows=//p' | head -n1)"
KEPT="$(printf '%s\n' "$STATS" | sed -n 's/^kept=//p' | head -n1)"
ERRORS="$(printf '%s\n' "$STATS" | sed -n 's/^errors=//p' | head -n1)"
ERROR_RATE="$(printf '%s\n' "$STATS" | sed -n 's/^error_rate=//p' | head -n1)"
ERROR_RATE_OK="$(printf '%s\n' "$STATS" | sed -n 's/^error_rate_ok=//p' | head -n1)"

if [ "$ROWS" != "$EXPECTED_CLIPS" ]; then
  fail "row-count-mismatch" "PHASE=manifest" "ROWS=$ROWS" "EXPECTED=$EXPECTED_CLIPS"
fi
if [ "$ERROR_RATE_OK" != "1" ]; then
  fail "error-rate-exceeded" "PHASE=manifest" "ERRORS=$ERRORS" "ERROR_RATE=$ERROR_RATE"
fi

# --- step 4: the upstream subset build --------------------------------------
wlog "building subsets ..."
SUBSET_OUT="$OUT_DIR/subsets"
rm -rf "$SUBSET_OUT"
mkdir -p "$SUBSET_OUT"
if ! ( cd "$REPO_ROOT" && uv run --frozen --no-sync python -m morphmimic.scripts.build_subsets \
        --manifest "$MANIFEST" \
        --out-dir "$SUBSET_OUT" \
        --seed 0 ) >"$LOG_DIR_REAL/13_seed_convert_subsets.out" 2>&1; then
  tail -n 30 "$LOG_DIR_REAL/13_seed_convert_subsets.out" 2>/dev/null | while IFS= read -r l; do wlog "$l"; done
  fail "subset-build-failed" "PHASE=subsets"
fi

NESTED_ARGS=()
while IFS= read -r name; do
  yaml_path="$SUBSET_OUT/$name.yaml"
  if [ ! -s "$yaml_path" ]; then
    fail "subset-missing" "PHASE=subsets" "NAME=$name" "PATH=$yaml_path"
  fi
  spec="$(python3 "$REPO_ROOT/repro/lib/seed_npz.py" subset-spec "$yaml_path" 2>&1)" || {
    fail "subset-unparsable" "PHASE=subsets" "NAME=$name" "PATH=$yaml_path"
  }
  clips="$(printf '%s\n' "$spec" | sed -n 's/^clips=//p' | head -n1)"
  hours="$(printf '%s\n' "$spec" | sed -n 's/^hours=//p' | head -n1)"
  wlog_ok "SEED_SUBSET_OK name=$name clips=$clips hours=$hours"
  NESTED_ARGS+=("$name=$yaml_path")
done <<<"$(seed_npz_subset_names)"

# the chain must be nested: tiny ⊂ 1h ⊂ 7h ⊂ 40h ⊂ all
if ! python3 "$REPO_ROOT/repro/lib/seed_npz.py" nested "${NESTED_ARGS[@]}" >/dev/null; then
  fail "subset-not-nested" "PHASE=subsets"
fi
wlog_ok "SEED_SUBSET_NESTED ok"

# --- terminal markers + status ----------------------------------------------
wlog_ok "SEED_NPZ_CONVERT_OK clips=$ROWS rows=$ROWS kept=$KEPT errors=$ERRORS error_rate=$ERROR_RATE elapsed_s=$ELAPSED"
flush_ok_markers
status_write DONE 0 "PID=$$" "PHASE=" "CLIPS=$ROWS" "ROWS=$ROWS" "ERRORS=$ERRORS" \
  "RATE=$ERROR_RATE" "ELAPSED=$ELAPSED"
wlog "=== 13_seed_convert_worker.sh DONE $STARTED_AT ==="
exit 0
