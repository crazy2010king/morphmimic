#!/usr/bin/env bash
# repro/tests/test_seed_convert.sh — offline fixture battery for
# repro/13_seed_convert.sh (the G1 50 Hz npz conversion orchestrator) and
# repro/13_seed_convert_worker.sh (its detached body).
#
# No network, no GPU, no payload: every fixture is synthetic and lives in a
# temp dir that is removed on exit.  The battery covers the FAILURE paths of
# the orchestrator, because those are the paths that decide whether a broken
# environment can masquerade as a successful conversion:
#
#   1. the env gate fails closed when a module cannot be imported (torch
#      first: the observed `torch._vendor` failure) and prints the fix hint
#   2. the env gate fails closed on a venv path mismatch
#   3. the env gate fails closed when the probe produces no output at all
#   4. the env gate succeeds on a well-formed probe
#   5. the worker fails closed on the space gate and writes STATE=FAILED
#      WITHOUT emitting SEED_NPZ_CONVERT_OK / SEED_SUBSET_OK
#   6. `status` always exits 0 (even without a status file)
#   7. `wait` returns 1 on FAILED and 75 on timeout, and never kills anything
#   8. an unknown subcommand exits 2
#
# The env gate is exercised through the SEED_NPZ_ENV_PY knob (the command
# that runs the probe) and SEED_NPZ_ENV_EXPECT_PREFIX, so no container and no
# `uv` are needed.
#
# Run locally:   bash repro/tests/test_seed_convert.sh
# Exit code 0 == all tests passed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONVERT_SH="$REPO_ROOT/repro/13_seed_convert.sh"
WORKER_SH="$REPO_ROOT/repro/13_seed_convert_worker.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SEED_NPZ_ALLOW_LOCAL=1
export SEED_NPZ_LOG_DIR="$TMP/logs"
mkdir -p "$SEED_NPZ_LOG_DIR"

# ---------------------------------------------------------------------------
# a stub probe: prints the `key=value` lines the env gate parses
# ---------------------------------------------------------------------------
mk_stub() {
  # mk_stub <path> <torch-line> [prefix]
  local path="$1" torch_line="$2" prefix="${3:-/fake/venv}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "python=3.11"\n'
    printf 'printf "%%s\\n" "prefix=%s"\n' "$prefix"
    printf 'printf "%%s\\n" "%s"\n' "$torch_line"
    printf 'printf "%%s\\n" "ok:mujoco:3.11.0"\n'
    printf 'printf "%%s\\n" "ok:scipy:1.17.1"\n'
    printf 'printf "%%s\\n" "ok:tqdm:4.70.1"\n'
    printf 'printf "%%s\\n" "ok:pandas:3.0.6"\n'
    printf 'printf "%%s\\n" "ok:yaml:6.0.3"\n'
    # NOTE: the stub's own "exit 0" must be WRITTEN into the file, not
    # executed here — an `exit` inside this brace group would terminate the
    # whole test script.
    printf 'exit 0\n'
  } >"$path"
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# 1. the env gate fails closed on a broken torch
# ---------------------------------------------------------------------------
STUB="$TMP/stub_torch_broken.sh"
mk_stub "$STUB" "fail:torch:ModuleNotFoundError(\"No module named 'torch._vendor'\")"
OUT="$(SEED_NPZ_ENV_PY="$STUB" SEED_NPZ_ENV_EXPECT_PREFIX=/fake/venv \
      "$CONVERT_SH" env 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "the env gate fails when torch cannot be imported (rc=$RC)"
else
  bad "the env gate passed with a broken torch"
fi
case "$OUT" in
  *SEED_NPZ_ENV_FAIL*import-failed*) ok "the env gate reports reason=import-failed" ;;
  *) bad "the env gate did not report an import failure"; printf '%s\n' "$OUT" | sed 's/^/      | /' ;;
esac
case "$OUT" in
  *SEED_NPZ_ENV_OK*) bad "a failing env gate still printed SEED_NPZ_ENV_OK" ;;
  *) ok "a failing env gate prints no SEED_NPZ_ENV_OK" ;;
esac
case "$OUT" in
  *'uv sync --frozen'*) ok "a broken torch is reported with the 'uv sync --frozen' hint" ;;
  *) bad "a broken torch is reported without the fix hint"; printf '%s\n' "$OUT" | sed 's/^/      | /' ;;
esac

