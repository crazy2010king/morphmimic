#!/usr/bin/env bash
# repro/15_seed_human.sh — the orchestrator of the human50 sidecar generation
# (slice S05).
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT DOES
#
# It turns the 490 clips of `data/seed_g1_npz50/subsets/1h.yaml` into 24-joint
# SMPL human50 sidecars and then asks upstream to check them:
#
#   env      a seconds-long, fail-closed gate that proves the container can
#            really run the conversion (venv importable, subset parsable with
#            the expected clip count, BVH root populated, sidecar root
#            writable).
#   convert  the real conversion (upstream `convert_human`) followed by the
#            upstream consistency check (`check_human`).
#   status   prints the status file and the key markers; ALWAYS exit 0.
#
# ---------------------------------------------------------------------------
# WHY THE WRAPPER IS FAIL-CLOSED (the two upstream traps)
#
# 1. UPSTREAM `convert_human` EXITS 0 EVEN WHEN CLIPS FAILED.
#    A per-clip failure is caught inside the pool worker and reported as
#    `[FAILED] <clip>: error: ...`; the summary line is
#    `converted N, skipped M, failed K` and the PROCESS EXIT CODE IS STILL 0.
#    Calling upstream directly would therefore produce a "successful" run
#    that converted nothing but a few clips.  This script therefore parses
#    that summary line and ASSERTS `failed == 0` and
#    `converted + skipped == 490` before it prints any OK marker.
#
# 2. UPSTREAM `convert_human` WITHOUT `--subset-yaml` GLOBS THE NPZ ROOT.
#    `Path(npz_root).glob("*/*.npz")` walks the npz root; once the sidecar
#    root `human50/` exists inside it, the sidecars can be picked up as
#    "robot clips" to convert (self-feeding, producing a pile of `[FAILED]`).
#    `--subset-yaml` is therefore MANDATORY here, and the source of this
#    file contains that argument on purpose.
#
# 3. UPSTREAM `check_human` NEVER FAILS ON FOOT Z.
#    The feet's lowest z outside [-0.05, 0.10] m is only COUNTED and printed;
#    the exit code is 1 only for a missing sidecar or a frame mismatch.  The
#    feet count is therefore recorded as its own number (`FEET_OFF`) and is
#    reported, never silently turned into a pass/fail verdict.  The
#    independent re-checker of slice S05 (repro/16_seed_human_verify.sh)
#    re-derives everything else from the files themselves.
#
# MARKERS (grep -F friendly; a failing path NEVER emits an *_OK marker)
#   SEED_HUMAN_ENV_OK clips=490 workers=28 python=<v> numpy=<v> scipy=<v>
#   SEED_HUMAN_ENV_FAIL reason=<...>
#   SEED_HUMAN_CONVERT_OK clips=<n> converted=<n> skipped=<n> failed=0 elapsed_s=<n>
#   SEED_HUMAN_SIDECARS count=<n> bytes=<n>
#   SEED_HUMAN_CHECK_OK clips=<n> missing=0 mismatch=0 feet_off=<n>
#   SEED_HUMAN_OK sidecars=<n>
#   SEED_HUMAN_FAIL reason=<...>
#
# The OK markers are BUFFERED and flushed only after EVERY check of the
# sub-command passed (the S03/S04 convention).
#
# ---------------------------------------------------------------------------
# RECORDED DEVIATIONS (deliberate, documented)
#
#   * `--workers 28`: the container advertises 32 CPUs (README suggests 96).
#     28 leaves head-room for the NFS write path; the conversion of the 1h
#     subset takes ~30 s, so the worker count is not the bottleneck.
#   * Only the 1h SUBSET (490 clips) is converted, not the full library
#     (142,220 clips, README).  Requirement R009 scopes S05 to the 1h
#     subset; the full run extrapolates to ~65 min and stays a follow-up.
#   * `check_human` gets an extra `--out logs/env/check_human_1h.csv` so the
#     per-clip table (feet_min_z, height ratio, pelvis rms) survives as
#     evidence.
#
# ENVIRONMENT OVERRIDES
#   SEED_HUMAN_ALLOW_LOCAL=1  allow running outside the ros_dev container
#                              (the offline fixtures run locally)
#   SEED_HUMAN_LOG_DIR        log directory   (default $LOG_DIR)
#   SEED_HUMAN_NPZ_ROOT       robot npz root  (default data/seed_g1_npz50)
#   SEED_HUMAN_BVH_ROOT       SOMA BVH root   (default data/seed/soma_uniform/bvh)
#   SEED_HUMAN_SUBSET         subset yaml     (default <npz root>/subsets/1h.yaml)
#   SEED_HUMAN_HUMAN_ROOT     sidecar root    (default <npz root>/human50)
#   SEED_HUMAN_EXPECT_CLIPS   expected clips  (default 490)
#   SEED_HUMAN_WORKERS        upstream workers (default 28)
#   SEED_HUMAN_PY             stdlib interpreter for repro/lib/seed_human.py
#                             (default python3 — no numpy needed)
#   SEED_HUMAN_VENV_PY        the upstream interpreter (default: .venv/bin/python,
#                             else `uv run --frozen --no-sync python`)
#
# USAGE
#   bash repro/15_seed_human.sh env
#   bash repro/15_seed_human.sh convert
#   bash repro/15_seed_human.sh status

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

