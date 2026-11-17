#!/usr/bin/env bash
# repro/09_seed_verify.sh — archive-level integrity gate for BONES-SEED.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The two BONES-SEED archives (g1.tar.gz 23,499,973,647 B +
# soma_uniform.tar.gz 45,188,088,297 B) travel through a proxy that has been
# observed to truncate / corrupt transfers. Unpacking 68 GB (>= 3 h of NFS
# small-file writes) is far too expensive to discover at the end that the
# archive was broken. This script is the gate in front of the unpack step:
#
#   1. sha256   — data/seed/_archives/SHA256SUMS must check out
#                  (the hashes are the HF API lfs.oid values, pinned in
#                  repro/lib/seed_download.sh)
#   2. gzip CRC — `tar -tzf` reads the whole member stream, so the gzip
#                  trailer CRC/ISIZE is verified implicitly; a truncated or
#                  corrupted archive makes tar exit non-zero
#   3. counts   — the archive must carry exactly 142,220 clips
#                  (142,220 CSV for g1, 142,220 BVH for soma_uniform)
#   4. layout   — every member must be a relative path of the shape
#                  g1/csv/<date>/<clip>.csv | soma_uniform/bvh/<date>/<clip>.bvh
#                  (no absolute paths, no "..", no foreign prefixes)
#
# The script is strictly READ-ONLY with respect to the data: it never
# touches the network and never unpacks anything. It may be re-run at any
# time; it only writes its own log and status file.
#
# SUBCOMMANDS
#   verify    run the four gates above (default)
#   selftest  run the offline fixture battery (repro/tests/test_seed_verify.sh)
#
# ENVIRONMENT OVERRIDES (used by the offline test fixtures)
#   SEED_ARCHIVE_DIR            default <repo>/data/seed/_archives
#   SEED_SHA256SUMS             default $SEED_ARCHIVE_DIR/SHA256SUMS
#   SEED_VERIFY_LOG             default <repo>/logs/env/09_seed_verify.txt
#   SEED_VERIFY_STATUS          default <repo>/logs/env/09_seed_verify.status
#   SEED_EXPECTED_CLIPS_G1      default 142220 (from repro/lib/seed_archive.sh)
#   SEED_EXPECTED_CLIPS_SOMA    default 142220
#   SEED_VERIFY_ALLOW_LOCAL=1   allow running outside the ros_dev container
#                               (the offline fixture test must run locally)
#
# MARKERS (grep -F friendly)
#   SEED_SHA256_OK file=<archive>
#   SEED_SHA256_MISMATCH file=<archive> expected=<sha> actual=<sha>
#   SEED_TAR_GZIP_OK file=<archive>
#   SEED_TAR_GZIP_FAIL file=<archive>
#   SEED_TAR_ENTRIES file=<archive> total=<n> dirs=<n> csv=<n> bvh=<n>
#   SEED_TAR_CLIPS file=<g1|soma_uniform> kind=<csv|bvh> count=<n>
#   SEED_TAR_CLIPS_MISMATCH file=<archive> expected=<n> actual=<n>
#   SEED_TAR_LAYOUT_OK file=<archive>
#   SEED_TAR_LAYOUT_FAIL file=<archive> entry=<member>
#   SEED_ARCHIVE_MISSING file=<archive>
#   SEED_VERIFY_OK archives=2 clips=284440
#
# A failing run NEVER prints any *_OK marker.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/seed_archive.sh
source "$_SCRIPT_DIR/lib/seed_archive.sh"

if [ "${SEED_VERIFY_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

cd "$REPO_ROOT"

ARCHIVE_DIR="${SEED_ARCHIVE_DIR:-$REPO_ROOT/data/seed/_archives}"
SHA256SUMS_FILE="${SEED_SHA256SUMS:-$ARCHIVE_DIR/SHA256SUMS}"
MAIN_LOG="${SEED_VERIFY_LOG:-$LOG_DIR/09_seed_verify.txt}"
STATUS_FILE="${SEED_VERIFY_STATUS:-$LOG_DIR/09_seed_verify.status}"

# The two archives, in verification order.
SEED_ARCHIVES=(g1.tar.gz soma_uniform.tar.gz)

usage() {
  cat <<EOF
usage: bash repro/09_seed_verify.sh [verify|selftest]

  verify    sha256 + gzip CRC + clip count + layout (default)
  selftest  offline fixture battery (no network, synthetic archives)

logs:  $MAIN_LOG
       $STATUS_FILE
EOF
}

# --- output -----------------------------------------------------------------
# olog prints to stdout AND appends to the log, so every marker of this
# script is greppable in logs/env/09_seed_verify.txt.
olog() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# OK_MARKERS holds the success markers of the individual gates. They are
# BUFFERED and only flushed when EVERY gate passed, so a failing run can
# never emit a single "*_OK" marker (the contract asserted by
# repro/tests/test_seed_verify.sh).
OK_MARKERS=()
olog_ok() {
  OK_MARKERS+=("$*")
}

# flush_ok_markers — emit the buffered success markers (only on the happy path)
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do
    olog "$m"
  done
  OK_MARKERS=()
}

