#!/usr/bin/env bash
# repro/25_human_replay.sh — the HUMAN-INTERFACE REPLAY ORCHESTRATOR of the
# deployment verification (slice S08, task T6).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The milestone requirement R015 asks for the proof that the exported ONNX
# policy really drives MuJoCo through the HUMAN interface (the
# `action_human` path), not only through the motion interface:
#
#     1. `deploy.tools.make_gmr_session` turns one G1 dataset clip into a
#        PICO recording (t_ns / body[N,24,7] / buttons[N,5]);
#     2. `deploy.run --teleop --replay <session> --interface human` starts
#        the streamer on that recording (`--target human`: HumanTarget, NO
#        GMR) and the policy node on the human goal, and runs the sim.
#
# The four unknown surfaces that meet here:
#
#     1. the PICO recording format (make_gmr_session <-> ReplaySource),
#     2. the human streamer target (HumanTarget: the operator on the uniform
#        skeleton, the calibration combo, the POSE state machine),
#     3. the human policy node (`--interface human`: the 24 SMPL slots, the
#        goal features, the --human-points mask),
#     4. the EGL rendering + the ZMQ protocol of the sim side.
#
# So this script is the orchestrator and repro/lib/deploy.py is the decision
# base: the session's array shapes, the replay summary's fields and the
# video's size are decided by ONE set of pure functions, so the shell and
# the python can never drift apart.
#
# ---------------------------------------------------------------------------
# SEMANTIC NOTE (read this before drawing any conclusion from the numbers)
#
# The "operator" inside the session is NOT a human: it is the G1 robot
# itself, put into GMR's PICO conventions (deploy/tools/gmr_operator.py:
# "The operator is the G1 itself").  This task therefore proves that the
# action_human PATH is executable end to end (the recording is consumed, the
# human goal is built, the policy acts, the sim renders) -- it does NOT
# measure the quality of a human's motion.  The motion interface's own
# branch does not apply here: `deploy.run --interface human` with `--clip`
# is refused upstream (a human clip needs its human sidecar, and
# `--from-stand` is not allowed under the human interface).
#
# Another upstream fact that shapes the summary contract: under
# `--interface human` the policy node sends NO reference window to the sim
# (the sim draws robot reference windows only), so the teleop summary
# carries `joint_err_rms_rad: null`.  The human replay contract is
# therefore steps / falls / travel_along_m (deploy.verify_human_replay_summary),
# NOT the motion branch's error block.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the fail-closed ENVIRONMENT GATE (seconds, no GPU):
#            the teleop group imports general_motion_retargeting (the GMR
#            submodule must be landed), the ONNX export directory holds
#            policy.onnx + <robot>.json, the assets directory holds
#            <robot>.xml, the selected G1 dataset clip exists, and
#            MUJOCO_GL=egl can be set.
#            Success prints ONE line
#                DEPLOY_HUMAN_ENV_OK robot=<robot> clip=<clip stem>
#            failure prints ONE line
#                DEPLOY_HUMAN_ENV_FAIL reason=<fixed reason set>
#            and exits non-zero.  The OK marker is BUFFERED and flushed only
#            when EVERY check passed (project convention P004).
#
#   session  build the PICO recording:
#              1. the environment gate MUST pass -- otherwise no session is
#                 built,
#              2. `make_gmr_session` writes <out>/session.npz,
#              3. the recording is verified by the decision base: it must
#                 hold t_ns / body / buttons and its body must be
#                 [N, 24, 7] with N > 0 (PICO's 24 joints, xyz + xyzw).
#            Success prints ONE line
#                DEPLOY_HUMAN_SESSION_OK samples=<n>
#            failure prints ONE line
#                DEPLOY_HUMAN_SESSION_FAIL reason=<fixed reason set>
#
#   run      the human-interface replay:
#              1. the environment gate MUST pass,
#              2. the session MUST exist (run it after `session`),
#              3. MUJOCO_GL=egl <uv> python -m deploy.run --deploy out/<robot>
#                 --assets assets --robot <robot> --teleop --replay <session>
#                 --interface human --human-points full --max-steps <N>
#                 --video <mp4> --summary <json>
#                 (MUJOCO_GL=egl is exported by THIS script: deploy.run does
#                 not set it, and without it MuJoCo cannot render headless),
#              4. the summary must carry robot / steps / falls /
#                 travel_along_m with non-empty values (the decision base),
#              5. the mp4 must have more than zero bytes.
#            Success prints ONE line
#                DEPLOY_HUMAN_OK steps=<n> falls=<n>
#            failure prints ONE line
#                DEPLOY_HUMAN_FAIL reason=<fixed reason set>
#
#   report   the replay-side self report (DEPLOY_REPORT_*): the session's
#            sample count and shape, the summary's steps / falls / travel
#            and the video's size.
#
#   selftest the offline battery: repro/tests/test_deploy_human.sh.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SETS (greppable)
#
#   env gate:  import-failed  deploy-dir-missing  deploy-onnx-missing
#              deploy-json-missing  assets-missing  assets-xml-missing
#              data-clip-missing  mujoco-gl-unset
#   session:   session-make-failed  session-missing  session-format-invalid
#              session-shape-invalid
#   run gate:  session-missing  replay-run-failed  replay-timeout
#              replay-summary-missing  replay-summary-empty
#              summary-field-missing  summary-value-empty
#              video-missing  video-empty
#
# The session / summary / video reasons are the ones repro/lib/deploy.py
# produces (deploy.REASONS), so the orchestrator and the decision base share
# ONE vocabulary.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without a GPU,
# without EGL and without the real replay)
#
#   HUMAN_ALLOW_LOCAL=1  allow running outside the ros_dev container
#   HUMAN_ROBOT          robot name (default g1_amber)
#   HUMAN_ASSETS_DIR     assets directory (default <repo>/assets)
#   HUMAN_DEPLOY_DIR     ONNX export directory (default <repo>/out/<robot>)
#   HUMAN_OUT_DIR        landing spot (default <repo>/runs/human)
#   HUMAN_SUBSET_YAML    the subset yaml the data clip is taken from
#                        (default <repo>/data/seed_g1_npz50/subsets/1h.yaml)
#   HUMAN_DATA_CLIP      the G1 dataset clip (default: the FIRST clip of the
#                        subset yaml, resolved against its `root:`)
#   HUMAN_UV_BIN         uv binary (default uv)
#   HUMAN_UV_ARGS        uv arguments (default
#                        run --frozen --offline --group export --group teleop)
#   HUMAN_IMPORT_CMD     the import probe (default
#                        "<uv> <uv args> python -c
#                         'import general_motion_retargeting'")
#   HUMAN_SESSION_CMD    the make_gmr_session command template (default
#                        "<uv> <uv args> python -m deploy.tools.make_gmr_session
#                         {session} --clip {clip}")
#   HUMAN_RUN_TEMPLATE   the replay command template (default
#                        "<uv> <uv args> python -m deploy.run --deploy {deploy}
#                         --assets {assets} --robot {robot} --teleop
#                         --replay {replay} --interface human
#                         --human-points full --max-steps {steps}
#                         --video {video} --summary {summary}")
#   HUMAN_MAX_STEPS      the replay's step budget (default 700)
#   HUMAN_REPLAY_TIMEOUT the wall-clock timeout of the replay in seconds
#                        (default 600; 0 disables it)
#   HUMAN_PY             the decision-base interpreter (default python3)
#   HUMAN_LOG_DIR        log directory (default $LOG_DIR)
#   HUMAN_SELFTEST_CMD   the offline battery command
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 21_assets.sh / 22_sim2sim.sh convention).
set +e

