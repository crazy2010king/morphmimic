#!/usr/bin/env bash
# repro/tests/test_deploy.sh — offline fixture battery for the deployment
# verification decision base (repro/lib/deploy.py + repro/lib/deploy.sh,
# slice S08).
#
# No network, no container, no torch/onnx: every summary JSON / eval CSV /
# mp4 / assets directory / official directory / session / comparison table is
# a synthetic fixture built in a temp dir.  The battery drives the real shell
# wrapper (repro/lib/deploy.sh) so that the wrapper is covered too.
#
# EVERY failing case asserts that
#   1. the exit code is non-zero,
#   2. NO DEPLOY_*_OK marker was printed,
#   3. the reason belongs to the fixed reason set of the decision base.
#
# Run locally:   bash repro/tests/test_deploy.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_deploy.sh
#
# Exit code 0 == all tests passed (and PASS >= 30, FAIL == 0).

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
WRAPPER="$LIB_DIR/deploy.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"

# The fixed reason set of the decision base (kept in sync with
# repro/lib/deploy.py REASONS).
REASONS="summary-missing summary-parse-failed summary-field-missing \
summary-value-empty summary-count-mismatch video-missing video-empty \
eval-csv-missing eval-csv-parse-failed eval-row-count-mismatch \
assets-missing assets-xml-missing assets-clips-missing assets-clips-mismatch \
official-dir-missing official-sha-missing official-sha-mismatch \
official-json-missing official-onnx-missing compare-missing \
compare-parse-failed compare-row-mismatch session-missing \
session-format-invalid replay-summary-missing replay-summary-empty \
session-shape-invalid deploy-dir-missing deploy-onnx-missing \
deploy-json-missing data-clip-missing mujoco-gl-unset \
session-make-failed replay-run-failed replay-timeout"

# --- runners ----------------------------------------------------------------

# run_cli <args...> -> sets $RC and $OUT (stdout + stderr of the wrapper)
run_cli() {
  bash "$WRAPPER" "$@" >"$OUT" 2>&1
  RC=$?
}

has_ok_marker() {
  grep -q '_OK ' "$OUT" || grep -q '_OK$' "$OUT"
}

reason_in_set() {
  local reason
  reason="$(sed -n 's/.*_FAIL reason=\([a-z-]*\).*/\1/p' "$OUT" | head -1)"
  [ -n "$reason" ] || return 1
  case " $REASONS " in
    *" $reason "*) return 0 ;;
  esac
  return 1
}

# assert_fail <label> <expected reason>
# The command must have exited non-zero, printed no OK marker and carried the
# expected reason.
assert_fail() {
  local label="$1" expected="$2"
  if [ "$RC" -eq 0 ]; then
    bad "$label: exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
    return
  fi
  ok "$label: exited non-zero ($RC)"
  if has_ok_marker; then
    bad "$label: an OK marker must NOT be printed on a failure"
    sed 's/^/      | /' "$OUT"
  else
    ok "$label: no OK marker"
  fi
  if ! reason_in_set; then
    bad "$label: no reason from the fixed set"; sed 's/^/      | /' "$OUT"
    return
  fi
  ok "$label: the reason belongs to the fixed set"
  local reason
  reason="$(sed -n 's/.*_FAIL reason=\([a-z-]*\).*/\1/p' "$OUT" | head -1)"
  if [ "$reason" = "$expected" ]; then
    ok "$label: reason=$expected"
  else
    bad "$label: reason=$reason (expected $expected)"
  fi
}

# assert_ok <label> [expected substring]
assert_ok() {
  local label="$1" expected="${2:-}"
  if [ "$RC" -eq 0 ]; then
    ok "$label: exited 0"
  else
    bad "$label: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
    return
  fi
  if has_ok_marker; then
    ok "$label: an OK marker was printed"
  else
    bad "$label: no OK marker"; sed 's/^/      | /' "$OUT"
    return
  fi
  if [ -n "$expected" ]; then
    if grep -q "$expected" "$OUT"; then
      ok "$label: the OK marker carries '$expected'"
    else
      bad "$label: the OK marker does not carry '$expected'"
      sed 's/^/      | /' "$OUT"
    fi
  fi
}

# --- fixture builders -------------------------------------------------------

SUM_DIR="$TMP/summaries"
EVAL_CSV="$TMP/eval_motion.csv"
ASSETS_DIR="$TMP/assets"
OFFICIAL_DIR="$TMP/morphmimic_policy"
SESSION_NPZ="$TMP/session.npz"
COMPARE_CSV="$TMP/compare.csv"

