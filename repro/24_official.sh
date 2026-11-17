#!/usr/bin/env bash
# repro/24_official.sh — the OFFICIAL v0.1 WEIGHTS + SIM2SIM COMPARISON
# orchestrator of the deployment verification (slice S08, task T5).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The milestone requirement R014 asks for a comparison between the policy we
# trained (S06/S07: logs/train/g1_amber_1h/ckpt_26413.pt -> out/g1_amber) and
# the OFFICIAL v0.1 release (github.com/lzyang2000/morphmimic, release v0.1,
# asset morphmimic_policy.zip).
#
# MEASURED FACTS (see logs/env/24_official.txt):
#
#   * the official v0.1 asset holds ONLY the ONNX deployment package:
#         morphmimic_policy/policy.onnx   (69,994,291 bytes)
#         morphmimic_policy/g1_amber.json
#         morphmimic_policy/x2.json
#         morphmimic_policy/t2.json
#         morphmimic_policy/MANIFEST.txt
#         morphmimic_policy/SHA256SUMS    (covers exactly those FOUR files)
#     There is NO PyTorch checkpoint in it.
#   * morphmimic.scripts.eval loads its policy with torch.load ONLY, so the
#     eval script CANNOT score the official ONNX package.
#
# => "score the official weights with the same eval script" is physically
#    impossible.  The comparison surface is therefore the SIM2SIM side: the
#    self-trained out/g1_amber and the official morphmimic_policy are run
#    over the SAME assets, the SAME clip list and the SAME deploy.run
#    command; only the --deploy directory changes.  This deviation is
#    recorded for S09 (DEPLOY.md section 2).
#
# The comparison table is per clip:
#   clip, frames,
#   self_result, self_joint_err_rms_rad, self_body_err_mean_m, self_end_drift_m,
#   official_result, official_joint_err_rms_rad, official_body_err_mean_m,
#   official_end_drift_m,
#   delta_joint_err_rms_rad, delta_body_err_mean_m, delta_end_drift_m
# with delta = self - official.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the fail-closed environment gate (seconds, no network):
#            the export group imports (onnxruntime + mujoco), the assets
#            directory holds <robot>.xml, the official directory is present
#            and the clip list is readable.
#            Success prints ONE line
#                DEPLOY_OFFICIAL_ENV_OK robot=<robot> clips=<n>
#            failure prints ONE line
#                DEPLOY_OFFICIAL_ENV_FAIL reason=<fixed reason set>
#
#   download fetch + unpack the official release:
#              1. the zip is downloaded through the PROCESS-SCOPED proxy
#                 (repro/lib/common.sh inlines it; it is NEVER written to any
#                 system configuration),
#              2. the zip is unpacked next to it (the archive carries its own
#                 morphmimic_policy/ top level directory),
#              3. the byte count and the file list are logged.
#            Success prints ONE line
#                DEPLOY_OFFICIAL_DOWNLOAD_OK bytes=<n> files=<n>
#
#   verify   the integrity gate:
#              1. repro/lib/deploy.py verifies the directory: policy.onnx
#                 non-empty, <robot>.json non-empty, SHA256SUMS present and
#                 covering policy.onnx AND <robot>.json (the official
#                 SHA256SUMS covers FOUR files -- policy.onnx, g1_amber.json,
#                 t2.json, x2.json -- and the two extra entries are NOT a
#                 failure),
#              2. `cd <dir> && sha256sum -c SHA256SUMS` is REALLY executed:
#                 every listed file must report OK and the number of OK
#                 lines must equal the number of entries.
#            Success prints ONE line
#                DEPLOY_OFFICIAL_OK files=<n> sha_files=<n>
#
#   compare  the sim2sim comparison:
#              1. the SAME-ORIGIN GUARD: the <robot>.json and the
#                 policy.onnx of the deploy directory must be the ones the
#                 official SHA256SUMS covers.  Mixing our own g1_amber.json
#                 into the official directory (the normalisers would not
#                 match) is refused with reason=mixed-json.
#              2. every clip of the T3 clip list (assets/clips_<robot>.txt)
#                 is replayed with the official deploy directory:
#                    MUJOCO_GL=egl <uv> python -m deploy.run
#                    --deploy <official dir> --assets assets --robot <robot>
#                    --clip <stem> --interface motion
#                    --video <mp4> --summary <json>
#              3. the comparison table is built by repro/lib/deploy.py from
#                 the self summaries (runs/sim2sim/summary) and the official
#                 ones (runs/official/sim2sim/summary) and verified: one row
#                 per clip of the list, both sides complete, the deltas
#                 present.
#            Success prints ONE line
#                DEPLOY_OFFICIAL_COMPARE_OK rows=<n>
#
#   report   the official-side self report (DEPLOY_REPORT_*): the official
#            file list, the digest coverage, the comparison row count and
#            the mean of the three deltas.
#
#   selftest the offline battery: repro/tests/test_deploy_official.sh.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SET (greppable)
#
#   env gate:   import-failed  assets-missing  assets-xml-missing
#               clip-list-missing  clip-list-empty  official-dir-missing
#   download:   download-failed  zip-missing  zip-extract-failed
#               official-dir-missing
#   verify:     official-dir-missing  official-sha-missing
#               official-sha-mismatch  official-onnx-missing
#               official-json-missing  sha-lines-mismatch
#   compare:    mixed-json  summary-count-mismatch  summary-missing
#               summary-field-missing  summary-value-empty  video-missing
#               video-empty  run-failed  replay-timeout  compare-missing
#               compare-parse-failed  compare-row-mismatch
#
# The official-* / summary-* / compare-* reasons are the ones
# repro/lib/deploy.py produces (deploy.REASONS): the orchestrator and the
# decision base share ONE vocabulary.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without a GPU,
# without EGL and without the network)
#
#   OFFICIAL_ALLOW_LOCAL=1  allow running outside the ros_dev container
#   OFFICIAL_URL            the release asset URL
#   OFFICIAL_DOWNLOAD_CMD   the download command (placeholders {zip} {url});
#                           the default is curl through the proxy
#   OFFICIAL_DOWNLOAD_TIMEOUT  the curl timeout in seconds (default 900)
#   OFFICIAL_OUT_DIR        the landing spot of the release (default
#                           <repo>/runs/official)
#   OFFICIAL_ZIP            the downloaded zip (default
#                           <OFFICIAL_OUT_DIR>/morphmimic_policy.zip)
#   OFFICIAL_DIR            the unpacked policy directory (default
#                           <OFFICIAL_OUT_DIR>/morphmimic_policy)
#   OFFICIAL_SIM_OUT_DIR    the official replay landing spot (default
#                           <repo>/runs/official/sim2sim)
#   OFFICIAL_SELF_SIM_DIR   the self replay landing spot of T3 (default
#                           <repo>/runs/sim2sim)
#   OFFICIAL_COMPARE_CSV    the comparison table (default
#                           <repo>/runs/official/compare_self_vs_official.csv)
#   OFFICIAL_ASSETS_DIR     the assets directory (default <repo>/assets)
#   OFFICIAL_CLIP_LIST      the clip list (default
#                           <assets>/clips_<robot>.txt)
#   OFFICIAL_ROBOT          the robot name (default g1_amber)
#   OFFICIAL_UV_BIN         uv binary (default uv)
#   OFFICIAL_UV_ARGS        uv arguments (default
#                           run --group export --frozen --offline)
#   OFFICIAL_IMPORT_CMD     the import probe
#   OFFICIAL_RUN_TEMPLATE   the replay command template (placeholders
#                           {deploy} {assets} {robot} {clip} {video} {summary})
#   OFFICIAL_CLIP_TIMEOUT   the per-clip wall clock timeout (default 900)
#   OFFICIAL_LIMIT          replay only the first N clips (0 = all)
#   OFFICIAL_PY             the decision-base interpreter (default python3)
#   OFFICIAL_LOG_DIR        the log directory (default $LOG_DIR)
#   OFFICIAL_SELFTEST_CMD   the offline battery command
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

