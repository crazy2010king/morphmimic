#!/usr/bin/env bash
# repro/lib/export.sh — THIN shell wrapper around repro/lib/export.py
# (slice S07: the ONNX export / parity decision base).
#
# It does NOT implement any decision: every check (manifest parity parsing,
# sha256 recomputation, the four-artefact contract, the EXPORT_VERIFY_* /
# EXPORT_REPORT_* output format) lives in the stdlib-only python module
# repro/lib/export.py, which can run with the container's system python3
# (no numpy).  This file only
#
#   1. picks the interpreter (EXPORT_PY, default `python3`),
#   2. locates export.py next to itself,
#   3. forwards the arguments.
#
# Source it or run it:
#   source repro/lib/export.sh
#   export_run verify --out-dir out/g1_amber --robot g1_amber
#   bash repro/lib/export.sh report --out-dir out/g1_amber --robot g1_amber
#
# Environment overrides:
#   EXPORT_PY      interpreter used to run export.py (default python3)
#   EXPORT_PYTHON  alias of EXPORT_PY

set -uo pipefail

EXPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_PY_FILE="$EXPORT_LIB_DIR/export.py"

# export_python
# Prints the interpreter that runs repro/lib/export.py.
export_python() {
  printf '%s' "${EXPORT_PY:-${EXPORT_PYTHON:-python3}}"
}

# export_run <args...>
# Runs repro/lib/export.py with the given arguments and returns its exit
# code.  Fails closed: a missing interpreter or a missing module is a
# non-zero exit, never a silent success.
export_run() {
  local python_bin
  python_bin="$(export_python)"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf 'export: 找不到解释器 %s\n' "$python_bin" >&2
    return 1
  fi
  if [ ! -f "$EXPORT_PY_FILE" ]; then
    printf 'export: 找不到 %s\n' "$EXPORT_PY_FILE" >&2
    return 1
  fi
  "$python_bin" "$EXPORT_PY_FILE" "$@"
}

# When executed directly, forward the arguments to the python module.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    printf 'usage: bash %s <command> [args...]\n' "$0" >&2
    exit 2
  fi
  export_run "$@"
  exit $?
fi
