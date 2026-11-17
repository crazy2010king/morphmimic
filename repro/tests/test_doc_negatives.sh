#!/usr/bin/env bash
# repro/tests/test_doc_negatives.sh — the OFFLINE-CLEAN wrapper of the real
# negative battery of the reproduction-record verifier (slice S09, task T5).
#
# WHAT THIS TEST COVERS
#
#   The offline battery (repro/tests/test_doc_verify.sh) drives the
#   verifier with synthetic fixtures; this one drives it with the REAL
#   record and the REAL artefacts, and asserts that the verifier is not a
#   machine that only ever prints OK:
#
#     NEG-1  a number inside the evidence index table is changed
#                                       -> reason=evidence-marker-missing
#     NEG-2  chapter 4 (已分析未执行清单) is deleted
#                                       -> reason=section-missing
#     NEG-3  a fake plaintext token is injected -> reason=token-leaked
#
#   Every negative must exit 1, name the expected reason, and print ZERO
#   "DOC_VERIFY_OK" / "DOC_MIRROR_OK" markers.  The formal landing points
#   (docs/code_read/, docs/code_doc/, runs/, out/) must be byte-identical
#   before and after the battery, and no ".staging-*" residue may exist.
#
#   The two-sided consistency of the terminal gate (host vs. container) is
#   only asserted when the ros_dev container is reachable; otherwise the
#   case is SKIPPED (the container gate is a separate, network-dependent
#   step).
#
# usage: bash repro/tests/test_doc_negatives.sh

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_SCRIPT_DIR/../lib/common.sh"
set +e

NEGATIVES="$REPO_ROOT/repro/29_doc_verify_negatives.sh"
NEG_LOG="$LOG_DIR/28_doc_verify_negatives.txt"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

if [ ! -f "$NEGATIVES" ]; then
  printf 'FAIL: %s is missing\n' "$NEGATIVES"
  printf 'TESTS_FAIL PASS=%s FAIL=%s\n' "$PASS" "$((FAIL + 1))"
  exit 1
fi

out="$(bash "$NEGATIVES" run 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/    | /'

[ "$rc" -eq 0 ] && ok "the negative battery exits 0" || bad "the negative battery exits $rc"
printf '%s\n' "$out" | grep -q 'DOC_NEGATIVES_OK negatives=3' \
  && ok "the battery prints DOC_NEGATIVES_OK negatives=3" \
  || bad "the battery prints no DOC_NEGATIVES_OK marker"

for reason in evidence-marker-missing section-missing token-leaked; do
  printf '%s\n' "$out" | grep -q "reason=$reason" \
    && ok "the battery observed reason=$reason" \
    || bad "the battery never observed reason=$reason"
done

if [ -f "$NEG_LOG" ]; then
  ok "the transcript $NEG_LOG exists"
  for id in NEG-1 NEG-2 NEG-3; do
    grep -q "^$id rc=1$" "$NEG_LOG" \
      && ok "the transcript records $id rc=1" \
      || bad "the transcript has no '$id rc=1' line"
  done
  grep -q "digests of the formal landing points AFTER the battery: .* (unchanged)" "$NEG_LOG" \
    && ok "the transcript records the landing points as unchanged" \
    || bad "the transcript does not record the landing points as unchanged"
  grep -q "staging residue (.staging-\*): none" "$NEG_LOG" \
    && ok "the transcript records no staging residue" \
    || bad "the transcript records staging residue"
  if grep -q 'DOC_VERIFY_OK' "$NEG_LOG"; then
    bad "the transcript contains a DOC_VERIFY_OK marker"
  else
    ok "the transcript contains zero DOC_VERIFY_OK markers"
  fi
  if grep -q 'DOC_MIRROR_OK' "$NEG_LOG"; then
    bad "the transcript contains a DOC_MIRROR_OK marker"
  else
    ok "the transcript contains zero DOC_MIRROR_OK markers"
  fi
else
  bad "the transcript $NEG_LOG is missing"
fi

# --- the two-sided consistency of the terminal gate -------------------------
both_out="$(bash "$NEGATIVES" both 2>&1)"
both_rc=$?
if printf '%s\n' "$both_out" | grep -q 'DOC_TWO_SIDES_OK markers_identical=1'; then
  ok "the host side and the container side print the same DOC_VERIFY_OK line"
elif [ "$both_rc" -ne 0 ] && printf '%s\n' "$both_out" | grep -qi 'connect\|refused\|timeout\|no route'; then
  printf 'SKIP: the ros_dev container is not reachable (the two-sided gate needs it)\n'
else
  bad "the host side and the container side do not agree"
  printf '%s\n' "$both_out" | sed 's/^/    | /'
fi

printf 'TESTS_OK PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
