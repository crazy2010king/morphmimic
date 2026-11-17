#!/usr/bin/env bash
# repro/tests/test_toolchain.sh — offline unit tests for the tool chain
# verdict contract (repro/lib/toolchain.sh).
#
# The tests are pure-local: they use fixture verdict files and the TC_OFFLINE
# short circuit, so they need neither network, compiler, container nor a real
# venv.
#
# Covered failure surfaces:
#   1. tc_emit_verdict: the three line format, the legal verdict values,
#      the non-empty reason and the non-empty evidence
#   2. a complete verdict set is accepted (TOOLCHAIN_OK)
#   3. a missing tool group fails
#   4. an empty reason fails
#   5. an empty evidence fails
#   6. an illegal verdict fails
#   7. tc_compare_verdicts: log and conclusion agree / disagree
#   8. the four probes run offline and produce four legal verdict groups
#
# Run locally:  bash repro/tests/test_toolchain.sh
# Run remotely: bash repro/lib/remote.sh tests/test_toolchain.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=repro/lib/toolchain.sh
source "$LIB_DIR/toolchain.sh"

# common.sh turns on `errexit`; this file drives commands that are EXPECTED
# to fail, so switch it back off for the assertions below.
set +e

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. the verdict line format -------------------------------------------
out="$(tc_emit_verdict GMR VERIFIED "子模块已落地且可导入" "logs/env/07_toolchain.txt")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]; then
  ok "tc_emit_verdict prints exactly three lines"
else
  bad "tc_emit_verdict must print exactly three lines (rc=$rc): $out"
fi
if printf '%s\n' "$out" | grep -qx 'TOOLCHAIN_GMR_VERDICT=VERIFIED' \
   && printf '%s\n' "$out" | grep -qx 'TOOLCHAIN_GMR_REASON=子模块已落地且可导入' \
   && printf '%s\n' "$out" | grep -qx 'TOOLCHAIN_GMR_EVIDENCE=logs/env/07_toolchain.txt'; then
  ok "the three verdict lines carry the expected names"
else
  bad "the three verdict lines are wrong: $out"
fi

# a SKIPPED verdict must still carry a reason
out="$(tc_emit_verdict SOMA SKIPPED "需要 Python >= 3.12，项目 venv 是 3.11" "logs/toolchain/diag/soma_sync.log")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'TOOLCHAIN_SOMA_VERDICT=SKIPPED'; then
  ok "a SKIPPED verdict with a reason is accepted"
else
  bad "a SKIPPED verdict with a reason must be accepted (rc=$rc): $out"
fi

# an empty reason is rejected
out="$(tc_emit_verdict XRT SKIPPED "" "logs/env/07_toolchain.txt" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'TOOLCHAIN_XRT_VERDICT='; then
  ok "an empty reason is rejected and nothing is printed"
else
  bad "an empty reason must be rejected (rc=$rc): $out"
fi

# an empty evidence is rejected
out="$(tc_emit_verdict XRT VERIFIED "验过了" "" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'TOOLCHAIN_XRT_VERDICT='; then
  ok "an empty evidence is rejected and nothing is printed"
else
  bad "an empty evidence must be rejected (rc=$rc): $out"
fi

# an illegal verdict is rejected
out="$(tc_emit_verdict XRT MAYBE "验过了" "logs/env/07_toolchain.txt" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an illegal verdict value is rejected"
else
  bad "an illegal verdict value must be rejected: $out"
fi

# an unknown tool name is rejected
out="$(tc_emit_verdict FOO VERIFIED "验过了" "logs/env/07_toolchain.txt" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an unknown tool name is rejected"
else
  bad "an unknown tool name must be rejected: $out"
fi

# --- 2. a complete verdict set passes -------------------------------------
LOG_FULL="$TMP/log_full.txt"
cat >"$LOG_FULL" <<'EOF'
=== 07_toolchain.sh probe 2026-01-01T00:00:00Z ===
PROBE[GMR] pinned=25f56db actual=25f56db
TOOLCHAIN_GMR_VERDICT=VERIFIED
TOOLCHAIN_GMR_REASON=GMR 子模块在锁定提交上且可导入
TOOLCHAIN_GMR_EVIDENCE=logs/env/07_toolchain.txt
TOOLCHAIN_SOMA_VERDICT=SKIPPED
TOOLCHAIN_SOMA_REASON=需要 Python >= 3.12
TOOLCHAIN_SOMA_EVIDENCE=logs/toolchain/diag/soma_sync.log
TOOLCHAIN_XRT_VERDICT=SKIPPED
TOOLCHAIN_XRT_REASON=构建需要外网拉 cmake
TOOLCHAIN_XRT_EVIDENCE=logs/toolchain/diag/xrt_build.log
TOOLCHAIN_UNITREE_VERDICT=VERIFIED
TOOLCHAIN_UNITREE_REASON=绑定在副本里构建成功
TOOLCHAIN_UNITREE_EVIDENCE=logs/toolchain/build/unitree_sdk2_wrapper
EOF
out="$(tc_check_verdicts "$LOG_FULL")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'TOOLCHAIN_OK'; then
  ok "a complete verdict set is accepted (TOOLCHAIN_OK)"
else
  bad "a complete verdict set must be accepted (rc=$rc): $out"
fi

# the parser exposes one row per tool
rows="$(tc_parse_verdicts "$LOG_FULL")"
if [ "$(printf '%s\n' "$rows" | wc -l)" -eq 4 ] \
   && printf '%s\n' "$rows" | grep -q '^GMR|VERIFIED|' \
   && printf '%s\n' "$rows" | grep -q '^UNITREE|VERIFIED|'; then
  ok "tc_parse_verdicts returns one row per tool"
