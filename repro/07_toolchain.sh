#!/usr/bin/env bash
# repro/07_toolchain.sh — availability probes for the four external tool
# chains (GMR / soma-retargeter / XRoboToolkit / Unitree SDK).
#
# R002 asks for "the tool chains around tools/soma_retargeter/ can be
# installed and used": each tool must end with a verdict that says either
# VERIFIED (it really was exercised) or SKIPPED (with the concrete reason).
# "Neither verified nor explained" is not an accepted state.
#
#   usage: bash repro/07_toolchain.sh [probe|verify]
#
#   probe   (default) runs the four probes inside the container and writes
#           stdout/stderr to logs/env/07_toolchain.txt.  When the four verdict
#           groups are complete the script prints TOOLCHAIN_OK and exits 0.
#           The probe is idempotent: an already cloned/built tool chain is
#           reused, so a second run is cheap.
#
#   verify  touches NO network and runs NO build.  It only asserts:
#             * the four verdict groups are complete, the verdicts are legal
#               and every reason / evidence is non-empty;
#             * logs/env/07_toolchain.txt and docs/code_read/TOOLCHAIN.md
#               carry the SAME verdict, reason and evidence per tool.
#           Prints TOOLCHAIN_OK / TOOLCHAIN_DOC_OK and exits 0.
#
# WHY THIS SCRIPT IS NOT PART OF repro/00_env.sh
#
#   The probes clone third party repositories, pull a cmake wheel from PyPI
#   and compile a pybind11 binding: ten minutes or more, and hard dependent
#   on the network.  Putting that into the one-shot orchestration would make
#   "one command, all green" fragile.  07 runs standalone; its conclusion
#   lives in docs/code_read/TOOLCHAIN.md and is checked by `verify`.
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); no
# system configuration is ever written.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/toolchain.sh
source "$_SCRIPT_DIR/lib/toolchain.sh"

cd "$REPO_ROOT"

MAIN_LOG="${TOOLCHAIN_LOG:-${SEED_STORE_ROOT:-$REPO_ROOT}/logs/env/07_toolchain.txt}"
CONCLUSION="${TOOLCHAIN_CONCLUSION:-$REPO_ROOT/docs/code_read/TOOLCHAIN.md}"
CMD="${1:-probe}"

usage() {
  echo "usage: bash repro/07_toolchain.sh [probe|verify]" >&2
  exit 2
}

case "$CMD" in
  probe|verify) ;;
  *) usage ;;
esac

# --- probe -----------------------------------------------------------------
run_probe() {
  # The probe writes hundreds of megabytes (three clones, two isolated venvs,
  # a pybind11 build tree).  They MUST land in the persistent store: a
  # worktree that is not store-backed is deleted by the next GSD reconcile
  # and takes them with it (observed 2026-11-11).
  if ! store_guard logs; then
    echo "TOOLCHAIN_FAIL reason=store-not-linked" >&2
    exit 1
  fi
  mkdir -p "$TC_SRC_DIR" "$TC_BUILD_DIR" "$TC_VENV_DIR" "$TC_DIAG_DIR" 2>/dev/null || true

  # a fresh log per run: the artefact must show ONE verdict, not the history
  # of earlier attempts.
  : >"$MAIN_LOG"

  {
    echo "=== 07_toolchain.sh probe $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "REPO_ROOT=$REPO_ROOT"
    echo "CONCLUSION=$CONCLUSION"
    echo "TC_ROOT=$TC_ROOT"
    echo "TC_SRC_DIR=$TC_SRC_DIR"
    echo "TC_VENV_DIR=$TC_VENV_DIR"
    echo "TC_BUILD_DIR=$TC_BUILD_DIR"
  } | tee -a "$MAIN_LOG"

  # the probes print their diagnostics AND their verdict lines; both belong
  # into the log.
  tc_probe_all 2>&1 | tee -a "$MAIN_LOG"

  echo "--- verdict check ---" | tee -a "$MAIN_LOG"
  if tc_check_verdicts "$MAIN_LOG" | tee -a "$MAIN_LOG"; then
    exit 0
  fi
  echo "ERROR: the tool chain verdicts are incomplete (see $MAIN_LOG)" >&2
  exit 1
}

# --- verify ----------------------------------------------------------------
run_verify() {
  local rc=0
  echo "=== 07_toolchain.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "LOG=$MAIN_LOG"
  echo "CONCLUSION=$CONCLUSION"

  if [ ! -f "$MAIN_LOG" ]; then
    echo "TOOLCHAIN_VERIFY_FAIL reason=probe-log-missing" >&2
    echo "ERROR: no probe log: $MAIN_LOG" >&2
    echo "       the log lives in the persistent store; re-create it with:" >&2
    echo "         bash repro/lib/remote.sh 07_toolchain.sh probe" >&2
    exit 1
  fi

  echo "--- log completeness ---"
  if tc_check_verdicts "$MAIN_LOG"; then
    :
  else
    rc=1
  fi

  echo "--- log vs conclusion ---"
  if tc_compare_verdicts "$MAIN_LOG" "$CONCLUSION"; then
    :
  else
    rc=1
  fi

  if [ "$rc" -ne 0 ]; then
    echo "TOOLCHAIN_VERIFY_FAIL"
    exit 1
  fi
  echo "TOOLCHAIN_VERIFY_OK"
  exit 0
}

case "$CMD" in
  probe) run_probe ;;
  verify) run_verify ;;
esac
