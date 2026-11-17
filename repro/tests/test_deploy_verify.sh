#!/usr/bin/env bash
# repro/tests/test_deploy_verify.sh — the OFFLINE battery of the READ-ONLY
# terminal reviewer (repro/26_deploy_verify.sh, slice S08 task T7).
#
# The battery drives the REAL reviewer with FAKE artefacts: a two-clip
# assets tree, two sim2sim summaries + videos, two eval CSVs, an official
# policy directory with a real SHA256SUMS, a comparison table and a PICO
# session npz.  Every artefact is written with the plain python3 (stdlib
# only -- the npz fixtures are written with struct + zipfile, so numpy is
# not needed anywhere), so neither the container, nor a GPU, nor EGL, nor
# the real replay are needed.
#
# Every negative scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# The decisions themselves are NOT stubbed: the assets contract, the summary
# contract, the eval CSV contract, the SHA-256 recomputation, the comparison
# table, the PICO session shapes and the replay summary are all decided by
# the real decision base (repro/lib/deploy.py).
#
# usage: bash repro/tests/test_deploy_verify.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEWER="$REPO_ROOT/repro/26_deploy_verify.sh"

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="$TMP/base"
WORK="$TMP/work"

# ---------------------------------------------------------------------------
# the fixture
# ---------------------------------------------------------------------------
build_fixture() { # <root>
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  python3 - "$root" <<'PY'
import hashlib, json, os, struct, sys, zipfile

root = sys.argv[1]
CLIPS = ["clip_a__A000", "clip_b__A001"]


def write(path, data, binary=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if binary else "w"
    with open(path, mode) as handle:
        handle.write(data)


def npy(shape):
    count = 1
    for value in shape:
        count *= value
    header = "{'descr': '<f8', 'fortran_order': False, 'shape': (%s), }" % (
        ",".join(str(value) for value in shape))
    pad = 64 - ((10 + len(header) + 1) % 64)
    header = header + " " * (pad - 1) + "\n"
    return (b"\x93NUMPY" + bytes([1, 0]) + struct.pack("<H", len(header))
            + header.encode("latin-1") + b"\x00" * (count * 8))


def build_session(path, body_shape=(4, 24, 7)):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("t_ns.npy", npy((body_shape[0],)))
        archive.writestr("body.npy", npy(body_shape))
        archive.writestr("buttons.npy", npy((body_shape[0], 5)))


# --- assets ---------------------------------------------------------------
write(root + "/assets/g1_amber.xml", "<mujoco/>\n")
write(root + "/assets/meshes/g1_amber/mesh_0.stl", "solid mesh\n")
for clip in CLIPS:
    write(root + "/assets/clips/g1_amber/%s.npz" % clip, b"PK\x03\x04fake-npz",
          binary=True)
write(root + "/assets/clips_g1_amber.txt",
      "".join("clips/g1_amber/%s.npz\n" % clip for clip in CLIPS))

# --- sim2sim replays -----------------------------------------------------
for clip in CLIPS:
    summary = {
        "robot": "g1_amber",
        "clip": clip,
        "frames": 120,
        "result": "completed",
        "joint_err_rms_rad": 0.11,
        "body_err_mean_m": 0.021,
        "end_drift_m": 0.031,
        "video": "/remote/container/path/%s.mp4" % clip,
        "interface": "motion",
    }
    write(root + "/runs/sim2sim/summary/%s.json" % clip, json.dumps(summary, indent=1))
    write(root + "/runs/sim2sim/video/%s.mp4" % clip, b"fake-mp4-bytes", binary=True)

# --- eval tables ---------------------------------------------------------
header = "name,frames,failed,fail_frame,norm_return,steps"
rows = ["%s,120,False,-1,0.5,119" % clip for clip in CLIPS]
for name in ("eval_motion_1h.csv", "eval_human_full_1h.csv"):
    write(root + "/runs/eval/" + name, header + "\n" + "\n".join(rows) + "\n")

# --- official weights ----------------------------------------------------
official = root + "/runs/official/morphmimic_policy"
os.makedirs(official, exist_ok=True)
write(official + "/policy.onnx", b"fake-onnx-policy", binary=True)
write(official + "/g1_amber.json", '{"normalizer": {}}\n')
write(official + "/x2.json", '{"normalizer": {}}\n')
write(official + "/t2.json", '{"normalizer": {}}\n')
write(official + "/MANIFEST.txt", "morphmimic policy v0.1\n")
sums = []
for name in ("policy.onnx", "g1_amber.json", "x2.json", "t2.json"):
    digest = hashlib.sha256(open(os.path.join(official, name), "rb").read()).hexdigest()
    sums.append("%s  %s\n" % (digest, name))
write(official + "/SHA256SUMS", "".join(sums))

# --- the self-vs-official comparison table -------------------------------
compare_header = ("clip,frames,self_result,self_joint_err_rms_rad,self_body_err_mean_m,"
                  "self_end_drift_m,official_result,official_joint_err_rms_rad,"
                  "official_body_err_mean_m,official_end_drift_m,delta_joint_err_rms_rad,"
                  "delta_body_err_mean_m,delta_end_drift_m")
compare_rows = []
for clip in CLIPS:
    compare_rows.append(",".join([
        clip, "120", "completed", "0.1", "0.02", "0.03",
        "completed", "0.08", "0.03", "0.05",
        "0.02", "-0.01", "-0.02"]))
write(root + "/runs/official/compare_self_vs_official.csv",
      compare_header + "\n" + "\n".join(compare_rows) + "\n")

# --- the human interface artefacts ---------------------------------------
build_session(root + "/runs/human/session.npz")
write(root + "/runs/human/replay_summary.json", json.dumps({
    "robot": "g1_amber",
    "mode": "teleop",
    "steps": 700,
    "seconds": 14.1,
    "falls": 0,
    "travel_along_m": -0.168,
    "video": "/remote/container/path/runs/human/replay.mp4",
    "interface": "human full",
}, indent=1))
write(root + "/runs/human/replay.mp4", b"fake-replay-mp4", binary=True)
PY
}

# ---------------------------------------------------------------------------
# the runner
# ---------------------------------------------------------------------------
OUT=""
RC=0

run_reviewer() { # <root>
  local root="$1"
  OUT="$(DEPLOY_ALLOW_LOCAL=1 \
    DEPLOY_ASSETS_DIR="$root/assets" \
    DEPLOY_CLIP_LIST="$root/assets/clips_g1_amber.txt" \
    DEPLOY_SIM_DIR="$root/runs/sim2sim" \
    DEPLOY_EVAL_DIR="$root/runs/eval" \
    DEPLOY_EVAL_EXPECT_ROWS=2 \
    DEPLOY_SUBSET_YAML="$root/no-such-subset.yaml" \
    DEPLOY_OFFICIAL_DIR="$root/runs/official/morphmimic_policy" \
    DEPLOY_COMPARE_CSV="$root/runs/official/compare_self_vs_official.csv" \
    DEPLOY_HUMAN_DIR="$root/runs/human" \
    DEPLOY_LOG_DIR="$root/logs" \
    bash "$REVIEWER" verify 2>&1)"
  RC=$?
}

# negative_case <label> <expected reason> <mutation function>
negative_case() {
  local label="$1" reason="$2" mutation="$3"
  rm -rf "$WORK"
  cp -a "$BASE" "$WORK"
  "$mutation" "$WORK"
  run_reviewer "$WORK"
  assert_rc_nonzero "$label: exits non-zero" "$RC"
  assert_contains "$label: reports reason=$reason" "$OUT" \
    "DEPLOY_VERIFY_FAIL reason=$reason"
  assert_not_contains "$label: prints no OK marker" "$OUT" "DEPLOY_VERIFY_OK"
}

# --- the mutations --------------------------------------------------------
mut_missing_assets() { rm -rf "$1/assets"; }
mut_missing_xml() { rm -f "$1/assets/g1_amber.xml"; }
mut_empty_xml() { : >"$1/assets/g1_amber.xml"; }
mut_missing_clip() {
  # the listed clip is gone; another clip keeps the COUNT equal, so the
  # failure can only be the missing LISTED clip
  rm -f "$1/assets/clips/g1_amber/clip_b__A001.npz"
  touch "$1/assets/clips/g1_amber/clip_x.npz"
}
mut_empty_clip() { : >"$1/assets/clips/g1_amber/clip_b__A001.npz"; }
mut_missing_clip_list() { rm -f "$1/assets/clips_g1_amber.txt"; }
mut_empty_clip_list() { : >"$1/assets/clips_g1_amber.txt"; }
mut_missing_meshes() { rm -rf "$1/assets/meshes"; }
mut_clip_count_mismatch() { rm -f "$1/assets/clips/g1_amber/clip_b__A001.npz"; }
mut_missing_summaries() { rm -rf "$1/runs/sim2sim/summary"; }
mut_summary_field_missing() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1] + "/runs/sim2sim/summary/clip_a__A000.json"
data = json.load(open(path))
del data["end_drift_m"]
json.dump(data, open(path, "w"))
PY
}
mut_summary_value_empty() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1] + "/runs/sim2sim/summary/clip_a__A000.json"
data = json.load(open(path))
data["body_err_mean_m"] = None
json.dump(data, open(path, "w"))
PY
}
mut_summary_parse_failed() { printf 'not json at all' >"$1/runs/sim2sim/summary/clip_a__A000.json"; }
mut_missing_video() { rm -f "$1/runs/sim2sim/video/clip_a__A000.mp4"; }
mut_empty_video() { : >"$1/runs/sim2sim/video/clip_a__A000.mp4"; }
mut_unknown_clip() {
  python3 - "$1" <<'PY'
import json, os, sys
root = sys.argv[1]
path = root + "/runs/sim2sim/summary/clip_a__A000.json"
data = json.load(open(path))
data["clip"] = "clip_z__A999"
json.dump(data, open(path, "w"))
write = open(root + "/runs/sim2sim/video/clip_z__A999.mp4", "wb")
write.write(b"fake-mp4-bytes")
write.close()
PY
}
mut_extra_summary() {
  python3 - "$1" <<'PY'
import json, sys
root = sys.argv[1]
summary = {
    "robot": "g1_amber", "clip": "clip_c__A002", "frames": 10,
    "result": "completed", "joint_err_rms_rad": 0.1,
    "body_err_mean_m": 0.01, "end_drift_m": 0.02,
    "video": "/remote/x.mp4", "interface": "motion",
}
with open(root + "/runs/sim2sim/summary/clip_c__A002.json", "w") as handle:
    json.dump(summary, handle)
with open(root + "/runs/sim2sim/video/clip_c__A002.mp4", "wb") as handle:
    handle.write(b"fake")
PY
}
mut_missing_eval_csv() { rm -f "$1/runs/eval/eval_motion_1h.csv"; }
mut_eval_header_broken() {
  printf 'name,frames,other,fail_frame,norm_return,steps\nclip_a,120,x,-1,0.5,119\n' \
    >"$1/runs/eval/eval_motion_1h.csv"
}
mut_eval_row_count() {
  printf 'name,frames,failed,fail_frame,norm_return,steps\nclip_a,120,False,-1,0.5,119\n' \
    >"$1/runs/eval/eval_motion_1h.csv"
}
mut_eval_failed_unparsable() {
  printf 'name,frames,failed,fail_frame,norm_return,steps\nclip_a,120,maybe,-1,0.5,119\nclip_b,120,maybe,-1,0.5,119\n' \
    >"$1/runs/eval/eval_motion_1h.csv"
}
mut_missing_official_dir() { rm -rf "$1/runs/official/morphmimic_policy"; }
mut_missing_sha() { rm -f "$1/runs/official/morphmimic_policy/SHA256SUMS"; }
mut_sha_mismatch() { printf 'tampered' >>"$1/runs/official/morphmimic_policy/policy.onnx"; }
mut_sha_not_covering() {
  grep -v 'policy.onnx' "$1/runs/official/morphmimic_policy/SHA256SUMS" \
    >"$1/runs/official/morphmimic_policy/SHA256SUMS.new"
  mv "$1/runs/official/morphmimic_policy/SHA256SUMS.new" \
    "$1/runs/official/morphmimic_policy/SHA256SUMS"
}
mut_missing_onnx() {
  rm -f "$1/runs/official/morphmimic_policy/policy.onnx"
  grep -v 'policy.onnx' "$1/runs/official/morphmimic_policy/SHA256SUMS" \
    >"$1/runs/official/morphmimic_policy/SHA256SUMS.new"
  mv "$1/runs/official/morphmimic_policy/SHA256SUMS.new" \
    "$1/runs/official/morphmimic_policy/SHA256SUMS"
}
mut_missing_json() {
  rm -f "$1/runs/official/morphmimic_policy/g1_amber.json" \
    "$1/runs/official/morphmimic_policy/x2.json" \
    "$1/runs/official/morphmimic_policy/t2.json"
  grep -v -e 'g1_amber.json' -e 'x2.json' -e 't2.json' \
    "$1/runs/official/morphmimic_policy/SHA256SUMS" \
    >"$1/runs/official/morphmimic_policy/SHA256SUMS.new"
  mv "$1/runs/official/morphmimic_policy/SHA256SUMS.new" \
    "$1/runs/official/morphmimic_policy/SHA256SUMS"
}
mut_missing_compare() { rm -f "$1/runs/official/compare_self_vs_official.csv"; }
mut_compare_header_broken() { printf 'clip,frames\nclip_a,120\n' >"$1/runs/official/compare_self_vs_official.csv"; }
mut_compare_row_count() {
  head -n 2 "$1/runs/official/compare_self_vs_official.csv" \
    >"$1/runs/official/compare_self_vs_official.csv.new"
  mv "$1/runs/official/compare_self_vs_official.csv.new" \
    "$1/runs/official/compare_self_vs_official.csv"
}
mut_missing_session() { rm -f "$1/runs/human/session.npz"; }
mut_session_format_invalid() { printf 'not a zip' >"$1/runs/human/session.npz"; }
mut_session_shape_invalid() {
  python3 - "$1" <<'PY'
import os, struct, sys, zipfile
root = sys.argv[1]
path = root + "/runs/human/session.npz"


def npy(shape):
    count = 1
    for value in shape:
        count *= value
    header = "{'descr': '<f8', 'fortran_order': False, 'shape': (%s), }" % (
        ",".join(str(value) for value in shape))
    pad = 64 - ((10 + len(header) + 1) % 64)
    header = header + " " * (pad - 1) + "\n"
    return (b"\x93NUMPY" + bytes([1, 0]) + struct.pack("<H", len(header))
            + header.encode("latin-1") + b"\x00" * (count * 8))


with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("t_ns.npy", npy((4,)))
    archive.writestr("body.npy", npy((4, 7, 7)))
    archive.writestr("buttons.npy", npy((4, 5)))
PY
}
mut_missing_replay_summary() { rm -f "$1/runs/human/replay_summary.json"; }
mut_empty_replay_summary() { : >"$1/runs/human/replay_summary.json"; }
mut_replay_field_missing() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1] + "/runs/human/replay_summary.json"
data = json.load(open(path))
del data["steps"]
json.dump(data, open(path, "w"))
PY
}
mut_replay_value_empty() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1] + "/runs/human/replay_summary.json"
data = json.load(open(path))
data["steps"] = 0
json.dump(data, open(path, "w"))
PY
}
mut_missing_human_video() { rm -f "$1/runs/human/replay.mp4"; }
mut_empty_human_video() { : >"$1/runs/human/replay.mp4"; }

