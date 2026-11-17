#!/usr/bin/env bash
# repro/tests/test_deploy_human.sh — the OFFLINE battery of the human
# interface replay orchestrator (repro/25_human_replay.sh).
#
# The battery drives the REAL orchestrator with FAKE commands (the
# HUMAN_IMPORT_CMD / HUMAN_SESSION_CMD / HUMAN_RUN_TEMPLATE overrides): the
# stubs stand in for
#
#     uv run --group export --group teleop python \
#         -m deploy.tools.make_gmr_session <session.npz> --clip <clip npz>
#     MUJOCO_GL=egl uv run --group export --group teleop python \
#         -m deploy.run --deploy ... --assets ... --robot ... --teleop \
#         --replay <session.npz> --interface human --human-points full \
#         --max-steps N --video <mp4> --summary <json>
#
# so neither the container, nor a GPU, nor EGL, nor the real replay are
# needed.  The stubs write the artefacts the upstream would write (a PICO
# npz, the teleop summary json, the mp4) and can be steered into every
# failure mode.
#
# Every negative scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# The decisions themselves are NOT stubbed: the session's array shapes, the
# summary's fields and the video's size are decided by the real decision
# base (repro/lib/deploy.py: verify_session / verify_session_arrays /
# verify_human_replay_summary / check_video) with the plain python3
# (stdlib only -- the npz fixtures are written with struct + zipfile, so no
# numpy is needed anywhere).
#
# usage: bash repro/tests/test_deploy_human.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/repro/25_human_replay.sh"

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

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the npz fixture writer ------------------------------------------------
# Writes a PICO recording (t_ns / body / buttons) with the shapes asked for.
# The .npy headers are written by hand (struct + zipfile): the standard
# library only, so the fixture works with the container's plain python3 too.
#
#   write_npz <out.npz> <body shape, e.g. 3x24x7> <samples>
#
# FAKE_SESSION_SHAPE overrides the body shape, FAKE_SESSION_SAMPLES the
# sample count.
NPZ_WRITER="$TMP/write_npz.py"
cat >"$NPZ_WRITER" <<'PY'
import os
import struct
import sys
import zipfile

out = sys.argv[1]
shape = os.environ.get("FAKE_SESSION_SHAPE", "3x24x7")
samples = int(os.environ.get("FAKE_SESSION_SAMPLES", "3"))
dims = [int(v) for v in shape.split("x")]


def member(archive, name, header_shape, values):
  shape_text = "(" + "".join("%d, " % d for d in header_shape) + ")"
  header = ("{'descr': '<f8', 'fortran_order': False, 'shape': %s, }"
            % shape_text).encode("latin-1")
  pad = (64 - ((10 + len(header) + 1) % 64)) % 64
  header += b" " * pad + b"\n"
  archive.writestr(name, b"\x93NUMPY" + bytes([1, 0]) +
                   struct.pack("<H", len(header)) + header + values)


with zipfile.ZipFile(out, "w") as archive:
  body_dims = dims if dims else [samples, 24, 7]
  count = 1
  for d in body_dims:
    count *= d
  member(archive, "body.npy", body_dims,
         struct.pack("<%dd" % count, *[0.5] * count))
  member(archive, "t_ns.npy", [samples],
         struct.pack("<%dq" % samples, *[1000 * i for i in range(samples)]))
  member(archive, "buttons.npy", [samples, 5],
         struct.pack("<%dd" % (samples * 5), *[0.0] * (samples * 5)))
print("wrote", out)
PY

# --- the fake make_gmr_session --------------------------------------------
STUB_SESSION="$TMP/stub_make_gmr_session.sh"
cat >"$STUB_SESSION" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
session=""
clip=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --clip) clip="$2"; shift 2 ;;
    *) if [ -z "$session" ]; then session="$1"; fi; shift ;;
  esac
done
printf 'fake make_gmr_session: clip=%s session=%s\n' "$clip" "$session" >>"${STUB_CALLS:?}"
if [ "${FAKE_SESSION_MODE:-ok}" = "fail" ]; then
  echo "fake make_gmr_session: failed" >&2
  exit 3
fi
if [ "${FAKE_SESSION_MODE:-ok}" = "no-session" ]; then
  exit 0
