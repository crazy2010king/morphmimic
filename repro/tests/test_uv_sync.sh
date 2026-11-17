#!/usr/bin/env bash
# repro/tests/test_uv_sync.sh — negative/edge-case tests for the helpers in
# repro/lib/uvsync.sh (used by repro/03_uv_sync.sh).
#
# These tests are pure-local: they use throwaway directories under $TMPDIR
# and fake interpreters, so they need neither network, GPU nor uv.
#
# Covered failure surfaces:
#   1. uvsync_managed_python_path: a *system* interpreter does NOT count as
#      managed (that would silently skip the managed-cpython requirement),
#      an unknown version returns non-zero; the glob fallback finds a
#      managed interpreter through UV_PYTHON_SEARCH_ROOTS (single root and
#      colon-separated list), while the production default roots stay
#      unchanged (MEM021 hermeticity fix: the assertions must hold on a
#      developer box without uv AND in the container that really has
#      /root/.local/share/uv/python/cpython-3.11-* installed)
#   2. uvsync_requires_managed_python: inverted polarity (present -> "no
#      download needed", absent -> "download needed")
#   3. uvsync_check_venv: rejects a missing venv, a non-executable python,
#      and a venv that lives OUTSIDE the worktree root (the real hazard:
#      UV_PROJECT_ENVIRONMENT pointing elsewhere); accepts a valid one and
#      prints the VENV_PYTHON_/VENV_PYTHON_VERSION_ markers
#   4. uvsync_log_has / uvsync_require_log_markers: missing log file,
#      missing marker, and the "all markers present" case
#
# Run locally:  bash repro/tests/test_uv_sync.sh
# Run remotely: bash repro/lib/remote.sh tests/test_uv_sync.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=repro/lib/uvsync.sh
source "$LIB_DIR/uvsync.sh"

# common.sh turns on `errexit`; this file drives commands that are EXPECTED
# to fail, so switch it back off for the assertions below.
set +e

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fake interpreters -----------------------------------------------------
# A "system" python: not under a uv python root -> must NOT count as managed.
mkdir -p "$TMP/system/bin"
cat >"$TMP/system/bin/python3.11" <<'EOF'
#!/usr/bin/env bash
echo "Python 3.11.99 (fake)"
EOF
chmod +x "$TMP/system/bin/python3.11"

# A "managed" python: under a uv python root -> must count as managed.
mkdir -p "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin"
cat >"$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11" <<'EOF'
#!/usr/bin/env bash
echo "Python 3.11.16 (fake managed)"
EOF
chmod +x "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11"

# --- 1. managed python detection ------------------------------------------
# These assertions must hold IDENTICALLY on a developer box without uv and in
# the ros_dev container, which really does have
# /root/.local/share/uv/python/cpython-3.11-* installed. Therefore every
# invocation isolates BOTH uv fallbacks:
#   * `uv` is replaced by a stub on PATH, so neither `uv python find` nor
#     `uv python list --only-installed` can see the real installation;
#   * the glob fallback root list is overridden with UV_PYTHON_SEARCH_ROOTS
#     pointing at an empty directory, so a real managed interpreter on the
#     machine cannot be picked up either.
# (MEM021: the previous version only stubbed `uv python find` and therefore
#  failed inside the container, where the fallback correctly found the real
#  managed interpreter.)
mkdir -p "$TMP/stub" "$TMP/empty_roots"

# Stub `uv` so the test does not depend on the real uv installation.
cat >"$TMP/stub/uv" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "python find 3.11")
    if [ -x "$TMP/system/bin/python3.11" ]; then
      echo "$TMP/system/bin/python3.11"; exit 0
    fi
    exit 1
    ;;
  "python find 3.99")
    exit 1
    ;;
  "python list --only-installed")
    # No managed interpreter is visible through the uv fallback.
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$TMP/stub/uv"

