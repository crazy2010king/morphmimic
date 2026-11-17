#!/usr/bin/env bash
# repro/11_seed_finalize.sh — the UNATTENDED terminal chain for BONES-SEED.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The BONES-SEED payload is 68.8 GB and the only egress is a proxy that
# delivers ~0.8 MB/s, so the download needs ~24 h of wall clock.  The
# terminal evidence of the slice (archive verification -> extraction ->
# metadata reconciliation) can only be produced AFTER the last byte landed.
#
# If that terminal chain is only ever driven by a human/session that polls
# the download, every session boundary silently postpones the evidence: the
# previous attempt of this very task burned 13 h of wall clock and produced
# nothing, because the session that was going to run the verification had
# already ended.
#
# This script removes the session from the loop.  It is a DETACHED worker
# that
#
#   1. waits for the download worker to reach STATE=DONE
#      (it re-reads the status file, and it refuses to wait forever on a
#      dead worker PID),
#   2. runs repro/09_seed_verify.sh verify   (sha256 + gzip CRC + clip
#      count + layout gate),
#   3. runs repro/10_seed_extract.sh worker  (serial extraction of both
#      archives + reconciliation against the metadata CSV),
#   4. runs repro/10_seed_extract.sh verify   (the read-only reconciliation
#      that produces SEED_META_MATCH / SEED_EXTRACT_OK),
#   5. runs `sha256sum -c` over data/seed/_archives/SHA256SUMS (the
#      archive-level integrity evidence).
#
# Every step is idempotent, so a re-run after a crash simply redoes what is
# missing.  The whole chain is observable: a status file plus greppable
# SEED_FINALIZE_* markers.
#
# SUBCOMMANDS
#   start            launch the detached finalize worker; returns immediately
#   status           print the status file + worker liveness (always exit 0)
#   wait [seconds]   bounded wait (default 75); 0=DONE 1=FAILED 75=timeout
#   worker           foreground chain (used by `start`)
#   verify           read-only: assert the terminal evidence is on disk
#   selftest         run the offline fixture battery
#
# ENVIRONMENT OVERRIDES (used by the offline fixtures)
#   SEED_FINALIZE_ALLOW_LOCAL=1   allow running outside the ros_dev container
#   SEED_FINALIZE_REPRO_DIR       directory holding 08/09/10 scripts
#   SEED_FINALIZE_DOWNLOAD_STATUS download status file to watch
#   SEED_FINALIZE_SHA256SUMS      SHA256SUMS list to check
#   SEED_FINALIZE_ARCHIVE_DIR     archive directory (for `sha256sum -c`)
#   SEED_FINALIZE_POLL_S          poll interval in seconds (default 60)
#   SEED_FINALIZE_MAX_WAIT_S      give up waiting for the download after N
#                                 seconds (0 = wait forever, the default)
#   SEED_FINALIZE_LOG             main marker log
#   SEED_FINALIZE_STATUS          status file
#   SEED_FINALIZE_WORKER_LOG      detached worker log
#
# MARKERS (grep -F friendly)
#   SEED_FINALIZE_START phase=<download|verify|extract|reconcile|sha256>
#   SEED_FINALIZE_WAIT state=<state> elapsed_s=<n>
#   SEED_FINALIZE_DONE phase=<phase> elapsed_s=<n>
#   SEED_FINALIZE_FAIL reason=<...> phase=<phase>
#   SEED_FINALIZE_OK files=<n>
#
# A failing run NEVER prints SEED_FINALIZE_OK.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
if [ "${SEED_FINALIZE_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

REPRO_DIR="${SEED_FINALIZE_REPRO_DIR:-$REPO_ROOT/repro}"
DOWNLOAD_SH="$REPRO_DIR/08_seed_download.sh"
VERIFY_SH="$REPRO_DIR/09_seed_verify.sh"
EXTRACT_SH="$REPRO_DIR/10_seed_extract.sh"
ARCHIVE_DIR="${SEED_FINALIZE_ARCHIVE_DIR:-$REPO_ROOT/data/seed/_archives}"
SHA256SUMS="${SEED_FINALIZE_SHA256SUMS:-$ARCHIVE_DIR/SHA256SUMS}"
DL_STATUS="${SEED_FINALIZE_DOWNLOAD_STATUS:-$LOG_DIR/08_seed_download.status}"
MAIN_LOG="${SEED_FINALIZE_LOG:-$LOG_DIR/11_seed_finalize.txt}"
STATUS_FILE="${SEED_FINALIZE_STATUS:-$LOG_DIR/11_seed_finalize.status}"
WORKER_LOG="${SEED_FINALIZE_WORKER_LOG:-$LOG_DIR/11_seed_finalize_worker.log}"
POLL_S="${SEED_FINALIZE_POLL_S:-60}"
MAX_WAIT_S="${SEED_FINALIZE_MAX_WAIT_S:-0}"
# The evidence logs of the verifier/extractor: `verify` asserts that the
# terminal markers really landed in them.
VERIFY_LOG="${SEED_FINALIZE_VERIFY_LOG:-$LOG_DIR/09_seed_verify.txt}"
EXTRACT_LOG="${SEED_FINALIZE_EXTRACT_LOG:-$LOG_DIR/10_seed_extract.txt}"

usage() {
  cat <<EOF
usage: bash repro/11_seed_finalize.sh [start|status|wait [seconds]|worker|verify|selftest]

  start            launch the detached finalize worker
  status           print the status file + worker liveness
  wait [sec]       bounded wait (default 75s); 0=DONE 1=FAILED 75=timeout
  worker           foreground: wait for the download, then verify/extract/reconcile
  verify           read-only: assert the terminal evidence is on disk
  selftest         offline fixture battery

logs:  $MAIN_LOG
       $WORKER_LOG
       $STATUS_FILE
EOF
}

# --- output -----------------------------------------------------------------
olog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# OK_MARKERS: buffered success markers, flushed only when every step passed
# (same convention as repro/09_seed_verify.sh and repro/10_seed_extract.sh).
OK_MARKERS=()
olog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do olog "$m"; done
  OK_MARKERS=()
}

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

