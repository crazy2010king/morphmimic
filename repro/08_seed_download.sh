#!/usr/bin/env bash
# repro/08_seed_download.sh — fetch BONES-SEED (68.8 GB) with a resumable,
# observable, detached HTTP download.
#
# ---------------------------------------------------------------------------
# WHY THIS INTERFACE
#
# The three files (metadata CSV 146,411,608 B + g1.tar.gz 23,499,973,647 B +
# soma_uniform.tar.gz 45,188,088,297 B) have to travel through the only
# egress this machine has (the proxy, measured 0.6-0.9 MB/s) -> 21-32 h of
# wall clock. Three properties are therefore mandatory:
#
#   1. RESUMABLE: `curl -L -C -` against a "<file>.part" that is never
#      deleted. A failure costs one attempt, not the whole transfer.
#   2. DETACHED: the transfer runs in repro/08_seed_download_worker.sh under
#      setsid/nohup, so it survives the ssh session that started it. This
#      script only ever runs short, cheap commands.
#   3. OBSERVABLE: a status file (STATE FILE BYTES TOTAL PCT RATE_BPS
#      ETA_SECONDS ATTEMPT PID RC STARTED_AT) plus greppable SEED_* markers
#      in logs/env/08_seed_download.txt.
#
# SUBCOMMANDS
#   start            launch the detached worker; returns immediately
#   status           print the status file + liveness (always exit 0)
#   wait [seconds]   bounded wait (default 600); 0=DONE 1=FAILED 2=timeout
#   verify           read-only assertion over the files on disk (no network)
#   probe [--bad-token]
#                    authentication + rate probe (bounded, a few MiB, no 23 GB)
#   segment <sec> [file-filter]
#                    bounded foreground download segment (the resume proof:
#                    run it twice and watch the .part grow)
#   run (default)    start + bounded wait + verify
#
# `wait` exits 75 (EX_TEMPFAIL) on timeout and NEVER kills the worker.
#
# ---------------------------------------------------------------------------
# PROXY
#
# The proxy is inlined into THIS process only (repro/lib/common.sh); nothing
# is ever written to a system configuration. The detached worker inherits the
# process-scoped proxy environment and inlines it again for itself.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
require_container
# shellcheck source=lib/seed_download.sh
source "$_SCRIPT_DIR/lib/seed_download.sh"

cd "$REPO_ROOT"

MAIN_LOG="$LOG_DIR/08_seed_download.txt"
WORKER_LOG="$LOG_DIR/08_seed_download_worker.log"
STATUS_FILE="$LOG_DIR/08_seed_download.status"
WORKER="$REPO_ROOT/repro/08_seed_download_worker.sh"

DEFAULT_WAIT=600

# Script-scope scratch files (the EXIT trap must be able to see them).
PROBE_HDR=""

usage() {
  cat <<EOF
usage: bash repro/08_seed_download.sh [start|status|wait [seconds]|verify|probe|segment <sec> [filter]|run]

  start                 launch the detached download worker; returns immediately
  status                print the worker state + the log tail (always exit 0)
  wait [sec]            bounded wait (default ${DEFAULT_WAIT}s); 0=DONE 1=FAILED 2=timeout (exit 75)
  verify                read-only assertion over the downloaded files (no network)
  probe [--bad-token]   authentication + rate probe (few MiB, bounded by --max-time)
  segment <sec> [filter]  bounded foreground download segment (resume proof)
  run                   start + bounded wait + verify

logs:  $MAIN_LOG
       $WORKER_LOG
       $STATUS_FILE
EOF
}

# --- output -----------------------------------------------------------------
# olog writes to stdout AND appends to the main log, so every marker of this
# script is greppable in logs/env/08_seed_download.txt.
olog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# --- status -----------------------------------------------------------------
# seed_dl_state <statusfile> -> STATE=RUNNING|DONE|FAILED|PAUSED|ABSENT
# A worker whose PID is gone but whose state is not terminal is reported as
# FAILED: "RUNNING forever" is exactly the failure mode this script exists
# to eliminate.
seed_dl_state() {
  local statusfile="$1"
  if [ ! -f "$statusfile" ]; then
    echo "STATE=ABSENT"
    return 3
  fi
  local state pid
  state="$(sed -n 's/^STATE=//p' "$statusfile" | head -n1)"
  pid="$(sed -n 's/^PID=//p' "$statusfile" | head -n1)"
  case "${state:-}" in
    DONE|FAILED|PAUSED)
      echo "STATE=$state"
      return 0
      ;;
  esac
  if [ -n "$pid" ] && [ "$pid" != "0" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "STATE=FAILED"
    echo "REASON=worker pid $pid is gone but no terminal state was written"
    return 0
  fi
  echo "STATE=RUNNING"
  return 0
}

