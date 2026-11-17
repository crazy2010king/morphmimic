#!/usr/bin/env bash
# repro/17_train_worker.sh — the DETACHED training body of the g1_amber
# formal run (slice S06).
#
# ---------------------------------------------------------------------------
# WHY A SEPARATE WORKER
#
# The formal run lasts hours.  A foreground training command inside one ssh
# session dies with the session and the whole machine budget is thrown away;
# a run without a status file leaves the resource peaks (VRAM / host RAM)
# unprovable.  So the body lives here and is started detached
# (`setsid nohup bash repro/17_train_worker.sh`, see repro/17_train.sh
# `start`): it survives the session that launched it, and it always leaves a
# terminal state behind.
#
# ---------------------------------------------------------------------------
# THE ORDER (fail-closed at every step)
#
#   1. the ENV GATE (repro/17_train.sh env) — no GPU second is spent on a
#      broken environment (venv drift, missing subset, missing sidecars,
#      broken npz library, no GPU, no disk).
#   2. the DISK GATE — the checkpoints need room.
#   3. the PLAN FILE (logs/env/17_train_plan.env, produced by the slice
#      task that measured the throughput) — ITERATIONS / LR_DECAY_ITERS /
#      CKPT_EVERY / SEGMENT_ITERS / BUDGET_SECONDS / COMPILE / NUM_ENVS /
#      HUMAN_ROOT / SUBSET_YAML.  A missing or self-inconsistent plan is a
#      hard failure: the worker never invents a training budget.
#   4. the RESOURCE SAMPLER — a background loop that appends one row every
#      30 s to logs/env/17_train_resources.csv:
#          ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,proc_rss_gb
#      (`nvidia-smi --query-gpu=memory.used,memory.total` + `free -m` +
#      /proc/<pid>/status VmRSS of the training process).
#   5. the SEGMENTED TRAINING LOOP — every segment runs the upstream
#      trainer with `--iterations <segment end>` (upstream `--iterations`
#      is "run UNTIL this iteration", trainer.py:2136 `while self.it <
#      cfg.iterations`), `--lr-decay-iters <FORMAL total>` (MEM005: the LR
#      schedule covers the WHOLE run, not a segment) and
#      `--ckpt-every <CKPT_EVERY>`.  Between two segments the run is
#      resumed from `--resume logs/train/<run>/latest.pt`; `iterations` is a
#      RESUME_FREE_FIELD (trainer.py:179), so it may grow on a resume.
#      Every segment ends with a checkpoint written by the trainer itself
#      (ckpt_<it>.pt + latest.pt) and a clean exit => the segment boundary
#      IS the resume point.
#   6. the TERMINAL STATE — the atomic status file
#      (logs/env/17_train.status: STATE / RC / ITER / TARGET_ITER /
#      IT_PER_S / GPU_PEAK_GB / HOST_PEAK_GB / ELAPSED / STARTED_AT /
#      FINISHED_AT) and the flushed marker
#      (TRAIN_TRAIN_OK ... / TRAIN_TRAIN_FAIL reason=<...>).
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES
#
#   TRAIN_ALLOW_LOCAL=1    allow running outside the ros_dev container
#   TRAIN_LOG_DIR          log directory       (default $LOG_DIR)
#   TRAIN_STATUS_FILE      status file         (default logs/env/17_train.status)
#   TRAIN_WORKER_LOG       worker stdout       (default logs/env/17_train_worker.log)
#   TRAIN_RESOURCES_CSV    resource sampler    (default logs/env/17_train_resources.csv)
#   TRAIN_PLAN_FILE        the plan file       (default logs/env/17_train_plan.env)
#   TRAIN_ENV_CMD          the env gate        (default: bash repro/17_train.sh env)
#   TRAIN_TRAIN_CMD        the training command (default: the upstream
#                          `uv run --frozen --no-sync python -m
#                           morphmimic.scripts.train ...` with the plan's
#                          values; overridable so the battery can drive the
#                          worker without a GPU)
#   TRAIN_MIN_FREE_GB      minimum free disk   (default 50)
#   TRAIN_NVIDIA_SMI       the nvidia-smi      (default nvidia-smi)
#   TRAIN_SAMPLE_INTERVAL  sampler period (s)  (default 30)
#   TRAIN_PY               the decision-base interpreter (default python3)
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

