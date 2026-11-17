#!/usr/bin/env bash
# repro/13_seed_convert.sh — the orchestrator of the G1 50 Hz npz conversion.
#
# ---------------------------------------------------------------------------
# WHY THIS INTERFACE
#
# The conversion turns 142,220 SEED CSVs (120 Hz) into 142,220 50 Hz npz files
# (~150-160 GB) plus a manifest.csv and five subset yamls.  It is a LONG job
# (CPU side ~20-35 min, the NFS write side may dominate), so it follows the
# S03 pattern that is already proven in this repo:
#
#   env      a seconds-long gate that proves the container can really run the
#            conversion (torch importable, venv in the right place, data/logs
#            linked into the persistent store)
#   smoke    a 30-clip calibration in a scratch directory
#   start    launches the DETACHED worker (setsid + nohup + disown)
#   status   prints the status file + worker liveness (always exit 0)
#   wait     bounded wait (default 75 s); exit 75 on timeout, the worker keeps
#            running and is NEVER killed
#   worker   the foreground body (delegates to repro/13_seed_convert_worker.sh)
#   verify   read-only re-check of the terminal evidence
#   selftest the offline fixture batteries (repro/tests/test_seed_npz.sh and
#            repro/tests/test_seed_convert.sh)
#
# WHY THE ENV GATE IS MANDATORY (not optional politeness)
#
# The upstream `convert_all` records a failing clip as
# `feas_reject = "error: ..."` IN THE MANIFEST and still writes a manifest with
# one row per clip.  A broken environment therefore produces a manifest with
# 142,220 rows and a 100% error rate — a "successful" run that converted
# nothing.  During the planning of this slice the container venv was observed
# with an incomplete torch installation (`import torch` -> ModuleNotFoundError:
# No module named 'torch._vendor'), which is exactly that failure mode.
# The env gate turns it into a loud, early failure with a fix hint.
#
# MARKERS (grep -F friendly; a failing path NEVER emits an *_OK marker)
#   SEED_NPZ_ENV_OK python=<v> torch=<v> mujoco=<v> scipy=<v> workers=<n>
#   SEED_NPZ_ENV_FAIL reason=<...>
#   SEED_NPZ_SMOKE clips=30 elapsed_s=<n> npz_bytes=<n> avg_bytes=<n> rate=<n/s>
#   SEED_NPZ_SMOKE_OK clips=30
#   SEED_NPZ_START clips=<n> workers=<n>
#   SEED_NPZ_PROGRESS done=<n> rate=<n/s>
#   SEED_NPZ_CONVERT_OK clips=<n> rows=<n> errors=<n> error_rate=<r> elapsed_s=<n>
#   SEED_SUBSET_OK name=<subset> clips=<n> hours=<h>
#   SEED_SUBSET_NESTED ok
#   SEED_NPZ_FAIL reason=<...>
#
# ENVIRONMENT OVERRIDES
#   SEED_NPZ_ALLOW_LOCAL=1   allow running outside the ros_dev container
#   SEED_NPZ_OUT_DIR         npz output root (default data/seed_g1_npz50)
#   SEED_NPZ_CSV_DIR         SEED csv root     (default data/seed/g1/csv)
#   SEED_NPZ_METADATA        metadata csv      (default data/seed/metadata/...)
#   SEED_NPZ_WORKERS         conversion workers (default 28)
#   SEED_NPZ_SMOKE_DIR       smoke scratch dir  (default data/seed/_smoke_npz)
#   SEED_NPZ_SMOKE_WORKERS   smoke workers      (default 4)
#   SEED_NPZ_SMOKE_CLIPS     smoke clip count   (default 30)
#   SEED_NPZ_LOG_DIR         log directory      (default $LOG_DIR)
#   SEED_NPZ_WORKER          the detached worker body (default repro/13_seed_convert_worker.sh)
#   SEED_NPZ_ENV_PY          the command that runs the env probe (default
#                            `uv run --frozen --no-sync python`); a knob for the
#                            offline fixtures, which inject a stub probe
#   SEED_NPZ_ENV_EXPECT_PREFIX
#                            the venv the env gate expects (default $REPO_ROOT/.venv)
#   SEED_NPZ_CONVERT_LIMIT   only for the offline rehearsal of the worker: adds
#                            `--limit <n>` to the upstream conversion (default:
#                            empty = convert every clip)
#   SEED_EXPECTED_ROWS       expected manifest rows (default 142220)
#   SEED_MIN_FREE_GB         space gate threshold in GiB (default 250)

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
CSV_DIR="${SEED_NPZ_CSV_DIR:-$REPO_ROOT/data/seed/g1/csv}"
METADATA="${SEED_NPZ_METADATA:-$REPO_ROOT/data/seed/metadata/seed_metadata_v004.csv}"
SMOKE_DIR="${SEED_NPZ_SMOKE_DIR:-$REPO_ROOT/data/seed/_smoke_npz}"
WORKERS="${SEED_NPZ_WORKERS:-28}"
SMOKE_WORKERS="${SEED_NPZ_SMOKE_WORKERS:-4}"
SMOKE_CLIPS="${SEED_NPZ_SMOKE_CLIPS:-30}"
MAIN_LOG="$LOG_DIR_REAL/13_seed_convert.txt"
STATUS_FILE="$LOG_DIR_REAL/13_seed_convert.status"
WORKER_LOG="$LOG_DIR_REAL/13_seed_convert_worker.log"
WORKER="${SEED_NPZ_WORKER:-$REPO_ROOT/repro/13_seed_convert_worker.sh}"
VERIFY_SH="$REPO_ROOT/repro/14_seed_npz_verify.sh"
DEFAULT_WAIT=75

