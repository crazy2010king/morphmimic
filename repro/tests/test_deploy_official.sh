#!/usr/bin/env bash
# repro/tests/test_deploy_official.sh — the OFFLINE battery of the official
# weights + sim2sim comparison orchestrator (repro/24_official.sh).
#
# The battery drives the REAL orchestrator with FAKE downloads and a FAKE
# replay command, so neither the container, nor the network, nor a GPU, nor
# EGL, nor the real replay are needed:
#
#   * the download is stubbed by OFFICIAL_DOWNLOAD_CMD (the stub copies a
#     fixture zip built here with python3's zipfile: the archive carries the
#     same morphmimic_policy/ top level directory as the official one),
#   * the replay is stubbed by OFFICIAL_RUN_TEMPLATE (the stub writes the
#     summary json and the mp4 the upstream would write).
#
# The DECISION is never stubbed: the official directory is verified by the
# real decision base (repro/lib/deploy.py) and the real `sha256sum -c`.
#
# Every negative scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# usage: bash repro/tests/test_deploy_official.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/repro/24_official.sh"
PY_BIN="${DEPLOY_PY:-python3}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '     %s\n' "$2"
  return 0
}

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi
}
assert_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing=[$3] in=[$2]" ;;
  esac
}
assert_not_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) fail "$1" "unexpected=[$3] in=[$2]" ;;
    *) pass "$1" ;;
  esac
}
assert_rc_zero() { # <label> <rc>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "rc=$2"; fi
}
assert_rc_nonzero() { # <label> <rc>
  if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "rc=0"; fi
}
assert_file() { # <label> <path>
  if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing file: $2"; fi
}
assert_nonempty_file() { # <label> <path>
  if [ -f "$2" ] && [ -s "$2" ]; then pass "$1"; else fail "$1" "missing/empty file: $2"; fi
}
assert_file_count() { # <label> <dir> <glob> <expected>
  local n
  n="$(find "$2" -maxdepth 1 -type f -name "$3" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$1" "$4" "$n"
}
assert_csv_rows() { # <label> <csv> <expected data rows>
  local n
  n="$(($(wc -l <"$2") - 1))"
  assert_eq "$1" "$3" "$n"
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the fixture package ---------------------------------------------------
# It mimics the official v0.1 layout: policy.onnx + three robot jsons +
# MANIFEST.txt + SHA256SUMS (covering FOUR files).
PKG="$TMP/pkg/morphmimic_policy"
mkdir -p "$PKG"
printf 'fake official policy graph\n' >"$PKG/policy.onnx"
printf '{"fake": "g1_amber json"}\n' >"$PKG/g1_amber.json"
printf '{"fake": "x2 json"}\n' >"$PKG/x2.json"
printf '{"fake": "t2 json"}\n' >"$PKG/t2.json"
printf 'SuperMimic deployment export (fixture)\n' >"$PKG/MANIFEST.txt"
( cd "$PKG" && sha256sum policy.onnx g1_amber.json t2.json x2.json >SHA256SUMS )

# the release zip: the same morphmimic_policy/ top level directory
FIXTURE_ZIP="$TMP/morphmimic_policy.zip"
"$PY_BIN" - "$PKG" "$FIXTURE_ZIP" <<'PY'
import os
import sys
import zipfile

source, target = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
  for name in sorted(os.listdir(source)):
    archive.write(os.path.join(source, name), "morphmimic_policy/" + name)
PY

# --- the fixtures ----------------------------------------------------------
ASSETS="$TMP/assets"
DEPLOY_SELF="$TMP/out/g1_amber"
OUT_DIR="$TMP/runs/official"
OFFICIAL_DIR="$OUT_DIR/morphmimic_policy"
SIM_OUT="$OUT_DIR/sim2sim"
SELF_SIM="$TMP/runs/sim2sim"
COMPARE_CSV="$OUT_DIR/compare_self_vs_official.csv"
LOGS="$TMP/logs"
CLIP_LIST="$ASSETS/clips_g1_amber.txt"

mkdir -p "$ASSETS" "$DEPLOY_SELF" "$LOGS" "$SELF_SIM/summary"
printf '<mujoco model="fake">\n  <worldbody/>\n</mujoco>\n' >"$ASSETS/g1_amber.xml"
printf 'fake onnx\n' >"$DEPLOY_SELF/policy.onnx"
{
  printf 'clips/g1_amber/clip_000__A000.npz\n'
  printf 'clips/g1_amber/clip_001__A001.npz\n'
  printf 'clips/g1_amber/clip_002__A002.npz\n'
} >"$CLIP_LIST"

CLIPS=(clip_000__A000 clip_001__A001 clip_002__A002)

# the SELF side of the comparison (the summaries 22_sim2sim.sh would write)
for clip in "${CLIPS[@]}"; do
  cat >"$SELF_SIM/summary/$clip.json" <<JSON
{"robot": "g1_amber", "clip": "$clip", "frames": 100, "result": "completed",
 "joint_err_rms_rad": 0.05, "body_err_mean_m": 0.02, "end_drift_m": 0.03}
JSON
done

# --- the fake replay command ------------------------------------------------
# It understands the upstream's arguments and writes the artefacts:
#   --summary <json>   the summary the upstream writes
#   --video <mp4>      the mp4 the upstream writes
# The behaviour is steered by FAKE_OFFICIAL_MODE:
#   ok           the happy path
#   empty-value  the summary carries body_err_mean_m: null
#   misaligned   the summary carries a clip name that does not match the
#                clip list (the comparison table then loses that row)
#   nonzero      the command itself fails
STUB="$TMP/stub_deploy_run.sh"
cat >"$STUB" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
summary=""
video=""
clip=""
deploy=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary) summary="$2"; shift 2 ;;
    --video) video="$2"; shift 2 ;;
    --clip) clip="$2"; shift 2 ;;
    --deploy) deploy="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\tMUJOCO_GL=%s\n' "$clip" "$deploy" "${MUJOCO_GL:-<unset>}" >>"${STUB_CALLS:?}"

