#!/usr/bin/env bash
# repro/tests/test_train_orchestrator.sh — the NEGATIVE battery of the
# training orchestrator of slice S06:
#
#   repro/17_train.sh        (env | start | status | wait | worker | ...)
#   repro/17_train_worker.sh (the detached training body)
#
# The battery runs OFFLINE: no GPU, no network, no container, no payload.
# Everything it needs is a synthetic fixture in a `mktemp -d` directory
# (a fake venv interpreter, a fake nvidia-smi, a synthetic subset yaml and
# a synthetic sidecar root).  The real `data/`, the real `logs/` and the
# container are NEVER touched: every path is redirected through the
# TRAIN_* environment overrides into the temp directory.
#
# Covered:
#   1.  the env gate PASSES on a complete fixture and prints exactly one
#       TRAIN_ENV_OK line with clips=490 sidecars=490
#   2.  a missing subset        -> non-zero exit, ZERO TRAIN_ENV_OK marker,
#                                  reason=subset-missing
#   3.  an unparsable subset    -> reason=subset-unparsable
#   4.  a wrong clip count      -> reason=subset-count
#   5.  a missing sidecar root  -> reason=sidecar-missing
#   6.  a wrong sidecar count   -> reason=sidecar-count
#   7.  a failing human verify  -> reason=sidecar-count
#   8.  a failing npz verify    -> reason=npz-verify-failed
#   9.  torch without CUDA      -> reason=cuda-unavailable
#  10.  a broken interpreter   -> reason=import-failed
#  11.  a wiped venv            -> reason=venv-drift AND the repair hint
#  12.  a GPU below 20000 MiB   -> reason=gpu-missing
#  13.  a full disk             -> reason=disk-insufficient
#  14.  `status` ALWAYS exits 0 (also with no status file at all)
#  15.  `wait` times out with 75 and does NOT kill the worker
#  16.  `wait` returns 0 on DONE and 1 on FAILED
#  17.  the worker fails closed on a missing plan file
#  18.  the worker refuses a plan whose LR_DECAY_ITERS != ITERATIONS
#  19.  the worker completes a segmented run and writes the DONE status
#  20.  the status file is written atomically (no .tmp residue anywhere)
#  21.  the worker RESUMES from the checkpoint (it does not replay the run)
#       and fails closed when the resume point is missing
#  22.  `start` re-arms a STALE RUNNING state (the worker is gone)
#  23.  `start` with a LIVE worker does not launch a second one
#
# Run locally:   bash repro/tests/test_train_orchestrator.sh
# Exit code 0 == all tests passed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/repro/17_train.sh"
WORKER="$REPO_ROOT/repro/17_train_worker.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

LOG_DIR="$TMP/logs"
mkdir -p "$LOG_DIR"

# --- the base environment of every orchestrator call ------------------------
# (everything is redirected into the temp directory: the real logs/ and the
# store are never written by this battery).
export TRAIN_ALLOW_LOCAL=1
export TRAIN_LOG_DIR="$LOG_DIR"
export TRAIN_STATUS_FILE="$LOG_DIR/17_train.status"
export TRAIN_WORKER_LOG="$LOG_DIR/17_train_worker.log"
export TRAIN_RESOURCES_CSV="$LOG_DIR/17_train_resources.csv"
export TRAIN_PLAN_FILE="$LOG_DIR/17_train_plan.env"
# The RUN DIRECTORY is redirected into the fixture too: the worker reads the
# checkpoint names from it to find the resume point, so the battery must
# NEVER see the real run directory (which lives in the seed store).
export TRAIN_RUN_DIR="$TMP/run/g1_amber_1h"
export TRAIN_PY=python3
export TRAIN_MIN_FREE_GB=1
mkdir -p "$TRAIN_RUN_DIR"

# --- the fixtures ------------------------------------------------------------
NPZ_ROOT="$TMP/npz"
SUBSET_YAML="$NPZ_ROOT/subsets/1h.yaml"
HUMAN_ROOT="$NPZ_ROOT/human50"
mkdir -p "$NPZ_ROOT/subsets" "$HUMAN_ROOT"

# make_subset <path> <clips>
make_subset() {
  local path="$1" clips="$2" i
  {
    printf 'root: %s\n' "$NPZ_ROOT"
    printf 'hours: 1.0014277778\n'
    printf 'clips:\n'
    for i in $(seq 1 "$clips"); do
      printf -- '- 220713/clip_%04d.npz\n' "$i"
    done
  } >"$path"
}

