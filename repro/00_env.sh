#!/usr/bin/env bash
# repro/00_env.sh — one-shot orchestration of the whole environment build.
#
# Goal (R003): every stage of "install morphmimic's runtime from scratch" is a
# re-runnable script that leaves a log behind; this script is the single
# command that runs all of them in order:
#
#     01_snapshot.sh -> 02_submodules.sh -> 03_uv_sync.sh -> 04_smoke.sh
#     -> 05_proxy_hygiene.sh -> 06_code_read.sh
#
# NOTE: repro/07_toolchain.sh is deliberately NOT part of this chain: it
# clones third-party repositories and builds native bindings (network
# dependent, ~10 min).  It runs standalone; see repro/README.md.
#
# Contract:
#   * every step's stdout/stderr is appended to logs/env/00_env.txt (one
#     fresh log per run; the previous run is kept as 00_env.prev.txt);
#   * a step that exits non-zero aborts the whole run (non-zero exit, no
#     ENV_READY line);
#   * after a step, the marker lines that step is supposed to produce are
#     collected FROM THE OUTPUT THAT THIS RUN PRODUCED (a marker left over
#     by an earlier run in the step's own log file never satisfies the
#     check) and appended to 00_env.txt, so the one log shows the whole
#     chain 01 -> 06;
#   * on success the log ends with ENV_READY plus a summary of the key
#     conclusions (torch version, CUDA availability, env count, reward mean,
#     proxy hygiene).
#
# ---------------------------------------------------------------------------
# WHY THE ORCHESTRATOR ITSELF RUNS DETACHED
#
# `uv sync --frozen` (step 03) downloads GBs of wheels and the 32-env
# simulation (step 04) JITs the warp kernels.  A foreground orchestrator
# would be one long blocking ssh call — exactly the shape that killed an
# earlier attempt (the session budget ran out mid-download and the result was
# lost).  So the pipeline runs in a DETACHED worker (setsid/nohup) that
# survives the ssh session, and this script only ever runs short, cheap
# commands:
#
#   start   launch the detached orchestrator; returns immediately
#   status  print STATE= plus the log tail (always exit 0)
#   wait    bounded wait for the orchestrator (0=DONE 1=FAILED 2=timeout)
#   verify  assert the markers in logs/env/00_env.txt (never runs a step)
#   (no argument) == run == start + bounded wait + verify; exit 75
#            (EX_TEMPFAIL) on timeout, with the command to continue with
#
# ---------------------------------------------------------------------------
# PROXY
#
# The proxy is inlined into EVERY STEP PROCESS and into NOTHING else: the
# orchestrator deliberately runs WITHOUT proxy variables
# (COMMON_PROXY_INLINE=0, see repro/lib/common.sh), because
# repro/05_proxy_hygiene.sh asserts that no ANCESTOR process of it exposes a
# proxy variable — the orchestrator would be such an ancestor.  Each step
# script sources repro/lib/common.sh itself and therefore gets the proxy in
# its own process, which is exactly the "inline, process-scoped only"
# convention of this project.  Nothing is ever written to a system config.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Opt out of the proxy export in common.sh (see the comment there).
COMMON_PROXY_INLINE=0
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/uvsync.sh
source "$_SCRIPT_DIR/lib/uvsync.sh"

MAIN_LOG="$LOG_DIR/00_env.txt"
WORKER_LOG="$LOG_DIR/00_env_worker.log"
STATUS_FILE="$LOG_DIR/00_env.status"
STEP_DIR="$REPO_ROOT/repro"

# How long the orchestrator waits for the uv-sync worker (step 03) before it
# gives up (the worker keeps running detached; a later run just polls again).
ENV_UVSYNC_TIMEOUT="${ENV_UVSYNC_TIMEOUT:-1800}"
# How long `00_env.sh run` waits for the whole pipeline.
DEFAULT_WAIT="${DEFAULT_WAIT:-1800}"

