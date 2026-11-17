#!/usr/bin/env bash
# repro/lib/seed_human.sh — THIN shell wrapper around repro/lib/seed_human.py
# (slice S05: the human50 sidecar decision base).
#
# It does NOT implement any decision: every check (sidecar set comparison,
# frame-count comparison, subset parsing) lives in the stdlib-only python
# module repro/lib/seed_human.py, which can run with the container's system
# python3 (no numpy).  This file only
#
#   1. picks the interpreter (SEED_HUMAN_PY, default `python3`),
#   2. locates seed_human.py next to itself,
#   3. forwards the arguments.
#
# Source it or run it:
#   source repro/lib/seed_human.sh
#   seed_human_run subset data/seed_g1_npz50/subsets/1h.yaml
#   bash repro/lib/seed_human.sh diff --root R --yaml Y
#
# Environment overrides:
#   SEED_HUMAN_PY      interpreter used to run seed_human.py (default python3)
#   SEED_HUMAN_PYTHON  alias of SEED_HUMAN_PY

SEED_HUMAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_HUMAN_PY_FILE="$SEED_HUMAN_LIB_DIR/seed_human.py"

# seed_human_python
# Prints the interpreter that runs repro/lib/seed_human.py.
seed_human_python() {
  printf '%s' "${SEED_HUMAN_PY:-${SEED_HUMAN_PYTHON:-python3}}"
}

# seed_human_run <args...>
# Runs repro/lib/seed_human.py with the given arguments and returns its exit
# code.  Fails closed: a missing interpreter or a missing module is a
# non-zero exit, never a silent success.
seed_human_run() {
  local python_bin
  python_bin="$(seed_human_python)"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf 'seed_human: 找不到解释器 %s\n' "$python_bin" >&2
    return 1
  fi
  if [ ! -f "$SEED_HUMAN_PY_FILE" ]; then
    printf 'seed_human: 找不到 %s\n' "$SEED_HUMAN_PY_FILE" >&2
    return 1
  fi
  "$python_bin" "$SEED_HUMAN_PY_FILE" "$@"
}

# When executed directly, forward the arguments to the python module.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    printf 'usage: bash %s <command> [args...]\n' "$0" >&2
    exit 2
  fi
  seed_human_run "$@"
  exit $?
fi
