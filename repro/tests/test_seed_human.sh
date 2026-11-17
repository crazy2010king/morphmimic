#!/usr/bin/env bash
# repro/tests/test_seed_human.sh — offline NEGATIVE-fixture battery for the
# human50 sidecar checker of slice S05:
#
#   * repro/16_seed_human_verify.sh  — the read-only independent re-checker
#   * repro/15_seed_human.sh         — the fail-closed conversion wrapper
#   * repro/tests/test_seed_human.py — the library-level unit tests
#
# The battery is built on synthetic fixtures ONLY: a fake npz root, a fake
# sidecar root, a fake `subsets/1h.yaml`, a fake upstream
# `check_human_1h.csv` and fake BVH headers, all created in a `mktemp -d`
# directory that is removed on exit.  The real payload (`data/`), the real
# logs (`logs/`), `.gsd/` and any other ignored path are NEVER read; no
# network access, no GPU, no container required.
#
# The fake `.npz` files are written with `zipfile` + hand-written `.npy`
# headers, so the battery needs NO numpy (the container's system python3 has
# none) — the checker runs with `SEED_HUMAN_PY=python3`.
#
# WHY THE NEGATIVE CASES MATTER
#   A checker that can only say "OK" is worse than no checker at all.  Every
#   negative scenario therefore asserts BOTH:
#     (1) a non-zero exit code, AND
#     (2) the ABSENCE of the `SEED_HUMAN_VERIFY_OK` marker in the output
#         (the S03/S04/S05 "no OK marker on a failing path" convention).
#
# Covered:
#   1. the fixture is created
#   2. POSITIVE: a complete and consistent tree -> rc=0 + the OK marker
#   3. NEGATIVE: one sidecar missing        -> rc!=0, no OK marker
#   4. NEGATIVE: one sidecar one frame short-> rc!=0, no OK marker
#   5. NEGATIVE: one extra sidecar          -> rc!=0, no OK marker
#   6. SEMANTICS: a feet_min_z out of range does NOT change the exit code
#      (upstream `check_human` only REPORTS the feet z)
#   7. SEMANTICS: a missing upstream CSV leaves feet_off empty, rc stays 0
#   8. TRAP: the BVH header `Frame Time: 0.008333` derives a DIFFERENT frame
#      count than the real one (the header must never be used to validate)
#   9. SOURCE LEVEL: repro/15_seed_human.sh passes `--subset-yaml` (without
#      it upstream feeds on its own sidecars), parses AND asserts the
#      upstream `failed` count (upstream exits 0 even when clips failed) and
#      emits the CONVERT_OK / CHECK_OK markers
#  10. the library-level unit tests (repro/tests/test_seed_human.py) are green
#
# Run locally:   bash repro/tests/test_seed_human.sh
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
VERIFY_SH="$REPO_ROOT/repro/16_seed_human_verify.sh"
CONVERT_SH="$REPO_ROOT/repro/15_seed_human.sh"
PY_LIB="$LIB_DIR/seed_human.py"
PY_TEST="$REPO_ROOT/repro/tests/test_seed_human.py"

PASS=0
FAIL=0
SKIP=0
python_bin="${SEED_HUMAN_PY:-python3}"

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

NPZ_ROOT="$TMP/npz"
HUMAN_ROOT="$NPZ_ROOT/human50"
BVH_ROOT="$TMP/bvh"
SUBSET_YAML="$NPZ_ROOT/subsets/1h.yaml"
LOG_DIR_REAL="$TMP/logs"
CHECK_CSV="$LOG_DIR_REAL/check_human_1h.csv"

# The fixture's frame counts follow the upstream resampling: a 121-frame
# SOMA BVH at 120 Hz becomes 51 frames at 50 Hz.  The TRUNCATED BVH header
# value (0.008333) derives 50 — one frame short.  That is the trap the
# decision path must avoid.
SOURCE_FRAMES=121
REAL_FRAMES=51
export SEED_HUMAN_REAL_FRAMES="$REAL_FRAMES"

# ============================================================================
# 0. the fixture builder (stdlib only) + the fixture itself
# ============================================================================
cat >"$TMP/make_fixture.py" <<'PYFIXTURE'
import os
import sys
import zipfile