# ---------------------------------------------------------------------------
# 2. the env gate fails closed on a venv path mismatch
# ---------------------------------------------------------------------------
STUB_OK="$TMP/stub_ok.sh"
mk_stub "$STUB_OK" "ok:torch:2.11.0+cu128" "/wrong/venv"
OUT="$(SEED_NPZ_ENV_PY="$STUB_OK" SEED_NPZ_ENV_EXPECT_PREFIX="$REPO_ROOT/.venv" \
      "$CONVERT_SH" env 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "the env gate fails on a venv path mismatch (rc=$RC)"
else
  bad "the env gate passed with a venv path mismatch"
fi
case "$OUT" in
  *SEED_NPZ_ENV_FAIL*venv-path-mismatch*) ok "the env gate reports reason=venv-path-mismatch" ;;
  *) bad "the env gate did not report a venv path mismatch" ;;
esac
case "$OUT" in
  *SEED_NPZ_ENV_OK*) bad "a failing env gate still printed SEED_NPZ_ENV_OK" ;;
  *) ok "a failing venv check prints no SEED_NPZ_ENV_OK" ;;
esac

# ---------------------------------------------------------------------------
# 3. the env gate fails closed when the probe produces no output
# ---------------------------------------------------------------------------
STUB_EMPTY="$TMP/stub_empty.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_EMPTY"
chmod +x "$STUB_EMPTY"
OUT="$(SEED_NPZ_ENV_PY="$STUB_EMPTY" "$CONVERT_SH" env 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "the env gate fails when the probe produces no output (rc=$RC)"
else
  bad "the env gate passed with an empty probe"
fi
case "$OUT" in
  *SEED_NPZ_ENV_OK*) bad "an empty probe still printed SEED_NPZ_ENV_OK" ;;
  *) ok "an empty probe prints no SEED_NPZ_ENV_OK" ;;
esac

# ---------------------------------------------------------------------------
# 4. the env gate succeeds on a well-formed probe
# ---------------------------------------------------------------------------
# The happy path additionally needs the store links, the csv dir and the
# metadata file; they exist in this checkout (data/ and logs/ are symlinks
# into the persistent store).
mk_stub "$STUB_OK" "ok:torch:2.11.0+cu128" "$REPO_ROOT/.venv"
OUT="$(SEED_NPZ_ENV_PY="$STUB_OK" SEED_NPZ_ENV_EXPECT_PREFIX="$REPO_ROOT/.venv" \
      "$CONVERT_SH" env 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "the env gate succeeds on a well-formed probe"
else
  bad "the env gate failed on a well-formed probe (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi
case "$OUT" in
  *SEED_NPZ_ENV_OK*) ok "the env gate prints SEED_NPZ_ENV_OK" ;;
  *) bad "the env gate did not print SEED_NPZ_ENV_OK"; printf '%s\n' "$OUT" | sed 's/^/      | /' ;;
esac

# ---------------------------------------------------------------------------
# 5. the worker fails closed on the space gate
# ---------------------------------------------------------------------------
# The worker runs the env gate (stubbed) and then the space gate; a huge
# threshold must abort it BEFORE the conversion, with STATE=FAILED and
# without any *_OK marker.
OUT_DIR="$TMP/worker_out"
mkdir -p "$OUT_DIR"
WORKER_LOG_DIR="$TMP/worker_logs"
mkdir -p "$WORKER_LOG_DIR"
OUT="$(SEED_NPZ_ENV_PY="$STUB_OK" \
      SEED_NPZ_ENV_EXPECT_PREFIX="$REPO_ROOT/.venv" \
      SEED_NPZ_OUT_DIR="$OUT_DIR" \
      SEED_NPZ_LOG_DIR="$WORKER_LOG_DIR" \
      SEED_MIN_FREE_GB=99999999 \
      bash "$WORKER_SH" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "the worker fails closed on the space gate (rc=$RC)"
else
  bad "the worker passed with an impossible space threshold"
fi
case "$OUT" in
  *SEED_NPZ_FAIL*space-gate-failed*) ok "the worker reports reason=space-gate-failed" ;;
  *) bad "the worker did not report a space gate failure"; printf '%s\n' "$OUT" | sed 's/^/      | /' ;;
esac
case "$OUT" in
  *SEED_NPZ_CONVERT_OK*) bad "the worker printed SEED_NPZ_CONVERT_OK after a failed space gate" ;;
  *) ok "a failed space gate produces no SEED_NPZ_CONVERT_OK" ;;
