#!/usr/bin/env bash
# repro/tests/test_seed_verify.sh — offline negative/positive fixture battery
# for repro/09_seed_verify.sh (the BONES-SEED archive integrity gate).
#
# No network access and no real archives: every archive is a synthetic tar
# built in a temp dir. The battery covers:
#
#   1. happy path            -> exit 0, all OK markers present
#   2. truncated gzip        -> exit != 0, SEED_TAR_GZIP_FAIL
#   3. missing member        -> exit != 0, SEED_TAR_CLIPS_MISMATCH
#   4. sha256 list mismatch  -> exit != 0, SEED_SHA256_MISMATCH
#   5. archive missing       -> exit != 0, SEED_ARCHIVE_MISSING ("归档未就位")
#   6. absolute-path member  -> exit != 0, SEED_TAR_LAYOUT_FAIL
#   7. ".." member           -> exit != 0, SEED_TAR_LAYOUT_FAIL
#   8. status file contract  -> STATE / RC / STARTED_AT / FINISHED_AT
#   9. the script is read-only: no curl/wget, no tar extraction
#
# EVERY failing case additionally asserts that NO *_OK marker was printed.
#
# Run locally:   bash repro/tests/test_seed_verify.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_seed_verify.sh
# (also reachable as `bash repro/lib/remote.sh 09_seed_verify.sh selftest`)
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/repro/09_seed_verify.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"

# --- fixture builders -------------------------------------------------------

# build_g1 <src dir> <clip names...> -> creates g1/csv/230509/<name>.csv
build_g1() {
  local src="$1"; shift
  mkdir -p "$src/g1/csv/230509"
  local name
  for name in "$@"; do
    printf 'a,b,c,d,e,f,g,h,i,j,k,l\n1,2,3,4,5,6,7,8,9,10,11,12\n' \
      >"$src/g1/csv/230509/$name.csv"
  done
}

# build_soma <src dir> <clip names...> -> soma_uniform/bvh/230509/<name>.bvh
build_soma() {
  local src="$1"; shift
  mkdir -p "$src/soma_uniform/bvh/230509"
  local name
  for name in "$@"; do
    printf 'HIERARCHY\nROOT x\n' >"$src/soma_uniform/bvh/230509/$name.bvh"
  done
}

# write_sums <archive dir> — SHA256SUMS for the archives present there
write_sums() {
  local dir="$1"
  ( cd "$dir" && sha256sum g1.tar.gz soma_uniform.tar.gz >SHA256SUMS 2>/dev/null || true )
  if [ ! -s "$dir/SHA256SUMS" ]; then
    ( cd "$dir" && for f in *.tar.gz; do sha256sum "$f"; done >SHA256SUMS )
  fi
}

# --- runner -----------------------------------------------------------------

# run_verify <archive dir> [ENV=VALUE ...]
# Runs the verifier against a fixture directory; sets $RC and $OUT.
run_verify() {
  local dir="$1"; shift
  OUT="$TMP/stdout.$(date +%s%N).txt"
  set +e
  env SEED_VERIFY_ALLOW_LOCAL=1 \
      SEED_ARCHIVE_DIR="$dir" \
      SEED_SHA256SUMS="$dir/SHA256SUMS" \
      SEED_VERIFY_LOG="$TMP/log.$(basename "$OUT").txt" \
      SEED_VERIFY_STATUS="$TMP/status.$(basename "$OUT").txt" \
      "$@" \
      bash "$SCRIPT" verify >"$OUT" 2>&1
  RC=$?
  set +e
  return 0
}

has() { grep -qF -- "$1" "$OUT"; }

# assert_no_ok_marker — a failing run must never print an OK marker
assert_no_ok_marker() {
  local label="$1" leaked=""
  for m in "SEED_VERIFY_OK" "SEED_SHA256_OK" "SEED_TAR_GZIP_OK" \
           "SEED_TAR_LAYOUT_OK" "SEED_TAR_CLIPS file="; do
    if grep -qF -- "$m" "$OUT"; then leaked="$leaked $m"; fi
  done
  if [ -n "$leaked" ]; then
    bad "$label: failing run leaked OK marker(s):$leaked"
    sed 's/^/      | /' "$OUT"
  else
    ok "$label: failing run printed no OK marker"
  fi
}

# ============================================================================
# 1. happy path
# ============================================================================
FIX="$TMP/case_ok"
mkdir -p "$FIX"
G1SRC="$TMP/src_ok_g1"; SOMSRC="$TMP/src_ok_soma"
build_g1 "$G1SRC" clip_a clip_b
build_soma "$SOMSRC" clip_a
tar -czf "$FIX/g1.tar.gz" -C "$G1SRC" g1
tar -czf "$FIX/soma_uniform.tar.gz" -C "$SOMSRC" soma_uniform
write_sums "$FIX"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -eq 0 ]; then
  ok "happy path: verify exits 0"
