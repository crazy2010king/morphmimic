#!/usr/bin/env bash
# repro/tests/test_seed_human_lib.sh — offline fixture battery for the
# human50 sidecar decision base of slice S05:
#
#   * repro/lib/seed_human.py  — the stdlib-only decision functions
#   * repro/lib/seed_human.sh  — the thin shell wrapper
#
# No network, no GPU, no 150 GB payload: every fixture is synthetic and lives
# in a temp dir that is removed on exit.  The fake npz files are written with
# `zipfile` + hand-written `.npy` headers, so the battery needs NO numpy (the
# container's system python3 has none).
#
# The battery covers:
#
#   1. the library files exist, source cleanly and import only the stdlib
#   2. the CLI prints the subset spec (root / hours / clips)
#   3. POSITIVE: the sidecar set equals the subset -> missing=0, extra=0
#   4. POSITIVE: every sidecar has the robot clip's frame count
#   5. NEGATIVE: one sidecar missing -> missing=1
#   6. NEGATIVE: one extra sidecar -> extra=1
#   7. NEGATIVE: one sidecar one frame short -> frames_match drops
#   8. TRAP: the BVH header `Frame Time: 0.008333` implies a DIFFERENT frame
#      count than the real one (the header must never be used to validate)
#   9. the decision path never calls the BVH-header helpers (static AST check)
#  10. the module works with numpy made un-importable
#
# Run locally:   bash repro/tests/test_seed_human_lib.sh
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SH_LIB="$LIB_DIR/seed_human.sh"
PY_LIB="$LIB_DIR/seed_human.py"

PASS=0
FAIL=0
SKIP=0
python_bin="${SEED_HUMAN_PY:-${SEED_HUMAN_PYTHON:-python3}}"

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NPZ_ROOT="$TMP/npz"
HUMAN_ROOT="$NPZ_ROOT/human50"
BVH_ROOT="$TMP/bvh"
SUBSET_YAML="$TMP/subsets/1h.yaml"

# ============================================================================
# 0. the fixture builder (stdlib only)
# ============================================================================
# Two clips: clip_a has 121 frames ((121-1) % 12 == 0 -> the BVH-header trap
# bites), clip_b has 100 frames (the trap does not bite).
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


def write_bvh(path, frame_time):
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with open(path, "w", encoding="utf-8") as handle:
    handle.write("HIERARCHY\n")
    handle.write("MOTION\n")
    handle.write("Frames: 2\n")
    handle.write("Frame Time: %s\n" % frame_time)


def main():
  npz_root, human_root, bvh_root, yaml_path = sys.argv[1:5]
  clips = (("clip_a", 121), ("clip_b", 100))
  rel_paths = []
  for stem, frames in clips:
    rel = "220713/%s.npz" % stem
    rel_paths.append(rel)
    write_npz(os.path.join(npz_root, rel), {"joint_pos": (frames, 29, 3)})
    write_npz(os.path.join(human_root, rel), {"human_pos_w": (frames, 24, 3)})
    write_bvh(os.path.join(bvh_root, "220713/%s.bvh" % stem), "0.008333")
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

if ! "$python_bin" "$TMP/make_fixture.py" "$NPZ_ROOT" "$HUMAN_ROOT" "$BVH_ROOT" "$SUBSET_YAML"; then
  bad "the fixture builder failed"
  exit 1
fi

if [ -f "$NPZ_ROOT/220713/clip_a.npz" ] && [ -f "$HUMAN_ROOT/220713/clip_a.npz" ] \
   && [ -f "$SUBSET_YAML" ] && [ -f "$BVH_ROOT/220713/clip_a.bvh" ]; then
  ok "the offline fixture was created"
else
  bad "the offline fixture is incomplete"
fi

# ============================================================================
# 1. the library files exist, source cleanly and are stdlib-only
# ============================================================================
if [ ! -f "$PY_LIB" ]; then
  bad "python library missing: $PY_LIB"
