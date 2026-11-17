#!/usr/bin/env bash
# repro/03_uv_sync.sh — install the project virtualenv and self-check it.
#
# Goal (R001 primary evidence): a .venv at the worktree root that can
# `import torch, mjlab, warp, morphmimic` and sees the GPU.
#
# Measured constraints this script encodes:
#   * pyproject.toml pins requires-python = "==3.11.*"; the container's system
#     python is 3.10/3.12, but uv already manages cpython-3.11.16 -> we probe
#     first and only download when it is really missing.
#   * torch comes from the explicit pytorch-cu128 index
#     (download.pytorch.org/whl/cu128); mjlab 1.6.0 is an sdist that has to be
#     built from source; general-motion-retargeting is the editable workspace
#     member third_party/GMR -> all three need the proxy (inlined per process
#     by repro/lib/common.sh, never written to any system config).
#   * the venv must be <repo>/.venv: deploy/install_pico.sh calls
#     `.venv/bin/python` by that exact relative path.
#   * `--frozen` (not `--locked`): --locked demands the lockfile match every
#     workspace member exactly, which is a much larger failure surface.
#
# ---------------------------------------------------------------------------
# SUBCOMMAND INTERFACE (why)
#
# `uv sync --frozen` downloads GBs of wheels (torch 2.11.0+cu128 + the whole
# nvidia-* stack) through the proxy. Running it in the FOREGROUND of a single
# ssh call is what killed the previous attempt: the log stopped at
# "### RUN ...: uv sync --frozen" with no EXIT line and no result, because the
# session budget ran out while the download was still going.
#
# So the heavy work runs in a DETACHED worker (repro/03_uv_sync_worker.sh,
# started with setsid/nohup) that survives the ssh session that launched it,
# and this script only ever runs short, cheap commands:
#
#   start   launch the worker (or report the running one) and return at once
#   status  print STATE=, the finished "### STEP" lines and the log tail
#   wait    bounded wait for the worker (0=DONE, 1=FAILED, 2=timeout)
#   verify  marker assertions only — never triggers a sync
#   (no argument) == run == start + bounded wait; exits 75 (EX_TEMPFAIL) on
#            timeout and prints the command to continue with
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh).

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
require_container
# shellcheck source=lib/uvsync.sh
source "$_SCRIPT_DIR/lib/uvsync.sh"

cd "$REPO_ROOT"

MAIN_LOG="$LOG_DIR/03_uv_sync.txt"
STATUS_FILE="$LOG_DIR/03_uv_sync.status"
WORKER="$REPO_ROOT/repro/03_uv_sync_worker.sh"

usage() {
  cat <<EOF
usage: bash repro/03_uv_sync.sh [start|status|wait [seconds]|verify|run]

  start          launch the detached uv-sync worker; returns immediately
  status         print the worker state + the log tail (always exit 0)
  wait [sec]     bounded wait (default ${DEFAULT_WAIT}s); 0=DONE 1=FAILED 2=timeout
  verify         assert the markers in $MAIN_LOG (no sync is triggered)
  run            start + bounded wait (default), the historical behaviour
EOF
}

DEFAULT_WAIT=600

# --- start ----------------------------------------------------------------
cmd_start() {
  if [ -f "$STATUS_FILE" ]; then
    state="$(uvsync_status "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)"
    if [ "$state" = "RUNNING" ]; then
      echo "worker already RUNNING:"
      uvsync_status "$STATUS_FILE"
      return 0
    fi
  fi
  echo "starting detached uv-sync worker ..."
  uvsync_run_detached "$STATUS_FILE" "$MAIN_LOG" bash "$WORKER"
  echo "poll with: bash repro/lib/remote.sh 03_uv_sync.sh status"
}

# --- status ---------------------------------------------------------------
cmd_status() {
  echo "=== 03_uv_sync.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  uvsync_status "$STATUS_FILE" || true
  echo "--- finished steps ---"
  if [ -f "$MAIN_LOG" ]; then
    grep -a '^### STEP .* DONE$' "$MAIN_LOG" || echo "(none yet)"
  else
    echo "(no log yet: $MAIN_LOG)"
  fi
  echo "--- log tail ---"
  uvsync_tail "$MAIN_LOG" 30 || true
  return 0
}

# --- wait -----------------------------------------------------------------
cmd_wait() {
  local timeout_s="${1:-$DEFAULT_WAIT}"
  uvsync_wait_bounded "$STATUS_FILE" "$timeout_s" 5
  local rc=$?
  case "$rc" in
    0) echo "worker finished: DONE" ;;
    1) echo "worker finished: FAILED" ;;
    2) echo "worker still running after ${timeout_s}s — keep polling:"
       echo "  bash repro/lib/remote.sh 03_uv_sync.sh status" ;;
  esac
  return $rc
}

# --- verify ---------------------------------------------------------------
cmd_verify() {
  echo "=== 03_uv_sync.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  local missing=0

  state="$(uvsync_status "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)"
  if [ "$state" != "DONE" ]; then
    echo "ERROR: worker state is ${state:-ABSENT}, expected DONE" >&2
    missing=1
  fi

  if ! uvsync_require_log_markers "$MAIN_LOG" \
        "TORCH_VERSION_2.11.0+cu128" \
        "CUDA_AVAILABLE_TRUE" \
        "CUDA_DEVICE_NVIDIA GeForce RTX 4090" \
        "UV_SYNC_OK"; then
    missing=1
  fi

  if ! grep -aq '^### STEP .* DONE$' "$MAIN_LOG" 2>/dev/null; then
    echo "ERROR: no '### STEP ... DONE' lines in $MAIN_LOG" >&2
    missing=1
  fi

  if ! uvsync_check_venv "$REPO_ROOT"; then
    missing=1
  fi

  [ "$missing" -eq 0 ] || { echo "ERROR: verification failed" >&2; exit 1; }
  echo "UV_SYNC_OK"
}

# --- run (default) --------------------------------------------------------
cmd_run() {
  cmd_start
  set +e
  cmd_wait "$DEFAULT_WAIT"
  local rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    echo "TIMEOUT: the worker keeps running detached; continue with:" >&2
    echo "  bash repro/lib/remote.sh 03_uv_sync.sh status" >&2
    echo "  bash repro/lib/remote.sh 03_uv_sync.sh wait 600" >&2
    exit 75
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  cmd_verify
}

case "${1:-run}" in
  start)  cmd_start ;;
  status) cmd_status ;;
  wait)   shift; cmd_wait "${1:-$DEFAULT_WAIT}" ;;
  verify) cmd_verify ;;
  run)    cmd_run ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