else
  bad "happy path: verify exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
for m in "SEED_SHA256_OK file=g1.tar.gz" \
         "SEED_SHA256_OK file=soma_uniform.tar.gz" \
         "SEED_TAR_GZIP_OK file=g1.tar.gz" \
         "SEED_TAR_ENTRIES file=g1.tar.gz" \
         "SEED_TAR_CLIPS file=g1 kind=csv count=2" \
         "SEED_TAR_CLIPS file=soma_uniform kind=bvh count=1" \
         "SEED_VERIFY_OK archives=2 clips=3"; do
  if has "$m"; then ok "happy path: marker present: $m"; else bad "happy path: marker MISSING: $m"; fi
done
STATUS_OK="$TMP/status.$(basename "$OUT").txt"
for k in "STATE=OK" "RC=0" "STARTED_AT=" "FINISHED_AT="; do
  if grep -qF -- "$k" "$STATUS_OK" 2>/dev/null; then
    ok "status file carries $k"
  else
    bad "status file missing $k"
  fi
done

# ============================================================================
# 2. truncated gzip (the archive was cut in half by the proxy)
# ============================================================================
FIX="$TMP/case_truncated"
mkdir -p "$FIX"
G1SRC="$TMP/src_tr_g1"; SOMSRC="$TMP/src_tr_soma"
build_g1 "$G1SRC" clip_a clip_b
build_soma "$SOMSRC" clip_a
tar -czf "$TMP/full_g1.tar.gz" -C "$G1SRC" g1
tar -czf "$FIX/soma_uniform.tar.gz" -C "$SOMSRC" soma_uniform
# cut the gzip stream in half
FULL_SIZE="$(stat -c %s "$TMP/full_g1.tar.gz")"
head -c $((FULL_SIZE / 2)) "$TMP/full_g1.tar.gz" >"$FIX/g1.tar.gz"
write_sums "$FIX"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -ne 0 ]; then
  ok "truncated gzip: verify exits non-zero ($RC)"
else
  bad "truncated gzip: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_TAR_GZIP_FAIL file=g1.tar.gz"; then
  ok "truncated gzip: SEED_TAR_GZIP_FAIL printed"
else
  bad "truncated gzip: SEED_TAR_GZIP_FAIL missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "truncated gzip"

# ============================================================================
# 3. one member missing (valid gzip, wrong clip count)
# ============================================================================
FIX="$TMP/case_missing_member"
mkdir -p "$FIX"
G1SRC="$TMP/src_mm_g1"; SOMSRC="$TMP/src_mm_soma"
build_g1 "$G1SRC" clip_a            # only ONE clip instead of two
build_soma "$SOMSRC" clip_a
tar -czf "$FIX/g1.tar.gz" -C "$G1SRC" g1
tar -czf "$FIX/soma_uniform.tar.gz" -C "$SOMSRC" soma_uniform
write_sums "$FIX"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -ne 0 ]; then
  ok "missing member: verify exits non-zero ($RC)"
else
  bad "missing member: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_TAR_CLIPS_MISMATCH file=g1.tar.gz expected=2 actual=1"; then
  ok "missing member: SEED_TAR_CLIPS_MISMATCH printed"
else
  bad "missing member: SEED_TAR_CLIPS_MISMATCH missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "missing member"

# ============================================================================
# 4. sha256 list does not match the archive
# ============================================================================
FIX="$TMP/case_sha_mismatch"
mkdir -p "$FIX"
G1SRC="$TMP/src_sha_g1"; SOMSRC="$TMP/src_sha_soma"
build_g1 "$G1SRC" clip_a clip_b
build_soma "$SOMSRC" clip_a
tar -czf "$FIX/g1.tar.gz" -C "$G1SRC" g1
tar -czf "$FIX/soma_uniform.tar.gz" -C "$SOMSRC" soma_uniform
write_sums "$FIX"
# corrupt the recorded hash of g1.tar.gz (deterministically: all zeroes)
sed -i 's|^[0-9a-f]\{64\}  g1\.tar\.gz$|0000000000000000000000000000000000000000000000000000000000000000  g1.tar.gz|' \
  "$FIX/SHA256SUMS"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -ne 0 ]; then
  ok "sha256 mismatch: verify exits non-zero ($RC)"
else
  bad "sha256 mismatch: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_SHA256_MISMATCH file=g1.tar.gz"; then
  ok "sha256 mismatch: SEED_SHA256_MISMATCH printed"
else
  bad "sha256 mismatch: SEED_SHA256_MISMATCH missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "sha256 mismatch"