# --- the step contract ----------------------------------------------------
#
# One row per step:  <script>|<log file>|<mode>|<marker>;<marker>;...
#
#   mode "simple"  -> run the script once
#   mode "uvsync"  -> the script speaks the start/status/verify protocol of
#                     repro/03_uv_sync.sh (a detached worker of its own)
env_step_table() {
  cat <<'EOF'
01_snapshot.sh|snapshot.txt|simple|SNAPSHOT_OK
02_submodules.sh|02_submodules.txt|simple|SUBMODULES_OK
03_uv_sync.sh|03_uv_sync.txt|uvsync|TORCH_VERSION_2.11.0+cu128;CUDA_AVAILABLE_TRUE;CUDA_DEVICE_NVIDIA GeForce RTX 4090;UV_SYNC_OK
04_smoke.sh|04_smoke.txt|simple|NUM_ENVS_32;REWARD_MEAN_FINITE;SMOKE_OK
05_proxy_hygiene.sh|05_proxy_hygiene.txt|simple|PROXY_HYGIENE_OK;PROXY_HYGIENE_SELFTEST_OK
06_code_read.sh|06_code_read.txt|simple|CODE_READ_OK
EOF
}

# --- small helpers ---------------------------------------------------------

# env_log <line...>
# Append to the orchestrator log AND to stdout (the stdout copy ends up in
# the detached worker's log, so the run can be watched live).
ENV_MAIN_LOG=""
env_log() {
  printf '%s\n' "$*" | tee -a "$ENV_MAIN_LOG"
}

# env_run_step <logfile> <cmd...>
# Run <cmd>, append its stdout+stderr to <logfile> (once) and echo it to
# stdout, propagate the exit code.
#
# The captured output is ALSO kept in $ENV_EVIDENCE_FILE (when set): that file
# is the evidence the marker check looks at, so a marker only counts when THIS
# run produced it — a marker left over by an earlier run in the step's own log
# file can never satisfy the check.
ENV_EVIDENCE_FILE=""
env_run_step() {
  local logfile="$1"; shift
  [ "$#" -gt 0 ] || { echo "env_run_step: no command given" >&2; return 2; }
  local tmp rc
  tmp="$(mktemp)"
  echo "### RUN $(date -u +%Y-%m-%dT%H:%M:%SZ): $*" | tee -a "$logfile"
  # `if` keeps the caller's errexit state untouched (the test suite sources
  # this file with errexit disabled and must stay that way).
  if "$@" >"$tmp" 2>&1; then rc=0; else rc=$?; fi
  cat "$tmp" >>"$logfile"
  if [ -n "$ENV_EVIDENCE_FILE" ]; then
    cat "$tmp" >>"$ENV_EVIDENCE_FILE"
  fi
  cat "$tmp"
  echo "### EXIT $rc: $*" | tee -a "$logfile"
  rm -f "$tmp"
  return "$rc"
}

# env_collect_markers <evidence file> <marker>...
#
# A marker counts only when it appears in the evidence file, i.e. in the
# output THIS run produced.  The matching lines are appended to the
# orchestrator log; the function returns non-zero when a marker is missing.
env_collect_markers() {
  local file="$1"; shift
  local m line missing=0
  for m in "$@"; do
    line="$(grep -aF -- "$m" "$file" 2>/dev/null | tail -n1 || true)"
    if [ -n "$line" ]; then
      env_log "### MARKER $line"
    else
      env_log "### MARKER MISSING: $m"
      missing=1
    fi
  done
  return "$missing"
}

# env_append_new_log_bytes <logfile> <byte offset>
#
# Append the bytes the step appended to its own log file to the evidence
# file.  Only used for the "uvsync" step, whose markers (torch version, CUDA
# device, ...) are written by the DETACHED worker into the step's log file
# instead of into the step's stdout.
env_append_new_log_bytes() {
  local file="$1" before="$2"
  [ -n "$ENV_EVIDENCE_FILE" ] || return 0
  [ -f "$file" ] || return 0
  local size
  size="$(wc -c <"$file" | tr -d ' ')"
  if [ "$size" -gt "$before" ]; then
    tail -c "+$((before + 1))" "$file" >>"$ENV_EVIDENCE_FILE" 2>/dev/null || true
  else
    # the file was rewritten (truncated) -> its whole content is from this run
    cat "$file" >>"$ENV_EVIDENCE_FILE"
  fi
  return 0
}

# env_conclusion <file> <pattern>
# Print the last line of <file> that starts with <pattern> (used for the
# summary at the end of the run).
env_conclusion() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || return 0
  grep -aE "^$pattern" "$file" 2>/dev/null | tail -n1 || true
}

