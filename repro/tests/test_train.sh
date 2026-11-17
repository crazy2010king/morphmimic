#!/usr/bin/env bash
# repro/tests/test_train.sh — offline fixture battery for the decision base
# of the g1_amber training run (slice S06):
#
#   * repro/lib/train.py  — the stdlib-only pure-function library
#   * repro/lib/train.sh  — the thin shell wrapper
#   * repro/tests/test_train.py — the library-level unit tests
#
# The battery is built on synthetic fixtures ONLY: a fake upstream training
# log, a fake resource sampler CSV and a fake status file, all created in a
# `mktemp -d` directory that is removed on exit.  The real payload (`data/`),
# the real logs (`logs/`), `.gsd/` and any other ignored path are NEVER read;
# no network access, no GPU, no container required.
#
# Only the python3 standard library is used — the container's system python3
# has NO numpy, therefore numpy is forbidden here.
#
# Covered:
#   1. the fixture is created
#   2. POSITIVE: an iteration line yields it / it/s / mem GB
#   3. POSITIVE: the `resumed <path> at iteration N` evidence is extracted
#   4. POSITIVE: plan_iterations(28800, 1.09, 0.85) == floor(...)
#   5. POSITIVE: plan_ckpt_every guarantees >= min_ckpts checkpoints
#   6. POSITIVE: budget_ok is True inside the budget
#   7. POSITIVE: the NaN whitelist accepts kp/return = NaN
#   8. NEGATIVE: it_per_s = 0 -> plan_iterations returns 0 (no exception)
#   9. NEGATIVE: 23 GB of VRAM -> budget_ok False, reason mentions 显存
#  10. NEGATIVE: 46 GB of host RAM -> budget_ok False
#  11. NEGATIVE: wall clock over budget -> budget_ok False
#  12. NEGATIVE: a resource CSV with a missing column -> parse_resource_csv
#      returns None
#  13. NEGATIVE: a NaN outside the whitelist -> nan_audit False, bad tag
#  14. NEGATIVE: nonfinite_steps > 0 -> the violation is listed
#  15. NEGATIVE: a missing required tag -> the missing tag is listed
#  16. the status file round trip leaves no .tmp residue
#  17. the thin wrapper repro/lib/train.sh forwards to train.py
#  18. the library-level unit tests (repro/tests/test_train.py) are green
#  19. SOURCE LEVEL: train.py / test_train.py import no third-party module
#  20. SOURCE LEVEL: train.sh contains no decision logic (only a wrapper)
#
# Run locally:   bash repro/tests/test_train.sh
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
PY_LIB="$LIB_DIR/train.py"
SH_LIB="$LIB_DIR/train.sh"
PY_TEST="$REPO_ROOT/repro/tests/test_train.py"

PASS=0
FAIL=0
SKIP=0
python_bin="${TRAIN_PY:-python3}"

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

LOG="$TMP/train.log"
RES_CSV="$TMP/resources.csv"
BAD_CSV="$TMP/resources_bad.csv"
STATUS="$TMP/17_train.status"

# ============================================================================
# 0. the fixture builder (stdlib only) + the fixture itself
# ============================================================================
cat >"$TMP/make_fixture.py" <<'PYFIXTURE'
import os
import sys

TMP = sys.argv[1]

# One real upstream iteration line (probe1.log, 2026-11-13), flattened.
IT_LINE = (
  "[morphmimic] it 20 | 1.09 it/s (0.054/0.294/0.568 s collect/wm/actor-critic)"
  " | env 2905/s imag 286039/s"
  " | wm loss 318.4488 bce 0.0071 pred8 0.4472 err8 pelvis 0.018 m"
  " joints 0.048 rad"
  " | J 0.8706 |g| 0.208 (max 0.394) critic 7.65e-03 V0 0.81 tclip 0.00%"
  " surv 0.273"
  " | rew 0.0358 nret 0.386 eplen 34.5 fail 350"
  " | nonfinite wm/pol/critic 0/0/0 | mem 17.09 GB"
  " | kp J nan act 0.0000 align 0.5910"
)

