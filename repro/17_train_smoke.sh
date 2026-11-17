#!/usr/bin/env bash
# repro/17_train_smoke.sh — the measurement driver of slice S06 / task T4.
#
# It measures the ACTUAL throughput / memory of the g1_amber training run on
# the remote ros_dev container (RTX 4090) and turns the measurement into the
# formal-run PLAN FILE (logs/env/17_train_plan.env) that
# repro/17_train_worker.sh consumes in T5.
#
# STAGES (every stage is idempotent: it first checks its own artefacts and
# only then decides to run):
#
#   env     the env gate (repro/17_train.sh env).  ONE bounded repair is
#           allowed: `uv sync --frozen --offline --group export --group
#           teleop` (offline, no proxy, timeout 900 s).  A second failure is
#           terminal (reason=env-gate-failed) -- the script never invents a
#           working environment.
#   smoke   2000 iterations, --compile none, run dir logs/train/smoke_2k,
#           hard timeout 5400 s.  Produces TRAIN_SMOKE_OK iters=... it_per_s=
#           ... gpu_peak_mb=... host_peak_gb=... ckpt_mb=... elapsed_s=...
#           (or TRAIN_SMOKE_FAIL reason=timeout|error|env-gate-failed).
#   cmp     200 iterations, --compile reduce-overhead, run dir
#           logs/train/smoke_cmp_200, hard timeout 1800 s.  Produces
#           COMPILE_CMP_OK ... or COMPILE_CMP_FAIL reason=oom|compile-error|
#           timeout|other (exactly one of the two is always written).
#   batch   OPTIONAL --imag-batch 2048 --kp-imag-batch 2048 probe; it runs
#           ONLY when the smoke peak is over 22000 MB, otherwise
#           BATCH_PROBE_SKIPPED reason=peak-below-budget is written.
#   plan    the plan file (ITERATIONS / LR_DECAY_ITERS / CKPT_EVERY /
#           SEGMENT_ITERS / ...), computed with repro/lib/train.py only, plus
#           the self-check (PLAN_WRITTEN / PLAN_SELF_CHECK).
#
# SUB-COMMANDS
#
#   start   launch the driver DETACHED (returns in seconds)
#   status  print the state / markers / log tail (always exits 0)
#   run     the driver body (the stage machine) -- started detached by
#           `start`; it survives the ssh session that launched it.
#
# All decisions go through repro/lib/train.py (MEM059: one parser only).
#
# ENVIRONMENT OVERRIDES
#
#   SMOKE_ALLOW_LOCAL=1     allow running outside the ros_dev container
#   SMOKE_LOG_DIR           log dir        (default $LOG_DIR)
#   SMOKE_ITERS             smoke iters    (default 2000)
#   SMOKE_CMP_ITERS         cmp iters      (default 200)
#   SMOKE_TIMEOUT           smoke timeout  (default 5400)
#   SMOKE_CMP_TIMEOUT       cmp timeout    (default 1800)
#   SMOKE_WM_ONLY_ITERS     warm-up iters  (default 500)
#   SMOKE_BUDGET_SECONDS    plan budget    (default 28800)
#   SMOKE_PROBE_IT_PER_S    probe it/s     (default 1.09)
#   SMOKE_GPU_TRIGGER_MB    batch-probe trigger (default 22000)
#   SMOKE_SEGMENT_MAX_SECONDS  max wall clock of one segment (default 3600)
#   SMOKE_PLAN_FILE         the plan file  (default logs/env/17_train_plan.env)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

set +e

CMD="${1:-status}"