fi
mkdir -p "$(dirname "$session")"
python3 "${NPZ_WRITER:?}" "$session"
exit 0
STUB
chmod +x "$STUB_SESSION"

# --- the fake deploy.run ---------------------------------------------------
# It understands the upstream's arguments and writes the artefacts:
#   --summary <json>   the teleop summary the upstream writes
#   --video <mp4>      the mp4 the upstream writes
# The behaviour is steered by FAKE_RUN_MODE:
#   ok              the happy path
#   missing-summary the summary is not written at all
#   empty-summary   the summary file is empty
#   missing-field   the summary lacks travel_along_m
#   empty-value     the summary carries steps: null
#   malformed       the summary is not JSON
#   empty-video     the mp4 has zero bytes
#   no-video        the mp4 does not exist
#   nonzero         the command itself fails
# FAKE_RUN_HANG=1 makes the stub hang forever (the replay timeout).
STUB_RUN="$TMP/stub_deploy_run.sh"
STUB_CALLS="$TMP/stub_calls.txt"
cat >"$STUB_RUN" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
summary=""
video=""
replay=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary) summary="$2"; shift 2 ;;
    --video) video="$2"; shift 2 ;;
    --replay) replay="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\tMUJOCO_GL=%s\n' "$replay" "${MUJOCO_GL:-<unset>}" >>"${STUB_CALLS:?}"

mode="${FAKE_RUN_MODE:-ok}"
if [ "${FAKE_RUN_HANG:-0}" = "1" ]; then
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
{"robot": "g1_amber", "mode": "teleop", "steps": 700, "falls": 0,
 "travel_across_m": 0.0, "turn_deg": 0.0, "joint_err_rms_rad": null}
JSON
    ;;
  empty-value)
    write_summary <<'JSON'
{"robot": "g1_amber", "mode": "teleop", "steps": null, "falls": 0,
 "travel_along_m": 0.0, "joint_err_rms_rad": null}
JSON
    ;;
  malformed)
    write_summary <<'JSON'
{robot: g1_amber, steps: 700,
JSON
    ;;
  empty-summary)
    mkdir -p "$(dirname "$summary")"
    : >"$summary"
    ;;
  ok|empty-video|no-video|missing-summary)
    write_summary <<'JSON'
{"robot": "g1_amber", "mode": "teleop", "steps": 700, "seconds": 14.0,
 "falls": 0, "travel_along_m": 0.12, "travel_across_m": -0.03,
 "turn_deg": 1.5, "joint_err_rms_rad": null, "joint_err_p95_rad": null,
 "delay_ms": 0.0}
JSON
    ;;
esac

case "$mode" in
  missing-summary)
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
chmod +x "$STUB_RUN"

# --- the fixtures ----------------------------------------------------------
ASSETS="$TMP/assets"
DEPLOY_DIR="$TMP/out/g1_amber"
OUT_DIR="$TMP/runs/human"
LOGS="$TMP/logs"
SUBSET="$TMP/subsets/1h.yaml"
DATA_ROOT="$TMP/data/seed_g1_npz50"

mkdir -p "$ASSETS" "$DEPLOY_DIR" "$LOGS" "$(dirname "$SUBSET")" "$DATA_ROOT/220713"
printf '<mujoco model="fake">\n  <worldbody/>\n</mujoco>\n' >"$ASSETS/g1_amber.xml"
printf 'fake onnx\n' >"$DEPLOY_DIR/policy.onnx"
printf '{"human_interface": true}\n' >"$DEPLOY_DIR/g1_amber.json"
printf 'fake clip bytes\n' >"$DATA_ROOT/220713/clip_000__A000.npz"
cat >"$SUBSET" <<'YAML'
root: PLACEHOLDER
hours: 1.0
clips:
- 220713/clip_000__A000.npz
YAML
sed -i "s|^root: PLACEHOLDER|root: $DATA_ROOT|" "$SUBSET"