# ---------------------------------------------------------------------------
# the positive case
# ---------------------------------------------------------------------------
build_fixture "$BASE"
run_reviewer "$BASE"
assert_rc_zero "the positive fixture exits 0" "$RC"
assert_contains "the positive fixture prints the OK marker" "$OUT" "DEPLOY_VERIFY_OK"
assert_contains "the OK marker reports the asset clip count" "$OUT" "assets_clips=2"
assert_contains "the OK marker reports the sim2sim clip count" "$OUT" "sim_clips=2"
assert_contains "the OK marker reports the motion eval rows" "$OUT" "eval_motion_rows=2"
assert_contains "the OK marker reports the human eval rows" "$OUT" "eval_human_rows=2"
assert_contains "the OK marker reports the official sha files" "$OUT" "official_sha_files=4"
assert_contains "the OK marker reports the comparison rows" "$OUT" "compare_rows=2"
assert_contains "the OK marker reports the human steps" "$OUT" "human_steps=700"
assert_eq "the positive fixture prints exactly one OK marker" "1" \
  "$(printf '%s\n' "$OUT" | grep -c '^DEPLOY_VERIFY_OK ')"

# the report sub-command prints the DEPLOY_REPORT_* facts
REPORT_OUT="$(DEPLOY_ALLOW_LOCAL=1 \
  DEPLOY_ASSETS_DIR="$BASE/assets" \
  DEPLOY_CLIP_LIST="$BASE/assets/clips_g1_amber.txt" \
  DEPLOY_SIM_DIR="$BASE/runs/sim2sim" \
  DEPLOY_EVAL_DIR="$BASE/runs/eval" \
  DEPLOY_EVAL_EXPECT_ROWS=2 \
  DEPLOY_SUBSET_YAML="$BASE/no-such-subset.yaml" \
  DEPLOY_OFFICIAL_DIR="$BASE/runs/official/morphmimic_policy" \
  DEPLOY_COMPARE_CSV="$BASE/runs/official/compare_self_vs_official.csv" \
  DEPLOY_HUMAN_DIR="$BASE/runs/human" \
  DEPLOY_LOG_DIR="$BASE/logs" \
  bash "$REVIEWER" report 2>&1)"
