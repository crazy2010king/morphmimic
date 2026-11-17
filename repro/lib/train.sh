#!/usr/bin/env bash
# repro/lib/train.sh — THIN shell wrapper around repro/lib/train.py
# (slice S06: the g1_amber training decision base).
#
# It does NOT implement any decision: every check (log parsing, iteration
# plan, resource budget, tensorboard NaN audit, status file) lives in the
# stdlib-only python module repro/lib/train.py, which can run with the
# container's system python3 (no numpy).  This file only
#
#   1. picks the interpreter (TRAIN_PY, default `python3`),
#   2. locates train.py next to itself,
#   3. forwards the arguments.
#
# Source it or run it:
#   source repro/lib/train.sh
#   train_run plan --budget-seconds 28800 --it-per-s 1.09
#   bash repro/lib/train.sh log-summary logs/train/g1_amber_1h/train.log
#   bash repro/lib/train.sh budget --gpu-peak-mb 18000 --host-peak-gb 12 \
#       --wall-s 28000 --wall-max-s 28800
#
# Environment overrides:
#   TRAIN_PY      interpreter used to run train.py (default python3)
#   TRAIN_PYTHON  alias of TRAIN_PY

set -uo pipefail

TRAIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAIN_PY_FILE="$TRAIN_LIB_DIR/train.py"

# train_python
# Prints the interpreter that runs repro/lib/train.py.
train_python() {
  printf '%s' "${TRAIN_PY:-${TRAIN_PYTHON:-python3}}"
}

# train_run <args...>
# Runs repro/lib/train.py with the given arguments and returns its exit
# code.  Fails closed: a missing interpreter or a missing module is a
# non-zero exit, never a silent success.
train_run() {
  local python_bin
  python_bin="$(train_python)"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf 'train: 找不到解释器 %s\n' "$python_bin" >&2
    return 1
  fi
  if [ ! -f "$TRAIN_PY_FILE" ]; then
    printf 'train: 找不到 %s\n' "$TRAIN_PY_FILE" >&2
    return 1
  fi
  "$python_bin" "$TRAIN_PY_FILE" "$@"
}

# When executed directly, forward the arguments to the python module.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    printf 'usage: bash %s <command> [args...]\n' "$0" >&2
    exit 2
  fi
  train_run "$@"
  exit $?
fi
