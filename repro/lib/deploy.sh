#!/usr/bin/env bash
# repro/lib/deploy.sh — THIN shell wrapper around repro/lib/deploy.py
# (slice S08: the deployment verification decision base).
#
# It does NOT implement any decision: every check (the sim2sim summary
# contract, the eval CSV contract, the assets / official / session / compare
# contracts and the DEPLOY_*_OK / DEPLOY_*_FAIL output format) lives in the
# stdlib-only python module repro/lib/deploy.py, which runs with the
# container's system python3 (no numpy).  This file only
#
#   1. picks the interpreter (DEPLOY_PY, default `python3`),
#   2. locates deploy.py next to itself,
#   3. forwards the arguments.
#
# Source it or run it:
#   source repro/lib/deploy.sh
#   deploy_run sim --dir out/summaries --expect-count 490
#   bash repro/lib/deploy.sh eval --path out/eval_motion.csv --expect-rows 490
#
# Environment overrides:
#   DEPLOY_PY      interpreter used to run deploy.py (default python3)
#   DEPLOY_PYTHON  alias of DEPLOY_PY

set -uo pipefail

DEPLOY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_PY_FILE="$DEPLOY_LIB_DIR/deploy.py"

# deploy_python
# Prints the interpreter that runs repro/lib/deploy.py.
deploy_python() {
  printf '%s' "${DEPLOY_PY:-${DEPLOY_PYTHON:-python3}}"
}

# deploy_run <args...>
# Runs repro/lib/deploy.py with the given arguments and returns its exit
# code.  Fails closed: a missing interpreter or a missing module is a
# non-zero exit, never a silent success.
deploy_run() {
  local python_bin
  python_bin="$(deploy_python)"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf 'deploy: 找不到解释器 %s\n' "$python_bin" >&2
    return 1
  fi
  if [ ! -f "$DEPLOY_PY_FILE" ]; then
    printf 'deploy: 找不到 %s\n' "$DEPLOY_PY_FILE" >&2
    return 1
  fi
  "$python_bin" "$DEPLOY_PY_FILE" "$@"
}

# When executed directly, forward the arguments to the python module.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    printf 'usage: bash %s <command> [args...]\n' "$0" >&2
    exit 2
  fi
  deploy_run "$@"
  exit $?
fi
