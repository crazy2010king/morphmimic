#!/usr/bin/env bash
# repro/tests/test_train_verify_tb_e2e.sh — the END-TO-END battery of the
# read-only reviewer against the REAL tensorboard and the REAL torch
# (slice S06, task T3).
#
# WHY THIS BATTERY EXISTS
#
# repro/tests/test_train_verify.sh drives the reviewer with STUBS (a fake
# tensorboard summary, a fake torch.load probe).  That proves the DECISION
# logic, but not the two heavy probes the reviewer really uses:
#
#   * the tensorboard aggregation over the WHOLE run directory
#     (EventAccumulator(run_dir, size_guidance={"scalars": 0})), and
#   * the `torch.load(path, map_location="cpu")` of the smallest
#     checkpoint and of latest.pt.
#
# This battery exercises exactly those two paths with the container's
# project venv: it writes REAL tensorboard event files (two of them, one per
# "process start", like the upstream trainer does) and REAL (tiny) .pt
# checkpoints, then runs repro/18_train_verify.sh WITHOUT any stub
# override.
#
# The battery SKIPS itself (exit 0, SKIP=1) when neither torch nor
# tensorboard is importable -- the local development box has no venv, so
# the skip is the normal outcome there and the coverage lives in the
# ros_dev container.
#
# Run locally:   bash repro/tests/test_train_verify_tb_e2e.sh
# Run in the container (the real coverage):
#   bash repro/lib/remote.sh ... (or docker exec ros_dev bash -lc 'cd
#   <repo> && bash repro/tests/test_train_verify_tb_e2e.sh')
# Exit code 0 == all tests passed (or the battery skipped).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$REPO_ROOT/repro/18_train_verify.sh"

PASS=0
FAIL=0
SKIP=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

# --- the interpreter that has torch + tensorboard ---------------------------
TORCH_PY="${TRAIN_TORCH_PY:-}"
if [ -z "$TORCH_PY" ]; then
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    TORCH_PY="$REPO_ROOT/.venv/bin/python"
  else
    TORCH_PY="python3"
  fi
fi

if ! "$TORCH_PY" -c 'import torch, tensorboard
from torch.utils.tensorboard import SummaryWriter' >/dev/null 2>&1; then
  printf 'SKIP  the tensorboard end-to-end battery (no torch/tensorboard for %s)\n' "$TORCH_PY"
  printf '\nPASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$((SKIP + 1))"
  exit 0
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export TRAIN_ALLOW_LOCAL=1
export TRAIN_LOG_DIR="$TMP/logs"
export TRAIN_PY=python3
export TRAIN_MIN_CKPTS=3
export TRAIN_GPU_MAX_MB=22528
export TRAIN_HOST_MAX_GB=45
export TRAIN_NPZ_VERIFY_CMD="true"
export TRAIN_HUMAN_VERIFY_CMD="true"
mkdir -p "$TRAIN_LOG_DIR"

# write_events <run_dir> <nan_state_loss:0|1> — ONE "process start": one
# events file in the run directory.
write_events() {
  "$TORCH_PY" - "$1" "$2" <<'PYEOF'
import os
import sys

import torch
from torch.utils.tensorboard import SummaryWriter

run_dir = sys.argv[1]
nan_state_loss = sys.argv[2] == "1"
writer = SummaryWriter(run_dir)
for step in range(5):
    writer.add_scalar("wm/state_loss",
                      float("nan") if nan_state_loss else 1.0 + step, step)
    writer.add_scalar("wm/nonfinite_steps", 0, step)
    writer.add_scalar("policy/objective", -0.5, step)
    writer.add_scalar("policy/nonfinite_steps", 0, step)
    writer.add_scalar("critic/loss", 0.9, step)
    writer.add_scalar("critic/nonfinite_steps", 0, step)
    writer.add_scalar("kp/nonfinite_steps", 0, step)
    writer.add_scalar("perf/it_per_s", 1.09, step)
    writer.add_scalar("perf/gpu_mem_gb", 17.09, step)
    # NaN BY DESIGN under --kp-student copy (upstream trainer.py:1935)
    writer.add_scalar("kp/return", float("nan"), step)
    writer.add_scalar("kp/scale_return", float("nan"), step)
writer.close()
for name in ("ckpt_1000.pt", "ckpt_2000.pt", "ckpt_3000.pt", "latest.pt"):
    torch.save({"x": torch.zeros(3)}, os.path.join(run_dir, name))
print("events:", sorted(n for n in os.listdir(run_dir)
                        if n.startswith("events.out.tfevents")))
PYEOF
}