if [ "${HUMAN_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${HUMAN_LOG_DIR:-$LOG_DIR}"
mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
MAIN_LOG="$LOG_DIR_REAL/25_human_replay.txt"

ROBOT="${HUMAN_ROBOT:-g1_amber}"
ASSETS_DIR_REAL="${HUMAN_ASSETS_DIR:-$REPO_ROOT/assets}"
DEPLOY_DIR_REAL="${HUMAN_DEPLOY_DIR:-$REPO_ROOT/out/$ROBOT}"
OUT_DIR_REAL="${HUMAN_OUT_DIR:-$REPO_ROOT/runs/human}"
SUBSET_YAML="${HUMAN_SUBSET_YAML:-$REPO_ROOT/data/seed_g1_npz50/subsets/1h.yaml}"
MAX_STEPS="${HUMAN_MAX_STEPS:-700}"
REPLAY_TIMEOUT="${HUMAN_REPLAY_TIMEOUT:-600}"
PY="${HUMAN_PY:-python3}"
UV_BIN="${HUMAN_UV_BIN:-uv}"
UV_ARGS="${HUMAN_UV_ARGS:-run --frozen --offline --group export --group teleop}"
IMPORT_CMD="${HUMAN_IMPORT_CMD:-$UV_BIN $UV_ARGS python -c 'import general_motion_retargeting'}"
# NOTE: the defaults of the templates hold `}` characters, so they can NOT be
# written as ${VAR:-...}: the closing brace would end the parameter expansion
# early.  Hence the explicit if.
if [ -n "${HUMAN_SESSION_CMD:-}" ]; then
  SESSION_TEMPLATE="$HUMAN_SESSION_CMD"
else
  SESSION_TEMPLATE="$UV_BIN $UV_ARGS python -m deploy.tools.make_gmr_session {session} --clip {clip}"
fi
if [ -n "${HUMAN_RUN_TEMPLATE:-}" ]; then
  RUN_TEMPLATE="$HUMAN_RUN_TEMPLATE"
else
  RUN_TEMPLATE="$UV_BIN $UV_ARGS python -m deploy.run --deploy {deploy} --assets {assets} --robot {robot} --teleop --replay {replay} --interface human --human-points full --max-steps {steps} --video {video} --summary {summary}"
fi
SELFTEST_CMD="${HUMAN_SELFTEST_CMD:-bash $REPO_ROOT/repro/tests/test_deploy_human.sh}"
DEPLOY_LIB="$REPO_ROOT/repro/lib/deploy.py"

SESSION_NPZ="$OUT_DIR_REAL/session.npz"
REPLAY_MP4="$OUT_DIR_REAL/replay.mp4"
REPLAY_SUMMARY="$OUT_DIR_REAL/replay_summary.json"
STDERR_LOG="$OUT_DIR_REAL/stderr.log"

usage() {
  cat <<EOF
usage: bash repro/25_human_replay.sh <subcommand> [options]

  env       the fail-closed environment gate (DEPLOY_HUMAN_ENV_OK / _FAIL)
  session   build the PICO recording (DEPLOY_HUMAN_SESSION_OK / _FAIL)
  run       the human-interface replay (DEPLOY_HUMAN_OK / _FAIL)
  report    the replay-side self report (DEPLOY_REPORT_*)
  selftest  the offline battery (repro/tests/test_deploy_human.sh)

robot:      $ROBOT
assets:     $ASSETS_DIR_REAL
deploy:     $DEPLOY_DIR_REAL
out:        $OUT_DIR_REAL
subset:     $SUBSET_YAML
log:        $MAIN_LOG
EOF
}

# --- output ----------------------------------------------------------------
elog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed ONLY when every check passed
# (project convention P004): a failure path must print NO OK marker.
OK_MARKERS=()
elog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do elog "$m"; done
  OK_MARKERS=()
}

