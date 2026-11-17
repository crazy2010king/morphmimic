#!/usr/bin/env bash
# repro/lib/coderead.sh — helpers for repro/06_code_read.sh.
#
# Split out of the script itself so that the module-discovery and the
# record-comparison logic can be unit tested (repro/tests/test_coderead.sh)
# without network, GPU, container or a real venv.
#
# The contract (R005 / R003):
#   * "the engineering read record" (docs/code_read/CODE_MAP.md) must cover
#     EVERY module of the repository, with a non-empty responsibility field —
#     a table of paths without responsibilities is worthless, so it fails;
#   * the coverage is asserted by a re-runnable gate, not by prose.
#
# Module discovery rules (the "coverage set"), as measured: 103 modules.
#   1. README.md                                       (1)
#   2. src/morphmimic/**/*.py  minus __init__.py      (53)
#   3. deploy/**/*.{py,sh,md}    minus __init__.py     (41)
#   4. tools/soma_retargeter/<top level>*.{py,sh}      (8)
# Excluded on purpose:
#   * __pycache__ and every __init__.py (namespace plumbing, no behaviour);
#   * data assets (*.json, XML, STL, ...) — they are data, not modules;
#   * third_party/** — vendored upstream code, listed as ONE section of the
#     record (with the pinned SHA and the verified/skipped verdict) instead
#     of 103+ rows of third-party files;
#   * repro/** (this script set) and logs/** (runtime artefacts).
#
# The record format: a markdown table whose FIRST cell is the module path
# (in backticks) and whose SECOND cell is the responsibility.  The table is
# delimited by the marker comments
#     <!-- CODE_READ_MODULE_TABLE_START -->
#     <!-- CODE_READ_MODULE_TABLE_END -->
# so that the other tables of the document (external dependencies, call
# chains, ...) can never be mistaken for module rows.  When the markers are
# absent the whole document is scanned (that fallback is what the unit tests
# exercise with their fixtures).
#
# The proxy is inlined into the sourcing process only (see repro/lib/common.sh).

# --- discovery -------------------------------------------------------------

# coderead_scan_modules <repo_root>
#
# Prints the normalised relative path of every module of the coverage set,
# one per line, sorted (LC_ALL=C, so the order is stable across machines).
# Paths are relative to <repo_root> and never carry a "./" prefix.
coderead_scan_modules() {
  local root="${1:-${REPO_ROOT:-.}}"
  [ -d "$root" ] || { echo "coderead_scan_modules: no such directory: $root" >&2; return 2; }

  local tmp
  tmp="$(mktemp)"
  # `find` on a missing directory must not abort the scan (set -e safe).
  {
    [ -f "$root/README.md" ] && printf 'README.md\n'
    if [ -d "$root/src/morphmimic" ]; then
      find "$root/src/morphmimic" -type f -name '*.py' \
        ! -name '__init__.py' ! -path '*/__pycache__/*' -print 2>/dev/null || true
    fi
    if [ -d "$root/deploy" ]; then
      find "$root/deploy" -type f \( -name '*.py' -o -name '*.sh' -o -name '*.md' \) \
        ! -name '__init__.py' ! -path '*/__pycache__/*' -print 2>/dev/null || true
    fi
    if [ -d "$root/tools/soma_retargeter" ]; then
      find "$root/tools/soma_retargeter" -maxdepth 1 -type f \
        \( -name '*.py' -o -name '*.sh' \) -print 2>/dev/null || true
    fi
  } | sed "s|^$root/||" | sed 's|^\./||' | grep -v '^$' | LC_ALL=C sort -u >"$tmp"

  cat "$tmp"
  rm -f "$tmp"
  return 0
}

