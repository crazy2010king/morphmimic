#!/usr/bin/env bash
# repro/08_seed_download_worker.sh — the DETACHED download body for BONES-SEED.
#
# Why a separate worker: the three files total 68,834,473,552 B and the proxy
# is the only egress (measured 0.6–0.9 MB/s -> 21–32 h wall clock). A
# foreground download inside one ssh call dies with the session, and a
# download that cannot resume would have to start from zero again. So the
# transfer runs in a detached worker (setsid/nohup, started by
# repro/08_seed_download.sh) that survives the session which launched it; the
# caller only ever runs short commands that read the status file.
#
# Contract
#   * order: metadata CSV -> g1.tar.gz -> soma_uniform.tar.gz
#     (the metadata lands in ~4 min and unblocks S04; g1 unblocks the S04
#     conversion as soon as it is complete).
#   * every file is fetched with `curl -L -C -` into "<dest>.part" (same
#     directory as the final file -> the rename is atomic on the same NFS
#     filesystem). `-C -` resumes from the bytes already on disk.
#   * the signed CDN URL expires after ~1.8 h, so EVERY attempt resolves the
#     URL again (a fresh 302 -> a fresh signature).
#   * the stall watchdog is curl's own --speed-limit/--speed-time
#     (32 KiB/s for 300 s): a transfer that hangs is aborted, the .part is
#     KEPT and the attempt is retried after an exponential backoff.
#   * nothing ever deletes a .part file.
#   * after every successful transfer: size check -> sha256 check against the
#     HF lfs.oid -> "<file>.sha256" sidecar -> atomic rename -> markers.
#   * terminal state is written to logs/env/08_seed_download.status
#     (STATE FILE BYTES TOTAL PCT RATE_BPS ETA_SECONDS ATTEMPT PID RC
#      STARTED_AT).
#
# The worker is ALSO the unit under test: repro/tests/test_seed_download_e2e.sh
# runs it against a local fixture server with these environment knobs:
#
#   SEED_FILE_TABLE      TSV file (name/size/sha256/url/dest_relpath) that
#                        replaces the built-in expected-file table
#   SEED_DEST_ROOT       root the dest_relpath is resolved against
#   SEED_STATUS_FILE     status file path
#   SEED_MAIN_LOG        marker log path
#   SEED_SHA256SUMS      SHA256SUMS output path
#   SEED_TOKEN           token (overrides HF_TOKEN / the token file)
#   SEED_MAX_ATTEMPTS    attempts per file (default 30)
#   SEED_BACKOFF_SCALE   backoff delay in percent (default 100, 0 = no wait)
#   SEED_PROGRESS_INTERVAL  progress sampling period in seconds (default 60)
#   SEED_SPEED_LIMIT / SEED_SPEED_TIME / SEED_CONNECT_TIMEOUT
#   SEED_TIME_BUDGET_S   stop the transfer after N seconds and KEEP the .part
#   SEED_FILE_FILTER     only download the files whose name matches
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it is
# never written to any system configuration. `set -x` is forbidden here: the
# token must never reach a log.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/seed_download.sh
source "$_SCRIPT_DIR/lib/seed_download.sh"

# Every failure path below is handled explicitly -> errexit off, nounset on.
set +e

cd "$REPO_ROOT" || exit 1

# --- knobs (see the header for the contract) --------------------------------
SEED_TABLE="${SEED_FILE_TABLE:-}"
SEED_DEST_ROOT="${SEED_DEST_ROOT:-$REPO_ROOT}"
SEED_STATUS_FILE="${SEED_STATUS_FILE:-$LOG_DIR/08_seed_download.status}"
SEED_MAIN_LOG="${SEED_MAIN_LOG:-$LOG_DIR/08_seed_download.txt}"
SEED_SHA256SUMS="${SEED_SHA256SUMS:-$SEED_DEST_ROOT/data/seed/_archives/SHA256SUMS}"
SEED_MAX_ATTEMPTS="${SEED_MAX_ATTEMPTS:-30}"
SEED_BACKOFF_SCALE="${SEED_BACKOFF_SCALE:-100}"
SEED_PROGRESS_INTERVAL="${SEED_PROGRESS_INTERVAL:-60}"
SEED_SPEED_LIMIT="${SEED_SPEED_LIMIT:-32768}"
SEED_SPEED_TIME="${SEED_SPEED_TIME:-300}"
SEED_CONNECT_TIMEOUT="${SEED_CONNECT_TIMEOUT:-20}"
SEED_TIME_BUDGET_S="${SEED_TIME_BUDGET_S:-0}"
SEED_FILE_FILTER="${SEED_FILE_FILTER:-}"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T_START="$(date +%s)"