# --- start ------------------------------------------------------------------
cmd_start() {
  local state
  state="$(seed_dl_state "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
  if [ "$state" = "RUNNING" ]; then
    olog "worker already RUNNING:"
    seed_dl_state "$STATUS_FILE" | while read -r line; do olog "$line"; done || true
    return 0
  fi
  olog "starting detached seed-download worker ..."
  mkdir -p "$LOG_DIR"
  # setsid detaches the worker into its own session: it survives the ssh
  # session that started it. stdout+stderr go to the worker log; the worker
  # itself also appends its markers to the main log.
  setsid nohup bash "$WORKER" >>"$WORKER_LOG" 2>&1 </dev/null &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  olog "WORKER_PID=$pid"
  olog "STATUS_FILE=$STATUS_FILE"
  olog "WORKER_LOG=$WORKER_LOG"
  olog "poll with: bash repro/lib/remote.sh 08_seed_download.sh status"
  return 0
}

# --- status -----------------------------------------------------------------
cmd_status() {
  echo "=== 08_seed_download.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  seed_dl_state "$STATUS_FILE" || true
  echo "--- status file ---"
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo "(no status file yet: $STATUS_FILE)"
  fi
  echo "--- log tail ---"
  if [ -f "$WORKER_LOG" ]; then
    tail -n 20 "$WORKER_LOG"
  else
    echo "(no worker log yet: $WORKER_LOG)"
  fi
  return 0
}

# --- wait -------------------------------------------------------------------
cmd_wait() {
  local timeout_s="${1:-$DEFAULT_WAIT}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local state
  while :; do
    state="$(seed_dl_state "$STATUS_FILE" | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
    case "$state" in
      DONE)
        olog "worker finished: DONE"
        return 0
        ;;
      FAILED)
        olog "worker finished: FAILED"
        return 1
        ;;
      PAUSED)
        olog "worker paused (time budget exhausted); the .part was kept"
        return 75
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      olog "worker still running after ${timeout_s}s - keep polling:"
      olog "  bash repro/lib/remote.sh 08_seed_download.sh status"
      olog "  bash repro/lib/remote.sh 08_seed_download.sh wait 600"
      # EX_TEMPFAIL: the worker keeps running, nothing was killed.
      return 75
    fi
    sleep 5
  done
}

# --- verify -----------------------------------------------------------------
# Read-only: no network, no writes. Asserts that all three files are on disk
# with the expected size and a matching sha256 sidecar, and that the
# SHA256SUMS list exists.
cmd_verify() {
  olog "=== 08_seed_download.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  local missing=0 name size sha url destrel dest shafile
  while IFS=$'\t' read -r name size sha url destrel; do
    [ -n "$name" ] || continue
    dest="$REPO_ROOT/$destrel"
    shafile="${dest}.sha256"
    if [ ! -f "$dest" ]; then
      olog "ERROR: missing file: $destrel"
      missing=1
      continue
    fi
    local have
    have="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    if [ "$have" != "$size" ]; then
      olog "ERROR: size mismatch for $destrel: expected=$size got=$have"
      missing=1
      continue
    fi
    if [ ! -f "$shafile" ]; then
      olog "ERROR: missing sha256 sidecar: $shafile"
      missing=1
      continue
    fi
    if ! grep -qF "$sha" "$shafile"; then
      olog "ERROR: sha256 sidecar does not carry the expected hash: $shafile"
      missing=1
      continue
    fi
    olog "SEED_DOWNLOAD_FILE_OK file=$name bytes=$have sha256=$sha"
  done < <(seed_expected_files)

  if [ ! -f "$REPO_ROOT/data/seed/_archives/SHA256SUMS" ]; then
    olog "ERROR: missing data/seed/_archives/SHA256SUMS"
    missing=1
  fi

  [ "$missing" -eq 0 ] || { olog "ERROR: seed download verification failed"; exit 1; }
  olog "SEED_DOWNLOAD_OK files=3 bytes=68688061944"
}

