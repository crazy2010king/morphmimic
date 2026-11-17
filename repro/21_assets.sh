#!/usr/bin/env bash
# repro/21_assets.sh — the ASSET EXPORT ORCHESTRATOR of the deployment
# verification (slice S08, task T2).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# `deploy.run --assets <dir>` needs a directory that holds
#
#     <robot>.xml                 the exported scene (MJCF)
#     meshes/<robot>/*            the meshes the scene refers to
#     clips/<robot>/<clip>.npz    one reference clip per replay
#
# The only producer is the upstream exporter
#
#     uv run python -m deploy.sim2sim.export_assets --robot <robot> \
#         --subset-yaml <yaml> --clips <stem>... --out <dir>
#
# which needs mjlab + a GPU and which writes DIRECTLY into --out.  A failed
# export therefore leaves a half-written directory behind, and the assets are
# binary artefacts (meshes + one npz per clip) that must never enter git and
# must not live in the worktree (GSD removes untracked files when a worktree
# is rebuilt).  So this script implements the S07 staging contract:
#
#     export into a STAGING directory -> verify the staging directory with
#     the decision base (repro/lib/deploy.py) -> publish atomically into the
#     formal landing spot <assets>/.  Every failure path deletes the staging
#     directory and leaves the formal landing spot UNTOUCHED.
#
# The assets live in the seed store (repro/lib/seed_store.sh links
# data/ logs/ out/ assets/ into it), so they survive a worktree rebuild.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the fail-closed ENVIRONMENT GATE (seconds): the export group
#            imports (mjlab + mujoco), the 1h subset yaml exists and holds
#            more than zero clips, the landing spot is writable.
#            Success prints ONE line
#                DEPLOY_ASSETS_ENV_OK clips=<n> sampled=<m> robot=<robot>
#            failure prints ONE line
#                DEPLOY_ASSETS_ENV_FAIL reason=<fixed reason set>
#            and exits non-zero.  The OK marker is BUFFERED and flushed only
#            when EVERY check passed (project convention P004).
#
#   export   the pipeline:
#              1. the environment gate MUST pass -- otherwise nothing is
#                 exported at all,
#              2. the sample of clips is computed from the subset yaml with
#                 the FIXED sampling rule (see below),
#              3. the upstream exporter writes into the staging directory,
#              4. the decision base verifies the staging directory
#                 (scene xml, one non-empty npz per sampled clip),
#              5. only then the staging directory is published into the
#                 formal landing spot.
#            Success prints ONE line
#                DEPLOY_ASSETS_OK clips=<n> xml=assets/<robot>.xml
#            failure prints ONE line
#                DEPLOY_ASSETS_FAIL reason=<fixed reason set>
#
#   report   the asset-side self report (DEPLOY_REPORT_*): the size of the
#            scene xml, the number of meshes, the number of clips and the
#            sampling rule that produced the clip list.
#
#   selftest the offline battery: repro/tests/test_deploy_assets.sh.
#
# ---------------------------------------------------------------------------
# THE SAMPLING RULE (fixed, written down in the script and echoed in the
# report so the documentation can quote it)
#
#   The 1h subset holds 490 clips.  The sample takes EVERY 10th clip of the
#   subset, in the order of the subset list: the indices 0, 10, 20, ..., 480
#   -> 49 clips.  The list is written to <assets>/clips_<robot>.txt with the
#   path of every exported clip RELATIVE to the assets directory
#   (clips/<robot>/<clip>.npz), so the replay (S08-T3) and the official
#   comparison (S08-T5) can reuse exactly the same clip list.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SETS (greppable)
#
#   env gate:    interpreter-missing  import-failed  subset-missing
#                subset-empty        assets-not-writable
#   export gate: export-failed         staging-verify-failed
#                publish-failed
#
# The staging verification itself is decided by the decision base
# (repro/lib/deploy.py: assets-missing / assets-xml-missing /
# assets-clips-missing / assets-clips-mismatch) plus two byte-level checks
# that only the orchestrator can make (assets-xml-empty / assets-clip-empty).
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without a GPU and
# without the real exporter)
#
#   ASSETS_ALLOW_LOCAL=1     allow running outside the ros_dev container
#   ASSETS_DIR               formal landing spot (default <repo>/assets)
#   ASSETS_SUBSET_YAML       the subset yaml (default
#                             data/seed_g1_npz50/subsets/1h.yaml)
#   ASSETS_ROBOT             robot name (default g1_amber)
#   ASSETS_SAMPLE_STRIDE     the sampling stride (default 10)
#   ASSETS_LOG_DIR           log directory (default $LOG_DIR)
#   ASSETS_PY                the decision-base interpreter (default python3)
#   ASSETS_UV_BIN            uv binary (default uv)
#   ASSETS_UV_ARGS           uv arguments (default
#                             run --group export --frozen --offline)
#   ASSETS_IMPORT_CMD        the import probe (default
#                             "<uv> <uv args> python -c 'import mjlab, mujoco'")
#   ASSETS_EXPORT_CMD        the upstream exporter (default
#                             "<uv> <uv args> python -m
#                              deploy.sim2sim.export_assets")
#   ASSETS_STAGING_DIR       staging directory (default
#                             <assets>/.staging-<pid>)
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/deploy.sh
source "$_SCRIPT_DIR/lib/deploy.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 19_export.sh / 20_export_verify.sh
# convention).
set +e