# write_the_rest <dir> — the resource CSV, the status file, the plan file
# and the training log of the fixture.
write_the_rest() {
  local dir="$1"
  cat >"$dir/17_train_worker.log" <<'EOF'
[morphmimic] it 1200 | 1.09 it/s | mem 17.09 GB | wm loss 0.5 | J -0.3 | critic 0.2 | nonfinite wm/pol/critic 0/0/0
resumed logs/train/g1_amber_1h/latest.pt at iteration 1000; restored networks, normalisers, optimisers, schedule, sampler, rng, keypoint
[morphmimic] it 2900 | 1.08 it/s | mem 17.20 GB | wm loss 0.4 | J -0.2 | critic 0.1 | nonfinite wm/pol/critic 0/0/0
EOF
  cat >"$dir/17_train_resources.csv" <<'EOF'
ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,proc_rss_gb
1700000000,1200,18000,24564,12,60,11
1700000030,1400,18500,24564,13,59,12
EOF
  cat >"$dir/17_train.status" <<'EOF'
STATE=DONE
RC=0
ITER=3000
ELAPSED=3600
EOF
  cat >"$dir/17_train_plan.env" <<'EOF'
ITERATIONS=3000
LR_DECAY_ITERS=3000
BUDGET_SECONDS=3600
EOF
}

use_fixture() {
  local dir="$1"
  export TRAIN_RUN_DIR="$dir/run"
  export TRAIN_STATUS_FILE="$dir/17_train.status"
  export TRAIN_RESOURCES_CSV="$dir/17_train_resources.csv"
  export TRAIN_WORKER_LOG="$dir/17_train_worker.log"
  export TRAIN_PLAN_FILE="$dir/17_train_plan.env"
}

# ============================================================================
# 1. the healthy run: the REAL tensorboard aggregation + the REAL torch.load
# ============================================================================
DIR="$TMP/healthy"
mkdir -p "$DIR/run"
write_events "$DIR/run" 0 >/dev/null
write_the_rest "$DIR"
use_fixture "$DIR"

OUT="$(bash "$VERIFIER" verify 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^TRAIN_VERIFY_OK '; then
  ok "the real tensorboard + real torch.load path verifies a healthy run"
else
  bad "the real tensorboard + real torch.load path verifies a healthy run"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi
if printf '%s\n' "$OUT" | grep -q 'tb_tags=11'; then
  ok "the real aggregation sees all 11 tags (whitelisted NaN included)"
else
  bad "the real aggregation sees all 11 tags (whitelisted NaN included)"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi

# ============================================================================
# 2. the trap: a NaN in the SECOND events file of the run directory
#    (every process start writes a new events file -> a reader that looks at
#     a single file would miss it)
# ============================================================================
DIR="$TMP/two_events"
mkdir -p "$DIR/run"
write_events "$DIR/run" 0 >/dev/null
write_events "$DIR/run" 1 >/dev/null
write_the_rest "$DIR"
use_fixture "$DIR"

COUNT="$(ls -1 "$DIR/run" | grep -c '^events\.out\.tfevents')"
if [ "$COUNT" -ge 2 ]; then
  ok "the fixture holds two events files in one run directory ($COUNT)"
else
  bad "the fixture holds two events files in one run directory ($COUNT)"
fi

OUT="$(bash "$VERIFIER" verify 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] \
   && printf '%s\n' "$OUT" | grep -q '^TRAIN_VERIFY_FAIL reason=tb-nonfinite$'; then
  ok "the NaN of the second events file is caught"
else
  bad "the NaN of the second events file is caught"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi
if printf '%s\n' "$OUT" | grep -q 'TRAIN_VERIFY_OK'; then
  bad "no OK marker leaks into the failing run"
else
  ok "no OK marker leaks into the failing run"
fi

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