# Every failure path below is handled explicitly -> errexit off.
set +e

if [ "${TRAIN_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

cd "$REPO_ROOT" || exit 1

LOG_DIR_REAL="${TRAIN_LOG_DIR:-$LOG_DIR}"
# CANONICALISE the log directory: the worktree's `logs/` symlink can vanish
# when GSD rebuilds the milestone worktree mid-run (observed 2026-11-13: the
# status write of the crashed worker silently failed because of exactly that).
# The seed store path never moves, so the status file / worker log / sampler
# CSV keep working across a rebuild.
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
STATUS_FILE="${TRAIN_STATUS_FILE:-$LOG_DIR_REAL/17_train.status}"
WORKER_LOG="${TRAIN_WORKER_LOG:-$LOG_DIR_REAL/17_train_worker.log}"
RESOURCES_CSV="${TRAIN_RESOURCES_CSV:-$LOG_DIR_REAL/17_train_resources.csv}"
PLAN_FILE="${TRAIN_PLAN_FILE:-$LOG_DIR_REAL/17_train_plan.env}"
TRAIN_PY_BIN="${TRAIN_PY:-python3}"
TRAIN_LIB_DIR="$REPO_ROOT/repro/lib"
TRAIN_MIN_FREE_GB="${TRAIN_MIN_FREE_GB:-50}"
TRAIN_NVIDIA_SMI="${TRAIN_NVIDIA_SMI:-nvidia-smi}"
TRAIN_SAMPLE_INTERVAL="${TRAIN_SAMPLE_INTERVAL:-30}"
ENV_CMD="${TRAIN_ENV_CMD:-bash $REPO_ROOT/repro/17_train.sh env}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

# --- output -----------------------------------------------------------------
wlog() { printf '%s\n' "$*"; }

# --- the atomic status file ------------------------------------------------
# write_status <state> <rc> [KEY=VALUE ...]
# Atomic: repro/lib/train.py `write_status` writes <path>.tmp and then
# os.replace()s it, so a reader never sees a half-written status file and no
# .tmp residue is left behind.
write_status() {
  local state="$1" rc="$2"; shift 2
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
' "$TRAIN_LIB_DIR" "$STATUS_FILE" "$state" "$rc" ${extra[@]+"${extra[@]}"} 2>/dev/null
}

# fail <reason> [detail...] — the terminal failure path: the status file
# (FAILED) + the flushed fail marker.  It NEVER prints an OK marker.
fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && wlog "  $detail"
  done
  stop_sampler
  write_status "FAILED" "1" "REASON=$reason" "ELAPSED=$(( $(date +%s) - START_TS ))"
  wlog "TRAIN_TRAIN_FAIL reason=$reason"
  exit 1
}

# --- the plan ---------------------------------------------------------------
# plan_get <KEY> — the value of a KEY of the plan file.
plan_get() {
  [ -f "$PLAN_FILE" ] || return 0
  sed -n "s/^$1=//p" "$PLAN_FILE" | head -n1
}