# --- helpers ---------------------------------------------------------------
# rel_to_repo <path> — the path relative to the repository root when it is
# inside it (the markers quote repo-relative paths), the path itself
# otherwise.
rel_to_repo() {
  local p="$1"
  case "$p" in
    "$REPO_ROOT"/*) printf '%s' "${p#"$REPO_ROOT"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# data_clip — the G1 dataset clip the session is built from (the first clip
# of the subset yaml, resolved against its `root:`).  Prints the path; empty
# when it cannot be resolved.
data_clip() {
  local root clip
  if [ -n "${HUMAN_DATA_CLIP:-}" ]; then
    printf '%s' "$HUMAN_DATA_CLIP"
    return 0
  fi
  [ -f "$SUBSET_YAML" ] || return 1
  root="$(sed -n 's/^root:[[:space:]]*//p' "$SUBSET_YAML" | head -n 1)"
  clip="$(sed -n 's/^- //p' "$SUBSET_YAML" | head -n 1)"
  [ -n "$clip" ] || return 1
  if [ -n "$root" ]; then
    printf '%s' "$root/$clip"
  else
    printf '%s' "$REPO_ROOT/data/seed_g1_npz50/$clip"
  fi
  return 0
}

# expand_template <template> <pairs...> — replaces the placeholders with
# shell-quoted values.  The pairs are "name=value" strings.
expand_template() {
  local template="$1"; shift
  local out="$template" pair name value
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    out="${out//\{$name\}/$(printf '%q' "$value")}"
  done
  printf '%s' "$out"
}