if [ "${OFFICIAL_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${OFFICIAL_LOG_DIR:-$LOG_DIR}"
mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
MAIN_LOG="$LOG_DIR_REAL/24_official.txt"

ROBOT="${OFFICIAL_ROBOT:-g1_amber}"
ROBOT_JSON="$ROBOT.json"
OFFICIAL_OUT_DIR_REAL="${OFFICIAL_OUT_DIR:-$REPO_ROOT/runs/official}"
OFFICIAL_ZIP_REAL="${OFFICIAL_ZIP:-$OFFICIAL_OUT_DIR_REAL/morphmimic_policy.zip}"
OFFICIAL_DIR_REAL="${OFFICIAL_DIR:-$OFFICIAL_OUT_DIR_REAL/morphmimic_policy}"
OFFICIAL_SIM_OUT_REAL="${OFFICIAL_SIM_OUT_DIR:-$REPO_ROOT/runs/official/sim2sim}"
SELF_SIM_DIR_REAL="${OFFICIAL_SELF_SIM_DIR:-$REPO_ROOT/runs/sim2sim}"
COMPARE_CSV_REAL="${OFFICIAL_COMPARE_CSV:-$REPO_ROOT/runs/official/compare_self_vs_official.csv}"
ASSETS_DIR_REAL="${OFFICIAL_ASSETS_DIR:-$REPO_ROOT/assets}"
CLIP_LIST_REAL="${OFFICIAL_CLIP_LIST:-$ASSETS_DIR_REAL/clips_$ROBOT.txt}"
OFFICIAL_URL_REAL="${OFFICIAL_URL:-https://github.com/lzyang2000/morphmimic/releases/download/v0.1/morphmimic_policy.zip}"
DOWNLOAD_TIMEOUT="${OFFICIAL_DOWNLOAD_TIMEOUT:-900}"
CLIP_TIMEOUT="${OFFICIAL_CLIP_TIMEOUT:-900}"
LIMIT="${OFFICIAL_LIMIT:-0}"
PY="${OFFICIAL_PY:-python3}"
UV_BIN="${OFFICIAL_UV_BIN:-uv}"
UV_ARGS="${OFFICIAL_UV_ARGS:-run --group export --frozen --offline}"
IMPORT_CMD="${OFFICIAL_IMPORT_CMD:-$UV_BIN $UV_ARGS python -c 'import onnxruntime, mujoco'}"
SELFTEST_CMD="${OFFICIAL_SELFTEST_CMD:-bash $REPO_ROOT/repro/tests/test_deploy_official.sh}"
DEPLOY_LIB="$REPO_ROOT/repro/lib/deploy.py"

SUMMARY_DIR="$OFFICIAL_SIM_OUT_REAL/summary"
VIDEO_DIR="$OFFICIAL_SIM_OUT_REAL/video"
TIMINGS_FILE="$OFFICIAL_SIM_OUT_REAL/timings.tsv"
SELF_SUMMARY_DIR="$SELF_SIM_DIR_REAL/summary"

usage() {
  cat <<EOF
usage: bash repro/24_official.sh <subcommand> [options]

  env       the fail-closed environment gate (DEPLOY_OFFICIAL_ENV_OK / _FAIL)
  download  fetch + unpack the official v0.1 release
            (DEPLOY_OFFICIAL_DOWNLOAD_OK / _FAIL reason=...)
  verify    the integrity gate (DEPLOY_OFFICIAL_OK files=<n> sha_files=<n>)
  compare   the sim2sim comparison (DEPLOY_OFFICIAL_COMPARE_OK rows=<n>)
            options: --limit N
  report    the official-side self report (DEPLOY_REPORT_*)
  selftest  the offline battery (repro/tests/test_deploy_official.sh)

robot:        $ROBOT
official dir: $OFFICIAL_DIR_REAL
zip:          $OFFICIAL_ZIP_REAL
assets:       $ASSETS_DIR_REAL
clip list:    $CLIP_LIST_REAL
self sim:     $SELF_SIM_DIR_REAL
official sim: $OFFICIAL_SIM_OUT_REAL
compare csv:  $COMPARE_CSV_REAL
log:          $MAIN_LOG
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

# official_fail <reason> [detail...] — the ONLY failure exit: it prints the
# fail marker (and the details) and returns 1.  It NEVER prints an OK marker.
official_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_OFFICIAL_FAIL reason=$reason"
  return 1
}

# --- helpers ---------------------------------------------------------------
rel_to_repo() {
  local p="$1"
  case "$p" in
    "$REPO_ROOT"/*) printf '%s' "${p#"$REPO_ROOT"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# clip_stems — the clip stems of the clip list (one per line, in order).
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

count_clips() {
  local n
  n="$(clip_stems 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

# expand_template <template> <clip> <video> <summary> — replaces the
# placeholders with shell-quoted values.
expand_template() {
  local template="$1" clip="$2" video="$3" summary="$4"
  local out="$template"
  out="${out//\{deploy\}/$(printf '%q' "$OFFICIAL_DIR_REAL")}"
  out="${out//\{assets\}/$(printf '%q' "$ASSETS_DIR_REAL")}"
  out="${out//\{robot\}/$(printf '%q' "$ROBOT")}"
  out="${out//\{clip\}/$(printf '%q' "$clip")}"
  out="${out//\{video\}/$(printf '%q' "$video")}"
  out="${out//\{summary\}/$(printf '%q' "$summary")}"
  printf '%s' "$out"
}

# summary_check <summary.json> — the decision is made by repro/lib/deploy.py
# (parse_sim_summary), NOT by the shell: ONE parser for the whole slice.
summary_check() {
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

# same_origin_check — the MIXING GUARD.  The <robot>.json and the
# policy.onnx of the deploy directory must be the ones the official
# SHA256SUMS covers: our own g1_amber.json must never be mixed into the
# official directory (the normalisers would not match the policy).
# Prints "reason=<reason>" and exits 1 on failure.
same_origin_check() {
  "$PY" - "$OFFICIAL_DIR_REAL" "$ROBOT_JSON" "$DEPLOY_LIB" <<'PY'
import importlib.util
import os
import sys

directory, robot_json, lib_path = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

entries, reason = module.read_sha256sums(directory)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)

for name in ("policy.onnx", robot_json):
  path = os.path.join(directory, name)
  if name not in entries:
    print("reason=mixed-json")
    sys.stdout.write("  %s is not covered by the official SHA256SUMS\n" % name)
    sys.exit(1)
  if not os.path.isfile(path):
    print("reason=official-sha-missing")
    sys.exit(1)
  digest = module._sha256_file(path)
  if digest is None or digest != entries[name]:
    print("reason=mixed-json")
    sys.stdout.write("  %s does not match the official SHA256SUMS\n" % name)
    sys.exit(1)
print("ok policy=%s json=%s" % (entries["policy.onnx"], entries[robot_json]))
PY
}

# --- env gate --------------------------------------------------------------
# env_fail <reason> [detail...] — the failure exit of the environment gate.
# It prints the DEPLOY_OFFICIAL_ENV_FAIL marker and NEVER an OK marker.
env_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_OFFICIAL_ENV_FAIL reason=$reason"
  return 1
}

env_gate() {
  local probe_out probe_rc
  probe_out="$(eval "$IMPORT_CMD" 2>&1)"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    env_fail "import-failed" "command: $IMPORT_CMD" \
      "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  if [ ! -d "$ASSETS_DIR_REAL" ]; then
    env_fail "assets-missing" "PATH=$ASSETS_DIR_REAL"
    return 1
  fi
  if [ ! -f "$ASSETS_DIR_REAL/$ROBOT.xml" ]; then
    env_fail "assets-xml-missing" "PATH=$ASSETS_DIR_REAL/$ROBOT.xml"
    return 1
  fi
  if [ ! -f "$CLIP_LIST_REAL" ]; then
    env_fail "clip-list-missing" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  local clips
  clips="$(count_clips)"
  if [ "${clips:-0}" -le 0 ]; then
    env_fail "clip-list-empty" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  if [ ! -d "$OFFICIAL_DIR_REAL" ]; then
    env_fail "official-dir-missing" "PATH=$OFFICIAL_DIR_REAL" \
      "hint: run 'bash repro/24_official.sh download' first"
    return 1
  fi
  elog_ok "DEPLOY_OFFICIAL_ENV_OK robot=$ROBOT clips=$clips"
  flush_ok_markers
  return 0
}

cmd_env() {
  elog "=== 24_official.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:        $ROBOT"
  elog "official dir: $OFFICIAL_DIR_REAL"
  elog "assets:       $ASSETS_DIR_REAL"
  elog "clip list:    $CLIP_LIST_REAL"
  elog "compare csv:  $COMPARE_CSV_REAL"
  local rc=0
  env_gate || rc=1
  return "$rc"
}

# --- download --------------------------------------------------------------
cmd_download() {
  elog "=== 24_official.sh download $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "url:        $OFFICIAL_URL_REAL"
  elog "zip:        $OFFICIAL_ZIP_REAL"
  elog "unpack to:  $OFFICIAL_OUT_DIR_REAL"
  mkdir -p "$OFFICIAL_OUT_DIR_REAL" 2>/dev/null || true
  if [ ! -d "$OFFICIAL_OUT_DIR_REAL" ]; then
    official_fail "download-failed" "cannot create $OFFICIAL_OUT_DIR_REAL"
    return 1
  fi

  local cmd out rc
  if [ -n "${OFFICIAL_DOWNLOAD_CMD:-}" ]; then
    cmd="${OFFICIAL_DOWNLOAD_CMD//\{zip\}/$(printf '%q' "$OFFICIAL_ZIP_REAL")}"
    cmd="${cmd//\{url\}/$(printf '%q' "$OFFICIAL_URL_REAL")}"
  else
    cmd="curl -sS -L --fail --max-time $DOWNLOAD_TIMEOUT -o $(printf '%q' "$OFFICIAL_ZIP_REAL") $(printf '%q' "$OFFICIAL_URL_REAL")"
  fi
  elog "command:    $cmd"
  rm -f "$OFFICIAL_ZIP_REAL" 2>/dev/null || true
  out="$(cd "$REPO_ROOT" && eval "$cmd" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    official_fail "download-failed" "rc=$rc" \
      "$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  if [ ! -s "$OFFICIAL_ZIP_REAL" ]; then
    official_fail "zip-missing" "PATH=$OFFICIAL_ZIP_REAL"
    return 1
  fi
  local bytes
  bytes="$(wc -c <"$OFFICIAL_ZIP_REAL" | tr -d ' ')"
  elog "  zip bytes: $bytes"

  # the archive carries its own morphmimic_policy/ top level directory
  out="$(cd "$OFFICIAL_OUT_DIR_REAL" && unzip -o -q "$OFFICIAL_ZIP_REAL" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    official_fail "zip-extract-failed" "rc=$rc" \
      "$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  if [ ! -d "$OFFICIAL_DIR_REAL" ]; then
    official_fail "official-dir-missing" "PATH=$OFFICIAL_DIR_REAL"
    return 1
  fi
  local files
  files="$(find "$OFFICIAL_DIR_REAL" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  elog "  unpacked files:"
  find "$OFFICIAL_DIR_REAL" -maxdepth 1 -type f -printf '    %f %s bytes\n' 2>/dev/null \
    | sort >>"$MAIN_LOG" 2>/dev/null || true
  elog_ok "DEPLOY_OFFICIAL_DOWNLOAD_OK bytes=$bytes files=$files"
  flush_ok_markers
  return 0
}

# --- verify ----------------------------------------------------------------
cmd_verify() {
  elog "=== 24_official.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "official dir: $OFFICIAL_DIR_REAL"

  # (1) the decision base: the directory, the files, the digest coverage.
  local out rc reason
  out="$("$PY" "$DEPLOY_LIB" official --dir "$OFFICIAL_DIR_REAL" \
        --require policy.onnx --require "$ROBOT_JSON" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(printf '%s\n' "$out" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -n1)"
    official_fail "${reason:-official-dir-missing}" "$out"
    return 1
  fi
  elog "  decision base: $(printf '%s\n' "$out" | sed -n 's/^DEPLOY_OFFICIAL_OK //p' | head -n1)"

  # (2) the REAL `sha256sum -c`: every listed file must report OK.
  local sha_out sha_rc ok_lines bad_lines entries
  sha_out="$(cd "$OFFICIAL_DIR_REAL" && sha256sum -c SHA256SUMS 2>&1)"
  sha_rc=$?
  printf '%s\n' "$sha_out" >>"$MAIN_LOG" 2>/dev/null || true
  ok_lines="$(printf '%s\n' "$sha_out" | grep -c ': OK$' || true)"
  bad_lines="$(printf '%s\n' "$sha_out" | grep -c 'FAILED' || true)"
  entries="$(grep -c '^[0-9a-fA-F]\{64\} ' "$OFFICIAL_DIR_REAL/SHA256SUMS" 2>/dev/null || true)"
  elog "  sha256sum -c: rc=$sha_rc ok=$ok_lines failed=$bad_lines entries=$entries"
  if [ "$sha_rc" -ne 0 ] || [ "${bad_lines:-0}" -gt 0 ]; then
    official_fail "official-sha-mismatch" \
      "$(printf '%s\n' "$sha_out" | grep -v ': OK$' | head -n 5 | tr '\n' ' ')"
    return 1
  fi
  if [ "${ok_lines:-0}" -ne "${entries:-0}" ] || [ "${entries:-0}" -le 0 ]; then
    official_fail "sha-lines-mismatch" "ok_lines=$ok_lines entries=$entries"
    return 1
  fi

  # (3) the marker (the format comes from repro/lib/deploy.py).
  out="$("$PY" - "$OFFICIAL_DIR_REAL" "$ROBOT_JSON" "$ok_lines" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

directory, robot_json, sha_files, lib_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

facts, reason = module.verify_official_dir(
    directory, require_covered=("policy.onnx", robot_json))
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print(module.format_ok("DEPLOY_OFFICIAL",
                       files=len(facts.get("files") or []),
                       sha_files=sha_files))
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(printf '%s\n' "$out" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -n1)"
    official_fail "${reason:-official-dir-missing}" "$out"
    return 1
  fi
  elog_ok "$out"
  flush_ok_markers
  return 0
}

# --- compare ---------------------------------------------------------------
cmd_compare() {
  elog "=== 24_official.sh compare $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "official dir: $OFFICIAL_DIR_REAL"
  elog "self sim:     $SELF_SIM_DIR_REAL"
  elog "official sim: $OFFICIAL_SIM_OUT_REAL"
  elog "compare csv:  $COMPARE_CSV_REAL"
  elog "clip list:    $CLIP_LIST_REAL"
  elog "limit:        ${LIMIT:-0}"

  # (1) the MIXING GUARD: the official deploy directory must be the
  #     untouched official package.
  local guard_out guard_rc reason
  guard_out="$(same_origin_check 2>&1)"
  guard_rc=$?
  if [ "$guard_rc" -ne 0 ]; then
    reason="$(printf '%s\n' "$guard_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    official_fail "${reason:-mixed-json}" "$guard_out"
    return 1
  fi
  elog "  same-origin guard: $guard_out"

  # (2) the clip list and the self summaries.
  if [ ! -f "$CLIP_LIST_REAL" ]; then
    official_fail "clip-list-missing" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  local total
  total="$(count_clips)"
  if [ "${total:-0}" -le 0 ]; then
    official_fail "clip-list-empty" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  elog "  clips in the list: $total"

  out="$("$PY" "$DEPLOY_LIB" sim --dir "$SELF_SUMMARY_DIR" --expect-count "$total" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(printf '%s\n' "$out" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -n1)"
    official_fail "${reason:-summary-missing}" "$out" \
      "the self summaries of 22_sim2sim.sh are missing"
    return 1
  fi
  elog "  self summaries: files=$(printf '%s\n' "$out" | sed -n 's/.*files=\([0-9]*\).*/\1/p' | head -n1) expected=$total"

  # (3) the replay with the OFFICIAL deploy directory.
  mkdir -p "$SUMMARY_DIR" "$VIDEO_DIR" 2>/dev/null || true
  if [ ! -d "$SUMMARY_DIR" ] || [ ! -d "$VIDEO_DIR" ]; then
    official_fail "run-failed" "cannot create $OFFICIAL_SIM_OUT_REAL"
    return 1
  fi
  local clips=0 completed=0 failed=0 video_ok=0 clip summary video cmd started ended elapsed check_out clip_result
  local out rc
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

    cmd="$(expand_template "${OFFICIAL_RUN_TEMPLATE:-}" "$clip" "$video" "$summary")"
    if [ -z "$cmd" ]; then
      cmd="$UV_BIN $UV_ARGS python -m deploy.run --deploy $(printf '%q' "$OFFICIAL_DIR_REAL") --assets $(printf '%q' "$ASSETS_DIR_REAL") --robot $(printf '%q' "$ROBOT") --clip $(printf '%q' "$clip") --interface motion --video $(printf '%q' "$video") --summary $(printf '%q' "$summary")"
    fi
    if [ "${CLIP_TIMEOUT:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
      cmd="timeout $CLIP_TIMEOUT $cmd"
    fi
    started="$(date +%s)"
    elog "  --- official clip $clips/$total: $clip"
    out="$(cd "$REPO_ROOT" && MUJOCO_GL=egl eval "$cmd" 2>&1)"
    rc=$?
    ended="$(date +%s)"
    elapsed=$((ended - started))
    printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      official_fail "replay-timeout" "clip=$clip" "command: $cmd"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      official_fail "run-failed" "clip=$clip rc=$rc" \
        "$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
      return 1
    fi

    check_out="$(summary_check "$summary")"
    if [ $? -ne 0 ]; then
      reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
      official_fail "${reason:-summary-parse-failed}" "clip=$clip summary=$summary"
      return 1
    fi
    clip_result="$(printf '%s\n' "$check_out" | sed -n 's/.*result=\([^ ]*\).*/\1/p' | head -n1)"
    case "$clip_result" in
      completed) completed=$((completed + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac

    check_out="$(video_check "$video")"
    if [ $? -ne 0 ]; then
      reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
      official_fail "${reason:-video-empty}" "clip=$clip video=$video"
      return 1
    fi
    video_ok=$((video_ok + 1))
    printf '%s\t%s\t%s\n' "$clip" "$elapsed" "$clip_result" >>"$TIMINGS_FILE"
  done <<<"$(clip_stems)"

  if [ "$clips" -le 0 ]; then
    official_fail "clip-list-empty" "PATH=$CLIP_LIST_REAL"
    return 1
  fi
  elog "  official clips=$clips completed=$completed failed=$failed video_ok=$video_ok"

  # (4) the comparison table (built by the decision base).
  mkdir -p "$(dirname "$COMPARE_CSV_REAL")" 2>/dev/null || true
  out="$("$PY" "$DEPLOY_LIB" compare-build --self-dir "$SELF_SUMMARY_DIR" \
        --official-dir "$SUMMARY_DIR" --out "$COMPARE_CSV_REAL" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(printf '%s\n' "$out" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -n1)"
    official_fail "${reason:-compare-missing}" "$out"
    return 1
  fi

  # (5) the verdict: one row per clip, both sides complete, deltas present.
  out="$("$PY" "$DEPLOY_LIB" compare --path "$COMPARE_CSV_REAL" --expect-rows "$clips" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(printf '%s\n' "$out" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -n1)"
    official_fail "${reason:-compare-row-mismatch}" "$out" \
      "the comparison table must hold one row per clip ($clips)"
    return 1
  fi
  elog "  comparison table: rows=$(printf '%s\n' "$out" | sed -n 's/.*rows=\([0-9]*\).*/\1/p' | head -n1) expected=$clips"
  elog_ok "DEPLOY_OFFICIAL_COMPARE_OK rows=$clips"
  flush_ok_markers
  return 0
}

# --- report ----------------------------------------------------------------
cmd_report() {
  elog "=== 24_official.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "DEPLOY_REPORT_SIDE=official"
  elog "DEPLOY_REPORT_DIR dir=$OFFICIAL_DIR_REAL"
  elog "DEPLOY_REPORT_ROBOT robot=$ROBOT"

  local files=0 sha_files=0
  if [ -d "$OFFICIAL_DIR_REAL" ]; then
    files="$(find "$OFFICIAL_DIR_REAL" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    sha_files="$(grep -c '^[0-9a-fA-F]\{64\} ' "$OFFICIAL_DIR_REAL/SHA256SUMS" 2>/dev/null || echo 0)"
  fi
  elog "DEPLOY_REPORT_OFFICIAL_FILES count=$files"
  elog "DEPLOY_REPORT_OFFICIAL_SHA count=$sha_files"

  local rows=0
  if [ -f "$COMPARE_CSV_REAL" ]; then
    rows="$(($(wc -l <"$COMPARE_CSV_REAL") - 1))"
  fi
  elog "DEPLOY_REPORT_COMPARE_ROWS rows=$rows"

  if [ -f "$COMPARE_CSV_REAL" ]; then
    local means
    means="$(awk -F',' 'NR > 1 {
        n++;
        j += $11; b += $12; d += $13;
      } END {
        if (n > 0) printf "joint=%.6f body=%.6f drift=%.6f", j/n, b/n, d/n;
      }' "$COMPARE_CSV_REAL")"
    elog "DEPLOY_REPORT_COMPARE_MEAN_DELTA $means"
  fi
  if [ -f "$TIMINGS_FILE" ]; then
    local total_s=0 mean_s=0 n=0 v
    while IFS=$'\t' read -r _ v _; do
      [ -n "${v:-}" ] || continue
      n=$((n + 1)); total_s=$((total_s + v))
    done <"$TIMINGS_FILE"
    [ "$n" -gt 0 ] && mean_s=$((total_s / n))
    elog "DEPLOY_REPORT_WALLCLOCK clips=$n total_s=$total_s mean_s=$mean_s"
  fi
  elog "DEPLOY_REPORT_OK=1"
  return 0
}

# --- selftest --------------------------------------------------------------
cmd_selftest() {
  elog "=== 24_official.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  eval "$SELFTEST_CMD"
  return $?
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  download) shift || true; cmd_download "$@" ;;
  verify)   shift || true; cmd_verify "$@" ;;
  compare)  shift || true
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --limit) LIMIT="${2:-0}"; shift 2 ;;
                --limit=*) LIMIT="${1#*=}"; shift ;;
                *) echo "24_official.sh: unknown option: $1" >&2; exit 2 ;;
              esac
            done
            cmd_compare ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/24_official.sh <env|download|verify|compare|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
