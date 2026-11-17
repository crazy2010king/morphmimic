#!/usr/bin/env bash
# repro/tests/test_seed_npz_verify.sh — offline fixture battery for the
# read-only terminal reviewer (repro/14_seed_npz_verify.sh).
#
# The reviewer is the LAST gate of slice S04: it decides whether the 50 Hz npz
# library is trustworthy.  A reviewer that reports OK on a broken library is
# worse than no reviewer at all, so every negative case asserts BOTH
#   (1) a non-zero exit code, and
#   (2) the ABSENCE of the SEED_NPZ_VERIFY_OK marker in the output
#       (the reviewer buffers its OK marker, so a failing run can never emit
#        one — the S03/MEM038 convention).
#
# The fixtures are built ON THE SPOT in a temporary directory: a 10-row
# manifest, five nested subset yamls and ten minimal npz files (fps=50).  No
# network, no real payload, no repository data.  Everything is removed on
# exit.
#
# WHY THE FIXTURE ALSO PLANTS A human50/ SIDECAR (slice S05):
#   `<npz root>/human50/` holds the SMPL human50 sidecars (one .npz per clip),
#   NOT robot npz clips.  The audit subcommand must PRUNE that directory, so
#   the "npz file count == manifest rows" evidence of slice S04 stays intact
#   (142,220 robot npz, not 142,710 with the 490 sidecars).  The fixture
#   plants a sidecar whose byte size differs from the robot npz files, so the
#   byte total is checked too — a count-only prune would still be a bug.
#
# usage: bash repro/tests/test_seed_npz_verify.sh

set -uo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_TEST_DIR/../.." && pwd)"
VERIFY_SH="$_REPO_ROOT/repro/14_seed_npz_verify.sh"

PASS=0
FAIL=0

# The python that can import numpy (needed to write the minimal npz files).
# The project venv comes first (the container's system python3 has no numpy),
# a plain python3 with numpy is the fallback (the offline local run).
NP_PY_ARGS=(python3)
if command -v uv >/dev/null 2>&1 && [ -x "$_REPO_ROOT/.venv/bin/python" ]; then
  if uv run --frozen --no-sync python -c 'import numpy' >/dev/null 2>&1; then
    NP_PY_ARGS=(uv run --frozen --no-sync python)
  fi
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export SEED_NPZ_ALLOW_LOCAL=1     # the fixtures run outside the container
export SEED_NPZ_LOG_DIR="$WORK/logs"

ok()   { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# --- the fixture builder ----------------------------------------------------
# make_fixture <dir> — writes a coherent miniature library:
#   manifest.csv   10 rows, all kept (name_reject == "" and feas_reject == "")
#   subsets/*.yaml tiny(2) ⊂ 1h(4) ⊂ 7h(6) ⊂ 40h(8) ⊂ all(10)
#   clip<i>.npz    10 minimal npz files with fps == 50
#   human50/session/side.npz  one S05-style human50 sidecar (must NOT be
#                     counted by the audit; its size is deliberately distinct)
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/subsets" "$dir/human50/session"
  "${NP_PY_ARGS[@]}" - "$dir" <<'PYEOF'
import csv
import os
import sys

import numpy as np

root = os.path.realpath(sys.argv[1])
clips = ["clip%d.npz" % i for i in range(10)]
seconds = 3600.0

for name in clips:
    np.savez(
        os.path.join(root, name),
        fps=np.array(50),
        joint_pos=np.zeros((2, 29), dtype=np.float64),
        joint_vel=np.zeros((2, 29), dtype=np.float64),
        joint_names=np.array(["j%d" % i for i in range(29)]),
        body_names=np.array(["b%d" % i for i in range(30)]),
    )

# the S05 human50 sidecar: same extension, different payload
np.savez(
    os.path.join(root, "human50", "session", "side.npz"),
    human_pos_w=np.zeros((2, 24, 3), dtype=np.float64),
    human_quat_w=np.zeros((2, 24, 4), dtype=np.float64),
    fps=np.array(50),
)

with open(os.path.join(root, "manifest.csv"), "w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow([
        "name", "path", "session", "frames", "seconds",
        "name_reject", "feas_reject", "category", "package",
    ])
    for i, clip in enumerate(clips):
        writer.writerow([
            "clip%d" % i, clip, "session", 50, seconds, "", "", "cat", "pkg",
        ])