else
  if grep -qE '^[[:space:]]*(import|from)[[:space:]]+(numpy|pandas|scipy|yaml|mujoco|torch)\b' "$PY_LIB"; then
    bad "the python library must only use the standard library"
  else
    ok "the python library imports only the standard library"
  fi
  if "$python_bin" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PY_LIB"; then
    ok "the python library parses"
  else
    bad "the python library does not parse"
  fi
fi

if [ ! -f "$SH_LIB" ]; then
  bad "shell wrapper missing: $SH_LIB"
else
  if bash -n "$SH_LIB"; then
    ok "the shell wrapper parses"
  else
    bad "the shell wrapper does not parse"
  fi
  # shellcheck source=../lib/seed_human.sh
  if source "$SH_LIB"; then
    ok "the shell wrapper sources cleanly"
  else
    bad "the shell wrapper failed to source"
  fi
  MISSING=""
  for fn in seed_human_python seed_human_run; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
      MISSING="$MISSING $fn"
    fi
  done
  if [ -z "$MISSING" ]; then
    ok "every documented wrapper function is defined"
  else
    bad "missing wrapper functions:$MISSING"
  fi
fi

# ============================================================================
# 2. the CLI prints the subset spec
# ============================================================================
SUBSET_OUT="$("$python_bin" "$PY_LIB" subset "$SUBSET_YAML" 2>&1)"
SUBSET_RC=$?
if [ "$SUBSET_RC" -eq 0 ]; then
  ok "the subset command exits 0"
else
  bad "the subset command exited $SUBSET_RC: $SUBSET_OUT"
fi
case "$SUBSET_OUT" in
  *"clips=2"*) ok "the subset command prints clips=2" ;;
  *) bad "the subset command did not print clips=2: $SUBSET_OUT" ;;
esac
case "$SUBSET_OUT" in
  *"hours=0.5000000000"*) ok "the subset command prints the hours" ;;
  *) bad "the subset command did not print the hours: $SUBSET_OUT" ;;
esac

# the shell wrapper must forward to the same module
WRAP_OUT="$(bash "$SH_LIB" subset "$SUBSET_YAML" 2>&1)"
if [ "$WRAP_OUT" = "$SUBSET_OUT" ]; then
  ok "the shell wrapper and the python CLI agree"
else
  bad "the shell wrapper and the python CLI disagree"
  printf '      shell : %s\n' "$(printf '%s' "$WRAP_OUT" | tr '\n' ' ')"
  printf '      python: %s\n' "$(printf '%s' "$SUBSET_OUT" | tr '\n' ' ')"
fi

# ============================================================================
# 3. POSITIVE: the sidecar set equals the subset
# ============================================================================
DIFF_OUT="$("$python_bin" "$PY_LIB" diff --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" 2>&1)"
DIFF_RC=$?
if [ "$DIFF_RC" -eq 0 ]; then
  ok "the diff command exits 0"
else
  bad "the diff command exited $DIFF_RC: $DIFF_OUT"
fi
case "$DIFF_OUT" in
  *"missing=0"*) ok "the sidecar set is complete (missing=0)" ;;
  *) bad "the sidecar set is not complete: $DIFF_OUT" ;;
esac
case "$DIFF_OUT" in
  *"extra=0"*) ok "there is no extra sidecar (extra=0)" ;;
  *) bad "there is an extra sidecar: $DIFF_OUT" ;;
esac
case "$DIFF_OUT" in
  *"sidecars=2"*) ok "the sidecar count is 2" ;;
  *) bad "the sidecar count is not 2: $DIFF_OUT" ;;
esac

# ============================================================================
# 4. POSITIVE: every sidecar has the robot clip's frame count
# ============================================================================
FRAMES_OUT="$("$python_bin" "$PY_LIB" frames --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" 2>&1)"
FRAMES_RC=$?
if [ "$FRAMES_RC" -eq 0 ]; then
  ok "the frames command exits 0"
else
  bad "the frames command exited $FRAMES_RC: $FRAMES_OUT"
fi
case "$FRAMES_OUT" in
  *"frames_match=2"*) ok "both sidecars match the robot frame count" ;;
  *) bad "the frame counts do not match: $FRAMES_OUT" ;;