mode="${FAKE_OFFICIAL_MODE:-ok}"
if [ "$mode" = "nonzero" ]; then
  echo "fake deploy.run: the official replay failed" >&2
  exit 7
fi

name="$clip"
if [ "$mode" = "misaligned" ]; then
  name="other_$clip"
fi
mkdir -p "$(dirname "$summary")"
case "$mode" in
  empty-value)
    cat >"$summary" <<JSON
{"robot": "g1_amber", "clip": "$name", "frames": 100, "result": "completed",
 "joint_err_rms_rad": 0.16, "body_err_mean_m": null, "end_drift_m": 0.39}
JSON
    ;;
  *)
    cat >"$summary" <<JSON
{"robot": "g1_amber", "clip": "$name", "frames": 100, "result": "completed",
 "joint_err_rms_rad": 0.16, "body_err_mean_m": 0.039, "end_drift_m": 0.38}
JSON
    ;;
esac
mkdir -p "$(dirname "$video")"
printf 'fake mp4 bytes\n' >"$video"
exit 0
STUB
chmod +x "$STUB"

STUB_CALLS="$TMP/stub_calls.txt"
: >"$STUB_CALLS"

RUN_TEMPLATE="$STUB --deploy {deploy} --assets {assets} --robot {robot} --clip {clip} --interface motion --video {video} --summary {summary}"
DOWNLOAD_CMD="cp $(printf '%q' "$FIXTURE_ZIP") {zip}"

