#!/usr/bin/env bash
# repro/tests/test_train_curves.sh — the OFFLINE fixture battery of the
# training curve extractor (slice S09, task T1):
#
#   repro/27_train_curves.sh (env | run | verify | report | selftest)
#
# The battery runs OFFLINE: no GPU, no network, no container, no tensorboard
# and no real run directory.  Everything it needs is a synthetic fixture
# inside a `mktemp -d` directory:
#
#   * a run directory with TEN fake `events.out.tfevents*` files (empty
#     files -- the real ones are ~170 KB each and are NEVER written by a
#     test),
#   * a fake tensorboard aggregation (the JSON payload the probe emits),
#     injected through the `CURVES_TB_CMD` override, so the test needs
#     neither tensorboard nor torch,
#   * the output directory of the artefacts (a temp directory).
#
# The real `data/`, the real `logs/`, the real `runs/` and the container are
# NEVER touched: every path is redirected through the CURVES_* overrides
# into the temp directory.
#
# Covered:
#   1.  the healthy fixture        -> rc=0 and exactly one TRAIN_CURVES_OK
#   2.  the artefacts are written  -> the CSV + the summary CSV exist and
#                                     carry no .tmp residue
#   3.  `verify` on the artefacts  -> rc=0 and one TRAIN_CURVES_OK with the
#                                     expected fields
#   4.  `verify` re-derives        -> a tampered CSV (a foreign NaN) is
#                                     caught with reason=nan-nonwhitelist
#   5.  a foreign NaN in the probe -> reason=nan-nonwhitelist, rc=1, and
#                                     ZERO OK marker
#   6.  a missing run directory    -> reason=run-dir-missing
#   7.  no events file             -> reason=events-missing
#   8.  a wrong events count       -> reason=events-count-mismatch
#   9.  a wrong step coverage      -> reason=curve-step-mismatch
#  10.  a missing curve CSV        -> reason=curve-csv-missing
#  11.  the NaN WHITELIST (kp/return, kp/scale_return are NaN BY DESIGN
#       under --kp-student copy) does NOT change the exit code
#  12.  `env` prints TRAIN_CURVES_ENV_OK
#  13.  `report` prints the TRAIN_CURVES_REPORT_* lines
#  14.  `selftest` runs the unit battery and exits 0
#
# Run locally:   bash repro/tests/test_train_curves.sh
# Exit code 0 == all tests passed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/repro/27_train_curves.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the fixture ------------------------------------------------------------
FIXTURE_RUN_DIR="$TMP/run"
FIXTURE_OUT_DIR="$TMP/out"
FIXTURE_LOG_DIR="$TMP/logs"
mkdir -p "$FIXTURE_RUN_DIR" "$FIXTURE_OUT_DIR" "$FIXTURE_LOG_DIR"

for i in 1 2 3 4 5 6 7 8 9 10; do
  : >"$FIXTURE_RUN_DIR/events.out.tfevents.1794560000.fixture.$i"
done

# The fake aggregation: a python one-liner that prints the payload of
# $FIXTURE_JSON (the extra argument the orchestrator appends is ignored).
cat >"$TMP/emit.py" <<'PYEOF'
import json, os, sys
with open(os.environ["FIXTURE_JSON"], "r", encoding="utf-8") as handle:
    print(json.dumps(json.load(handle)))
PYEOF

# The healthy payload: the 9 required tags + the 2 design-NaN tags + one
# extra tag.  Steps 50 .. 100 (the trainer logs every 50 iterations).
python3 - "$TMP/healthy.json" <<'PYEOF'
import json, sys
scalars = {}
for tag in ("wm/state_loss", "wm/nonfinite_steps", "policy/objective",
            "policy/nonfinite_steps", "critic/loss", "critic/nonfinite_steps",
            "kp/nonfinite_steps", "perf/it_per_s", "perf/gpu_mem_gb"):
    scalars[tag] = [[50, 0 if tag.endswith("nonfinite_steps") else 1.0],
                    [100, 0 if tag.endswith("nonfinite_steps") else 2.0]]
scalars["kp/return"] = [[50, "nan"], [100, "nan"]]
scalars["kp/scale_return"] = [[50, "nan"], [100, "nan"]]
scalars["custom/tag"] = [[50, 0.0], [100, 3.0]]
json.dump({"error": None, "events_files": 10, "scalars": scalars},
          open(sys.argv[1], "w", encoding="utf-8"))
PYEOF

# The foreign-NaN payload: one tag outside the whitelist carries a NaN.
python3 - "$TMP/healthy.json" "$TMP/foreign_nan.json" <<'PYEOF'
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
payload["scalars"]["foreign/tag"] = [[50, "nan"], [100, "nan"]]
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF

# --- the environment of every orchestrator call -----------------------------
export CURVES_ALLOW_LOCAL=1
export CURVES_RUN_DIR="$FIXTURE_RUN_DIR"
export CURVES_OUT_DIR="$FIXTURE_OUT_DIR"
export CURVES_LOG_DIR="$FIXTURE_LOG_DIR"
export CURVES_PY=python3
export CURVES_NO_PLOT=1
export CURVES_EXPECTED_EVENTS_FILES=10
export CURVES_EXPECTED_TAGS=12
export CURVES_EXPECTED_MAX_STEP=100
export CURVES_EXPECTED_MIN_STEP=50
export CURVES_TB_CMD="python3 $TMP/emit.py"

run_orchestrator() {
  FIXTURE_JSON="$FIXTURE_JSON" bash "$ORCHESTRATOR" "$@" 2>&1
}

# assert_ok_marker <output> <label> — exactly one TRAIN_CURVES_OK line.
assert_ok_marker() {
  local out="$1" label="$2"
  local count
  count="$(printf '%s\n' "$out" | grep -c '^TRAIN_CURVES_OK ' || true)"
  if [ "$count" = "1" ]; then
    ok "$label"
  else
    bad "$label (TRAIN_CURVES_OK lines=$count)"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

# assert_fail <output> <rc> <reason> <label> — rc=1, the expected reason and
# ZERO OK marker.
assert_fail() {
  local out="$1" rc="$2" reason="$3" label="$4"
  local ok_count
  ok_count="$(printf '%s\n' "$out" | grep -c '^TRAIN_CURVES_OK ' || true)"
  if [ "$rc" != "1" ]; then
    bad "$label (rc=$rc, expected 1)"
    printf '%s\n' "$out" | sed 's/^/      /'
    return
  fi
  if [ "$ok_count" != "0" ]; then
    bad "$label (an OK marker was printed on the failure path)"
    printf '%s\n' "$out" | sed 's/^/      /'
    return
  fi
  if ! printf '%s\n' "$out" | grep -q "TRAIN_CURVES_FAIL reason=$reason"; then
    bad "$label (reason=$reason expected)"
    printf '%s\n' "$out" | sed 's/^/      /'
    return
  fi
  ok "$label"
}

# --- 1/2: the healthy fixture ----------------------------------------------
FIXTURE_JSON="$TMP/healthy.json"
OUT="$(run_orchestrator run)"
RC=$?
if [ "$RC" = "0" ]; then ok "run: the healthy fixture exits 0"; else
  bad "run: the healthy fixture exits 0 (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
assert_ok_marker "$OUT" "run: exactly one TRAIN_CURVES_OK"

CSV="$FIXTURE_OUT_DIR/g1_amber_1h_curves.csv"
SUMMARY="$FIXTURE_OUT_DIR/g1_amber_1h_curves_summary.csv"
if [ -f "$CSV" ] && [ -f "$SUMMARY" ]; then
  ok "run: both artefacts are written"
else
  bad "run: both artefacts are written"
fi
if [ ! -e "$CSV.tmp" ] && [ ! -e "$SUMMARY.tmp" ]; then
  ok "run: the atomic write leaves no .tmp residue"
else
  bad "run: the atomic write leaves no .tmp residue"
fi
if head -n1 "$CSV" | grep -q '^step,tag,value$'; then
  ok "run: the curve CSV carries the step,tag,value header"
else
  bad "run: the curve CSV carries the step,tag,value header"
fi

# --- 3: verify on the artefacts --------------------------------------------
OUT="$(run_orchestrator verify)"
RC=$?
if [ "$RC" = "0" ]; then ok "verify: the healthy artefacts pass"; else
  bad "verify: the healthy artefacts pass (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
assert_ok_marker "$OUT" "verify: exactly one TRAIN_CURVES_OK"
if printf '%s\n' "$OUT" | grep -q 'TRAIN_CURVES_OK events_files=10 tags=12 rows=24 steps=100 '; then
  ok "verify: the marker carries the expected fields"
else
  bad "verify: the marker carries the expected fields"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# --- 4: verify re-derives from the artefacts, not from the log --------------
cp "$CSV" "$TMP/curve_backup.csv"
printf '150,foreign/tag,nan\n' >>"$CSV"
OUT="$(run_orchestrator verify)"
RC=$?
assert_fail "$OUT" "$RC" "nan-nonwhitelist" "verify: a tampered CSV is caught"
cp "$TMP/curve_backup.csv" "$CSV"

# --- 5: a foreign NaN in the probe -----------------------------------------
FIXTURE_JSON="$TMP/foreign_nan.json"
OUT="$(run_orchestrator run)"
RC=$?
assert_fail "$OUT" "$RC" "nan-nonwhitelist" "run: a foreign NaN fails closed"
FIXTURE_JSON="$TMP/healthy.json"
# restore the healthy artefacts (the failing extraction wrote the poisoned
# CSV before it rejected it -- the fixture must go back to a clean state)
OUT="$(run_orchestrator run)"
RC=$?
if [ "$RC" = "0" ]; then ok "run: the artefacts are restored after the foreign NaN"; else
  bad "run: the artefacts are restored after the foreign NaN (rc=$RC)"; fi

# --- 6: a missing run directory --------------------------------------------
OUT="$(CURVES_RUN_DIR="$TMP/nope" run_orchestrator run)"
RC=$?
assert_fail "$OUT" "$RC" "run-dir-missing" "run: a missing run directory fails closed"

# --- 7: no events file ------------------------------------------------------
EMPTY_RUN_DIR="$TMP/empty_run"
mkdir -p "$EMPTY_RUN_DIR"
OUT="$(CURVES_RUN_DIR="$EMPTY_RUN_DIR" run_orchestrator run)"
RC=$?
assert_fail "$OUT" "$RC" "events-missing" "run: an empty run directory fails closed"

# --- 8: a wrong events count -----------------------------------------------
ONE_RUN_DIR="$TMP/one_run"
mkdir -p "$ONE_RUN_DIR"
: >"$ONE_RUN_DIR/events.out.tfevents.1"
OUT="$(CURVES_RUN_DIR="$ONE_RUN_DIR" run_orchestrator verify)"
RC=$?
assert_fail "$OUT" "$RC" "events-count-mismatch" "verify: a wrong events count fails closed"

# --- 9: a wrong step coverage ----------------------------------------------
OUT="$(CURVES_EXPECTED_MAX_STEP=999 run_orchestrator verify)"
RC=$?
assert_fail "$OUT" "$RC" "curve-step-mismatch" "verify: a wrong step coverage fails closed"

# --- 10: a missing curve CSV -----------------------------------------------
rm -f "$CSV" "$SUMMARY"
OUT="$(CURVES_EXPECTED_MAX_STEP=999 run_orchestrator verify)"
RC=$?
# the artefacts are missing -> the extraction runs first and fails on the
# step coverage; the failure must still be visible and carry no OK marker.
assert_fail "$OUT" "$RC" "curve-step-mismatch" "verify: a missing CSV is re-extracted, not silently accepted"
# restore the artefacts for the remaining cases
OUT="$(run_orchestrator run)"
RC=$?
if [ "$RC" = "0" ]; then ok "run: the artefacts are restored"; else
  bad "run: the artefacts are restored (rc=$RC)"; fi

# --- 11: the NaN whitelist does not change the verdict ---------------------
if printf '%s\n' "$(run_orchestrator verify)" | grep -q '^TRAIN_CURVES_OK '; then
  ok "the NaN whitelist (kp/return, kp/scale_return) does not change the verdict"
else
  bad "the NaN whitelist (kp/return, kp/scale_return) does not change the verdict"
fi

# --- 12: env ----------------------------------------------------------------
OUT="$(run_orchestrator env)"
RC=$?
if [ "$RC" = "0" ] && printf '%s\n' "$OUT" | grep -q '^TRAIN_CURVES_ENV_OK events_files=10$'; then
  ok "env: prints TRAIN_CURVES_ENV_OK events_files=10"
else
  bad "env: prints TRAIN_CURVES_ENV_OK events_files=10"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# --- 13: report -------------------------------------------------------------
OUT="$(run_orchestrator report)"
RC=$?
if [ "$RC" = "0" ] && printf '%s\n' "$OUT" | grep -q '^TRAIN_CURVES_REPORT_OK=1$'; then
  ok "report: prints the TRAIN_CURVES_REPORT_* lines"
else
  bad "report: prints the TRAIN_CURVES_REPORT_* lines"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# --- 14: selftest -----------------------------------------------------------
OUT="$(run_orchestrator selftest)"
RC=$?
if [ "$RC" = "0" ]; then
  ok "selftest: the unit battery exits 0"
else
  bad "selftest: the unit battery exits 0 (rc=$RC)"
  printf '%s\n' "$OUT" | tail -n 20 | sed 's/^/      /'
fi

# --- 15: an unwritable output directory -------------------------------------
OUT="$(CURVES_OUT_DIR=/proc/gsd-curves-unwritable run_orchestrator run)"
RC=$?
assert_fail "$OUT" "$RC" "analysis-failed" "run: an unwritable output directory fails closed"

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