RESUME_LINE = (
  "[morphmimic] resumed logs/_probe/probe1/latest.pt at iteration 20;"
  " restored networks, normalisers, optimisers, schedule, sampler, rng,"
  " keypoint"
)

with open(os.path.join(TMP, "train.log"), "w", encoding="utf-8") as handle:
  handle.write("[morphmimic] run dir: logs/train/g1_amber_1h\n")
  handle.write(IT_LINE + "\n")
  handle.write(RESUME_LINE + "\n")
  handle.write(
    "[morphmimic] it 40 | 1.12 it/s | wm loss 2.0 | J 0.4 critic 1e-03"
    " | nonfinite wm/pol/critic 0/0/0 | mem 18.50 GB"
    " | kp J nan act 0.0 align 0.5\n")

with open(os.path.join(TMP, "resources.csv"), "w", encoding="utf-8") as handle:
  handle.write(
    "ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,"
    "proc_rss_gb\n")
  handle.write("1700000000,100,12000,24564,10.5,51.0,8.2\n")
  handle.write("1700000030,200,18050,24564,12.5,49.0,9.1\n")

with open(os.path.join(TMP, "resources_bad.csv"), "w", encoding="utf-8") as handle:
  handle.write("ts,iter,gpu_used_mb\n")
  handle.write("1700000000,100,12000\n")
PYFIXTURE

if "$python_bin" "$TMP/make_fixture.py" "$TMP" >/dev/null 2>&1 \
  && [ -s "$LOG" ] && [ -s "$RES_CSV" ] && [ -s "$BAD_CSV" ]; then
  ok "fixture created (log / resources csv / bad csv)"
else
  bad "fixture creation failed"
  printf 'FAIL=1\n'
  exit 1
fi

# ============================================================================
# 1-16: the python decision battery (stdlib only, no numpy)
# ============================================================================
cat >"$TMP/battery.py" <<'PYBATTERY'
import math
import os
import sys

LIB_DIR = sys.argv[1]
TMP = sys.argv[2]
LOG = os.path.join(TMP, "train.log")
RES_CSV = os.path.join(TMP, "resources.csv")
BAD_CSV = os.path.join(TMP, "resources_bad.csv")
STATUS = os.path.join(TMP, "17_train.status")

sys.path.insert(0, LIB_DIR)
import train  # noqa: E402

FAILURES = []
PASSES = []


def check(name, condition, detail=""):
  if condition:
    PASSES.append(name)
  else:
    FAILURES.append("%s%s" % (name, (" :: " + str(detail)) if detail else ""))


# --- 2. POSITIVE: an iteration line yields it / it/s / mem GB --------------
parsed = train.parse_log_line(
  "[morphmimic] it 20 | 1.09 it/s | wm loss 318.4488 | J 0.8706"
  " critic 7.65e-03 | nonfinite wm/pol/critic 0/0/0 | mem 17.09 GB")
check("2 iteration line parsed", parsed is not None)
if parsed:
  check("2 it == 20", parsed["it"] == 20, parsed)
  check("2 it_per_s == 1.09", abs(parsed["it_per_s"] - 1.09) < 1e-9, parsed)
  check("2 mem_gb == 17.09", abs(parsed["mem_gb"] - 17.09) < 1e-9, parsed)

# --- 3. POSITIVE: the resume evidence is extracted --------------------------
summary = train.parse_log_file(LOG)
check("3 log summary exists", summary is not None)
if summary:
  events = summary["resume_events"]
  check("3 one resume event", len(events) == 1, events)
  check("3 resume path", events and events[0][0] == "logs/_probe/probe1/latest.pt", events)
  check("3 resume iteration", events and events[0][1] == 20, events)
  check("3 max_it == 40", summary["max_it"] == 40, summary)
  check("3 mem peak", abs(summary["mem_gb_peak"] - 18.50) < 1e-9, summary)

# --- 4. POSITIVE: plan_iterations ------------------------------------------
expected = math.floor(28800 * 1.09 * 0.85)
check("4 plan_iterations", train.plan_iterations(28800, 1.09, 0.85) == expected,
      train.plan_iterations(28800, 1.09, 0.85))