# make_sidecars <dir> <count>
make_sidecars() {
  local dir="$1" count="$2" i
  mkdir -p "$dir/220713"
  for i in $(seq 1 "$count"); do
    : >"$dir/220713/clip_$(printf '%04d' "$i").npz"
  done
}

# make_fake_python <path> <mode>  (mode: ok | nocuda | importfail | drift)
make_fake_python() {
  local path="$1" mode="$2"
  {
    printf '#!/usr/bin/env bash\n'
    case "$mode" in
      ok)
        printf 'printf "PY_VERSION=3.11.16\\n"\n'
        printf 'printf "TORCH_VERSION=2.11.0+cu128\\n"\n'
        printf 'printf "CUDA_AVAILABLE=TRUE\\n"\n'
        ;;
      nocuda)
        printf 'printf "PY_VERSION=3.11.16\\n"\n'
        printf 'printf "TORCH_VERSION=2.11.0+cu128\\n"\n'
        printf 'printf "CUDA_AVAILABLE=FALSE\\n"\n'
        ;;
      importfail)
        printf 'printf "Traceback (most recent call last):\\n  ModuleNotFoundError: No module named %s\\n" "torch" >&2\n'
        printf 'exit 1\n'
        ;;
      drift)
        printf 'printf "error: No virtual environment found at %s\\n" ".venv" >&2\n'
        printf 'exit 1\n'
        ;;
    esac
  } >"$path"
  chmod +x "$path"
}

# make_fake_smi <path> <total_mb> — answers both query shapes the
# orchestrator and the resource sampler use.
make_fake_smi() {
  local path="$1" total="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'query=""\n'
    printf 'for arg in "$@"; do\n'
    printf '  case "$arg" in --query-gpu=*) query="$arg" ;; esac\n'
    printf 'done\n'
    printf 'case "$query" in\n'
    printf '  *memory.used,memory.total*) printf "%%s, %%s\\n" "%s" "%s" ;;\n' "$(( total / 2 ))" "$total"
    printf '  *) printf "%%s\\n" "%s" ;;\n' "$total"
    printf 'esac\n'
  } >"$path"
  chmod +x "$path"
}

make_fake_python "$TMP/py_ok" ok
make_fake_python "$TMP/py_nocuda" nocuda
make_fake_python "$TMP/py_importfail" importfail
make_fake_python "$TMP/py_drift" drift
make_fake_smi "$TMP/smi_ok" 24564
make_fake_smi "$TMP/smi_small" 8192
make_subset "$SUBSET_YAML" 490
make_sidecars "$HUMAN_ROOT" 490

# --- the env gate fixture ----------------------------------------------------
export TRAIN_VENV_PY="$TMP/py_ok"
export TRAIN_NVIDIA_SMI="$TMP/smi_ok"
export TRAIN_NPZ_ROOT="$NPZ_ROOT"
export TRAIN_SUBSET_YAML="$SUBSET_YAML"
export TRAIN_HUMAN_ROOT="$HUMAN_ROOT"
export TRAIN_DISK_PATH="$NPZ_ROOT"
export TRAIN_NPZ_VERIFY_CMD=true
export TRAIN_HUMAN_VERIFY_CMD=true

OUT="$TMP/out.txt"

# assert_no_ok_marker <file> <label> — a failing gate must NEVER print an OK
# marker (the S03/MEM038 convention).
assert_no_ok_marker() {
  local file="$1" label="$2"
  if grep -q 'TRAIN_ENV_OK' "$file"; then
    bad "$label: the output contains a TRAIN_ENV_OK marker"
  else
    ok "$label: no TRAIN_ENV_OK marker on the failure path"
  fi
}

# assert_fail_reason <file> <reason> <label>
assert_fail_reason() {
  local file="$1" reason="$2" label="$3"
  if grep -q "TRAIN_ENV_FAIL reason=$reason" "$file"; then
    ok "$label: reason=$reason"
  else
    bad "$label: expected reason=$reason"
    sed -n '1,40p' "$file"
  fi
}

# ============================================================================
# 1. POSITIVE: the env gate passes on a complete fixture
# ============================================================================
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "env gate passes on a complete fixture (rc=0)"
else
  bad "env gate passes on a complete fixture (rc=$rc)"
  sed -n '1,40p' "$OUT"
fi
if grep -q 'TRAIN_ENV_OK python=.* torch=.* clips=490 sidecars=490 gpu_total_mb=24564 free_gb=' "$OUT"; then
  ok "env gate prints TRAIN_ENV_OK with clips=490 sidecars=490"
