#!/usr/bin/env bash
# repro/tests/test_deploy_sim2sim.sh — the OFFLINE battery of the sim2sim
# replay orchestrator (repro/22_sim2sim.sh).
#
# The battery drives the REAL orchestrator with a FAKE replay command (the
# SIM_RUN_TEMPLATE override): the stub stands in for
#
#     MUJOCO_GL=egl uv run --group export --frozen --offline python \
#         -m deploy.run --deploy ... --assets ... --robot ... --clip ...
#         --interface motion --video <mp4> --summary <json>
#
# so neither the container, nor a GPU, nor EGL, nor the real replay are
# needed.  The stub writes the summary json and the mp4 the upstream would
# write, and can be steered into every failure mode.
#
# Every negative scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# The decision itself is NOT stubbed: the summaries are parsed by the real
# decision base (repro/lib/deploy.py: parse_sim_summary / check_video) with
# the container's / the host's plain python3 (stdlib only).
#
# usage: bash repro/tests/test_deploy_sim2sim.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/repro/22_sim2sim.sh"

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
assert_absent() { # <label> <path>
  if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected path: $2"; fi
}
assert_file_count() { # <label> <dir> <glob> <expected>
  local n
  n="$(find "$2" -maxdepth 1 -type f -name "$3" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$1" "$4" "$n"
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the fake replay command ------------------------------------------------
# It understands the upstream's arguments and writes the artefacts:
#   --summary <json>   the summary the upstream writes
#   --video <mp4>      the mp4 the upstream writes
# The behaviour is steered by FAKE_RUN_MODE:
#   ok             the happy path
#   missing-field  the summary lacks body_err_mean_m
#   empty-value    the summary carries body_err_mean_m: null
#   malformed      the summary is not JSON
#   no-summary     the summary is not written at all
#   empty-video    the mp4 has zero bytes
#   no-video       the mp4 does not exist
#   nonzero        the command itself fails
# The behaviour is steered by STUB_HANG=1 as well: the stub then hangs
# forever, so the per-clip timeout of the orchestrator can be tested.
# Every invocation is recorded in $STUB_CALLS (one line per clip).
STUB="$TMP/stub_deploy_run.sh"
STUB_CALLS="$TMP/stub_calls.txt"
cat >"$STUB" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
summary=""
video=""
clip=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary) summary="$2"; shift 2 ;;
    --video) video="$2"; shift 2 ;;
    --clip) clip="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\tMUJOCO_GL=%s\n' "$clip" "${MUJOCO_GL:-<unset>}" >>"${STUB_CALLS:?}"

mode="${FAKE_RUN_MODE:-ok}"
if [ "${STUB_HANG:-0}" = "1" ]; then
  # simulate a hung replay: the process never finishes
  sleep 30
  exit 0
fi
if [ "$mode" = "nonzero" ]; then
  echo "fake deploy.run: the replay failed" >&2
  exit 7
fi

write_summary() {
  mkdir -p "$(dirname "$summary")"
  cat >"$summary"
}

case "$mode" in
  missing-field)
    write_summary <<'JSON'
{"robot": "g1_amber", "clip": "x", "frames": 10, "result": "completed",
 "joint_err_rms_rad": 0.12, "end_drift_m": 0.03}
JSON
    ;;
  empty-value)
    write_summary <<'JSON'
{"robot": "g1_amber", "clip": "x", "frames": 10, "result": "completed",
 "joint_err_rms_rad": 0.12, "body_err_mean_m": null, "end_drift_m": 0.03}
JSON
    ;;
  malformed)
    write_summary <<'JSON'
{robot: g1_amber, result: completed,
JSON
    ;;
  ok|empty-video|no-video)
    write_summary <<'JSON'
{"robot": "g1_amber", "clip": "x", "frames": 10, "result": "completed",
 "joint_err_rms_rad": 0.12, "body_err_mean_m": 0.04, "end_drift_m": 0.03}
JSON
    ;;
