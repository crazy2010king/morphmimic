#!/usr/bin/env bash
# repro/tests/test_seed_archive.sh — offline unit tests for
# repro/lib/seed_archive.sh (the pure-function side of the BONES-SEED
# archive inspection / extraction).
#
# No network access: every fixture is a synthetic tar built in a temp dir.
#
# Covered:
#   1. archive kind / prefix / expected clip counts
#   2. entry counting (csv / bvh / total / directories)
#   3. layout validation: relative paths OK, absolute paths rejected,
#      ".." traversal rejected, wrong prefix rejected
#   4. extraction flags: --no-same-owner present, --same-owner / -p absent
#   5. the extraction flags really work (synthetic tar extracts cleanly)
#   6. free space gate
#   7. the library contains no network invocation
#
# Run locally:  bash repro/tests/test_seed_archive.sh
# Run remotely: bash repro/lib/remote.sh tests/test_seed_archive.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=repro/lib/seed_archive.sh
source "$LIB_DIR/seed_archive.sh"
# common.sh turns on `errexit`; these tests drive commands that are EXPECTED
# to fail, so switch it back off.
set +e

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixtures ---------------------------------------------------------------
# a realistic g1 archive: g1/csv/<date>/*.csv
G1_ROOT="$TMP/g1src"
mkdir -p "$G1_ROOT/g1/csv/230509" "$G1_ROOT/g1/csv/230510"
printf 'a,b,c,d,e,f,g,h,i,j,k,l\n1,2,3,4,5,6,7,8,9,10,11,12\n' \
  >"$G1_ROOT/g1/csv/230509/clip_a.csv"
printf 'a,b,c,d,e,f,g,h,i,j,k,l\n2,2,3,4,5,6,7,8,9,10,11,12\n' \
  >"$G1_ROOT/g1/csv/230509/clip_b.csv"
printf 'a,b,c,d,e,f,g,h,i,j,k,l\n3,2,3,4,5,6,7,8,9,10,11,12\n' \
  >"$G1_ROOT/g1/csv/230510/clip_c.csv"
G1_TAR="$TMP/g1.tar.gz"
tar -czf "$G1_TAR" -C "$G1_ROOT" g1

# a realistic soma archive: soma_uniform/bvh/<date>/*.bvh
SOMA_ROOT="$TMP/somasrc"
mkdir -p "$SOMA_ROOT/soma_uniform/bvh/230509"
printf 'HIERARCHY\nROOT x\n' >"$SOMA_ROOT/soma_uniform/bvh/230509/clip_a.bvh"
SOMA_TAR="$TMP/soma_uniform.tar.gz"
tar -czf "$SOMA_TAR" -C "$SOMA_ROOT" soma_uniform

# --- 1. archive facts -------------------------------------------------------
kind="$(seed_archive_kind g1.tar.gz)"
if [ "$kind" = "csv" ]; then
  ok "seed_archive_kind maps g1.tar.gz to csv"
else
  bad "seed_archive_kind returned '$kind' for g1.tar.gz"
fi

kind="$(seed_archive_kind soma_uniform.tar.gz)"
if [ "$kind" = "bvh" ]; then
  ok "seed_archive_kind maps soma_uniform.tar.gz to bvh"
else
  bad "seed_archive_kind returned '$kind' for soma_uniform.tar.gz"
fi

rc=0
seed_archive_kind other.tar.gz >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "seed_archive_kind fails for an unknown archive (rc=$rc)"
else
  bad "seed_archive_kind should fail for an unknown archive"
fi

prefix="$(seed_archive_prefix g1.tar.gz)"
if [ "$prefix" = "g1/csv/" ]; then
  ok "seed_archive_prefix returns g1/csv/"
else
  bad "seed_archive_prefix returned '$prefix'"
fi
prefix="$(seed_archive_prefix soma_uniform.tar.gz)"
if [ "$prefix" = "soma_uniform/bvh/" ]; then
  ok "seed_archive_prefix returns soma_uniform/bvh/"
