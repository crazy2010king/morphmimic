#!/usr/bin/env bash
# repro/22_sim2sim.sh — the SIM2SIM REPLAY ORCHESTRATOR of the deployment
# verification (slice S08, task T3).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The milestone requirement R013 asks for the proof that the exported
# assets + the exported ONNX policy really drive MuJoCo in a headless
# container: a full clip, an mp4 and non-empty completion / joint error /
# body error / drift numbers.  Four unknown surfaces meet in ONE command:
#
#     1. the EGL rendering (no display in the container),
#     2. the ONNX policy node (deploy/sim2sim/policy_node.py),
#     3. the exported asset layout (assets/<robot>.xml + clips/...),
#     4. the ZMQ protocol between the policy node and the sim node.
#
# `deploy.run` exists and does exactly that — but it is a single-shot tool:
# one clip, one summary, one video, and NO verification of its own output.
# The orchestration contract of this slice needs more:
#
#     * the env gate must pass BEFORE any clip runs (fail closed),
#     * the clip list is the one the asset export produced
#       (assets/clips_<robot>.txt — the same source the official comparison
#       uses, so the two sides stay comparable),
#     * EVERY clip must leave a summary whose completion / error / drift
#       numbers are present and non-empty AND an mp4 with more than zero
#       bytes,
#     * a failure must be visible: non-zero exit, NO OK marker, and the
#       fixed reason.
#
# So this script is the orchestrator and repro/lib/deploy.py is the decision
# base: the summary is parsed by ONE parser (deploy.parse_sim_summary), so
# the shell and the python can never drift apart.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the fail-closed ENVIRONMENT GATE (seconds, no GPU, no network):
#            the export group imports (onnxruntime + mujoco), the assets
#            directory holds <robot>.xml, the ONNX policy exists and
#            MUJOCO_GL=egl can be set.
#            Success prints ONE line
#                DEPLOY_SIM_ENV_OK robot=<robot> clips=<n>
#            failure prints ONE line
#                DEPLOY_SIM_ENV_FAIL reason=<fixed reason set>
#            and exits non-zero.  The OK marker is BUFFERED and flushed only
#            when EVERY check passed (project convention P004).
#
#   run      the replay:
#              1. the environment gate MUST pass -- otherwise no clip runs,
#              2. every clip of the clip list is replayed with
#                    MUJOCO_GL=egl <uv> python -m deploy.run
#                    --deploy out/<robot> --assets assets --robot <robot>
#                    --clip <stem> --interface motion
#                    --video <mp4> --summary <json>
#                 (MUJOCO_GL=egl is exported by THIS script: deploy.run does
#                 not set it, and without it MuJoCo cannot render headless),
#              3. every summary is parsed with deploy.parse_sim_summary and
#                 must carry result / joint_err_rms_rad / body_err_mean_m /
#                 end_drift_m with non-empty values,
#              4. every mp4 must have more than zero bytes.
#            Success prints ONE line
#                DEPLOY_SIM_OK clips=<n> completed=<n> video_ok=<n> parity=<a>/<b>
#            failure prints ONE line
#                DEPLOY_SIM_FAIL reason=<fixed reason set>
#            plus the per-clip line
#                DEPLOY_SIM_CLIP_FAILED clip=<stem> reason=<reason>
#
#   report   the replay-side self report (DEPLOY_REPORT_*): the clip count,
#            the number of summaries / videos, the completion count and the
#            measured wall clock per clip (total / mean / min / max).
#
#   selftest the offline battery: repro/tests/test_deploy_sim2sim.sh.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SETS (greppable)
#
#   env gate:  import-failed  assets-missing  assets-xml-missing
#              policy-missing  mujoco-gl-unset
#   run gate:  clip-list-missing  clip-list-empty  run-failed
#              replay-timeout    summary-missing  summary-parse-failed
#              summary-field-missing summary-value-empty  video-missing
#              video-empty
#
# The summary / video reasons are the ones repro/lib/deploy.py produces
# (deploy.REASONS), so the orchestrator and the decision base share ONE
# vocabulary.
#
# NOTE ON "failed" CLIPS: the upstream summary carries `result`, which is
# "completed" for a clean run and "failed at frame N" when the simulated
# robot fell.  A fallen clip is NOT an orchestrator failure: its summary
# still carries non-empty numbers and its mp4 still exists, so it is
# counted in `failed=` and does not stop the replay.  Only an INFRASTRUCTURE
# failure (missing / malformed / empty summary, missing / empty video, a
# non-zero exit of deploy.run) stops the replay with a non-zero exit and
# NO DEPLOY_SIM_OK marker.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without a GPU,
# without EGL and without the real replay)
#
#   DEPLOY_SIM_ALLOW_LOCAL=1  allow running outside the ros_dev container
#   SIM_ROBOT                 robot name (default g1_amber)
#   SIM_ASSETS_DIR            assets directory (default <repo>/assets)
#   SIM_DEPLOY_DIR            ONNX export directory (default <repo>/out/<robot>)
#   SIM_OUT_DIR               landing spot (default <repo>/runs/sim2sim)
#   SIM_CLIP_LIST             clip list (default
#                             <assets>/clips_<robot>.txt)
#   SIM_UV_BIN                uv binary (default uv)
#   SIM_UV_ARGS               uv arguments (default
#                             run --group export --frozen --offline)
#   SIM_IMPORT_CMD            the import probe (default
#                             "<uv> <uv args> python -c
#                              'import onnxruntime, mujoco'")
#   SIM_RUN_TEMPLATE          the replay command template (default
#                             "<uv> <uv args> python -m deploy.run
#                              --deploy {deploy} --assets {assets}
#                              --robot {robot} --clip {clip}
#                              --interface motion --video {video}
#                              --summary {summary}")
#   SIM_CLIP_TIMEOUT          the per-clip wall-clock timeout in seconds
#                             (default 900; 0 disables the timeout)
#   SIM_PY                    the decision-base interpreter (default python3)
#   SIM_LOG_DIR               log directory (default $LOG_DIR)
#   SIM_SELFTEST_CMD          the offline battery command
#
# CLI OPTIONS of `run`:
#   --limit N          replay only the first N clips of the list
#   --clip-list FILE   replay the clips of FILE instead of the default list
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 19_export.sh / 21_assets.sh convention).
set +e