# run <subcommand> [VAR=value ...] [args...]
# The VAR=value arguments become environment overrides of the orchestrator
# (they are applied AFTER the defaults, so they win); every other argument
# is passed to the orchestrator as an argument.
run() {
  local sub="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  OUT="$(env \
    OFFICIAL_ALLOW_LOCAL=1 \
    STUB_CALLS="$STUB_CALLS" \
    FAKE_OFFICIAL_MODE="ok" \
    OFFICIAL_OUT_DIR="$OUT_DIR" \
    OFFICIAL_DIR="$OFFICIAL_DIR" \
    OFFICIAL_ZIP="$OUT_DIR/morphmimic_policy.zip" \
    OFFICIAL_SIM_OUT_DIR="$SIM_OUT" \
    OFFICIAL_SELF_SIM_DIR="$SELF_SIM" \
    OFFICIAL_COMPARE_CSV="$COMPARE_CSV" \
    OFFICIAL_ASSETS_DIR="$ASSETS" \
    OFFICIAL_CLIP_LIST="$CLIP_LIST" \
    OFFICIAL_IMPORT_CMD="true" \
    OFFICIAL_RUN_TEMPLATE="$RUN_TEMPLATE" \
    OFFICIAL_DOWNLOAD_CMD="$DOWNLOAD_CMD" \
    OFFICIAL_LOG_DIR="$LOGS" \
    "${envs[@]+"${envs[@]}"}" \
    bash "$ORCH" "$sub" "$@" 2>&1)"
  RC=$?
}

stub_calls() { wc -l <"$STUB_CALLS" 2>/dev/null | tr -d ' '; }

echo "== 24_official.sh: the download =="

run download
assert_rc_zero "the download exits 0" "$RC"
assert_contains "the download prints DEPLOY_OFFICIAL_DOWNLOAD_OK" "$OUT" "DEPLOY_OFFICIAL_DOWNLOAD_OK"
assert_file "the zip is kept" "$OUT_DIR/morphmimic_policy.zip"
assert_file_count "the unpacked package holds six files" "$OFFICIAL_DIR" '*' 6
assert_file "the unpacked package holds the policy" "$OFFICIAL_DIR/policy.onnx"
assert_file "the unpacked package holds the robot json" "$OFFICIAL_DIR/g1_amber.json"

run download "OFFICIAL_DOWNLOAD_CMD=false"
assert_rc_nonzero "the download fails when the download command fails" "$RC"
assert_contains "the download reports download-failed" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=download-failed"
assert_not_contains "a failed download prints no OK marker" "$OUT" "_OK"

run download "OFFICIAL_DOWNLOAD_CMD=true"
assert_rc_nonzero "the download fails when no zip arrives" "$RC"
assert_contains "the download reports zip-missing" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=zip-missing"
assert_not_contains "a missing zip prints no OK marker" "$OUT" "_OK"

run download "OFFICIAL_DOWNLOAD_CMD=printf 'not a zip' >{zip}"
assert_rc_nonzero "the download fails when the archive is broken" "$RC"
assert_contains "the download reports zip-extract-failed" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=zip-extract-failed"
assert_not_contains "a broken archive prints no OK marker" "$OUT" "_OK"

echo "== 24_official.sh: the verification =="

# the package is in place (the download above unpacked it)
run verify
assert_rc_zero "the verification exits 0" "$RC"
assert_contains "the verification prints DEPLOY_OFFICIAL_OK" "$OUT" "DEPLOY_OFFICIAL_OK"
assert_contains "the verification reports the file count" "$OUT" "files=6"
assert_contains "the verification reports the digest coverage" "$OUT" "sha_files=4"
assert_contains "the verification really ran sha256sum -c" "$OUT" "sha256sum -c: rc=0 ok=4"
assert_contains "the verification logged the four OK lines" "$(cat "$LOGS/24_official.txt")" "g1_amber.json: OK"

cp -r "$OFFICIAL_DIR" "$TMP/official_tampered"
printf 'tampered\n' >"$TMP/official_tampered/policy.onnx"
run verify "OFFICIAL_DIR=$TMP/official_tampered"
assert_rc_nonzero "the verification fails when a digest does not match" "$RC"
assert_contains "the verification reports official-sha-mismatch" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=official-sha-mismatch"
assert_not_contains "a digest mismatch prints no OK marker" "$OUT" "_OK"

cp -r "$OFFICIAL_DIR" "$TMP/official_no_json"
rm -f "$TMP/official_no_json/g1_amber.json"
run verify "OFFICIAL_DIR=$TMP/official_no_json"
assert_rc_nonzero "the verification fails when the robot json is missing" "$RC"
assert_contains "the verification reports official-sha-missing" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=official-sha-missing"
assert_not_contains "a missing json prints no OK marker" "$OUT" "_OK"