if [ "${ASSETS_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${ASSETS_LOG_DIR:-$LOG_DIR}"
mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
MAIN_LOG="$LOG_DIR_REAL/21_assets.txt"

ROBOT="${ASSETS_ROBOT:-g1_amber}"
ASSETS_DIR_REAL="${ASSETS_DIR:-$REPO_ROOT/assets}"
SUBSET_YAML="${ASSETS_SUBSET_YAML:-$REPO_ROOT/data/seed_g1_npz50/subsets/1h.yaml}"
STRIDE="${ASSETS_SAMPLE_STRIDE:-10}"
PY="${ASSETS_PY:-python3}"
UV_BIN="${ASSETS_UV_BIN:-uv}"
UV_ARGS="${ASSETS_UV_ARGS:-run --group export --frozen --offline}"
IMPORT_CMD="${ASSETS_IMPORT_CMD:-$UV_BIN $UV_ARGS python -c 'import mjlab, mujoco'}"
EXPORT_CMD="${ASSETS_EXPORT_CMD:-$UV_BIN $UV_ARGS python -m deploy.sim2sim.export_assets}"
STAGING_DIR="${ASSETS_STAGING_DIR:-$ASSETS_DIR_REAL/.staging-$$}"
SELFTEST_CMD="${ASSETS_SELFTEST_CMD:-bash $REPO_ROOT/repro/tests/test_deploy_assets.sh}"

# The clip list of the sample (relative to the assets directory).
CLIP_LIST_NAME="clips_$ROBOT.txt"
CLIP_LIST_PATH="$ASSETS_DIR_REAL/$CLIP_LIST_NAME"

usage() {
  cat <<EOF
usage: bash repro/21_assets.sh <subcommand>

  env       the fail-closed environment gate (DEPLOY_ASSETS_ENV_OK / _FAIL)
  export    env gate -> staging export -> verify -> atomic publish
            (DEPLOY_ASSETS_OK / DEPLOY_ASSETS_FAIL reason=...)
  report    the asset-side self report (DEPLOY_REPORT_*)
  selftest  the offline battery (repro/tests/test_deploy_assets.sh)

robot:      $ROBOT
assets dir: $ASSETS_DIR_REAL
subset:     $SUBSET_YAML
stride:     $STRIDE
staging:    $STAGING_DIR
log:        $MAIN_LOG
EOF
}

# --- output ----------------------------------------------------------------
# Every marker is written to stdout AND appended to the log file, so the log
# file is greppable after the fact.
elog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed ONLY when every check passed.
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

# subset_clips — the clip stems of the subset yaml, in the order of the
# list.  The yaml is a flat list of "- <path>.npz" entries; the stem is the
# name the upstream `resolve_clip` matches on.
subset_clips() {
  awk '
    /^[[:space:]]*-[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^"|"$/, "", line)
      n = split(line, parts, "/")
      name = parts[n]
      sub(/\.npz$/, "", name)
      if (name != "") print name
    }
  ' "$SUBSET_YAML"
}

# sample_clips — the SAMPLE of the subset list: every STRIDE-th clip, i.e.
# the indices 0, STRIDE, 2*STRIDE, ... of the subset list.
sample_clips() {
  subset_clips | awk -v s="$STRIDE" '((NR - 1) % s) == 0'
}

# count_subset_clips / count_sample_clips
count_subset_clips() { subset_clips | wc -l | tr -d ' '; }
count_sample_clips() { sample_clips | wc -l | tr -d ' '; }