assert_contains "the report prints the assets line" "$REPORT_OUT" "DEPLOY_REPORT_ASSETS"
assert_contains "the report prints the sim2sim line" "$REPORT_OUT" "DEPLOY_REPORT_SIM"
assert_contains "the report prints the eval line" "$REPORT_OUT" "DEPLOY_REPORT_EVAL"
assert_contains "the report prints the official line" "$REPORT_OUT" "DEPLOY_REPORT_OFFICIAL"
assert_contains "the report prints the comparison line" "$REPORT_OUT" "DEPLOY_REPORT_COMPARE"
assert_contains "the report prints the human line" "$REPORT_OUT" "DEPLOY_REPORT_HUMAN"
assert_not_contains "the report prints no gate marker" "$REPORT_OUT" "DEPLOY_VERIFY_OK"
assert_contains "the report keeps the raw sha256sum transcript" "$REPORT_OUT" "policy.onnx: OK"

# the reviewer never writes into the artefacts it inspects
BEFORE="$(find "$BASE" -type f ! -path '*/logs/*' -printf '%p %s\n' | sort | md5sum)"
run_reviewer "$BASE"
AFTER="$(find "$BASE" -type f ! -path '*/logs/*' -printf '%p %s\n' | sort | md5sum)"
assert_eq "the reviewer does not touch the artefacts" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
# the negative battery
# ---------------------------------------------------------------------------
negative_case "the assets directory is missing" "assets-missing" mut_missing_assets
negative_case "the scene xml is missing" "assets-xml-missing" mut_missing_xml
negative_case "the scene xml is empty" "assets-xml-empty" mut_empty_xml
negative_case "a listed clip is missing" "assets-clips-missing" mut_missing_clip
negative_case "a listed clip is empty" "assets-clip-empty" mut_empty_clip
negative_case "the clip list is missing" "clip-list-missing" mut_missing_clip_list
negative_case "the clip list is empty" "clip-list-empty" mut_empty_clip_list
negative_case "the meshes are missing" "assets-meshes-missing" mut_missing_meshes
negative_case "the clip count differs from the list" "assets-clips-mismatch" mut_clip_count_mismatch
negative_case "the sim2sim summaries are missing" "summary-missing" mut_missing_summaries
negative_case "a summary field is missing" "summary-field-missing" mut_summary_field_missing
negative_case "a summary value is empty" "summary-value-empty" mut_summary_value_empty
negative_case "a summary is not parsable" "summary-parse-failed" mut_summary_parse_failed
negative_case "a clip has no video" "video-missing" mut_missing_video
negative_case "a clip video is empty" "video-empty" mut_empty_video
negative_case "a summary names an unknown clip" "summary-clip-unknown" mut_unknown_clip
negative_case "there are more summaries than clips" "summary-count-mismatch" mut_extra_summary
negative_case "the eval CSV is missing" "eval-csv-missing" mut_missing_eval_csv
negative_case "the eval CSV header is broken" "eval-csv-parse-failed" mut_eval_header_broken
negative_case "the eval CSV row count differs" "eval-row-count-mismatch" mut_eval_row_count
negative_case "the eval failed column is unparsable" "eval-csv-parse-failed" mut_eval_failed_unparsable
negative_case "the official directory is missing" "official-dir-missing" mut_missing_official_dir
negative_case "the official SHA256SUMS is missing" "official-sha-missing" mut_missing_sha
negative_case "an official digest does not match" "official-sha-mismatch" mut_sha_mismatch
negative_case "the SHA256SUMS does not cover policy.onnx" "official-sha-missing" mut_sha_not_covering
negative_case "the official policy.onnx is missing" "official-onnx-missing" mut_missing_onnx
negative_case "the official robot json is missing" "official-json-missing" mut_missing_json
negative_case "the comparison table is missing" "compare-missing" mut_missing_compare
negative_case "the comparison header is broken" "compare-parse-failed" mut_compare_header_broken
negative_case "the comparison row count differs" "compare-row-mismatch" mut_compare_row_count
negative_case "the session is missing" "session-missing" mut_missing_session
negative_case "the session is not a npz" "session-format-invalid" mut_session_format_invalid
negative_case "the session body shape is wrong" "session-shape-invalid" mut_session_shape_invalid
negative_case "the replay summary is missing" "replay-summary-missing" mut_missing_replay_summary
negative_case "the replay summary is empty" "replay-summary-empty" mut_empty_replay_summary
negative_case "the replay summary field is missing" "summary-field-missing" mut_replay_field_missing
negative_case "the replay summary value is empty" "summary-value-empty" mut_replay_value_empty
negative_case "the replay video is missing" "video-missing" mut_missing_human_video
negative_case "the replay video is empty" "video-empty" mut_empty_human_video

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
