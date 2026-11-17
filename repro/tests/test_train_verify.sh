#!/usr/bin/env bash
# repro/tests/test_train_verify.sh — the OFFLINE fixture battery of the
# READ-ONLY terminal reviewer of the formal training run (slice S06, T3):
#
#   repro/18_train_verify.sh (verify | report)
#
# The battery runs OFFLINE: no GPU, no network, no container, no payload.
# Everything it needs is a synthetic fixture inside a `mktemp -d` directory:
#
#   * a run directory with three FAKE `ckpt_*.pt` files plus `latest.pt`
#     (a few bytes each — the real checkpoints are 301 MB and are NEVER
#     written by a test),
#   * a fake tensorboard summary (the JSON the aggregation command emits),
#     injected through the `TRAIN_TB_CMD` override, so the test needs
#     neither tensorboard nor torch,
#   * a fake `torch.load` probe (`TRAIN_CKPT_LOAD_CMD`),
#   * a fake resource sampler CSV, a fake status file, a fake plan file and
#     a fake training log with a real `resumed ... at iteration N` line.
#
# The real `data/`, the real `logs/` and the container are NEVER touched:
# every path is redirected through the TRAIN_* overrides into the temp
# directory.
#
# Covered:
#   1.  the positive fixture      -> rc=0 and exactly one TRAIN_VERIFY_OK
#  2.  only two checkpoints      -> reason=ckpt-count
#   2b. no checkpoint at all     -> reason=ckpt-missing
#   3.  no latest.pt              -> reason=latest-missing
#   4.  an unloadable checkpoint  -> reason=ckpt-unloadable
#   5.  a NaN outside the whitelist-> reason=tb-nonfinite
#   6.  a nonfinite_steps counter > 0 -> reason=tb-nonfinite-steps
#   7.  a missing required tag    -> reason=tb-tag-missing
#   8.  no tensorboard event      -> reason=tb-no-events
#   9.  no resume event           -> reason=resume-missing
#  10.  a resume at iteration 0   -> reason=resume-iteration
#  11.  no checkpoint newer than the resume point -> reason=resume-iteration
#  12.  a missing resource CSV    -> reason=resource-csv-missing
#  13.  a VRAM peak of 23 GiB     -> reason=gpu-over-budget
#  14.  a host RAM peak of 46 GiB -> reason=host-over-budget
#  15.  a wall clock over budget  -> reason=wall-over-budget
#  16.  iterations != lr-decay-iters -> reason=iterations-mismatch
#  17.  a failing npz gate        -> reason=npz-verify-failed
#  18.  a failing human50 gate    -> reason=human-verify-failed
#  19.  the NaN WHITELIST (kp/return, kp/scale_return are NaN BY DESIGN
#       under --kp-student copy) does NOT change the exit code
#  20.  the reviewer is READ-ONLY: the run directory is not modified
#  21.  the `report` subcommand prints the TRAIN_REPORT_* lines
#
# Run locally:   bash repro/tests/test_train_verify.sh
# Exit code 0 == all tests passed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$REPO_ROOT/repro/18_train_verify.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the environment of every reviewer call --------------------------------
export TRAIN_ALLOW_LOCAL=1
export TRAIN_LOG_DIR="$TMP/logs"
export TRAIN_PY=python3
export TRAIN_MIN_CKPTS=3
export TRAIN_GPU_MAX_MB=22528
export TRAIN_HOST_MAX_GB=45
export TRAIN_NPZ_VERIFY_CMD="true"
export TRAIN_HUMAN_VERIFY_CMD="true"

mkdir -p "$TRAIN_LOG_DIR"

# --- the two stubs ----------------------------------------------------------
# the tensorboard aggregation is replaced by a stub that prints a fixture
cat >"$TMP/tb_stub.sh" <<'EOF'
#!/usr/bin/env bash
cat "$TRAIN_TB_FIXTURE"
EOF

# the torch.load probe is replaced by a stub that only checks the file
cat >"$TMP/load_stub.sh" <<'EOF'
#!/usr/bin/env bash
[ -s "$1" ]
EOF