esac

case "$mode" in
  no-summary)
    rm -f "$summary"
    ;;
  empty-video)
    mkdir -p "$(dirname "$video")"
    : >"$video"
    ;;
  no-video)
    rm -f "$video"
    ;;
  *)
    mkdir -p "$(dirname "$video")"
    printf 'fake mp4 bytes\n' >"$video"
    ;;
esac
exit 0
STUB
chmod +x "$STUB"

# --- the fixtures -----------------------------------------------------------
ASSETS="$TMP/assets"
DEPLOY_DIR="$TMP/out/g1_amber"
OUT_DIR="$TMP/runs/sim2sim"
LOGS="$TMP/logs"
CLIP_LIST="$ASSETS/clips_g1_amber.txt"

mkdir -p "$ASSETS" "$DEPLOY_DIR" "$LOGS"
printf '<mujoco model="fake">\n  <worldbody/>\n</mujoco>\n' >"$ASSETS/g1_amber.xml"
printf 'fake onnx\n' >"$DEPLOY_DIR/policy.onnx"
{
  printf 'clips/g1_amber/clip_000__A000.npz\n'
  printf 'clips/g1_amber/clip_001__A001.npz\n'
  printf 'clips/g1_amber/clip_002__A002.npz\n'
} >"$CLIP_LIST"

EMPTY_CLIP_LIST="$TMP/empty_clips.txt"
: >"$EMPTY_CLIP_LIST"

RUN_TEMPLATE="$STUB --deploy {deploy} --assets {assets} --robot {robot} --clip {clip} --interface motion --video {video} --summary {summary}"

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
    DEPLOY_SIM_ALLOW_LOCAL=1 \
    STUB_CALLS="$STUB_CALLS" \
    FAKE_RUN_MODE="ok" \
    SIM_ASSETS_DIR="$ASSETS" \
    SIM_DEPLOY_DIR="$DEPLOY_DIR" \
    SIM_OUT_DIR="$OUT_DIR" \
    SIM_CLIP_LIST="$CLIP_LIST" \
    SIM_IMPORT_CMD="true" \
    SIM_RUN_TEMPLATE="$RUN_TEMPLATE" \
    SIM_LOG_DIR="$LOGS" \
    "${envs[@]+"${envs[@]}"}" \
    bash "$ORCH" "$sub" "$@" 2>&1)"
  RC=$?
}

stub_calls() { wc -l <"$STUB_CALLS" 2>/dev/null | tr -d ' '; }

echo "== 22_sim2sim.sh: the environment gate =="

run env
assert_rc_zero "env gate exits 0" "$RC"
assert_contains "env gate prints DEPLOY_SIM_ENV_OK" "$OUT" "DEPLOY_SIM_ENV_OK"
assert_contains "env gate reports the robot" "$OUT" "robot=g1_amber"
assert_contains "env gate reports the clip count" "$OUT" "clips=3"

run env SIM_IMPORT_CMD=false
assert_rc_nonzero "env gate fails when the import probe fails" "$RC"
assert_contains "env gate reports import-failed" "$OUT" "DEPLOY_SIM_ENV_FAIL reason=import-failed"
assert_not_contains "env gate prints no OK marker on an import failure" "$OUT" "_OK"

run env SIM_ASSETS_DIR="$TMP/nope"
assert_rc_nonzero "env gate fails without the assets directory" "$RC"
assert_contains "env gate reports assets-missing" "$OUT" "DEPLOY_SIM_ENV_FAIL reason=assets-missing"
assert_not_contains "env gate prints no OK marker without the assets" "$OUT" "_OK"

mkdir -p "$TMP/empty_assets"
run env SIM_ASSETS_DIR="$TMP/empty_assets"
assert_rc_nonzero "env gate fails without the scene xml" "$RC"
assert_contains "env gate reports assets-xml-missing" "$OUT" "DEPLOY_SIM_ENV_FAIL reason=assets-xml-missing"
assert_not_contains "env gate prints no OK marker without the scene xml" "$OUT" "_OK"

