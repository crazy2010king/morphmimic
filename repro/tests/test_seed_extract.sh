#!/usr/bin/env bash
# repro/tests/test_seed_extract.sh — offline fixture battery for
# repro/10_seed_extract.sh (BONES-SEED extraction + metadata reconciliation).
#
# No network and no real archives: every archive is a synthetic tar built in
# a temp dir and every metadata CSV is synthetic.  The battery covers:
#
#   1. happy path        -> exit 0, all markers present, trees extracted
#   2. idempotent re-run -> exit 0, SEED_EXTRACT_SKIP, .done marker present
#   3. missing member    -> exit != 0, SEED_META_MATCH missing>0
#   4. extra file        -> exit != 0, SEED_META_MATCH extra>0
#   5. zero-byte file    -> exit != 0
#   6. space gate        -> exit != 0, "空间不足" hint
#   7. the script never uses --same-owner / -p (root-squash safety)
#
# EVERY failing case additionally asserts that SEED_EXTRACT_OK was NOT
# printed (same OK-marker buffering convention as repro/09_seed_verify.sh).
#
# Run locally:   bash repro/tests/test_seed_extract.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_seed_extract.sh
# (also reachable as `bash repro/lib/remote.sh 10_seed_extract.sh selftest`)
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/repro/10_seed_extract.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT=""
RC=0

# --- fixture builders -------------------------------------------------------

# build_archives <archive dir> <n clips> [extra-member-name]
# Creates g1.tar.gz + soma_uniform.tar.gz + SHA256SUMS in <archive dir>.
build_archives() {
  local dir="$1" n="$2" extra="${3:-}"
  local src="$TMP/src_$(basename "$dir")"
  rm -rf "$src"
  mkdir -p "$src/g1/csv/230509" "$src/soma_uniform/bvh/230509" "$dir"
  local i name
  for i in $(seq 1 "$n"); do
    name="clip_$(printf '%03d' "$i")"
    printf 'a,b,c,d,e,f,g,h,i,j,k,l,m\n1,2,3,4,5,6,7,8,9,10,11,12,13\n' \
      >"$src/g1/csv/230509/$name.csv"
    printf 'HIERARCHY\nROOT x\n' >"$src/soma_uniform/bvh/230509/$name.bvh"
  done
  if [ -n "$extra" ]; then
    printf 'a,b,c,d,e,f,g,h,i,j,k,l,m\n1,2,3\n' >"$src/g1/csv/230509/$extra.csv"
    printf 'HIERARCHY\nROOT x\n' >"$src/soma_uniform/bvh/230509/$extra.bvh"
  fi
  tar -czf "$dir/g1.tar.gz" -C "$src" g1
  tar -czf "$dir/soma_uniform.tar.gz" -C "$src" soma_uniform
  ( cd "$dir" && sha256sum g1.tar.gz soma_uniform.tar.gz >SHA256SUMS )
}

# build_metadata <csv path> <n clips> [extra clip name]
# The metadata uses the same three columns as the real CSV.
build_metadata() {
  local path="$1" n="$2" extra="${3:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf 'filename,move_g1_path,move_soma_uniform_path\n'
    local i name
    for i in $(seq 1 "$n"); do
      name="clip_$(printf '%03d' "$i")"
      printf '%s,g1/csv/230509/%s.csv,soma_uniform/bvh/230509/%s.bvh\n' "$name" "$name" "$name"
    done
    if [ -n "$extra" ]; then
      printf '%s,g1/csv/230509/%s.csv,soma_uniform/bvh/230509/%s.bvh\n' "$extra" "$extra" "$extra"
    fi
  } >"$path"
}

# --- runner -----------------------------------------------------------------

# run_extract <case dir> <subcommand> [ENV=VALUE ...]
# Runs the extract script against a fixture; sets $RC and $OUT.
run_extract() {
  local dir="$1" sub="$2"; shift 2
  OUT="$TMP/out.$(basename "$dir").$sub.$(date +%s%N).txt"
  set +e
  env SEED_EXTRACT_ALLOW_LOCAL=1 \
      SEED_ARCHIVE_DIR="$dir/archives" \
      SEED_EXTRACT_ROOT="$dir/root" \
      SEED_EXTRACT_LOG="$dir/log.txt" \
      SEED_EXTRACT_STATUS="$dir/status.txt" \
      SEED_EXTRACT_WORKER_LOG="$dir/worker.log" \
      SEED_METADATA_CSV="$dir/root/metadata/seed_metadata_v004.csv" \
      SEED_EXPECTED_CLIPS_G1="${FIXTURE_CLIPS_G1:-}" \
      SEED_EXPECTED_CLIPS_SOMA="${FIXTURE_CLIPS_SOMA:-}" \
      SEED_MIN_FREE_GB="${FIXTURE_MIN_FREE_GB:-1}" \
      "$@" \
      bash "$SCRIPT" "$sub" >"$OUT" 2>&1
  RC=$?
  set +e
  return 0
}