esac
case "$FRAMES_OUT" in
  *"mismatch=0"*) ok "there is no frame mismatch" ;;
  *) bad "there is a frame mismatch: $FRAMES_OUT" ;;
esac

# ============================================================================
# 5. NEGATIVE: one sidecar missing
# ============================================================================
mv "$HUMAN_ROOT/220713/clip_b.npz" "$TMP/clip_b.npz.bak"
DIFF_MISS="$("$python_bin" "$PY_LIB" diff --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" 2>&1)"
case "$DIFF_MISS" in
  *"missing=1"*) ok "a missing sidecar is detected (missing=1)" ;;
  *) bad "a missing sidecar was not detected: $DIFF_MISS" ;;
esac
case "$DIFF_MISS" in
  *"missing_clip=220713/clip_b.npz"*) ok "the missing sidecar is named" ;;
  *) bad "the missing sidecar is not named: $DIFF_MISS" ;;
esac
mv "$TMP/clip_b.npz.bak" "$HUMAN_ROOT/220713/clip_b.npz"

# ============================================================================
# 6. NEGATIVE: one extra sidecar
# ============================================================================
cp "$HUMAN_ROOT/220713/clip_b.npz" "$HUMAN_ROOT/220713/clip_extra.npz"
DIFF_EXTRA="$("$python_bin" "$PY_LIB" diff --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" 2>&1)"
case "$DIFF_EXTRA" in
  *"extra=1"*) ok "an extra sidecar is detected (extra=1)" ;;
  *) bad "an extra sidecar was not detected: $DIFF_EXTRA" ;;
esac
case "$DIFF_EXTRA" in
  *"extra_clip=220713/clip_extra.npz"*) ok "the extra sidecar is named" ;;
  *) bad "the extra sidecar is not named: $DIFF_EXTRA" ;;
esac
rm -f "$HUMAN_ROOT/220713/clip_extra.npz"

# ============================================================================
# 7. NEGATIVE: one sidecar one frame short
# ============================================================================
# rewrite clip_b's sidecar with 99 frames instead of 100
"$python_bin" - "$HUMAN_ROOT/220713/clip_b.npz" <<'PYSHRINK'
import sys
import zipfile

path = sys.argv[1]
header = "{'descr': '<f4', 'fortran_order': False, 'shape': (99, 24, 3), }"
prefix = 6 + 2 + 2
pad = 64 - ((prefix + len(header) + 1) % 64)
if pad == 64:
  pad = 0
header = header + " " * pad + "\n"
body = b"\x00" * (99 * 24 * 3 * 4)
blob = b"\x93NUMPY" + bytes([1, 0]) + len(header).to_bytes(2, "little") + header.encode("latin1") + body
with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
  archive.writestr("human_pos_w.npy", blob)
PYSHRINK
FRAMES_SHORT="$("$python_bin" "$PY_LIB" frames --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" 2>&1)"
case "$FRAMES_SHORT" in
  *"frames_match=1"*) ok "a short sidecar is not counted as a match" ;;
  *) bad "a short sidecar was counted as a match: $FRAMES_SHORT" ;;
esac
case "$FRAMES_SHORT" in
  *"mismatch=1"*) ok "a short sidecar is reported as a mismatch" ;;
  *) bad "a short sidecar was not reported as a mismatch: $FRAMES_SHORT" ;;
esac
case "$FRAMES_SHORT" in
  *"robot=100 human=99"*) ok "the mismatch reports both frame counts" ;;
  *) bad "the mismatch does not report both frame counts: $FRAMES_SHORT" ;;
esac
# restore the fixture
"$python_bin" "$TMP/make_fixture.py" "$NPZ_ROOT" "$HUMAN_ROOT" "$BVH_ROOT" "$SUBSET_YAML" >/dev/null 2>&1

# ============================================================================
# 8. TRAP: the BVH header implies a different frame count
# ============================================================================
TRAP_OUT="$("$python_bin" - "$PY_LIB" "$BVH_ROOT/220713/clip_a.bvh" <<'PYTRAP'
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
import seed_human