# the chain is nested: every subset is a prefix of the next one
for name, count in (("tiny", 2), ("1h", 4), ("7h", 6), ("40h", 8), ("all", 10)):
    with open(os.path.join(root, "subsets", "%s.yaml" % name), "w") as handle:
        handle.write("root: %s\n" % root)
        handle.write("hours: %s\n" % (count * seconds / 3600.0))
        handle.write("clips:\n")
        for clip in clips[:count]:
            handle.write("- %s\n" % clip)
PYEOF
}

# --- the runner -------------------------------------------------------------
# run_verify <label> <out dir> [expected rows] — runs the reviewer and stores
# the exit code in RC and the combined output in OUT.
run_verify() {
  local label="$1" dir="$2" expected="${3:-10}"
  OUT="$(SEED_NPZ_OUT_DIR="$dir" SEED_EXPECTED_ROWS="$expected" \
        SEED_NPZ_SAMPLE=3 bash "$VERIFY_SH" verify 2>&1)"
  RC=$?
  LAST_LABEL="$label"
}

assert_ok() {
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "SEED_NPZ_VERIFY_OK"; then
    ok "$1 (verify passed and printed the OK marker)"
  else
    bad "$1 (rc=$RC, output below)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
}

assert_failed() {
  local expected_reason="${2:-}"
  if [ "$RC" -eq 0 ]; then
    bad "$1 (expected a non-zero exit code, got 0)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    return
  fi
  if printf '%s\n' "$OUT" | grep -q "SEED_NPZ_VERIFY_OK"; then
    bad "$1 (failed run still printed the OK marker)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    return
  fi
  if ! printf '%s\n' "$OUT" | grep -q "SEED_NPZ_VERIFY_FAIL"; then
    bad "$1 (no SEED_NPZ_VERIFY_FAIL marker in the output)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    return
  fi
  if [ -n "$expected_reason" ] && ! printf '%s\n' "$OUT" | grep -q "SEED_NPZ_VERIFY_FAIL reason=$expected_reason"; then
    bad "$1 (failed for the wrong reason: expected $expected_reason)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    return
  fi
  ok "$1 (rc=$RC, no OK marker, fail marker present${expected_reason:+, reason=$expected_reason})"
}

# --- 1) the forward case ----------------------------------------------------
GOOD="$WORK/good"
make_fixture "$GOOD"
run_verify "forward" "$GOOD" 10
assert_ok "forward case"

# the OK marker must carry the expected numbers
if printf '%s\n' "$OUT" | grep -q "SEED_NPZ_VERIFY_OK rows=10 errors=0"; then
  ok "forward case (OK marker carries rows=10 errors=0)"
else
  bad "forward case (OK marker does not carry the row/error numbers)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# --- the audit and the report subcommands ----------------------------------
AUDIT_OUT="$(SEED_NPZ_OUT_DIR="$GOOD" SEED_EXPECTED_ROWS=10 bash "$VERIFY_SH" audit 2>&1)"
AUDIT_RC=$?
if [ "$AUDIT_RC" -eq 0 ] && printf '%s\n' "$AUDIT_OUT" | grep -q "SEED_NPZ_FILES count=10"; then
  ok "audit counts the npz files of the fixture"
else
  bad "audit (rc=$AUDIT_RC)"
  printf '%s\n' "$AUDIT_OUT" | sed 's/^/    /'
fi

# --- 1b) the audit must EXCLUDE the human50 sidecar root (slice S05) --------
# The fixture holds 10 robot npz + 1 sidecar under human50/session/.  The
# audit count must stay 10 and the byte total must cover the robot npz only.
EXPECTED_BYTES="$(find "$GOOD" -maxdepth 1 -type f -name '*.npz' -printf '%s\n' \
  | awk '{s+=$1} END {printf "%.0f", s+0}')"
SIDECAR_BYTES="$(stat -c '%s' "$GOOD/human50/session/side.npz")"
if printf '%s\n' "$AUDIT_OUT" | grep -q "SEED_NPZ_FILES count=10 bytes=$EXPECTED_BYTES"; then
  ok "audit excludes the human50 sidecar from the count and from the bytes"
else
  bad "audit counted the human50 sidecar (expected count=10 bytes=$EXPECTED_BYTES)"
  printf '%s\n' "$AUDIT_OUT" | sed 's/^/    /'
  printf '    (sidecar bytes=%s, robot npz bytes=%s)\n' "$SIDECAR_BYTES" "$EXPECTED_BYTES"
fi