write_summary() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  cat >"$dir/$name" <<'JSON'
{
 "robot": "g1_amber",
 "clip": "walk_forward_start_001__A021",
 "frames": 178,
 "result": "completed",
 "joint_err_rms_rad": 0.0312,
 "body_err_mean_m": 0.0417,
 "end_drift_m": 0.0553
}
JSON
}

write_eval_csv() {
  local path="$1" rows="$2"
  {
    printf 'name,frames,failed,fail_frame,norm_return,steps\n'
    local i=0
    while [ "$i" -lt "$rows" ]; do
      printf 'clip_%03d,178,False,-1,0.5,178\n' "$i"
      i=$((i + 1))
    done
  } >"$path"
}

write_assets_dir() {
  local dir="$1" clips="$2"
  mkdir -p "$dir/clips/g1_amber"
  printf '<mujoco/>\n' >"$dir/g1_amber.xml"
  local i=0
  while [ "$i" -lt "$clips" ]; do
    printf 'fake npz bytes\n' >"$dir/clips/g1_amber/clip_$(printf '%03d' "$i").npz"
    i=$((i + 1))
  done
}

write_official_dir() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'fake policy graph\n' >"$dir/policy.onnx"
  printf '{"fake": "robot json"}\n' >"$dir/g1_amber.json"
  ( cd "$dir" && sha256sum policy.onnx g1_amber.json >SHA256SUMS )
}

write_session() {
  local path="$1"
  "$DEPLOY_PY_BIN" - "$path" <<'PY'
import struct, sys, zipfile

path = sys.argv[1]


def npy(values):
  header = ("{'descr': '<f8', 'fortran_order': False, 'shape': (%d,), }"
            % len(values))
  raw = header.encode("latin-1")
  pad = (64 - ((10 + len(raw) + 1) % 64)) % 64
  raw += b" " * pad + b"\n"
  return (b"\x93NUMPY" + bytes([1, 0]) + struct.pack("<H", len(raw)) + raw
          + struct.pack("<%dd" % len(values), *values))


with zipfile.ZipFile(path, "w") as archive:
  for member in ("t_ns.npy", "body.npy", "buttons.npy"):
    archive.writestr(member, npy([0.0, 1.0, 2.0]))
PY
}

write_compare_csv() {
  local path="$1"
  {
    printf 'clip,frames,self_result,self_joint_err_rms_rad,self_body_err_mean_m,self_end_drift_m,official_result,official_joint_err_rms_rad,official_body_err_mean_m,official_end_drift_m,delta_joint_err_rms_rad,delta_body_err_mean_m,delta_end_drift_m\n'
    printf 'clip_a,178,completed,0.5,0.6,0.7,completed,0.2,0.4,0.5,0.3,0.2,0.2\n'
  } >"$path"
}

DEPLOY_PY_BIN="${DEPLOY_PY:-python3}"

# ============================================================================
# 1. the sim2sim summary contract
# ============================================================================
write_summary "$SUM_DIR" "clip_a.json"
write_summary "$SUM_DIR" "clip_b.json"

run_cli sim --dir "$SUM_DIR" --expect-count 2
assert_ok "healthy summaries" "DEPLOY_SIM_OK"

run_cli sim --dir "$TMP/no_such_dir" --expect-count 1
assert_fail "missing summary directory" "summary-missing"

mkdir -p "$TMP/empty_sum_dir"
run_cli sim --dir "$TMP/empty_sum_dir" --expect-count 1
assert_fail "empty summary directory" "summary-missing"

run_cli sim --dir "$SUM_DIR" --expect-count 490
assert_fail "summary count mismatch" "summary-count-mismatch"

mkdir -p "$TMP/broken_sum_dir"
printf '{not json\n' >"$TMP/broken_sum_dir/broken.json"
run_cli sim --dir "$TMP/broken_sum_dir" --expect-count 1
assert_fail "broken summary json" "summary-parse-failed"

mkdir -p "$TMP/no_field_sum_dir"
printf '{"robot": "g1_amber", "frames": 10}\n' >"$TMP/no_field_sum_dir/a.json"
run_cli sim --dir "$TMP/no_field_sum_dir" --expect-count 1
assert_fail "summary without the required fields" "summary-field-missing"