else
  bad "env gate prints TRAIN_ENV_OK with clips=490 sidecars=490"
  sed -n '1,40p' "$OUT"
fi
if [ "$(grep -c 'TRAIN_ENV_OK' "$OUT")" -eq 1 ]; then
  ok "env gate prints the OK marker exactly once"
else
  bad "env gate prints the OK marker exactly once"
fi

# ============================================================================
# 2-13. the negative env-gate paths
# ============================================================================

# 2. a missing subset
mv "$SUBSET_YAML" "$TMP/1h.yaml.bak"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "missing subset: non-zero exit ($rc)" || bad "missing subset: non-zero exit"
assert_no_ok_marker "$OUT" "missing subset"
assert_fail_reason "$OUT" "subset-missing" "missing subset"
mv "$TMP/1h.yaml.bak" "$SUBSET_YAML"

# 3. an unparsable subset
cp "$SUBSET_YAML" "$TMP/1h.yaml.bak"
printf 'this is not: [a valid\n  yaml\n' >"$SUBSET_YAML"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "unparsable subset: non-zero exit ($rc)" || bad "unparsable subset: non-zero exit"
assert_no_ok_marker "$OUT" "unparsable subset"
assert_fail_reason "$OUT" "subset-unparsable" "unparsable subset"
cp "$TMP/1h.yaml.bak" "$SUBSET_YAML"

# 4. a wrong clip count
make_subset "$SUBSET_YAML" 12
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "wrong clip count: non-zero exit ($rc)" || bad "wrong clip count: non-zero exit"
assert_no_ok_marker "$OUT" "wrong clip count"
assert_fail_reason "$OUT" "subset-count" "wrong clip count"
make_subset "$SUBSET_YAML" 490

# 5. a missing sidecar root
mv "$HUMAN_ROOT" "$TMP/human50.bak"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "missing sidecar root: non-zero exit ($rc)" || bad "missing sidecar root: non-zero exit"
assert_no_ok_marker "$OUT" "missing sidecar root"
assert_fail_reason "$OUT" "sidecar-missing" "missing sidecar root"
mv "$TMP/human50.bak" "$HUMAN_ROOT"

# 6. a wrong sidecar count
mv "$HUMAN_ROOT" "$TMP/human50.bak"
make_sidecars "$HUMAN_ROOT" 3
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "wrong sidecar count: non-zero exit ($rc)" || bad "wrong sidecar count: non-zero exit"
assert_no_ok_marker "$OUT" "wrong sidecar count"
assert_fail_reason "$OUT" "sidecar-count" "wrong sidecar count"
rm -rf "$HUMAN_ROOT"
mv "$TMP/human50.bak" "$HUMAN_ROOT"

# 7. a failing human verifier
export TRAIN_HUMAN_VERIFY_CMD=false
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "failing human verify: non-zero exit ($rc)" || bad "failing human verify: non-zero exit"
assert_no_ok_marker "$OUT" "failing human verify"
assert_fail_reason "$OUT" "sidecar-count" "failing human verify"
export TRAIN_HUMAN_VERIFY_CMD=true

# 8. a failing npz verifier
export TRAIN_NPZ_VERIFY_CMD=false
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "failing npz verify: non-zero exit ($rc)" || bad "failing npz verify: non-zero exit"
assert_no_ok_marker "$OUT" "failing npz verify"
assert_fail_reason "$OUT" "npz-verify-failed" "failing npz verify"
export TRAIN_NPZ_VERIFY_CMD=true

# 9. torch without CUDA
export TRAIN_VENV_PY="$TMP/py_nocuda"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "no CUDA: non-zero exit ($rc)" || bad "no CUDA: non-zero exit"
assert_no_ok_marker "$OUT" "no CUDA"
assert_fail_reason "$OUT" "cuda-unavailable" "no CUDA"
export TRAIN_VENV_PY="$TMP/py_ok"

# 10. a broken interpreter
export TRAIN_VENV_PY="$TMP/py_importfail"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "broken interpreter: non-zero exit ($rc)" || bad "broken interpreter: non-zero exit"
assert_no_ok_marker "$OUT" "broken interpreter"
assert_fail_reason "$OUT" "import-failed" "broken interpreter"
export TRAIN_VENV_PY="$TMP/py_ok"

