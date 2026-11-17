#!/usr/bin/env bash
# repro/17_train.sh — the TRAINING ORCHESTRATOR of the g1_amber formal run
# (slice S06).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# `python -m morphmimic.scripts.train` is a multi-hour, GPU-saturating
# command.  Running it in the foreground of one ssh session would die with
# the session and throw away the whole machine budget; running it without a
# status file would leave the resource peaks (VRAM / host RAM) unprovable.
#
# So this script is the S03/S04-style triple:
#
#   * a DETACHED worker (repro/17_train_worker.sh, started with
#     setsid/nohup) that survives the session that launched it,
#   * a BOUNDED poll (`wait <timeout_s>`) that never blocks forever and
#     NEVER kills the worker when it times out (exit 75 = EX_TEMPFAIL),
#   * an ATOMIC status file (logs/env/17_train.status, written through
#     repro/lib/train.py `write_status`: .tmp + os.replace).
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env       the fail-closed ENVIRONMENT GATE (seconds).  Everything the
#             training needs must be in place BEFORE a single GPU second is
#             spent: venv + torch/CUDA, the 1h subset (490 clips), the
#             human50 sidecars (490), the npz library (142,220 rows), a GPU
#             with >= 20 GiB, and >= 50 GiB of free disk for the ckpts.
#             Success prints ONE line:
#                 TRAIN_ENV_OK python=<v> torch=<v> clips=490 sidecars=490 \
#                        gpu_total_mb=<n> free_gb=<n>
#             Failure prints ONE line:
#                 TRAIN_ENV_FAIL reason=<fixed reason set>
#             and exits non-zero.  The OK marker is BUFFERED and flushed only
#             when EVERY check passed, so a failing gate can never emit a
#             half-OK marker (the S03/MEM038 convention).
#
#   smoke     the 2k-iteration smoke test.  SKELETON in this task: the
#             implementation belongs to T3 (it needs the GPU).  It fails
#             closed with reason=smoke-not-implemented until then.
#
#   start     launch the detached worker; prints WORKER_PID / STATUS_FILE /
#             WORKER_LOG and returns immediately (never blocks).
#
#   status    READ-ONLY snapshot: the status file, the resource peaks and
#             the training log tail.  ALWAYS exits 0 (it is a diagnostic,
#             not a gate).
#
#   wait <s>  bounded wait: 0 = DONE, 1 = FAILED, 75 = timeout (the worker
#             keeps running; it is NEVER killed).
#
#   worker    run the training body in the foreground (the detached worker
#             does the same; this is the manual entry point).
#
#   verify    delegate to the read-only verifier repro/18_train_verify.sh
#             (built by T3).
#
#   selftest  run the offline battery: repro/tests/test_train.sh (the
#             decision base) + repro/tests/test_train_orchestrator.sh (the
#             negative battery of THIS script) +
#             repro/tests/test_train_verify.sh (the fixture battery of the
#             read-only reviewer repro/18_train_verify.sh) +
#             repro/tests/test_train_verify_tb_e2e.sh (the same reviewer
#             against the REAL tensorboard / torch; it skips itself when
#             neither is importable).
#
# ---------------------------------------------------------------------------
# THE FAILURE REASON SET OF THE ENV GATE (fixed, greppable)
#
#   import-failed      the venv python cannot import torch/mjlab/morphmimic
#   cuda-unavailable   torch imports but torch.cuda.is_available() is False
#   venv-drift         the project venv is gone (the S05 gotcha) — the
#                      message carries the repair hint
#                      `uv sync --frozen --offline --group export --group teleop`
#                      (the container has NO outbound network -> --offline)
#   subset-missing     data/seed_g1_npz50/subsets/1h.yaml does not exist
#   subset-unparsable  the yaml exists but cannot be parsed
#   subset-count       the yaml parses but does not hold 490 clips
#   sidecar-missing    the human50 sidecar root is absent / holds no file
#   sidecar-count      the sidecar count is not 490 (this is also the reason
#                      used when the upstream human verifier fails)
#   npz-verify-failed  repro/14_seed_npz_verify.sh verify failed
#   gpu-missing        no GPU with >= 20000 MiB of total memory
#   disk-insufficient  the data disk has < 50 GiB free
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the negative battery
# can drive the gate offline, without a GPU and without the payload)
#
#   TRAIN_ALLOW_LOCAL=1     allow running outside the ros_dev container
#   TRAIN_LOG_DIR           log directory      (default $LOG_DIR = store)
#   TRAIN_STATUS_FILE       status file        (default logs/env/17_train.status)
#   TRAIN_WORKER_LOG        worker stdout      (default logs/env/17_train_worker.log)
#   TRAIN_RESOURCES_CSV     resource sampler   (default logs/env/17_train_resources.csv)
#   TRAIN_PLAN_FILE         the plan file      (default logs/env/17_train_plan.env)
#   TRAIN_NPZ_ROOT          npz root           (default data/seed_g1_npz50)
#   TRAIN_SUBSET_YAML       subset yaml        (default <npz root>/subsets/1h.yaml)
#   TRAIN_HUMAN_ROOT        sidecar root       (default <npz root>/human50)
#   TRAIN_DISK_PATH         disk to measure    (default <npz root>)
#   TRAIN_EXPECT_CLIPS      expected clips     (default 490)
#   TRAIN_MIN_GPU_MB        minimum GPU memory (default 20000)
#   TRAIN_MIN_FREE_GB       minimum free disk (default 50)
#   TRAIN_VENV_PY           the interpreter    (default .venv/bin/python, else
#                                                     `uv run --frozen --no-sync python`)
#   TRAIN_NVIDIA_SMI        the nvidia-smi     (default nvidia-smi)
#   TRAIN_NPZ_VERIFY_CMD    the npz gate       (default bash repro/14_seed_npz_verify.sh verify)
#   TRAIN_HUMAN_VERIFY_CMD  the human gate     (default bash repro/16_seed_human_verify.sh verify)
#   TRAIN_PY                the decision-base interpreter (default python3)
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/train.sh
source "$_SCRIPT_DIR/lib/train.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 16_seed_human_verify.sh convention).
set +e