mkdir -p "$TMP/empty_value_sum_dir"
cat >"$TMP/empty_value_sum_dir/a.json" <<'JSON'
{"robot": "g1_amber", "clip": "c", "frames": 178, "result": "completed",
 "joint_err_rms_rad": null, "body_err_mean_m": 0.04, "end_drift_m": 0.05}
JSON
run_cli sim --dir "$TMP/empty_value_sum_dir" --expect-count 1
assert_fail "summary with a null value" "summary-value-empty"

mkdir -p "$TMP/nan_value_sum_dir"
cat >"$TMP/nan_value_sum_dir/a.json" <<'JSON'
{"robot": "g1_amber", "clip": "c", "frames": 178, "result": "completed",
 "joint_err_rms_rad": 0.01, "body_err_mean_m": 0.04, "end_drift_m": NaN}
JSON
run_cli sim --dir "$TMP/nan_value_sum_dir" --expect-count 1
assert_fail "summary with a NaN value" "summary-value-empty"

# ============================================================================
# 2. the video contract
# ============================================================================
mkdir -p "$TMP/video_sum_dir"
printf 'fake mp4 bytes\n' >"$TMP/clip.mp4"
cat >"$TMP/video_sum_dir/a.json" <<JSON
{"robot": "g1_amber", "clip": "c", "frames": 178, "result": "completed",
 "joint_err_rms_rad": 0.01, "body_err_mean_m": 0.04, "end_drift_m": 0.05,
 "video": "$TMP/clip.mp4"}
JSON
run_cli sim --dir "$TMP/video_sum_dir" --expect-count 1
assert_ok "summary with a non-empty video"

mkdir -p "$TMP/missing_video_sum_dir"
cat >"$TMP/missing_video_sum_dir/a.json" <<JSON
{"robot": "g1_amber", "clip": "c", "frames": 178, "result": "completed",
 "joint_err_rms_rad": 0.01, "body_err_mean_m": 0.04, "end_drift_m": 0.05,
 "video": "$TMP/gone.mp4"}
JSON
run_cli sim --dir "$TMP/missing_video_sum_dir" --expect-count 1
assert_fail "summary naming a missing video" "video-missing"

mkdir -p "$TMP/empty_video_sum_dir"
: >"$TMP/empty.mp4"
cat >"$TMP/empty_video_sum_dir/a.json" <<JSON
{"robot": "g1_amber", "clip": "c", "frames": 178, "result": "completed",
 "joint_err_rms_rad": 0.01, "body_err_mean_m": 0.04, "end_drift_m": 0.05,
 "video": "$TMP/empty.mp4"}
JSON
run_cli sim --dir "$TMP/empty_video_sum_dir" --expect-count 1
assert_fail "summary naming an empty video" "video-empty"

# ============================================================================
# 3. the eval CSV contract
# ============================================================================
write_eval_csv "$EVAL_CSV" 490
run_cli eval --path "$EVAL_CSV" --expect-rows 490
assert_ok "healthy eval csv" "DEPLOY_EVAL_OK"

run_cli eval --path "$TMP/no_such.csv" --expect-rows 490
assert_fail "missing eval csv" "eval-csv-missing"

printf 'name,frames\nclip,178\n' >"$TMP/short_header.csv"
run_cli eval --path "$TMP/short_header.csv" --expect-rows 1
assert_fail "eval csv without the required columns" "eval-csv-parse-failed"

write_eval_csv "$TMP/short.csv" 489
run_cli eval --path "$TMP/short.csv" --expect-rows 490
assert_fail "eval csv with the wrong row count" "eval-row-count-mismatch"

# ============================================================================
# 4. the assets contract
# ============================================================================
write_assets_dir "$ASSETS_DIR" 3
run_cli assets --dir "$ASSETS_DIR" --expect-clips 3
assert_ok "healthy assets directory" "DEPLOY_ASSETS_OK"

run_cli assets --dir "$TMP/no_such_assets" --expect-clips 3
assert_fail "missing assets directory" "assets-missing"

mkdir -p "$TMP/assets_no_xml/clips/g1_amber"
printf 'x\n' >"$TMP/assets_no_xml/clips/g1_amber/a.npz"
run_cli assets --dir "$TMP/assets_no_xml" --expect-clips 1
assert_fail "assets directory without the robot xml" "assets-xml-missing"