SESSION_TEMPLATE="bash $STUB_SESSION {session} --clip {clip}"
RUN_TEMPLATE="bash $STUB_RUN --deploy {deploy} --assets {assets} --robot {robot} --replay {replay} --interface human --human-points full --max-steps {steps} --video {video} --summary {summary}"

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
    HUMAN_ALLOW_LOCAL=1 \
    STUB_CALLS="$STUB_CALLS" \
    NPZ_WRITER="$NPZ_WRITER" \
    FAKE_SESSION_MODE="ok" \
    FAKE_RUN_MODE="ok" \
    HUMAN_ASSETS_DIR="$ASSETS" \
    HUMAN_DEPLOY_DIR="$DEPLOY_DIR" \
    HUMAN_OUT_DIR="$OUT_DIR" \
    HUMAN_SUBSET_YAML="$SUBSET" \
    HUMAN_IMPORT_CMD="true" \
    HUMAN_SESSION_CMD="$SESSION_TEMPLATE" \
    HUMAN_RUN_TEMPLATE="$RUN_TEMPLATE" \
    HUMAN_LOG_DIR="$LOGS" \
    "${envs[@]+"${envs[@]}"}" \
    bash "$ORCH" "$sub" "$@" 2>&1)"
  RC=$?
}

stub_calls() { wc -l <"$STUB_CALLS" 2>/dev/null | tr -d ' '; }

echo "== 25_human_replay.sh: the environment gate =="

run env
assert_rc_zero "env gate exits 0" "$RC"
assert_contains "env gate prints DEPLOY_HUMAN_ENV_OK" "$OUT" "DEPLOY_HUMAN_ENV_OK"
assert_contains "env gate reports the robot" "$OUT" "robot=g1_amber"
assert_contains "env gate reports the data clip" "$OUT" "clip=clip_000__A000"

run env HUMAN_IMPORT_CMD=false
assert_rc_nonzero "env gate fails when the import probe fails" "$RC"
assert_contains "env gate reports import-failed" "$OUT" "DEPLOY_HUMAN_ENV_FAIL reason=import-failed"
assert_not_contains "env gate prints no OK marker on an import failure" "$OUT" "_OK"

run env HUMAN_DEPLOY_DIR="$TMP/nothing"
assert_rc_nonzero "env gate fails without the ONNX export directory" "$RC"
assert_contains "env gate reports deploy-dir-missing" "$OUT" "DEPLOY_HUMAN_ENV_FAIL reason=deploy-dir-missing"
assert_not_contains "env gate prints no OK marker without the export directory" "$OUT" "_OK"

mkdir -p "$TMP/no_onnx"
run env HUMAN_DEPLOY_DIR="$TMP/no_onnx"
assert_rc_nonzero "env gate fails without the ONNX policy" "$RC"
assert_contains "env gate reports deploy-onnx-missing" "$OUT" "DEPLOY_HUMAN_ENV_FAIL reason=deploy-onnx-missing"
assert_not_contains "env gate prints no OK marker without the policy" "$OUT" "_OK"

mkdir -p "$TMP/no_json"
printf 'fake onnx\n' >"$TMP/no_json/policy.onnx"
run env HUMAN_DEPLOY_DIR="$TMP/no_json"
assert_rc_nonzero "env gate fails without the robot json" "$RC"
assert_contains "env gate reports deploy-json-missing" "$OUT" "DEPLOY_HUMAN_ENV_FAIL reason=deploy-json-missing"
assert_not_contains "env gate prints no OK marker without the robot json" "$OUT" "_OK"

run env HUMAN_ASSETS_DIR="$TMP/nope"
assert_rc_nonzero "env gate fails without the assets directory" "$RC"
assert_contains "env gate reports assets-missing" "$OUT" "DEPLOY_HUMAN_ENV_FAIL reason=assets-missing"
assert_not_contains "env gate prints no OK marker without the assets" "$OUT" "_OK"

run env HUMAN_SUBSET_YAML="$TMP/nope.yaml"
assert_rc_nonzero "env gate fails without the data clip" "$RC"
assert_contains "env gate reports data-clip-missing" "$OUT" "DEPLOY_HUMAN_ENV_FAIL reason=data-clip-missing"
assert_not_contains "env gate prints no OK marker without the data clip" "$OUT" "_OK"

echo "== 25_human_replay.sh: the session =="

: >"$STUB_CALLS"
run session
assert_rc_zero "the session step exits 0" "$RC"
assert_contains "the session step prints DEPLOY_HUMAN_SESSION_OK" "$OUT" "DEPLOY_HUMAN_SESSION_OK"
assert_contains "the session step reports the sample count" "$OUT" "samples=3"
assert_nonempty_file "the session npz was written" "$OUT_DIR/session.npz"
assert_eq "make_gmr_session was called once" "1" "$(stub_calls)"