# --- canonical paths --------------------------------------------------------
# abs_path <path> — the CANONICAL (symlink-resolved, absolute) form of a
# path.  A relative path is resolved against the repository root.
#
# WHY THIS IS NOT COSMETIC (observed 2026-11-13, segment 7):
# GSD rebuilds the milestone worktree while a DETACHED run is in flight, and
# the rebuild drops the worktree's `data/` and `logs/` symlinks into the seed
# store.  A trainer that still holds the RELATIVE `--log-dir logs/train`
# then writes its tensorboard events into a directory that no longer
# resolves -> `FileNotFoundError` in the tensorboard writer thread -> the
# segment dies with rc=1 at iteration 18800 (the checkpoints were safe: they
# live in the store).  Canonicalising every path ONCE, up front, points the
# trainer at the SEED STORE location, which no worktree lifecycle touches.
abs_path() {
  local p="$1"
  [ -n "$p" ] || return 0
  case "$p" in
    /*) printf '%s' "$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")" ;;
    *)  printf '%s' "$(readlink -f "$REPO_ROOT/$p" 2>/dev/null || printf '%s' "$REPO_ROOT/$p")" ;;
  esac
}

# store_path <relative path under the repo> — the SAME path, but resolved
# through the SEED STORE instead of through the worktree.  The store is
# outside every git worktree, so this path keeps working even when the
# milestone worktree (and its `logs/` / `data/` symlinks) is rebuilt
# under a running job.
store_path() {
  local p="$1"
  if [ -n "${SEED_STORE_ROOT:-}" ] && [ -d "$SEED_STORE_ROOT/$p" ]; then
    printf '%s' "$SEED_STORE_ROOT/$p"
    return 0
  fi
  abs_path "$p"
}

# --- the resource sampler ---------------------------------------------------
SAMPLER_PID=""

# sample_once — one CSV row: ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,
# host_avail_gb,proc_rss_gb.
sample_once() {
  local ts iter gpu_line gpu_used gpu_total host_line host_used host_avail rss pid
  ts="$(date +%s)"
  iter="$(current_iteration)"
  gpu_line="$("$TRAIN_NVIDIA_SMI" --query-gpu=memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  gpu_used="$(printf '%s' "$gpu_line" | cut -d, -f1 | tr -d ' ')"
  gpu_total="$(printf '%s' "$gpu_line" | cut -d, -f2 | tr -d ' ')"
  host_line="$(free -m 2>/dev/null | awk '/^Mem:/ {print $3, $7}')"
  host_used="$(printf '%s' "$host_line" | awk '{print $1}')"
  host_avail="$(printf '%s' "$host_line" | awk '{print $2}')"
  pid="$(pgrep -f 'morphmimic.scripts.train' 2>/dev/null | head -n1)"
  rss=""
  if [ -n "$pid" ] && [ -r "/proc/$pid/status" ]; then
    rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
  fi
  # Empty fields become 0 so the CSV parser never sees a broken row.
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "${iter:-0}" "${gpu_used:-0}" "${gpu_total:-0}" \
    "$(( ${host_used:-0} / 1024 ))" "$(( ${host_avail:-0} / 1024 ))" \
    "$(( ${rss:-0} / 1024 / 1024 ))"
}

# current_iteration — the highest iteration the upstream trainer printed so
# far (the training stdout is the worker log).
current_iteration() {
  local it
  [ -f "$WORKER_LOG" ] || { echo 0; return 0; }
  it="$(grep -aoE '\[morphmimic\] it [0-9]+' "$WORKER_LOG" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -n | tail -n1)"
  printf '%s' "${it:-0}"
}

start_sampler() {
  # The CSV is APPENDED across re-arms (only the header is written when the
  # file does not exist yet): the resource peaks are the evidence of the
  # whole formal run, and a re-armed worker must not erase the peaks of the
  # segments that already ran.
  if [ ! -s "$RESOURCES_CSV" ]; then
    printf 'ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,proc_rss_gb\n' \
      >"$RESOURCES_CSV"
  fi
  (
    while :; do
      sample_once >>"$RESOURCES_CSV" 2>/dev/null
      sleep "$TRAIN_SAMPLE_INTERVAL"
    done
  ) >/dev/null 2>&1 &
  SAMPLER_PID=$!
  wlog "resource sampler started (pid=$SAMPLER_PID, period=${TRAIN_SAMPLE_INTERVAL}s, csv=$RESOURCES_CSV)"
}

stop_sampler() {
  [ -n "$SAMPLER_PID" ] || return 0
  kill "$SAMPLER_PID" 2>/dev/null
  wait "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=""
}

# resource_peaks — the peaks of the sampler CSV (the decision base parses it).
resource_peaks() {
  "$TRAIN_PY_BIN" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
summary = train.parse_resource_csv(sys.argv[2])
if summary is None:
    print("0 0")
else:
    print("%.0f %.2f" % (summary["gpu_used_mb_peak"] or 0,
                         summary["host_used_gb_peak"] or 0))
' "$TRAIN_LIB_DIR" "$RESOURCES_CSV" 2>/dev/null
}

# --- start ------------------------------------------------------------------
START_TS="$(date +%s)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
wlog "=== 17_train_worker.sh $STARTED_AT ==="
wlog "REPO_ROOT=$REPO_ROOT"
wlog "PID=$$"

write_status "RUNNING" "0" "PID=$$" "STARTED_AT=$STARTED_AT"

# --- 1) the env gate --------------------------------------------------------
wlog "--- step 1: env gate ---"
env_out="$(eval "$ENV_CMD" 2>&1)"
env_rc=$?
printf '%s\n' "$env_out"
if [ "$env_rc" -ne 0 ]; then
  fail "env-gate-failed" "the env gate did not pass; see the output above"
fi
wlog "### STEP env_gate DONE"

# --- 2) the disk gate -------------------------------------------------------
wlog "--- step 2: disk gate ---"
DISK_PATH="${TRAIN_DISK_PATH:-$REPO_ROOT/data/seed_g1_npz50}"
free_kb="$(df -Pk "$DISK_PATH" 2>/dev/null | awk 'NR==2 {print $4}')"
free_gb=$(( ${free_kb:-0} / 1024 / 1024 ))
if [ "$free_gb" -lt "$TRAIN_MIN_FREE_GB" ]; then
  fail "disk-insufficient" "free_gb=$free_gb required_gb=$TRAIN_MIN_FREE_GB path=$DISK_PATH"
fi
wlog "    free_gb=$free_gb (>= $TRAIN_MIN_FREE_GB)"
wlog "### STEP disk_gate DONE"

# --- 3) the plan ------------------------------------------------------------
wlog "--- step 3: the plan file ---"
if [ ! -f "$PLAN_FILE" ]; then
  fail "plan-missing" "PATH=$PLAN_FILE"
fi
ITERATIONS="$(plan_get ITERATIONS)"
LR_DECAY_ITERS="$(plan_get LR_DECAY_ITERS)"
CKPT_EVERY="$(plan_get CKPT_EVERY)"
SEGMENT_ITERS="$(plan_get SEGMENT_ITERS)"
BUDGET_SECONDS="$(plan_get BUDGET_SECONDS)"
COMPILE="$(plan_get COMPILE)"
NUM_ENVS="$(plan_get NUM_ENVS)"
HUMAN_ROOT="$(plan_get HUMAN_ROOT)"
SUBSET_YAML="$(plan_get SUBSET_YAML)"
RUN_NAME="$(plan_get RUN_NAME)"
ROBOT="$(plan_get ROBOT)"
TRAIN_LOG_DIR="$(plan_get TRAIN_LOG_DIR)"

: "${COMPILE:=none}"
: "${NUM_ENVS:=1024}"
: "${RUN_NAME:=g1_amber_1h}"
: "${ROBOT:=g1_amber}"
: "${TRAIN_LOG_DIR:=logs/train}"

if ! printf '%s' "$ITERATIONS" | grep -qE '^[0-9]+$' || [ "$ITERATIONS" -le 0 ]; then
  fail "plan-invalid" "ITERATIONS='$ITERATIONS' is not a positive integer (file=$PLAN_FILE)"
fi
if ! printf '%s' "$LR_DECAY_ITERS" | grep -qE '^[0-9]+$' || [ "$LR_DECAY_ITERS" -le 0 ]; then
  fail "plan-invalid" "LR_DECAY_ITERS='$LR_DECAY_ITERS' is not a positive integer (file=$PLAN_FILE)"
fi
if [ "$LR_DECAY_ITERS" != "$ITERATIONS" ]; then
  fail "plan-inconsistent" "LR_DECAY_ITERS=$LR_DECAY_ITERS must equal ITERATIONS=$ITERATIONS (MEM005)"
fi
if ! printf '%s' "$CKPT_EVERY" | grep -qE '^[0-9]+$' || [ "$CKPT_EVERY" -lt 1000 ]; then
  fail "plan-invalid" "CKPT_EVERY='$CKPT_EVERY' must be >= 1000 (file=$PLAN_FILE)"
fi
if [ $(( CKPT_EVERY % 1000 )) -ne 0 ]; then
  fail "plan-invalid" "CKPT_EVERY=$CKPT_EVERY must be a multiple of 1000 (file=$PLAN_FILE)"
fi
if ! printf '%s' "$SEGMENT_ITERS" | grep -qE '^[0-9]+$' || [ "$SEGMENT_ITERS" -le 0 ]; then
  fail "plan-invalid" "SEGMENT_ITERS='$SEGMENT_ITERS' is not a positive integer (file=$PLAN_FILE)"
fi
if [ -z "$SUBSET_YAML" ] || [ -z "$HUMAN_ROOT" ]; then
  fail "plan-invalid" "SUBSET_YAML/HUMAN_ROOT must be set in $PLAN_FILE"
fi
wlog "    ITERATIONS=$ITERATIONS LR_DECAY_ITERS=$LR_DECAY_ITERS CKPT_EVERY=$CKPT_EVERY"
wlog "    SEGMENT_ITERS=$SEGMENT_ITERS BUDGET_SECONDS=${BUDGET_SECONDS:-0} COMPILE=$COMPILE NUM_ENVS=$NUM_ENVS"
wlog "### STEP plan DONE"

# --- 3b) the canonical paths ------------------------------------------------
# Every path the trainer touches is canonicalised here, ONCE: the worktree's
# `data/` and `logs/` symlinks may vanish mid-run (a GSD worktree rebuild),
# but the SEED STORE paths they point at never do.
TRAIN_LOG_DIR_ABS="$(store_path "$TRAIN_LOG_DIR")"
SUBSET_YAML_ABS="$(store_path "$SUBSET_YAML")"
HUMAN_ROOT_ABS="$(store_path "$HUMAN_ROOT")"
wlog "    train_log_dir=$TRAIN_LOG_DIR_ABS"
wlog "    subset_yaml=$SUBSET_YAML_ABS"
wlog "    human_root=$HUMAN_ROOT_ABS"

# --- 4) the resource sampler ------------------------------------------------
wlog "--- step 4: resource sampler ---"
start_sampler

# --- 5) the segmented training loop ----------------------------------------
wlog "--- step 5: segmented training ---"
RUN_DIR="${TRAIN_RUN_DIR:-$TRAIN_LOG_DIR_ABS/$RUN_NAME}"
RESUME_PATH="$RUN_DIR/latest.pt"
CURRENT=0
SEGMENT_INDEX=0

# CURRENT — the iteration the run has ALREADY reached.  A re-armed worker
# must not replay the segments that the checkpoints already cover: the
# trainer runs "UNTIL --iterations", so a segment whose target is below the
# resumed iteration is a no-op that still pays the startup cost.  The
# authoritative source is the checkpoint FILE NAMES in the run directory
# (ckpt_<it>.pt); `latest.pt` is the resume point.
if [ -d "$RUN_DIR" ]; then
  for ckpt_file in "$RUN_DIR"/ckpt_*.pt; do
    [ -f "$ckpt_file" ] || continue
    ckpt_it="${ckpt_file##*/ckpt_}"
    ckpt_it="${ckpt_it%.pt}"
    case "$ckpt_it" in ''|*[!0-9]*) continue ;; esac
    [ "$ckpt_it" -gt "$CURRENT" ] && CURRENT="$ckpt_it"
  done