else
  bad "seed_archive_prefix returned '$prefix'"
fi

clips="$(seed_archive_expected_clips g1.tar.gz)"
if [ "$clips" = "142220" ]; then
  ok "seed_archive_expected_clips is 142220 for g1"
else
  bad "seed_archive_expected_clips returned '$clips' for g1"
fi
clips="$(seed_archive_expected_clips soma_uniform.tar.gz)"
if [ "$clips" = "142220" ]; then
  ok "seed_archive_expected_clips is 142220 for soma_uniform"
else
  bad "seed_archive_expected_clips returned '$clips' for soma_uniform"
fi

# --- 2. entry counting ------------------------------------------------------
counts="$(seed_tar_count "$G1_TAR")"
csv="$(printf '%s' "$counts" | sed -n 's/.*csv=\([0-9]*\).*/\1/p')"
bvh="$(printf '%s' "$counts" | sed -n 's/.*bvh=\([0-9]*\).*/\1/p')"
total="$(printf '%s' "$counts" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
dirs="$(printf '%s' "$counts" | sed -n 's/.*dirs=\([0-9]*\).*/\1/p')"
if [ "$csv" = "3" ]; then
  ok "seed_tar_count counts 3 csv clips in the synthetic g1 archive"
else
  bad "seed_tar_count csv=$csv, expected 3 (counts: $counts)"
fi
if [ "$bvh" = "0" ]; then
  ok "seed_tar_count counts 0 bvh clips in the synthetic g1 archive"
else
  bad "seed_tar_count bvh=$bvh, expected 0 (counts: $counts)"
fi
if [ "$total" = "7" ] && [ "$dirs" = "4" ]; then
  ok "seed_tar_count reports total=7 dirs=4 for the synthetic g1 archive"
else
  bad "seed_tar_count reported total=$total dirs=$dirs, expected 7/4 (counts: $counts)"
fi

counts="$(seed_tar_count "$SOMA_TAR")"
bvh="$(printf '%s' "$counts" | sed -n 's/.*bvh=\([0-9]*\).*/\1/p')"
csv="$(printf '%s' "$counts" | sed -n 's/.*csv=\([0-9]*\).*/\1/p')"
if [ "$bvh" = "1" ] && [ "$csv" = "0" ]; then
  ok "seed_tar_count counts 1 bvh clip in the synthetic soma archive"
else
  bad "seed_tar_count counts: $counts (expected bvh=1 csv=0)"
fi

# a truncated gzip must not be counted as a valid archive
head -c 40 "$G1_TAR" >"$TMP/truncated.tar.gz"
rc=0
seed_tar_count "$TMP/truncated.tar.gz" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "seed_tar_count fails on a truncated gzip (rc=$rc)"
else
  bad "seed_tar_count should fail on a truncated gzip"
fi

# --- 3. layout validation ---------------------------------------------------
rc=0
seed_tar_layout_ok "$G1_TAR" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "seed_tar_layout_ok accepts a well-formed archive"
else
  bad "seed_tar_layout_ok rejected a well-formed archive (rc=$rc)"
fi

rc=0
seed_tar_layout_ok "$SOMA_TAR" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "seed_tar_layout_ok accepts a well-formed soma archive"
else
  bad "seed_tar_layout_ok rejected a well-formed soma archive (rc=$rc)"
fi

# absolute path member -> must fail
mkdir -p "$TMP/abs"
tar -czf "$TMP/abs/g1.tar.gz" -P /etc/hostname 2>/dev/null
rc=0
out="$(seed_tar_layout_ok "$TMP/abs/g1.tar.gz" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "seed_tar_layout_ok rejects an absolute path member (rc=$rc)"
else
  bad "seed_tar_layout_ok accepted an absolute path member"
fi
case "$out" in
  *"absolute path"*) ok "the absolute path violation is reported" ;;
  *) bad "unexpected violation message: $out" ;;
esac