export TRAIN_TB_CMD="bash $TMP/tb_stub.sh"
export TRAIN_CKPT_LOAD_CMD="bash $TMP/load_stub.sh"

# --- the fixtures -----------------------------------------------------------
# tb_json <path> <body...> — the aggregated tensorboard summary.
tb_json() {
  local path="$1"; shift
  printf '%s\n' "$*" >"$path"
}

# make_fixture <dir> — the complete, HEALTHY fixture.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/run"

  # three fake checkpoints (a few bytes, NOT 301 MB) + latest.pt
  local it
  for it in 1000 2000 3000; do
    printf 'fake-checkpoint-%s\n' "$it" >"$dir/run/ckpt_$it.pt"
  done
  printf 'fake-latest-checkpoint\n' >"$dir/run/latest.pt"

  # the training log: iteration lines + a real resume line
  cat >"$dir/17_train_worker.log" <<'EOF'
### SEGMENT 1: iterations 0 -> 1500
[morphmimic] it 1200 | 1.09 it/s | mem 17.09 GB | wm loss 0.5 | J -0.3 | critic 0.2 | nonfinite wm/pol/critic 0/0/0
### SEGMENT 2: iterations 1500 -> 3000 (resume='--resume logs/train/g1_amber_1h/latest.pt')
resumed logs/train/g1_amber_1h/latest.pt at iteration 1500; restored networks, normalisers, optimisers, schedule, sampler, rng, keypoint
[morphmimic] it 2900 | 1.08 it/s | mem 17.20 GB | wm loss 0.4 | J -0.2 | critic 0.1 | nonfinite wm/pol/critic 0/0/0
EOF

  # the resource sampler CSV (nvidia-smi process occupancy, NOT the torch
  # allocator view)
  cat >"$dir/17_train_resources.csv" <<'EOF'
ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,proc_rss_gb
1700000000,1200,18000,24564,12,60,11
1700000030,1400,18500,24564,13,59,12
EOF

  # the status file of the worker
  cat >"$dir/17_train.status" <<'EOF'
STATE=DONE
RC=0
STARTED_AT=2026-01-01T00:00:00Z
ITER=3000
TARGET_ITER=3000
IT_PER_S=1.0850
GPU_PEAK_MB=18500
HOST_PEAK_GB=13.00
ELAPSED=3600
FINISHED_AT=2026-01-01T01:00:00Z
EOF

  # the plan file
  cat >"$dir/17_train_plan.env" <<'EOF'
ITERATIONS=3000
LR_DECAY_ITERS=3000
CKPT_EVERY=1000
SEGMENT_ITERS=1500
BUDGET_SECONDS=3600
COMPILE=none
NUM_ENVS=1024
RUN_NAME=g1_amber_1h
ROBOT=g1_amber
TRAIN_LOG_DIR=logs/train
EOF

  # the healthy tensorboard summary (the two whitelisted tags are NaN BY
  # DESIGN under --kp-student copy)
  tb_json "$dir/tb.json" '{"n_events_files": 2, "error": null, "tags": {
    "wm/state_loss": {"n": 30, "finite": true, "max": 1.5},
    "wm/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
    "policy/objective": {"n": 30, "finite": true, "max": -0.5},
    "policy/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
    "critic/loss": {"n": 30, "finite": true, "max": 0.9},
    "critic/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
    "kp/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
    "perf/it_per_s": {"n": 30, "finite": true, "max": 1.09},
    "perf/gpu_mem_gb": {"n": 30, "finite": true, "max": 17.09},
    "kp/return": {"n": 30, "finite": false, "max": null},
    "kp/scale_return": {"n": 30, "finite": false, "max": null}
  }}'
}

# use_fixture <dir> — point every reviewer path at the fixture.
use_fixture() {
  local dir="$1"
  export TRAIN_RUN_DIR="$dir/run"
  export TRAIN_STATUS_FILE="$dir/17_train.status"
  export TRAIN_RESOURCES_CSV="$dir/17_train_resources.csv"
  export TRAIN_WORKER_LOG="$dir/17_train_worker.log"
  export TRAIN_PLAN_FILE="$dir/17_train_plan.env"
  export TRAIN_TB_FIXTURE="$dir/tb.json"
}