rc=0
path="$(UV_PYTHON_SEARCH_ROOTS="$TMP/empty_roots" PATH="$TMP/stub:$PATH" uvsync_managed_python_path 3.11 2>/dev/null)" || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_managed_python_path rejects a SYSTEM interpreter as 'managed'"
else
  bad "uvsync_managed_python_path accepted a system interpreter (path=$path)"
fi

rc=0
UV_PYTHON_SEARCH_ROOTS="$TMP/empty_roots" PATH="$TMP/stub:$PATH" \
  uvsync_managed_python_path 3.99 >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_managed_python_path returns non-zero for an unknown version"
else
  bad "uvsync_managed_python_path returned 0 for an unknown version"
fi

# With the managed interpreter visible, detection must succeed.
cat >"$TMP/stub/uv" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "python find 3.11") echo "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11"; exit 0 ;;
  "python list --only-installed") exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/stub/uv"
rc=0
path="$(UV_PYTHON_SEARCH_ROOTS="$TMP/empty_roots" PATH="$TMP/stub:$PATH" uvsync_managed_python_path 3.11 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$path" = "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11" ]; then
  ok "uvsync_managed_python_path finds a uv-managed interpreter"
else
  bad "uvsync_managed_python_path did not find the managed interpreter (rc=$rc path=$path)"
fi

# --- 1b. the glob fallback must find a managed interpreter ------------------
# `uv` knows nothing here (find fails, list is empty): the managed
# interpreter must still be detected through the UV_PYTHON_SEARCH_ROOTS glob.
cat >"$TMP/stub/uv" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "python list --only-installed") exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/stub/uv"
rc=0
path="$(UV_PYTHON_SEARCH_ROOTS="$TMP/uv/share/uv/python" PATH="$TMP/stub:$PATH" uvsync_managed_python_path 3.11 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$path" = "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11" ]; then
  ok "uvsync_managed_python_path finds a managed interpreter through UV_PYTHON_SEARCH_ROOTS"
else
  bad "UV_PYTHON_SEARCH_ROOTS fallback did not find the managed interpreter (rc=$rc path=$path)"
fi

# A UV_PYTHON_SEARCH_ROOTS list may hold several colon-separated roots; the
# first one that contains an interpreter wins.
mkdir -p "$TMP/uv2/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin"
cat >"$TMP/uv2/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11" <<'EOF'
#!/usr/bin/env bash
echo "Python 3.11.16 (fake managed, second root)"
EOF
chmod +x "$TMP/uv2/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11"
rc=0
path="$(UV_PYTHON_SEARCH_ROOTS="$TMP/empty_roots:$TMP/uv2/share/uv/python" PATH="$TMP/stub:$PATH" uvsync_managed_python_path 3.11 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$path" = "$TMP/uv2/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11" ]; then
  ok "uvsync_managed_python_path honours a colon-separated UV_PYTHON_SEARCH_ROOTS list"
else
  bad "colon-separated UV_PYTHON_SEARCH_ROOTS was not honoured (rc=$rc path=$path)"
fi