# and the sidecar must actually exist in the fixture, otherwise the assertion
# above would pass vacuously
if [ -f "$GOOD/human50/session/side.npz" ]; then
  ok "the fixture really contains a human50 sidecar"
else
  bad "the fixture is missing the human50 sidecar"
fi

# the negative guard for the guard: WITHOUT the prune the same tree counts 11
# npz files.  If the prune were removed from the script, the audit marker
# would become count=11 and the assertion above would fail — so this line
# proves the fixture really exercises the pruning path.
UNPRUNED_COUNT="$(find "$GOOD" -type f -name '*.npz' | wc -l | tr -d ' ')"
if [ "$UNPRUNED_COUNT" = "11" ]; then
  ok "the unpruned npz count of the fixture is 11 (prune is doing real work)"
else
  bad "the unpruned npz count of the fixture is $UNPRUNED_COUNT, expected 11"
fi

REPORT_OUT="$(SEED_NPZ_OUT_DIR="$GOOD" SEED_EXPECTED_ROWS=10 bash "$VERIFY_SH" report 2>&1)"
REPORT_RC=$?
if [ "$REPORT_RC" -eq 0 ] \
   && printf '%s\n' "$REPORT_OUT" | grep -q "SEED_REPORT_NPZ_ROWS=10" \
   && printf '%s\n' "$REPORT_OUT" | grep -q "SEED_REPORT_NPZ_1H_CLIPS=4" \
   && printf '%s\n' "$REPORT_OUT" | grep -q "SEED_REPORT_NPZ_OK=1"; then
  ok "report prints the SEED_REPORT_NPZ_* numbers"
else
  bad "report (rc=$REPORT_RC)"
  printf '%s\n' "$REPORT_OUT" | sed 's/^/    /'
fi

# --- 2) negative: the row count does not match ------------------------------
ROWCOUNT="$WORK/rowcount"
make_fixture "$ROWCOUNT"
# drop the last manifest row: 9 rows while 10 are expected
python3 - "$ROWCOUNT/manifest.csv" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as handle:
    lines = handle.readlines()
with open(path, "w") as handle:
    handle.writelines(lines[:-1])
PYEOF
run_verify "row-count" "$ROWCOUNT" 10
assert_failed "negative: row count mismatch" "row-count"

# --- 3) negative: the error rate exceeds 1% ---------------------------------
ERRRATE="$WORK/errrate"
make_fixture "$ERRRATE"
python3 - "$ERRRATE/manifest.csv" <<'PYEOF'
import csv
import sys

path = sys.argv[1]
with open(path, newline="") as handle:
    reader = csv.reader(handle)
    rows = list(reader)
for index in (1, 2):
    rows[index][6] = "error: mujoco exploded"
with open(path, "w", newline="") as handle:
    csv.writer(handle).writerows(rows)
PYEOF
run_verify "error-rate" "$ERRRATE" 10
assert_failed "negative: error rate above 1%" "error-rate"

# --- 4) negative: the subset chain is not nested -----------------------------
NESTED="$WORK/nested"
make_fixture "$NESTED"
# a clip of 1h that is not part of all.yaml
python3 - "$NESTED/subsets/1h.yaml" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
with open(path, "w") as handle:
    handle.write(text + "- ghost_clip.npz\n")
PYEOF
run_verify "not-nested" "$NESTED" 10
assert_failed "negative: subset chain not nested" "subset-not-nested"

# --- 5) negative: a sampled npz is missing -----------------------------------
MISSING="$WORK/missing"
make_fixture "$MISSING"
# the deterministic sample of 3 covers the rows 0, 5 and 9
rm -f "$MISSING/clip9.npz"
run_verify "missing-npz" "$MISSING" 10
assert_failed "negative: sampled npz missing" "sample-missing"

# --- 6) negative: the 1h.yaml root points at the wrong directory ------------
ROOTBAD="$WORK/rootbad"
make_fixture "$ROOTBAD"
python3 - "$ROOTBAD/subsets/1h.yaml" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as handle:
    lines = handle.readlines()
lines[0] = "root: /nonexistent/npz/root\n"
with open(path, "w") as handle:
    handle.writelines(lines)
PYEOF
run_verify "bad-root" "$ROOTBAD" 10
assert_failed "negative: 1h.yaml root points at the wrong directory" "subset-root-mismatch"

# --- 7) negative: the manifest does not exist --------------------------------
run_verify "no-manifest" "$WORK/does-not-exist" 10
assert_failed "negative: manifest missing" "manifest-missing"

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