OUT=""
RC=0

# run_verify — run the reviewer, capture stdout+stderr and the exit code.
run_verify() {
  OUT="$(bash "$VERIFIER" verify 2>&1)"
  RC=$?
}

# assert_ok <name> — rc must be 0 and the output must carry the OK marker.
assert_ok() {
  local name="$1"
  if [ "$RC" -ne 0 ]; then
    bad "$name (rc=$RC, expected 0)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    return 1
  fi
  if ! printf '%s\n' "$OUT" | grep -q '^TRAIN_VERIFY_OK '; then
    bad "$name (no TRAIN_VERIFY_OK marker)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    return 1
  fi
  ok "$name"
  return 0
}

# assert_fail <name> <expected reason> — rc must be non-zero, the expected
# reason must be printed and NO OK marker may appear.
assert_fail() {
  local name="$1" reason="$2"
  if [ "$RC" -eq 0 ]; then
    bad "$name (rc=0, expected non-zero)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    return 1
  fi
  if printf '%s\n' "$OUT" | grep -q 'TRAIN_VERIFY_OK'; then
    bad "$name (an OK marker leaked into a failing run)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    return 1
  fi
  if ! printf '%s\n' "$OUT" | grep -q "^TRAIN_VERIFY_FAIL reason=$reason\$"; then
    bad "$name (expected reason=$reason)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    return 1
  fi
  ok "$name"
  return 0
}

# ============================================================================
# 1. the positive fixture
# ============================================================================
BASE="$TMP/base"
make_fixture "$BASE"
use_fixture "$BASE"
run_verify
assert_ok "the healthy fixture verifies"
if printf '%s\n' "$OUT" | grep -q '^TRAIN_VERIFY_OK ckpts=3 latest=1 '; then
  ok "the OK marker carries ckpts=3 latest=1"
else
  bad "the OK marker carries ckpts=3 latest=1"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi
if printf '%s\n' "$OUT" | grep -q 'resume_events=1'; then
  ok "the OK marker carries resume_events=1"
else
  bad "the OK marker carries resume_events=1"
fi
if printf '%s\n' "$OUT" | grep -q 'iterations=3000 lr_decay_iters=3000'; then
  ok "the OK marker carries the aligned iteration plan"
else
  bad "the OK marker carries the aligned iteration plan"
fi
if printf '%s\n' "$OUT" | grep -q 'nan_whitelist=2'; then
  ok "the OK marker carries nan_whitelist=2"
else
  bad "the OK marker carries nan_whitelist=2"
fi

# ============================================================================
# 19. the NaN WHITELIST does not change the exit code
# ============================================================================
# (the healthy fixture ALREADY has kp/return and kp/scale_return as NaN:
#  under --kp-student copy they are NaN by design, upstream trainer.py:1935)
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$OUT" | grep -q '^TRAIN_VERIFY_OK '; then
  ok "a NaN kp/return (whitelisted) does not change the exit code"
else
  bad "a NaN kp/return (whitelisted) does not change the exit code"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi

# ============================================================================
# 20. the reviewer is READ-ONLY
# ============================================================================
BEFORE="$(cd "$BASE/run" && ls -1 | sort)"
run_verify
AFTER="$(cd "$BASE/run" && ls -1 | sort)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "the reviewer does not write into the run directory"
else
  bad "the reviewer does not write into the run directory"
  printf '      before: %s\n      after:  %s\n' "$BEFORE" "$AFTER"
fi

# ============================================================================
# 2. only two checkpoints
# ============================================================================
D="$TMP/ckpt_count"; make_fixture "$D"; rm -f "$D/run/ckpt_3000.pt"; use_fixture "$D"
run_verify
assert_fail "two checkpoints are rejected" "ckpt-count"

# ============================================================================
# 2b. no checkpoint at all
# ============================================================================
D="$TMP/ckpt_missing"; make_fixture "$D"; rm -f "$D/run"/ckpt_*.pt; use_fixture "$D"
run_verify
assert_fail "a run without any checkpoint is rejected" "ckpt-missing"