# --- 1c. the production defaults must be unchanged -------------------------
# Without UV_PYTHON_SEARCH_ROOTS the search roots are exactly the S01 ones.
roots="$( unset UV_PYTHON_INSTALL_DIR UV_PYTHON_SEARCH_ROOTS; uvsync_python_search_roots )"
if [ "$roots" = "$HOME/.local/share/uv/python
/root/.local/share/uv/python" ]; then
  ok "the default uv python search roots are unchanged"
else
  bad "the default uv python search roots changed (roots=$(tr '\n' ' ' <<<"$roots"))"
fi

# UV_PYTHON_INSTALL_DIR keeps its historical precedence.
roots="$( UV_PYTHON_INSTALL_DIR="$TMP/uv/share/uv/python" UV_PYTHON_SEARCH_ROOTS= uvsync_python_search_roots )"
first="$(head -n1 <<<"$roots")"
if [ "$first" = "$TMP/uv/share/uv/python" ]; then
  ok "UV_PYTHON_INSTALL_DIR still takes precedence over the default search roots"
else
  bad "UV_PYTHON_INSTALL_DIR no longer takes precedence (first=$first)"
fi

# And the same default search root still finds a managed interpreter.
rc=0
path="$( UV_PYTHON_INSTALL_DIR="$TMP/uv/share/uv/python" PATH="$TMP/stub:$PATH" \
          uvsync_managed_python_path 3.11 2>/dev/null )" || rc=$?
if [ "$rc" -eq 0 ] && [ "$path" = "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11" ]; then
  ok "uvsync_managed_python_path finds a managed interpreter under UV_PYTHON_INSTALL_DIR"
else
  bad "UV_PYTHON_INSTALL_DIR fallback did not find the managed interpreter (rc=$rc path=$path)"
fi

# Restore the stub that reports the managed interpreter through `uv python find`
# for the polarity checks below.
cat >"$TMP/stub/uv" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "python find 3.11") echo "$TMP/uv/share/uv/python/cpython-3.11.16-linux-x86_64-gnu/bin/python3.11"; exit 0 ;;
  "python find 3.99") exit 1 ;;
  "python list --only-installed") exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/stub/uv"

# --- 2. requires_managed_python polarity ----------------------------------
rc=0
UV_PYTHON_SEARCH_ROOTS="$TMP/empty_roots" PATH="$TMP/stub:$PATH" \
  uvsync_requires_managed_python 3.11 >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_requires_managed_python reports 'no download needed' when managed python exists"
else
  bad "uvsync_requires_managed_python must return non-zero when the interpreter exists"
fi

rc=0
UV_PYTHON_SEARCH_ROOTS="$TMP/empty_roots" PATH="$TMP/stub:$PATH" \
  uvsync_requires_managed_python 3.99 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "uvsync_requires_managed_python reports 'download needed' when the interpreter is missing"
else
  bad "uvsync_requires_managed_python must return 0 when the interpreter is missing"
fi

# --- 3. venv location assertion -------------------------------------------
FAKE_ROOT="$TMP/repo"
mkdir -p "$FAKE_ROOT"

# 3a. missing venv -> non-zero
rc=0
uvsync_check_venv "$FAKE_ROOT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_check_venv rejects a missing .venv"
else
  bad "uvsync_check_venv accepted a missing .venv"
fi

# 3b. non-executable python -> non-zero
mkdir -p "$FAKE_ROOT/.venv/bin"
: >"$FAKE_ROOT/.venv/bin/python"
chmod -x "$FAKE_ROOT/.venv/bin/python"
rc=0
uvsync_check_venv "$FAKE_ROOT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_check_venv rejects a non-executable .venv/bin/python"
else
  bad "uvsync_check_venv accepted a non-executable .venv/bin/python"
fi

# 3c. the .venv DIRECTORY symlinked outside the worktree root -> non-zero
#     (the UV_PROJECT_ENVIRONMENT hazard: deploy/install_pico.sh expects
#      <repo>/.venv/bin/python to live in the worktree)
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE/.venv/bin"
cat >"$OUTSIDE/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
echo "Python 3.11.16 (outside)"
EOF
chmod +x "$OUTSIDE/.venv/bin/python"

mkdir -p "$FAKE_ROOT/.venv/bin"
rm -rf "$FAKE_ROOT/.venv"
ln -sfn "$OUTSIDE/.venv" "$FAKE_ROOT/.venv"
rc=0
uvsync_check_venv "$FAKE_ROOT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_check_venv rejects a .venv symlinked outside the worktree root"
else
  bad "uvsync_check_venv accepted a .venv symlinked outside the worktree root"
fi

# 3d. a real venv whose bin/python points at the base interpreter outside
#     the worktree (exactly how uv creates it) must still be ACCEPTED
rm -rf "$FAKE_ROOT/.venv"
mkdir -p "$FAKE_ROOT/.venv/bin"
ln -sfn "$OUTSIDE/.venv/bin/python" "$FAKE_ROOT/.venv/bin/python"
rc=0
uvsync_check_venv "$FAKE_ROOT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "uvsync_check_venv accepts a real venv whose python symlink points at the base interpreter"
else
  bad "uvsync_check_venv rejected a legitimate uv-style venv (rc=$rc)"
