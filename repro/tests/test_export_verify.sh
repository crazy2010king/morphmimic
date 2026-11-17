#!/usr/bin/env bash
# repro/tests/test_export_verify.sh — offline NEGATIVE fixture battery for the
# read-only independent reviewer repro/20_export_verify.sh (slice S07, T2).
#
# The reviewer is the acceptance gate of the ONNX export: if it always said
# OK, the export would be accepted without a proof.  This battery therefore
# proves the opposite: every broken artefact must produce a NON-ZERO exit, an
# EXPORT_VERIFY_FAIL line whose reason belongs to the fixed set, and ZERO
# EXPORT_VERIFY_OK markers.
#
# No network, no container, no torch/onnx, no GPU: every export directory is a
# synthetic fixture built in a temp dir.  The reviewer itself is the real
# script (repro/20_export_verify.sh), driven with EXPORT_ALLOW_LOCAL=1,
# EXPORT_OUT_DIR=<fixture> and EXPORT_LOG_DIR=<temp log dir>.
#
#   1. happy path                -> exit 0, one EXPORT_VERIFY_OK line
#   2. report mode               -> EXPORT_REPORT_* lines, no gate marker
#   3. missing policy.onnx       -> missing-file
#   4. missing MANIFEST.txt      -> missing-file
#   5. missing <robot>.json      -> missing-file
#   6. empty artefact            -> empty-file
#   7. MANIFEST without parity   -> manifest-parse-failed
#   8. parity above 1e-4         -> parity-over-tol
#   9. tampered SHA256SUMS       -> sha-mismatch
#  10. SHA256SUMS w/o policy.onnx-> sha-missing
#  11. parity of another robot   -> robot-mismatch
#  12. parity exactly 1e-4       -> accepted (boundary)
#  13. missing interpreter       -> fail closed, no OK marker
#  14. READ-ONLY contract        -> the export directory is byte-identical
#                                   before and after the reviewer ran
#  15. the reviewer holds no decision logic of its own
#  16. the reviewer writes its own log (logs/env/20_export_verify.txt)
#
# Run locally:   bash repro/tests/test_export_verify.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_export_verify.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
REVIEWER="$REPO_ROOT/repro/20_export_verify.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"
FIX="$TMP/fixture"
LOGD="$TMP/logs"

# The fixed reason set of the decision base (kept in sync with
# repro/lib/export.py REASONS).
REASONS="missing-file empty-file manifest-parse-failed parity-over-tol sha-missing sha-mismatch robot-mismatch"

# --- fixture builders -------------------------------------------------------

# build_fixture <dir> — a healthy fake export directory (the upstream shape:
# MANIFEST.txt with a parity line, a file-digest block and the source
# checkpoints; SHA256SUMS over policy.onnx and <robot>.json).
build_fixture() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf 'fake policy graph\n' >"$dir/policy.onnx"
  printf '{"fake": "robot json"}\n' >"$dir/g1_amber.json"
  {
    printf 'MorphMimic export manifest\n\n'
    printf 'Parity with PyTorch (each robot'"'"'s own checkpoint, 64 random inputs):\n\n'
    printf '  g1_amber max |ONNX - PyTorch|  motion 6.2e-06  human 5.2e-06\n\n'
    printf 'Files (check with: sha256sum -c SHA256SUMS)\n\n'
    ( cd "$dir" && sha256sum policy.onnx g1_amber.json ) | sed 's/^/  /'
    printf '\nSource checkpoints\n\n'
    printf '  g1_amber logs/train/g1_amber_1h/ckpt_26413.pt\n'
  } >"$dir/MANIFEST.txt"
  ( cd "$dir" && sha256sum policy.onnx g1_amber.json >SHA256SUMS )
}

# rewrite_parity <dir> <motion> <human>
rewrite_parity() {
  local dir="$1" motion="$2" human="$3"
  sed -i "s/max |ONNX - PyTorch|.*/max |ONNX - PyTorch|  motion $motion  human $human/" \
    "$dir/MANIFEST.txt"
}

# snapshot <dir> — a content fingerprint of a directory (file names + digests).
snapshot() {
  local dir="$1"
  ( cd "$dir" && find . -type f | LC_ALL=C sort | xargs -r sha256sum )
}

# --- runner -----------------------------------------------------------------