# --- 5. POSITIVE: plan_ckpt_every ------------------------------------------
every = train.plan_ckpt_every(26683, 3)
check("5 ckpt_every >= 1000", every >= 1000, every)
check("5 ckpt_every multiple of 1000", every % 1000 == 0, every)
check("5 ckpt count >= min", train.ckpt_count(26683, every) >= 3,
      (every, train.ckpt_count(26683, every)))

# --- 6. POSITIVE: budget_ok inside the budget ------------------------------
ok, reasons = train.budget_ok(18000, 12.0, 28000, {"wall_max_s": 28800})
check("6 budget_ok inside", ok is True and reasons == [], (ok, reasons))

# --- 7. POSITIVE: the NaN whitelist accepts kp/return = NaN ----------------
scalars = {
  "wm/state_loss": [1.0],
  "wm/nonfinite_steps": [0],
  "policy/objective": [0.5],
  "policy/nonfinite_steps": [0],
  "critic/loss": [0.001],
  "critic/nonfinite_steps": [0],
  "kp/nonfinite_steps": [0],
  "perf/it_per_s": [1.09],
  "perf/gpu_mem_gb": [17.09],
  "kp/return": [float("nan")],
  "kp/scale_return": [float("nan")],
}
ok, bad_tags, missing, violations = train.nan_audit(scalars)
check("7 whitelist NaN accepted", ok is True, (bad_tags, missing, violations))

# --- 8. NEGATIVE: it_per_s = 0 --------------------------------------------
value = train.plan_iterations(28800, 0, 0.85)
check("8 plan_iterations(0 it/s) == 0", value == 0, value)
check("8 plan_iterations never negative", value >= 0, value)

# --- 9. NEGATIVE: 23 GB of VRAM --------------------------------------------
ok, reasons = train.budget_ok(23 * 1024, 12.0, 100, {"wall_max_s": 28800})
check("9 gpu over budget -> False", ok is False, ok)
check("9 gpu reason mentions 显存",
      any("显存" in r for r in reasons), reasons)

# --- 10. NEGATIVE: 46 GB of host RAM ---------------------------------------
ok, reasons = train.budget_ok(18000, 46.0, 100, {"wall_max_s": 28800})
check("10 host over budget -> False", ok is False, ok)
check("10 host reason mentions 主机内存",
      any("主机内存" in r for r in reasons), reasons)

# --- 11. NEGATIVE: wall clock over budget ----------------------------------
ok, reasons = train.budget_ok(18000, 12.0, 30000, {"wall_max_s": 28800})
check("11 wall over budget -> False", ok is False, ok)
check("11 wall reason mentions 墙钟", any("墙钟" in r for r in reasons), reasons)

# --- 12. NEGATIVE: a resource CSV with a missing column --------------------
check("12 bad resource csv -> None", train.parse_resource_csv(BAD_CSV) is None)
parsed_csv = train.parse_resource_csv(RES_CSV)
check("12 good resource csv parsed", parsed_csv is not None)
if parsed_csv:
  check("12 gpu peak", abs(parsed_csv["gpu_used_mb_peak"] - 18050.0) < 1e-6,
        parsed_csv)
  check("12 host peak", abs(parsed_csv["host_used_gb_peak"] - 12.5) < 1e-9,
        parsed_csv)
  check("12 samples", parsed_csv["samples"] == 2, parsed_csv)

# --- 13. NEGATIVE: a NaN outside the whitelist -----------------------------
scalars_bad = dict(scalars)
scalars_bad["wm/state_loss"] = [float("nan")]
ok, bad_tags, missing, violations = train.nan_audit(scalars_bad)
check("13 foreign NaN -> False", ok is False, ok)
check("13 bad tag listed", "wm/state_loss" in bad_tags, bad_tags)

# --- 14. NEGATIVE: nonfinite_steps > 0 -------------------------------------
scalars_nf = dict(scalars)
scalars_nf["policy/nonfinite_steps"] = [0, 1]
ok, bad_tags, missing, violations = train.nan_audit(scalars_nf)
check("14 nonfinite_steps violation -> False", ok is False, ok)
check("14 violation listed",
      any("policy/nonfinite_steps" in v for v in violations), violations)