# coderead_normalize_path <path>
#
# Normalises a path for the comparison: strips whitespace and backticks,
# removes a leading "./" and collapses duplicate slashes.  Empty output for
# an empty input.
coderead_normalize_path() {
  local p="${1:-}"
  p="${p#"${p%%[![:space:]]*}"}"   # ltrim
  p="${p%"${p##*[![:space:]]}"}"   # rtrim
  p="${p//\`/}"                    # backticks
  p="${p#./}"                      # leading ./
  while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done
  printf '%s' "$p"
}

# coderead_is_separator_row <line>
#
# True when <line> is a markdown table separator row ("|---|---|").
coderead_is_separator_row() {
  local line="${1:-}"
  local cell
  cell="${line#|}"
  cell="${cell%%|*}"
  cell="${cell// /}"
  [ -n "$cell" ] || return 1
  case "$cell" in
    *[!:-]*) return 1 ;;
  esac
  return 0
}

# coderead_parse_record <record_file>
#
# Prints one record entry per line: "<path>\t<duty>".  The duty is empty when
# the record row has no responsibility cell (or only a placeholder).
coderead_parse_record() {
  local record="${1:-}"
  [ -f "$record" ] || return 2

  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done <"$record"

  local in_table=0 saw_marker=0 cell path duty remainder next
  local i n start=-1 end=-1
  n=${#lines[@]}
  # When the document carries the marker comments, ONLY the rows between
  # them are record rows (the other tables of the document — the slice
  # mapping, the external dependencies, ... — are not module rows).
  for (( i = 0; i < n; i++ )); do
    case "${lines[i]}" in
      *CODE_READ_MODULE_TABLE_START*) start=$i; break ;;
    esac
  done
  if [ "$start" -ge 0 ]; then
    for (( i = start + 1; i < n; i++ )); do
      case "${lines[i]}" in
        *CODE_READ_MODULE_TABLE_END*) end=$i; break ;;
      esac
    done
    [ "$end" -lt 0 ] && end=$((n - 1))
  fi

  for (( i = 0; i < n; i++ )); do
    line="${lines[i]}"
    if [ "$start" -ge 0 ]; then
      # inside the marked region only
      if [ "$i" -le "$start" ] || [ "$i" -ge "$end" ]; then
        continue
      fi
    fi
    # only markdown table rows
    case "$line" in
      "|"*) ;;
      *) continue ;;
    esac
    # a row directly above a separator row is the table HEADER, not a record
    next=""
    if [ $((i + 1)) -lt "$n" ]; then
      next="${lines[i + 1]}"
    fi
    if [ -n "$next" ] && coderead_is_separator_row "$next"; then
      continue
    fi
    # split the row into cells
    cell="$line"
    cell="${cell#|}"
    path="${cell%%|*}"
    remainder="${cell#*|}"
    if [ "$remainder" = "$cell" ]; then
      duty=""
    else
      duty="${remainder%%|*}"
    fi
    path="$(coderead_normalize_path "$path")"
    [ -n "$path" ] || continue
    # separator row (|---|---|)
    case "$path" in
      -*|*:*) continue ;;
    esac
    duty="${duty#"${duty%%[![:space:]]*}"}"
    duty="${duty%"${duty##*[![:space:]]}"}"
    case "$duty" in
      "-"|"--"|"—"|"–"|"TBD"|"TODO"|"N/A"|"n/a"|"待填") duty="" ;;
    esac
    printf '%s\t%s\n' "$path" "$duty"
  done <"$record"
  return 0
}

# --- comparison ------------------------------------------------------------

# coderead_record_index <record_file> <index_file>
#
# Parses the record ONCE into "<path>\t<duty>" lines.  The comparison below
# needs one lookup per module; re-parsing the record for every module made
# the gate quadratic in the size of the record (103 modules x a 57 KB
# document re-read over NFS -> ~22 s).  The index is parsed once and then
# kept in memory, which makes the gate linear (seconds -> milliseconds).
coderead_record_index() {
  local record="${1:-}" index="${2:-}"
  if [ ! -f "$record" ]; then
    echo "ERROR: coderead_record_index: no such record file: $record" >&2
    return 2
  fi
  coderead_parse_record "$record" >"$index"
  return 0
}