if [ "${DEPLOY_SIM_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${SIM_LOG_DIR:-$LOG_DIR}"
mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
MAIN_LOG="$LOG_DIR_REAL/22_sim2sim.txt"

ROBOT="${SIM_ROBOT:-g1_amber}"
ASSETS_DIR_REAL="${SIM_ASSETS_DIR:-$REPO_ROOT/assets}"
DEPLOY_DIR_REAL="${SIM_DEPLOY_DIR:-$REPO_ROOT/out/$ROBOT}"
OUT_DIR_REAL="${SIM_OUT_DIR:-$REPO_ROOT/runs/sim2sim}"
CLIP_LIST_DEFAULT="${SIM_CLIP_LIST:-$ASSETS_DIR_REAL/clips_$ROBOT.txt}"
CLIP_LIST_REAL="$CLIP_LIST_DEFAULT"
LIMIT="${SIM_LIMIT:-0}"
CLIP_TIMEOUT="${SIM_CLIP_TIMEOUT:-900}"
PY="${SIM_PY:-python3}"
UV_BIN="${SIM_UV_BIN:-uv}"
UV_ARGS="${SIM_UV_ARGS:-run --group export --frozen --offline}"
IMPORT_CMD="${SIM_IMPORT_CMD:-$UV_BIN $UV_ARGS python -c 'import onnxruntime, mujoco'}"
# NOTE: the default of the replay template holds `}` characters, so it can NOT
# be written as ${SIM_RUN_TEMPLATE:-...}: the closing brace would end the
# parameter expansion early.  Hence the explicit if.
if [ -n "${SIM_RUN_TEMPLATE:-}" ]; then
  RUN_TEMPLATE="$SIM_RUN_TEMPLATE"
else
  RUN_TEMPLATE="$UV_BIN $UV_ARGS python -m deploy.run --deploy {deploy} --assets {assets} --robot {robot} --clip {clip} --interface motion --video {video} --summary {summary}"
fi
SELFTEST_CMD="${SIM_SELFTEST_CMD:-bash $REPO_ROOT/repro/tests/test_deploy_sim2sim.sh}"
DEPLOY_LIB="$REPO_ROOT/repro/lib/deploy.py"

SUMMARY_DIR="$OUT_DIR_REAL/summary"
VIDEO_DIR="$OUT_DIR_REAL/video"
TIMINGS_FILE="$OUT_DIR_REAL/timings.tsv"

usage() {
  cat <<EOF
usage: bash repro/22_sim2sim.sh <subcommand> [options]

  env       the fail-closed environment gate (DEPLOY_SIM_ENV_OK / _FAIL)
  run       the sim2sim replay (DEPLOY_SIM_OK / DEPLOY_SIM_FAIL reason=...)
            options: --limit N   --clip-list FILE
  report    the replay-side self report (DEPLOY_REPORT_*)
  selftest  the offline battery (repro/tests/test_deploy_sim2sim.sh)

robot:      $ROBOT
assets:     $ASSETS_DIR_REAL
deploy:     $DEPLOY_DIR_REAL
out:        $OUT_DIR_REAL
clip list:  $CLIP_LIST_REAL
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

# sim_summary_check <summary.json>
# The decision is made by repro/lib/deploy.py (parse_sim_summary), NOT by
# the shell: one parser for the whole slice.  Prints
#   ok result=<r> joint_err_rms_rad=<v> body_err_mean_m=<v> end_drift_m=<v>
# on success and
#   reason=<reason>
# on failure (exit code 1).
sim_summary_check() {
  "$PY" - "$1" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

summary_path, lib_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

required = ("result", "joint_err_rms_rad", "body_err_mean_m", "end_drift_m")
facts, reason = module.parse_sim_summary(summary_path, required=required)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print("ok result=%s joint_err_rms_rad=%s body_err_mean_m=%s end_drift_m=%s" % (
  facts["result"], facts["joint_err_rms_rad"], facts["body_err_mean_m"],
  facts["end_drift_m"]))
PY
}

# sim_video_check <mp4>
# The decision is made by repro/lib/deploy.py (check_video): the file must
# exist and hold more than zero bytes.
sim_video_check() {
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

# clip_stems — the clip stems of the clip list (one per line, in order).
# The list holds the assets-relative paths (clips/<robot>/<stem>.npz).
clip_stems() {
  local line stem
  [ -f "$CLIP_LIST_REAL" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    [ -n "$line" ] || continue
    stem="$(basename "$line")"
    stem="${stem%.npz}"
    [ -n "$stem" ] && printf '%s\n' "$stem"
  done <"$CLIP_LIST_REAL"
}

# count_clips — the number of clips the list holds (0 when the list is
# missing).
count_clips() {
  local n
  n="$(clip_stems 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

# expand_template <template> — replaces the placeholders {deploy} {assets}
# {robot} {clip} {video} {summary} with shell-quoted values.
expand_template() {
  local template="$1" clip="$2" video="$3" summary="$4"
  local out="$template"
  out="${out//\{deploy\}/$(printf '%q' "$DEPLOY_DIR_REAL")}"
  out="${out//\{assets\}/$(printf '%q' "$ASSETS_DIR_REAL")}"
  out="${out//\{robot\}/$(printf '%q' "$ROBOT")}"
  out="${out//\{clip\}/$(printf '%q' "$clip")}"
  out="${out//\{video\}/$(printf '%q' "$video")}"
  out="${out//\{summary\}/$(printf '%q' "$summary")}"
  printf '%s' "$out"
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
  elog "DEPLOY_SIM_ENV_FAIL reason=$reason"
  return 1
}

env_gate() {
  # (1) the export group must import (onnxruntime + mujoco).
  local probe_out probe_rc
  probe_out="$(eval "$IMPORT_CMD" 2>&1)"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    env_fail "import-failed" \
      "command: $IMPORT_CMD" \
      "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    return 1
  fi

  # (2) the assets directory must exist ...
  if [ ! -d "$ASSETS_DIR_REAL" ]; then
    env_fail "assets-missing" "PATH=$ASSETS_DIR_REAL" || return 1
    return 1
  fi

  # (3) ... and hold the exported scene.
  if [ ! -f "$ASSETS_DIR_REAL/$ROBOT.xml" ]; then
    env_fail "assets-xml-missing" "PATH=$ASSETS_DIR_REAL/$ROBOT.xml" || return 1
    return 1
  fi

  # (4) the ONNX policy must exist.
  if [ ! -f "$DEPLOY_DIR_REAL/policy.onnx" ]; then
    env_fail "policy-missing" "PATH=$DEPLOY_DIR_REAL/policy.onnx" || return 1
    return 1
  fi

  # (5) MUJOCO_GL=egl must be settable (it is what makes the headless
  #     rendering work; deploy.run does not set it).
  MUJOCO_GL=egl
  export MUJOCO_GL
  if [ "${MUJOCO_GL:-}" != "egl" ]; then
    env_fail "mujoco-gl-unset" "MUJOCO_GL=${MUJOCO_GL:-<empty>}" || return 1
    return 1
  fi

  local clips
  clips="$(count_clips)"
  elog_ok "DEPLOY_SIM_ENV_OK robot=$ROBOT clips=$clips"
  flush_ok_markers
  return 0
}

cmd_env() {
  elog "=== 22_sim2sim.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "assets:     $ASSETS_DIR_REAL"
  elog "deploy:     $DEPLOY_DIR_REAL"
  elog "clip list:  $CLIP_LIST_REAL"
  elog "out:        $OUT_DIR_REAL"
  local rc=0
  env_gate || rc=1
  return "$rc"
}

# --- run -------------------------------------------------------------------
# run_fail <reason> [clip] [detail...]
run_fail() {
  local reason="$1" clip="${2:-}" detail="${3:-}"
  if [ -n "$clip" ]; then
    elog "DEPLOY_SIM_CLIP_FAILED clip=$clip reason=$reason"
  fi
  [ -n "$detail" ] && elog "  $detail"
  elog "DEPLOY_SIM_FAIL reason=$reason"
  return 1
}

cmd_run() {
  elog "=== 22_sim2sim.sh run $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "assets:     $ASSETS_DIR_REAL"
  elog "deploy:     $DEPLOY_DIR_REAL"
  elog "clip list:  $CLIP_LIST_REAL"
  elog "out:        $OUT_DIR_REAL"
  elog "limit:      ${LIMIT:-0}"

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
    reason="$(sed -n 's/^DEPLOY_SIM_ENV_FAIL reason=\([a-z-]*\)$/\1/p' "$gate_tmp" | head -n1)"
    rm -f "$gate_tmp"
    elog "  the environment gate failed: reason=${reason:-unknown}"
    elog "DEPLOY_SIM_FAIL reason=${reason:-import-failed}"
    return 1
  fi
  rm -f "$gate_tmp"
  elog "  environment gate: PASS"

  # (1) the clip list must exist and hold more than zero clip.
  if [ ! -f "$CLIP_LIST_REAL" ]; then
    run_fail "clip-list-missing" "" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  local total
  total="$(count_clips)"
  if [ "${total:-0}" -le 0 ]; then
    run_fail "clip-list-empty" "" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  elog "  clips in the list: $total"

  # (2) the landing spot.
  mkdir -p "$SUMMARY_DIR" "$VIDEO_DIR" 2>/dev/null || true
  if [ ! -d "$SUMMARY_DIR" ] || [ ! -d "$VIDEO_DIR" ]; then
    run_fail "outdir-not-creatable" "" "PATH=$OUT_DIR_REAL"
    return 1
  fi

  # (3) the replay, clip by clip.
  local clips=0 completed=0 failed=0 video_ok=0 clip stem summary video cmd rc out
  local started ended elapsed check_out clip_result
  : >"$TIMINGS_FILE"
  while IFS= read -r clip; do
    [ -n "$clip" ] || continue
    if [ "${LIMIT:-0}" -gt 0 ] && [ "$clips" -ge "$LIMIT" ]; then
      break
    fi
    clips=$((clips + 1))
    summary="$SUMMARY_DIR/$clip.json"
    video="$VIDEO_DIR/$clip.mp4"
    rm -f "$summary" "$video" 2>/dev/null || true

    cmd="$(expand_template "$RUN_TEMPLATE" "$clip" "$video" "$summary")"
    # A hung clip (a deadlock in the ZMQ handshake, a MuJoCo stall) must
    # not stall the whole replay: the per-clip wall clock is bounded and a
    # timeout is reported with its own fixed reason.
    if [ "${CLIP_TIMEOUT:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
      cmd="timeout $CLIP_TIMEOUT $cmd"
    fi
    started="$(date +%s)"
    elog "  --- clip $clips/$total: $clip"
    out="$(cd "$REPO_ROOT" && eval "$cmd" 2>&1)"
    rc=$?
    ended="$(date +%s)"
    elapsed=$((ended - started))
    printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      elog "  the replay timed out after ${elapsed}s (timeout=${CLIP_TIMEOUT:-0}s)"
      run_fail "replay-timeout" "$clip" "command: $cmd"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      elog "  the replay command failed (rc=$rc)"
      elog "  $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
      run_fail "run-failed" "$clip" "command: $cmd"
      return 1
    fi

    # (3a) the summary must carry the completion / error / drift numbers.
    check_out="$(sim_summary_check "$summary")"
    if [ $? -ne 0 ]; then
      reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
      run_fail "${reason:-summary-parse-failed}" "$clip" \
        "summary: $summary ($check_out)"
      return 1
    fi
    elog "  summary: $check_out"
    # the result of THIS clip ("completed" / "failed at frame N"): it is
    # kept apart from $check_out, which the video check overwrites.
    clip_result="$(printf '%s\n' "$check_out" | sed -n 's/.*result=\([^ ]*\).*/\1/p' | head -n1)"
    case "$clip_result" in
      completed) completed=$((completed + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac

    # (3b) the video must hold more than zero bytes.
    check_out="$(sim_video_check "$video")"
    if [ $? -ne 0 ]; then
      reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
      run_fail "${reason:-video-empty}" "$clip" "video: $video ($check_out)"
      return 1
    fi
    video_ok=$((video_ok + 1))

    printf '%s\t%s\t%s\n' "$clip" "$elapsed" "$clip_result" >>"$TIMINGS_FILE"
  done <<<"$(clip_stems)"

  if [ "$clips" -le 0 ]; then
    run_fail "clip-list-empty" "" "PATH=$CLIP_LIST_REAL"
    return 1
  fi

  elog "  clips=$clips completed=$completed failed=$failed video_ok=$video_ok"
  elog_ok "DEPLOY_SIM_OK clips=$clips completed=$completed video_ok=$video_ok parity=$clips/$clips"
  flush_ok_markers
  return 0
}

# --- report ----------------------------------------------------------------
cmd_report() {
  elog "=== 22_sim2sim.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "DEPLOY_REPORT_SIDE=sim"
  elog "DEPLOY_REPORT_DIR dir=$OUT_DIR_REAL"
  elog "DEPLOY_REPORT_ROBOT robot=$ROBOT"

  local clips=0 summaries=0 videos=0 completed=0 failed=0
  if [ -d "$SUMMARY_DIR" ]; then
    summaries="$(find "$SUMMARY_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ -d "$VIDEO_DIR" ]; then
    videos="$(find "$VIDEO_DIR" -maxdepth 1 -type f -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ -f "$CLIP_LIST_REAL" ]; then
    clips="$(count_clips)"
  fi
  elog "DEPLOY_REPORT_CLIPS count=$clips"
  elog "DEPLOY_REPORT_SUMMARY count=$summaries"
  elog "DEPLOY_REPORT_VIDEO count=$videos"

  if [ -f "$TIMINGS_FILE" ]; then
    local total_s=0 mean_s=0 min_s="" max_s="" n=0 v
    while IFS=$'\t' read -r _ v _; do
      [ -n "${v:-}" ] || continue
      n=$((n + 1))
      total_s=$((total_s + v))
      if [ -z "$min_s" ] || [ "$v" -lt "$min_s" ]; then min_s="$v"; fi
      if [ -z "$max_s" ] || [ "$v" -gt "$max_s" ]; then max_s="$v"; fi
    done <"$TIMINGS_FILE"
    if [ "$n" -gt 0 ]; then
      mean_s=$((total_s / n))
    else
      min_s=0
      max_s=0
    fi
    elog "DEPLOY_REPORT_WALLCLOCK clips=$n total_s=$total_s mean_s=$mean_s min_s=${min_s:-0} max_s=${max_s:-0}"
    completed="$(awk -F'\t' '$3 == "completed" {n++} END {print n+0}' "$TIMINGS_FILE")"
    failed=$((n - completed))
    elog "DEPLOY_REPORT_COMPLETION completed=$completed failed=$failed"
  else
    elog "DEPLOY_REPORT_WALLCLOCK clips=0 total_s=0 mean_s=0 min_s=0 max_s=0"
  fi
  elog "DEPLOY_REPORT_OK=1"
  return 0
}

# --- selftest --------------------------------------------------------------
cmd_selftest() {
  elog "=== 22_sim2sim.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  eval "$SELFTEST_CMD"
  return $?
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  run)      shift || true
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --limit) LIMIT="${2:-0}"; shift 2 ;;
                --limit=*) LIMIT="${1#*=}"; shift ;;
                --clip-list) CLIP_LIST_REAL="${2:-}"; shift 2 ;;
                --clip-list=*) CLIP_LIST_REAL="${1#*=}"; shift ;;
                *) echo "22_sim2sim.sh: unknown option: $1" >&2; exit 2 ;;
              esac
            done
            cmd_run ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/22_sim2sim.sh <env|run|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