UV_RUN=(uv run --frozen --no-sync python)
# The command used by the env gate to probe the environment.  It is a knob so
# that the offline negative fixtures can inject a stub probe (e.g. one that
# reports a broken torch) without a container.
ENV_PY_CMD="${SEED_NPZ_ENV_PY:-uv run --frozen --no-sync python}"
# The venv the env gate expects; overridable for the same reason.
ENV_EXPECT_PREFIX="${SEED_NPZ_ENV_EXPECT_PREFIX:-$REPO_ROOT/.venv}"

usage() {
  cat <<EOF
usage: bash repro/13_seed_convert.sh [env|smoke|start|status|wait [sec]|worker|verify|selftest]

  env       seconds-long environment gate (torch/mujoco/... importable)
  smoke     30-clip calibration in a scratch directory
  start     launch the detached conversion worker
  status    print the status file + worker liveness (always exit 0)
  wait      bounded wait (default ${DEFAULT_WAIT}s); exit 75 on timeout
  worker    the foreground conversion body
  verify    read-only re-check of the terminal evidence
  selftest  the offline fixture battery

logs:  $MAIN_LOG
       $WORKER_LOG
       $STATUS_FILE
EOF
}

# --- output -----------------------------------------------------------------
# olog writes to stdout AND appends to the main log, so every marker is
# greppable in logs/env/13_seed_convert.txt.
olog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# OK_MARKERS holds the success markers of the individual gates.  They are
# BUFFERED and only flushed when EVERY check of the gate passed, so a failing
# run can never emit a single "*_OK" marker (the convention of S03, MEM038).
OK_MARKERS=()
olog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do olog "$m"; done
  OK_MARKERS=()
}

# --- status -----------------------------------------------------------------
# npz_state <status file> -> STATE=RUNNING|DONE|FAILED|ABSENT
# A worker whose PID is gone but whose state is not terminal counts as FAILED:
# "RUNNING forever" is exactly the failure mode this script exists to avoid.
npz_state() {
  local statusfile="$1"
  if [ ! -f "$statusfile" ]; then
    echo "STATE=ABSENT"
    return 3
  fi
  local state pid
  state="$(sed -n 's/^STATE=//p' "$statusfile" | head -n1)"
  pid="$(sed -n 's/^PID=//p' "$statusfile" | head -n1)"
  case "${state:-}" in
    DONE|FAILED)
      echo "STATE=$state"
      return 0
      ;;
  esac
  if [ -n "${pid:-}" ] && [ "$pid" != "0" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "STATE=FAILED"
    echo "REASON=worker pid $pid is gone but no terminal state was written"
    return 0
  fi
  echo "STATE=RUNNING"
  return 0
}

