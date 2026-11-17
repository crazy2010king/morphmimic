#!/usr/bin/env bash
# repro/10_seed_extract.sh — extract the BONES-SEED archives and reconcile
# the extracted trees against the metadata.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The two archives (g1.tar.gz 23,499,973,647 B + soma_uniform.tar.gz
# 45,188,088,297 B) carry the two trees that S04 (CSV -> npz) and S05 (BVH ->
# human50 sidecar) actually consume:
#
#   data/seed/g1/csv/<session>/<clip>.csv             (142,220 files)
#   data/seed/soma_uniform/bvh/<session>/<clip>.bvh   (142,220 files)
#
# The archive members are RELATIVE paths, so extracting with the seed root
# as the working directory yields exactly the two trees above.
#
# Two facts drive the whole design:
#
#   1. The NFS export is root-squashed and the archive members are owned by
#      another uid -> the extraction MUST carry --no-same-owner.  --same-owner
#      and -p are forbidden (D013: extraction is strictly serial, one archive
#      at a time, so the NFS small-file write rate is not thrashed).
#   2. 284,440 small files at the measured ~22 ms/file is ~90 min per
#      archive, and `find` over 142k files itself takes minutes.  So the
#      extraction runs DETACHED (setsid/nohup worker), the counters are
#      streamed (never slurped into memory) and every step is idempotent
#      (a `.done` marker per archive makes a re-run skip what is done).
#
# SUBCOMMANDS
#   start            launch the detached extraction worker (returns at once)
#   status           print status file + worker liveness (always exit 0)
#   wait [seconds]   bounded wait (default 75); 0=DONE 1=FAILED 75=timeout
#   worker           foreground extraction + reconciliation (used by `start`)
#   verify           READ-ONLY reconciliation of the extracted trees
#   selftest         run the offline fixture battery
#
# ENVIRONMENT OVERRIDES (used by the offline fixtures)
#   SEED_ARCHIVE_DIR          default <repo>/data/seed/_archives
#   SEED_EXTRACT_ROOT         default <repo>/data/seed
#   SEED_EXTRACT_DONE_DIR     default $SEED_EXTRACT_ROOT/_extract
#   SEED_EXTRACT_LOG          default <repo>/logs/env/10_seed_extract.txt
#   SEED_EXTRACT_STATUS       default <repo>/logs/env/10_seed_extract.status
#   SEED_EXTRACT_WORKER_LOG   default <repo>/logs/env/10_seed_extract_worker.log
#   SEED_METADATA_CSV         default $SEED_EXTRACT_ROOT/metadata/seed_metadata_v004.csv
#   SEED_MIN_FREE_GB          default 400 (free space gate)
#   SEED_EXPECTED_CLIPS_G1    default 142220
#   SEED_EXPECTED_CLIPS_SOMA  default 142220
#   SEED_EXTRACT_ALLOW_LOCAL=1  allow running outside the ros_dev container
#
# MARKERS (grep -F friendly)
#   SEED_EXTRACT_GATE_SPACE required_gb=<n> free_gb=<n>
#   SEED_EXTRACT_GATE_FAIL reason=<...>
#   SEED_EXTRACT_START file=<archive>
#   SEED_EXTRACT_SKIP file=<archive> reason=done-marker-matches-tree
#   SEED_EXTRACT_DONE file=<archive> clips=<n> sha256=<sha> elapsed_s=<n>
#   SEED_EXTRACT_FILES file=<g1|soma_uniform> count=<n>
#   SEED_EXTRACT_ZERO_BYTE count=<n>
#   SEED_META_MATCH matched=<n> missing=<n> extra=<n>
#   SEED_META_SESSION session=<date> expected=<n> actual=<n>
#   SEED_EXTRACT_OK files=<n>
#
# A failing run NEVER prints SEED_EXTRACT_OK.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
if [ "${SEED_EXTRACT_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi
# shellcheck source=lib/seed_archive.sh
source "$_SCRIPT_DIR/lib/seed_archive.sh"

ARCHIVE_DIR="${SEED_ARCHIVE_DIR:-$REPO_ROOT/data/seed/_archives}"
EXTRACT_ROOT="${SEED_EXTRACT_ROOT:-$REPO_ROOT/data/seed}"
DONE_DIR="${SEED_EXTRACT_DONE_DIR:-$EXTRACT_ROOT/_extract}"
MAIN_LOG="${SEED_EXTRACT_LOG:-$LOG_DIR/10_seed_extract.txt}"
STATUS_FILE="${SEED_EXTRACT_STATUS:-$LOG_DIR/10_seed_extract.status}"
WORKER_LOG="${SEED_EXTRACT_WORKER_LOG:-$LOG_DIR/10_seed_extract_worker.log}"
METADATA_CSV="${SEED_METADATA_CSV:-$EXTRACT_ROOT/metadata/seed_metadata_v004.csv}"

G1_TREE="$EXTRACT_ROOT/g1/csv"
SOMA_TREE="$EXTRACT_ROOT/soma_uniform/bvh"

SEED_ARCHIVES=(g1.tar.gz soma_uniform.tar.gz)

usage() {
  cat <<EOF
usage: bash repro/10_seed_extract.sh [start|status|wait [seconds]|worker|verify|selftest]

  start            launch the detached extraction worker
  status           print the status file + worker liveness
  wait [sec]       bounded wait (default 75s); 0=DONE 1=FAILED 75=timeout
  worker           foreground extraction + reconciliation
  verify           read-only reconciliation of the extracted trees
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

# OK_MARKERS: buffered success markers, flushed only when every check
# passed (same convention as repro/09_seed_verify.sh).
OK_MARKERS=()
olog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do olog "$m"; done
  OK_MARKERS=()
}

# --- status -----------------------------------------------------------------
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

status_write() {
  # status_write <state> <rc> [key=value ...]
  local state="$1" rc="$2"; shift 2 || true
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
  {
    printf 'STATE=%s\n' "$state"
    printf 'RC=%s\n' "$rc"
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
    printf 'STARTED_AT=%s\n' "$STARTED_AT"
    printf 'FINISHED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$STATUS_FILE.tmp" 2>/dev/null || true
  mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null || true
}

extract_state() {
  # extract_state -> prints STATE=RUNNING|DONE|FAILED|ABSENT
  if [ ! -f "$STATUS_FILE" ]; then
    echo "STATE=ABSENT"
    return 3
  fi
  local state pid
  state="$(sed -n 's/^STATE=//p' "$STATUS_FILE" | head -n1)"
  pid="$(sed -n 's/^PID=//p' "$STATUS_FILE" | head -n1)"
  case "${state:-}" in
    DONE|FAILED)
      echo "STATE=$state"
      return 0
      ;;
  esac
  if [ -n "${pid:-}" ] && [ "$pid" != "0" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "STATE=FAILED"
    echo "REASON=worker pid $pid is gone but no terminal state was written"
    return 0
  fi
  echo "STATE=RUNNING"
  return 0
}

# --- tree helpers -----------------------------------------------------------
# tree_root <archive>  -> the extracted tree root of an archive
tree_root() {
  case "$(basename "$1")" in
    g1.tar.gz)           printf '%s' "$G1_TREE" ;;
    soma_uniform.tar.gz) printf '%s' "$SOMA_TREE" ;;
    *) return 1 ;;
  esac
}