# --- output -----------------------------------------------------------------
# wlog writes to stdout (the detached runner redirects it into
# logs/env/08_seed_download_worker.log) AND appends the same line to the
# main log, so every marker of the transfer is greppable in
# logs/env/08_seed_download.txt as well.
wlog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$SEED_MAIN_LOG" 2>/dev/null
}

# seed_dl_status <KEY=VALUE>... — atomic status file write.
seed_dl_status() {
  seed_status_write "$SEED_STATUS_FILE" "$@"
}

# --- token ------------------------------------------------------------------
# The token is only ever written into a 0600 header file that is removed by
# the EXIT trap. It is never echoed, never traced and never passed on the
# command line (so it cannot show up in `ps`).
HDR_FILE=""
# The progress monitor must not survive the worker: it would keep writing
# SEED_DL_PROGRESS lines into a log nobody reads any more.
monitor_stop() {
  if [ -n "${monitor_pid:-}" ]; then
    kill "$monitor_pid" 2>/dev/null
    wait "$monitor_pid" 2>/dev/null
    monitor_pid=""
  fi
}
trap 'monitor_stop; rm -f "$HDR_FILE"; exit 143' INT TERM
trap 'monitor_stop; rm -f "$HDR_FILE"' EXIT

seed_dl_token() {
  if [ -n "${SEED_TOKEN:-}" ]; then
    printf '%s' "$SEED_TOKEN"
    return 0
  fi
  seed_resolve_token
}

TOKEN="$(seed_dl_token)"
CURL_HDR_ARGS=()
if [ -n "$TOKEN" ]; then
  HDR_FILE="$(mktemp "${TMPDIR:-/tmp}/seed_dl_hdr.XXXXXX")" || HDR_FILE=""
  if [ -n "$HDR_FILE" ]; then
    chmod 600 "$HDR_FILE"
    printf 'Authorization: Bearer %s\n' "$TOKEN" >"$HDR_FILE"
    CURL_HDR_ARGS=(-H "@$HDR_FILE")
  fi
fi
TOKEN=""

# --- expected file table ----------------------------------------------------
seed_dl_table() {
  if [ -n "$SEED_TABLE" ]; then
    cat "$SEED_TABLE"
  else
    seed_expected_files
  fi
}

# --- helpers ----------------------------------------------------------------
seed_dl_size() {
  stat -c %s "$1" 2>/dev/null || echo 0
}