# 11. a wiped venv -> venv-drift WITH the repair hint
export TRAIN_VENV_PY="$TMP/py_drift"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "venv drift: non-zero exit ($rc)" || bad "venv drift: non-zero exit"
assert_no_ok_marker "$OUT" "venv drift"
assert_fail_reason "$OUT" "venv-drift" "venv drift"
if grep -q 'uv sync --frozen --offline --group export --group teleop' "$OUT"; then
  ok "venv drift: the message carries the repair hint"
else
  bad "venv drift: the message carries the repair hint"
  sed -n '1,40p' "$OUT"
fi
export TRAIN_VENV_PY="$TMP/py_ok"

# 12. a GPU below 20000 MiB
export TRAIN_NVIDIA_SMI="$TMP/smi_small"
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "small GPU: non-zero exit ($rc)" || bad "small GPU: non-zero exit"
assert_no_ok_marker "$OUT" "small GPU"
assert_fail_reason "$OUT" "gpu-missing" "small GPU"
export TRAIN_NVIDIA_SMI="$TMP/smi_ok"

# 13. a full disk
export TRAIN_MIN_FREE_GB=999999999
bash "$ORCH" env >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "full disk: non-zero exit ($rc)" || bad "full disk: non-zero exit"
assert_no_ok_marker "$OUT" "full disk"
assert_fail_reason "$OUT" "disk-insufficient" "full disk"
export TRAIN_MIN_FREE_GB=1

# ============================================================================
# 14. `status` ALWAYS exits 0
# ============================================================================
rm -f "$TRAIN_STATUS_FILE"
bash "$ORCH" status >"$OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "status with no status file exits 0" || bad "status with no status file exits 0 (rc=$rc)"
printf 'STATE=RUNNING\nRC=0\n' >"$TRAIN_STATUS_FILE"
bash "$ORCH" status >"$OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "status with a status file exits 0" || bad "status with a status file exits 0 (rc=$rc)"

# ============================================================================
# 15. `wait` times out with 75 and does NOT kill the worker
# ============================================================================
printf 'STATE=RUNNING\nRC=0\n' >"$TRAIN_STATUS_FILE"
# A sentinel that must still be alive after the timeout: the wait must NOT
# kill anything when it gives up.
sleep 30 &
SENTINEL=$!
bash "$ORCH" wait 2 >"$OUT" 2>&1
rc=$?
if [ "$rc" -eq 75 ]; then
  ok "wait times out with 75 (EX_TEMPFAIL)"
else
  bad "wait times out with 75 (rc=$rc)"
  sed -n '1,20p' "$OUT"
fi
if kill -0 "$SENTINEL" 2>/dev/null; then
  ok "wait did not kill the worker on timeout"
else
  bad "wait did not kill the worker on timeout"
fi
kill "$SENTINEL" 2>/dev/null
wait "$SENTINEL" 2>/dev/null

# ============================================================================
# 16. `wait` returns 0 on DONE and 1 on FAILED
# ============================================================================
printf 'STATE=DONE\nRC=0\n' >"$TRAIN_STATUS_FILE"
bash "$ORCH" wait 5 >"$OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "wait returns 0 on DONE" || bad "wait returns 0 on DONE (rc=$rc)"
printf 'STATE=FAILED\nRC=1\n' >"$TRAIN_STATUS_FILE"
bash "$ORCH" wait 5 >"$OUT" 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "wait returns 1 on FAILED" || bad "wait returns 1 on FAILED (rc=$rc)"

# ============================================================================
# 17-19. the worker (the plan gate and the segmented loop)
# ============================================================================
export TRAIN_ENV_CMD=true
export TRAIN_DISK_PATH="$TMP"
export TRAIN_SAMPLE_INTERVAL=1
export TRAIN_TRAIN_CMD=true

# 17. a missing plan file -> fail closed
rm -f "$TRAIN_PLAN_FILE"
rm -f "$TRAIN_STATUS_FILE"
bash "$WORKER" >"$TMP/worker.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "worker with a missing plan exits non-zero ($rc)" || bad "worker with a missing plan exits non-zero"
if grep -q 'TRAIN_TRAIN_FAIL reason=plan-missing' "$TMP/worker.out"; then
  ok "worker with a missing plan: reason=plan-missing"
else
  bad "worker with a missing plan: reason=plan-missing"
  sed -n '1,40p' "$TMP/worker.out"
fi
if grep -q 'TRAIN_TRAIN_OK' "$TMP/worker.out"; then
  bad "worker with a missing plan prints no OK marker"
else
  ok "worker with a missing plan prints no OK marker"
