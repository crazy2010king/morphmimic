#!/usr/bin/env bash
# repro/lib/doc.sh — THIN shell wrapper around repro/lib/doc.py
# (slice S09, task T2: the reproduction record decision base).
#
# It does NOT implement any decision: every check (the nine-chapter
# contract, the evidence index table, the SHA-256 recomputation, the eval
# row count / completion, the comparison table, the training curve
# coverage, the plaintext-token scan and the DOC_VERIFY_OK / DOC_VERIFY_FAIL
# output format) lives in the stdlib-only python module repro/lib/doc.py,
# which runs with the container's system python3 (no numpy) and with the
# host python3.  This file only
#
#   1. picks the interpreter (DOC_PY, default `python3`),
#   2. locates doc.py next to itself,
#   3. forwards the arguments.
#
# Source it or run it:
#   source repro/lib/doc.sh
#   doc_run verify --doc docs/code_read/MorphMimic完整复现记录.md
#   bash repro/lib/doc.sh mirror --doc A --mirror B
#
# Environment overrides:
#   DOC_PY      interpreter used to run doc.py (default python3)
#   DOC_PYTHON  alias of DOC_PY

set -uo pipefail

DOC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_PY_FILE="$DOC_LIB_DIR/doc.py"

# doc_python
# Prints the interpreter that runs repro/lib/doc.py.
doc_python() {
  printf '%s' "${DOC_PY:-${DOC_PYTHON:-python3}}"
}

# doc_run <args...>
# Runs repro/lib/doc.py with the given arguments and returns its exit
# code.  Fails closed: a missing interpreter or a missing module is a
# non-zero exit, never a silent success.
doc_run() {
  local python_bin
  python_bin="$(doc_python)"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf 'doc: 找不到解释器 %s\n' "$python_bin" >&2
    return 1
  fi
  if [ ! -f "$DOC_PY_FILE" ]; then
    printf 'doc: 找不到 %s\n' "$DOC_PY_FILE" >&2
    return 1
  fi
  "$python_bin" "$DOC_PY_FILE" "$@"
}

# When executed directly, forward the arguments to the python module.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    printf 'usage: bash %s <command> [args...]\n' "$0" >&2
    exit 2
  fi
  doc_run "$@"
  exit $?
fi