# --- the env gate -----------------------------------------------------------
# The probe prints one `key=value` line per module; it never raises, so the
# shell can decide which module failed (the hint differs: torch needs
# `uv sync --frozen`, everything else needs a bug report).
ENV_PROBE='
import importlib, sys
print("python=%d.%d" % (sys.version_info[0], sys.version_info[1]))
print("prefix=%s" % sys.prefix)
for _m in ("torch", "mujoco", "scipy", "tqdm", "pandas", "yaml"):
    try:
        _mod = importlib.import_module(_m)
        print("ok:%s:%s" % (_m, getattr(_mod, "__version__", "unknown")))
    except Exception as _e:  # noqa: BLE001
        print("fail:%s:%r" % (_m, _e))
'

cmd_env() {
  olog "=== 13_seed_convert.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

  local probe rc=0
  # shellcheck disable=SC2086
  probe="$(cd "$REPO_ROOT" && $ENV_PY_CMD -c "$ENV_PROBE" 2>&1)" || rc=$?
  if [ -z "$probe" ]; then
    olog "SEED_NPZ_ENV_FAIL reason=no-probe-output rc=$rc"
    return 1
  fi
  while IFS= read -r line; do olog "probe: $line"; done <<<"$probe"

  local failed=""
  local mod
  for mod in torch mujoco scipy tqdm pandas yaml; do
    if ! printf '%s\n' "$probe" | grep -q "^ok:$mod:"; then
      failed="$failed $mod"
    fi
  done
  if [ -n "$failed" ]; then
    olog "SEED_NPZ_ENV_FAIL reason=import-failed modules=$failed"
    if printf '%s\n' "$failed" | grep -q "torch"; then
      olog "HINT: the container venv has no usable torch installation."
      olog "HINT: fix it INSIDE the container with: uv sync --frozen"
      olog "HINT: (the fix is NOT run automatically: a long job must not silently"
      olog "HINT:  change its own environment)."
    fi
    return 1
  fi

  local prefix
  prefix="$(printf '%s\n' "$probe" | sed -n 's/^prefix=//p' | head -n1)"
  local expected_prefix="$ENV_EXPECT_PREFIX"
  # Compare the RESOLVED paths: a venv may be reached through a symlink
  # (e.g. the .venv directory linked to a local disk to dodge slow NFS
  # copies), and sys.prefix then reports the link target, not the link.
  local prefix_real expected_real
  prefix_real="$(readlink -f "$prefix" 2>/dev/null || true)"
  expected_real="$(readlink -f "$expected_prefix" 2>/dev/null || true)"
  [ -n "$prefix_real" ] || prefix_real="$prefix"
  [ -n "$expected_real" ] || expected_real="$expected_prefix"
  prefix="$prefix_real"; expected_prefix="$expected_real"
  if [ -z "$prefix" ] || [ "$prefix" != "$expected_prefix" ]; then
    olog "SEED_NPZ_ENV_FAIL reason=venv-path-mismatch prefix=$prefix expected=$expected_prefix"
    return 1
  fi

  # data/ and logs/ must be SYMLINKS into the persistent store: the payload
  # must survive a rebuild of this worktree (see repro/lib/seed_store.sh).
  local store="${SEED_STORE_ROOT:-}"
  local name link resolved
  for name in data logs; do
    if [ ! -L "$REPO_ROOT/$name" ]; then
      olog "SEED_NPZ_ENV_FAIL reason=store-link-missing name=$name"
      return 1
    fi
    resolved="$(readlink -f "$REPO_ROOT/$name" 2>/dev/null || true)"
    if [ -z "$store" ] || ! printf '%s' "$resolved" | grep -q "^$store"; then
      olog "SEED_NPZ_ENV_FAIL reason=store-link-wrong name=$name resolved=$resolved store=$store"
      return 1
    fi
    link="$(readlink "$REPO_ROOT/$name")"
    olog "store link ok: $name -> $link (resolved $resolved)"
  done

  if [ ! -d "$CSV_DIR" ]; then
    olog "SEED_NPZ_ENV_FAIL reason=csv-dir-missing dir=$CSV_DIR"
    return 1
  fi
  if [ ! -f "$METADATA" ]; then
    olog "SEED_NPZ_ENV_FAIL reason=metadata-missing file=$METADATA"
    return 1
  fi

  local python_version torch_version mujoco_version scipy_version
  python_version="$(printf '%s\n' "$probe" | sed -n 's/^python=//p' | head -n1)"
  torch_version="$(printf '%s\n' "$probe" | sed -n 's/^ok:torch://p' | head -n1)"
  mujoco_version="$(printf '%s\n' "$probe" | sed -n 's/^ok:mujoco://p' | head -n1)"
  scipy_version="$(printf '%s\n' "$probe" | sed -n 's/^ok:scipy://p' | head -n1)"

  olog_ok "SEED_NPZ_ENV_OK python=$python_version torch=$torch_version mujoco=$mujoco_version scipy=$scipy_version workers=$WORKERS"
  flush_ok_markers
  return 0
}