# env_run_uvsync <script> <logfile> <byte offset>
# Drive a step that speaks the start/status/verify protocol (step 03).
env_run_uvsync() {
  local step="$1" step_log="${2:-}" before="${3:-0}"
  env_run_step "$ENV_MAIN_LOG" bash "$step" start || return $?
  local deadline state
  deadline=$(( $(date +%s) + ENV_UVSYNC_TIMEOUT ))
  while :; do
    state="$(bash "$step" status 2>&1 | grep -a '^STATE=' | head -n1 | sed 's/^STATE=//' || true)"
    case "$state" in
      DONE)
        env_log "### uvsync state=DONE"
        break ;;
      FAILED)
        env_log "### uvsync state=FAILED"
        return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      env_log "### uvsync TIMEOUT after ${ENV_UVSYNC_TIMEOUT}s — the worker keeps running detached"
      return 2
    fi
    # Poll every 2s instead of 5s: the step itself takes ~70s, and the
    # detection delay after the worker finished is pure dead time for the
    # one-shot run (the whole chain has to stay inside a couple of minutes).
    sleep 2
  done
  env_run_step "$ENV_MAIN_LOG" bash "$step" verify || return $?
  # the markers of this step live in its own log file (written by the
  # detached worker), not in the stdout of start/status/verify
  if [ -n "$step_log" ]; then
    env_append_new_log_bytes "$step_log" "$before"
  fi
  return 0
}

# --- the store pre-flight --------------------------------------------------
#
# Every heavy artefact of this project lives in the PERSISTENT STORE outside
# any git worktree, and the worktree only carries relative symlinks into it.
# GSD deletes milestone worktrees that are not registered with git, and a
# recursive deletion takes every untracked file with it — that is how 23.5 GB
# of g1.tar.gz and the whole tool-chain probe output were lost.
#
# So the chain REFUSES to start when the store is not healthy: a broken
# store means "the artefacts of the previous runs are not where the scripts
# think they are", and running on would only produce new artefacts in a
# directory that the next rebuild deletes.
env_store_preflight() {
  local log_dir="$1"
  env_log "### STORE PRE-FLIGHT $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Repair first (explicitly, and only here): a worktree path that became a
  # real directory is merged back into the store and re-linked.  Importing
  # repro/lib/common.sh must not have that side effect (it is sourced by
  # 35+ scripts, read-only ones included).
  local out rc=0
  out="$(bash "$STEP_DIR/30_store_guard.sh" migrate 2>&1)" || rc=$?
  printf '%s\n' "$out" | grep -aE '^(MOVED|DEDUPED|CONFLICT|LINKED)' | while IFS= read -r line; do
    env_log "    $line"
  done
  local rc2=0
  out="$(bash "$STEP_DIR/30_store_guard.sh" check 2>&1)" || rc2=$?
  printf '%s\n' "$out" | tee -a "$log_dir/30_store_guard.txt" >/dev/null
  printf '%s\n' "$out" | grep -aE '^(SEED_STORE_|STORE_GUARD_|OK |WARN |FAIL )' | while IFS= read -r line; do
    env_log "    $line"
  done
  if [ "$rc2" -ne 0 ]; then
    env_log "### STORE PRE-FLIGHT FAILED: the persistent store is not intact"
    env_log "    repair: bash repro/30_store_guard.sh migrate"
    return 1
  fi
  env_log "### STORE PRE-FLIGHT OK"
  return 0
}

# --- the pipeline ----------------------------------------------------------

