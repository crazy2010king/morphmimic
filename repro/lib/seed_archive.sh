#!/usr/bin/env bash
# repro/lib/seed_archive.sh — pure functions for inspecting / extracting the
# BONES-SEED tar archives.
#
# No network access here either: everything works on local files, so the
# whole archive contract (layout, entry counts, extraction flags, free space
# gate) is unit testable offline with synthetic tar files.
#
# usage: source repro/lib/seed_archive.sh

# --- archive facts ----------------------------------------------------------

# seed_archive_kind <file>
# Prints the clip kind carried by an archive: g1.tar.gz -> csv,
# soma_uniform.tar.gz -> bvh. Unknown archive -> rc 1.
seed_archive_kind() {
  case "$(basename "$1")" in
    g1.tar.gz) printf 'csv' ;;
    soma_uniform.tar.gz) printf 'bvh' ;;
    *) return 1 ;;
  esac
}

# seed_archive_prefix <file>
# Prints the expected relative path prefix inside the archive:
#   g1.tar.gz           -> g1/csv/
#   soma_uniform.tar.gz -> soma_uniform/bvh/
seed_archive_prefix() {
  case "$(basename "$1")" in
    g1.tar.gz) printf 'g1/csv/' ;;
    soma_uniform.tar.gz) printf 'soma_uniform/bvh/' ;;
    *) return 1 ;;
  esac
}

# seed_archive_expected_clips <file>
# Expected number of clips in each archive (metadata has 142,220 rows and
# each archive carries exactly one clip per row).
seed_archive_expected_clips() {
  case "$(basename "$1")" in
    g1.tar.gz) printf '142220' ;;
    soma_uniform.tar.gz) printf '142220' ;;
    *) return 1 ;;
  esac
}

# seed_archive_root <file>
# Prints the top level directory inside the archive (g1 / soma_uniform).
seed_archive_root() {
  case "$(basename "$1")" in
    g1.tar.gz) printf 'g1' ;;
    soma_uniform.tar.gz) printf 'soma_uniform' ;;
    *) return 1 ;;
  esac
}

# --- entry counting ---------------------------------------------------------

# seed_tar_list <archive.tar.gz>
# Writes the member list into a temporary file and returns tar's exit code.
# The list path is left in SEED_TAR_LIST (the caller removes it).
#
# Keeping the exit code matters: a truncated gzip must FAIL the counting
# instead of silently counting the members that could still be read.
SEED_TAR_LIST=""
seed_tar_list() {
  local archive="$1" tmp
  SEED_TAR_LIST=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/seed_tar_list.XXXXXX")" || return 2
  if tar -tzf "$archive" >"$tmp" 2>/dev/null; then
    SEED_TAR_LIST="$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# seed_tar_count <archive.tar.gz>
# Counts the entries of `tar -tzf`. Prints one line:
#   csv=<n> bvh=<n> total=<n> dirs=<n>
# The clip count (csv/bvh) is the assertion-relevant number; the total entry
# count is observational only (it also counts the directory entries).
# Also exports SEED_TAR_CSV / SEED_TAR_BVH / SEED_TAR_TOTAL / SEED_TAR_DIRS.
# Returns non-zero when the archive cannot be read (truncated gzip, ...).
seed_tar_count() {
  local archive="$1"
  local csv=0 bvh=0 total=0 dirs=0 entry
  if ! seed_tar_list "$archive"; then
    SEED_TAR_CSV=0
    SEED_TAR_BVH=0
    SEED_TAR_TOTAL=0
    SEED_TAR_DIRS=0
    printf 'csv=0 bvh=0 total=0 dirs=0\n'
    printf 'archive unreadable: %s\n' "$archive"
    return 1
  fi
  while IFS= read -r entry; do
    total=$((total + 1))
    case "$entry" in
      */) dirs=$((dirs + 1)) ;;
    esac
    case "$entry" in
      *.csv) csv=$((csv + 1)) ;;
      *.bvh) bvh=$((bvh + 1)) ;;
    esac
  done <"$SEED_TAR_LIST"
  rm -f "$SEED_TAR_LIST"
  SEED_TAR_LIST=""
  SEED_TAR_CSV="$csv"
  SEED_TAR_BVH="$bvh"
  SEED_TAR_TOTAL="$total"
  SEED_TAR_DIRS="$dirs"
  printf 'csv=%d bvh=%d total=%d dirs=%d\n' "$csv" "$bvh" "$total" "$dirs"
}

# --- layout -----------------------------------------------------------------

# seed_tar_layout_ok <archive.tar.gz>
# Succeeds (rc 0) when every member is a RELATIVE path with the expected
# shape:
#   g1/csv/<date>/<clip>.csv             (g1.tar.gz)
#   soma_uniform/bvh/<date>/<clip>.bvh   (soma_uniform.tar.gz)
# The archive root directory ("g1/" / "soma_uniform/") and the second level
# ("g1/csv/") are accepted as well. Absolute paths, paths containing a ".."
# component and members outside the expected shape are rejected (rc 1).
# The offending member is printed to stdout so the log keeps the evidence.
seed_tar_layout_ok() {
  local archive="$1" prefix root kind
  prefix="$(seed_archive_prefix "$archive")" || {
    printf 'unknown archive layout: %s\n' "$archive"
    return 1
  }
  root="$(seed_archive_root "$archive")" || {
    printf 'unknown archive layout: %s\n' "$archive"
    return 1
  }
  kind="$(seed_archive_kind "$archive")" || {
    printf 'unknown archive layout: %s\n' "$archive"
    return 1
  }
  if ! seed_tar_list "$archive"; then
    printf 'archive unreadable: %s\n' "$archive"
    return 1
  fi
  local entry bad=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    local stripped="${entry%/}"
    case "$stripped" in
      /*)
        bad="absolute path: $entry"; break ;;
    esac
    case "/$stripped/" in
      */../*)
        bad="parent traversal: $entry"; break ;;
    esac
    case "$stripped" in
      "$root"|"$root/$kind"|"$prefix"*) : ;;
      *)
        bad="unexpected prefix: $entry"; break ;;
    esac
  done <"$SEED_TAR_LIST"
  rm -f "$SEED_TAR_LIST"
  SEED_TAR_LIST=""
  if [ -n "$bad" ]; then
    printf 'layout violation: %s\n' "$bad"
    return 1
  fi
  return 0
}

# --- extraction -------------------------------------------------------------

# seed_extract_args <archive.tar.gz>
# Prints the extraction flags, one per line, and fills SEED_EXTRACT_ARGS.
#
# --no-same-owner is MANDATORY: the archives carry members owned by
# mpanek/root with 0770 directories, and the NFS export is root-squashed,
# so preserving ownership fails with "Cannot change ownership to uid 0".
# --same-owner and -p are therefore forbidden.
seed_extract_args() {
  local archive="$1"
  SEED_EXTRACT_ARGS=(
    -xzf
    "$archive"
    --no-same-owner
    --warning=no-unknown-keyword
  )
  printf '%s\n' "${SEED_EXTRACT_ARGS[@]}"
}

# --- disk space gate --------------------------------------------------------

# seed_free_gb <dir>
# Prints the free space of the filesystem holding <dir>, in whole GiB.
seed_free_gb() {
  local dir="$1"
  df -Pk "$dir" 2>/dev/null | awk 'NR==2 { printf "%d\n", $4 / 1024 / 1024 }'
}

# seed_min_free_gb
# Prints the configured minimum free space gate (GiB).
seed_min_free_gb() {
  printf '%s' "${SEED_MIN_FREE_GB:-400}"
}