status_write() {
  # status_write <state> <rc> [key=value ...]
  local state="$1" rc="$2"; shift 2 || true
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
  {
    printf 'STATE=%s\n' "$state"
    printf 'RC=%s\n' "$rc"
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
    printf 'STARTED_AT=%s\n' "$STARTED_AT"
    printf 'FINISHED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$STATUS_FILE.tmp" 2>/dev/null || true
  mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null || true
}

# --- download state ---------------------------------------------------------
# dl_state -> prints STATE=RUNNING|DONE|FAILED|PAUSED|ABSENT
# A status file whose PID is gone but whose state is not terminal means the
# download worker died: that is FAILED, not "still running".  Without this
# rule the finalize worker would wait forever on a dead predecessor.
dl_state() {
  if [ ! -f "$DL_STATUS" ]; then
    echo "STATE=ABSENT"
    return 3
  fi
  local state pid
  state="$(sed -n 's/^STATE=//p' "$DL_STATUS" | head -n1)"
  pid="$(sed -n 's/^PID=//p' "$DL_STATUS" | head -n1)"
  case "${state:-}" in
    DONE|FAILED|PAUSED)
      echo "STATE=$state"
      return 0
      ;;
  esac
  if [ -n "${pid:-}" ] && [ "$pid" != "0" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "STATE=FAILED"
    echo "REASON=download worker pid $pid is gone but no terminal state was written"
    return 0
  fi
  echo "STATE=RUNNING"
  return 0
}

# --- steps ------------------------------------------------------------------
# run_step <phase> <cmd...> — run a step, log its output, fail loudly.
run_step() {
  local phase="$1"; shift
  local t0 rc=0 out
  t0="$(date +%s)"
  olog "SEED_FINALIZE_START phase=$phase"
  out="$(mktemp "${TMPDIR:-/tmp}/seed_finalize.XXXXXX")"
  set +e
  "$@" >"$out" 2>&1
  rc=$?
  set -e
  # The step output goes to the worker log AND to the main log: the 09/10
  # markers (SEED_TAR_CLIPS, SEED_VERIFY_OK, SEED_META_MATCH, ...) are the
  # evidence of this slice and must be greppable in one place.
  while IFS= read -r line; do olog "$line"; done <"$out"
  rm -f "$out"
  if [ "$rc" -ne 0 ]; then
    olog "SEED_FINALIZE_FAIL reason=step-failed phase=$phase rc=$rc"
    return 1
  fi
  olog "SEED_FINALIZE_DONE phase=$phase elapsed_s=$(( $(date +%s) - t0 ))"
  return 0
}

# --- worker -----------------------------------------------------------------
cmd_worker() {
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  olog "=== 11_seed_finalize.sh worker $STARTED_AT ==="
  olog "SEED_FINALIZE_REPRO_DIR dir=$REPRO_DIR"
  status_write RUNNING 0 "PID=$$" "PHASE=download"

  # --- phase 1: wait for the download --------------------------------------
  local t0 elapsed state
  t0="$(date +%s)"
  while :; do
    state="$(dl_state | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
    case "$state" in
      DONE)
        olog "SEED_FINALIZE_DONE phase=download elapsed_s=$(( $(date +%s) - t0 ))"
        break
        ;;
      FAILED)
        olog "SEED_FINALIZE_FAIL reason=download-failed phase=download"
        status_write FAILED 1 "PID=$$" "PHASE=download"
        exit 1
        ;;
      PAUSED)
        olog "SEED_FINALIZE_FAIL reason=download-paused phase=download"
        status_write FAILED 1 "PID=$$" "PHASE=download"
        exit 1
        ;;
    esac
    elapsed=$(( $(date +%s) - t0 ))
    if [ "$MAX_WAIT_S" -gt 0 ] && [ "$elapsed" -ge "$MAX_WAIT_S" ]; then
      olog "SEED_FINALIZE_FAIL reason=download-timeout phase=download elapsed_s=$elapsed"
      status_write FAILED 1 "PID=$$" "PHASE=download"
      exit 1
    fi
    olog "SEED_FINALIZE_WAIT state=$state elapsed_s=$elapsed"
    sleep "$POLL_S"
  done

  # --- phase 2: archive verification ---------------------------------------
  status_write RUNNING 0 "PID=$$" "PHASE=verify"
  if [ ! -f "$VERIFY_SH" ]; then
    olog "SEED_FINALIZE_FAIL reason=verifier-missing phase=verify path=$VERIFY_SH"
    status_write FAILED 1 "PID=$$" "PHASE=verify"
    exit 1
  fi
  run_step verify bash "$VERIFY_SH" verify || {
    status_write FAILED 1 "PID=$$" "PHASE=verify"
    exit 1
  }

  # --- phase 3: extraction --------------------------------------------------
  status_write RUNNING 0 "PID=$$" "PHASE=extract"
  if [ ! -f "$EXTRACT_SH" ]; then
    olog "SEED_FINALIZE_FAIL reason=extractor-missing phase=extract path=$EXTRACT_SH"
    status_write FAILED 1 "PID=$$" "PHASE=extract"
    exit 1
  fi
  run_step extract bash "$EXTRACT_SH" worker || {
    status_write FAILED 1 "PID=$$" "PHASE=extract"
    exit 1
  }

  # --- phase 4: read-only reconciliation -----------------------------------
  status_write RUNNING 0 "PID=$$" "PHASE=reconcile"
  run_step reconcile bash "$EXTRACT_SH" verify || {
    status_write FAILED 1 "PID=$$" "PHASE=reconcile"
    exit 1
  }

  # --- phase 5: archive-level sha256 ---------------------------------------
  status_write RUNNING 0 "PID=$$" "PHASE=sha256"
  if [ ! -f "$SHA256SUMS" ]; then
    olog "SEED_FINALIZE_FAIL reason=sha256sums-missing phase=sha256 path=$SHA256SUMS"
    status_write FAILED 1 "PID=$$" "PHASE=sha256"
    exit 1
  fi
  local sha_out sha_rc=0
  sha_out="$(mktemp "${TMPDIR:-/tmp}/seed_finalize_sha.XXXXXX")"
  set +e
  ( cd "$ARCHIVE_DIR" && sha256sum -c "$(basename "$SHA256SUMS")" ) >"$sha_out" 2>&1
  sha_rc=$?
  set -e
  while IFS= read -r line; do olog "$line"; done <"$sha_out"
  rm -f "$sha_out"
  if [ "$sha_rc" -ne 0 ]; then
    olog "SEED_FINALIZE_FAIL reason=sha256-check-failed phase=sha256 rc=$sha_rc"
    status_write FAILED 1 "PID=$$" "PHASE=sha256"
    exit 1
  fi
  olog "SEED_FINALIZE_DONE phase=sha256"

  # --- done -----------------------------------------------------------------
  local files
  files="$(grep -c . "$SHA256SUMS" 2>/dev/null | head -n1)" || files=0
  [ -n "$files" ] || files=0
  olog_ok "SEED_FINALIZE_OK files=$files"
  flush_ok_markers
  status_write DONE 0 "PID=$$" "PHASE="
  olog "=== 11_seed_finalize.sh worker DONE $STARTED_AT ==="
  return 0
}