# env_orchestrate <log dir> <step dir> <main log> <status file>
#
# Runs the whole step table.  Returns 0 only when every step succeeded AND
# every step produced its markers.
env_orchestrate() {
  local log_dir="$1" step_dir="$2" main_log="$3" status_file="$4"
  ENV_MAIN_LOG="$main_log"
  mkdir -p "$log_dir" "$(dirname "$main_log")"

  local t_overall; t_overall=$(date +%s)
  env_log "=== 00_env.sh orchestrator $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  env_log "REPO_ROOT=$REPO_ROOT"
  env_log "STEP_DIR=$step_dir"
  env_log "LOG_DIR=$log_dir"

  local rc=0
  local row script logfile mode markers

  # The store pre-flight is a PRECONDITION of the whole chain, not a step:
  # without a healthy store the artefacts of the previous runs are not where
  # the scripts expect them, and the new ones would be written into a
  # directory that the next GSD reconcile deletes.
  if ! env_store_preflight "$log_dir"; then
    env_log "=== 00_env.sh FAILED: store pre-flight ==="
    return 1
  fi

  while IFS='|' read -r script logfile mode markers; do
    [ -n "${script:-}" ] || continue
    local step="$step_dir/$script"
    local step_log="$log_dir/$logfile"
    local before=0
    if [ -f "$step_log" ]; then
      before="$(wc -c < "$step_log" | tr -d ' ')"
    fi
    local t0; t0=$(date +%s)
    env_log "### STEP $script START $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # fresh evidence file per step: only what THIS step produced in THIS run
    # can satisfy the marker check.
    ENV_EVIDENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/00_env_evidence.XXXXXX")"

    if [ ! -f "$step" ]; then
      env_log "### STEP $script FAILED: script not found: $step"
      rm -f "$ENV_EVIDENCE_FILE"
      rc=1
      break
    fi

    case "$mode" in
      simple) env_run_step "$main_log" bash "$step" || rc=$? ;;
      uvsync) env_run_uvsync "$step" "$step_log" "$before" || rc=$? ;;
      *)
        env_log "### STEP $script FAILED: unknown mode '$mode'"
        rc=1 ;;
    esac

    if [ "$rc" -ne 0 ]; then
      env_log "### STEP $script FAILED rc=$rc"
      rm -f "$ENV_EVIDENCE_FILE"
      break
    fi

    local t1; t1=$(date +%s)
    env_log "### STEP $script DONE elapsed=$((t1 - t0))s"

    local -a marker_list=()
    IFS=';' read -r -a marker_list <<<"$markers"
    if ! env_collect_markers "$ENV_EVIDENCE_FILE" "${marker_list[@]}"; then
      env_log "### STEP $script FAILED: missing marker(s) (see the step output above)"
      rm -f "$ENV_EVIDENCE_FILE"
      rc=1
      break
    fi
    rm -f "$ENV_EVIDENCE_FILE"
  done < <(env_step_table)

  local t_end; t_end=$(date +%s)
  if [ "$rc" -eq 0 ]; then
    env_log "TOTAL_ELAPSED_SECONDS_$((t_end - t_overall))"
    env_log "--- key conclusions ---"
    local pair pattern line
    for pair in \
      "$log_dir/03_uv_sync.txt:TORCH_VERSION_" \
      "$log_dir/03_uv_sync.txt:CUDA_AVAILABLE_" \
      "$log_dir/03_uv_sync.txt:CUDA_DEVICE_" \
      "$log_dir/03_uv_sync.txt:MJLAB_VERSION_" \
      "$log_dir/03_uv_sync.txt:WARP_VERSION_" \
      "$log_dir/04_smoke.txt:NUM_ENVS_" \
      "$log_dir/04_smoke.txt:REWARD_MEAN_" \
      "$log_dir/05_proxy_hygiene.txt:PROXY_HYGIENE_OK" \
      "$log_dir/06_code_read.txt:MODULES_TOTAL_" \
      "$log_dir/06_code_read.txt:MODULES_MISSING_"; do
      pattern="${pair##*:}"
      line="$(env_conclusion "${pair%:*}" "$pattern")"
      [ -n "$line" ] && env_log "SUMMARY $line"
    done
    env_log "ENV_READY"
    printf 'STATE=DONE\nRC=0\n' >"$status_file"
  else
    env_log "ENV_FAILED rc=$rc"
    printf 'STATE=FAILED\nRC=%s\n' "$rc" >"$status_file"
  fi
  return "$rc"
}

# --- the step markers that `verify` asserts on the orchestrator log --------
env_expected_markers() {
  printf '%s\n' \
    "SNAPSHOT_OK" \
    "SUBMODULES_OK" \
    "TORCH_VERSION_2.11.0+cu128" \
    "CUDA_AVAILABLE_TRUE" \
    "CUDA_DEVICE_NVIDIA GeForce RTX 4090" \
    "UV_SYNC_OK" \
    "NUM_ENVS_32" \
    "REWARD_MEAN_FINITE" \
    "SMOKE_OK" \
    "PROXY_HYGIENE_OK" \
    "PROXY_HYGIENE_SELFTEST_OK" \
    "CODE_READ_OK" \
    "ENV_READY"
}

# --- sub commands ----------------------------------------------------------