cp -r "$OFFICIAL_DIR" "$TMP/official_uncovered"
grep -v -e 'g1_amber.json' -e 'x2.json' -e 't2.json' "$TMP/official_uncovered/SHA256SUMS" >"$TMP/official_uncovered/SHA256SUMS.new"
mv "$TMP/official_uncovered/SHA256SUMS.new" "$TMP/official_uncovered/SHA256SUMS"
rm -f "$TMP/official_uncovered"/g1_amber.json "$TMP/official_uncovered"/x2.json "$TMP/official_uncovered"/t2.json
run verify "OFFICIAL_DIR=$TMP/official_uncovered"
assert_rc_nonzero "the verification fails when no robot json is left" "$RC"
assert_contains "the verification reports official-json-missing" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=official-json-missing"
assert_not_contains "an uncovered json prints no OK marker" "$OUT" "_OK"

cp -r "$OFFICIAL_DIR" "$TMP/official_uncovered2"
grep -v 'g1_amber.json' "$TMP/official_uncovered2/SHA256SUMS" >"$TMP/official_uncovered2/SHA256SUMS.new"
mv "$TMP/official_uncovered2/SHA256SUMS.new" "$TMP/official_uncovered2/SHA256SUMS"
run verify "OFFICIAL_DIR=$TMP/official_uncovered2"
assert_rc_nonzero "the verification fails when the robot json is not covered" "$RC"
assert_contains "the verification reports official-sha-missing" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=official-sha-missing"
assert_not_contains "an uncovered json prints no OK marker" "$OUT" "_OK"

run verify "OFFICIAL_DIR=$TMP/no_such_official"
assert_rc_nonzero "the verification fails without the official directory" "$RC"
assert_contains "the verification reports official-dir-missing" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=official-dir-missing"
assert_not_contains "a missing directory prints no OK marker" "$OUT" "_OK"

echo "== 24_official.sh: the comparison =="

: >"$STUB_CALLS"
run compare
assert_rc_zero "the comparison exits 0" "$RC"
assert_contains "the comparison prints DEPLOY_OFFICIAL_COMPARE_OK" "$OUT" "DEPLOY_OFFICIAL_COMPARE_OK"
assert_contains "the comparison reports the row count" "$OUT" "DEPLOY_OFFICIAL_COMPARE_OK rows=3"
assert_eq "every clip of the list was replayed with the official policy" "3" "$(stub_calls)"
assert_contains "the replay used the official deploy directory" "$(cat "$STUB_CALLS")" "$OFFICIAL_DIR"
assert_contains "the replay exported MUJOCO_GL=egl itself" "$(cat "$STUB_CALLS")" "MUJOCO_GL=egl"
assert_file "the comparison table is written" "$COMPARE_CSV"
assert_csv_rows "the comparison table holds one row per clip" "$COMPARE_CSV" 3
assert_contains "the comparison table names the self side" "$(head -n 1 "$COMPARE_CSV")" "self_joint_err_rms_rad"
assert_contains "the comparison table names the official side" "$(head -n 1 "$COMPARE_CSV")" "official_joint_err_rms_rad"
assert_contains "the comparison table carries the deltas" "$(head -n 1 "$COMPARE_CSV")" "delta_end_drift_m"
assert_contains "the first row carries a delta value" "$(sed -n 2p "$COMPARE_CSV")" "-0.11"
assert_file_count "one official summary per clip" "$SIM_OUT/summary" '*.json' 3
assert_file_count "one official video per clip" "$SIM_OUT/video" '*.mp4' 3

# the MIXED json is refused: our own robot json in the official directory
: >"$STUB_CALLS"
cp -r "$OFFICIAL_DIR" "$TMP/official_mixed"
cp "$DEPLOY_SELF/g1_amber.json" "$TMP/official_mixed/g1_amber.json" 2>/dev/null \
  || printf 'our own json\n' >"$TMP/official_mixed/g1_amber.json"
run compare "OFFICIAL_DIR=$TMP/official_mixed"
assert_rc_nonzero "the comparison refuses a mixed robot json" "$RC"
assert_contains "the comparison reports mixed-json" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=mixed-json"
assert_not_contains "a mixed json prints no OK marker" "$OUT" "_OK"
assert_eq "a mixed json replays no clip" "0" "$(stub_calls)"