# tree_ext <archive> -> the file extension of the clips in the archive
tree_ext() {
  case "$(basename "$1")" in
    g1.tar.gz)           printf 'csv' ;;
    soma_uniform.tar.gz) printf 'bvh' ;;
    *) return 1 ;;
  esac
}

# count_tree <root> <ext> -> number of files (streamed, never buffered)
count_tree() {
  local root="$1" ext="$2" n=0
  if [ ! -d "$root" ]; then
    printf '0'
    return 0
  fi
  n="$(find "$root" -type f -name "*.$ext" 2>/dev/null | wc -l)"
  printf '%s' "$n"
}

# count_zero_byte <root> <ext> -> number of empty files (streamed)
count_zero_byte() {
  local root="$1" ext="$2" n=0
  if [ ! -d "$root" ]; then
    printf '0'
    return 0
  fi
  n="$(find "$root" -type f -name "*.$ext" -size 0 2>/dev/null | wc -l)"
  printf '%s' "$n"
}

expected_clips_for() {
  case "$(basename "$1")" in
    g1.tar.gz)           printf '%s' "${SEED_EXPECTED_CLIPS_G1:-$(seed_archive_expected_clips g1.tar.gz)}" ;;
    soma_uniform.tar.gz) printf '%s' "${SEED_EXPECTED_CLIPS_SOMA:-$(seed_archive_expected_clips soma_uniform.tar.gz)}" ;;
    *) return 1 ;;
  esac
}