# --- the smoke gate ---------------------------------------------------------
# The smoke runs the REAL upstream converter on 30 clips in a scratch directory
# and reads one npz back.  It calibrates the wall clock and the bytes per clip
# so that the full-run size/wall-clock can be extrapolated.
SMOKE_PROBE='
import glob, os, sys
import numpy as np
from morphmimic.robots import get_robot
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "*", "*.npz")))
print("nfiles=%d" % len(files))
if not files:
    sys.exit(2)
with np.load(files[0], allow_pickle=False) as z:
    print("keys=%s" % ",".join(sorted(z.files)))
    print("fps=%d" % int(z["fps"]))
    joints = [str(x) for x in z["joint_names"]]
    print("njoints=%d" % len(joints))
    print("nbodies=%d" % len([str(x) for x in z["body_names"]]))
    frames = int(z["joint_pos"].shape[0])
    print("frames=%d" % frames)
    print("zmin_len=%d" % len(z["z_min"]))
    print("foot_len=%d" % len(z["foot_dist"]))
    spec = get_robot("g1")
    print("g1_joint_match=%d" % int(set(joints) == set(spec.joint_names)))
'

cmd_smoke() {
  olog "=== 13_seed_convert.sh smoke $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

  # The scratch directory must hold the REAL conversion, so any leftovers of a
  # previous smoke are removed first: upstream reuses an existing npz instead
  # of converting it, which would make the calibration meaningless.
  case "$SMOKE_DIR" in
    */_smoke_npz|*/_smoke_npz/*) : ;;
    *)
      olog "SEED_NPZ_FAIL reason=unsafe-smoke-dir dir=$SMOKE_DIR"
      return 1
      ;;
  esac
  rm -rf "$SMOKE_DIR"
  mkdir -p "$SMOKE_DIR"

  local started ended elapsed rc=0
  started="$(date +%s)"
  ( cd "$REPO_ROOT" && "${UV_RUN[@]}" -m morphmimic.scripts.convert_seed \
      --csv-dir "$CSV_DIR" \
      --metadata "$METADATA" \
      --out-dir "$SMOKE_DIR" \
      --workers "$SMOKE_WORKERS" \
      --limit "$SMOKE_CLIPS" ) 2>&1 | tee "$LOG_DIR_REAL/13_seed_convert_smoke.log"
  rc=${PIPESTATUS[0]}
  ended="$(date +%s)"
  elapsed=$((ended - started))
  if [ "$rc" -ne 0 ]; then
    olog "SEED_NPZ_FAIL reason=smoke-convert-failed rc=$rc"
    return 1
  fi

  local npz_count npz_bytes avg_bytes rate
  npz_count="$(find "$SMOKE_DIR" -type f -name '*.npz' | wc -l | tr -d ' ')"
  npz_bytes="$(find "$SMOKE_DIR" -type f -name '*.npz' -printf '%s\n' | awk '{s+=$1} END {printf "%d", s+0}')"
  if [ "$npz_count" -lt 1 ]; then
    olog "SEED_NPZ_FAIL reason=smoke-no-npz dir=$SMOKE_DIR"
    return 1
  fi
  avg_bytes=$((npz_bytes / npz_count))
  rate="$(awk -v n="$npz_count" -v s="$elapsed" 'BEGIN { if (s > 0) printf "%.2f", n/s; else printf "0.00" }')"

  local probe probe_rc=0
  probe="$(cd "$REPO_ROOT" && "${UV_RUN[@]}" - "$SMOKE_DIR" <<<"$SMOKE_PROBE" 2>&1)" || probe_rc=$?
  while IFS= read -r line; do olog "smoke: $line"; done <<<"$probe"
  if [ "$probe_rc" -ne 0 ]; then
    olog "SEED_NPZ_FAIL reason=smoke-probe-failed rc=$probe_rc"
    return 1
  fi

  local value
  value() { printf '%s\n' "$probe" | sed -n "s/^$1=//p" | head -n1; }

  local expected_keys="body_ang_vel_w,body_lin_vel_w,body_names,body_pos_w,body_quat_w,foot_dist,fps,joint_names,joint_pos,joint_vel,robot,root_body,z_min"
  local got_keys; got_keys="$(value keys)"
  if [ "$got_keys" != "$expected_keys" ]; then
    olog "SEED_NPZ_FAIL reason=smoke-key-set got=$got_keys expected=$expected_keys"
    return 1
  fi
  if [ "$(value fps)" != "50" ]; then
    olog "SEED_NPZ_FAIL reason=smoke-fps got=$(value fps) expected=50"
    return 1
  fi
  if [ "$(value njoints)" != "29" ]; then
    olog "SEED_NPZ_FAIL reason=smoke-joint-count got=$(value njoints) expected=29"
    return 1
  fi
  if [ "$(value g1_joint_match)" != "1" ]; then
    olog "SEED_NPZ_FAIL reason=smoke-joint-set-mismatch"
    return 1
  fi
  if [ "$(value nbodies)" -le 0 ] 2>/dev/null; then
    olog "SEED_NPZ_FAIL reason=smoke-no-bodies got=$(value nbodies)"
    return 1
  fi
  local frames zmin_len foot_len
  frames="$(value frames)"; zmin_len="$(value zmin_len)"; foot_len="$(value foot_len)"
  if [ "$zmin_len" != "$frames" ] || [ "$foot_len" != "$frames" ]; then
    olog "SEED_NPZ_FAIL reason=smoke-frame-lengths frames=$frames zmin=$zmin_len foot=$foot_len"
    return 1
  fi
  if [ "$npz_count" != "$SMOKE_CLIPS" ]; then
    olog "SEED_NPZ_FAIL reason=smoke-clip-count got=$npz_count expected=$SMOKE_CLIPS"
    return 1
  fi

  olog "SEED_NPZ_SMOKE_EXTRACT clips=$npz_count elapsed_s=$elapsed npz_bytes=$npz_bytes avg_bytes=$avg_bytes rate=$rate"
  local total_bytes est_seconds
  total_bytes=$((avg_bytes * $(seed_npz_expected_rows)))
  est_seconds="$(awk -v n="$npz_count" -v s="$elapsed" -v t="$(seed_npz_expected_rows)" \
    'BEGIN { if (s > 0) printf "%d", t*s/n; else printf "0" }')"
  olog "SEED_NPZ_SMOKE_EXTRACT full_bytes=$total_bytes full_seconds=$est_seconds"

  olog_ok "SEED_NPZ_SMOKE clips=$npz_count elapsed_s=$elapsed npz_bytes=$npz_bytes avg_bytes=$avg_bytes rate=$rate"
  olog_ok "SEED_NPZ_SMOKE_OK clips=$npz_count"
  flush_ok_markers
  return 0
}

# --- start / status / wait --------------------------------------------------
cmd_start() {
  local state
  state="$(npz_state "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
  if [ "$state" = "RUNNING" ]; then
    olog "conversion worker already RUNNING:"
    npz_state "$STATUS_FILE" | while read -r line; do olog "$line"; done || true
    return 0
  fi
  if [ ! -f "$WORKER" ]; then
    olog "SEED_NPZ_FAIL reason=worker-missing path=$WORKER"
    return 1
  fi
  olog "starting detached seed-npz conversion worker ..."
  mkdir -p "$LOG_DIR_REAL"
  setsid nohup bash "$WORKER" >>"$WORKER_LOG" 2>&1 </dev/null &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  olog "WORKER_PID=$pid"
  olog "STATUS_FILE=$STATUS_FILE"
  olog "WORKER_LOG=$WORKER_LOG"
  olog "poll with: bash repro/lib/remote.sh 13_seed_convert.sh status"
  return 0
}

cmd_status() {
  echo "=== 13_seed_convert.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  npz_state "$STATUS_FILE" || true
  echo "--- status file ---"
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo "(no status file yet: $STATUS_FILE)"
  fi
  echo "--- log tail ---"
  if [ -f "$WORKER_LOG" ]; then
    tail -n 20 "$WORKER_LOG"
  elif [ -f "$MAIN_LOG" ]; then
    tail -n 20 "$MAIN_LOG"
  else
    echo "(no log yet: $MAIN_LOG)"
  fi
  return 0
}

cmd_wait() {
  local timeout_s="${1:-$DEFAULT_WAIT}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local state
  while :; do
    state="$(sed -n 's/^STATE=//p' "$STATUS_FILE" 2>/dev/null | head -n1)" || state="ABSENT"
    case "${state:-}" in
      DONE)  olog "conversion worker finished: DONE";  return 0 ;;
      FAILED) olog "conversion worker finished: FAILED"; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      olog "conversion worker still running after ${timeout_s}s - keep polling:"
      olog "  bash repro/lib/remote.sh 13_seed_convert.sh status"
      olog "  bash repro/lib/remote.sh 13_seed_convert.sh wait 300"
      # EX_TEMPFAIL: the worker keeps running, nothing was killed.
      return 75
    fi
    sleep 5
  done
}

# --- worker / verify / selftest ---------------------------------------------
cmd_worker() {
  bash "$WORKER" "$@"
}

cmd_verify() {
  if [ -f "$VERIFY_SH" ]; then
    bash "$VERIFY_SH" verify "$@"
    return $?
  fi
  # Fallback until repro/14_seed_npz_verify.sh exists (slice task T03).
  olog "=== 13_seed_convert.sh verify (fallback) $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  local manifest="$OUT_DIR/manifest.csv"
  if [ ! -f "$manifest" ]; then
    olog "SEED_NPZ_FAIL reason=manifest-missing path=$manifest"
    return 1
  fi
  local stats rows errors ok
  stats="$(python3 "$REPO_ROOT/repro/lib/seed_npz.py" stats "$manifest" 2>&1)" || {
    olog "SEED_NPZ_FAIL reason=manifest-unparsable"
    return 1
  }
  rows="$(printf '%s\n' "$stats" | sed -n 's/^rows=//p' | head -n1)"
  errors="$(printf '%s\n' "$stats" | sed -n 's/^errors=//p' | head -n1)"
  ok="$(printf '%s\n' "$stats" | sed -n 's/^error_rate_ok=//p' | head -n1)"
  if [ "$rows" != "$(seed_npz_expected_rows)" ] || [ "$ok" != "1" ]; then
    olog "SEED_NPZ_FAIL reason=manifest-rejected rows=$rows expected=$(seed_npz_expected_rows) error_rate_ok=$ok"
    return 1
  fi
  local name missing=""
  for name in tiny 1h 7h 40h all; do
    [ -s "$OUT_DIR/subsets/$name.yaml" ] || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    olog "SEED_NPZ_FAIL reason=subsets-missing names=$missing"
    return 1
  fi
  olog "SEED_NPZ_VERIFY_FALLBACK_OK rows=$rows errors=$errors"
  return 0
}

cmd_selftest() {
  # T01's battery (the pure decision functions) plus this slice's own
  # failure-path battery (the orchestrator's fail-closed behaviour).
  bash "$REPO_ROOT/repro/tests/test_seed_npz.sh" || return 1
  bash "$REPO_ROOT/repro/tests/test_seed_convert.sh" || return 1
  return 0
}

case "${1:-status}" in
  env)      shift || true; cmd_env "$@" ;;
  smoke)    shift || true; cmd_smoke "$@" ;;
  start)    shift || true; cmd_start "$@" ;;
  status)   shift || true; cmd_status "$@" ;;
  wait)     shift || true; cmd_wait "${1:-$DEFAULT_WAIT}" ;;
  worker)   shift || true; cmd_worker "$@" ;;
  verify)   shift || true; cmd_verify "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