# session_check <session.npz>
# The decision is made by repro/lib/deploy.py (verify_session +
# verify_session_arrays): the recording must hold the three PICO members and
# its body must be [N, 24, 7] with N > 0.  Prints
#   ok samples=<n> body=<shape>
# on success and
#   reason=<reason>
# on failure (exit code 1).
session_check() {
  "$PY" - "$1" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

session_path, lib_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

facts, reason = module.verify_session(session_path)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
facts, reason = module.verify_session_arrays(session_path)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print("ok samples=%d body=%s" % (facts["samples"], "x".join(str(v) for v in facts["shapes"]["body"])))
PY
}

# replay_summary_check <summary.json>
# The decision is made by repro/lib/deploy.py (verify_human_replay_summary):
# the summary must carry robot / steps / falls / travel_along_m with
# non-empty values, and the video it names must exist and be non-empty.
# Prints
#   ok steps=<n> falls=<n> travel_along_m=<v>
# on success and
#   reason=<reason>
# on failure (exit code 1).
replay_summary_check() {
  "$PY" - "$1" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

summary_path, lib_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

facts, reason = module.verify_human_replay_summary(summary_path)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print("ok steps=%d falls=%d travel_along_m=%s" % (
  facts["steps"], facts["falls"], facts["travel_along_m"]))
PY
}

# video_check <mp4>
# The decision is made by repro/lib/deploy.py (check_video): the file must
# exist and hold more than zero bytes.
video_check() {
  "$PY" - "$1" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

video_path, lib_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
reason = module.check_video(video_path)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print("ok")
PY
}

# --- env gate --------------------------------------------------------------
# env_fail <reason> [detail...] — the ONLY failure exit of the gate: it
# prints the fail marker (and the details) and returns 1.  It NEVER prints
# an OK marker.
env_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_HUMAN_ENV_FAIL reason=$reason"
  return 1
}

