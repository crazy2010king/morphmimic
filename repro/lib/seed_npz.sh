#!/usr/bin/env bash
# repro/lib/seed_npz.sh — pure shell helpers for the G1 50 Hz npz conversion
# (slice S04): expected row count, disk-space gate, uniform manifest sampling
# and atomic status-file writes.
#
# No network access, no writes outside the status file the caller names.
# Source it, do not execute it:
#   source repro/lib/seed_npz.sh
#
# The decision logic that needs real parsing (manifest statistics, error
# rate, subset nesting) lives in the stdlib-only python module
# repro/lib/seed_npz.py; this file only holds what shell can decide cheaply
# and delegates the CSV parsing to that module.

# Directory of this library, used to find seed_npz.py.
SEED_NPZ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- facts ------------------------------------------------------------------

# seed_npz_expected_rows
# Expected number of manifest DATA rows for the G1 conversion.
# Overridable with SEED_EXPECTED_ROWS (the offline fixtures use a small
# number so the same assertions can be exercised without the real payload).
seed_npz_expected_rows() {
  printf '%s' "${SEED_EXPECTED_ROWS:-142220}"
}

# seed_npz_min_free_gb
# Minimum free space (GiB) required on the filesystem that will hold the
# converted npz files. Overridable with SEED_MIN_FREE_GB.
seed_npz_min_free_gb() {
  printf '%s' "${SEED_MIN_FREE_GB:-250}"
}

# --- disk space gate --------------------------------------------------------

# seed_npz_free_gb <dir>
# Prints the free space of the filesystem holding <dir>, in whole GiB.
# Prints nothing and returns non-zero when <dir> cannot be stat'ed.
seed_npz_free_gb() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  [ -e "$dir" ] || return 1
  df -Pk "$dir" 2>/dev/null | awk 'NR==2 { printf "%d\n", $4 / 1024 / 1024 }'
}

# seed_npz_space_gate <dir>
# Succeeds (rc 0) when the filesystem holding <dir> has at least
# seed_npz_min_free_gb GiB free, fails (rc 1) otherwise and prints an
# explicit hint. Fail closed: an unmeasurable directory fails.
seed_npz_space_gate() {
  local dir="$1" free min
  min="$(seed_npz_min_free_gb)"
  if ! free="$(seed_npz_free_gb "$dir")" || [ -z "$free" ]; then
    printf '空间不足: 无法测量目录 %s 的可用空间\n' "$dir" >&2
    return 1
  fi
  if [ "$free" -lt "$min" ]; then
    printf '空间不足: %s 可用 %s GiB < 要求的 %s GiB\n' "$dir" "$free" "$min" >&2
    return 1
  fi
  printf 'space gate ok: %s free=%s GiB min=%s GiB\n' "$dir" "$free" "$min"
  return 0
}

# --- manifest sampling ------------------------------------------------------

# seed_npz_sample_paths <manifest> <n>
# Prints n evenly spaced `path` values of the manifest, one per line.
# The sampling is deterministic (no RNG): sample i of n picks
# round(i * (rows - 1) / (n - 1)), so the sample spans the whole manifest
# instead of clustering in its head.
#
# The manifest is parsed by repro/lib/seed_npz.py (stdlib csv), NOT by awk:
# upstream writes the manifest with pandas `to_csv`, so a field may be
# quoted and a naive `awk -F,` would mis-align the columns.  The python
# module holds the single canonical implementation of the sampling; this
# function is a thin wrapper so the bash layer cannot drift away from it.
seed_npz_sample_paths() {
  local manifest="$1" n="${2:-0}"
  [ -n "$manifest" ] || return 1
  [ -f "$manifest" ] || return 1
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$n" -gt 0 ] || return 0
  local py="${SEED_NPZ_PY:-$SEED_NPZ_LIB_DIR/seed_npz.py}"
  local python_bin="${SEED_NPZ_PYTHON:-python3}"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf '无法抽样: 找不到 %s\n' "$python_bin" >&2
    return 1
  fi
  if [ ! -f "$py" ]; then
    printf '无法抽样: 找不到 %s\n' "$py" >&2
    return 1
  fi
  "$python_bin" "$py" sample-paths "$manifest" "$n"
}

# --- progress parsing --------------------------------------------------------

# seed_npz_parse_progress <stderr file>
# Prints "done total rate" for the last tqdm progress line in <stderr file>
# (or nothing when the file holds no progress line yet).
#
# The upstream converter reports its progress with tqdm on STDERR, using
# carriage returns instead of newlines:
#   convert:  45%|#####     | 64000/142220 [00:30<00:40, 2.1kit/s]
# so the file must be split on \r before it is parsed.  The rate unit is
# stripped ("2.1kit/s" -> "2.1k"), the count is kept as a plain number.
#
# Fail closed: a malformed or empty file yields no output at all (the caller
# then simply reports no progress yet, instead of a bogus done count).
seed_npz_parse_progress() {
  local file="$1"
  [ -n "$file" ] || return 1
  [ -f "$file" ] || return 1
  tr '\r' '\n' <"$file" 2>/dev/null | awk '
    /\/[0-9]+ \[/ {
      if (match($0, /[0-9]+\/[0-9]+ \[/)) {
        seg = substr($0, RSTART, RLENGTH)
        split(seg, a, "/")
        split(a[2], b, " ")
        done = a[1]; total = b[1]
      }
      if (match($0, /[0-9.]+[a-zA-Z]*\/s/)) {
        rate = substr($0, RSTART, RLENGTH)
        sub(/[a-zA-Z]*\/s$/, "", rate)
      }
    }
    END { if (done != "") printf "%s %s %s\n", done, total, rate }
  '
}

# --- status file ------------------------------------------------------------

# seed_npz_write_status <status_file> <state> <rc> [k=v ...]
# Atomically writes the status file: the content goes to <status_file>.tmp
# first and is then moved into place with mv -f, so a reader never sees a
# half-written status file.
#
# Always written: STATE, RC and FINISHED_AT.  STARTED_AT is written when
# SEED_STARTED_AT is set.  Extra key=value pairs are appended verbatim.
seed_npz_write_status() {
  local status="$1" state="$2" rc="$3"
  shift 3 || true
  [ -n "$status" ] || return 1
  local dir tmp
  dir="$(dirname "$status")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="${status}.tmp"
  {
    printf 'STATE=%s\n' "$state"
    printf 'RC=%s\n' "$rc"
    if [ -n "${SEED_STARTED_AT:-}" ]; then
      printf 'STARTED_AT=%s\n' "$SEED_STARTED_AT"
    fi
    local kv
    for kv in "$@"; do
      [ -n "$kv" ] || continue
      printf '%s\n' "$kv"
    done
    printf 'FINISHED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv -f "$tmp" "$status"
}

# --- subset names -----------------------------------------------------------

# seed_npz_subset_names
# Prints the canonical subset chain (upstream SUBSET_HOURS), one per line.
seed_npz_subset_names() {
  printf '%s\n' tiny 1h 7h 40h all
}