has() { grep -qF -- "$1" "$OUT"; }

assert_no_ok_marker() {
  local label="$1"
  if grep -qF -- "SEED_EXTRACT_OK" "$OUT"; then
    bad "$label: failing run leaked SEED_EXTRACT_OK"
    sed 's/^/      | /' "$OUT"
  else
    ok "$label: failing run printed no SEED_EXTRACT_OK"
  fi
}

# ============================================================================
# 1. happy path
# ============================================================================
FIX="$TMP/case_ok"
mkdir -p "$FIX"
build_archives "$FIX/archives" 2
build_metadata "$FIX/root/metadata/seed_metadata_v004.csv" 2
FIXTURE_CLIPS_G1=2 FIXTURE_CLIPS_SOMA=2
export FIXTURE_CLIPS_G1 FIXTURE_CLIPS_SOMA

run_extract "$FIX" worker
if [ "$RC" -eq 0 ]; then
  ok "happy path: worker exits 0"
else
  bad "happy path: worker exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
for m in "SEED_EXTRACT_START file=g1.tar.gz" \
         "SEED_EXTRACT_DONE file=g1.tar.gz clips=2" \
         "SEED_EXTRACT_DONE file=soma_uniform.tar.gz clips=2" \
         "SEED_EXTRACT_FILES file=g1 count=2" \
         "SEED_EXTRACT_FILES file=soma_uniform count=2" \
         "SEED_EXTRACT_ZERO_BYTE count=0" \
         "SEED_META_MATCH matched=2 missing=0 extra=0" \
         "SEED_META_SESSION session=230509 expected=2 actual=2" \
         "SEED_EXTRACT_OK files=4"; do
  if has "$m"; then ok "happy path: marker present: $m"; else bad "happy path: marker MISSING: $m"; fi
done
if [ -f "$FIX/root/g1/csv/230509/clip_001.csv" ]; then
  ok "happy path: g1 tree extracted at the expected relative path"
else
  bad "happy path: g1 tree NOT extracted at g1/csv/230509/"
fi
if [ -f "$FIX/root/soma_uniform/bvh/230509/clip_001.bvh" ]; then
  ok "happy path: soma tree extracted at the expected relative path"
else
  bad "happy path: soma tree NOT extracted at soma_uniform/bvh/230509/"
fi
if [ -f "$FIX/root/_extract/g1.tar.gz.done" ] && [ -f "$FIX/root/_extract/soma_uniform.tar.gz.done" ]; then
  ok "happy path: .done markers written"
else
  bad "happy path: .done markers missing"
fi
for k in "STATE=DONE" "RC=0" "STARTED_AT=" "FINISHED_AT="; do
  if grep -qF -- "$k" "$FIX/status.txt" 2>/dev/null; then
    ok "status file carries $k"
  else
    bad "status file missing $k"
  fi
done

# ============================================================================
# 2. idempotent re-run (the .done marker makes the second run skip)
# ============================================================================
run_extract "$FIX" worker
if [ "$RC" -eq 0 ]; then
  ok "re-run: worker exits 0"
else
  bad "re-run: worker exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_EXTRACT_SKIP file=g1.tar.gz"; then
  ok "re-run: g1 extraction skipped (idempotent)"
else
  bad "re-run: g1 extraction was NOT skipped"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_EXTRACT_SKIP file=soma_uniform.tar.gz"; then
  ok "re-run: soma extraction skipped (idempotent)"
else
  bad "re-run: soma extraction was NOT skipped"; sed 's/^/      | /' "$OUT"
fi
if [ -f "$FIX/root/_extract/g1.tar.gz.done" ]; then
  ok "re-run: .done marker still present"
else
  bad "re-run: .done marker missing"
fi

# ============================================================================
# 3. missing member (a clip vanished from the extracted tree)
# ============================================================================
FIX="$TMP/case_missing"
mkdir -p "$FIX"
build_archives "$FIX/archives" 2
build_metadata "$FIX/root/metadata/seed_metadata_v004.csv" 2
FIXTURE_CLIPS_G1=2 FIXTURE_CLIPS_SOMA=2
export FIXTURE_CLIPS_G1 FIXTURE_CLIPS_SOMA
run_extract "$FIX" worker
rm -f "$FIX/root/g1/csv/230509/clip_002.csv"
run_extract "$FIX" verify
if [ "$RC" -ne 0 ]; then
  ok "missing member: verify exits non-zero ($RC)"
else
  bad "missing member: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_META_MATCH matched=1 missing=1 extra=0"; then
  ok "missing member: SEED_META_MATCH shows missing=1"