seed_dl_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# seed_dl_filter_ok <name> — true when the file must be downloaded.
seed_dl_filter_ok() {
  [ -z "$SEED_FILE_FILTER" ] && return 0
  case "$1" in
    *"$SEED_FILE_FILTER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# build_curl_args <dest> <url> — the runtime form of seed_curl_args.
# The library form is used verbatim whenever no timing knob was overridden,
# so the production transfer is exactly the tested argument list.
build_curl_args() {
  local dest="$1" url="$2"
  if [ "$SEED_SPEED_LIMIT" = "32768" ] && [ "$SEED_SPEED_TIME" = "300" ] \
     && [ "$SEED_CONNECT_TIMEOUT" = "20" ]; then
    seed_curl_args "$dest" "$url" "$HDR_FILE" >/dev/null
    SEED_CURL_ARGS=(-sS "${SEED_CURL_ARGS[@]}")
  else
    SEED_CURL_ARGS=(
      -sS -L -C -
      --connect-timeout "$SEED_CONNECT_TIMEOUT"
      --speed-limit "$SEED_SPEED_LIMIT"
      --speed-time "$SEED_SPEED_TIME"
      --retry 0
    )
    if [ -n "$HDR_FILE" ]; then
      SEED_CURL_ARGS+=(-H "@$HDR_FILE")
    fi
    SEED_CURL_ARGS+=(-o "${dest}.part" "$url")
  fi
}

# --- progress monitor -------------------------------------------------------
# Runs in the background while curl transfers; samples the .part size and
# publishes both the status file and the SEED_DL_PROGRESS marker.
monitor_pid=""

monitor_loop() {
  local name="$1" part="$2" total="$3" attempt="$4" t0="$5"
  # The lock file descriptors must NOT leak into children: a surviving child
  # (e.g. an orphaned `sleep`) would keep the worker lock alive after the
  # worker exited and every later worker would refuse to start.
  exec 8>&- 9>&-
  while :; do
    sleep "$SEED_PROGRESS_INTERVAL" || return 0
    local bytes now elapsed pct rate eta
    bytes="$(seed_dl_size "$part")"
    now="$(date +%s)"
    elapsed=$((now - t0))
    seed_progress "$bytes" "$total" "$elapsed" >/dev/null
    pct="${SEED_PCT:-0.0}"
    rate="${SEED_RATE_BPS:-0}"
    eta="${SEED_ETA_SECONDS:-0}"
    seed_dl_status \
      "STATE=DOWNLOADING" "FILE=$name" "BYTES=$bytes" "TOTAL=$total" \
      "PCT=$pct" "RATE_BPS=$rate" "ETA_SECONDS=$eta" "ATTEMPT=$attempt" \
      "PID=$$" "RC=" "STARTED_AT=$STARTED_AT"
    wlog "SEED_DL_PROGRESS file=$name bytes=$bytes pct=$pct rate_bps=$rate eta_seconds=$eta"
  done
}

monitor_start() {
  monitor_loop "$@" &
  monitor_pid=$!
}

# --- one file ---------------------------------------------------------------
# download_file <name> <size> <sha256> <url> <dest_relpath>
# return: 0 = done, 1 = failed (fatal for the file), 2 = auth failure (fatal
# for the whole worker), 75 = time budget exhausted (keep the .part).
download_file() {
  local name="$1" size="$2" sha="$3" url="$4" destrel="$5"
  local dest="$SEED_DEST_ROOT/$destrel"
  local part="${dest}.part"
  local shafile="${dest}.sha256"
  local lockfile="${dest}.lock"

  mkdir -p "$(dirname "$dest")" || return 1

  # One worker per file: flock keeps two workers from writing the same
  # .part (the second one exits and the first one continues).
  exec 9>"$lockfile" || return 1
  if ! flock -n 9; then
    wlog "SEED_DL_LOCK_BUSY file=$name"
    return 0
  fi

  # --- idempotency: a complete, verified file is never downloaded again ---
  if [ -f "$dest" ]; then
    local have
    have="$(seed_dl_size "$dest")"
    if [ "$have" = "$size" ]; then
      local known=""
      if [ -f "$shafile" ]; then
        known="$(awk '{print $1}' "$shafile" 2>/dev/null | head -n1)" || known=""
      fi
      if [ "$known" = "$sha" ] || [ "$(seed_dl_sha256 "$dest")" = "$sha" ]; then
        printf '%s  %s\n' "$sha" "$(basename "$dest")" >"$shafile"
        wlog "SEED_DL_FILE_SKIP file=$name bytes=$have sha256=$sha"
        return 0
      fi
    fi
    wlog "SEED_DL_FILE_STALE file=$name bytes=$have expected=$size"
  fi

  local attempt=0
  while :; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$SEED_MAX_ATTEMPTS" ]; then
      wlog "SEED_DL_GAVE_UP file=$name attempts=$((attempt - 1)) bytes=$(seed_dl_size "$part")"
      return 1
    fi

    # --- 1) resolve the (signed) URL ---------------------------------------
    # A fresh resolve per attempt is mandatory: the CDN signature expires
    # after ~1.8 h.
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -I "${CURL_HDR_ARGS[@]}" "$url" 2>/dev/null)" || code="000"
    case "$code" in
      401|403)
        wlog "SEED_DL_AUTH_FAIL http=$code file=$name"
        return 2
        ;;
      2??|3??)
        : ;;
      *)
        wlog "SEED_DL_RESOLVE_FAIL http=$code file=$name attempt=$attempt"
        local d
        d="$(seed_backoff_delay "$attempt")"
        d=$((d * SEED_BACKOFF_SCALE / 100))
        wlog "SEED_DL_RETRY file=$name attempt=$attempt reason=resolve_fail sleep=$d"
        [ "$d" -gt 0 ] && sleep "$d"
        continue
        ;;
    esac

    # --- 2) transfer -------------------------------------------------------
    local offset t_attempt
    offset="$(seed_dl_size "$part")"
    t_attempt="$(date +%s)"
    wlog "SEED_DL_ATTEMPT_START file=$name attempt=$attempt bytes=$offset total=$size"
    if [ "$offset" -gt 0 ]; then
      wlog "SEED_DL_RESUME file=$name offset=$offset"
    fi

    build_curl_args "$dest" "$url"
    monitor_start "$name" "$part" "$size" "$attempt" "$t_attempt"
    local rc=0
    # The transfer runs in a subshell that drops the lock file descriptors:
    # a curl that outlives the worker must not keep the worker lock alive.
    (
      exec 8>&- 9>&-
      if [ "$SEED_TIME_BUDGET_S" -gt 0 ]; then
        exec timeout --signal=TERM "$SEED_TIME_BUDGET_S" curl "${SEED_CURL_ARGS[@]}"
      else
        exec curl "${SEED_CURL_ARGS[@]}"
      fi
    )
    rc=$?
    monitor_stop

    local bytes
    bytes="$(seed_dl_size "$part")"

    if [ "$rc" -eq 0 ]; then
      # --- 3) size --------------------------------------------------------
      if [ "$bytes" != "$size" ]; then
        wlog "SEED_DL_SIZE_MISMATCH file=$name expected=$size got=$bytes"
        return 1
      fi
      # --- 4) sha256 ------------------------------------------------------
      local actual
      actual="$(seed_dl_sha256 "$part")" || actual=""
      if [ "$actual" != "$sha" ]; then
        wlog "SEED_DL_SHA256_MISMATCH file=$name expected=$sha got=$actual"
        return 1
      fi
      # --- 5) publish -----------------------------------------------------
      printf '%s  %s\n' "$sha" "$(basename "$dest")" >"$shafile"
      mv -f "$part" "$dest" || return 1
      wlog "SEED_DL_FILE_OK file=$name bytes=$bytes sha256=$sha"
      wlog "SEED_SHA256_OK file=$name"
      seed_dl_status \
        "STATE=DOWNLOADING" "FILE=$name" "BYTES=$bytes" "TOTAL=$size" \
        "PCT=100.0" "RATE_BPS=0" "ETA_SECONDS=0" "ATTEMPT=$attempt" \
        "PID=$$" "RC=0" "STARTED_AT=$STARTED_AT"
      return 0
    fi

    if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
      # the time budget expired: keep the .part and stop cleanly
      wlog "SEED_DL_BUDGET_EXHAUSTED file=$name bytes=$bytes budget_s=$SEED_TIME_BUDGET_S"
      seed_dl_status \
        "STATE=PAUSED" "FILE=$name" "BYTES=$bytes" "TOTAL=$size" \
        "PCT=0.0" "RATE_BPS=0" "ETA_SECONDS=0" "ATTEMPT=$attempt" \
        "PID=$$" "RC=75" "STARTED_AT=$STARTED_AT"
      return 75
    fi

    # --- 6) classify the failure and retry --------------------------------
    if [ "$rc" -eq 28 ]; then
      wlog "SEED_DL_STALL_KILL file=$name bytes=$bytes"
    else
      wlog "SEED_DL_TRANSFER_FAIL file=$name rc=$rc bytes=$bytes"
    fi
    local d
    d="$(seed_backoff_delay "$attempt")"
    d=$((d * SEED_BACKOFF_SCALE / 100))
    wlog "SEED_DL_RETRY file=$name attempt=$attempt sleep=$d"
    [ "$d" -gt 0 ] && sleep "$d"
  done
}