# coderead_compare <modules_file> <record_file>
#
# Compares the discovered modules with the record and prints:
#   MODULES_TOTAL_<n>        modules discovered on disk
#   MODULES_RECORDED_<n>     of them covered by the record
#   MODULES_MISSING_<n>      of them NOT covered by the record (a failure)
#   MODULES_STALE_<n>        record entries without a module on disk (warning)
#   MODULES_EMPTY_DUTY_<n>   covered modules without a responsibility (failure)
# plus one line per problem:
#   MISSING <path> / STALE <path> / EMPTY_DUTY <path>
#
# Returns 0 only when nothing is missing and no responsibility is empty.
# A stale entry is a warning, never a failure.
coderead_compare() {
  local modules_file="${1:-}" record_file="${2:-}"
  if [ ! -f "$modules_file" ]; then
    echo "ERROR: coderead_compare: no such modules file: $modules_file" >&2
    return 2
  fi
  if [ ! -f "$record_file" ]; then
    echo "ERROR: coderead_compare: no such record file: $record_file" >&2
    return 2
  fi

  local index
  index="$(mktemp "${TMPDIR:-/tmp}/coderead_index.XXXXXX")"
  coderead_record_index "$record_file" "$index" || { rm -f "$index"; return 2; }

  # the record, parsed once
  local -A duty_of=()
  local path duty
  while IFS=$'\t' read -r path duty || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    # the first entry wins (same order semantics as coderead_record_lookup)
    if [ -z "${duty_of["$path"]+x}" ]; then
      duty_of["$path"]="$duty"
    fi
  done <"$index"

  # the modules on disk, normalised
  local -A module_set=()
  local mod
  while IFS= read -r mod || [ -n "$mod" ]; do
    mod="$(coderead_normalize_path "$mod")"
    [ -n "$mod" ] || continue
    module_set["$mod"]=1
  done <"$modules_file"

  local total=0 recorded=0 missing=0 stale=0 empty_duty=0
  while IFS= read -r mod || [ -n "$mod" ]; do
    mod="$(coderead_normalize_path "$mod")"
    [ -n "$mod" ] || continue
    total=$((total + 1))
    if [ -n "${duty_of["$mod"]+x}" ]; then
      recorded=$((recorded + 1))
      duty="${duty_of["$mod"]}"
      if [ -z "$duty" ]; then
        empty_duty=$((empty_duty + 1))
        echo "EMPTY_DUTY $mod"
      fi
    else
      missing=$((missing + 1))
      echo "MISSING $mod"
    fi
  done <"$modules_file"

  # stale: recorded entries that are not on disk any more
  for path in "${!duty_of[@]}"; do
    [ -n "$path" ] || continue
    if [ -z "${module_set["$path"]+x}" ]; then
      stale=$((stale + 1))
      echo "STALE $path"
    fi
  done

  rm -f "$index"

  echo "MODULES_TOTAL_$total"
  echo "MODULES_RECORDED_$recorded"
  echo "MODULES_MISSING_$missing"
  echo "MODULES_STALE_$stale"
  echo "MODULES_EMPTY_DUTY_$empty_duty"

  if [ "$missing" -ne 0 ] || [ "$empty_duty" -ne 0 ]; then
    return 1
  fi
  return 0
}

# coderead_record_lookup <record_file> <module path>
#
# Prints the responsibility of <module path> when the record covers it,
# returns 0.  Returns 1 when the record does not cover it.
coderead_record_lookup() {
  local record="${1:-}" want
  want="$(coderead_normalize_path "${2:-}")"
  local path duty
  while IFS=$'\t' read -r path duty || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if [ "$path" = "$want" ]; then
      printf '%s' "$duty"
      return 0
    fi
  done < <(coderead_parse_record "$record")
  return 1
}