# ============================================================================
# 5. archive missing (not downloaded yet)
# ============================================================================
FIX="$TMP/case_missing_archive"
mkdir -p "$FIX"
G1SRC="$TMP/src_ma_g1"; SOMSRC="$TMP/src_ma_soma"
build_g1 "$G1SRC" clip_a clip_b
build_soma "$SOMSRC" clip_a
tar -czf "$FIX/g1.tar.gz" -C "$G1SRC" g1
# soma_uniform.tar.gz deliberately NOT created
write_sums "$FIX"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -ne 0 ]; then
  ok "missing archive: verify exits non-zero ($RC)"
else
  bad "missing archive: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_ARCHIVE_MISSING file=soma_uniform.tar.gz"; then
  ok "missing archive: SEED_ARCHIVE_MISSING printed"
else
  bad "missing archive: SEED_ARCHIVE_MISSING missing"; sed 's/^/      | /' "$OUT"
fi
if has "归档未就位"; then
  ok "missing archive: explicit '归档未就位' hint printed"
else
  bad "missing archive: no '归档未就位' hint"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "missing archive"

# ============================================================================
# 6. layout violation: absolute member path
# ============================================================================
FIX="$TMP/case_abs_layout"
mkdir -p "$FIX"
ABS="$TMP/absroot"
mkdir -p "$ABS"
printf 'a,b,c\n1,2,3\n' >"$ABS/abs_a.csv"
printf 'a,b,c\n4,5,6\n' >"$ABS/abs_b.csv"
# -P keeps the leading "/" inside the archive
tar -czPf "$FIX/g1.tar.gz" -C / "$ABS/abs_a.csv" "$ABS/abs_b.csv"
G1SRC="$TMP/src_al_g1"; SOMSRC="$TMP/src_al_soma"
build_soma "$SOMSRC" clip_a
tar -czf "$FIX/soma_uniform.tar.gz" -C "$SOMSRC" soma_uniform
write_sums "$FIX"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -ne 0 ]; then
  ok "absolute layout: verify exits non-zero ($RC)"
else
  bad "absolute layout: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_TAR_LAYOUT_FAIL file=g1.tar.gz"; then
  ok "absolute layout: SEED_TAR_LAYOUT_FAIL printed"
else
  bad "absolute layout: SEED_TAR_LAYOUT_FAIL missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "absolute layout"

# ============================================================================
# 7. layout violation: ".." member path
# ============================================================================
FIX="$TMP/case_dotdot_layout"
mkdir -p "$FIX"
EVIL="$TMP/evilroot"
mkdir -p "$EVIL/evil"
printf 'a,b,c\n1,2,3\n' >"$EVIL/evil/e_a.csv"
printf 'a,b,c\n4,5,6\n' >"$EVIL/evil/e_b.csv"
tar -czPf "$FIX/g1.tar.gz" -C "$TMP" "evilroot/../evilroot/evil/e_a.csv" "evilroot/../evilroot/evil/e_b.csv"
G1SRC="$TMP/src_dd_g1"; SOMSRC="$TMP/src_dd_soma"
build_soma "$SOMSRC" clip_a
tar -czf "$FIX/soma_uniform.tar.gz" -C "$SOMSRC" soma_uniform
write_sums "$FIX"

run_verify "$FIX" SEED_EXPECTED_CLIPS_G1=2 SEED_EXPECTED_CLIPS_SOMA=1
if [ "$RC" -ne 0 ]; then
  ok "dotdot layout: verify exits non-zero ($RC)"
else
  bad "dotdot layout: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_TAR_LAYOUT_FAIL file=g1.tar.gz"; then
  ok "dotdot layout: SEED_TAR_LAYOUT_FAIL printed"
else
  bad "dotdot layout: SEED_TAR_LAYOUT_FAIL missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "dotdot layout"

# ============================================================================
# 8. the verifier is read-only and offline
# ============================================================================
if grep -Eq '(^|[^a-zA-Z_])(curl|wget)([^a-zA-Z_]|$)' "$SCRIPT"; then
  bad "the verifier must not contain any network invocation"
  grep -nE '(curl|wget)' "$SCRIPT" | sed 's/^/      | /'
else
  ok "the verifier contains no network invocation (curl/wget)"
fi
if grep -Eq 'tar[^|]*-[a-zA-Z]*x' "$SCRIPT"; then
  bad "the verifier must not extract anything (tar -x)"
else
  ok "the verifier never extracts (no tar -x)"
fi

# ============================================================================
# summary
# ============================================================================
printf '\n== test_seed_verify.sh: PASS=%d FAIL=%d SKIP=%d ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "ERROR: $SKIP test(s) were skipped — a SKIP must never mask a failure." >&2
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