def npy_bytes(shape, descr="<f4"):
  header = "{'descr': '%s', 'fortran_order': False, 'shape': (%s), }" % (
    descr, ", ".join(str(int(d)) for d in shape))
  prefix = 6 + 2 + 2
  pad = 64 - ((prefix + len(header) + 1) % 64)
  if pad == 64:
    pad = 0
  header = header + " " * pad + "\n"
  count = 1
  for dim in shape:
    count *= int(dim)
  body = b"\x00" * (count * 4)
  return b"\x93NUMPY" + bytes([1, 0]) + len(header).to_bytes(2, "little") + header.encode("latin1") + body


def write_npz(path, arrays):
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
    for name, shape in arrays.items():
      archive.writestr(name + ".npy", npy_bytes(shape))


def write_bvh(path, frames, frame_time):
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with open(path, "w", encoding="utf-8") as handle:
    handle.write("HIERARCHY\n")
    handle.write("MOTION\n")
    handle.write("Frames: %d\n" % frames)
    handle.write("Frame Time: %s\n" % frame_time)


def main():
  npz_root, human_root, bvh_root, yaml_path = sys.argv[1:5]
  source_frames = int(sys.argv[5])
  real_frames = int(sys.argv[6])
  clips = (("220713", "clip_a"), ("230301", "clip_b"))
  rel_paths = []
  for session, stem in clips:
    rel = "%s/%s.npz" % (session, stem)
    rel_paths.append(rel)
    write_npz(os.path.join(npz_root, rel), {"joint_pos": (real_frames, 29, 3)})
    write_npz(os.path.join(human_root, rel), {"human_pos_w": (real_frames, 24, 3)})
    write_bvh(os.path.join(bvh_root, "%s/%s.bvh" % (session, stem)),
              source_frames, "0.008333")
  os.makedirs(os.path.dirname(yaml_path), exist_ok=True)
  with open(yaml_path, "w", encoding="utf-8") as handle:
    handle.write("root: %s\n" % npz_root)
    handle.write("hours: 0.5000000000\n")
    handle.write("clips:\n")
    for rel in rel_paths:
      handle.write("- %s\n" % rel)


if __name__ == "__main__":
  main()
PYFIXTURE

write_check_csv() {
  # The upstream `check_human --out` table (pandas to_csv layout).
  local out="$1"
  local feet_a="$2"
  local feet_b="$3"
  mkdir -p "$(dirname "$out")"
  {
    printf 'name,robot_frames,human_frames,frames_match,feet_min_z,height_ratio,pelvis_xy_rms_m,sidecar\n'
    printf 'clip_a,51,51,True,%s,1.0,0.0,True\n' "$feet_a"
    printf 'clip_b,51,51,True,%s,1.0,0.0,True\n' "$feet_b"
  } >"$out"
}

build_fixture() {
  rm -rf "$NPZ_ROOT" "$BVH_ROOT" "$LOG_DIR_REAL"
  "$python_bin" "$TMP/make_fixture.py" "$NPZ_ROOT" "$HUMAN_ROOT" "$BVH_ROOT" \
    "$SUBSET_YAML" "$SOURCE_FRAMES" "$REAL_FRAMES" || return 1
  mkdir -p "$LOG_DIR_REAL"
  write_check_csv "$CHECK_CSV" "0.0" "0.0"
  return 0
}

# run_verify — run the read-only checker against the fixture; the output
# lands in $OUT and the exit code in $RC.
run_verify() {
  OUT="$(SEED_HUMAN_ALLOW_LOCAL=1 \
    SEED_HUMAN_PY="$python_bin" \
    SEED_HUMAN_NPZ_ROOT="$NPZ_ROOT" \
    SEED_HUMAN_SUBSET="$SUBSET_YAML" \
    SEED_HUMAN_HUMAN_ROOT="$HUMAN_ROOT" \
    SEED_HUMAN_LOG_DIR="$LOG_DIR_REAL" \
    SEED_HUMAN_CHECK_CSV="$CHECK_CSV" \
    SEED_HUMAN_EXPECT_CLIPS=2 \
    SEED_HUMAN_PROBE_TIMEOUT=120 \
    bash "$VERIFY_SH" verify 2>&1)"
  RC=$?
  return 0
}

if ! build_fixture; then
  bad "the fixture builder failed"
  exit 1
fi