if [ "${TRAIN_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${TRAIN_LOG_DIR:-$LOG_DIR}"
# CANONICALISE: the worktree's `logs/` symlink into the seed store can vanish
# when GSD rebuilds the milestone worktree mid-run (observed 2026-11-13, when
# the crashed worker could not even write its own status file).  The store
# path never moves, so the status file survives a rebuild.
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/17_train.txt"
ENV_LOG="$LOG_DIR_REAL/17_train_env.txt"
STATUS_FILE="${TRAIN_STATUS_FILE:-$LOG_DIR_REAL/17_train.status}"
WORKER_LOG="${TRAIN_WORKER_LOG:-$LOG_DIR_REAL/17_train_worker.log}"
RESOURCES_CSV="${TRAIN_RESOURCES_CSV:-$LOG_DIR_REAL/17_train_resources.csv}"
PLAN_FILE="${TRAIN_PLAN_FILE:-$LOG_DIR_REAL/17_train_plan.env}"
WORKER="$REPO_ROOT/repro/17_train_worker.sh"
VERIFIER="$REPO_ROOT/repro/18_train_verify.sh"

TRAIN_NPZ_ROOT="${TRAIN_NPZ_ROOT:-$REPO_ROOT/data/seed_g1_npz50}"
TRAIN_SUBSET_YAML="${TRAIN_SUBSET_YAML:-$TRAIN_NPZ_ROOT/subsets/1h.yaml}"
TRAIN_HUMAN_ROOT="${TRAIN_HUMAN_ROOT:-$TRAIN_NPZ_ROOT/human50}"
TRAIN_DISK_PATH="${TRAIN_DISK_PATH:-$TRAIN_NPZ_ROOT}"
TRAIN_EXPECT_CLIPS="${TRAIN_EXPECT_CLIPS:-490}"
TRAIN_MIN_GPU_MB="${TRAIN_MIN_GPU_MB:-20000}"
TRAIN_MIN_FREE_GB="${TRAIN_MIN_FREE_GB:-50}"
TRAIN_NVIDIA_SMI="${TRAIN_NVIDIA_SMI:-nvidia-smi}"
TRAIN_NPZ_VERIFY_CMD="${TRAIN_NPZ_VERIFY_CMD:-bash $REPO_ROOT/repro/14_seed_npz_verify.sh verify}"
TRAIN_HUMAN_VERIFY_CMD="${TRAIN_HUMAN_VERIFY_CMD:-bash $REPO_ROOT/repro/16_seed_human_verify.sh verify}"
TRAIN_PY_BIN="${TRAIN_PY:-python3}"
TRAIN_LIB_DIR="$REPO_ROOT/repro/lib"
SEED_NPZ_PY_MODULE="$TRAIN_LIB_DIR/seed_npz.py"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/17_train.sh <subcommand>

  env             the fail-closed environment gate (TRAIN_ENV_OK / TRAIN_ENV_FAIL)
  smoke           the 2k-iteration smoke test (skeleton: implemented in T3)
  start           launch the detached training worker (returns immediately)
  status          read-only snapshot (state file + resource peaks + log tail); exit 0
  wait [seconds]  bounded wait; 0=DONE 1=FAILED 75=timeout (the worker survives)
  worker          run the training body in the foreground
  verify          delegate to repro/18_train_verify.sh verify
  selftest        the offline battery (test_train.sh + test_train_orchestrator.sh
                  + test_train_verify.sh + test_train_verify_tb_e2e.sh)

logs:   $LOG_DIR_REAL
status: $STATUS_FILE
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

# The OK markers are buffered and flushed ONLY when every check passed.
OK_MARKERS=()
elog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do elog "$m"; done
  OK_MARKERS=()
}