# --- status -----------------------------------------------------------------
status_write() {
  # status_write <state> <rc>
  local state="$1" rc="$2"
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
  {
    printf 'STATE=%s\n' "$state"
    printf 'RC=%s\n' "$rc"
    printf 'STARTED_AT=%s\n' "$STARTED_AT"
    printf 'FINISHED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$STATUS_FILE.tmp" 2>/dev/null || true
  mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null || true
}

# --- helpers ----------------------------------------------------------------
expected_clips_for() {
  # expected_clips_for <archive basename>
  case "$1" in
    g1.tar.gz)        printf '%s' "${SEED_EXPECTED_CLIPS_G1:-$(seed_archive_expected_clips g1.tar.gz)}" ;;
    soma_uniform.tar.gz) printf '%s' "${SEED_EXPECTED_CLIPS_SOMA:-$(seed_archive_expected_clips soma_uniform.tar.gz)}" ;;
    *) return 1 ;;
  esac
}

# sha256sum -c on a filtered checksum list (only the archive lines) so the
# metadata entry of the global SHA256SUMS (which lives in a sibling
# directory) cannot make the archive gate fail for the wrong reason.
sha_gate_archive() {
  # sha_gate_archive <archive basename> -> prints the sha256, rc 0 on match
  local name="$1" expected actual sumfile
  if [ ! -f "$SHA256SUMS_FILE" ]; then
    olog "SEED_SHA256_MISMATCH file=SHA256SUMS reason=missing path=$SHA256SUMS_FILE"
    return 1
  fi
  sumfile="$(mktemp "${TMPDIR:-/tmp}/seed_sha.XXXXXX")"
  # SHA256SUMS lines look like "<sha256>  <name>"; match the archive name.
  awk -v want="$name" '
    { line=$0
      sub(/^[0-9a-fA-F]+[[:space:]]+\*?/, "", line)
      n=split(line, parts, "/")
      base=parts[n]
      if (base == want) print $0 }
  ' "$SHA256SUMS_FILE" >"$sumfile"
  if [ ! -s "$sumfile" ]; then
    rm -f "$sumfile"
    olog "SEED_SHA256_MISMATCH file=$name reason=not-listed path=$SHA256SUMS_FILE"
    return 1
  fi
  expected="$(awk '{print $1; exit}' "$sumfile")"
  actual="$(sha256sum "$ARCHIVE_DIR/$name" | awk '{print $1}')"
  rm -f "$sumfile"
  if [ "$expected" != "$actual" ]; then
    olog "SEED_SHA256_MISMATCH file=$name expected=$expected actual=$actual"
    return 1
  fi
  olog_ok "SEED_SHA256_OK file=$name sha256=$actual"
  return 0
}