run env SIM_DEPLOY_DIR="$TMP/nothing"
assert_rc_nonzero "env gate fails without the ONNX policy" "$RC"
assert_contains "env gate reports policy-missing" "$OUT" "DEPLOY_SIM_ENV_FAIL reason=policy-missing"
assert_not_contains "env gate prints no OK marker without the policy" "$OUT" "_OK"

echo "== 22_sim2sim.sh: the replay =="

: >"$STUB_CALLS"
run run
assert_rc_zero "the replay exits 0" "$RC"
assert_contains "the replay prints DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"
assert_contains "the replay reports the clip count" "$OUT" "DEPLOY_SIM_OK clips=3"
assert_contains "the replay reports the completed count" "$OUT" "completed=3"
assert_contains "the replay reports the video count" "$OUT" "video_ok=3"
assert_eq "every clip of the list was replayed" "3" "$(stub_calls)"
assert_contains "the replay exports MUJOCO_GL=egl itself" "$(cat "$STUB_CALLS")" "MUJOCO_GL=egl"
assert_file_count "one summary per clip was written" "$OUT_DIR/summary" '*.json' 3
assert_file_count "one video per clip was written" "$OUT_DIR/video" '*.mp4' 3
assert_nonempty_file "the first summary is non-empty" "$OUT_DIR/summary/clip_000__A000.json"
assert_nonempty_file "the first video is non-empty" "$OUT_DIR/video/clip_000__A000.mp4"
assert_nonempty_file "the timings file is written" "$OUT_DIR/timings.tsv"
assert_contains "the timings file records the result of every clip" \
  "$(cat "$OUT_DIR/timings.tsv")" "completed"
assert_contains "the summary carries the drift number" \
  "$(cat "$OUT_DIR/summary/clip_000__A000.json")" "end_drift_m"

echo "== 22_sim2sim.sh: the negative paths =="

: >"$STUB_CALLS"
run run FAKE_RUN_MODE=missing-field
assert_rc_nonzero "the replay fails when a summary field is missing" "$RC"
assert_contains "the replay reports summary-field-missing" "$OUT" "DEPLOY_SIM_FAIL reason=summary-field-missing"
assert_contains "the replay names the failed clip" "$OUT" "DEPLOY_SIM_CLIP_FAILED clip=clip_000__A000"
assert_not_contains "a missing field prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"
assert_not_contains "a missing field prints no DEPLOY_SIM_ENV_OK" "$OUT" "DEPLOY_SIM_ENV_OK"

run run FAKE_RUN_MODE=empty-value
assert_rc_nonzero "the replay fails when a summary value is empty" "$RC"
assert_contains "the replay reports summary-value-empty" "$OUT" "DEPLOY_SIM_FAIL reason=summary-value-empty"
assert_not_contains "an empty value prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run FAKE_RUN_MODE=malformed
assert_rc_nonzero "the replay fails when the summary is malformed" "$RC"
assert_contains "the replay reports summary-parse-failed" "$OUT" "DEPLOY_SIM_FAIL reason=summary-parse-failed"
assert_not_contains "a malformed summary prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run FAKE_RUN_MODE=no-summary
assert_rc_nonzero "the replay fails when the summary is missing" "$RC"
assert_contains "the replay reports summary-missing" "$OUT" "DEPLOY_SIM_FAIL reason=summary-missing"
assert_not_contains "a missing summary prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run FAKE_RUN_MODE=empty-video
assert_rc_nonzero "the replay fails when the video is empty" "$RC"
assert_contains "the replay reports video-empty" "$OUT" "DEPLOY_SIM_FAIL reason=video-empty"
assert_not_contains "an empty video prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run FAKE_RUN_MODE=no-video
assert_rc_nonzero "the replay fails when the video is missing" "$RC"
assert_contains "the replay reports video-missing" "$OUT" "DEPLOY_SIM_FAIL reason=video-missing"
assert_not_contains "a missing video prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run FAKE_RUN_MODE=nonzero
assert_rc_nonzero "the replay fails when the replay command exits non-zero" "$RC"
assert_contains "the replay reports run-failed" "$OUT" "DEPLOY_SIM_FAIL reason=run-failed"
assert_not_contains "a failing replay prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