run session FAKE_SESSION_MODE=fail
assert_rc_nonzero "the session step fails when make_gmr_session fails" "$RC"
assert_contains "the session step reports session-make-failed" "$OUT" "DEPLOY_HUMAN_SESSION_FAIL reason=session-make-failed"
assert_not_contains "a failed session prints no DEPLOY_HUMAN_SESSION_OK" "$OUT" "DEPLOY_HUMAN_SESSION_OK"

run session FAKE_SESSION_MODE=no-session
assert_rc_nonzero "the session step fails when no recording is written" "$RC"
assert_contains "the session step reports session-missing" "$OUT" "DEPLOY_HUMAN_SESSION_FAIL reason=session-missing"
assert_not_contains "a missing recording prints no DEPLOY_HUMAN_SESSION_OK" "$OUT" "DEPLOY_HUMAN_SESSION_OK"

run session FAKE_SESSION_SHAPE=3x24x6
assert_rc_nonzero "the session step fails when the body shape is wrong" "$RC"
assert_contains "the session step reports session-shape-invalid" "$OUT" "DEPLOY_HUMAN_SESSION_FAIL reason=session-shape-invalid"
assert_not_contains "a wrong body shape prints no DEPLOY_HUMAN_SESSION_OK" "$OUT" "DEPLOY_HUMAN_SESSION_OK"

run session FAKE_SESSION_SHAPE=0x24x7
assert_rc_nonzero "the session step fails when the recording is empty" "$RC"
assert_contains "the session step reports session-shape-invalid for an empty recording" "$OUT" "DEPLOY_HUMAN_SESSION_FAIL reason=session-shape-invalid"
assert_not_contains "an empty recording prints no DEPLOY_HUMAN_SESSION_OK" "$OUT" "DEPLOY_HUMAN_SESSION_OK"

run session HUMAN_IMPORT_CMD=false
assert_rc_nonzero "the session step fails when the environment gate fails" "$RC"
assert_contains "the session step reports the environment gate reason" "$OUT" "DEPLOY_HUMAN_SESSION_FAIL reason=import-failed"
assert_not_contains "a failed environment gate prints no DEPLOY_HUMAN_SESSION_OK" "$OUT" "DEPLOY_HUMAN_SESSION_OK"

echo "== 25_human_replay.sh: the replay =="

# a good session first (the replay consumes it)
run session
assert_rc_zero "the session step exits 0 (for the replay)" "$RC"

: >"$STUB_CALLS"
run run
assert_rc_zero "the replay exits 0" "$RC"
assert_contains "the replay prints DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"
assert_contains "the replay reports the step count" "$OUT" "steps=700"
assert_nonempty_file "the replay mp4 was written" "$OUT_DIR/replay.mp4"
assert_nonempty_file "the replay summary was written" "$OUT_DIR/replay_summary.json"
assert_eq "the replay was started once" "1" "$(stub_calls)"
assert_contains "the replay exports MUJOCO_GL=egl itself" "$(cat "$STUB_CALLS")" "MUJOCO_GL=egl"
assert_contains "the replay passes the recording to the streamer" "$(cat "$STUB_CALLS")" "session.npz"

echo "== 25_human_replay.sh: the negative paths =="