if [ -f "$NPZ_ROOT/220713/clip_a.npz" ] && [ -f "$HUMAN_ROOT/220713/clip_a.npz" ] \
   && [ -f "$SUBSET_YAML" ] && [ -f "$BVH_ROOT/220713/clip_a.bvh" ] \
   && [ -f "$CHECK_CSV" ]; then
  ok "the offline fixture was created"
else
  bad "the offline fixture is incomplete"
fi

# ============================================================================
# 2. POSITIVE: a complete and consistent tree -> rc=0 + the OK marker
# ============================================================================
run_verify
if [ "$RC" -eq 0 ]; then
  ok "the positive case exits 0"
else
  bad "the positive case exited $RC: $OUT"
fi
case "$OUT" in
  *"SEED_HUMAN_VERIFY_OK"*) ok "the positive case emits SEED_HUMAN_VERIFY_OK" ;;
  *) bad "the positive case does not emit SEED_HUMAN_VERIFY_OK: $OUT" ;;
esac
case "$OUT" in
  *"missing=0"*) ok "the positive case reports missing=0" ;;
  *) bad "the positive case does not report missing=0: $OUT" ;;
esac
case "$OUT" in
  *"extra=0"*) ok "the positive case reports extra=0" ;;
  *) bad "the positive case does not report extra=0: $OUT" ;;
esac
case "$OUT" in
  *"frames_match=2"*) ok "the positive case reports frames_match=2" ;;
  *) bad "the positive case does not report frames_match=2: $OUT" ;;
esac

REPORT_OUT="$(SEED_HUMAN_ALLOW_LOCAL=1 \
  SEED_HUMAN_PY="$python_bin" \
  SEED_HUMAN_NPZ_ROOT="$NPZ_ROOT" \
  SEED_HUMAN_SUBSET="$SUBSET_YAML" \
  SEED_HUMAN_HUMAN_ROOT="$HUMAN_ROOT" \
  SEED_HUMAN_LOG_DIR="$LOG_DIR_REAL" \
  SEED_HUMAN_CHECK_CSV="$CHECK_CSV" \
  SEED_HUMAN_EXPECT_CLIPS=2 \
  SEED_HUMAN_PROBE_TIMEOUT=120 \
  bash "$VERIFY_SH" report 2>&1)"
REPORT_RC=$?
if [ "$REPORT_RC" -eq 0 ]; then
  ok "the report subcommand exits 0"
else
  bad "the report subcommand exited $REPORT_RC: $REPORT_OUT"
fi
case "$REPORT_OUT" in
  *"SEED_REPORT_HUMAN_OK=1"*) ok "the report prints SEED_REPORT_HUMAN_OK=1" ;;
  *) bad "the report does not print SEED_REPORT_HUMAN_OK=1: $REPORT_OUT" ;;
esac

# ============================================================================
# 3. NEGATIVE: one sidecar missing
# ============================================================================
mv "$HUMAN_ROOT/230301/clip_b.npz" "$TMP/clip_b.npz.bak"
run_verify
if [ "$RC" -ne 0 ]; then
  ok "a missing sidecar makes the checker exit non-zero"
else
  bad "a missing sidecar did not make the checker fail: $OUT"
fi
case "$OUT" in
  *"SEED_HUMAN_VERIFY_OK"*)
    bad "a missing sidecar still emitted the OK marker: $OUT" ;;
  *)
    ok "a missing sidecar emits no OK marker" ;;
esac
case "$OUT" in
  *"reason=sidecar-missing"*) ok "a missing sidecar is reported as sidecar-missing" ;;
  *) bad "a missing sidecar has the wrong reason: $OUT" ;;
esac
mv "$TMP/clip_b.npz.bak" "$HUMAN_ROOT/230301/clip_b.npz"

# ============================================================================
# 4. NEGATIVE: one sidecar one frame short
# ============================================================================
"$python_bin" - "$HUMAN_ROOT/230301/clip_b.npz" <<'PYSHRINK'
import sys
import zipfile

path = sys.argv[1]
header = "{'descr': '<f4', 'fortran_order': False, 'shape': (50, 24, 3), }"
prefix = 6 + 2 + 2
pad = 64 - ((prefix + len(header) + 1) % 64)
if pad == 64:
  pad = 0
header = header + " " * pad + "\n"
body = b"\x00" * (50 * 24 * 3 * 4)
blob = b"\x93NUMPY" + bytes([1, 0]) + len(header).to_bytes(2, "little") + header.encode("latin1") + body
with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
  archive.writestr("human_pos_w.npy", blob)