if [ "$CMD" != "status" ] && [ "${SMOKE_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

cd "$REPO_ROOT" || exit 1

LOG_DIR_REAL="${SMOKE_LOG_DIR:-$LOG_DIR}"
STATE_FILE="${SMOKE_STATE_FILE:-$LOG_DIR_REAL/17_train_smoke.state}"
MARKER_FILE="${SMOKE_MARKER_FILE:-$LOG_DIR_REAL/17_train_smoke.txt}"
RES_CSV="${SMOKE_RESOURCES_CSV:-$LOG_DIR_REAL/17_train_smoke_resources.csv}"
CMP_CSV="${SMOKE_CMP_RESOURCES_CSV:-$LOG_DIR_REAL/17_train_smoke_cmp_resources.csv}"
TRAIN_LOG="${SMOKE_TRAIN_LOG:-$LOG_DIR_REAL/17_train_smoke_train.log}"
CMP_LOG="${SMOKE_CMP_LOG:-$LOG_DIR_REAL/17_train_smoke_cmp.log}"
DRIVER_LOG="${SMOKE_DRIVER_LOG:-$LOG_DIR_REAL/17_train_smoke_driver.log}"
PLAN_FILE="${SMOKE_PLAN_FILE:-$LOG_DIR_REAL/17_train_plan.env}"
TRAIN_LIB="$REPO_ROOT/repro/lib"
TRAIN_PY="${TRAIN_PY:-python3}"
NPROC="${SMOKE_NVIDIA_SMI:-nvidia-smi}"

SMOKE_ITERS="${SMOKE_ITERS:-2000}"
CMP_ITERS="${SMOKE_CMP_ITERS:-200}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-5400}"
CMP_TIMEOUT="${SMOKE_CMP_TIMEOUT:-1800}"
WM_ONLY_ITERS="${SMOKE_WM_ONLY_ITERS:-500}"
BUDGET_SECONDS="${SMOKE_BUDGET_SECONDS:-28800}"
PROBE_IT_PER_S="${SMOKE_PROBE_IT_PER_S:-1.09}"
GPU_TRIGGER_MB="${SMOKE_GPU_TRIGGER_MB:-22000}"
SEGMENT_MAX_SECONDS="${SMOKE_SEGMENT_MAX_SECONDS:-3600}"
SAMPLE_INTERVAL="${SMOKE_SAMPLE_INTERVAL:-30}"

ROBOT="${SMOKE_ROBOT:-g1_amber}"
SUBSET_YAML="${SMOKE_SUBSET_YAML:-data/seed_g1_npz50/subsets/1h.yaml}"
HUMAN_ROOT="${SMOKE_HUMAN_ROOT:-data/seed_g1_npz50/human50}"
TRAIN_LOG_DIR="${SMOKE_TRAIN_LOG_DIR:-logs/train}"
RUN_NAME="${SMOKE_RUN_NAME:-g1_amber_1h}"
NUM_ENVS="${SMOKE_NUM_ENVS:-1024}"
LIBRARY_DTYPE="${SMOKE_LIBRARY_DTYPE:-float16}"
LOG_EVERY="${SMOKE_LOG_EVERY:-50}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

wlog() { printf '%s\n' "$*"; }

marker() { printf '%s\n' "$*" >>"$MARKER_FILE" 2>/dev/null; }

has_marker() { grep -qF "$1" "$MARKER_FILE" 2>/dev/null; }

# --- the atomic state file -------------------------------------------------
write_state() {
  local state="$1" rc="$2"; shift 2
  "$TRAIN_PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
extra = {}
for kv in sys.argv[5:]:
    key, _, value = kv.partition("=")
    if key:
        extra[key] = value
train.write_status(sys.argv[2], sys.argv[3], sys.argv[4], extra)
' "$TRAIN_LIB" "$STATE_FILE" "$state" "$rc" "$@" 2>/dev/null
}

state_get() {
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | head -n1
}

# --- the resource sampler ---------------------------------------------------
SAMPLER_PID=""

current_iteration() {
  local it
  [ -f "$1" ] || { echo 0; return 0; }
  it="$(grep -aoE '\[morphmimic\] it [0-9]+' "$1" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -n | tail -n1)"
  printf '%s' "${it:-0}"
}

sample_once() {
  local log="$1" ts iter gpu_line gpu_used gpu_total host_line host_used host_avail rss pid
  ts="$(date +%s)"
  iter="$(current_iteration "$log")"
  gpu_line="$("$NPROC" --query-gpu=memory.used,memory.total \
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
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "${iter:-0}" "${gpu_used:-0}" "${gpu_total:-0}" \
    "$(( ${host_used:-0} / 1024 ))" "$(( ${host_avail:-0} / 1024 ))" \
    "$(( ${rss:-0} / 1024 / 1024 ))"
}

start_sampler() {
  local csv="$1" log="$2"
  printf 'ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,proc_rss_gb\n' >"$csv"
  (
    while :; do
      sample_once "$log" >>"$csv" 2>/dev/null
      sleep "$SAMPLE_INTERVAL"
    done
  ) >/dev/null 2>&1 &
  SAMPLER_PID=$!
}

stop_sampler() {
  [ -n "$SAMPLER_PID" ] || return 0
  kill "$SAMPLER_PID" 2>/dev/null
  wait "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=""
}

# --- the interpreter --------------------------------------------------------
PY_BIN=""
resolve_python() {
  if [ -n "${SMOKE_PYTHON_BIN:-}" ]; then
    PY_BIN="$SMOKE_PYTHON_BIN"
    return 0
  fi
  if [ -x "$REPO_ROOT/.venv/bin/python" ] && \
     "$REPO_ROOT/.venv/bin/python" -c 'import torch' >/dev/null 2>&1; then
    PY_BIN="$REPO_ROOT/.venv/bin/python"
    return 0
  fi
  PY_BIN="uv run --frozen --no-sync python"
  return 0
}

# --- the training command ---------------------------------------------------
# train_cmd <run-name> <iterations> <compile> <ckpt-every> <wm-only-iters> [extra...]
train_cmd() {
  local run_name="$1" iterations="$2" compile_mode="$3" ckpt_every="$4" wm_only="$5"
  shift 5
  printf '%s' "$PY_BIN -m morphmimic.scripts.train"
  printf ' --robot %s' "$ROBOT"
  printf ' --subset-yaml %s' "$SUBSET_YAML"
  printf ' --human-root %s' "$HUMAN_ROOT"
  printf ' --kp-interface --kp-student copy --no-kp-preview-mix'
  printf ' --library-dtype %s' "$LIBRARY_DTYPE"
  printf ' --num-envs %s' "$NUM_ENVS"
  printf ' --compile %s' "$compile_mode"
  printf ' --iterations %s' "$iterations"
  printf ' --wm-only-iters %s' "$wm_only"
  printf ' --ckpt-every %s' "$ckpt_every"
  printf ' --log-every %s' "$LOG_EVERY"
  printf ' --log-dir %s' "$TRAIN_LOG_DIR"
  printf ' --run-name %s' "$run_name"
  local extra
  for extra in "$@"; do
    printf ' %s' "$extra"
  done
}

# --- the log statistics (repro/lib/train.py is the ONLY parser) -------------
# log_stats <log-file> <wm-only-iters> -> "it_per_s mem_gb_peak max_it samples"
log_stats() {
  "$TRAIN_PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
log_path = sys.argv[2]
wm_only = int(sys.argv[3])
values = []
mem = None
max_it = 0
try:
    handle = open(log_path, "r", encoding="utf-8", errors="replace")
except OSError:
    handle = None
if handle is not None:
    with handle:
        for raw in handle:
            parsed = train.parse_log_line(raw)
            if not parsed:
                continue
            if parsed["it"] > max_it:
                max_it = parsed["it"]
            if parsed["it"] <= wm_only:
                continue
            values.append(parsed["it_per_s"])
            if parsed["mem_gb"] is not None and (mem is None or parsed["mem_gb"] > mem):
                mem = parsed["mem_gb"]
mean = (sum(values) / len(values)) if values else 0.0
print("%.4f %.2f %d %d" % (mean, mem or 0.0, max_it, len(values)))
' "$TRAIN_LIB" "$1" "$2" 2>/dev/null
}

# --- the plan file ----------------------------------------------------------
# write_plan <it-per-s> <source: probe|smoke>
write_plan() {
  "$TRAIN_PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
lib, plan_path, itps_text, source = sys.argv[1:5]
segment_max = float(sys.argv[5])
budget = float(sys.argv[6])
itps = float(itps_text)
iterations = train.plan_iterations(budget, itps, train.DEFAULT_FACTOR)
lr_decay = train.plan_lr_decay_iters(iterations)
ckpt_every = train.plan_ckpt_every(iterations, train.DEFAULT_MIN_CKPTS)
max_iters = int(segment_max * itps)
if max_iters < train.CKPT_GRID:
    max_iters = train.CKPT_GRID
if ckpt_every > max_iters:
    ckpt_every = (max_iters // train.CKPT_GRID) * train.CKPT_GRID
    if ckpt_every < train.CKPT_GRID:
        ckpt_every = train.CKPT_GRID
while ckpt_every > train.CKPT_GRID and train.ckpt_count(iterations, ckpt_every) < train.DEFAULT_MIN_CKPTS:
    ckpt_every -= train.CKPT_GRID
segments = max(1, max_iters // ckpt_every)
segment_iters = ckpt_every * segments
lines = [
    "ITERATIONS=%d" % iterations,
    "LR_DECAY_ITERS=%d" % lr_decay,
    "CKPT_EVERY=%d" % ckpt_every,
    "SEGMENT_ITERS=%d" % segment_iters,
    "BUDGET_SECONDS=%d" % int(budget),
    "COMPILE=none",
    "NUM_ENVS=%s" % sys.argv[7],
    "HUMAN_ROOT=%s" % sys.argv[8],
    "SUBSET_YAML=%s" % sys.argv[9],
    "RUN_NAME=%s" % sys.argv[10],
    "ROBOT=%s" % sys.argv[11],
    "TRAIN_LOG_DIR=%s" % sys.argv[12],
    "PYTHON_BIN=%s" % sys.argv[13],
    "IT_PER_S_MEASURED=%.4f" % itps,
    "IT_PER_S_SOURCE=%s" % source,
    "LIBRARY_DTYPE=%s" % sys.argv[14],
    "CKPT_COUNT=%d" % train.ckpt_count(iterations, ckpt_every),
    "WM_ONLY_ITERS=%s" % sys.argv[15],
    "LOG_EVERY=%s" % sys.argv[16],
]
with open(plan_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
print("iterations=%d ckpt_every=%d segment_iters=%d ckpt_count=%d" % (
    iterations, ckpt_every, segment_iters, train.ckpt_count(iterations, ckpt_every)))
' "$TRAIN_LIB" "$PLAN_FILE" "$1" "$2" "$SEGMENT_MAX_SECONDS" "$BUDGET_SECONDS" \
  "$NUM_ENVS" "$HUMAN_ROOT" "$SUBSET_YAML" "$RUN_NAME" "$ROBOT" "$TRAIN_LOG_DIR" \
  "$PY_BIN" "$LIBRARY_DTYPE" "$WM_ONLY_ITERS" "$LOG_EVERY" 2>/dev/null
}

# plan_self_check — re-derives the plan from the plan file with train.py.
plan_self_check() {
  "$TRAIN_PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
plan_path = sys.argv[2]
values = {}
with open(plan_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
iterations = int(values["ITERATIONS"])
lr_decay = int(values["LR_DECAY_ITERS"])
ckpt_every = int(values["CKPT_EVERY"])
segment_iters = int(values["SEGMENT_ITERS"])
assert lr_decay == iterations, values
assert iterations == train.plan_lr_decay_iters(iterations), values
assert ckpt_every >= train.CKPT_GRID and ckpt_every % train.CKPT_GRID == 0, values
assert train.ckpt_count(iterations, ckpt_every) >= train.DEFAULT_MIN_CKPTS, values
assert segment_iters % ckpt_every == 0, values
assert values["COMPILE"] == "none", values
assert values["NUM_ENVS"] == "1024", values
assert values["TRAIN_LOG_DIR"] and values["SUBSET_YAML"] and values["HUMAN_ROOT"], values
assert values["RUN_NAME"] and values["ROBOT"], values
print("PLAN_OK iterations=%d ckpt_every=%d segment_iters=%d ckpt_count=%d" % (
    iterations, ckpt_every, segment_iters, train.ckpt_count(iterations, ckpt_every)))
' "$TRAIN_LIB" "$PLAN_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# the stages
# ---------------------------------------------------------------------------

stage_env() {
  local out rc
  wlog "--- stage env ---"
  out="$(bash "$REPO_ROOT/repro/17_train.sh" env 2>&1)"
  rc=$?
  printf '%s\n' "$out" | tail -n 20
  if [ "$rc" -ne 0 ]; then
    local repair_marker="$LOG_DIR_REAL/17_train_smoke_env_repair.done"
    if [ ! -f "$repair_marker" ]; then
      wlog "env gate failed; ONE bounded offline repair: uv sync --frozen --offline"
      marker "SMOKE_ENV_REPAIR start"
      ( unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        timeout 900 uv sync --frozen --offline --group export --group teleop ) \
        >>"$LOG_DIR_REAL/17_train_smoke_env_repair.log" 2>&1
      printf 'done\n' >"$repair_marker"
      out="$(bash "$REPO_ROOT/repro/17_train.sh" env 2>&1)"
      rc=$?
      printf '%s\n' "$out" | tail -n 20
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    marker "TRAIN_SMOKE_FAIL reason=env-gate-failed"
    write_state "FAILED" "1" "STAGE=failed" "REASON=env-gate-failed"
    wlog "TRAIN_SMOKE_FAIL reason=env-gate-failed"
    return 1
  fi
  wlog "### stage env DONE"
  return 0
}

# run_training <run-name> <iters> <compile> <ckpt-every> <wm-only> <log> <csv> <timeout>
# echoes "<rc> <compile_s> <elapsed_s>"
run_training() {
  local run_name="$1" iterations="$2" compile_mode="$3" ckpt_every="$4" wm_only="$5"
  local log="$6" csv="$7" timeout_s="$8"
  local cmd start_ts first_ts compile_s rc
  cmd="$(train_cmd "$run_name" "$iterations" "$compile_mode" "$ckpt_every" "$wm_only")"
  start_ts="$(date +%s)"
  : >"$log"
  start_sampler "$csv" "$log"
  ( PYTHONUNBUFFERED=1 timeout --signal=TERM "$timeout_s" $cmd ) >>"$log" 2>&1 &
  local pid=$!
  compile_s=""
  while kill -0 "$pid" 2>/dev/null; do
    if grep -aq '\[morphmimic\] it ' "$log" 2>/dev/null; then
      first_ts="$(date +%s)"
      compile_s=$(( first_ts - start_ts ))
      break
    fi
    sleep 2
  done
  wait "$pid"
  rc=$?
  stop_sampler
  printf '%s %s %s' "$rc" "${compile_s:-0}" "$(( $(date +%s) - start_ts ))"
}

stage_smoke() {
  local run_name="smoke_2k" ckpt_every=1000
  local rc compile_s elapsed stats itps mem_gb max_it samples gpu_peak host_peak ckpt_mb
  wlog "--- stage smoke (${SMOKE_ITERS} iterations, --compile none) ---"
  write_state "RUNNING" "0" "STAGE=smoke" "ITERATIONS=$SMOKE_ITERS"
  stats="$(run_training "$run_name" "$SMOKE_ITERS" none "$ckpt_every" "$WM_ONLY_ITERS" \
    "$TRAIN_LOG" "$RES_CSV" "$SMOKE_TIMEOUT")"
  rc="$(printf '%s' "$stats" | awk '{print $1}')"
  compile_s="$(printf '%s' "$stats" | awk '{print $2}')"
  elapsed="$(printf '%s' "$stats" | awk '{print $3}')"
  stats="$(log_stats "$TRAIN_LOG" "$WM_ONLY_ITERS")"
  itps="$(printf '%s' "$stats" | awk '{print $1}')"
  mem_gb="$(printf '%s' "$stats" | awk '{print $2}')"
  max_it="$(printf '%s' "$stats" | awk '{print $3}')"
  samples="$(printf '%s' "$stats" | awk '{print $4}')"
  gpu_peak="$(resource_peaks "$RES_CSV" | awk '{print $1}')"
  host_peak="$(resource_peaks "$RES_CSV" | awk '{print $2}')"
  ckpt_mb="$(ckpt_size_mb "$TRAIN_LOG_DIR/$run_name")"
  wlog "smoke rc=$rc it_per_s=$itps mem_gb=$mem_gb max_it=$max_it samples=$samples gpu_peak_mb=$gpu_peak host_peak_gb=$host_peak ckpt_mb=$ckpt_mb elapsed=$elapsed"
  if [ "$rc" = "124" ]; then
    marker "TRAIN_SMOKE_FAIL reason=timeout"
    marker "SMOKE_DETAIL iters_done=$max_it it_per_s=$itps gpu_peak_mb=$gpu_peak host_peak_gb=$host_peak elapsed_s=$elapsed"
    write_state "FAILED" "1" "STAGE=failed" "REASON=timeout" "MAX_ITER=$max_it" "ELAPSED=$elapsed"
    return 1
  fi
  if [ "$rc" != "0" ] || [ "$max_it" -lt "$SMOKE_ITERS" ] || [ "$samples" -le 0 ]; then
    marker "TRAIN_SMOKE_FAIL reason=error"
    marker "SMOKE_DETAIL rc=$rc iters_done=$max_it it_per_s=$itps gpu_peak_mb=$gpu_peak host_peak_gb=$host_peak elapsed_s=$elapsed"
    write_state "FAILED" "1" "STAGE=failed" "REASON=error" "RC=$rc" "MAX_ITER=$max_it" "ELAPSED=$elapsed"
    return 1
  fi
  marker "TRAIN_SMOKE_OK iters=$SMOKE_ITERS it_per_s=$itps gpu_peak_mb=$gpu_peak host_peak_gb=$host_peak ckpt_mb=$ckpt_mb elapsed_s=$elapsed"
  write_state "RUNNING" "0" "STAGE=smoke-ok" "IT_PER_S=$itps" "GPU_PEAK_MB=$gpu_peak" \
    "HOST_PEAK_GB=$host_peak" "CKPT_MB=$ckpt_mb" "ELAPSED=$elapsed"
  SMOKE_IT_PER_S="$itps"
  SMOKE_GPU_PEAK_MB="$gpu_peak"
  return 0
}

stage_cmp() {
  local run_name="smoke_cmp_200" ckpt_every=100
  local rc compile_s elapsed stats itps mem_gb max_it samples gpu_peak
  wlog "--- stage cmp (${CMP_ITERS} iterations, --compile reduce-overhead) ---"
  write_state "RUNNING" "0" "STAGE=compile-cmp"
  stats="$(run_training "$run_name" "$CMP_ITERS" reduce-overhead "$ckpt_every" 0 \
    "$CMP_LOG" "$CMP_CSV" "$CMP_TIMEOUT")"
  rc="$(printf '%s' "$stats" | awk '{print $1}')"
  compile_s="$(printf '%s' "$stats" | awk '{print $2}')"
  elapsed="$(printf '%s' "$stats" | awk '{print $3}')"
  stats="$(log_stats "$CMP_LOG" 0)"
  itps="$(printf '%s' "$stats" | awk '{print $1}')"
  mem_gb="$(printf '%s' "$stats" | awk '{print $2}')"
  max_it="$(printf '%s' "$stats" | awk '{print $3}')"
  samples="$(printf '%s' "$stats" | awk '{print $4}')"
  gpu_peak="$(resource_peaks "$CMP_CSV" | awk '{print $1}')"
  wlog "cmp rc=$rc it_per_s=$itps mem_gb=$mem_gb max_it=$max_it gpu_peak_mb=$gpu_peak compile_s=$compile_s elapsed=$elapsed"
  if [ "$rc" = "124" ]; then
    marker "COMPILE_CMP_FAIL reason=timeout"
    write_state "RUNNING" "0" "STAGE=compile-cmp" "CMP_REASON=timeout"
    return 0
  fi
  if [ "$rc" != "0" ] || [ "$max_it" -lt "$CMP_ITERS" ] || [ "$samples" -le 0 ]; then
    local reason="other"
    if grep -aqi 'out of memory\|CUDA error: out of memory\|OutOfMemoryError' "$CMP_LOG" 2>/dev/null; then
      reason="oom"
    elif grep -aqi 'dynamo\|compile error\|CompilationError\|BackendCompilerFailed' "$CMP_LOG" 2>/dev/null; then
      reason="compile-error"
    fi
    marker "COMPILE_CMP_FAIL reason=$reason"
    write_state "RUNNING" "0" "STAGE=compile-cmp" "CMP_REASON=$reason"
    return 0
  fi
  local verdict="use_none"
  if [ "${SMOKE_IT_PER_S:-0}" != "0" ] && [ "${SMOKE_GPU_PEAK_MB:-0}" != "0" ]; then
    if awk -v a="$itps" -v b="$SMOKE_IT_PER_S" 'BEGIN {exit !(a > b * 1.1)}' && \
       [ "$gpu_peak" -lt "$GPU_TRIGGER_MB" ]; then
      verdict="use_reduce_overhead"
    fi
  fi
  marker "COMPILE_CMP_OK mode=reduce-overhead it_per_s=$itps gpu_peak_mb=$gpu_peak compile_s=$compile_s verdict=$verdict"
  write_state "RUNNING" "0" "STAGE=compile-cmp" "CMP_IT_PER_S=$itps" "CMP_VERDICT=$verdict"
  return 0
}

stage_batch() {
  local gpu_peak="$1"
  if [ "${gpu_peak:-0}" -le "$GPU_TRIGGER_MB" ]; then
    marker "BATCH_PROBE_SKIPPED reason=peak-below-budget"
    wlog "batch probe skipped (gpu_peak_mb=$gpu_peak <= $GPU_TRIGGER_MB)"
    return 0
  fi
  local run_name="smoke_batch_2048" rc elapsed stats itps gpu_peak2
  wlog "--- stage batch probe (--imag-batch 2048 --kp-imag-batch 2048) ---"
  stats="$(run_training "$run_name" "$CMP_ITERS" none 100 0 \
    "$LOG_DIR_REAL/17_train_smoke_batch.log" "$LOG_DIR_REAL/17_train_smoke_batch_resources.csv" \
    "$CMP_TIMEOUT" "--imag-batch 2048 --kp-imag-batch 2048")"
  rc="$(printf '%s' "$stats" | awk '{print $1}')"
  elapsed="$(printf '%s' "$stats" | awk '{print $3}')"
  stats="$(log_stats "$LOG_DIR_REAL/17_train_smoke_batch.log" 0)"
  itps="$(printf '%s' "$stats" | awk '{print $1}')"
  gpu_peak2="$(resource_peaks "$LOG_DIR_REAL/17_train_smoke_batch_resources.csv" | awk '{print $1}')"
  if [ "$rc" = "0" ]; then
    marker "BATCH_PROBE_OK it_per_s=$itps gpu_peak_mb=$gpu_peak2 elapsed_s=$elapsed"
  else
    marker "BATCH_PROBE_FAIL reason=$( [ "$rc" = "124" ] && echo timeout || echo error )"
  fi
  return 0
}

# resource_peaks <csv> -> "<gpu_used_mb_peak> <host_used_gb_peak>"
resource_peaks() {
  "$TRAIN_PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import train
summary = train.parse_resource_csv(sys.argv[2])
if summary is None:
    print("0 0")
else:
    print("%.0f %.2f" % (summary["gpu_used_mb_peak"] or 0,
                         summary["host_used_gb_peak"] or 0))
' "$TRAIN_LIB" "$1" 2>/dev/null
}

# ckpt_size_mb <run-dir> -> the size of the largest ckpt_*.pt in MiB
ckpt_size_mb() {
  local dir="$1" kb
  kb="$(find "$dir" -maxdepth 1 -name 'ckpt_*.pt' -printf '%k\n' 2>/dev/null | sort -n | tail -n1)"
  printf '%s' "$(( ${kb:-0} / 1024 ))"
}

# --- the driver body --------------------------------------------------------
run_driver() {
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  wlog "=== 17_train_smoke.sh $started_at ==="
  wlog "REPO_ROOT=$REPO_ROOT"
  resolve_python
  wlog "PYTHON_BIN=$PY_BIN"

  if [ "$(state_get STAGE)" = "done" ]; then
    wlog "stage=done already -- nothing to do"
    exit 0
  fi

  write_state "RUNNING" "0" "STAGE=env" "STARTED_AT=$started_at"

  # the TEMP plan (probe it/s) is written FIRST so T5's worker never hits
  # plan-missing even if the smoke run fails; a successful smoke overwrites
  # it with the measured value (source=smoke) at the end of this driver.
  if [ ! -f "$PLAN_FILE" ]; then
    wlog "--- stage plan-temp (probe, it_per_s=$PROBE_IT_PER_S) ---"
    write_plan "$PROBE_IT_PER_S" probe
    if [ -f "$PLAN_FILE" ]; then
      marker "PLAN_WRITTEN_TEMP source=probe it_per_s=$PROBE_IT_PER_S"
    else
      wlog "plan-temp write failed (the final plan stage will retry)"
    fi
  fi

  if ! has_marker "TRAIN_SMOKE_OK" && ! has_marker "TRAIN_SMOKE_FAIL"; then
    if ! stage_env; then
      exit 1
    fi
  fi

  if ! has_marker "TRAIN_SMOKE_OK"; then
    stage_smoke
    stage_rc=$?
    if [ "$stage_rc" -ne 0 ]; then
      exit 1
    fi
  else
    SMOKE_IT_PER_S="$(marker_value TRAIN_SMOKE_OK it_per_s)"
    SMOKE_GPU_PEAK_MB="$(marker_value TRAIN_SMOKE_OK gpu_peak_mb)"
  fi

  if ! has_marker "COMPILE_CMP_OK" && ! has_marker "COMPILE_CMP_FAIL"; then
    stage_cmp
  fi

  stage_batch "${SMOKE_GPU_PEAK_MB:-0}"

  # the plan file: the measured throughput wins over the probe value
  if has_marker "TRAIN_SMOKE_OK"; then
    itps="$(marker_value TRAIN_SMOKE_OK it_per_s)"
    source="smoke"
  else
    itps="$PROBE_IT_PER_S"
    source="probe"
  fi
  if [ ! -f "$PLAN_FILE" ] || [ "$(sed -n 's/^IT_PER_S_SOURCE=//p' "$PLAN_FILE" | head -n1)" != "$source" ]; then
    wlog "--- stage plan ($source, it_per_s=$itps) ---"
    write_plan "$itps" "$source"
    marker "PLAN_WRITTEN iterations=$(sed -n 's/^ITERATIONS=//p' "$PLAN_FILE" | head -n1) ckpt_every=$(sed -n 's/^CKPT_EVERY=//p' "$PLAN_FILE" | head -n1) segment_iters=$(sed -n 's/^SEGMENT_ITERS=//p' "$PLAN_FILE" | head -n1) it_per_s=$itps source=$source"
  fi
  check="$(plan_self_check)"
  marker "PLAN_SELF_CHECK $check"
  wlog "$check"

  write_state "DONE" "0" "STAGE=done" "REASON=none"
  marker "SMOKE_DONE stage=done"
  wlog "SMOKE_DONE stage=done"
  exit 0
}

# marker_value <marker-prefix> <key> -- the value of KEY in the marker line
marker_value() {
  local prefix="$1" key="$2"
  grep -m1 -F "$prefix" "$MARKER_FILE" 2>/dev/null \
    | tr ' ' '\n' | sed -n "s/^$key=//p" | head -n1
}

case "$CMD" in
  start)
    if pgrep -f '17_train_smoke[.]sh run' >/dev/null 2>&1; then
      wlog "SMOKE_ALREADY_RUNNING"
      exit 0
    fi
    setsid nohup bash "$0" run >>"$DRIVER_LOG" 2>&1 </dev/null &
    wlog "SMOKE_STARTED pid=$! log=$DRIVER_LOG"
    exit 0
    ;;
  status)
    wlog "STATE_FILE=$STATE_FILE"
    if [ -f "$STATE_FILE" ]; then
      cat "$STATE_FILE"
    else
      wlog "STATE=ABSENT"
    fi
    wlog "--- markers ---"
    if [ -f "$MARKER_FILE" ]; then
      cat "$MARKER_FILE"
    else
      wlog "(no marker file yet)"
    fi
    wlog "--- plan file ---"
    if [ -f "$PLAN_FILE" ]; then
      cat "$PLAN_FILE"
    else
      wlog "(no plan file yet)"
    fi
    exit 0
    ;;
  run)
    run_driver
    exit $?
    ;;
  *)
    wlog "usage: bash $0 {start|status|run}"
    exit 2
    ;;
esac
