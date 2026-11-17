#!/usr/bin/env bash
# repro/tests/test_00_env.sh — negative / edge tests for the repro/00_env.sh
# orchestrator.
#
# The orchestrator is the piece that decides whether "the environment is
# ready", so its failure faces are the interesting ones:
#
#   * a step that exits non-zero must abort the whole run (no ENV_READY);
#   * a step that "succeeds" but does not produce its marker must abort the
#     run — and a marker left over by an EARLIER run must not satisfy the
#     check (the marker is only accepted when it was written by this run);
#   * the uv-sync step speaks the start/status/verify protocol: a FAILED
#     worker and a worker that never finishes (timeout) must both abort the
#     run;
#   * the steps must run in the order 01 -> 06;
#   * the step table must contain 06_code_read.sh and the expected marker
#     list must contain CODE_READ_OK (the one-shot orchestration is only
#     "green" when the read record's coverage gate is part of it).
#
# The tests are pure local bash: no network, no GPU, no container.  They
# source repro/00_env.sh (which does NOT run the pipeline when sourced) and
# call env_orchestrate with fake step scripts and a temporary log directory.

set -uo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_TEST_DIR/../.." && pwd)"

# shellcheck source=../00_env.sh
source "$_REPO_ROOT/repro/00_env.sh"

# common.sh enables `set -e`; the test drives commands that are expected to
# fail, so the errexit behaviour is disabled again for the whole test.
set +e

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test_00_env.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

FAILURES=0
pass() { echo "TEST ok: $*"; }
fail() { echo "TEST FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# --- fake steps ------------------------------------------------------------
#
# The fake steps write the marker lines into the log directory the
# orchestrator was given (ENV_FAKE_LOG_DIR), exactly like the real steps write
# into logs/env/.
make_fake_steps() {
  local dir="$1"
  mkdir -p "$dir"

  cat >"$dir/01_snapshot.sh" <<'EOF'
#!/usr/bin/env bash
echo "SNAPSHOT_OK" >>"$ENV_FAKE_LOG_DIR/snapshot.txt"
echo "SNAPSHOT_OK"
echo "fake snapshot done"
EOF

  cat >"$dir/02_submodules.sh" <<'EOF'
#!/usr/bin/env bash
echo "SUBMODULES_OK" >>"$ENV_FAKE_LOG_DIR/02_submodules.txt"
echo "SUBMODULES_OK"
echo "fake submodules done"
EOF

  cat >"$dir/03_uv_sync.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  start)
    {
      echo "TORCH_VERSION_2.11.0+cu128"
      echo "CUDA_AVAILABLE_TRUE"
      echo "CUDA_DEVICE_NVIDIA GeForce RTX 4090"
      echo "UV_SYNC_OK"
    } >>"$ENV_FAKE_LOG_DIR/03_uv_sync.txt"
    echo "STATE=DONE"
    ;;
  status)
    echo "STATE=$ENV_FAKE_UVSYNC_STATE"
    ;;
  verify)
    echo "UV_SYNC_OK"
    ;;
  *)
    echo "unknown subcommand" >&2
    exit 2
    ;;