# --- gates ------------------------------------------------------------------
# gate_preverify: the archive must have passed repro/09_seed_verify.sh
# (sha256 + gzip CRC + clip count + layout).  Re-running it here is cheap
# compared to a 90 min extraction of a broken archive.
gate_preverify() {
  local verifier="$REPO_ROOT/repro/09_seed_verify.sh"
  if [ ! -f "$verifier" ]; then
    olog "SEED_EXTRACT_GATE_FAIL reason=verifier-missing path=$verifier"
    return 1
  fi
  local rc=0
  olog "SEED_EXTRACT_GATE_PREVERIFY start"
  # The verifier gets ITS OWN log/status files: re-running the gate must not
  # overwrite logs/env/09_seed_verify.txt (that log is the T3 evidence).
  local vlog vstatus
  vlog="$(mktemp "${TMPDIR:-/tmp}/seed_preverify.XXXXXX.log")"
  vstatus="$(mktemp "${TMPDIR:-/tmp}/seed_preverify.XXXXXX.status")"
  local venv=(
    SEED_VERIFY_ALLOW_LOCAL=1
    SEED_ARCHIVE_DIR="$ARCHIVE_DIR"
    SEED_VERIFY_LOG="$vlog"
    SEED_VERIFY_STATUS="$vstatus"
  )
  [ -n "${SEED_EXPECTED_CLIPS_G1:-}" ] && venv+=("SEED_EXPECTED_CLIPS_G1=$SEED_EXPECTED_CLIPS_G1")
  [ -n "${SEED_EXPECTED_CLIPS_SOMA:-}" ] && venv+=("SEED_EXPECTED_CLIPS_SOMA=$SEED_EXPECTED_CLIPS_SOMA")
  set +e
  env "${venv[@]}" bash "$verifier" verify >>"$MAIN_LOG" 2>&1
  rc=$?
  set -e
  rm -f "$vlog" "$vstatus"
  if [ "$rc" -ne 0 ]; then
    olog "SEED_EXTRACT_GATE_FAIL reason=preverify-failed rc=$rc"
    return 1
  fi
  olog "SEED_EXTRACT_GATE_PREVERIFY_OK"
  return 0
}

# gate_space: the filesystem holding the extraction root must have at least
# SEED_MIN_FREE_GB GiB free.
gate_space() {
  local required free
  required="$(seed_min_free_gb)"
  free="$(seed_free_gb "$EXTRACT_ROOT")"
  if [ -z "$free" ]; then
    olog "SEED_EXTRACT_GATE_FAIL reason=free-space-unknown dir=$EXTRACT_ROOT"
    return 1
  fi
  if [ "$free" -lt "$required" ]; then
    olog "SEED_EXTRACT_SPACE_LOW required_gb=$required free_gb=$free dir=$EXTRACT_ROOT"
    olog "ERROR: 空间不足 — 解包目录 $EXTRACT_ROOT 只剩 ${free} GB，需要至少 ${required} GB"
    olog "SEED_EXTRACT_GATE_FAIL reason=insufficient-space required_gb=$required free_gb=$free"
    return 1
  fi
  olog "SEED_EXTRACT_GATE_SPACE required_gb=$required free_gb=$free"
  return 0
}

# gate_target: the extraction root must exist and be writable.
gate_target() {
  if [ ! -d "$EXTRACT_ROOT" ]; then
    olog "SEED_EXTRACT_GATE_FAIL reason=target-missing dir=$EXTRACT_ROOT"
    olog "ERROR: 解包目标目录不存在 — $EXTRACT_ROOT"
    return 1
  fi
  if [ ! -w "$EXTRACT_ROOT" ]; then
    olog "SEED_EXTRACT_GATE_FAIL reason=target-not-writable dir=$EXTRACT_ROOT"
    olog "ERROR: 解包目标目录不可写 — $EXTRACT_ROOT"
    return 1
  fi
  olog "SEED_EXTRACT_GATE_TARGET dir=$EXTRACT_ROOT"
  return 0
}