# --- env gate --------------------------------------------------------------
# env_fail <reason> [detail...] — the ONLY failure exit of the gate: it
# prints the fail marker (and the details) and returns 1.  It NEVER prints an
# OK marker.
env_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_ASSETS_ENV_FAIL reason=$reason"
  return 1
}

env_gate() {
  # (1) the export group must import (mjlab + mujoco).
  local probe_out probe_rc
  probe_out="$(eval "$IMPORT_CMD" 2>&1)"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    env_fail "import-failed" \
      "command: $IMPORT_CMD" \
      "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    return 1
  fi

  # (2) the subset yaml must exist ...
  if [ ! -f "$SUBSET_YAML" ]; then
    env_fail "subset-missing" "PATH=$SUBSET_YAML" || return 1
    return 1
  fi

  # (3) ... and hold more than zero clips.
  local clips
  clips="$(count_subset_clips)"
  if [ "${clips:-0}" -le 0 ]; then
    env_fail "subset-empty" "PATH=$SUBSET_YAML" || return 1
    return 1
  fi

  # (4) the landing spot must be creatable and writable.
  if ! mkdir -p "$ASSETS_DIR_REAL" 2>/dev/null; then
    env_fail "assets-not-writable" \
      "PATH=$ASSETS_DIR_REAL" \
      "fix: SEED_WORKTREE=<worktree> bash repro/lib/seed_store.sh link" || return 1
    return 1
  fi
  if [ ! -w "$ASSETS_DIR_REAL" ]; then
    env_fail "assets-not-writable" \
      "PATH=$ASSETS_DIR_REAL" \
      "fix: SEED_WORKTREE=<worktree> bash repro/lib/seed_store.sh link" || return 1
    return 1
  fi

  local sampled
  sampled="$(count_sample_clips)"
  elog_ok "DEPLOY_ASSETS_ENV_OK clips=$clips sampled=$sampled robot=$ROBOT"
  flush_ok_markers
  return 0
}

cmd_env() {
  elog "=== 21_assets.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "assets dir: $ASSETS_DIR_REAL"
  elog "subset:     $SUBSET_YAML"
  elog "stride:     $STRIDE"
  local rc=0
  env_gate || rc=1
  return "$rc"
}

# --- export ----------------------------------------------------------------
# cleanup_staging — remove the staging directory.  The formal landing spot is
# NEVER touched here.
cleanup_staging() {
  rm -rf "$STAGING_DIR" 2>/dev/null || true
}

# publish_entry <src> <dst> — move <src> onto <dst> atomically (a rename).
# The previous <dst> is moved aside first and only deleted when the new one
# is in place, so a failed publish restores the old content.
publish_entry() {
  local src="$1" dst="$2" trash=""
  if [ ! -e "$src" ]; then return 1; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    trash="$dst.trash.$$"
    rm -rf "$trash" 2>/dev/null || true
    if ! mv "$dst" "$trash" 2>/dev/null; then return 1; fi
  fi
  if ! mv "$src" "$dst" 2>/dev/null; then
    if [ -n "$trash" ]; then mv "$trash" "$dst" 2>/dev/null || true; fi
    return 1
  fi
  [ -n "$trash" ] && rm -rf "$trash" 2>/dev/null || true
  return 0
}

# verify_staging <dir> <expected clips>
# The structural decision is the one of the decision base (repro/lib/deploy.py
# via repro/lib/deploy.sh); the orchestrator adds the two byte-level checks
# the decision base does not make (a non-empty scene xml, non-empty clips).
# On success the number of verified clips is left in STAGING_CLIPS.
STAGING_CLIPS=""
STAGING_REASON=""