env_gate() {
  # (1) the teleop group must import general_motion_retargeting (the GMR
  #     submodule must be landed: it is a workspace editable source).
  local probe_out probe_rc
  probe_out="$(eval "$IMPORT_CMD" 2>&1)"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    env_fail "import-failed" \
      "command: $IMPORT_CMD" \
      "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    return 1
  fi

  # (2) the ONNX export directory must exist ...
  if [ ! -d "$DEPLOY_DIR_REAL" ]; then
    env_fail "deploy-dir-missing" "PATH=$DEPLOY_DIR_REAL" || return 1
    return 1
  fi
  # (3) ... and hold the policy and the robot's json.
  if [ ! -f "$DEPLOY_DIR_REAL/policy.onnx" ]; then
    env_fail "deploy-onnx-missing" "PATH=$DEPLOY_DIR_REAL/policy.onnx" || return 1
    return 1
  fi
  if [ ! -f "$DEPLOY_DIR_REAL/$ROBOT.json" ]; then
    env_fail "deploy-json-missing" "PATH=$DEPLOY_DIR_REAL/$ROBOT.json" || return 1
    return 1
  fi

  # (4) the assets directory must exist ...
  if [ ! -d "$ASSETS_DIR_REAL" ]; then
    env_fail "assets-missing" "PATH=$ASSETS_DIR_REAL" || return 1
    return 1
  fi
  # (5) ... and hold the exported scene.
  if [ ! -f "$ASSETS_DIR_REAL/$ROBOT.xml" ]; then
    env_fail "assets-xml-missing" "PATH=$ASSETS_DIR_REAL/$ROBOT.xml" || return 1
    return 1
  fi

  # (6) the selected G1 dataset clip must exist (the session is built from
  #     it).
  local clip
  clip="$(data_clip)"
  if [ -z "$clip" ] || [ ! -f "$clip" ]; then
    env_fail "data-clip-missing" \
      "subset: $SUBSET_YAML" "clip: ${clip:-<unresolved>}" || return 1
    return 1
  fi

  # (7) MUJOCO_GL=egl must be settable (it is what makes the headless
  #     rendering work; deploy.run does not set it).
  MUJOCO_GL=egl
  export MUJOCO_GL
  if [ "${MUJOCO_GL:-}" != "egl" ]; then
    env_fail "mujoco-gl-unset" "MUJOCO_GL=${MUJOCO_GL:-<empty>}" || return 1
    return 1
  fi

  local stem
  stem="$(basename "$clip")"
  stem="${stem%.npz}"
  elog_ok "DEPLOY_HUMAN_ENV_OK robot=$ROBOT clip=$stem"
  flush_ok_markers
  return 0
}

cmd_env() {
  elog "=== 25_human_replay.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "assets:     $ASSETS_DIR_REAL"
  elog "deploy:     $DEPLOY_DIR_REAL"
  elog "out:        $OUT_DIR_REAL"
  elog "subset:     $SUBSET_YAML"
  local rc=0
  env_gate || rc=1
  return "$rc"
}

# --- session ---------------------------------------------------------------
# session_fail <reason> [detail...]
session_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_HUMAN_SESSION_FAIL reason=$reason"
  return 1
}

cmd_session() {
  elog "=== 25_human_replay.sh session $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "out:        $OUT_DIR_REAL"
  elog "subset:     $SUBSET_YAML"

  # (0) the ENVIRONMENT GATE must pass -- otherwise no session is built.
  local gate_tmp gate_rc reason
  gate_tmp="$(mktemp)"
  env_gate >"$gate_tmp" 2>&1
  gate_rc=$?
  {
    printf -- '--- environment gate (rc=%s) ---\n' "$gate_rc"
    cat "$gate_tmp"
  } >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$gate_rc" -ne 0 ]; then
    reason="$(sed -n 's/^DEPLOY_HUMAN_ENV_FAIL reason=\([a-z-]*\)$/\1/p' "$gate_tmp" | head -n1)"
    rm -f "$gate_tmp"
    elog "  the environment gate failed: reason=${reason:-unknown}"
    elog "DEPLOY_HUMAN_SESSION_FAIL reason=${reason:-import-failed}"
    return 1
  fi
  rm -f "$gate_tmp"
  elog "  environment gate: PASS"

  # (1) the data clip.
  local clip
  clip="$(data_clip)"
  if [ -z "$clip" ] || [ ! -f "$clip" ]; then
    session_fail "data-clip-missing" "clip: ${clip:-<unresolved>}"
    return 1
  fi
  elog "  data clip: $clip"

  # (2) the landing spot.
  mkdir -p "$OUT_DIR_REAL" 2>/dev/null || true
  if [ ! -d "$OUT_DIR_REAL" ]; then
    session_fail "session-make-failed" "cannot create $OUT_DIR_REAL"
    return 1
  fi
  rm -f "$SESSION_NPZ" 2>/dev/null || true

  # (3) make_gmr_session.
  local cmd out rc started ended
  cmd="$(expand_template "$SESSION_TEMPLATE" \
    "session=$SESSION_NPZ" "clip=$clip")"
  started="$(date +%s)"
  out="$(cd "$REPO_ROOT" && eval "$cmd" 2>&1)"
  rc=$?
  ended="$(date +%s)"
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  elog "  make_gmr_session: rc=$rc ($((ended - started))s)"
  if [ "$rc" -ne 0 ]; then
    elog "  $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
    session_fail "session-make-failed" "command: $cmd"
    return 1
  fi

  # (4) the recording's contract (the decision base).
  local check_out
  check_out="$(session_check "$SESSION_NPZ")"
  if [ $? -ne 0 ]; then
    reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    session_fail "${reason:-session-format-invalid}" \
      "session: $(rel_to_repo "$SESSION_NPZ") ($check_out)"
    return 1
  fi
  elog "  session: $check_out"
  local samples
  samples="$(printf '%s\n' "$check_out" | sed -n 's/.*samples=\([0-9]*\).*/\1/p' | head -n1)"
  elog_ok "DEPLOY_HUMAN_SESSION_OK samples=${samples:-0}"
  flush_ok_markers
  return 0
}