# common.sh turns on `set -e`.  This script handles every failure path
# explicitly (each gate prints its own fail marker and returns 1), and an
# unchecked non-zero status of an intermediate probe (a grep that finds
# nothing, a python probe that fails) must NOT abort the gate before the
# fail marker is printed.  Errexit is therefore disabled here.
set +e

if [ "${SEED_HUMAN_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

LOG_DIR_REAL="${SEED_HUMAN_LOG_DIR:-$LOG_DIR}"
NPZ_ROOT="${SEED_HUMAN_NPZ_ROOT:-$REPO_ROOT/data/seed_g1_npz50}"
BVH_ROOT="${SEED_HUMAN_BVH_ROOT:-$REPO_ROOT/data/seed/soma_uniform/bvh}"
SUBSET_YAML="${SEED_HUMAN_SUBSET:-$NPZ_ROOT/subsets/1h.yaml}"
HUMAN_ROOT="${SEED_HUMAN_HUMAN_ROOT:-$NPZ_ROOT/human50}"
EXPECT_CLIPS="${SEED_HUMAN_EXPECT_CLIPS:-490}"
WORKERS="${SEED_HUMAN_WORKERS:-28}"
MAIN_LOG="$LOG_DIR_REAL/15_seed_human.txt"
STATUS_FILE="$LOG_DIR_REAL/15_seed_human.status"
CHECK_CSV="$LOG_DIR_REAL/check_human_1h.csv"
PY="${SEED_HUMAN_PY:-python3}"
SEED_HUMAN_PY_MODULE="$REPO_ROOT/repro/lib/seed_human.py"

usage() {
  cat <<EOF
usage: bash repro/15_seed_human.sh [env|convert|status]

  env      fail-closed environment gate (seconds); SEED_HUMAN_ENV_OK
  convert  convert the subset to human50 sidecars + upstream check
  status   print the status file and the key markers (always exit 0)

logs:  $MAIN_LOG
       $STATUS_FILE
       $CHECK_CSV
EOF
}

# --- output -----------------------------------------------------------------
# hlog writes to stdout AND appends to the log file, so every marker is
# greppable in logs/env/15_seed_human.txt.
hlog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed only when EVERY check passed.
OK_MARKERS=()
hlog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do hlog "$m"; done
  OK_MARKERS=()
}

# fail <reason> [key=value ...] — the ONLY failure exit of a gate.
# It prints the fail marker and returns 1; it never prints an OK marker.
fail() {
  local reason="$1"; shift || true
  hlog "SEED_HUMAN_FAIL reason=$reason"
  local kv
  for kv in "$@"; do
    [ -n "$kv" ] && hlog "  $kv"
  done
  return 1
}

# --- the upstream interpreter ----------------------------------------------
# The upstream scripts need numpy/scipy/pandas (the container's system
# python3 has no numpy).  Prefer the project venv; fall back to `uv run`.
venv_python_cmd() {
  if [ -n "${SEED_HUMAN_VENV_PY:-}" ]; then
    printf '%s\n' "$SEED_HUMAN_VENV_PY"
    return 0
  fi
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    printf '%s\n' "$REPO_ROOT/.venv/bin/python"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    printf '%s\n' "uv run --frozen --no-sync python"
    return 0
  fi
  printf '%s\n' "python3"
}

# --- the env gate -----------------------------------------------------------
# The probe prints one `key=value` line per module; it never raises, so the
# shell decides which module failed and which reason applies.
ENV_PROBE='
import importlib, sys
print("python=%d.%d.%d" % sys.version_info[0:3])
for _m in ("morphmimic", "numpy", "scipy"):
    try:
        _mod = importlib.import_module(_m)
        print("ok:%s:%s" % (_m, getattr(_mod, "__version__", "unknown")))
    except Exception as _e:
        print("fail:%s:%r" % (_m, _e))