verify_staging() {
  local dir="$1" expect="$2" out rc
  STAGING_CLIPS=""
  STAGING_REASON=""

  out="$(deploy_run assets --dir "$dir" --expect-clips "$expect" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    STAGING_REASON="$(printf '%s\n' "$out" | sed -n 's/^DEPLOY_ASSETS_FAIL reason=\([a-z-]*\).*$/\1/p' | head -n1)"
    STAGING_REASON="${STAGING_REASON:-assets-clips-mismatch}"
    return 1
  fi

  # the scene xml must exist AND be non-empty
  local xml="$dir/$ROBOT.xml"
  if [ ! -f "$xml" ]; then
    STAGING_REASON="assets-xml-missing"
    return 1
  fi
  if [ ! -s "$xml" ]; then
    STAGING_REASON="assets-xml-empty"
    return 1
  fi

  # every clip must sit in clips/<robot>/ and be non-empty
  local clips_root="$dir/clips/$ROBOT"
  if [ ! -d "$clips_root" ]; then
    STAGING_REASON="assets-clips-missing"
    return 1
  fi
  local count
  count="$(find "$clips_root" -maxdepth 1 -type f -name '*.npz' | wc -l | tr -d ' ')"
  if [ "${count:-0}" -ne "$expect" ]; then
    STAGING_REASON="assets-clips-mismatch"
    return 1
  fi
  local zero
  zero="$(find "$clips_root" -maxdepth 1 -type f -name '*.npz' -size 0 | wc -l | tr -d ' ')"
  if [ "${zero:-0}" -ne 0 ]; then
    STAGING_REASON="assets-clip-empty"
    return 1
  fi
  local deeper
  # clips/<robot>/<clip>.npz is at depth 2 relative to clips/; anything
  # deeper means the exporter wrote a clip outside the robot's own folder.
  deeper="$(find "$dir/clips" -mindepth 3 -type f -name '*.npz' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${deeper:-0}" -ne 0 ]; then
    STAGING_REASON="assets-clips-mismatch"
    return 1
  fi

  STAGING_CLIPS="$count"
  return 0
}

cmd_export() {
  elog "=== 21_assets.sh export $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "robot:      $ROBOT"
  elog "assets dir: $ASSETS_DIR_REAL"
  elog "subset:     $SUBSET_YAML"
  elog "stride:     $STRIDE"
  elog "staging:    $STAGING_DIR"

  # (0) the ENVIRONMENT GATE must pass -- otherwise nothing is exported.
  local gate_tmp gate_rc reason
  gate_tmp="$(mktemp)"
  env_gate >"$gate_tmp" 2>&1
  gate_rc=$?
  {
    printf -- '--- environment gate (rc=%s) ---\n' "$gate_rc"
    cat "$gate_tmp"
  } >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$gate_rc" -ne 0 ]; then
    reason="$(sed -n 's/^DEPLOY_ASSETS_ENV_FAIL reason=\([a-z-]*\)$/\1/p' "$gate_tmp" | head -n1)"
    rm -f "$gate_tmp"
    elog "  the environment gate failed: reason=${reason:-unknown}"
    elog "DEPLOY_ASSETS_FAIL reason=${reason:-import-failed}"
    return 1
  fi
  rm -f "$gate_tmp"
  elog "  environment gate: PASS"

  # (1) the sample of clips.
  local clips
  clips="$(count_sample_clips)"
  if [ "${clips:-0}" -le 0 ]; then
    elog "DEPLOY_ASSETS_FAIL reason=subset-empty"
    return 1
  fi
  elog "  sampled clips: $clips (every ${STRIDE}th of the subset list)"

  # (2) the staging directory.
  if ! mkdir -p "$STAGING_DIR" 2>/dev/null; then
    elog "DEPLOY_ASSETS_FAIL reason=publish-failed"
    elog "  the staging directory is not creatable: $STAGING_DIR"
    return 1
  fi

  # (3) the upstream export.
  local cmd out rc clip
  cmd="$EXPORT_CMD --robot $(printf '%q' "$ROBOT") --subset-yaml $(printf '%q' "$SUBSET_YAML")"
  cmd="$cmd --clips"
  while IFS= read -r clip; do
    [ -n "$clip" ] && cmd="$cmd $(printf '%q' "$clip")"
  done <<<"$(sample_clips)"
  cmd="$cmd --out $(printf '%q' "$STAGING_DIR")"
  elog "  upstream command: $cmd"
  out="$(eval "$cmd" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    elog "  the upstream exporter failed (rc=$rc)"
    cleanup_staging
    elog "DEPLOY_ASSETS_FAIL reason=export-failed"
    return 1
  fi

  # (4) the staging directory must pass EVERY gate before it is published.
  if ! verify_staging "$STAGING_DIR" "$clips"; then
    elog "  the staging directory was rejected: reason=${STAGING_REASON:-unknown}"
    cleanup_staging
    elog "DEPLOY_ASSETS_FAIL reason=staging-verify-failed"
    return 1
  fi
  elog "  staging verified: clips=$STAGING_CLIPS"

  # (5) the ATOMIC PUBLISH into the formal landing spot.
  mkdir -p "$ASSETS_DIR_REAL" 2>/dev/null || true
  local entry
  for entry in "$ROBOT.xml" clips meshes; do
    [ -e "$STAGING_DIR/$entry" ] || continue
    if ! publish_entry "$STAGING_DIR/$entry" "$ASSETS_DIR_REAL/$entry"; then
      elog "  the staging entry could not be published: $entry"
      cleanup_staging
      elog "DEPLOY_ASSETS_FAIL reason=publish-failed"
      return 1
    fi
  done

  # (6) the clip list of the sample (repo-relative paths inside the assets
  # directory), written atomically so a reader never sees a partial list.
  local list_tmp
  list_tmp="$(mktemp "$ASSETS_DIR_REAL/.clips.XXXXXX" 2>/dev/null)"
  if [ -z "$list_tmp" ]; then
    cleanup_staging
    elog "DEPLOY_ASSETS_FAIL reason=publish-failed"
    elog "  the clip list could not be written: $CLIP_LIST_PATH"
    return 1
  fi
  while IFS= read -r clip; do
    [ -n "$clip" ] && printf 'clips/%s/%s.npz\n' "$ROBOT" "$clip" >>"$list_tmp"
  done <<<"$(sample_clips)"
  if ! mv "$list_tmp" "$CLIP_LIST_PATH" 2>/dev/null; then
    rm -f "$list_tmp" 2>/dev/null || true
    cleanup_staging
    elog "DEPLOY_ASSETS_FAIL reason=publish-failed"
    elog "  the clip list could not be published: $CLIP_LIST_PATH"
    return 1
  fi
  # mktemp creates the file with 0600; the clip list is read by the replay and
  # the comparison orchestrators, so it must stay world-readable.
  chmod 0644 "$CLIP_LIST_PATH" 2>/dev/null || true

  # (7) no staging residue may survive.
  cleanup_staging

  elog_ok "DEPLOY_ASSETS_OK clips=$STAGING_CLIPS xml=$(rel_to_repo "$ASSETS_DIR_REAL/$ROBOT.xml")"
  flush_ok_markers
  return 0
}

