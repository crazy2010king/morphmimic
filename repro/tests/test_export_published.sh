#!/usr/bin/env bash
# repro/tests/test_export_published.sh — the READ-ONLY regression gate of the
# PUBLISHED export artefacts (slice S07, task T4).
#
# The fixture batteries (test_export.sh / test_export_verify.sh /
# test_export_orchestrator.sh) prove the DECISION LOGIC on synthetic inputs.
# This script proves the REAL, PUBLISHED artefacts still satisfy that logic,
# so a later change (a re-export, a worktree rebuild, a seed-store migration)
# cannot silently degrade the published landing spot.
#
# It is READ-ONLY: it never writes into the export directory, never launches
# the export toolchain (no torch / no GPU / no network).  It only reads:
#
#   out/g1_amber/{policy.onnx,g1_amber.json,MANIFEST.txt,SHA256SUMS}
#   logs/env/19_export.txt
#   logs/env/20_export_verify.txt
#
# Checks (each one prints PASS / FAIL):
#
#   1. the four artefacts exist and are non-empty
#   2. MANIFEST.txt carries a parsable parity block, every interface <= 1e-4
#   3. SHA256SUMS covers policy.onnx and g1_amber.json and the recomputed
#      digests match  (sha256sum -c must print two OK lines)
#   4. the independent reviewer (20_export_verify.sh verify) exits 0 and
#      prints EXPORT_VERIFY_OK
#   5. the export log carries the positive marker EXPORT_EXPORT_OK
#   6. the export log carries the negative-event markers EXPORT_NEG_FAIL
#      (at least one real negative path was exercised)
#   7. NO staging directory is left behind in out/  (no half-finished export)
#
# Usage: bash repro/tests/test_export_published.sh
# Exit code 0 == every check passed.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
cd "$_REPO_ROOT" || exit 2

ROBOT="${EXPORT_ROBOT:-g1_amber}"
ATOL="${EXPORT_ATOL:-1e-4}"
OUT_DIR="${EXPORT_OUT_DIR:-$_REPO_ROOT/out/$ROBOT}"
EXPORT_LOG="${EXPORT_LOG_DIR:-$_REPO_ROOT/logs/env}/19_export.txt"
VERIFY_LOG="${EXPORT_LOG_DIR:-$_REPO_ROOT/logs/env}/20_export_verify.txt"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# --- 1. the four artefacts exist and are non-empty -------------------------
for name in policy.onnx "$ROBOT.json" MANIFEST.txt SHA256SUMS; do
  if [ -s "$OUT_DIR/$name" ]; then
    ok "artefact present and non-empty: $name"
  else
    ko "artefact missing or empty: $name"
  fi
done

# --- 2. the parity block is parsable and within tolerance ------------------
if [ -s "$OUT_DIR/MANIFEST.txt" ]; then
  parity_line="$(grep 'ONNX - PyTorch' "$OUT_DIR/MANIFEST.txt" | head -n1)"
  if [ -z "$parity_line" ]; then
    ko "MANIFEST.txt has no parity line"
  else
    ok "MANIFEST.txt parity line present"
    # every "<interface> <value>" pair must be a finite number <= atol
    worst="$(printf '%s\n' "$parity_line" | tr -s ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+)?[eE][-+]?[0-9]+$' | sort -g | tail -n1)"
    if [ -z "$worst" ]; then
      ko "MANIFEST.txt parity line carries no numeric value"
    elif awk -v v="$worst" -v t="$ATOL" 'BEGIN { exit (v <= t) ? 0 : 1 }'; then
      ok "parity within tolerance: max=$worst <= $ATOL"
    else
      ko "parity over tolerance: max=$worst > $ATOL"
    fi
  fi
fi

# --- 3. the digests match the bytes on disk ---------------------------------
if [ -s "$OUT_DIR/SHA256SUMS" ]; then
  sums_out="$(cd "$OUT_DIR" && sha256sum -c SHA256SUMS 2>&1)"
  sums_rc=$?
  ok_count="$(printf '%s\n' "$sums_out" | grep -c ': OK$')"
  if [ "$sums_rc" -eq 0 ] && [ "$ok_count" -ge 2 ]; then
    ok "sha256sum -c SHA256SUMS: $ok_count OK lines"
  else
    ko "sha256sum -c SHA256SUMS failed (rc=$sums_rc, ok lines=$ok_count)"
  fi
else
  ko "SHA256SUMS missing or empty"
fi

# --- 4. the independent reviewer still passes -------------------------------
review_out="$(EXPORT_ALLOW_LOCAL=1 bash "$_REPO_ROOT/repro/20_export_verify.sh" verify 2>&1)"
review_rc=$?
if [ "$review_rc" -eq 0 ] && printf '%s\n' "$review_out" | grep -q '^EXPORT_VERIFY_OK '; then
  ok "20_export_verify.sh verify: $(printf '%s\n' "$review_out" | grep '^EXPORT_VERIFY_OK ' | head -n1)"
else
  ko "20_export_verify.sh verify failed (rc=$review_rc)"
fi

# --- 5./6. the export log markers ------------------------------------------
if [ -s "$EXPORT_LOG" ]; then
  if grep -q '^EXPORT_EXPORT_OK ' "$EXPORT_LOG"; then
    ok "export log carries EXPORT_EXPORT_OK"
  else
    ko "export log has no EXPORT_EXPORT_OK"
  fi
  neg_count="$(grep -c '^EXPORT_NEG_FAIL ' "$EXPORT_LOG")"
  if [ "$neg_count" -ge 1 ]; then
    ok "export log carries $neg_count EXPORT_NEG_FAIL negative-event marker(s)"
  else
    ko "export log has no EXPORT_NEG_FAIL marker (no failure path was exercised)"
  fi
else
  ko "export log missing or empty: $EXPORT_LOG"
fi

if [ -s "$VERIFY_LOG" ]; then
  if grep -q 'EXPORT_VERIFY_OK' "$VERIFY_LOG"; then
    ok "verifier log carries EXPORT_VERIFY_OK"
  else
    ko "verifier log has no EXPORT_VERIFY_OK"
  fi
else
  ko "verifier log missing or empty: $VERIFY_LOG"
fi

# --- 7. no staging residue --------------------------------------------------
residue="$(find "$(dirname "$OUT_DIR")" -maxdepth 1 -name '.staging-*' 2>/dev/null | head -n5)"
if [ -z "$residue" ]; then
  ok "no staging directory left behind in $(dirname "$OUT_DIR")"
else
  ko "staging residue found: $residue"
fi

printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