fi
if grep -q '^STATE=FAILED' "$TRAIN_STATUS_FILE" 2>/dev/null; then
  ok "worker with a missing plan writes STATE=FAILED"
else
  bad "worker with a missing plan writes STATE=FAILED"
  sed -n '1,20p' "$TRAIN_STATUS_FILE" 2>/dev/null
fi

# 18. a plan whose LR_DECAY_ITERS != ITERATIONS -> refused (MEM005)
cat >"$TRAIN_PLAN_FILE" <<'PLANEOF'
ITERATIONS=20000
LR_DECAY_ITERS=250000
CKPT_EVERY=2000
SEGMENT_ITERS=2000
BUDGET_SECONDS=28800
COMPILE=none
NUM_ENVS=1024
HUMAN_ROOT=/tmp/human50
SUBSET_YAML=/tmp/1h.yaml
RUN_NAME=g1_amber_1h
PLANEOF
bash "$WORKER" >"$TMP/worker.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "worker with a misaligned plan exits non-zero ($rc)" || bad "worker with a misaligned plan exits non-zero"
if grep -q 'TRAIN_TRAIN_FAIL reason=plan-inconsistent' "$TMP/worker.out"; then
  ok "worker with a misaligned plan: reason=plan-inconsistent"
else
  bad "worker with a misaligned plan: reason=plan-inconsistent"
  sed -n '1,40p' "$TMP/worker.out"
fi

# 19. a consistent plan -> the segmented loop completes
cat >"$TRAIN_PLAN_FILE" <<'PLANEOF'
ITERATIONS=2000
LR_DECAY_ITERS=2000
CKPT_EVERY=1000
SEGMENT_ITERS=1000
BUDGET_SECONDS=28800
COMPILE=none
NUM_ENVS=1024
HUMAN_ROOT=/tmp/human50
SUBSET_YAML=/tmp/1h.yaml
RUN_NAME=g1_amber_1h
PLANEOF
rm -f "$TRAIN_STATUS_FILE"
bash "$WORKER" >"$TMP/worker.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "worker with a consistent plan exits 0" || bad "worker with a consistent plan exits 0 (rc=$rc)"
if grep -q 'TRAIN_TRAIN_OK' "$TMP/worker.out"; then
  ok "worker with a consistent plan prints TRAIN_TRAIN_OK"
else
  bad "worker with a consistent plan prints TRAIN_TRAIN_OK"
  sed -n '1,40p' "$TMP/worker.out"
fi
if [ "$(grep -c '### SEGMENT' "$TMP/worker.out")" -eq 2 ]; then
  ok "worker splits the run into 2 segments (2000 iterations, 1000 per segment)"
else
  bad "worker splits the run into 2 segments (got $(grep -c '### SEGMENT' "$TMP/worker.out"))"
fi
if grep -q '^STATE=DONE' "$TRAIN_STATUS_FILE" 2>/dev/null; then
  ok "worker writes STATE=DONE"
else
  bad "worker writes STATE=DONE"
  sed -n '1,20p' "$TRAIN_STATUS_FILE" 2>/dev/null
fi
if grep -q '^TARGET_ITER=2000' "$TRAIN_STATUS_FILE" 2>/dev/null; then
  ok "worker writes TARGET_ITER=2000"
else
  bad "worker writes TARGET_ITER=2000"
fi
if [ -f "$TRAIN_RESOURCES_CSV" ] \
   && head -n1 "$TRAIN_RESOURCES_CSV" | grep -q '^ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,proc_rss_gb$'; then
  ok "the resource sampler wrote the documented CSV header"
else
  bad "the resource sampler wrote the documented CSV header"
  head -n2 "$TRAIN_RESOURCES_CSV" 2>/dev/null
fi

# ============================================================================
# 20. the status file is written atomically (no .tmp residue)
# ============================================================================
if [ -z "$(find "$TMP" -name '*.tmp' -print -quit)" ]; then
  ok "no .tmp residue anywhere in the fixture tree"
else
  bad "no .tmp residue anywhere in the fixture tree"
  find "$TMP" -name '*.tmp' -print
fi