# --- the decision-base helpers ---------------------------------------------
# train_status_write <path> <state> <rc> [KEY=VALUE ...]
# Atomic (write .tmp + os.replace) through repro/lib/train.py.
train_status_write() {
  local path="$1" state="$2" rc="$3"; shift 3
  local -a extra=("$@")
  "$TRAIN_PY_BIN" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
extra = {}
for kv in sys.argv[5:]:
    key, _, value = kv.partition("=")
    if key:
        extra[key] = value
train.write_status(sys.argv[2], sys.argv[3], sys.argv[4], extra)
' "$TRAIN_LIB_DIR" "$path" "$state" "$rc" ${extra[@]+"${extra[@]}"} 2>/dev/null
}

# train_status_field <key> — the value of a key of the status file.
train_status_field() {
  [ -f "$STATUS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATUS_FILE" | head -n1
}

# train_resource_peaks — the peaks of the resource sampler CSV (the decision
# base parses it; the shell never re-implements the parser).
train_resource_peaks() {
  "$TRAIN_PY_BIN" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
summary = train.parse_resource_csv(sys.argv[2])
if summary is None:
    print("gpu_used_mb_peak=0")
    print("host_used_gb_peak=0")
    print("samples=0")
else:
    print("gpu_used_mb_peak=%.0f" % (summary["gpu_used_mb_peak"] or 0))
    print("host_used_gb_peak=%.2f" % (summary["host_used_gb_peak"] or 0))
    print("samples=%d" % summary["samples"])
' "$TRAIN_LIB_DIR" "$RESOURCES_CSV" 2>/dev/null
}

# --- env gate ---------------------------------------------------------------
# The interpreter: an explicit override wins, then the project venv, then
# `uv run --frozen --no-sync python` (which needs an existing venv too).
train_interpreter() {
  if [ -n "${TRAIN_VENV_PY:-}" ]; then
    printf '%s' "$TRAIN_VENV_PY"
    return 0
  fi
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    printf '%s' "$REPO_ROOT/.venv/bin/python"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    printf '%s' "uv run --frozen --no-sync python"
    return 0
  fi
  printf '%s' ""
}

IMPORT_PROBE='
import sys
import torch
import mjlab
import morphmimic
print("PY_VERSION=" + sys.version.split()[0])
print("TORCH_VERSION=" + str(torch.__version__))
print("CUDA_AVAILABLE=" + str(torch.cuda.is_available()).upper())
if torch.cuda.is_available():
    print("CUDA_DEVICE=" + str(torch.cuda.get_device_name(0)))
'

# env_fail <reason> [detail...]
# The ONLY failure exit of the gate: it prints the fail marker (and the
# details) and returns 1.  It NEVER prints an OK marker.
env_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "TRAIN_ENV_FAIL reason=$reason"
  return 1
}