PYSHRINK
run_verify
if [ "$RC" -ne 0 ]; then
  ok "a short sidecar makes the checker exit non-zero"
else
  bad "a short sidecar did not make the checker fail: $OUT"
fi
case "$OUT" in
  *"SEED_HUMAN_VERIFY_OK"*)
    bad "a short sidecar still emitted the OK marker: $OUT" ;;
  *)
    ok "a short sidecar emits no OK marker" ;;
esac
case "$OUT" in
  *"reason=frames-mismatch"*) ok "a short sidecar is reported as frames-mismatch" ;;
  *) bad "a short sidecar has the wrong reason: $OUT" ;;
esac
build_fixture

# ============================================================================
# 5. NEGATIVE: one extra sidecar
# ============================================================================
cp "$HUMAN_ROOT/230301/clip_b.npz" "$HUMAN_ROOT/220713/clip_extra.npz"
run_verify
if [ "$RC" -ne 0 ]; then
  ok "an extra sidecar makes the checker exit non-zero"
else
  bad "an extra sidecar did not make the checker fail: $OUT"
fi
case "$OUT" in
  *"SEED_HUMAN_VERIFY_OK"*)
    bad "an extra sidecar still emitted the OK marker: $OUT" ;;
  *)
    ok "an extra sidecar emits no OK marker" ;;
esac
case "$OUT" in
  *"reason=sidecar-extra"*) ok "an extra sidecar is reported as sidecar-extra" ;;
  *) bad "an extra sidecar has the wrong reason: $OUT" ;;
esac
rm -f "$HUMAN_ROOT/220713/clip_extra.npz"

# ============================================================================
# 6. SEMANTICS: the feet z is REPORTED, never judged
# ============================================================================
# clip_a's feet leave [-0.05, 0.10] m -> feet_off=1, but the exit code and
# the OK marker must stay untouched (upstream `check_human` only counts it).
write_check_csv "$CHECK_CSV" "-0.09" "0.0"
run_verify
if [ "$RC" -eq 0 ]; then
  ok "a feet_min_z out of range does NOT change the exit code"
else
  bad "a feet_min_z out of range changed the exit code ($RC): $OUT"
fi
case "$OUT" in
  *"SEED_HUMAN_VERIFY_OK"*) ok "a feet_min_z out of range keeps the OK marker" ;;
  *) bad "a feet_min_z out of range removed the OK marker: $OUT" ;;
esac
case "$OUT" in
  *"feet_off=1"*) ok "a feet_min_z out of range is reported as feet_off=1" ;;
  *) bad "a feet_min_z out of range is not reported as feet_off=1: $OUT" ;;
esac

# ============================================================================
# 7. SEMANTICS: a missing upstream CSV leaves feet_off empty, rc stays 0
# ============================================================================
rm -f "$CHECK_CSV"
run_verify
if [ "$RC" -eq 0 ]; then
  ok "a missing upstream CSV does NOT change the exit code"
else
  bad "a missing upstream CSV changed the exit code ($RC): $OUT"
fi
case "$OUT" in
  *"SEED_HUMAN_VERIFY_OK"*) ok "a missing upstream CSV keeps the OK marker" ;;
  *) bad "a missing upstream CSV removed the OK marker: $OUT" ;;
esac
case "$OUT" in
  *"feet_off="*) ok "a missing upstream CSV leaves the feet_off field empty" ;;
  *) bad "a missing upstream CSV removed the feet_off field: $OUT" ;;
esac
write_check_csv "$CHECK_CSV" "0.0" "0.0"

# ============================================================================
# 8. TRAP: the BVH header derives a DIFFERENT frame count
# ============================================================================
TRAP_OUT="$("$python_bin" - "$PY_LIB" "$BVH_ROOT/220713/clip_a.bvh" "$SOURCE_FRAMES" <<'PYTRAP'
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
import seed_human