run run FAKE_RUN_MODE=missing-summary
assert_rc_nonzero "the replay fails when the summary is missing" "$RC"
assert_contains "the replay reports replay-summary-missing" "$OUT" "DEPLOY_HUMAN_FAIL reason=replay-summary-missing"
assert_not_contains "a missing summary prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=empty-summary
assert_rc_nonzero "the replay fails when the summary is empty" "$RC"
assert_contains "the replay reports replay-summary-empty" "$OUT" "DEPLOY_HUMAN_FAIL reason=replay-summary-empty"
assert_not_contains "an empty summary prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=malformed
assert_rc_nonzero "the replay fails when the summary is malformed" "$RC"
assert_contains "the replay reports replay-summary-empty for a malformed summary" "$OUT" "DEPLOY_HUMAN_FAIL reason=replay-summary-empty"
assert_not_contains "a malformed summary prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=missing-field
assert_rc_nonzero "the replay fails when a summary field is missing" "$RC"
assert_contains "the replay reports summary-field-missing" "$OUT" "DEPLOY_HUMAN_FAIL reason=summary-field-missing"
assert_not_contains "a missing field prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=empty-value
assert_rc_nonzero "the replay fails when a summary value is empty" "$RC"
assert_contains "the replay reports summary-value-empty" "$OUT" "DEPLOY_HUMAN_FAIL reason=summary-value-empty"
assert_not_contains "an empty value prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=empty-video
assert_rc_nonzero "the replay fails when the video is empty" "$RC"
assert_contains "the replay reports video-empty" "$OUT" "DEPLOY_HUMAN_FAIL reason=video-empty"
assert_not_contains "an empty video prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=no-video
assert_rc_nonzero "the replay fails when the video is missing" "$RC"
assert_contains "the replay reports video-missing" "$OUT" "DEPLOY_HUMAN_FAIL reason=video-missing"
assert_not_contains "a missing video prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

run run FAKE_RUN_MODE=nonzero
assert_rc_nonzero "the replay fails when the replay command exits non-zero" "$RC"
assert_contains "the replay reports replay-run-failed" "$OUT" "DEPLOY_HUMAN_FAIL reason=replay-run-failed"
assert_not_contains "a failing replay prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

# a hung replay must not stall the step: the wall clock is bounded.
run run HUMAN_REPLAY_TIMEOUT=1 FAKE_RUN_HANG=1
assert_rc_nonzero "the replay fails when it times out" "$RC"
assert_contains "the replay reports replay-timeout" "$OUT" "DEPLOY_HUMAN_FAIL reason=replay-timeout"
assert_not_contains "a timed-out replay prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

# without a recording the replay must not start at all.
mv "$OUT_DIR/session.npz" "$TMP/session.saved"
: >"$STUB_CALLS"
run run
assert_rc_nonzero "the replay fails without the recording" "$RC"
assert_contains "the replay reports session-missing" "$OUT" "DEPLOY_HUMAN_FAIL reason=session-missing"
assert_not_contains "a missing recording prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"
assert_eq "a missing recording starts no replay" "0" "$(stub_calls)"
mv "$TMP/session.saved" "$OUT_DIR/session.npz"

run run HUMAN_IMPORT_CMD=false
assert_rc_nonzero "the replay fails when the environment gate fails" "$RC"
assert_contains "the replay reports the environment gate reason" "$OUT" "DEPLOY_HUMAN_FAIL reason=import-failed"
assert_not_contains "a failed environment gate prints no DEPLOY_HUMAN_OK" "$OUT" "DEPLOY_HUMAN_OK"

echo "== 25_human_replay.sh: the report =="

run report
assert_rc_zero "report exits 0" "$RC"
assert_contains "report names its side" "$OUT" "DEPLOY_REPORT_SIDE=human"
assert_contains "report prints the session facts" "$OUT" "DEPLOY_REPORT_SESSION"
assert_contains "report prints the body shape" "$OUT" "body_shape=3x24x7"
assert_contains "report prints the replay facts" "$OUT" "DEPLOY_REPORT_REPLAY"
assert_contains "report prints the byte counts" "$OUT" "DEPLOY_REPORT_BYTES"

echo "== 25_human_replay.sh: the repository wiring =="

assert_contains "the orchestrator exports MUJOCO_GL=egl" \
  "$(cat "$ORCH")" "MUJOCO_GL=egl"
assert_contains "the orchestrator uses the shared decision base" \
  "$(cat "$ORCH")" "repro/lib/deploy.py"
assert_contains "the orchestrator drives the human interface" \
  "$(cat "$ORCH")" "--interface human"
assert_contains "the orchestrator replays the recording" \
  "$(cat "$ORCH")" "--replay"
assert_contains "the decision base knows the session's array shapes" \
  "$(cat "$REPO_ROOT/repro/lib/deploy.py")" "SESSION_BODY_TAIL"
assert_contains "the decision base knows the human replay fields" \
  "$(cat "$REPO_ROOT/repro/lib/deploy.py")" "HUMAN_REPLAY_FIELDS"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