# a hung clip must not stall the replay: the per-clip wall clock is bounded
# and the timeout has its own fixed reason.
run run SIM_CLIP_TIMEOUT=1 STUB_HANG=1
assert_rc_nonzero "the replay fails when a clip times out" "$RC"
assert_contains "the replay reports replay-timeout" "$OUT" "DEPLOY_SIM_FAIL reason=replay-timeout"
assert_not_contains "a timed-out replay prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run SIM_CLIP_LIST="$TMP/nope.txt"
assert_rc_nonzero "the replay fails without a clip list" "$RC"
assert_contains "the replay reports clip-list-missing" "$OUT" "DEPLOY_SIM_FAIL reason=clip-list-missing"
assert_not_contains "a missing clip list prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

run run SIM_CLIP_LIST="$EMPTY_CLIP_LIST"
assert_rc_nonzero "the replay fails on an empty clip list" "$RC"
assert_contains "the replay reports clip-list-empty" "$OUT" "DEPLOY_SIM_FAIL reason=clip-list-empty"
assert_not_contains "an empty clip list prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"

: >"$STUB_CALLS"
run run SIM_IMPORT_CMD=false
assert_rc_nonzero "the replay fails when the environment gate fails" "$RC"
assert_contains "the replay reports the environment gate reason" "$OUT" "DEPLOY_SIM_FAIL reason=import-failed"
assert_not_contains "a failed environment gate prints no DEPLOY_SIM_OK" "$OUT" "DEPLOY_SIM_OK"
assert_eq "a failed environment gate replays no clip" "0" "$(stub_calls)"

echo "== 22_sim2sim.sh: the options =="

: >"$STUB_CALLS"
rm -rf "$OUT_DIR/summary" "$OUT_DIR/video"
run run --limit 1
assert_rc_zero "the limited replay exits 0" "$RC"
assert_contains "the limited replay reports one clip" "$OUT" "DEPLOY_SIM_OK clips=1"
assert_eq "the limited replay replays one clip" "1" "$(stub_calls)"
assert_file_count "the limited replay writes one summary" "$OUT_DIR/summary" '*.json' 1

echo "== 22_sim2sim.sh: the report =="

run report
assert_rc_zero "report exits 0" "$RC"
assert_contains "report names its side" "$OUT" "DEPLOY_REPORT_SIDE=sim"
assert_contains "report prints the clip count" "$OUT" "DEPLOY_REPORT_CLIPS count=3"
assert_contains "report prints the summary count" "$OUT" "DEPLOY_REPORT_SUMMARY count=1"
assert_contains "report prints the wall clock" "$OUT" "DEPLOY_REPORT_WALLCLOCK"
assert_contains "report prints the completion count" "$OUT" "DEPLOY_REPORT_COMPLETION"

echo "== 22_sim2sim.sh: the repository wiring =="

assert_contains "the seed store links the runs directory" \
  "$(cat "$REPO_ROOT/repro/lib/seed_store.sh")" "for link in data logs out assets runs"
assert_contains "common.sh links the runs directory" \
  "$(cat "$REPO_ROOT/repro/lib/common.sh")" "seed_store_link runs"
assert_contains "the replay artefacts are git-ignored" \
  "$(cat "$REPO_ROOT/.gitignore")" "/runs/"
assert_contains "the orchestrator exports MUJOCO_GL=egl" \
  "$(cat "$ORCH")" "MUJOCO_GL=egl"
assert_contains "the orchestrator uses the shared decision base" \
  "$(cat "$ORCH")" "repro/lib/deploy.py"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