# --- start / status / wait --------------------------------------------------
cmd_start() {
  local state
  state="$(dl_state | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
  if grep -q "^STATE=RUNNING" "$STATUS_FILE" 2>/dev/null; then
    olog "finalize worker already RUNNING:"
    [ -f "$STATUS_FILE" ] && cat "$STATUS_FILE"
    return 0
  fi
  olog "starting detached seed-finalize worker ..."
  mkdir -p "$LOG_DIR"
  setsid nohup bash "$_SCRIPT_DIR/11_seed_finalize.sh" worker >>"$WORKER_LOG" 2>&1 </dev/null &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  olog "WORKER_PID=$pid"
  olog "STATUS_FILE=$STATUS_FILE"
  olog "WORKER_LOG=$WORKER_LOG"
  olog "poll with: bash repro/lib/remote.sh 11_seed_finalize.sh status"
  return 0
}

cmd_status() {
  echo "=== 11_seed_finalize.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "--- download state ---"
  dl_state || true
  echo "--- status file ---"
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo "(no status file yet: $STATUS_FILE)"
  fi
  echo "--- log tail ---"
  if [ -f "$WORKER_LOG" ]; then
    tail -n 20 "$WORKER_LOG"
  elif [ -f "$MAIN_LOG" ]; then
    tail -n 20 "$MAIN_LOG"
  else
    echo "(no log yet: $MAIN_LOG)"
  fi
  return 0
}