# ============================================================================
# 3. no latest.pt
# ============================================================================
D="$TMP/latest_missing"; make_fixture "$D"; rm -f "$D/run/latest.pt"; use_fixture "$D"
run_verify
assert_fail "a missing latest.pt is rejected" "latest-missing"

# ============================================================================
# 4. an unloadable checkpoint
# ============================================================================
D="$TMP/ckpt_unloadable"; make_fixture "$D"; use_fixture "$D"
TRAIN_CKPT_LOAD_CMD="false" run_verify
assert_fail "an unloadable checkpoint is rejected" "ckpt-unloadable"
export TRAIN_CKPT_LOAD_CMD="bash $TMP/load_stub.sh"

# ============================================================================
# 5. a NaN outside the whitelist
# ============================================================================
D="$TMP/tb_nan"; make_fixture "$D"
tb_json "$D/tb.json" '{"n_events_files": 2, "error": null, "tags": {
  "wm/state_loss": {"n": 30, "finite": false, "max": null},
  "wm/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "policy/objective": {"n": 30, "finite": true, "max": -0.5},
  "policy/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "critic/loss": {"n": 30, "finite": true, "max": 0.9},
  "critic/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "kp/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "perf/it_per_s": {"n": 30, "finite": true, "max": 1.09},
  "perf/gpu_mem_gb": {"n": 30, "finite": true, "max": 17.09}
  }}'
use_fixture "$D"
run_verify
assert_fail "a NaN outside the whitelist is rejected" "tb-nonfinite"

# ============================================================================
# 6. a nonfinite_steps counter > 0
# ============================================================================
D="$TMP/tb_steps"; make_fixture "$D"
tb_json "$D/tb.json" '{"n_events_files": 2, "error": null, "tags": {
  "wm/state_loss": {"n": 30, "finite": true, "max": 1.5},
  "wm/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "policy/objective": {"n": 30, "finite": true, "max": -0.5},
  "policy/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "critic/loss": {"n": 30, "finite": true, "max": 0.9},
  "critic/nonfinite_steps": {"n": 30, "finite": true, "max": 3},
  "kp/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "perf/it_per_s": {"n": 30, "finite": true, "max": 1.09},
  "perf/gpu_mem_gb": {"n": 30, "finite": true, "max": 17.09}
  }}'
use_fixture "$D"
run_verify
assert_fail "a nonfinite_steps counter > 0 is rejected" "tb-nonfinite-steps"

# ============================================================================
# 7. a missing required tag
# ============================================================================
D="$TMP/tb_missing_tag"; make_fixture "$D"
tb_json "$D/tb.json" '{"n_events_files": 2, "error": null, "tags": {
  "wm/state_loss": {"n": 30, "finite": true, "max": 1.5},
  "wm/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "policy/objective": {"n": 30, "finite": true, "max": -0.5},
  "policy/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "critic/loss": {"n": 30, "finite": true, "max": 0.9},
  "critic/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "kp/nonfinite_steps": {"n": 30, "finite": true, "max": 0},
  "perf/it_per_s": {"n": 30, "finite": true, "max": 1.09}
  }}'
use_fixture "$D"
run_verify
assert_fail "a missing required tag is rejected" "tb-tag-missing"

# ============================================================================
# 8. no tensorboard event at all
# ============================================================================
D="$TMP/tb_no_events"; make_fixture "$D"
tb_json "$D/tb.json" '{"n_events_files": 0, "error": null, "tags": {}}'
use_fixture "$D"
run_verify
assert_fail "a run without tensorboard events is rejected" "tb-no-events"

# ============================================================================
# 9. no resume event
# ============================================================================
D="$TMP/resume_missing"; make_fixture "$D"
grep -v '^resumed ' "$BASE/17_train_worker.log" >"$D/17_train_worker.log"
use_fixture "$D"
run_verify
assert_fail "a run without a resume event is rejected" "resume-missing"

# ============================================================================
# 10. a resume at iteration 0
# ============================================================================
D="$TMP/resume_zero"; make_fixture "$D"
sed -i 's/at iteration 1500/at iteration 0/' "$D/17_train_worker.log"
use_fixture "$D"
run_verify
assert_fail "a resume at iteration 0 is rejected" "resume-iteration"