# --- extraction -------------------------------------------------------------
# extract_archive <archive>
# Serial extraction (D013).  Idempotent: when the `.done` marker exists and
# the tree still carries the recorded number of clips, the archive is
# skipped.
extract_archive() {
  local name="$1"
  local archive="$ARCHIVE_DIR/$name"
  local root ext expected done_file recorded actual sha elapsed t0

  if [ ! -f "$archive" ]; then
    olog "SEED_EXTRACT_FAIL reason=archive-missing file=$name path=$archive"
    return 1
  fi

  root="$(tree_root "$name")"
  ext="$(tree_ext "$name")"
  expected="$(expected_clips_for "$name")"
  done_file="$DONE_DIR/$name.done"

  if [ -f "$done_file" ]; then
    recorded="$(sed -n 's/^clips=//p' "$done_file" | head -n1)"
    actual="$(count_tree "$root" "$ext")"
    if [ -n "${recorded:-}" ] && [ "$recorded" = "$actual" ] && [ "$actual" = "$expected" ]; then
      olog "SEED_EXTRACT_SKIP file=$name reason=done-marker-matches-tree clips=$actual"
      return 0
    fi
    olog "SEED_EXTRACT_REDO file=$name recorded_clips=${recorded:-none} actual_clips=$actual expected_clips=$expected"
  fi

  olog "SEED_EXTRACT_START file=$name archive=$archive target=$root"
  mkdir -p "$root" "$DONE_DIR"
  t0="$(date +%s)"
  # --no-same-owner is mandatory (root-squashed NFS); -p/--same-owner are
  # forbidden.  --no-same-permissions keeps the umask default instead of
  # the archive's 0770 members, so the trees stay readable for S04/S05.
  set +e
  tar -xzf "$archive" -C "$EXTRACT_ROOT" \
      --no-same-owner --no-same-permissions --warning=no-unknown-keyword \
      >>"$MAIN_LOG" 2>&1
  local rc=$?
  set -e
  elapsed=$(( $(date +%s) - t0 ))
  if [ "$rc" -ne 0 ]; then
    olog "SEED_EXTRACT_FAIL reason=tar-failed file=$name rc=$rc elapsed_s=$elapsed"
    return 1
  fi

  actual="$(count_tree "$root" "$ext")"
  sha="$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')"
  {
    printf 'archive=%s\n' "$name"
    printf 'clips=%s\n' "$actual"
    printf 'sha256=%s\n' "${sha:-unknown}"
    printf 'elapsed_s=%s\n' "$elapsed"
    printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$done_file.tmp" 2>/dev/null || true
  mv -f "$done_file.tmp" "$done_file" 2>/dev/null || true
  olog "SEED_EXTRACT_DONE file=$name clips=$actual expected=$expected sha256=${sha:-unknown} elapsed_s=$elapsed"

  if [ "$actual" != "$expected" ]; then
    olog "SEED_EXTRACT_FAIL reason=clip-count-mismatch file=$name expected=$expected actual=$actual"
    return 1
  fi
  return 0
}

# --- reconciliation (read-only) --------------------------------------------
# cmd_reconcile: counts the two trees, scans for empty files and reconciles
# them against the metadata.  Prints:
#   SEED_EXTRACT_FILES file=g1 count=<n>
#   SEED_EXTRACT_FILES file=soma_uniform count=<n>
#   SEED_EXTRACT_ZERO_BYTE count=<n>
#   SEED_META_MATCH matched=<n> missing=<n> extra=<n>
#   SEED_META_SESSION session=<date> expected=<n> actual=<n>
#   SEED_EXTRACT_OK files=<n>
cmd_reconcile() {
  local g1_count soma_count zero_total rc=0
  g1_count="$(count_tree "$G1_TREE" csv)"
  soma_count="$(count_tree "$SOMA_TREE" bvh)"
  zero_total=$(( $(count_zero_byte "$G1_TREE" csv) + $(count_zero_byte "$SOMA_TREE" bvh) ))

  olog "SEED_EXTRACT_FILES file=g1 count=$g1_count"
  olog "SEED_EXTRACT_FILES file=soma_uniform count=$soma_count"
  olog "SEED_EXTRACT_ZERO_BYTE count=$zero_total"

  if [ ! -f "$METADATA_CSV" ]; then
    olog "SEED_EXTRACT_FAIL reason=metadata-missing path=$METADATA_CSV"
    olog "ERROR: metadata 未就位 — $METADATA_CSV"
    return 1
  fi

  # The metadata reconciliation itself (stdlib only, no network).
  local py_out
  py_out="$(mktemp "${TMPDIR:-/tmp}/seed_meta.XXXXXX")"
  set +e
  python3 "$REPO_ROOT/repro/lib/seed_verify.py" \
      --metadata "$METADATA_CSV" \
      --g1-csv "$G1_TREE" \
      --soma-bvh "$SOMA_TREE" \
      --sessions "$G1_TREE" \
      --mode clips >"$py_out" 2>&1
  rc=$?
  set -e
  # The script prints its own zero-byte counter; keep the python output but
  # drop the duplicated SEED_EXTRACT_ZERO_BYTE line.
  grep -v '^SEED_EXTRACT_ZERO_BYTE' "$py_out" | while IFS= read -r line; do olog "$line"; done
  rm -f "$py_out"

  if [ "$rc" -ne 0 ]; then
    olog "SEED_EXTRACT_FAIL reason=metadata-reconcile-failed rc=$rc"
    return 1
  fi
  if [ "$zero_total" -ne 0 ]; then
    olog "SEED_EXTRACT_FAIL reason=zero-byte-files count=$zero_total"
    return 1
  fi

  local expected_g1 expected_soma
  expected_g1="$(expected_clips_for g1.tar.gz)"
  expected_soma="$(expected_clips_for soma_uniform.tar.gz)"
  if [ "$g1_count" != "$expected_g1" ] || [ "$soma_count" != "$expected_soma" ]; then
    olog "SEED_EXTRACT_FAIL reason=clip-count-mismatch g1=$g1_count/$expected_g1 soma=$soma_count/$expected_soma"
    return 1
  fi

  olog_ok "SEED_EXTRACT_OK files=$((g1_count + soma_count))"
  flush_ok_markers
  return 0
}

# --- worker -----------------------------------------------------------------
cmd_worker() {
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  olog "=== 10_seed_extract.sh worker $STARTED_AT ==="
  olog "SEED_EXTRACT_ARCHIVE_DIR dir=$ARCHIVE_DIR"
  olog "SEED_EXTRACT_ROOT dir=$EXTRACT_ROOT"
  status_write RUNNING 0 "PID=$$" "FILE="

  if ! gate_preverify; then
    status_write FAILED 1 "PID=$$" "FILE="
    exit 1
  fi
  if ! gate_space; then
    status_write FAILED 1 "PID=$$" "FILE="
    exit 1
  fi
  if ! gate_target; then
    status_write FAILED 1 "PID=$$" "FILE="
    exit 1
  fi

  local name
  for name in "${SEED_ARCHIVES[@]}"; do
    status_write RUNNING 0 "PID=$$" "FILE=$name"
    if ! extract_archive "$name"; then
      status_write FAILED 1 "PID=$$" "FILE=$name"
      exit 1
    fi
  done

  if ! cmd_reconcile; then
    status_write FAILED 1 "PID=$$" "FILE="
    exit 1
  fi
  status_write DONE 0 "PID=$$" "FILE="
  olog "=== 10_seed_extract.sh worker DONE $STARTED_AT ==="
  return 0
}

# --- start / status / wait --------------------------------------------------
cmd_start() {
  local state
  state="$(extract_state | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
  if [ "$state" = "RUNNING" ]; then
    olog "worker already RUNNING:"
    extract_state | while IFS= read -r line; do olog "$line"; done || true
    return 0
  fi
  olog "starting detached seed-extract worker ..."
  mkdir -p "$LOG_DIR"
  setsid nohup bash "$_SCRIPT_DIR/10_seed_extract.sh" worker >>"$WORKER_LOG" 2>&1 </dev/null &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  olog "WORKER_PID=$pid"
  olog "STATUS_FILE=$STATUS_FILE"
  olog "WORKER_LOG=$WORKER_LOG"
  return 0
}

cmd_status() {
  echo "=== 10_seed_extract.sh status $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  extract_state || true
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

cmd_wait() {
  local timeout_s="${1:-75}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local state
  while :; do
    state="$(extract_state | sed -n 's/^STATE=//p' | head -n1)" || state="ABSENT"
    case "$state" in
      DONE)  olog "worker finished: DONE";  return 0 ;;
      FAILED) olog "worker finished: FAILED"; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      olog "worker still running after ${timeout_s}s - keep polling:"
      olog "  bash repro/lib/remote.sh 10_seed_extract.sh status"
      olog "  bash repro/lib/remote.sh 10_seed_extract.sh wait 75"
      return 75
    fi
    sleep 5
  done
}

cmd_verify() {
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  olog "=== 10_seed_extract.sh verify $STARTED_AT ==="
  status_write RUNNING 0 "PID=$$" "FILE="
  if cmd_reconcile; then
    status_write OK 0 "PID=$$" "FILE="
    return 0
  fi
  status_write FAILED 1 "PID=$$" "FILE="
  return 1
}

cmd_selftest() {
  exec bash "$REPO_ROOT/repro/tests/test_seed_extract.sh"
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