fi
if [ "$CURRENT" -gt 0 ] && [ ! -f "$RESUME_PATH" ]; then
  fail "checkpoint-missing" \
    "the run directory holds ckpt_* up to iteration $CURRENT but the resume point $RESUME_PATH is missing" \
    "the run cannot continue without its resume point"
fi
if [ "$CURRENT" -gt 0 ]; then
  wlog "    resuming from iteration $CURRENT (resume point: $RESUME_PATH)"
fi

while [ "$CURRENT" -lt "$ITERATIONS" ]; do
  SEGMENT_INDEX=$((SEGMENT_INDEX + 1))
  SEG_END=$((CURRENT + SEGMENT_ITERS))
  if [ "$SEG_END" -gt "$ITERATIONS" ]; then
    SEG_END="$ITERATIONS"
  fi
  if [ -f "$RESUME_PATH" ]; then
    RESUME_ARG="--resume $RESUME_PATH"
  else
    RESUME_ARG=""
  fi
  wlog "### SEGMENT $SEGMENT_INDEX: iterations $CURRENT -> $SEG_END (resume='${RESUME_ARG:-none}')"

  if [ -n "${TRAIN_TRAIN_CMD:-}" ]; then
    # The battery drives the worker with a stub command.
    train_cmd="$TRAIN_TRAIN_CMD"
  else
    train_cmd="uv run --frozen --no-sync python -m morphmimic.scripts.train \
--robot $ROBOT \
--subset-yaml $SUBSET_YAML_ABS \
--human-root $HUMAN_ROOT_ABS \
--kp-interface \
--kp-student copy \
--no-kp-preview-mix \
--library-dtype float16 \
--num-envs $NUM_ENVS \
--compile $COMPILE \
--iterations $SEG_END \
--lr-decay-iters $ITERATIONS \
--ckpt-every $CKPT_EVERY \
--log-every 50 \
--wm-only-iters 500 \
--log-dir $TRAIN_LOG_DIR_ABS \
--run-name $RUN_NAME \
$RESUME_ARG"
  fi

  wlog "### RUN $(date -u +%Y-%m-%dT%H:%M:%SZ): $train_cmd"
  eval "$train_cmd"
  seg_rc=$?
  wlog "### EXIT $seg_rc: segment $SEGMENT_INDEX"
  if [ "$seg_rc" -ne 0 ]; then
    fail "segment-failed" "segment=$SEGMENT_INDEX rc=$seg_rc target=$SEG_END"
  fi
  CURRENT="$SEG_END"