mkdir -p "$TMP/assets_no_clips"
printf '<mujoco/>\n' >"$TMP/assets_no_clips/g1_amber.xml"
run_cli assets --dir "$TMP/assets_no_clips" --expect-clips 1
assert_fail "assets directory without clips" "assets-clips-missing"

write_assets_dir "$TMP/assets_few" 2
run_cli assets --dir "$TMP/assets_few" --expect-clips 490
assert_fail "assets directory with the wrong clip count" "assets-clips-mismatch"

# ============================================================================
# 5. the official policy contract
# ============================================================================
write_official_dir "$OFFICIAL_DIR"
run_cli official --dir "$OFFICIAL_DIR"
assert_ok "healthy official directory" "DEPLOY_OFFICIAL_OK"

run_cli official --dir "$TMP/no_such_official"
assert_fail "missing official directory" "official-dir-missing"

mkdir -p "$TMP/official_no_sums"
printf 'fake policy graph\n' >"$TMP/official_no_sums/policy.onnx"
run_cli official --dir "$TMP/official_no_sums"
assert_fail "official directory without SHA256SUMS" "official-sha-missing"

cp -r "$OFFICIAL_DIR" "$TMP/official_tampered"
printf 'tampered\n' >"$TMP/official_tampered/policy.onnx"
run_cli official --dir "$TMP/official_tampered"
assert_fail "official directory with a tampered digest" "official-sha-mismatch"

mkdir -p "$TMP/official_no_json"
printf 'fake policy graph\n' >"$TMP/official_no_json/policy.onnx"
( cd "$TMP/official_no_json" && sha256sum policy.onnx >SHA256SUMS )
run_cli official --dir "$TMP/official_no_json"
assert_fail "official directory without a robot json" "official-json-missing"

cp -r "$OFFICIAL_DIR" "$TMP/official_missing_file"
rm -f "$TMP/official_missing_file/g1_amber.json"
run_cli official --dir "$TMP/official_missing_file"
assert_fail "official directory with a missing listed file" "official-sha-missing"

# ============================================================================
# 6. the human session contract
# ============================================================================
write_session "$SESSION_NPZ"
run_cli session --path "$SESSION_NPZ"
assert_ok "healthy session" "DEPLOY_HUMAN_OK"

run_cli session --path "$TMP/no_such.npz"
assert_fail "missing session" "session-missing"

printf 'not a zip at all\n' >"$TMP/broken.npz"
run_cli session --path "$TMP/broken.npz"
assert_fail "session that is not an npz" "session-format-invalid"

# ============================================================================
# 7. the comparison table contract
# ============================================================================
write_compare_csv "$COMPARE_CSV"
run_cli compare --path "$COMPARE_CSV" --expect-rows 1
assert_ok "healthy comparison table" "DEPLOY_VERIFY_OK"

run_cli compare --path "$TMP/no_such.csv"
assert_fail "missing comparison table" "compare-missing"

printf 'clip,frames\nclip_a,178\n' >"$TMP/compare_short.csv"
run_cli compare --path "$TMP/compare_short.csv"
assert_fail "comparison table without the required columns" "compare-parse-failed"

run_cli compare --path "$COMPARE_CSV" --expect-rows 49
assert_fail "comparison table with the wrong row count" "compare-row-mismatch"

sed 's/,0.3,0.2,0.2$/,0.9,0.2,0.2/' "$COMPARE_CSV" >"$TMP/compare_bad_delta.csv"
run_cli compare --path "$TMP/compare_bad_delta.csv"
assert_fail "comparison table with a wrong delta" "compare-row-mismatch"

# ============================================================================
# 8. the wrapper holds no decision logic of its own
# ============================================================================
if grep -qE 'DEPLOY_(SIM|EVAL|ASSETS|OFFICIAL|HUMAN|VERIFY)_(OK|FAIL)' "$WRAPPER"; then
  bad "the wrapper must not print a decision marker itself"
else
  ok "the wrapper prints no decision marker itself"
fi
if grep -qE 'reason=' "$WRAPPER"; then
  bad "the wrapper must not decide a reason itself"
else
  ok "the wrapper decides no reason itself"
fi
if [ ! -f "$LIB_DIR/deploy.py" ]; then
  bad "the wrapper points at a missing module"
else
  ok "the wrapper points at an existing module"
fi

# ============================================================================
# summary
# ============================================================================
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
if [ "$PASS" -lt 30 ]; then
  printf 'FAIL  the battery must run at least 30 checks (ran %d)\n' "$PASS"
  exit 1
fi
exit 0