# env_gate — run every check; returns 0 and prints the OK marker when all
# of them passed, otherwise returns 1 with exactly one fail marker.
env_gate() {
  local interp probe_out probe_rc
  local python_version="" torch_version="" cuda_available=""
  interp="$(train_interpreter)"
  if [ -z "$interp" ]; then
    env_fail "venv-drift" \
      "no interpreter: neither .venv/bin/python nor uv run --frozen --no-sync python is available" \
      "fix: uv sync --frozen --offline --group export --group teleop" || return 1
    return 1
  fi

  # (1) the interpreter imports torch / mjlab / morphmimic and sees the GPU.
  local -a interp_cmd
  read -r -a interp_cmd <<<"$interp"
  probe_out="$("${interp_cmd[@]}" -c "$IMPORT_PROBE" 2>&1)"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    if printf '%s\n' "$probe_out" | grep -qiE 'no virtual environment|virtual environment|\.venv'; then
      env_fail "venv-drift" \
        "the project venv is gone or incomplete ($interp)" \
        "fix: uv sync --frozen --offline --group export --group teleop  (--offline: the container has no outbound network)" \
        "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    else
      env_fail "import-failed" \
        "interpreter=$interp" \
        "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    fi
    return 1
  fi
  python_version="$(printf '%s\n' "$probe_out" | sed -n 's/^PY_VERSION=//p' | head -n1)"
  torch_version="$(printf '%s\n' "$probe_out" | sed -n 's/^TORCH_VERSION=//p' | head -n1)"
  cuda_available="$(printf '%s\n' "$probe_out" | sed -n 's/^CUDA_AVAILABLE=//p' | head -n1)"
  if [ "$cuda_available" != "TRUE" ]; then
    env_fail "cuda-unavailable" "torch.cuda.is_available() is false (torch=$torch_version)" || return 1
    return 1
  fi

  # (2) the 1h subset: parsable and exactly 490 clips.
  if [ ! -f "$TRAIN_SUBSET_YAML" ]; then
    env_fail "subset-missing" "PATH=$TRAIN_SUBSET_YAML" || return 1
    return 1
  fi
  local spec_out spec_rc=0 clips=""
  spec_out="$("$TRAIN_PY_BIN" "$SEED_NPZ_PY_MODULE" subset-spec "$TRAIN_SUBSET_YAML" 2>&1)" || spec_rc=$?
  if [ "$spec_rc" -ne 0 ]; then
    env_fail "subset-unparsable" "PATH=$TRAIN_SUBSET_YAML" "detail: $(printf '%s\n' "$spec_out" | tail -n1)" || return 1
    return 1
  fi
  clips="$(printf '%s\n' "$spec_out" | sed -n 's/^clips=//p' | head -n1)"
  if [ -z "$clips" ]; then
    env_fail "subset-unparsable" "PATH=$TRAIN_SUBSET_YAML" "detail: no clips= field" || return 1
    return 1
  fi
  if [ "$clips" != "$TRAIN_EXPECT_CLIPS" ]; then
    env_fail "subset-count" "clips=$clips expected=$TRAIN_EXPECT_CLIPS" || return 1
    return 1
  fi

  # (3) the human50 sidecars: 490 files, and the upstream verifier agrees.
  if [ ! -d "$TRAIN_HUMAN_ROOT" ]; then
    env_fail "sidecar-missing" "PATH=$TRAIN_HUMAN_ROOT" || return 1
    return 1
  fi
  local sidecars
  sidecars="$(find "$TRAIN_HUMAN_ROOT" -type f -name '*.npz' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${sidecars:-0}" -eq 0 ]; then
    env_fail "sidecar-missing" "PATH=$TRAIN_HUMAN_ROOT" "detail: no sidecar files" || return 1
    return 1
  fi
  if [ "$sidecars" != "$TRAIN_EXPECT_CLIPS" ]; then
    env_fail "sidecar-count" "sidecars=$sidecars expected=$TRAIN_EXPECT_CLIPS" || return 1
    return 1
  fi
  if ! eval "$TRAIN_HUMAN_VERIFY_CMD" >/dev/null 2>&1; then
    env_fail "sidecar-count" "the human50 verifier failed: $TRAIN_HUMAN_VERIFY_CMD" || return 1
    return 1
  fi

  # (4) the npz library must still be intact (142,220 rows, 0 errors).
  if ! eval "$TRAIN_NPZ_VERIFY_CMD" >/dev/null 2>&1; then
    env_fail "npz-verify-failed" "the npz verifier failed: $TRAIN_NPZ_VERIFY_CMD" || return 1
    return 1
  fi

  # (5) a GPU with enough memory.
  local gpu_total
  gpu_total="$("$TRAIN_NVIDIA_SMI" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
    | tr -d ' ' | grep -E '^[0-9]+$' | sort -n | tail -n1)"
  if [ -z "$gpu_total" ]; then
    env_fail "gpu-missing" "no GPU reported by $TRAIN_NVIDIA_SMI" || return 1
    return 1
  fi
  if [ "$gpu_total" -lt "$TRAIN_MIN_GPU_MB" ]; then
    env_fail "gpu-missing" "gpu_total_mb=$gpu_total required_mb=$TRAIN_MIN_GPU_MB" || return 1
    return 1
  fi

  # (6) free disk for the checkpoints.
  local free_kb free_gb
  free_kb="$(df -Pk "$TRAIN_DISK_PATH" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -z "$free_kb" ]; then
    env_fail "disk-insufficient" "cannot measure the free space of $TRAIN_DISK_PATH" || return 1
    return 1
  fi
  free_gb=$((free_kb / 1024 / 1024))
  if [ "$free_gb" -lt "$TRAIN_MIN_FREE_GB" ]; then
    env_fail "disk-insufficient" "free_gb=$free_gb required_gb=$TRAIN_MIN_FREE_GB" || return 1
    return 1
  fi

  elog_ok "TRAIN_ENV_OK python=$python_version torch=$torch_version clips=$clips sidecars=$sidecars gpu_total_mb=$gpu_total free_gb=$free_gb"
  flush_ok_markers
  return 0
}