# --- main -------------------------------------------------------------------
wlog "=== 08_seed_download_worker.sh $STARTED_AT ==="
wlog "SEED_HF_REPO $SEED_HF_REPO"
wlog "SEED_HF_REVISION $SEED_HF_REVISION"
wlog "SEED_DL_WORKER_PID $$"
wlog "SEED_DL_DEST_ROOT=$SEED_DEST_ROOT"

# Global worker lock: a second worker must not touch the same .part files.
GLOBAL_LOCK="${SEED_STATUS_FILE}.worker.lock"
exec 8>"$GLOBAL_LOCK"
if ! flock -n 8; then
  wlog "SEED_DL_ALREADY_RUNNING"
  exit 0
fi

# The file plan (size + sha256 of every file) goes into the log first, so a
# half-finished log still documents what was being fetched.
ENTRIES_FILE="$(mktemp "${TMPDIR:-/tmp}/seed_dl_entries.XXXXXX")"
FILES_TOTAL=0
ARCHIVE_BYTES=0
while IFS=$'\t' read -r name size sha url destrel; do
  [ -n "$name" ] || continue
  FILES_TOTAL=$((FILES_TOTAL + 1))
  case "$name" in
    *.tar.gz) ARCHIVE_BYTES=$((ARCHIVE_BYTES + size)) ;;
  esac
  wlog "SEED_FILE_PLAN file=$name size=$size sha256=$sha"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$size" "$sha" "$url" "$destrel" >>"$ENTRIES_FILE"