# --- 15. NEGATIVE: a missing required tag ----------------------------------
scalars_missing = dict(scalars)
del scalars_missing["perf/gpu_mem_gb"]
ok, bad_tags, missing, violations = train.nan_audit(scalars_missing)
check("15 missing tag -> False", ok is False, ok)
check("15 missing tag listed", "perf/gpu_mem_gb" in missing, missing)

# --- 16. the status file round trip ----------------------------------------
train.write_status(STATUS, "DONE", 0, {"ITER": "26683", "IT_PER_S": "1.09"})
status = train.read_status(STATUS)
check("16 status STATE", status.get("STATE") == "DONE", status)
check("16 status RC", status.get("RC") == "0", status)
check("16 status ITER", status.get("ITER") == "26683", status)
check("16 no .tmp residue", not os.path.exists(STATUS + ".tmp"),
      os.listdir(TMP))

for name in PASSES:
  print("PASS  %s" % name)
for name in FAILURES:
  print("FAIL  %s" % name)
print("BATTERY_FAIL=%d" % len(FAILURES))
sys.exit(1 if FAILURES else 0)
PYBATTERY

BATTERY_OUT="$TMP/battery.out"
if "$python_bin" "$TMP/battery.py" "$LIB_DIR" "$TMP" >"$BATTERY_OUT" 2>&1; then
  while IFS= read -r line; do
    case "$line" in
      PASS\ *) ok "${line#PASS  }" ;;
      FAIL\ *) bad "${line#FAIL  }" ;;
    esac
  done <"$BATTERY_OUT"
  ok "python decision battery green"
else
  while IFS= read -r line; do
    case "$line" in
      PASS\ *) ok "${line#PASS  }" ;;
      FAIL\ *) bad "${line#FAIL  }" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$BATTERY_OUT"
  bad "python decision battery"
fi

# ============================================================================
# 17. the thin wrapper forwards to train.py
# ============================================================================
WRAP_OUT="$TMP/wrap.out"
if bash "$SH_LIB" log-summary "$LOG" >"$WRAP_OUT" 2>&1 \
  && grep -q '"max_it": 40' "$WRAP_OUT"; then
  ok "train.sh log-summary forwards to train.py"
else
  bad "train.sh log-summary forwarding"
  printf '%s\n' "$WRAP_OUT"
fi

if bash "$SH_LIB" plan --budget-seconds 28800 --it-per-s 1.09 >"$WRAP_OUT" 2>&1 \
  && grep -q '^iterations=26683$' "$WRAP_OUT" \
  && grep -q '^lr_decay_iters=26683$' "$WRAP_OUT"; then
  ok "train.sh plan is self-consistent (iterations == lr_decay_iters)"
else
  bad "train.sh plan output"
fi

# ============================================================================
# 19. SOURCE LEVEL: train.py uses the standard library ONLY (no numpy)
# ============================================================================
if grep -Eq '^[[:space:]]*(import|from)[[:space:]]+(numpy|scipy|torch|pandas)' "$PY_LIB"; then
  bad "train.py imports a third-party module (numpy/torch/... forbidden)"
else
  ok "train.py imports no third-party module"
fi

if grep -Eq '^[[:space:]]*(import|from)[[:space:]]+(numpy|scipy|torch|pandas)' "$PY_TEST"; then
  bad "test_train.py imports a third-party module (numpy/torch/... forbidden)"
else
  ok "test_train.py imports no third-party module"
fi

# ============================================================================
# 20. SOURCE LEVEL: train.sh carries no decision logic
# ============================================================================
if grep -Eq 'awk|grep|sed .*=>|python -c|import numpy' "$SH_LIB"; then
  bad "train.sh contains decision logic (must be a thin wrapper)"
else
  ok "train.sh has no decision logic"
fi

# ============================================================================
# 18. the library-level unit tests
# ============================================================================
UNIT_OUT="$TMP/unit.out"
if "$python_bin" "$PY_TEST" >"$UNIT_OUT" 2>&1; then
  ok "repro/tests/test_train.py green"
else
  bad "repro/tests/test_train.py"
  tail -n 30 "$UNIT_OUT"
fi

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