cmd_env() {
  elog "=== 17_train.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
  local rc=0
  env_gate || rc=1
  # The env gate has its own log file (the slice verification list names
  # logs/env/17_train_env.txt).
  if [ -f "$MAIN_LOG" ]; then
    tail -n 40 "$MAIN_LOG" >>"$ENV_LOG" 2>/dev/null || true
  fi
  return "$rc"
}

# --- start ------------------------------------------------------------------
cmd_start() {
  local state pid
  state="$(train_status_field STATE)"
  if [ "$state" = "RUNNING" ]; then
    pid="$(train_status_field PID)"
    if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      elog "worker already RUNNING (pid=$pid)"
      elog "STATUS_FILE=$STATUS_FILE"
      return 0
    fi
    # A RUNNING state whose worker is gone is STALE (the worker crashed, or
    # the milestone worktree was rebuilt under it).  Re-arming must not be
    # blocked by it: the honest move is to start a new worker, which
    # overwrites the state with its own PID.
    elog "stale RUNNING state (pid=${pid:-?} is not alive) — re-arming the worker"
  fi
  if [ ! -f "$WORKER" ]; then
    elog "TRAIN_START_FAIL reason=worker-missing path=$WORKER"
    return 1
  fi
  mkdir -p "$(dirname "$WORKER_LOG")" 2>/dev/null || true
  # The worker writes its own stdout into WORKER_LOG; the status file starts
  # as RUNNING so a `wait` has something to poll.
  train_status_write "$STATUS_FILE" "RUNNING" "0" "PID=0" "STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The worker log is APPENDED, never truncated: it is the only place that
  # holds the upstream `resumed ... at iteration N` lines and the per-iteration
  # throughput, and a re-armed worker must not erase the evidence of the
  # segments that already ran.
  {
    printf '=== re-arm %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >>"$WORKER_LOG" 2>/dev/null || true
  setsid nohup bash "$WORKER" >>"$WORKER_LOG" 2>&1 </dev/null &
  local pid=$!
  sleep 1
  elog "WORKER_PID=$pid"
  elog "STATUS_FILE=$STATUS_FILE"
  elog "WORKER_LOG=$WORKER_LOG"
  elog "poll with: bash repro/lib/remote.sh 17_train.sh status"
  return 0
}

# --- status (always exit 0) -------------------------------------------------
cmd_status() {
  elog "=== 17_train.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  if [ -f "$STATUS_FILE" ]; then
    elog "--- status file ($STATUS_FILE) ---"
    while IFS= read -r line; do elog "$line"; done <"$STATUS_FILE"
  else
    elog "STATE=ABSENT (no status file yet: $STATUS_FILE)"
  fi
  elog "--- resource peaks ($RESOURCES_CSV) ---"
  local peak
  while IFS= read -r peak; do elog "$peak"; done < <(train_resource_peaks)
  elog "--- training log tail ($WORKER_LOG) ---"
  if [ -f "$WORKER_LOG" ]; then
    tail -n 20 "$WORKER_LOG" | while IFS= read -r line; do elog "$line"; done
  else
    elog "(no worker log yet: $WORKER_LOG)"
  fi
  return 0
}

# --- wait (bounded; the worker is NEVER killed) ----------------------------
cmd_wait() {
  local timeout_s="${1:-3600}"
  local started elapsed state
  started="$(date +%s)"
  elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    state="$(train_status_field STATE)"
    case "$state" in
      DONE)
        elog "worker finished: DONE"
        return 0
        ;;
      FAILED)
        elog "worker finished: FAILED (rc=$(train_status_field RC))"
        return 1
        ;;
    esac
    sleep 5
    elapsed=$(( $(date +%s) - started ))
  done
  elog "TIMEOUT after ${timeout_s}s: the worker keeps running detached."
  elog "  bash repro/lib/remote.sh 17_train.sh status"
  return 75
}