bvh = sys.argv[2]
source_frames = int(sys.argv[3])
frame_time = seed_human.bvh_header_frame_time(bvh)
trapped = seed_human.frames_from_bvh_header(source_frames, frame_time, 50)
exact = seed_human.frames_from_bvh_header(source_frames, 1.0 / 120.0, 50)
print("frame_time=%.6f" % frame_time)
print("trapped=%d" % trapped)
print("exact=%d" % exact)
print("real=%d" % int(os.environ.get("SEED_HUMAN_REAL_FRAMES", "-1")))
print("differs=%d" % int(trapped != int(os.environ.get("SEED_HUMAN_REAL_FRAMES", "-1"))))
PYTRAP
)"
case "$TRAP_OUT" in
  *"frame_time=0.008333"*) ok "the BVH header frame time is read as 0.008333" ;;
  *) bad "the BVH header frame time was not read: $TRAP_OUT" ;;
esac
case "$TRAP_OUT" in
  *"trapped=50"*) ok "the truncated BVH header derives 50 frames" ;;
  *) bad "the truncated BVH header did not derive 50 frames: $TRAP_OUT" ;;
esac
case "$TRAP_OUT" in
  *"exact=51"*) ok "the exact 1/120 rate derives the true frame count (51)" ;;
  *) bad "the exact rate did not derive 51 frames: $TRAP_OUT" ;;
esac
case "$TRAP_OUT" in
  *"differs=1"*) ok "the BVH-header frame count differs from the real one" ;;
  *) bad "the BVH-header trap did not reproduce: $TRAP_OUT" ;;
esac

# ============================================================================
# 9. SOURCE LEVEL: the conversion wrapper's upstream traps are handled
# ============================================================================
if [ ! -f "$CONVERT_SH" ]; then
  bad "the conversion wrapper is missing: $CONVERT_SH"
else
  if grep -q -- '--subset-yaml' "$CONVERT_SH"; then
    ok "the conversion wrapper passes --subset-yaml (no self-feeding)"
  else
    bad "the conversion wrapper does not pass --subset-yaml"
  fi
  if grep -qE "converted \[0-9\]\+, skipped \[0-9\]\+, failed \[0-9\]\+" "$CONVERT_SH"; then
    ok "the conversion wrapper parses the upstream converted/skipped/failed summary"
  else
    bad "the conversion wrapper does not parse the upstream summary line"
  fi
  if grep -qE '\[ "\$failed" != "0" \]' "$CONVERT_SH"; then
    ok "the conversion wrapper ASSERTS the upstream failed count (upstream exits 0 anyway)"
  else
    bad "the conversion wrapper does not assert the upstream failed count"
  fi
  if grep -q 'SEED_HUMAN_CONVERT_OK' "$CONVERT_SH"; then
    ok "the conversion wrapper emits SEED_HUMAN_CONVERT_OK"
  else
    bad "the conversion wrapper does not emit SEED_HUMAN_CONVERT_OK"
  fi
  if grep -q 'SEED_HUMAN_CHECK_OK' "$CONVERT_SH"; then
    ok "the conversion wrapper emits SEED_HUMAN_CHECK_OK"
  else
    bad "the conversion wrapper does not emit SEED_HUMAN_CHECK_OK"
  fi
  if grep -q 'SEED_HUMAN_PY' "$VERIFY_SH"; then
    ok "the checker exposes the SEED_HUMAN_PY interpreter override"
  else
    bad "the checker does not expose the SEED_HUMAN_PY interpreter override"
  fi
fi

# ============================================================================
# 10. the library-level unit tests are green
# ============================================================================
if [ ! -f "$PY_TEST" ]; then
  bad "the library-level unit test file is missing: $PY_TEST"
else
  UNIT_OUT="$("$python_bin" "$PY_TEST" 2>&1)"
  UNIT_RC=$?
  if [ "$UNIT_RC" -eq 0 ]; then
    ok "the library-level unit tests are green"
  else
    bad "the library-level unit tests failed (rc=$UNIT_RC): $UNIT_OUT"
  fi
  case "$UNIT_OUT" in
    *"OK"*) ok "the library-level unit tests report OK" ;;
    *) bad "the library-level unit tests do not report OK: $UNIT_OUT" ;;
  esac
  if grep -qE '^[[:space:]]*(import|from)[[:space:]]+(numpy|pandas|scipy|torch|yaml)\b' "$PY_TEST"; then
    bad "the library-level unit test file must only use the standard library"
  else
    ok "the library-level unit test file imports only the standard library"
  fi
fi

# ============================================================================
# summary
# ============================================================================
printf '\n== test_seed_human.sh: PASS=%d FAIL=%d SKIP=%d ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "ERROR: $SKIP test(s) were skipped — a SKIP must never mask a failure." >&2
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
