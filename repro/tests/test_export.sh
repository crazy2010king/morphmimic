#!/usr/bin/env bash
# repro/tests/test_export.sh — offline fixture battery for the ONNX export
# decision base (repro/lib/export.py + repro/lib/export.sh, slice S07).
#
# No network, no container, no torch/onnx: every export directory is a
# synthetic fixture built in a temp dir.  The battery drives the real shell
# wrapper (repro/lib/export.sh) so that the wrapper is covered too.
#
#   1. happy path            -> exit 0, EXPORT_VERIFY_OK present
#   2. missing policy.onnx   -> exit != 0, no OK marker, missing-file
#   3. missing MANIFEST.txt  -> exit != 0, no OK marker, missing-file
#   4. empty artefact        -> exit != 0, no OK marker, empty-file
#   5. manifest without parity line -> exit != 0, no OK marker,
#                                      manifest-parse-failed
#   6. parity above 1e-4     -> exit != 0, no OK marker, parity-over-tol
#   7. tampered digest       -> exit != 0, no OK marker, sha-mismatch
#   8. SHA256SUMS without policy.onnx -> exit != 0, no OK marker,
#                                      sha-missing
#   9. parity exactly 1e-4   -> exit 0, OK marker present
#  10. the wrapper holds no decision logic of its own
#
# EVERY failing case additionally asserts that NO EXPORT_VERIFY_OK marker was
# printed and that the reason belongs to the fixed reason set.
#
# Run locally:   bash repro/tests/test_export.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_export.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
WRAPPER="$LIB_DIR/export.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"
FIX="$TMP/fixture"

# The fixed reason set of the decision base (kept in sync with
# repro/lib/export.py REASONS).
REASONS="missing-file empty-file manifest-parse-failed parity-over-tol sha-missing sha-mismatch robot-mismatch"

# --- fixture builders -------------------------------------------------------

# build_fixture <dir> — a healthy fake export directory.
build_fixture() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf 'fake policy graph\n' >"$dir/policy.onnx"
  printf '{"fake": "robot json"}\n' >"$dir/g1_amber.json"
  printf 'fake parity marker\n' >"$dir/MANIFEST.txt.parity"
  {
    printf 'MorphMimic export manifest\n\n'
    printf 'Parity with PyTorch (each robot'"'"'s own checkpoint, 64 random inputs):\n\n'
    printf '  g1_amber max |ONNX - PyTorch|  motion 6.2e-06  human 5.2e-06\n\n'
    printf 'Files (check with: sha256sum -c SHA256SUMS)\n\n'
    ( cd "$dir" && sha256sum policy.onnx g1_amber.json ) | sed 's/^/  /'
    printf '\nSource checkpoints\n\n'
    printf '  g1_amber logs/train/g1_amber_1h/ckpt_26413.pt\n'
  } >"$dir/MANIFEST.txt"
  rm -f "$dir/MANIFEST.txt.parity"
  ( cd "$dir" && sha256sum policy.onnx g1_amber.json >SHA256SUMS )
}

# rewrite_parity <dir> <motion value> <human value>
rewrite_parity() {
  local dir="$1" motion="$2" human="$3"
  sed -i "s/max |ONNX - PyTorch|.*/max |ONNX - PyTorch|  motion $motion  human $human/" \
    "$dir/MANIFEST.txt"
}

# --- runner -----------------------------------------------------------------

# run_verify <dir> [extra args...] -> sets $RC and $OUT
run_verify() {
  local dir="$1"; shift
  bash "$WRAPPER" verify --out-dir "$dir" --robot g1_amber "$@" \
    >"$OUT" 2>&1
  RC=$?
}

has_ok_marker() {
  grep -q 'EXPORT_VERIFY_OK' "$OUT"
}

reason_in_set() {
  local reason
  reason="$(sed -n 's/.*EXPORT_VERIFY_FAIL reason=\([a-z-]*\).*/\1/p' "$OUT" | head -1)"
  [ -n "$reason" ] || return 1
  case " $REASONS " in
    *" $reason "*) return 0 ;;
  esac
  return 1
}

assert_no_ok_marker() {
  if has_ok_marker; then
    bad "$1: EXPORT_VERIFY_OK must NOT be printed on a failure"
    sed 's/^/      | /' "$OUT"
    FAIL=$((FAIL + 1))
  else
    ok "$1: no EXPORT_VERIFY_OK marker"
    PASS=$((PASS + 1))
  fi
}

# ============================================================================
# 1. happy path
# ============================================================================
build_fixture "$FIX"
run_verify "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "healthy fixture: verify exits 0"
else
  bad "healthy fixture: verify exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if has_ok_marker; then
  ok "healthy fixture: EXPORT_VERIFY_OK printed"
else
  bad "healthy fixture: EXPORT_VERIFY_OK missing"; sed 's/^/      | /' "$OUT"
fi
if grep -q 'EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber' "$OUT"; then
  ok "healthy fixture: the OK marker carries the expected facts"
else
  bad "healthy fixture: unexpected OK marker content"; sed 's/^/      | /' "$OUT"
fi

# ============================================================================
# 2. missing policy.onnx
# ============================================================================
build_fixture "$FIX"
rm -f "$FIX/policy.onnx"
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "missing policy.onnx: verify exits non-zero" \
                || { bad "missing policy.onnx: verify exited 0"; sed 's/^/      | /' "$OUT"; }
reason_in_set && ok "missing policy.onnx: reason belongs to the fixed set" \
                || { bad "missing policy.onnx: reason outside the fixed set"; sed 's/^/      | /' "$OUT"; }