done
wlog "### STEP training DONE"

# --- 6) the terminal state --------------------------------------------------
stop_sampler
ELAPSED=$(( $(date +%s) - START_TS ))
FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

peaks="$(resource_peaks)"
GPU_PEAK_MB="$(printf '%s' "$peaks" | awk '{print $1}')"
HOST_PEAK_GB="$(printf '%s' "$peaks" | awk '{print $2}')"
GPU_PEAK_GB="$(awk -v mb="${GPU_PEAK_MB:-0}" 'BEGIN {printf "%.2f", mb / 1024}')"

# The mean throughput of the whole run (the decision base parses the log).
IT_PER_S="$(bash "$REPO_ROOT/repro/lib/train.sh" log-summary "$WORKER_LOG" 2>/dev/null \
  | "$TRAIN_PY_BIN" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("0")
    raise SystemExit(0)
values = data.get("it_per_s") or []
print("%.4f" % (sum(values) / len(values)) if values else "0")
')"

write_status "DONE" "0" \
  "ITER=$ITERATIONS" \
  "TARGET_ITER=$ITERATIONS" \
  "IT_PER_S=${IT_PER_S:-0}" \
  "GPU_PEAK_MB=${GPU_PEAK_MB:-0}" \
  "GPU_PEAK_GB=${GPU_PEAK_GB:-0}" \
  "HOST_PEAK_GB=${HOST_PEAK_GB:-0}" \
  "ELAPSED=$ELAPSED" \
  "FINISHED_AT=$FINISHED_AT"

wlog "TRAIN_TRAIN_OK iterations=$ITERATIONS it_per_s=${IT_PER_S:-0} gpu_peak_gb=${GPU_PEAK_GB:-0} host_peak_gb=${HOST_PEAK_GB:-0} elapsed_s=$ELAPSED"
exit 0