esac
EOF

  cat >"$dir/04_smoke.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "NUM_ENVS_32"
  echo "REWARD_MEAN_FINITE"
  echo "SMOKE_OK"
} >>"$ENV_FAKE_LOG_DIR/04_smoke.txt"
echo "NUM_ENVS_32"
echo "REWARD_MEAN_FINITE"
echo "SMOKE_OK"
echo "fake smoke done"
EOF

  cat >"$dir/05_proxy_hygiene.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "PROXY_HYGIENE_OK"
  echo "PROXY_HYGIENE_SELFTEST_OK"
} >>"$ENV_FAKE_LOG_DIR/05_proxy_hygiene.txt"
echo "PROXY_HYGIENE_OK"
echo "PROXY_HYGIENE_SELFTEST_OK"
echo "fake proxy hygiene done"
EOF

  cat >"$dir/06_code_read.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "MODULES_TOTAL_103"
  echo "MODULES_MISSING_0"
  echo "CODE_READ_OK"
} >>"$ENV_FAKE_LOG_DIR/06_code_read.txt"
echo "MODULES_TOTAL_103"
echo "MODULES_MISSING_0"
echo "CODE_READ_OK"
echo "fake code read done"
EOF

  chmod +x "$dir"/*.sh
}

# run_orchestrator <step dir> <log dir>
#
# Runs env_orchestrate with the fake steps; stores the orchestrator's exit
# code in RC (the function itself always returns 0 so that a failing
# orchestrator cannot abort the test through errexit) and leaves the
# orchestrator log at <log dir>/00_env.txt.
RC=0
run_orchestrator() {
  local step_dir="$1" log_dir="$2"
  mkdir -p "$log_dir"
  ENV_FAKE_LOG_DIR="$log_dir"
  export ENV_FAKE_LOG_DIR
  env_orchestrate "$log_dir" "$step_dir" "$log_dir/00_env.txt" "$log_dir/00_env.status" \
    >"$log_dir/stdout.txt" 2>&1
  RC=$?
  return 0
}

# --- case 1: the happy path ------------------------------------------------
steps="$TMP_ROOT/steps_ok"
logs="$TMP_ROOT/logs_ok"
rm -rf "$logs"; mkdir -p "$logs"
make_fake_steps "$steps"
ENV_FAKE_UVSYNC_STATE=DONE
export ENV_FAKE_UVSYNC_STATE

run_orchestrator "$steps" "$logs"
rc=$RC
if [ "$rc" -eq 0 ]; then
  pass "happy path: the orchestrator exits 0"
else
  fail "happy path: expected exit 0, got $rc"
fi

for marker in SNAPSHOT_OK SUBMODULES_OK TORCH_VERSION_2.11.0+cu128 \
              CUDA_AVAILABLE_TRUE "CUDA_DEVICE_NVIDIA GeForce RTX 4090" \
              UV_SYNC_OK NUM_ENVS_32 REWARD_MEAN_FINITE SMOKE_OK \
              PROXY_HYGIENE_OK PROXY_HYGIENE_SELFTEST_OK CODE_READ_OK \
              ENV_READY; do
  if grep -aqF -- "$marker" "$logs/00_env.txt"; then
    pass "happy path: $marker is in the orchestrator log"
  else
    fail "happy path: $marker is MISSING from the orchestrator log"
  fi
done

if grep -aq '^STATE=DONE$' "$logs/00_env.status"; then
  pass "happy path: the status file says STATE=DONE"
else
  fail "happy path: the status file does not say STATE=DONE"
fi

# the steps must run in the order 01 -> 06
order="$(grep -ao '### STEP [0-9][0-9]_[a-z_]*\.sh START' "$logs/00_env.txt" \
         | sed 's/### STEP //; s/ START//' | tr '\n' ' ')"
expected_order="01_snapshot.sh 02_submodules.sh 03_uv_sync.sh 04_smoke.sh 05_proxy_hygiene.sh 06_code_read.sh "
if [ "$order" = "$expected_order" ]; then
  pass "happy path: the steps ran in the order 01 -> 06"
else
  fail "happy path: wrong step order: got [$order] expected [$expected_order]"
fi

# --- case 1b: the step table and the expected markers know about 06 -------
if env_step_table | grep -q '^06_code_read\.sh|06_code_read\.txt|simple|CODE_READ_OK$'; then
  pass "step table: 06_code_read.sh is wired in with the CODE_READ_OK marker"
else
  fail "step table: 06_code_read.sh is missing or wired in wrongly"
fi

if env_expected_markers | grep -qx 'CODE_READ_OK'; then
  pass "expected markers: CODE_READ_OK is asserted by verify"
else
  fail "expected markers: CODE_READ_OK is missing"
fi

# the toolchain probe must stay OUT of the one-shot chain: it needs the
# network and builds native bindings (~10 min), which would make the
# one-shot run fragile.
if env_step_table | grep -q '07_toolchain.sh'; then
  fail "step table: 07_toolchain.sh must NOT be part of the one-shot chain"
else
  pass "step table: 07_toolchain.sh is deliberately not part of the chain"
fi

# --- case 2: a step that fails aborts the run -----------------------------
steps="$TMP_ROOT/steps_fail"
logs="$TMP_ROOT/logs_fail"
rm -rf "$logs"; mkdir -p "$logs"
make_fake_steps "$steps"
cat >"$steps/04_smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
EOF
chmod +x "$steps/04_smoke.sh"

run_orchestrator "$steps" "$logs"
rc=$RC
if [ "$rc" -ne 0 ]; then
  pass "failing step: the orchestrator exits non-zero (rc=$rc)"
else
  fail "failing step: the orchestrator exited 0"
fi
if grep -aq '^ENV_READY$' "$logs/00_env.txt"; then
  fail "failing step: ENV_READY was written although a step failed"
else
  pass "failing step: no ENV_READY"
fi
if grep -aq '### STEP 05_proxy_hygiene.sh START' "$logs/00_env.txt"; then
  fail "failing step: the run continued after the failing step"
else
  pass "failing step: the run stopped at the failing step"
fi
if grep -aq '^STATE=FAILED$' "$logs/00_env.status"; then
  pass "failing step: the status file says STATE=FAILED"
else
  fail "failing step: the status file does not say STATE=FAILED"
fi

# --- case 3: a stale marker does not satisfy the check ---------------------
steps="$TMP_ROOT/steps_stale"
logs="$TMP_ROOT/logs_stale"
rm -rf "$logs"; mkdir -p "$logs"
make_fake_steps "$steps"
# the marker of step 01 is already in the log from an earlier run, and this
# run's step 01 writes NOTHING -> the marker must not be accepted.
echo "SNAPSHOT_OK" >"$logs/snapshot.txt"
cat >"$steps/01_snapshot.sh" <<'EOF'
#!/usr/bin/env bash
echo "snapshot done but without the marker"
EOF
chmod +x "$steps/01_snapshot.sh"

run_orchestrator "$steps" "$logs"
rc=$RC
if [ "$rc" -ne 0 ]; then
  pass "stale marker: the orchestrator exits non-zero (rc=$rc)"
else
  fail "stale marker: the orchestrator accepted a marker from an earlier run"
fi
if grep -aq '^ENV_READY$' "$logs/00_env.txt"; then
  fail "stale marker: ENV_READY was written although a marker was missing"
else
  pass "stale marker: no ENV_READY"
fi

# --- case 4: the uv-sync worker reports FAILED -----------------------------
steps="$TMP_ROOT/steps_uvfailed"
logs="$TMP_ROOT/logs_uvfailed"
rm -rf "$logs"; mkdir -p "$logs"
make_fake_steps "$steps"
ENV_FAKE_UVSYNC_STATE=FAILED
export ENV_FAKE_UVSYNC_STATE

run_orchestrator "$steps" "$logs"
rc=$RC
if [ "$rc" -ne 0 ]; then
  pass "uv-sync FAILED: the orchestrator exits non-zero (rc=$rc)"
else
  fail "uv-sync FAILED: the orchestrator exited 0"
fi
if grep -aq '^ENV_READY$' "$logs/00_env.txt"; then
  fail "uv-sync FAILED: ENV_READY was written"
else
  pass "uv-sync FAILED: no ENV_READY"
fi

# --- case 5: the uv-sync worker never finishes (timeout) -------------------
steps="$TMP_ROOT/steps_uvtimeout"
logs="$TMP_ROOT/logs_uvtimeout"
rm -rf "$logs"; mkdir -p "$logs"
make_fake_steps "$steps"
ENV_FAKE_UVSYNC_STATE=RUNNING
export ENV_FAKE_UVSYNC_STATE
ENV_UVSYNC_TIMEOUT=1
export ENV_UVSYNC_TIMEOUT

run_orchestrator "$steps" "$logs"
rc=$RC
if [ "$rc" -ne 0 ]; then
  pass "uv-sync timeout: the orchestrator exits non-zero (rc=$rc)"
else
  fail "uv-sync timeout: the orchestrator exited 0"
fi
if grep -aq 'uvsync TIMEOUT' "$logs/00_env.txt"; then
  pass "uv-sync timeout: the timeout is recorded in the log"
else
  fail "uv-sync timeout: the timeout is NOT recorded in the log"
fi
if grep -aq '^ENV_READY$' "$logs/00_env.txt"; then
  fail "uv-sync timeout: ENV_READY was written"
else
  pass "uv-sync timeout: no ENV_READY"
fi
unset ENV_UVSYNC_TIMEOUT

# --- case 6: a missing step script aborts the run -------------------------
steps="$TMP_ROOT/steps_missing"
logs="$TMP_ROOT/logs_missing"
rm -rf "$logs"; mkdir -p "$logs"
make_fake_steps "$steps"
rm -f "$steps/02_submodules.sh"

run_orchestrator "$steps" "$logs"
rc=$RC
if [ "$rc" -ne 0 ]; then
  pass "missing step: the orchestrator exits non-zero (rc=$rc)"
else
  fail "missing step: the orchestrator exited 0"
fi
if grep -aq 'script not found' "$logs/00_env.txt"; then
  pass "missing step: the reason is recorded in the log"
else
  fail "missing step: the reason is NOT recorded in the log"
fi

# --- case 7: the orchestrator itself carries no proxy variable ------------
# repro/05_proxy_hygiene.sh asserts that no ANCESTOR process exposes a proxy
# variable — the orchestrator is such an ancestor, so it must stay clean.
if env | grep -qi 'proxy'; then
  fail "proxy hygiene: the orchestrator process exposes a proxy variable"
else
  pass "proxy hygiene: the orchestrator process carries no proxy variable"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "TESTS_FAILED ($FAILURES failing case(s))"
  exit 1
fi
echo "TESTS_OK"