# --- worker / verify / selftest --------------------------------------------
cmd_worker() {
  if [ ! -f "$WORKER" ]; then
    elog "TRAIN_WORKER_FAIL reason=worker-missing path=$WORKER"
    return 1
  fi
  bash "$WORKER"
  return $?
}

cmd_verify() {
  if [ ! -f "$VERIFIER" ]; then
    elog "TRAIN_VERIFY_FAIL reason=verifier-missing path=$VERIFIER"
    return 1
  fi
  # the default subcommand of the reviewer is `verify`
  if [ "$#" -eq 0 ]; then
    set -- verify
  fi
  bash "$VERIFIER" "$@"
  return $?
}

cmd_selftest() {
  local rc=0
  local t
  for t in "$REPO_ROOT/repro/tests/test_train.sh" \
           "$REPO_ROOT/repro/tests/test_train_orchestrator.sh" \
           "$REPO_ROOT/repro/tests/test_train_verify.sh" \
           "$REPO_ROOT/repro/tests/test_train_verify_tb_e2e.sh"; do
    if [ ! -f "$t" ]; then
      elog "TRAIN_SELFTEST_FAIL reason=test-missing path=$t"
      rc=1
      continue
    fi
    elog "--- selftest: $t ---"
    bash "$t" || rc=1
  done
  return "$rc"
}

cmd_smoke() {
  # T3 owns the smoke implementation (it needs the GPU).  The skeleton is
  # here so the interface is fixed; it fails closed until then.
  if [ -n "${TRAIN_SMOKE_CMD:-}" ]; then
    eval "$TRAIN_SMOKE_CMD"
    return $?
  fi
  elog "TRAIN_SMOKE_FAIL reason=smoke-not-implemented (implemented by slice task T3)"
  return 1
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  smoke)    shift || true; cmd_smoke "$@" ;;
  start)    shift || true; cmd_start "$@" ;;
  status)   shift || true; cmd_status "$@" ;;
  wait)     shift || true; cmd_wait "${1:-3600}" ;;
  worker)   shift || true; cmd_worker "$@" ;;
  verify)   shift || true; cmd_verify "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/17_train.sh <env|smoke|start|status|wait|worker|verify|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