# run_reviewer <cmd> [extra env assignments...] — sets $RC and $OUT.
run_reviewer() {
  local cmd="$1"; shift
  env EXPORT_ALLOW_LOCAL=1 \
      EXPORT_OUT_DIR="$FIX" \
      EXPORT_LOG_DIR="$LOGD" \
      "$@" \
      bash "$REVIEWER" "$cmd" >"$OUT" 2>&1
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

# assert_failure <label> <expected reason>
assert_failure() {
  local label="$1" expected="$2"
  if [ "$RC" -eq 0 ]; then
    bad "$label: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
  else
    ok "$label: verify exits non-zero ($RC)"
  fi
  if has_ok_marker; then
    bad "$label: EXPORT_VERIFY_OK must NOT be printed on a failure"
    sed 's/^/      | /' "$OUT"
    FAIL=$((FAIL + 1))
  else
    ok "$label: no EXPORT_VERIFY_OK marker"
    PASS=$((PASS + 1))
  fi
  if reason_in_set; then
    ok "$label: reason belongs to the fixed set"
  else
    bad "$label: reason outside the fixed set"; sed 's/^/      | /' "$OUT"
  fi
  if grep -q "reason=$expected" "$OUT"; then
    ok "$label: reason=$expected"
  else
    bad "$label: expected reason=$expected"; sed 's/^/      | /' "$OUT"
  fi
}

# ============================================================================
# 1. happy path
# ============================================================================
build_fixture "$FIX"
run_reviewer verify
if [ "$RC" -eq 0 ]; then
  ok "healthy fixture: verify exits 0"
else
  bad "healthy fixture: verify exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if grep -q 'EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber' "$OUT"; then
  ok "healthy fixture: the OK marker carries the expected facts"
else
  bad "healthy fixture: unexpected OK marker content"; sed 's/^/      | /' "$OUT"
fi
if [ "$(grep -c 'EXPORT_VERIFY_OK' "$OUT")" -eq 1 ]; then
  ok "healthy fixture: exactly ONE OK marker line"
else
  bad "healthy fixture: more than one OK marker line"; sed 's/^/      | /' "$OUT"
fi

# ============================================================================
# 2. report mode
# ============================================================================
run_reviewer report
if [ "$RC" -eq 0 ]; then
  ok "report: exits 0 on a healthy fixture"
else
  bad "report: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
for needle in "EXPORT_REPORT_PARITY robot=g1_amber interface=motion" \
              "EXPORT_REPORT_PARITY robot=g1_amber interface=human" \
              "EXPORT_REPORT_SIZE file=policy.onnx bytes=" \
              "EXPORT_REPORT_SIZE file=g1_amber.json bytes=" \
              "EXPORT_REPORT_SHA file=policy.onnx sha256=" \
              "EXPORT_REPORT_SHA file=g1_amber.json sha256=" \
              "EXPORT_REPORT_SOURCE_CKPT path=logs/train/g1_amber_1h/ckpt_26413.pt"; do
  if grep -qF "$needle" "$OUT"; then
    ok "report: prints '$needle'"
  else
    bad "report: missing '$needle'"; sed 's/^/      | /' "$OUT"
  fi
done
if grep -qE 'EXPORT_REPORT_SHA .*sha256_12=[0-9a-f]{12}( |$)' "$OUT"; then
  ok "report: prints the 12-digit digest prefix"
else
  bad "report: no 12-digit digest prefix"; sed 's/^/      | /' "$OUT"
fi
if has_ok_marker; then
  bad "report: the report must not print the gate marker EXPORT_VERIFY_OK"
  sed 's/^/      | /' "$OUT"
else
  ok "report: no gate marker (EXPORT_VERIFY_OK belongs to verify)"
fi

# ============================================================================
# 3. missing policy.onnx
# ============================================================================
build_fixture "$FIX"
rm -f "$FIX/policy.onnx"
run_reviewer verify
assert_failure "missing policy.onnx" "missing-file"

# ============================================================================
# 4. missing MANIFEST.txt
# ============================================================================
build_fixture "$FIX"
rm -f "$FIX/MANIFEST.txt"
run_reviewer verify
assert_failure "missing MANIFEST.txt" "missing-file"

# ============================================================================
# 5. missing <robot>.json
# ============================================================================
build_fixture "$FIX"
rm -f "$FIX/g1_amber.json"
run_reviewer verify
assert_failure "missing g1_amber.json" "missing-file"

# ============================================================================
# 6. empty artefact
# ============================================================================
build_fixture "$FIX"
: >"$FIX/policy.onnx"
run_reviewer verify
assert_failure "empty policy.onnx" "empty-file"

# ============================================================================
# 7. MANIFEST without a parity line
# ============================================================================
build_fixture "$FIX"
grep -v 'max |ONNX - PyTorch|' "$FIX/MANIFEST.txt" >"$FIX/MANIFEST.tmp" \
  && mv "$FIX/MANIFEST.tmp" "$FIX/MANIFEST.txt"
run_reviewer verify
assert_failure "manifest without parity line" "manifest-parse-failed"

# ============================================================================
# 8. parity above the 1e-4 tolerance
# ============================================================================
build_fixture "$FIX"
rewrite_parity "$FIX" 6.2e-06 2.0e-04
run_reviewer verify
assert_failure "parity 2.0e-04" "parity-over-tol"

# ============================================================================
# 9. tampered SHA256SUMS digest
# ============================================================================
build_fixture "$FIX"
sed -i '0,/^[0-9a-f]\{64\}/s//0000000000000000000000000000000000000000000000000000000000000000/' \
  "$FIX/SHA256SUMS"
run_reviewer verify
assert_failure "tampered digest" "sha-mismatch"

# ============================================================================
# 10. SHA256SUMS without the policy.onnx entry
# ============================================================================
build_fixture "$FIX"
grep -v 'policy.onnx' "$FIX/SHA256SUMS" >"$FIX/SHA256SUMS.tmp" \
  && mv "$FIX/SHA256SUMS.tmp" "$FIX/SHA256SUMS"
run_reviewer verify
assert_failure "SHA256SUMS without policy.onnx" "sha-missing"

# ============================================================================
# 11. the parity block belongs to another robot
# ============================================================================
build_fixture "$FIX"
sed -i 's/^  g1_amber max |ONNX - PyTorch|/  g2_amber max |ONNX - PyTorch|/' \
  "$FIX/MANIFEST.txt"
run_reviewer verify
assert_failure "parity of another robot" "robot-mismatch"

# ============================================================================
# 12. parity exactly at the tolerance is accepted
# ============================================================================
build_fixture "$FIX"
rewrite_parity "$FIX" 1.0e-04 1.0e-04
run_reviewer verify
if [ "$RC" -eq 0 ] && has_ok_marker; then
  ok "parity exactly 1e-4: accepted (exit 0 + OK marker)"
else
  bad "parity exactly 1e-4: rejected"; sed 's/^/      | /' "$OUT"
fi

# ============================================================================
# 13. the decision base cannot run (missing interpreter) -> fail closed
# ============================================================================
build_fixture "$FIX"
run_reviewer verify EXPORT_PY="$TMP/no-such-python"
assert_failure "missing interpreter" "manifest-parse-failed"

# ============================================================================
# 14. the READ-ONLY contract
# ============================================================================
build_fixture "$FIX"
BEFORE="$TMP/before.txt"
AFTER="$TMP/after.txt"
snapshot "$FIX" >"$BEFORE"
run_reviewer verify
run_reviewer report
snapshot "$FIX" >"$AFTER"
if diff -q "$BEFORE" "$AFTER" >/dev/null 2>&1; then
  ok "read-only: the export directory is byte-identical after verify+report"
else
  bad "read-only: the reviewer modified the export directory"
  diff "$BEFORE" "$AFTER" | sed 's/^/      | /'
fi
if [ "$(find "$FIX" -type f | wc -l)" -eq 4 ]; then
  ok "read-only: the export directory still holds exactly 4 files"
else
  bad "read-only: unexpected file count in the export directory"
fi

# ============================================================================
# 15. the reviewer holds no decision logic of its own
# ============================================================================
if grep -Eq 'sha256sum|awk |python3? -c' "$REVIEWER"; then
  bad "the reviewer must not implement any decision itself"
  grep -nE 'sha256sum|awk |python3? -c' "$REVIEWER" | sed 's/^/      | /'
else
  ok "the reviewer contains no decision logic (no sha256sum / awk / inline python)"
fi
if grep -Eq '(^|[^_[:alnum:]])(uv |torch|onnxruntime)' "$REVIEWER"; then
  bad "the reviewer must not launch torch/onnx/uv"
  grep -nE '(^|[^_[:alnum:]])(uv |torch|onnxruntime)' "$REVIEWER" | sed 's/^/      | /'
else
  ok "the reviewer launches no torch/onnx/uv process (CPU, stdlib only)"
fi

# ============================================================================
# 16. the reviewer writes its own log
# ============================================================================
build_fixture "$FIX"
rm -f "$LOGD/20_export_verify.txt"
run_reviewer verify
if [ -s "$LOGD/20_export_verify.txt" ]; then
  ok "log: the reviewer wrote logs/env/20_export_verify.txt"
else
  bad "log: no log file written"; ls -l "$LOGD" 2>&1 | sed 's/^/      | /'
fi
if grep -q 'EXPORT_VERIFY_OK' "$LOGD/20_export_verify.txt" 2>/dev/null; then
  ok "log: the OK marker is greppable in the log file"
else
  bad "log: the OK marker is missing from the log file"
fi

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