bvh = sys.argv[2]
frame_time = seed_human.bvh_header_frame_time(bvh)
# 121 source frames at 120 Hz -> 51 frames at 50 Hz with the exact rate,
# but only 50 with the truncated header value: one frame LOST.
trapped = seed_human.frames_from_bvh_header(121, frame_time, 50)
exact = seed_human.frames_from_bvh_header(121, 1.0 / 120.0, 50)
print("frame_time=%.6f" % frame_time)
print("trapped=%d" % trapped)
print("exact=%d" % exact)
print("differs=%d" % int(trapped != exact))
PYTRAP
)"
case "$TRAP_OUT" in
  *"frame_time=0.008333"*) ok "the BVH header frame time is read as 0.008333" ;;
  *) bad "the BVH header frame time was not read: $TRAP_OUT" ;;
esac
case "$TRAP_OUT" in
  *"differs=1"*) ok "the BVH header implies a DIFFERENT frame count than the real one" ;;
  *) bad "the BVH header trap did not reproduce: $TRAP_OUT" ;;
esac
case "$TRAP_OUT" in
  *"trapped=50"*) ok "the truncated header loses one frame (51 -> 50)" ;;
  *) bad "the truncated header did not lose frames: $TRAP_OUT" ;;
esac
case "$TRAP_OUT" in
  *"exact=51"*) ok "the exact 1/120 rate yields the true frame count (51)" ;;
  *) bad "the exact rate did not yield 51 frames: $TRAP_OUT" ;;
esac

# ============================================================================
# 9. the decision path never uses the BVH header (static AST check)
# ============================================================================
AST_OUT="$("$python_bin" - "$PY_LIB" <<'PYAST'
import ast
import sys

source = open(sys.argv[1], "r", encoding="utf-8").read()
tree = ast.parse(source)
trap_functions = {"bvh_header_frame_time", "frames_from_bvh_header"}
callers = {}
for node in ast.walk(tree):
  if isinstance(node, ast.FunctionDef):
    for inner in ast.walk(node):
      if isinstance(inner, ast.Call) and isinstance(inner.func, ast.Name):
        if inner.func.id in trap_functions:
          callers.setdefault(inner.func.id, set()).add(node.name)
report = []
for name in sorted(trap_functions):
  users = sorted(callers.get(name, set()))
  report.append("%s=%s" % (name, ",".join(users) if users else "none"))
print(" ".join(report))
PYAST
)"
case "$AST_OUT" in
  *"bvh_header_frame_time=none"*) ok "bvh_header_frame_time is called by nobody" ;;
  *) bad "bvh_header_frame_time is called somewhere: $AST_OUT" ;;
esac
case "$AST_OUT" in
  *"frames_from_bvh_header=none"*) ok "frames_from_bvh_header is called by nobody" ;;
  *) bad "frames_from_bvh_header is called somewhere: $AST_OUT" ;;
esac

# ============================================================================
# 10. the module works with numpy made un-importable
# ============================================================================
BLOCK_DIR="$TMP/no-numpy"
mkdir -p "$BLOCK_DIR"
cat >"$BLOCK_DIR/numpy.py" <<'PYNUMPY'
raise ImportError("numpy is not available in this environment")
PYNUMPY
BLOCK_OUT="$(PYTHONPATH="$BLOCK_DIR" "$python_bin" "$PY_LIB" frames --root "$NPZ_ROOT" --yaml "$SUBSET_YAML" 2>&1)"
BLOCK_RC=$?
if [ "$BLOCK_RC" -eq 0 ]; then
  ok "the library runs with numpy un-importable"
else
  bad "the library needs numpy (rc=$BLOCK_RC): $BLOCK_OUT"
fi
case "$BLOCK_OUT" in
  *"frames_match=2"*) ok "the numpy-free run still compares the frames" ;;
  *) bad "the numpy-free run did not compare the frames: $BLOCK_OUT" ;;
esac

# ============================================================================
# summary
# ============================================================================
printf '\n== test_seed_human_lib.sh: PASS=%d FAIL=%d SKIP=%d ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "ERROR: $SKIP test(s) were skipped — a SKIP must never mask a failure." >&2
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