# ============================================================================
# 11. no checkpoint newer than the resume point
# ============================================================================
D="$TMP/resume_no_ckpt"; make_fixture "$D"
sed -i 's/at iteration 1500/at iteration 3000/' "$D/17_train_worker.log"
use_fixture "$D"
run_verify
assert_fail "a resume without a newer checkpoint is rejected" "resume-iteration"

# ============================================================================
# 12. a missing resource CSV
# ============================================================================
D="$TMP/res_missing"; make_fixture "$D"; rm -f "$D/17_train_resources.csv"; use_fixture "$D"
run_verify
assert_fail "a missing resource CSV is rejected" "resource-csv-missing"

# ============================================================================
# 13. a VRAM peak of 23 GiB (over the 22 GiB red line)
# ============================================================================
D="$TMP/gpu_over"; make_fixture "$D"
sed -i 's/,18000,24564/,23552,24564/' "$D/17_train_resources.csv"
use_fixture "$D"
run_verify
assert_fail "a VRAM peak of 23 GiB is rejected" "gpu-over-budget"

# ============================================================================
# 14. a host RAM peak of 46 GiB
# ============================================================================
D="$TMP/host_over"; make_fixture "$D"
sed -i 's/,12,60,11/,46,26,11/' "$D/17_train_resources.csv"
use_fixture "$D"
run_verify
assert_fail "a host RAM peak of 46 GiB is rejected" "host-over-budget"

# ============================================================================
# 15. a wall clock over the budget
# ============================================================================
D="$TMP/wall_over"; make_fixture "$D"
sed -i 's/^ELAPSED=3600/ELAPSED=7200/' "$D/17_train.status"
use_fixture "$D"
run_verify
assert_fail "a wall clock over the budget is rejected" "wall-over-budget"

# ============================================================================
# 16. iterations != lr-decay-iters
# ============================================================================
D="$TMP/iter_mismatch"; make_fixture "$D"
sed -i 's/^LR_DECAY_ITERS=3000/LR_DECAY_ITERS=2500/' "$D/17_train_plan.env"
use_fixture "$D"
run_verify
assert_fail "iterations != lr-decay-iters is rejected" "iterations-mismatch"

# ============================================================================
# 17. a failing npz gate
# ============================================================================
D="$TMP/npz_fail"; make_fixture "$D"; use_fixture "$D"
TRAIN_NPZ_VERIFY_CMD="false" run_verify
assert_fail "a failing npz gate is rejected" "npz-verify-failed"
export TRAIN_NPZ_VERIFY_CMD="true"

# ============================================================================
# 18. a failing human50 gate
# ============================================================================
D="$TMP/human_fail"; make_fixture "$D"; use_fixture "$D"
TRAIN_HUMAN_VERIFY_CMD="false" run_verify
assert_fail "a failing human50 gate is rejected" "human-verify-failed"
export TRAIN_HUMAN_VERIFY_CMD="true"

# ============================================================================
# 21. the `report` subcommand
# ============================================================================
use_fixture "$BASE"
REPORT="$(bash "$VERIFIER" report 2>&1)"
REPORT_RC=$?
if [ "$REPORT_RC" -eq 0 ]; then
  ok "the report subcommand exits 0 on a healthy fixture"
else
  bad "the report subcommand exits 0 on a healthy fixture"
  printf '%s\n' "$REPORT" | sed 's/^/      | /'
fi
for key in CKPTS ITERATIONS IT_PER_S GPU_PEAK_MB HOST_PEAK_GB WALL_S \
           TB_TAGS NONFINITE_TAGS RESUME_EVENTS OK; do
  if printf '%s\n' "$REPORT" | grep -q "^TRAIN_REPORT_$key="; then
    ok "the report prints TRAIN_REPORT_$key"
  else
    bad "the report prints TRAIN_REPORT_$key"
  fi
done
if printf '%s\n' "$REPORT" | grep -q '^TRAIN_REPORT_OK=1$'; then
  ok "the report ends with TRAIN_REPORT_OK=1"
else
  bad "the report ends with TRAIN_REPORT_OK=1"
  printf '%s\n' "$REPORT" | sed 's/^/      | /'
fi

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