# the table must hold one row per clip: a misaligned clip name loses a row
run compare FAKE_OFFICIAL_MODE=misaligned
assert_rc_nonzero "the comparison fails when the table loses a row" "$RC"
assert_contains "the comparison reports compare-row-mismatch" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=compare-row-mismatch"
assert_not_contains "a row mismatch prints no OK marker" "$OUT" "_OK"

# the self side must hold one summary per clip
rm -f "$SELF_SIM/summary/clip_001__A001.json"
run compare
assert_rc_nonzero "the comparison fails when the self side is incomplete" "$RC"
assert_contains "the comparison reports summary-count-mismatch" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=summary-count-mismatch"
assert_not_contains "an incomplete self side prints no OK marker" "$OUT" "_OK"
cp "$TMP/pkg/morphmimic_policy/g1_amber.json" /dev/null 2>/dev/null || true
cat >"$SELF_SIM/summary/clip_001__A001.json" <<'JSON'
{"robot": "g1_amber", "clip": "clip_001__A001", "frames": 100, "result": "completed",
 "joint_err_rms_rad": 0.05, "body_err_mean_m": 0.02, "end_drift_m": 0.03}
JSON

run compare FAKE_OFFICIAL_MODE=empty-value
assert_rc_nonzero "the comparison fails when an official metric is empty" "$RC"
assert_contains "the comparison reports summary-value-empty" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=summary-value-empty"
assert_not_contains "an empty metric prints no OK marker" "$OUT" "_OK"

run compare FAKE_OFFICIAL_MODE=nonzero
assert_rc_nonzero "the comparison fails when the replay command fails" "$RC"
assert_contains "the comparison reports run-failed" "$OUT" "DEPLOY_OFFICIAL_FAIL reason=run-failed"
assert_not_contains "a failing replay prints no OK marker" "$OUT" "_OK"

echo "== 24_official.sh: the environment gate =="

run env
assert_rc_zero "the environment gate exits 0" "$RC"
assert_contains "the environment gate prints DEPLOY_OFFICIAL_ENV_OK" "$OUT" "DEPLOY_OFFICIAL_ENV_OK"
assert_contains "the environment gate reports the clip count" "$OUT" "clips=3"

run env "OFFICIAL_DIR=$TMP/no_such_official"
assert_rc_nonzero "the environment gate fails without the official directory" "$RC"
assert_contains "the environment gate reports official-dir-missing" "$OUT" "DEPLOY_OFFICIAL_ENV_FAIL reason=official-dir-missing"
assert_not_contains "a failed environment gate prints no OK marker" "$OUT" "_OK"

echo "== 24_official.sh: the report =="

run compare
assert_rc_zero "the comparison succeeds again before the report" "$RC"
run report
assert_rc_zero "the report exits 0" "$RC"
assert_contains "the report names its side" "$OUT" "DEPLOY_REPORT_SIDE=official"
assert_contains "the report counts the official files" "$OUT" "DEPLOY_REPORT_OFFICIAL_FILES count=6"
assert_contains "the report counts the digest coverage" "$OUT" "DEPLOY_REPORT_OFFICIAL_SHA count=4"
assert_contains "the report counts the comparison rows" "$OUT" "DEPLOY_REPORT_COMPARE_ROWS rows=3"

echo "== 24_official.sh: the repository wiring =="

assert_contains "the orchestrator uses the shared decision base" \
  "$(cat "$ORCH")" "repro/lib/deploy.py"
assert_contains "the orchestrator exports MUJOCO_GL=egl" \
  "$(cat "$ORCH")" "MUJOCO_GL=egl"
assert_contains "the orchestrator guards against a mixed robot json" \
  "$(cat "$ORCH")" "mixed-json"
assert_contains "the decision base exposes the sha256sums reader" \
  "$(cat "$REPO_ROOT/repro/lib/deploy.py")" "def read_sha256sums"
assert_contains "the decision base builds the table from the summaries" \
  "$(cat "$REPO_ROOT/repro/lib/deploy.py")" "def summaries_to_rows"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