# --- probe ------------------------------------------------------------------
# Authentication + rate probe. It resolves the real download URL (one HEAD,
# a few hundred bytes of traffic), then pulls a bounded Range chunk to
# measure the achievable rate. It never downloads the 23 GB archive.
cmd_probe() {
  local bad_token=0
  for a in "$@"; do
    case "$a" in
      --bad-token) bad_token=1 ;;
    esac
  done

  olog "=== 08_seed_download.sh probe $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  local token
  if [ "$bad_token" -eq 1 ]; then
    token="hf_invalid_token_for_negative_probe"
    olog "probe mode: --bad-token (expected to fail with 401)"
  else
    token="$(seed_resolve_token)"
    if [ -z "$token" ]; then
      olog "ERROR: no HF token available (HF_TOKEN or ${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token})"
      exit 1
    fi
  fi

  local url="https://huggingface.co/datasets/bones-studio/seed/resolve/main/g1.tar.gz"
  local codes cdn
  # The header file (token) is created with a script-scope name: the EXIT
  # trap runs after the function returned, so it cannot see a local.
  PROBE_HDR="$(mktemp)"
  chmod 600 "$PROBE_HDR"
  printf 'Authorization: Bearer %s\n' "$token" >"$PROBE_HDR"
  trap 'rm -f "${PROBE_HDR:-}"' EXIT

  codes="$(curl -sS -o /dev/null -D "$PROBE_HDR.headers" -w '%{http_code}' -I -H "@$PROBE_HDR" "$url" 2>/dev/null)" || codes="000"
  cdn="$(grep -i '^location:' "$PROBE_HDR.headers" 2>/dev/null | head -n1 | sed 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r')" || cdn=""
  rm -f "$PROBE_HDR.headers"

  olog "SEED_DL_PROBE_RESOLVE http=$codes"
  case "$codes" in
    401|403)
      olog "SEED_DL_AUTH_FAIL http=$codes"
      exit 1
      ;;
    2??|3??) : ;;
    *)
      olog "SEED_DL_PROBE_RESOLVE_FAIL http=$codes"
      exit 1
      ;;
  esac
  if [ -z "$cdn" ]; then
    # A 200 means the server served the file directly (no redirect).
    cdn="$url"
  fi

  # Bounded range probe: at most 8 MiB, at most 5 minutes, and --max-filesize
  # aborts the transfer if the server ignores the Range header.
  local out
  out="$(mktemp)"
  local stats rc=0
  stats="$(curl -sS -L -r 0-8388607 --max-time 300 --max-filesize 33554432 \
             -o "$out" -w '%{http_code} %{size_download} %{speed_download}' \
             -H "@$PROBE_HDR" "$cdn" 2>/dev/null)" || rc=$?
  local code size speed
  code="$(printf '%s' "$stats" | awk '{print $1}')"
  size="$(printf '%s' "$stats" | awk '{print $2}')"
  speed="$(printf '%s' "$stats" | awk '{print $3}')"
  rm -f "$out"

  if [ "$rc" -ne 0 ] || [ -z "${size:-}" ] || [ "${size:-0}" -le 0 ]; then
    olog "SEED_DL_PROBE_FAIL rc=$rc http=${code:-none} bytes=${size:-0}"
    exit 1
  fi
  olog "SEED_DL_PROBE_TRANSFER http=$code bytes=$size speed_bps=$speed"
  olog "SEED_DL_PROBE_OK url=$url bytes=$size rate_bps=$speed"
}

# --- segment ----------------------------------------------------------------
# A bounded foreground download segment: the resume proof. Run it twice with
# the same file filter and watch the .part grow (the second run resumes at
# the byte offset the first run reached).
cmd_segment() {
  local budget="${1:-120}"
  local filter="${2:-}"
  olog "=== 08_seed_download.sh segment budget=${budget}s filter=${filter:-<all>} ==="
  # A segment gets its OWN status file: it must never clobber the status of
  # a detached worker that is running at the same time.
  set +e
  SEED_TIME_BUDGET_S="$budget" SEED_FILE_FILTER="$filter" \
    SEED_STATUS_FILE="$LOG_DIR/08_seed_download.segment.status" \
    bash "$WORKER"
  local rc=$?
  set -e
  olog "SEED_DL_SEGMENT_DONE rc=$rc"
  return "$rc"
}

# --- run (default) ----------------------------------------------------------
cmd_run() {
  cmd_start
  set +e
  cmd_wait "$DEFAULT_WAIT"
  local rc=$?
  set -e
  if [ "$rc" -eq 75 ]; then
    olog "TIMEOUT: the worker keeps running detached; continue with:"
    olog "  bash repro/lib/remote.sh 08_seed_download.sh status"
    olog "  bash repro/lib/remote.sh 08_seed_download.sh wait 600"
    exit 75
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  cmd_verify
}

case "${1:-run}" in
  start)   shift; cmd_start "$@" ;;
  status)  cmd_status ;;
  wait)    shift; cmd_wait "${1:-$DEFAULT_WAIT}" ;;
  verify)  cmd_verify ;;
  probe)   shift; cmd_probe "$@" ;;
  segment) shift; cmd_segment "${1:-120}" "${2:-}" ;;
  run)     cmd_run ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