# ".." traversal -> must fail
mkdir -p "$TMP/esc/sub"
echo x >"$TMP/esc/outside.csv"
( cd "$TMP/esc/sub" && tar -czf "$TMP/esc/g1.tar.gz" -P ../outside.csv ) 2>/dev/null
rc=0
out="$(seed_tar_layout_ok "$TMP/esc/g1.tar.gz" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "seed_tar_layout_ok rejects a parent-traversal member (rc=$rc)"
else
  bad "seed_tar_layout_ok accepted a parent-traversal member"
fi
case "$out" in
  *"parent traversal"*) ok "the parent traversal violation is reported" ;;
  *) bad "unexpected violation message: $out" ;;
esac

# wrong prefix -> must fail
mkdir -p "$TMP/wrong/g1/bvh"
echo x >"$TMP/wrong/g1/bvh/clip.bvh"
tar -czf "$TMP/wrong/g1.tar.gz" -C "$TMP/wrong" g1
rc=0
out="$(seed_tar_layout_ok "$TMP/wrong/g1.tar.gz" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "seed_tar_layout_ok rejects a member outside the expected prefix (rc=$rc)"
else
  bad "seed_tar_layout_ok accepted a member outside the expected prefix"
fi

# --- 4. extraction flags ----------------------------------------------------
seed_extract_args "$G1_TAR" >/dev/null
args="${SEED_EXTRACT_ARGS[*]}"
case " $args " in
  *"--no-same-owner"*) ok "the extraction flags include --no-same-owner" ;;
  *) bad "the extraction flags miss --no-same-owner (got: $args)" ;;
esac
case " $args " in
  *"--same-owner"*) bad "the extraction flags contain --same-owner (got: $args)" ;;
  *) ok "the extraction flags do not contain --same-owner" ;;
esac
case " $args " in
  *" -p "*) bad "the extraction flags contain -p (got: $args)" ;;
  *) ok "the extraction flags do not contain -p" ;;
esac
case " $args " in
  *"-xzf"*) ok "the extraction flags extract with gzip (-xzf)" ;;
  *) bad "the extraction flags miss -xzf (got: $args)" ;;
esac
case " $args " in
  *"$G1_TAR"*) ok "the extraction flags reference the archive" ;;
  *) bad "the extraction flags do not reference the archive (got: $args)" ;;
esac

# --- 5. the extraction flags really work -----------------------------------
OUT="$TMP/extracted"
mkdir -p "$OUT"
( cd "$OUT" && tar "${SEED_EXTRACT_ARGS[@]}" ) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$OUT/g1/csv/230509/clip_a.csv" ]; then
  ok "the synthetic g1 archive extracts to g1/csv/<date>/ with the given flags"
else
  bad "extracting the synthetic archive failed (rc=$rc)"
fi
n="$(find "$OUT" -name '*.csv' -type f | wc -l)"
if [ "$n" -eq 3 ]; then
  ok "the extracted tree contains the 3 synthetic csv clips"
else
  bad "the extracted tree contains $n csv clips, expected 3"
fi

# --- 6. free space gate -----------------------------------------------------
free="$(seed_free_gb "$TMP")"
case "$free" in
  ''|*[!0-9]*) bad "seed_free_gb did not return a number (got '$free')" ;;
  *) ok "seed_free_gb reports the free space as a whole number of GiB ($free)" ;;
esac
min="$(seed_min_free_gb)"
if [ "$min" = "400" ]; then
  ok "the free space gate defaults to 400 GiB"
else
  bad "the free space gate default is '$min', expected 400"
fi

# --- 7. the library must not touch the network ------------------------------
net_hits="$(grep -nE 'curl[[:space:]]|requests|urllib\.request\.urlopen|wget[[:space:]]|http\.client' \
  "$LIB_DIR/seed_archive.sh" || true)"
if [ -z "$net_hits" ]; then
  ok "seed_archive.sh contains no network invocation"
else
  bad "seed_archive.sh contains a network invocation: $net_hits"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo "SEED_TESTS_FAILED"
  exit 1
fi
echo "SEED_TESTS_OK"
exit 0