# --- run -------------------------------------------------------------------
# run_fail <reason> [detail...]
run_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_HUMAN_FAIL reason=$reason"
  return 1
}

cmd_run() {
  elog "=== 25_human_replay.sh run $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "assets:     $ASSETS_DIR_REAL"
  elog "deploy:     $DEPLOY_DIR_REAL"
  elog "out:        $OUT_DIR_REAL"
  elog "max steps:  $MAX_STEPS"

  # (0) the ENVIRONMENT GATE must pass -- otherwise nothing is replayed.
  local gate_tmp gate_rc reason
  gate_tmp="$(mktemp)"
  env_gate >"$gate_tmp" 2>&1
  gate_rc=$?
  {
    printf -- '--- environment gate (rc=%s) ---\n' "$gate_rc"
    cat "$gate_tmp"
  } >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$gate_rc" -ne 0 ]; then
    reason="$(sed -n 's/^DEPLOY_HUMAN_ENV_FAIL reason=\([a-z-]*\)$/\1/p' "$gate_tmp" | head -n1)"
    rm -f "$gate_tmp"
    elog "  the environment gate failed: reason=${reason:-unknown}"
    elog "DEPLOY_HUMAN_FAIL reason=${reason:-import-failed}"
    return 1
  fi
  rm -f "$gate_tmp"
  elog "  environment gate: PASS"

  # (1) the session must exist (build it with `session`).
  if [ ! -f "$SESSION_NPZ" ]; then
    run_fail "session-missing" "PATH=$(rel_to_repo "$SESSION_NPZ")"
    return 1
  fi

  # (2) the landing spot.
  mkdir -p "$OUT_DIR_REAL" 2>/dev/null || true
  if [ ! -d "$OUT_DIR_REAL" ]; then
    run_fail "replay-run-failed" "cannot create $OUT_DIR_REAL"
    return 1
  fi
  rm -f "$REPLAY_MP4" "$REPLAY_SUMMARY" 2>/dev/null || true

  # (3) the replay.  MUJOCO_GL=egl is exported HERE (deploy.run does not set
  #     it, and without it MuJoCo cannot render headless).
  local cmd out rc started elapsed
  cmd="$(expand_template "$RUN_TEMPLATE" \
    "deploy=$DEPLOY_DIR_REAL" "assets=$ASSETS_DIR_REAL" "robot=$ROBOT" \
    "replay=$SESSION_NPZ" "steps=$MAX_STEPS" \
    "video=$REPLAY_MP4" "summary=$REPLAY_SUMMARY")"
  # A hung replay (a deadlock in the ZMQ handshake, a MuJoCo stall) must not
  # stall the whole step: the wall clock is bounded and a timeout has its own
  # fixed reason.
  if [ "${REPLAY_TIMEOUT:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    cmd="timeout $REPLAY_TIMEOUT $cmd"
  fi
  started="$(date +%s)"
  out="$(cd "$REPO_ROOT" && MUJOCO_GL=egl eval "$cmd" 2>"$STDERR_LOG")"
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  {
    printf -- '--- stderr (%s) ---\n' "$(rel_to_repo "$STDERR_LOG")"
    cat "$STDERR_LOG" 2>/dev/null
  } >>"$MAIN_LOG" 2>/dev/null || true
  elog "  replay: rc=$rc (${elapsed}s)"
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    elog "  the replay timed out after ${elapsed}s (timeout=${REPLAY_TIMEOUT:-0}s)"
    run_fail "replay-timeout" "command: $cmd"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    elog "  $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
    run_fail "replay-run-failed" "command: $cmd"
    return 1
  fi

  # (4) the summary's contract (the decision base).
  local check_out
  check_out="$(replay_summary_check "$REPLAY_SUMMARY")"
  if [ $? -ne 0 ]; then
    reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    run_fail "${reason:-replay-summary-empty}" \
      "summary: $(rel_to_repo "$REPLAY_SUMMARY") ($check_out)"
    return 1
  fi
  elog "  summary: $check_out"
  local steps falls
  steps="$(printf '%s\n' "$check_out" | sed -n 's/.*steps=\([0-9]*\).*/\1/p' | head -n1)"
  falls="$(printf '%s\n' "$check_out" | sed -n 's/.*falls=\([0-9]*\).*/\1/p' | head -n1)"

  # (5) the video must hold more than zero bytes.
  check_out="$(video_check "$REPLAY_MP4")"
  if [ $? -ne 0 ]; then
    reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    run_fail "${reason:-video-empty}" "video: $(rel_to_repo "$REPLAY_MP4") ($check_out)"
    return 1
  fi

  elog_ok "DEPLOY_HUMAN_OK steps=${steps:-0} falls=${falls:-0}"
  flush_ok_markers
  return 0
}

# --- report ----------------------------------------------------------------
cmd_report() {
  elog "=== 25_human_replay.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "DEPLOY_REPORT_SIDE=human"
  elog "DEPLOY_REPORT_DIR dir=$OUT_DIR_REAL"
  elog "DEPLOY_REPORT_ROBOT robot=$ROBOT"

  local samples=0 shapes="-" steps=0 falls=0 travel="-" video_bytes=0 summary_bytes=0
  if [ -f "$SESSION_NPZ" ]; then
    local check_out
    check_out="$(session_check "$SESSION_NPZ")"
    if [ $? -eq 0 ]; then
      samples="$(printf '%s\n' "$check_out" | sed -n 's/.*samples=\([0-9]*\).*/\1/p' | head -n1)"
      shapes="$(printf '%s\n' "$check_out" | sed -n 's/.*body=\([^ ]*\).*/\1/p' | head -n1)"
    fi
  fi
  if [ -f "$REPLAY_SUMMARY" ]; then
    summary_bytes="$(wc -c <"$REPLAY_SUMMARY" | tr -d ' ')"
    local check_out
    check_out="$(replay_summary_check "$REPLAY_SUMMARY")"
    if [ $? -eq 0 ]; then
      steps="$(printf '%s\n' "$check_out" | sed -n 's/.*steps=\([0-9]*\).*/\1/p' | head -n1)"
      falls="$(printf '%s\n' "$check_out" | sed -n 's/.*falls=\([0-9]*\).*/\1/p' | head -n1)"
      travel="$(printf '%s\n' "$check_out" | sed -n 's/.*travel_along_m=\([^ ]*\).*/\1/p' | head -n1)"
    fi
  fi
  if [ -f "$REPLAY_MP4" ]; then
    video_bytes="$(wc -c <"$REPLAY_MP4" | tr -d ' ')"
  fi
  elog "DEPLOY_REPORT_SESSION samples=${samples:-0} body_shape=${shapes:--}"
  elog "DEPLOY_REPORT_REPLAY steps=${steps:-0} falls=${falls:-0} travel_along_m=${travel:--}"
  elog "DEPLOY_REPORT_BYTES summary_bytes=${summary_bytes:-0} video_bytes=${video_bytes:-0}"
  elog "DEPLOY_REPORT_OK=1"
  return 0
}

# --- selftest --------------------------------------------------------------
cmd_selftest() {
  elog "=== 25_human_replay.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  eval "$SELFTEST_CMD"
  return $?
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  session)  shift || true; cmd_session "$@" ;;
  run)      shift || true; cmd_run "$@" ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/25_human_replay.sh <env|session|run|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