esac
case "$OUT" in
  *SEED_SUBSET_OK*) bad "the worker printed SEED_SUBSET_OK after a failed space gate" ;;
  *) ok "a failed space gate produces no SEED_SUBSET_OK" ;;
esac
if [ -f "$WORKER_LOG_DIR/13_seed_convert.status" ]; then
  if grep -q '^STATE=FAILED$' "$WORKER_LOG_DIR/13_seed_convert.status"; then
    ok "the worker wrote STATE=FAILED to the status file"
  else
    bad "the worker did not write STATE=FAILED"
    sed 's/^/      | /' "$WORKER_LOG_DIR/13_seed_convert.status"
  fi
else
  bad "the worker wrote no status file"
fi

# ---------------------------------------------------------------------------
# 6. `status` always exits 0
# ---------------------------------------------------------------------------
OUT="$(SEED_NPZ_LOG_DIR="$TMP/empty_logs" "$CONVERT_SH" status 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "status exits 0 without a status file"
else
  bad "status exited $RC without a status file"
fi

# ---------------------------------------------------------------------------
# 7. `wait`: 1 on FAILED, 75 on timeout
# ---------------------------------------------------------------------------
WAIT_LOGS="$TMP/wait_logs"
mkdir -p "$WAIT_LOGS"
printf 'STATE=FAILED\nRC=1\nPID=0\n' >"$WAIT_LOGS/13_seed_convert.status"
OUT="$(SEED_NPZ_LOG_DIR="$WAIT_LOGS" "$CONVERT_SH" wait 5 2>&1)"
RC=$?
if [ "$RC" -eq 1 ]; then
  ok "wait returns 1 on a FAILED worker"
else
  bad "wait returned $RC on a FAILED worker (expected 1)"
fi

printf 'STATE=RUNNING\nRC=0\nPID=%s\n' "$$" >"$WAIT_LOGS/13_seed_convert.status"
OUT="$(SEED_NPZ_LOG_DIR="$WAIT_LOGS" "$CONVERT_SH" wait 1 2>&1)"
RC=$?
if [ "$RC" -eq 75 ]; then
  ok "wait returns 75 on a timeout (the worker keeps running)"
else
  bad "wait returned $RC on a timeout (expected 75)"
fi
if kill -0 "$$" 2>/dev/null; then
  ok "wait did not kill anything"
else
  bad "wait killed the caller"
fi

# ---------------------------------------------------------------------------
# 7b. `start` launches the detached worker and `wait` sees its terminal state
# ---------------------------------------------------------------------------
# A stub worker replaces the real one (SEED_NPZ_WORKER): it must write the
# terminal status file from a DETACHED process, otherwise `wait` could never
# observe DONE.
STUB_WORKER="$TMP/stub_worker.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'sleep 2\n'
  printf 'printf "STATE=DONE\\nRC=0\\nPID=%%s\\n" "$$" > "$SEED_NPZ_LOG_DIR/13_seed_convert.status"\n'
} >"$STUB_WORKER"
chmod +x "$STUB_WORKER"
DETACH_LOGS="$TMP/detach_logs"
mkdir -p "$DETACH_LOGS"
OUT="$(SEED_NPZ_LOG_DIR="$DETACH_LOGS" SEED_NPZ_WORKER="$STUB_WORKER" \
      "$CONVERT_SH" start 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "start launches the detached worker (rc=0)"
else
  bad "start exited $RC"
fi
case "$OUT" in
  *WORKER_PID=*) ok "start reports the worker PID" ;;
  *) bad "start did not report a worker PID" ;;
esac
OUT="$(SEED_NPZ_LOG_DIR="$DETACH_LOGS" SEED_NPZ_WORKER="$STUB_WORKER" \
      "$CONVERT_SH" wait 30 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "wait observes the detached worker's DONE state"
else
  bad "wait returned $RC for a finished detached worker"
fi

# ---------------------------------------------------------------------------
# 8. an unknown subcommand exits 2
# ---------------------------------------------------------------------------
"$CONVERT_SH" bogus-subcommand >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
  ok "an unknown subcommand exits 2"
else
  bad "an unknown subcommand exited $RC (expected 2)"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\n== test_seed_convert.sh: PASS=%d FAIL=%d SKIP=%d ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "ERROR: $SKIP test(s) were skipped — a SKIP must never mask a failure." >&2
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