fi

# 3e. a valid venv inside the root -> 0 plus the expected markers
cat >"$FAKE_ROOT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
echo "Python 3.11.16 (fake venv)"
EOF
chmod +x "$FAKE_ROOT/.venv/bin/python"
out="$TMP/venv.out"
rc=0
uvsync_check_venv "$FAKE_ROOT" >"$out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q "^VENV_PYTHON_" "$out" \
   && grep -q "^VENV_PYTHON_VERSION_Python 3.11.16" "$out"; then
  ok "uvsync_check_venv accepts a valid venv and prints the markers"
else
  bad "uvsync_check_venv rejected a valid venv (rc=$rc out=$(tr '\n' ' ' <"$out"))"
fi

# --- 4. log marker helpers -------------------------------------------------
LOG="$TMP/markers.log"
printf 'TORCH_VERSION_2.11.0+cu128\nCUDA_AVAILABLE_TRUE\n' >"$LOG"

rc=0
uvsync_log_has "$LOG" "TORCH_VERSION_2.11.0+cu128" || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "uvsync_log_has finds an existing marker"
else
  bad "uvsync_log_has missed an existing marker"
fi

rc=0
uvsync_log_has "$LOG" "CUDA_AVAILABLE_FALSE" || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_log_has returns non-zero for a missing marker"
else
  bad "uvsync_log_has returned 0 for a missing marker"
fi

rc=0
uvsync_log_has "$TMP/no-such-file.log" "TORCH_VERSION_2.11.0+cu128" || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_log_has returns non-zero for a missing log file"
else
  bad "uvsync_log_has returned 0 for a missing log file"
fi

rc=0
uvsync_require_log_markers "$LOG" "TORCH_VERSION_2.11.0+cu128" "CUDA_AVAILABLE_TRUE" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "uvsync_require_log_markers accepts a log carrying every marker"
else
  bad "uvsync_require_log_markers rejected a complete log"
fi

rc=0
uvsync_require_log_markers "$LOG" "TORCH_VERSION_2.11.0+cu128" "CUDA_DEVICE_NVIDIA GeForce RTX 4090" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "uvsync_require_log_markers rejects a log missing one marker"
else
  bad "uvsync_require_log_markers accepted an incomplete log"
fi

# --- 5. detached worker state machine --------------------------------------
# The heavy `uv sync` runs in a detached worker so that a session that dies
# mid-download does not destroy the result. The state machine it relies on
# (ABSENT -> RUNNING -> DONE|FAILED) is tested here with fake commands: no
# network, no GPU, no uv.
STAT_DIR="$TMP/status"
mkdir -p "$STAT_DIR"

# 5a. no status file yet -> ABSENT (and a non-zero exit code)
rc=0
uvsync_status "$STAT_DIR/absent.status" >"$TMP/absent.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q '^STATE=ABSENT$' "$TMP/absent.out"; then
  ok "uvsync_status reports ABSENT when no status file exists"
else
  bad "uvsync_status did not report ABSENT (rc=$rc out=$(tr '\n' ' ' <"$TMP/absent.out"))"
fi

# 5b. a running worker -> RUNNING
STAT="$STAT_DIR/running.status"
LOG="$STAT_DIR/running.log"
uvsync_run_detached "$STAT" "$LOG" sleep 30 >"$TMP/start.out" 2>&1
rc=0
out="$(uvsync_status "$STAT")" || rc=$?
if grep -q '^STATE=RUNNING$' <<<"$out"; then
  ok "uvsync_status reports RUNNING while the detached worker lives"
else
  bad "uvsync_status did not report RUNNING (out=$(tr '\n' ' ' <<<"$out"))"