assert_no_ok_marker "missing policy.onnx"

# ============================================================================
# 3. missing MANIFEST.txt
# ============================================================================
build_fixture "$FIX"
rm -f "$FIX/MANIFEST.txt"
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "missing MANIFEST.txt: verify exits non-zero" \
                || { bad "missing MANIFEST.txt: verify exited 0"; sed 's/^/      | /' "$OUT"; }
assert_no_ok_marker "missing MANIFEST.txt"

# ============================================================================
# 4. empty artefact
# ============================================================================
build_fixture "$FIX"
: >"$FIX/g1_amber.json"
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "empty g1_amber.json: verify exits non-zero" \
                || { bad "empty g1_amber.json: verify exited 0"; sed 's/^/      | /' "$OUT"; }
assert_no_ok_marker "empty g1_amber.json"

# ============================================================================
# 5. manifest without a parity line
# ============================================================================
build_fixture "$FIX"
grep -v 'max |ONNX - PyTorch|' "$FIX/MANIFEST.txt" >"$FIX/MANIFEST.tmp" \
  && mv "$FIX/MANIFEST.tmp" "$FIX/MANIFEST.txt"
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "manifest without parity line: verify exits non-zero" \
                || { bad "manifest without parity line: verify exited 0"; sed 's/^/      | /' "$OUT"; }
if grep -q 'reason=manifest-parse-failed' "$OUT"; then
  ok "manifest without parity line: reason=manifest-parse-failed"
else
  bad "manifest without parity line: unexpected reason"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "manifest without parity line"

# ============================================================================
# 6. parity above the 1e-4 tolerance
# ============================================================================
build_fixture "$FIX"
rewrite_parity "$FIX" 6.2e-06 2.0e-04
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "parity 2.0e-04: verify exits non-zero" \
                || { bad "parity 2.0e-04: verify exited 0"; sed 's/^/      | /' "$OUT"; }
if grep -q 'reason=parity-over-tol' "$OUT"; then
  ok "parity 2.0e-04: reason=parity-over-tol"
else
  bad "parity 2.0e-04: unexpected reason"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "parity above tolerance"

# ============================================================================
# 7. tampered sha256 digest
# ============================================================================
build_fixture "$FIX"
sed -i '0,/^[0-9a-f]\{64\}/s//0000000000000000000000000000000000000000000000000000000000000000/' \
  "$FIX/SHA256SUMS"
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "tampered digest: verify exits non-zero" \
                || { bad "tampered digest: verify exited 0"; sed 's/^/      | /' "$OUT"; }
if grep -q 'reason=sha-mismatch' "$OUT"; then
  ok "tampered digest: reason=sha-mismatch"
else
  bad "tampered digest: unexpected reason"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "tampered digest"

# ============================================================================
# 8. SHA256SUMS without the policy.onnx entry
# ============================================================================
build_fixture "$FIX"
grep -v 'policy.onnx' "$FIX/SHA256SUMS" >"$FIX/SHA256SUMS.tmp" \
  && mv "$FIX/SHA256SUMS.tmp" "$FIX/SHA256SUMS"
run_verify "$FIX"
[ "$RC" -ne 0 ] && ok "SHA256SUMS without policy.onnx: verify exits non-zero" \
                || { bad "SHA256SUMS without policy.onnx: verify exited 0"; sed 's/^/      | /' "$OUT"; }
if grep -q 'reason=sha-missing' "$OUT"; then
  ok "SHA256SUMS without policy.onnx: reason=sha-missing"
else
  bad "SHA256SUMS without policy.onnx: unexpected reason"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "SHA256SUMS without policy.onnx"

# ============================================================================
# 9. parity exactly at the tolerance is accepted
# ============================================================================
build_fixture "$FIX"
rewrite_parity "$FIX" 1.0e-04 1.0e-04
run_verify "$FIX"
[ "$RC" -eq 0 ] && ok "parity exactly 1e-4: verify exits 0" \
                || { bad "parity exactly 1e-4: verify exited $RC"; sed 's/^/      | /' "$OUT"; }
if has_ok_marker; then
  ok "parity exactly 1e-4: EXPORT_VERIFY_OK printed"
else
  bad "parity exactly 1e-4: EXPORT_VERIFY_OK missing"; sed 's/^/      | /' "$OUT"
fi

# ============================================================================
# 10. the wrapper holds no decision logic
# ============================================================================
if grep -Eq 'sha256sum|python3? -c|awk ' "$WRAPPER"; then
  bad "the wrapper must not implement any decision itself"
  grep -nE 'sha256sum|python3? -c|awk ' "$WRAPPER" | sed 's/^/      | /'
else
  ok "the wrapper contains no decision logic (no sha256sum / awk / inline python)"
fi
if grep -q 'EXPORT_VERIFY_OK' "$WRAPPER"; then
  bad "the wrapper must not print OK markers itself"
else
  ok "the wrapper prints no OK marker itself (the module owns the format)"
fi

# ============================================================================
# 11. the decision base is stdlib-only (no numpy / torch / onnx)
# ============================================================================
if grep -nE '^[[:space:]]*(import|from)[[:space:]]+(numpy|torch|onnx|onnxruntime|onnxscript)\b' \
    "$LIB_DIR/export.py"; then
  bad "export.py must not import numpy/torch/onnx (stdlib only)"
else
  ok "export.py imports no numpy/torch/onnx (stdlib only, container python3 works)"
fi

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