else
  bad "missing member: SEED_META_MATCH missing=1 missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "missing member"

# ============================================================================
# 4. extra file (a clip on disk that the metadata does not know)
# ============================================================================
FIX="$TMP/case_extra"
mkdir -p "$FIX"
build_archives "$FIX/archives" 2
build_metadata "$FIX/root/metadata/seed_metadata_v004.csv" 2
FIXTURE_CLIPS_G1=2 FIXTURE_CLIPS_SOMA=2
export FIXTURE_CLIPS_G1 FIXTURE_CLIPS_SOMA
run_extract "$FIX" worker
printf 'a,b,c\n1,2,3\n' >"$FIX/root/g1/csv/230509/clip_999.csv"
run_extract "$FIX" verify
if [ "$RC" -ne 0 ]; then
  ok "extra file: verify exits non-zero ($RC)"
else
  bad "extra file: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "extra=1"; then
  ok "extra file: SEED_META_MATCH reports extra=1"
else
  bad "extra file: SEED_META_MATCH does not report extra=1"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "extra file"

# ============================================================================
# 5. zero-byte file
# ============================================================================
FIX="$TMP/case_zero"
mkdir -p "$FIX"
build_archives "$FIX/archives" 2
build_metadata "$FIX/root/metadata/seed_metadata_v004.csv" 2
FIXTURE_CLIPS_G1=2 FIXTURE_CLIPS_SOMA=2
export FIXTURE_CLIPS_G1 FIXTURE_CLIPS_SOMA
run_extract "$FIX" worker
: >"$FIX/root/g1/csv/230509/clip_002.csv"
run_extract "$FIX" verify
if [ "$RC" -ne 0 ]; then
  ok "zero-byte file: verify exits non-zero ($RC)"
else
  bad "zero-byte file: verify exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_EXTRACT_ZERO_BYTE count=1"; then
  ok "zero-byte file: SEED_EXTRACT_ZERO_BYTE count=1"
else
  bad "zero-byte file: SEED_EXTRACT_ZERO_BYTE count=1 missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "zero-byte file"

# ============================================================================
# 6. space gate (not enough free space -> refuse to extract)
# ============================================================================
FIX="$TMP/case_space"
mkdir -p "$FIX"
build_archives "$FIX/archives" 1
build_metadata "$FIX/root/metadata/seed_metadata_v004.csv" 1
FIXTURE_CLIPS_G1=1 FIXTURE_CLIPS_SOMA=1
export FIXTURE_CLIPS_G1 FIXTURE_CLIPS_SOMA
FIXTURE_MIN_FREE_GB=99999999
export FIXTURE_MIN_FREE_GB
run_extract "$FIX" worker
if [ "$RC" -ne 0 ]; then
  ok "space gate: worker exits non-zero ($RC)"
else
  bad "space gate: worker exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
fi
if has "空间不足"; then
  ok "space gate: explicit '空间不足' hint printed"
else
  bad "space gate: no '空间不足' hint"; sed 's/^/      | /' "$OUT"
fi
if has "SEED_EXTRACT_GATE_FAIL reason=insufficient-space"; then
  ok "space gate: SEED_EXTRACT_GATE_FAIL reason=insufficient-space"
else
  bad "space gate: gate-fail marker missing"; sed 's/^/      | /' "$OUT"
fi
assert_no_ok_marker "space gate"
FIXTURE_MIN_FREE_GB=1
export FIXTURE_MIN_FREE_GB

# ============================================================================
# 7. root-squash safety: --no-same-owner is mandatory, -p is forbidden
# ============================================================================
if grep -nE -- '--same-owner' "$SCRIPT" | grep -v -- '--no-same-owner' | grep -q .; then
  bad "the extractor must not use --same-owner (root-squashed NFS)"
  grep -nE -- '--same-owner' "$SCRIPT" | sed 's/^/      | /'
else
  ok "the extractor never uses --same-owner (only --no-same-owner)"
fi
if grep -nE -- 'tar .*(^|[[:space:]])-p([[:space:]]|$)' "$SCRIPT" | grep -q .; then
  bad "the extractor must not use -p (preserve permissions)"
  grep -nE -- 'tar .*(^|[[:space:]])-p([[:space:]]|$)' "$SCRIPT" | sed 's/^/      | /'
else
  ok "the extractor never passes -p to tar (only the harmless 'mkdir -p')"
fi
if grep -qF -- '--no-same-owner' "$SCRIPT"; then
  ok "the extractor passes --no-same-owner"
else
  bad "the extractor does NOT pass --no-same-owner"
fi

# ============================================================================
# summary
# ============================================================================
printf '\n== test_seed_extract.sh: PASS=%d FAIL=%d SKIP=%d ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "ERROR: $SKIP test(s) were skipped — a SKIP must never mask a failure." >&2
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