# --- report (the asset-side self report) -----------------------------------
cmd_report() {
  elog "=== 21_assets.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "DEPLOY_REPORT_SIDE=assets"
  elog "DEPLOY_REPORT_DIR dir=$ASSETS_DIR_REAL"
  elog "DEPLOY_REPORT_ROBOT robot=$ROBOT"
  elog "DEPLOY_REPORT_SUBSET path=$SUBSET_YAML"

  local xml="$ASSETS_DIR_REAL/$ROBOT.xml" bytes=0
  if [ -f "$xml" ]; then
    bytes="$(wc -c <"$xml" 2>/dev/null | tr -d ' ')"
  fi
  elog "DEPLOY_REPORT_XML path=$(rel_to_repo "$xml") bytes=$bytes"

  local meshes=0
  if [ -d "$ASSETS_DIR_REAL/meshes/$ROBOT" ]; then
    meshes="$(find "$ASSETS_DIR_REAL/meshes/$ROBOT" -type f | wc -l | tr -d ' ')"
  fi
  elog "DEPLOY_REPORT_MESH count=$meshes"

  local clips=0
  if [ -d "$ASSETS_DIR_REAL/clips/$ROBOT" ]; then
    clips="$(find "$ASSETS_DIR_REAL/clips/$ROBOT" -maxdepth 1 -type f -name '*.npz' | wc -l | tr -d ' ')"
  fi
  elog "DEPLOY_REPORT_CLIPS count=$clips"

  local subset_clips_total=0 sampled=0
  subset_clips_total="$(count_subset_clips)"
  sampled="$(count_sample_clips)"
  elog "DEPLOY_REPORT_SAMPLE stride=$STRIDE rule=every-${STRIDE}th-clip-of-the-subset-list indices=0,$STRIDE,...,$(($STRIDE * (sampled > 0 ? sampled - 1 : 0))) subset_clips=$subset_clips_total sampled=$sampled"
  elog "DEPLOY_REPORT_CLIP_LIST path=$(rel_to_repo "$CLIP_LIST_PATH")"
  if [ -f "$CLIP_LIST_PATH" ]; then
    local listed
    listed="$(wc -l <"$CLIP_LIST_PATH" 2>/dev/null | tr -d ' ')"
    elog "DEPLOY_REPORT_CLIP_LIST_LINES count=$listed"
  else
    elog "DEPLOY_REPORT_CLIP_LIST_LINES count=0"
  fi
  elog "DEPLOY_REPORT_OK=1"
  return 0
}

# --- selftest --------------------------------------------------------------
cmd_selftest() {
  elog "=== 21_assets.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  eval "$SELFTEST_CMD"
  return $?
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  export)   shift || true; cmd_export "$@" ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/21_assets.sh <env|export|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