# ============================================================================
# 21. the worker resumes from the CHECKPOINT, it does not replay the run
# ============================================================================
# The run directory holds ckpt_1500.pt: a re-armed worker must start at
# iteration 1500 (the checkpoint is the resume point), not at 0.
RUN_DIR_FIX="$TRAIN_RUN_DIR"
mkdir -p "$RUN_DIR_FIX"
: >"$RUN_DIR_FIX/ckpt_1500.pt"
: >"$RUN_DIR_FIX/latest.pt"
cat >"$TRAIN_PLAN_FILE" <<'PLANEOF'
ITERATIONS=2000
LR_DECAY_ITERS=2000
CKPT_EVERY=1000
SEGMENT_ITERS=1000
BUDGET_SECONDS=28800
COMPILE=none
NUM_ENVS=1024
HUMAN_ROOT=/tmp/human50
SUBSET_YAML=/tmp/1h.yaml
RUN_NAME=g1_amber_1h
PLANEOF
rm -f "$TRAIN_STATUS_FILE"
bash "$WORKER" >"$TMP/worker.out" 2>&1
rc=$?
if grep -q '### SEGMENT 1: iterations 1500 -> 2000' "$TMP/worker.out"; then
  ok "the worker resumes from the checkpoint (1500), it does not replay from 0"
else
  bad "the worker resumes from the checkpoint (1500), it does not replay from 0"
  grep -a '### SEGMENT' "$TMP/worker.out" | head -n 5
fi
if [ "$(grep -c '### SEGMENT' "$TMP/worker.out")" -eq 1 ]; then
  ok "a resumed worker runs only the remaining segment (1 of 2)"
else
  bad "a resumed worker runs only the remaining segment (got $(grep -c '### SEGMENT' "$TMP/worker.out"))"
fi

# 21b. a run directory with a checkpoint but NO resume point -> fail closed
rm -f "$RUN_DIR_FIX/latest.pt"
cat >"$TRAIN_PLAN_FILE" <<'PLANEOF'
ITERATIONS=2000
LR_DECAY_ITERS=2000
CKPT_EVERY=1000
SEGMENT_ITERS=1000
BUDGET_SECONDS=28800
COMPILE=none
NUM_ENVS=1024
HUMAN_ROOT=/tmp/human50
SUBSET_YAML=/tmp/1h.yaml
RUN_NAME=g1_amber_1h
PLANEOF
bash "$WORKER" >"$TMP/worker.out" 2>&1
rc=$?
if grep -q 'TRAIN_TRAIN_FAIL reason=checkpoint-missing' "$TMP/worker.out"; then
  ok "a checkpoint without a resume point fails closed (reason=checkpoint-missing)"
else
  bad "a checkpoint without a resume point fails closed (reason=checkpoint-missing)"
  sed -n '1,40p' "$TMP/worker.out"
fi
if grep -q 'TRAIN_TRAIN_OK' "$TMP/worker.out"; then
  bad "a checkpoint without a resume point prints no OK marker"
else
  ok "a checkpoint without a resume point prints no OK marker"
fi
rm -f "$RUN_DIR_FIX/ckpt_1500.pt"

# ============================================================================
# 22. `start` re-arms a STALE RUNNING state (the worker is gone)
# ============================================================================
# A RUNNING state whose PID is not alive must NOT block the re-arm: the
# observed 2026-11-13 crash left exactly that state behind and the run could
# not be continued.
sleep 1 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
printf 'STATE=RUNNING\nRC=0\nPID=%s\n' "$DEAD_PID" >"$TRAIN_STATUS_FILE"
if bash "$ORCH" start >"$OUT" 2>&1; then
  ok "start with a stale RUNNING state exits 0"
else
  bad "start with a stale RUNNING state exits 0"
fi
if grep -q 'stale RUNNING state' "$OUT"; then
  ok "start reports the stale RUNNING state and re-arms"
else
  bad "start reports the stale RUNNING state and re-arms"
  sed -n '1,20p' "$OUT"
fi
if grep -q 'WORKER_PID=' "$OUT"; then
  ok "start launches a worker for the stale RUNNING state"
else
  bad "start launches a worker for the stale RUNNING state"
  sed -n '1,20p' "$OUT"
fi
sleep 2

# ============================================================================
# 23. `start` with a LIVE worker still does not launch a second one
# ============================================================================
sleep 30 &
LIVE_PID=$!
export TRAIN_STATUS_FILE="$LOG_DIR/17_train.live.status"
printf 'STATE=RUNNING\nRC=0\nPID=%s\n' "$LIVE_PID" >"$TRAIN_STATUS_FILE"
bash "$ORCH" start >"$OUT" 2>&1
if grep -q 'worker already RUNNING' "$OUT"; then
  ok "start with a live worker does not launch a second one"
else
  bad "start with a live worker does not launch a second one"
  sed -n '1,20p' "$OUT"
fi
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