fi
# The launcher must return immediately and report where the state lives.
if grep -q '^WORKER_PID=' "$TMP/start.out" && grep -q '^STATUS_FILE=' "$TMP/start.out"; then
  ok "uvsync_run_detached returns the worker pid and the status file path"
else
  bad "uvsync_run_detached did not report WORKER_PID/STATUS_FILE (out=$(tr '\n' ' ' <"$TMP/start.out"))"
fi

# 5c. bounded wait on a still-running worker -> timeout (2)
rc=0
uvsync_wait_bounded "$STAT" 1 1 >"$TMP/wait_to.out" 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  ok "uvsync_wait_bounded returns 2 on timeout"
else
  bad "uvsync_wait_bounded must return 2 on timeout (rc=$rc)"
fi

# 5d. a worker that succeeds -> DONE, exit code 0, output in the log
STAT="$STAT_DIR/done.status"
LOG="$STAT_DIR/done.log"
uvsync_run_detached "$STAT" "$LOG" bash -c 'echo WORKER_OUTPUT_MARKER; exit 0' >/dev/null 2>&1
rc=0
uvsync_wait_bounded "$STAT" 30 1 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q '^STATE=DONE$' "$STAT" \
   && grep -q 'WORKER_OUTPUT_MARKER' "$LOG"; then
  ok "uvsync_wait_bounded returns 0 for a successful worker and the output lands in the log"
else
  bad "successful worker not reported as DONE (rc=$rc status=$(tr '\n' ' ' <"$STAT" 2>/dev/null))"
fi

# 5e. a worker that fails -> FAILED, and the exit code is propagated
STAT="$STAT_DIR/failed.status"
LOG="$STAT_DIR/failed.log"
uvsync_run_detached "$STAT" "$LOG" bash -c 'echo BOOM >&2; exit 7' >/dev/null 2>&1
rc=0
uvsync_wait_bounded "$STAT" 30 1 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q '^STATE=FAILED$' "$STAT" \
   && grep -q '^RC=7$' "$STAT" \
   && grep -q 'BOOM' "$LOG"; then
  ok "a failing worker is reported as FAILED with its exit code and its stderr"
else
  bad "failing worker not reported correctly (rc=$rc status=$(tr '\n' ' ' <"$STAT" 2>/dev/null))"
fi

# 5f. a worker that writes its OWN terminal state must not be overwritten
STAT="$STAT_DIR/self.status"
LOG="$STAT_DIR/self.log"
uvsync_run_detached "$STAT" "$LOG" bash -c \
  "printf 'STATE=DONE\nRC=0\n' > '$STAT'; echo SELF_STATE_WRITTEN" >/dev/null 2>&1
rc=0
uvsync_wait_bounded "$STAT" 30 1 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^SELF_STATE_WRITTEN$' "$LOG"; then
  ok "a worker that publishes its own terminal state keeps it"
else
  bad "the detached runner overwrote the worker's own terminal state (rc=$rc)"
fi

# 5g. a worker that dies without writing a terminal state -> FAILED, not
#     "RUNNING forever" (that is the failure mode this design removes)
STAT="$STAT_DIR/dead.status"
LOG="$STAT_DIR/dead.log"
mkdir -p "$STAT_DIR"
printf 'STATE=RUNNING\nPID=999999\n' >"$STAT"   # a pid that cannot be alive
rc=0
out="$(uvsync_status "$STAT")" || rc=$?
if grep -q '^STATE=FAILED$' <<<"$out"; then
  ok "uvsync_status reports FAILED for a worker that vanished without a terminal state"
else
  bad "uvsync_status did not detect the dead worker (out=$(tr '\n' ' ' <<<"$out"))"
fi

# 5h. uvsync_tail prints the tail of the log
if uvsync_tail "$STAT_DIR/self.log" 5 2>/dev/null | grep -q 'SELF_STATE_WRITTEN'; then
  ok "uvsync_tail prints the last lines of the log"
else
  bad "uvsync_tail did not print the expected line"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "TESTS_OK"