done < <(seed_dl_table)
wlog "SEED_FILE_PLAN_TOTAL files=$FILES_TOTAL bytes=$ARCHIVE_BYTES"

RC=0
while IFS=$'\t' read -r name size sha url destrel; do
  [ -n "$name" ] || continue
  if ! seed_dl_filter_ok "$name"; then
    wlog "SEED_DL_SKIP_FILTER file=$name"
    continue
  fi
  seed_dl_status \
    "STATE=DOWNLOADING" "FILE=$name" "BYTES=$(seed_dl_size "$SEED_DEST_ROOT/$destrel.part")" \
    "TOTAL=$size" "PCT=0.0" "RATE_BPS=0" "ETA_SECONDS=0" "ATTEMPT=1" \
    "PID=$$" "RC=" "STARTED_AT=$STARTED_AT"
  download_file "$name" "$size" "$sha" "$url" "$destrel"
  frc=$?
  if [ "$frc" -eq 2 ]; then
    RC=2
    break
  fi
  if [ "$frc" -eq 75 ]; then
    RC=75
    break
  fi
  if [ "$frc" -ne 0 ]; then
    RC=1
    break
  fi
done < "$ENTRIES_FILE"

if [ "$RC" -eq 0 ]; then
  # --- SHA256SUMS ----------------------------------------------------------
  mkdir -p "$(dirname "$SEED_SHA256SUMS")"
  : >"$SEED_SHA256SUMS.tmp"
  while IFS=$'\t' read -r name size sha url destrel; do
    [ -n "$name" ] || continue
    dest="$SEED_DEST_ROOT/$destrel"
    [ -f "$dest" ] || continue
    rel="$(realpath --relative-to="$(dirname "$SEED_SHA256SUMS")" "$dest" 2>/dev/null || basename "$dest")" || rel="$(basename "$dest")"
    printf '%s  %s\n' "$sha" "$rel" >>"$SEED_SHA256SUMS.tmp"
  done < "$ENTRIES_FILE"
  mv -f "$SEED_SHA256SUMS.tmp" "$SEED_SHA256SUMS"
  wlog "SEED_SHA256SUMS_WRITTEN path=$SEED_SHA256SUMS lines=$(wc -l <"$SEED_SHA256SUMS")"
  ELAPSED=$(( $(date +%s) - T_START ))
  wlog "SEED_DOWNLOAD_OK files=$FILES_TOTAL bytes=$ARCHIVE_BYTES elapsed=$ELAPSED"
  seed_dl_status \
    "STATE=DONE" "FILE=" "BYTES=$ARCHIVE_BYTES" "TOTAL=$ARCHIVE_BYTES" \
    "PCT=100.0" "RATE_BPS=0" "ETA_SECONDS=0" "ATTEMPT=" "PID=$$" \
    "RC=0" "STARTED_AT=$STARTED_AT"
else
  ELAPSED=$(( $(date +%s) - T_START ))
  if [ "$RC" -eq 75 ]; then
    # The time budget expired: this is NOT a failure, the .part is kept and
    # the next run resumes from it.
    wlog "SEED_DOWNLOAD_PAUSED rc=$RC elapsed=$ELAPSED"
    seed_dl_status \
      "STATE=PAUSED" "FILE=" "BYTES=0" "TOTAL=0" "PCT=0.0" "RATE_BPS=0" \
      "ETA_SECONDS=0" "ATTEMPT=" "PID=$$" "RC=$RC" "STARTED_AT=$STARTED_AT"
  else
    wlog "SEED_DOWNLOAD_FAILED rc=$RC elapsed=$ELAPSED"
    seed_dl_status \
      "STATE=FAILED" "FILE=" "BYTES=0" "TOTAL=0" "PCT=0.0" "RATE_BPS=0" \
      "ETA_SECONDS=0" "ATTEMPT=" "PID=$$" "RC=$RC" "STARTED_AT=$STARTED_AT"
  fi
fi

rm -f "$ENTRIES_FILE"
exit "$RC"