else
  bad "tc_parse_verdicts must return one row per tool: $rows"
fi

# --- 3. a missing group fails ---------------------------------------------
LOG_MISSING="$TMP/log_missing.txt"
grep -v 'TOOLCHAIN_XRT_' "$LOG_FULL" >"$LOG_MISSING"
out="$(tc_check_verdicts "$LOG_MISSING")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'missing verdict for XRT'; then
  ok "a missing tool group fails and is named"
else
  bad "a missing tool group must fail (rc=$rc): $out"
fi

# --- 4. an empty reason fails ---------------------------------------------
LOG_NO_REASON="$TMP/log_no_reason.txt"
sed 's/^TOOLCHAIN_SOMA_REASON=.*/TOOLCHAIN_SOMA_REASON=/' "$LOG_FULL" >"$LOG_NO_REASON"
out="$(tc_check_verdicts "$LOG_NO_REASON")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'empty reason for SOMA'; then
  ok "an empty reason fails and is named"
else
  bad "an empty reason must fail (rc=$rc): $out"
fi

# --- 5. an empty evidence fails -------------------------------------------
LOG_NO_EVIDENCE="$TMP/log_no_evidence.txt"
sed 's/^TOOLCHAIN_UNITREE_EVIDENCE=.*/TOOLCHAIN_UNITREE_EVIDENCE=/' "$LOG_FULL" >"$LOG_NO_EVIDENCE"
out="$(tc_check_verdicts "$LOG_NO_EVIDENCE")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'empty evidence for UNITREE'; then
  ok "an empty evidence fails and is named"
else
  bad "an empty evidence must fail (rc=$rc): $out"
fi

# --- 6. an illegal verdict fails ------------------------------------------
LOG_BAD_VERDICT="$TMP/log_bad_verdict.txt"
sed 's/^TOOLCHAIN_GMR_VERDICT=.*/TOOLCHAIN_GMR_VERDICT=MAYBE/' "$LOG_FULL" >"$LOG_BAD_VERDICT"
out="$(tc_check_verdicts "$LOG_BAD_VERDICT")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'illegal verdict for GMR'; then
  ok "an illegal verdict fails and is named"
else
  bad "an illegal verdict must fail (rc=$rc): $out"
fi

# --- 7. log vs conclusion --------------------------------------------------
DOC_SAME="$TMP/doc_same.md"
{
  echo "# 工具链结论"
  echo
  echo '```'
  grep '^TOOLCHAIN_' "$LOG_FULL"
  echo '```'
} >"$DOC_SAME"
out="$(tc_compare_verdicts "$LOG_FULL" "$DOC_SAME")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'TOOLCHAIN_DOC_OK'; then
  ok "log and conclusion with the same verdicts agree"
else
  bad "log and conclusion must agree (rc=$rc): $out"
fi

DOC_DIFF="$TMP/doc_diff.md"
sed 's/^TOOLCHAIN_SOMA_VERDICT=.*/TOOLCHAIN_SOMA_VERDICT=VERIFIED/' "$DOC_SAME" >"$DOC_DIFF"
out="$(tc_compare_verdicts "$LOG_FULL" "$DOC_DIFF")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'verdict mismatch for SOMA'; then
  ok "a verdict mismatch between log and conclusion fails"
else
  bad "a verdict mismatch must fail (rc=$rc): $out"
fi

DOC_REASON_DIFF="$TMP/doc_reason_diff.md"
sed 's/^TOOLCHAIN_XRT_REASON=.*/TOOLCHAIN_XRT_REASON=别的说法/' "$DOC_SAME" >"$DOC_REASON_DIFF"
out="$(tc_compare_verdicts "$LOG_FULL" "$DOC_REASON_DIFF")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'reason mismatch for XRT'; then
  ok "a reason mismatch between log and conclusion fails"
else
  bad "a reason mismatch must fail (rc=$rc): $out"
fi

out="$(tc_compare_verdicts "$LOG_FULL" "$TMP/does_not_exist.md" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a missing conclusion file fails the comparison"
else
  bad "a missing conclusion file must fail the comparison: $out"
fi

# --- 8. the four probes run offline ---------------------------------------
PROBE_OUT="$TMP/probe_out.txt"
TC_OFFLINE=1 tc_probe_all >"$PROBE_OUT" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "the four probes run offline without an error"
else
  bad "the four probes must run offline without an error (rc=$rc): $(cat "$PROBE_OUT")"
fi
if [ "$(grep -c '^TOOLCHAIN_.*_VERDICT=' "$PROBE_OUT")" -eq 4 ]; then
  ok "the four probes produce four verdict lines"
else
  bad "the four probes must produce four verdict lines: $(cat "$PROBE_OUT")"
fi
if tc_check_verdicts "$PROBE_OUT" | grep -qx 'TOOLCHAIN_OK'; then
  ok "the offline verdict set satisfies the contract"
else
  bad "the offline verdict set must satisfy the contract: $(cat "$PROBE_OUT")"
fi
if [ "$(grep -c '^TOOLCHAIN_.*_VERDICT=SKIPPED' "$PROBE_OUT")" -eq 4 ] \
   && [ "$(grep -c '^TOOLCHAIN_.*_REASON=..' "$PROBE_OUT")" -eq 4 ]; then
  ok "every offline verdict is SKIPPED and carries a reason"
else
  bad "every offline verdict must be SKIPPED with a reason: $(cat "$PROBE_OUT")"
fi

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "TESTS_FAILED"
  exit 1
fi
echo "TESTS_OK"
exit 0