cmd_start() {
  if [ -f "$STATUS_FILE" ]; then
    local state
    state="$(uvsync_status "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)"
    if [ "$state" = "RUNNING" ]; then
      echo "orchestrator already RUNNING:"
      uvsync_status "$STATUS_FILE"
      return 0
    fi
  fi
  echo "starting detached orchestrator ..."
  uvsync_run_detached "$STATUS_FILE" "$WORKER_LOG" bash "$_SCRIPT_DIR/00_env.sh" --worker
  echo "poll with: bash repro/lib/remote.sh 00_env.sh status"
}

cmd_status() {
  echo "=== 00_env.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  uvsync_status "$STATUS_FILE" || true
  echo "--- steps finished so far ---"
  if [ -f "$MAIN_LOG" ]; then
    grep -a '^### STEP .* DONE' "$MAIN_LOG" || echo "(none yet)"
  else
    echo "(no log yet: $MAIN_LOG)"
  fi
  echo "--- log tail ---"
  uvsync_tail "$MAIN_LOG" 30 || true
  return 0
}

cmd_wait() {
  local timeout_s="${1:-$DEFAULT_WAIT}"
  set +e
  uvsync_wait_bounded "$STATUS_FILE" "$timeout_s" 2
  local rc=$?
  set -e
  case "$rc" in
    0) echo "orchestrator finished: DONE" ;;
    1) echo "orchestrator finished: FAILED" ;;
    2) echo "orchestrator still running after ${timeout_s}s — keep polling:" ;;
  esac
  return "$rc"
}

cmd_verify() {
  echo "=== 00_env.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  local missing=0

  local state
  state="$(uvsync_status "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)"
  if [ "$state" != "DONE" ]; then
    echo "ERROR: orchestrator state is ${state:-ABSENT}, expected DONE" >&2
    missing=1
  fi

  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if ! grep -aqF -- "$m" "$MAIN_LOG" 2>/dev/null; then
      echo "ERROR: missing marker in $MAIN_LOG: $m" >&2
      missing=1
    fi
  done < <(env_expected_markers)

  if [ "$missing" -ne 0 ]; then
    echo "ERROR: verification failed" >&2
    exit 1
  fi
  echo "ENV_READY"
}

cmd_run() {
  cmd_start
  set +e
  cmd_wait "$DEFAULT_WAIT"
  local rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    echo "TIMEOUT: the orchestrator keeps running detached; continue with:" >&2
    echo "  bash repro/lib/remote.sh 00_env.sh status" >&2
    echo "  bash repro/lib/remote.sh 00_env.sh wait 600" >&2
    exit 75
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  cmd_verify
}

worker_main() {
  require_container
  cd "$REPO_ROOT"
  # Keep the previous run's log as 00_env.prev.txt and start this run with a
  # fresh 00_env.txt: the artefact of a run must show ONE complete chain
  # 01 -> 06, not the failures of earlier attempts.
  if [ -f "$MAIN_LOG" ]; then
    cp -f "$MAIN_LOG" "$LOG_DIR/00_env.prev.txt"
    : >"$MAIN_LOG"
  fi
  env_orchestrate "$LOG_DIR" "$STEP_DIR" "$MAIN_LOG" "$STATUS_FILE"
}

usage() {
  cat <<EOF
usage: bash repro/00_env.sh [start|status|wait [seconds]|verify|run|--worker]

  start          launch the detached orchestrator; returns immediately
  status         print the state + the log tail (always exit 0)
  wait [sec]     bounded wait (default ${DEFAULT_WAIT}s); 0=DONE 1=FAILED 2=timeout
  verify         assert the markers in $MAIN_LOG (no step is run)
  run            start + bounded wait + verify (the default)
  --worker       internal: the detached pipeline body
EOF
}

main() {
  require_container
  cd "$REPO_ROOT"
  case "${1:-run}" in
    --worker) shift; worker_main "$@" ;;
    start)  cmd_start ;;
    status) cmd_status ;;
    wait)   shift; cmd_wait "${1:-$DEFAULT_WAIT}" ;;
    verify) cmd_verify ;;
    run)    cmd_run ;;
    -h|--help|help) usage ;;
    *)
      echo "unknown subcommand: $1" >&2
      usage >&2
      exit 2 ;;
  esac
}

# Only run the pipeline when the script is EXECUTED, not when it is sourced:
# repro/tests/test_00_env.sh sources it to exercise env_orchestrate with
# fake steps (no container, no network, no GPU).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