cmd_wait() {
  local timeout_s="${1:-75}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local state
  while :; do
    state="$(sed -n 's/^STATE=//p' "$STATUS_FILE" 2>/dev/null | head -n1)" || state="ABSENT"
    case "${state:-}" in
      DONE)  olog "finalize worker finished: DONE";  return 0 ;;
      FAILED) olog "finalize worker finished: FAILED"; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      olog "finalize worker still running after ${timeout_s}s - keep polling:"
      olog "  bash repro/lib/remote.sh 11_seed_finalize.sh status"
      olog "  bash repro/lib/remote.sh 11_seed_finalize.sh wait 75"
      return 75
    fi
    sleep 5
  done
}

# --- verify -----------------------------------------------------------------
# Read-only: assert that the terminal evidence of the slice is on disk.
cmd_verify() {
  olog "=== 11_seed_finalize.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  local missing=0
  local f
  for f in "$DL_STATUS" "$SHA256SUMS"; do
    if [ ! -f "$f" ]; then
      olog "ERROR: missing: $f"
      missing=1
    fi
  done
  if [ "$missing" -eq 0 ]; then
    local state
    state="$(sed -n 's/^STATE=//p' "$DL_STATUS" | head -n1)"
    if [ "$state" != "DONE" ]; then
      olog "ERROR: download state is $state (expected DONE)"
      missing=1
    fi
  fi
  if [ "$missing" -eq 0 ]; then
    if ! grep -q "SEED_VERIFY_OK" "$VERIFY_LOG" 2>/dev/null; then
      olog "ERROR: SEED_VERIFY_OK missing from $VERIFY_LOG"
      missing=1
    fi
    if ! grep -q "SEED_META_MATCH matched=142220 missing=0 extra=0" "$EXTRACT_LOG" 2>/dev/null; then
      olog "ERROR: SEED_META_MATCH matched=142220 missing=0 extra=0 missing from $EXTRACT_LOG"
      missing=1
    fi
    if ! grep -q "SEED_EXTRACT_OK files=284440" "$EXTRACT_LOG" 2>/dev/null; then
      olog "ERROR: SEED_EXTRACT_OK files=284440 missing from $EXTRACT_LOG"
      missing=1
    fi
  fi
  [ "$missing" -eq 0 ] || { olog "ERROR: seed finalize verification failed"; exit 1; }
  olog "SEED_FINALIZE_OK files=3"
  return 0
}

cmd_selftest() {
  exec bash "$REPO_ROOT/repro/tests/test_seed_finalize.sh"
}

case "${1:-verify}" in
  start)   shift || true; cmd_start "$@" ;;
  status)  cmd_status ;;
  wait)    shift || true; cmd_wait "${1:-75}" ;;
  worker)  shift || true; cmd_worker "$@" ;;
  verify)  shift || true; cmd_verify "$@" ;;
  selftest) cmd_selftest ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