# layout_gate <archive basename> <list file>
# Every member must be a relative path below the expected prefix.
layout_gate() {
  local name="$1" list="$2" prefix root kind entry bad=""
  prefix="$(seed_archive_prefix "$name")"
  root="$(seed_archive_root "$name")"
  kind="$(seed_archive_kind "$name")"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    local stripped="${entry%/}"
    case "$stripped" in
      /*) bad="absolute path: $entry"; break ;;
    esac
    case "/$stripped/" in
      */../*) bad="parent traversal: $entry"; break ;;
    esac
    case "$stripped" in
      "$root"|"$root/$kind"|"$prefix"*) : ;;
      *) bad="unexpected prefix: $entry"; break ;;
    esac
  done <"$list"
  if [ -n "$bad" ]; then
    olog "SEED_TAR_LAYOUT_FAIL file=$name entry=$bad"
    return 1
  fi
  olog_ok "SEED_TAR_LAYOUT_OK file=$name"
  return 0
}

# --- verify -----------------------------------------------------------------
cmd_verify() {
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  olog "=== 09_seed_verify.sh verify $STARTED_AT ==="
  olog "SEED_VERIFY_ARCHIVE_DIR dir=$ARCHIVE_DIR"
  status_write RUNNING 0

  local name path list clips_total=0

  # --- gate 0: the archives must be in place -------------------------------
  for name in "${SEED_ARCHIVES[@]}"; do
    path="$ARCHIVE_DIR/$name"
    if [ ! -f "$path" ]; then
      olog "SEED_ARCHIVE_MISSING file=$name path=$path reason=归档未就位 (archive not in place)"
      olog "ERROR: 归档未就位 — $path 不存在，无法校验"
      status_write FAILED 1
      exit 1
    fi
  done

  # --- gate 1: sha256 -------------------------------------------------------
  for name in "${SEED_ARCHIVES[@]}"; do
    if ! sha_gate_archive "$name"; then
      status_write FAILED 1
      exit 1
    fi
  done

  # --- gate 2: gzip integrity + entry listing ------------------------------
  local lists=()
  for name in "${SEED_ARCHIVES[@]}"; do
    path="$ARCHIVE_DIR/$name"
    list="$(mktemp "${TMPDIR:-/tmp}/seed_verify_list.XXXXXX")"
    if ! tar -tzf "$path" >"$list" 2>/dev/null; then
      rm -f "$list"
      olog "SEED_TAR_GZIP_FAIL file=$name reason=gzip stream / tar structure broken"
      status_write FAILED 1
      exit 1
    fi
    olog_ok "SEED_TAR_GZIP_OK file=$name"
    lists+=("$list")
  done

  # --- gate 3: entry counts -------------------------------------------------
  local idx=0
  for name in "${SEED_ARCHIVES[@]}"; do
    list="${lists[$idx]}"; idx=$((idx + 1))
    local total=0 dirs=0 csv=0 bvh=0 entry kind root expected actual
    while IFS= read -r entry; do
      total=$((total + 1))
      case "$entry" in
        */) dirs=$((dirs + 1)) ;;
      esac
      case "$entry" in
        *.csv) csv=$((csv + 1)) ;;
        *.bvh) bvh=$((bvh + 1)) ;;
      esac
    done <"$list"
    olog "SEED_TAR_ENTRIES file=$name total=$total dirs=$dirs csv=$csv bvh=$bvh"

    kind="$(seed_archive_kind "$name")"
    root="$(seed_archive_root "$name")"
    expected="$(expected_clips_for "$name")"
    if [ "$kind" = "csv" ]; then actual="$csv"; else actual="$bvh"; fi
    if [ "$actual" != "$expected" ]; then
      olog "SEED_TAR_CLIPS_MISMATCH file=$name expected=$expected actual=$actual"
      rm -f ${lists[@]+"${lists[@]}"}
      status_write FAILED 1
      exit 1
    fi
    olog_ok "SEED_TAR_CLIPS file=$root kind=$kind count=$actual"
    clips_total=$((clips_total + actual))
  done

  # --- gate 4: layout -------------------------------------------------------
  idx=0
  for name in "${SEED_ARCHIVES[@]}"; do
    list="${lists[$idx]}"; idx=$((idx + 1))
    if ! layout_gate "$name" "$list"; then
      rm -f ${lists[@]+"${lists[@]}"}
      status_write FAILED 1
      exit 1
    fi
  done
  rm -f ${lists[@]+"${lists[@]}"}

  # every gate passed -> the buffered success markers may be emitted now
  flush_ok_markers
  olog "SEED_VERIFY_OK archives=${#SEED_ARCHIVES[@]} clips=$clips_total"
  status_write OK 0
  return 0
}

# --- selftest ---------------------------------------------------------------
cmd_selftest() {
  # The fixture battery lives in the test file so that the same assertions
  # run locally (bash repro/tests/test_seed_verify.sh) and in the container
  # (bash repro/lib/remote.sh 09_seed_verify.sh selftest).
  exec bash "$REPO_ROOT/repro/tests/test_seed_verify.sh"
}

case "${1:-verify}" in
  verify)   shift || true; cmd_verify "$@" ;;
  selftest) cmd_selftest ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