'

# probe_env <python-cmd...> — runs the import probe; prints the probe output.
probe_env() {
  ( cd "$REPO_ROOT" && "$@" -c "$ENV_PROBE" 2>&1 )
}

# VENV_CMD is the upstream interpreter, resolved ONCE (globally, because both
# cmd_env and cmd_convert need it).
VENV_CMD=()
_vpy_cand="$(venv_python_cmd)"
read -r -a VENV_CMD <<<"$_vpy_cand"
if [ "${#VENV_CMD[@]}" -eq 0 ]; then
  VENV_CMD=(python3)
fi

cmd_env() {
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
  hlog "=== 15_seed_human.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  # (a) the upstream interpreter must import morphmimic + numpy + scipy.
  local probe probe_rc=0
  probe="$(probe_env "${VENV_CMD[@]}")" || probe_rc=$?
  while IFS= read -r line; do hlog "probe: $line"; done <<<"$probe"
  local failed=""
  local mod
  for mod in morphmimic numpy scipy; do
    if ! printf '%s\n' "$probe" | grep -q "^ok:$mod:"; then
      failed="$failed $mod"
    fi
  done
  if [ -n "$failed" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=env-import-failed modules=$failed rc=$probe_rc"
    hlog "HINT: the container venv is incomplete; fix it with: uv sync --frozen"
    return 1
  fi

  # (b) the subset yaml must exist, be parsable and hold the expected clips.
  if [ ! -f "$SUBSET_YAML" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=subset-missing path=$SUBSET_YAML"
    return 1
  fi
  local spec spec_rc=0
  spec="$("$PY" "$SEED_HUMAN_PY_MODULE" subset "$SUBSET_YAML" 2>&1)" || spec_rc=$?
  while IFS= read -r line; do hlog "subset: $line"; done <<<"$spec"
  if [ "$spec_rc" -ne 0 ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=subset-unparsable path=$SUBSET_YAML"
    return 1
  fi
  local clips
  clips="$(printf '%s\n' "$spec" | sed -n 's/^clips=//p' | head -n1)"
  if [ -z "$clips" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=subset-unparsable path=$SUBSET_YAML"
    return 1
  fi
  if [ "$clips" != "$EXPECT_CLIPS" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=subset-unparsable clips=$clips expected=$EXPECT_CLIPS"
    return 1
  fi

  # (c) the BVH root must exist and hold at least one BVH.
  if [ ! -d "$BVH_ROOT" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=bvh-root-missing dir=$BVH_ROOT"
    return 1
  fi
  if [ -z "$(find "$BVH_ROOT" -type f -name '*.bvh' -print -quit 2>/dev/null)" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=bvh-root-missing dir=$BVH_ROOT (no *.bvh inside)"
    return 1
  fi

  # (d) the sidecar root must be writable (the conversion writes into it).
  if ! mkdir -p "$HUMAN_ROOT" 2>/dev/null; then
    hlog "SEED_HUMAN_ENV_FAIL reason=human-root-unwritable dir=$HUMAN_ROOT"
    return 1
  fi
  if [ ! -w "$HUMAN_ROOT" ]; then
    hlog "SEED_HUMAN_ENV_FAIL reason=human-root-unwritable dir=$HUMAN_ROOT"
    return 1
  fi

  local python_version numpy_version scipy_version
  python_version="$(printf '%s\n' "$probe" | sed -n 's/^python=//p' | head -n1)"
  numpy_version="$(printf '%s\n' "$probe" | sed -n 's/^ok:numpy://p' | head -n1)"
  scipy_version="$(printf '%s\n' "$probe" | sed -n 's/^ok:scipy://p' | head -n1)"

  hlog_ok "SEED_HUMAN_ENV_OK clips=$clips workers=$WORKERS python=$python_version numpy=$numpy_version scipy=$scipy_version"
  flush_ok_markers
  return 0
}

# --- convert ----------------------------------------------------------------
# The status file is written atomically (tmp file + rename) so a reader never
# sees a half-written state.
write_status() {
  local state="$1"; shift
  local tmp="$STATUS_FILE.tmp.$$"
  {
    printf 'STATE=%s\n' "$state"
    printf 'RC=%s\n' "$1"; shift
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
    printf 'FINISHED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp" 2>/dev/null || true
  mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || true
}

cmd_convert() {
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
  hlog "=== 15_seed_human.sh convert $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  # The env gate is a precondition: converting with a broken environment
  # would leave a half-written sidecar tree behind.
  if ! cmd_env; then
    write_status "FAILED" "1" "CLIPS=$EXPECT_CLIPS" "REASON=env-gate"
    return 1
  fi

  local started ended elapsed
  started="$(date +%s)"

  # --- upstream conversion --------------------------------------------------
  # `--subset-yaml` is MANDATORY (without it upstream globs the npz root and
  # would feed on its own sidecars).  `--overwrite` is NOT passed: an
  # existing sidecar is then "skipped", which keeps a re-run cheap.
  local convert_out convert_rc=0
  convert_out="$(
    cd "$REPO_ROOT" && "${VENV_CMD[@]}" -m morphmimic.scripts.convert_human \
      --npz-root "$NPZ_ROOT" \
      --bvh-root "$BVH_ROOT" \
      --human-root "$HUMAN_ROOT" \
      --subset-yaml "$SUBSET_YAML" \
      --workers "$WORKERS" 2>&1
  )" || convert_rc=$?
  while IFS= read -r line; do hlog "convert: $line"; done <<<"$convert_out"

  if [ "$convert_rc" -ne 0 ]; then
    fail "convert-nonzero" "RC=$convert_rc"
    write_status "FAILED" "$convert_rc" "CLIPS=$EXPECT_CLIPS" "REASON=convert-nonzero"
    return 1
  fi

  # Upstream exits 0 even when clips failed -> parse the summary line and
  # assert it.  This is the trap that makes a direct upstream call a false
  # green.
  local summary converted skipped failed
  summary="$(printf '%s\n' "$convert_out" | grep -E '^converted [0-9]+, skipped [0-9]+, failed [0-9]+$' | tail -n1 || true)"
  if [ -z "$summary" ]; then
    fail "convert-summary-unparsable"
    write_status "FAILED" "1" "CLIPS=$EXPECT_CLIPS" "REASON=convert-summary-unparsable"
    return 1
  fi
  converted="$(printf '%s\n' "$summary" | sed -n 's/^converted \([0-9]*\),.*/\1/p')"
  skipped="$(printf '%s\n' "$summary" | sed -n 's/.*skipped \([0-9]*\),.*/\1/p')"
  failed="$(printf '%s\n' "$summary" | sed -n 's/.*failed \([0-9]*\)$/\1/p')"
  hlog "convert summary: converted=$converted skipped=$skipped failed=$failed"

  if [ "$failed" != "0" ]; then
    fail "convert-failed-clips" "FAILED=$failed" "SUMMARY=$summary"
    write_status "FAILED" "1" "CLIPS=$EXPECT_CLIPS" "CONVERTED=$converted" "SKIPPED=$skipped" "FAILED=$failed" "REASON=convert-failed-clips"
    return 1
  fi
  if [ $((converted + skipped)) -ne "$EXPECT_CLIPS" ]; then
    fail "convert-count" "CONVERTED=$converted" "SKIPPED=$skipped" "EXPECTED=$EXPECT_CLIPS"
    write_status "FAILED" "1" "CLIPS=$EXPECT_CLIPS" "CONVERTED=$converted" "SKIPPED=$skipped" "FAILED=$failed" "REASON=convert-count"
    return 1
  fi

  # --- the sidecars on disk -------------------------------------------------
  local sidecars sidecar_bytes
  sidecars="$(find "$HUMAN_ROOT" -type f -name '*.npz' | wc -l | tr -d ' ')"
  sidecar_bytes="$(find "$HUMAN_ROOT" -type f -name '*.npz' -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s+0}')"
  hlog "sidecars: count=$sidecars bytes=$sidecar_bytes"
  if [ "$sidecars" != "$EXPECT_CLIPS" ]; then
    fail "sidecar-count" "COUNT=$sidecars" "EXPECTED=$EXPECT_CLIPS" "DIR=$HUMAN_ROOT"
    write_status "FAILED" "1" "CLIPS=$EXPECT_CLIPS" "CONVERTED=$converted" "SKIPPED=$skipped" "FAILED=$failed" "SIDECARS=$sidecars" "REASON=sidecar-count"
    return 1
  fi

  # --- upstream check -------------------------------------------------------
  # The `--out` CSV is the evidence of the per-clip table (feet_min_z ...).
  local check_out check_rc=0
  check_out="$(
    cd "$REPO_ROOT" && "${VENV_CMD[@]}" -m morphmimic.scripts.check_human \
      --subset-yaml "$SUBSET_YAML" \
      --human-root "$HUMAN_ROOT" \
      --out "$CHECK_CSV" 2>&1
  )" || check_rc=$?
  while IFS= read -r line; do hlog "check: $line"; done <<<"$check_out"

  if [ "$check_rc" -ne 0 ]; then
    fail "check-nonzero" "RC=$check_rc"
    write_status "FAILED" "$check_rc" "CLIPS=$EXPECT_CLIPS" "CONVERTED=$converted" "SKIPPED=$skipped" "FAILED=$failed" "SIDECARS=$sidecars" "REASON=check-nonzero"
    return 1
  fi

  # Upstream prints: "<n> clips, <m> missing sidecars, <k> mismatches,
  # <f> feet_min_z outside [-0.05, 0.1] m".  The feet count is REPORTED
  # ONLY: upstream never fails on it.
  local missing mismatch feet_off
  missing="$(printf '%s\n' "$check_out" | sed -n 's/^[0-9]* clips, \([0-9]*\) missing sidecars.*/\1/p' | tail -n1 || true)"
  mismatch="$(printf '%s\n' "$check_out" | sed -n 's/.*, \([0-9]*\) mismatches,.*/\1/p' | tail -n1 || true)"
  feet_off="$(printf '%s\n' "$check_out" | sed -n 's/.*, \([0-9]*\) feet_min_z outside.*/\1/p' | tail -n1 || true)"
  missing="${missing:-0}"; mismatch="${mismatch:-0}"; feet_off="${feet_off:-0}"
  hlog "check summary: missing=$missing mismatch=$mismatch feet_off=$feet_off"

  if [ "$missing" != "0" ] || [ "$mismatch" != "0" ]; then
    fail "check-inconsistent" "MISSING=$missing" "MISMATCH=$mismatch"
    write_status "FAILED" "1" "CLIPS=$EXPECT_CLIPS" "CONVERTED=$converted" "SKIPPED=$skipped" "FAILED=$failed" "SIDECARS=$sidecars" "REASON=check-inconsistent"
    return 1
  fi

  ended="$(date +%s)"
  elapsed=$((ended - started))

  write_status "DONE" "0" \
    "CLIPS=$EXPECT_CLIPS" \
    "CONVERTED=$converted" \
    "SKIPPED=$skipped" \
    "FAILED=$failed" \
    "SIDECARS=$sidecars" \
    "FEET_OFF=$feet_off" \
    "ELAPSED=$elapsed"

  hlog_ok "SEED_HUMAN_CONVERT_OK clips=$EXPECT_CLIPS converted=$converted skipped=$skipped failed=$failed elapsed_s=$elapsed"
  hlog_ok "SEED_HUMAN_SIDECARS count=$sidecars bytes=$sidecar_bytes"
  hlog_ok "SEED_HUMAN_CHECK_OK clips=$EXPECT_CLIPS missing=$missing mismatch=$mismatch feet_off=$feet_off"
  hlog_ok "SEED_HUMAN_OK sidecars=$sidecars"
  flush_ok_markers
  return 0
}

# --- status -----------------------------------------------------------------
# Read-only, ALWAYS exit 0 (the caller must always be able to ask "what
# happened?" without the command itself failing).
cmd_status() {
  echo "=== 15_seed_human.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "--- status file ---"
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo "(no status file yet: $STATUS_FILE)"
  fi
  echo "--- key markers ---"
  if [ -f "$MAIN_LOG" ]; then
    grep -E '^SEED_HUMAN_(ENV_OK|CONVERT_OK|SIDECARS|CHECK_OK|OK|ENV_FAIL|FAIL) ' "$MAIN_LOG" | tail -n 10 || true
  else
    echo "(no log yet: $MAIN_LOG)"
  fi
  echo "--- sidecars on disk ---"
  if [ -d "$HUMAN_ROOT" ]; then
    local count
    count="$(find "$HUMAN_ROOT" -type f -name '*.npz' | wc -l | tr -d ' ')"
    echo "SIDECARS=$count DIR=$HUMAN_ROOT"
  else
    echo "SIDECARS=0 DIR=$HUMAN_ROOT (directory absent)"
  fi
  return 0
}

case "${1:-status}" in
  env)     shift || true; cmd_env "$@" ;;
  convert) shift || true; cmd_convert "$@" ;;
  status)  shift || true; cmd_status "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
