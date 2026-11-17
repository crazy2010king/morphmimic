#!/usr/bin/env bash
# repro/lib/seed_download.sh — pure functions for the BONES-SEED downloader.
#
# This library contains NO network access: it only *describes* the download.
# The actual transfer lives in repro/08_seed_download.sh + its worker (T2),
# which call the functions below. Keeping the description here means the whole
# download contract (expected file table, token resolution, transfer flags,
# backoff, status file, progress/ETA) can be unit tested offline.
#
# Dataset facts (measured 2026-11-10 in the ros_dev container, HF API):
#   repo     bones-studio/seed   (gated=auto, private=false)
#   revision 2f59b2077b9da34dd4e43618e705c7cb962c9a66
#   sha256   == the HF API `lfs.oid` field (NOT `xetHash`, which is a
#             different Merkle root and must never be used as a sha256).
#
# usage: source repro/lib/seed_download.sh

# --- constants -------------------------------------------------------------

SEED_HF_REPO="bones-studio/seed"
SEED_HF_REVISION="2f59b2077b9da34dd4e43618e705c7cb962c9a66"
SEED_HF_BASE_URL="https://huggingface.co/datasets/bones-studio/seed/resolve/main"

# Total bytes of the two tar archives (g1 + soma_uniform).
# NOTE: the slice plan quotes "68688061944 B for the three files", but that
# number is the sum of the TWO archives only (23499973647 + 45188088297).
# The real three-file total (metadata included) is 68834473552 B — see
# SEED_TOTAL_BYTES_ALL. The plan's marker contract (`bytes=68688061944`)
# is kept as-is for the two archives.
SEED_TOTAL_BYTES=68688061944
# Total bytes of all three downloaded files (metadata + both archives).
SEED_TOTAL_BYTES_ALL=68834473552

# --- expected file table ----------------------------------------------------

# seed_expected_files
# Prints three TSV lines: name <TAB> size <TAB> sha256 <TAB> remote_path <TAB> dest_relpath
seed_expected_files() {
  local base="$SEED_HF_BASE_URL"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "metadata/seed_metadata_v004.csv" \
    "146411608" \
    "71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39" \
    "$base/metadata/seed_metadata_v004.csv" \
    "data/seed/metadata/seed_metadata_v004.csv"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "g1.tar.gz" \
    "23499973647" \
    "52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a" \
    "$base/g1.tar.gz" \
    "data/seed/_archives/g1.tar.gz"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "soma_uniform.tar.gz" \
    "45188088297" \
    "0c1fd91628d2644d0d7c0b735ae64faa5fa79834280bc1ce7860a871e55f912c" \
    "$base/soma_uniform.tar.gz" \
    "data/seed/_archives/soma_uniform.tar.gz"
}

# seed_expected_file <name>
# Prints the TSV line for one file (empty output + rc 1 when unknown).
seed_expected_file() {
  local want="$1" line
  while IFS=$'\t' read -r name size sha url dest; do
    [ -n "$name" ] || continue
    if [ "$name" = "$want" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$size" "$sha" "$url" "$dest"
      return 0
    fi
  done < <(seed_expected_files)
  return 1
}

# seed_remote_path <file>
# Prints the resolve URL for a repository-relative file path.
seed_remote_path() {
  printf '%s/%s\n' "$SEED_HF_BASE_URL" "$1"
}

# seed_file_plan_line <file>
# Prints the greppable plan marker for one file:
#   SEED_FILE_PLAN file=<name> size=<bytes> sha256=<sha256>
seed_file_plan_line() {
  local name="$1" line
  line="$(seed_expected_file "$name")" || return 1
  IFS=$'\t' read -r _n size sha _u _d <<<"$line"
  printf 'SEED_FILE_PLAN file=%s size=%s sha256=%s\n' "$1" "$size" "$sha"
}

# --- authentication ---------------------------------------------------------

# seed_resolve_token
# Returns the HuggingFace token on stdout (and ONLY the token — never a
# diagnostic line, never the token file path). Resolution order:
#   1. $HF_TOKEN
#   2. contents of ${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}
# Returns an empty string when no token is available.
# The caller owns the secrecy of the value: it must write it into a 0600
# header file, pass it via the `-H @file` option and delete it with a trap.
seed_resolve_token() {
  if [ -n "${HF_TOKEN:-}" ]; then
    printf '%s' "$HF_TOKEN"
    return 0
  fi
  local path="${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}"
  [ -f "$path" ] || return 0
  # Strip trailing newlines only; the token itself must stay verbatim.
  local content
  content="$(cat "$path" 2>/dev/null || true)"
  content="${content%$'\n'}"
  content="${content%$'\n'}"
  printf '%s' "$content"
}

# --- transfer description ---------------------------------------------------

# seed_curl_args <dest> <url> [header_file]
# Fills the global array SEED_CURL_ARGS with the transfer flags and echoes
# them one per line. The transfer writes to "<dest>.part" so that an
# interrupted transfer can be resumed from the existing bytes.
#
# Flags (measured need):
#   -L                      follow the 302 redirect to the CDN
#   -C -                    resume from the current size of the .part file
#   --connect-timeout 20    the proxy sometimes drops the connect
#   --speed-limit 32768     abort when slower than 32 KiB/s ...
#   --speed-time 300        ... for 300 s (the proxy silently hangs)
#   --retry 0               retries are handled by the worker (backoff),
#                           the transfer must fail fast instead
#   -H @<file>              token header read from a 0600 file
seed_curl_args() {
  local dest="$1" url="$2" hdr="${3:-}"
  SEED_CURL_ARGS=(
    -L
    -C
    -
    --connect-timeout
    "20"
    --speed-limit
    "32768"
    --speed-time
    "300"
    --retry
    "0"
  )
  if [ -n "$hdr" ]; then
    SEED_CURL_ARGS+=(-H "@$hdr")
  fi
  SEED_CURL_ARGS+=(-o "${dest}.part" "$url")
  printf '%s\n' "${SEED_CURL_ARGS[@]}"
}

# --- retry backoff ----------------------------------------------------------

# seed_backoff_delay <attempt>
# Exponential backoff base sequence 30 / 60 / 120 / 240 / 300 seconds
# (300 s is the cap), plus +/- 20 % jitter. Attempt >= 5 always uses the cap.
# Prints the delay in whole seconds.
seed_backoff_delay() {
  local attempt="${1:-1}"
  case "$attempt" in
    ''|*[!0-9]*) attempt=1 ;;
  esac
  [ "$attempt" -ge 1 ] || attempt=1
  local base
  if [ "$attempt" -ge 5 ]; then
    base=300
  else
    case "$attempt" in
      1) base=30 ;;
      2) base=60 ;;
      3) base=120 ;;
      4) base=240 ;;
      *) base=300 ;;
    esac
  fi
  # jitter factor in [-20, +20] percent
  local pct=$((RANDOM % 41 - 20))
  local delay=$((base + base * pct / 100))
  [ "$delay" -ge 1 ] || delay=1
  printf '%d' "$delay"
}

# --- status file ------------------------------------------------------------

# seed_status_write <statusfile> [KEY=VALUE ...]
# Writes the download status file atomically (temp file + rename), so a
# concurrent reader never observes a half-written state.
# Contract keys: STATE FILE BYTES TOTAL PCT RATE_BPS ETA_SECONDS ATTEMPT RC
#                STARTED_AT
seed_status_write() {
  local file="$1"; shift || true
  local dir
  dir="$(dirname "$file")"
  [ -d "$dir" ] || mkdir -p "$dir"
  local tmp="${file}.tmp.$$"
  : >"$tmp"
  local kv key value
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  done
  mv -f "$tmp" "$file"
}

# seed_status_read <statusfile>
# Prints the status file as KEY=VALUE lines (empty output when absent).
seed_status_read() {
  local file="$1"
  [ -f "$file" ] || return 0
  cat "$file"
}

# seed_status_get <statusfile> <key>
# Prints the value of one key (empty when absent).
seed_status_get() {
  local file="$1" key="$2" line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s' "${line#*=}" ; return 0 ;;
    esac
  done < <(seed_status_read "$file")
  return 0
}

# --- progress / ETA ---------------------------------------------------------

# seed_progress <bytes> <total> <elapsed_s>
# Prints one line: PCT=<0..100, one decimal> RATE_BPS=<int> ETA_SECONDS=<int>
# Also exports SEED_PCT / SEED_RATE_BPS / SEED_ETA_SECONDS.
# A zero total means "size unknown" -> PCT=0.0 RATE_BPS=0 ETA_SECONDS=0.
seed_progress() {
  local bytes="${1:-0}" total="${2:-0}" elapsed="${3:-0}"
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$elapsed" in ''|*[!0-9]*) elapsed=0 ;; esac

  local pct="0.0" rate=0 eta=0
  if [ "$total" -gt 0 ]; then
    pct="$(awk -v b="$bytes" -v t="$total" 'BEGIN { p = (b * 100.0) / t; if (p < 0) p = 0; if (p > 100) p = 100; printf "%.1f", p }')"
    if [ "$elapsed" -gt 0 ]; then
      rate=$((bytes / elapsed))
    else
      rate=0
    fi
  else
    # unknown total -> no percentage, no rate, no ETA
    rate=0
  fi
  if [ "$total" -gt 0 ] && [ "$rate" -gt 0 ]; then
    eta=$(( (total - bytes) / rate ))
    [ "$eta" -ge 0 ] || eta=0
  else
    eta=0
  fi
  SEED_PCT="$pct"
  SEED_RATE_BPS="$rate"
  SEED_ETA_SECONDS="$eta"
  printf 'PCT=%s RATE_BPS=%d ETA_SECONDS=%d\n' "$pct" "$rate" "$eta"
}

# --- markers ----------------------------------------------------------------

# seed_marker <NAME> [k=v ...]
# Prints exactly one line: "<NAME> k=v k=v". The caller passes the full
# marker name (including the SEED_ prefix) so that a single grep -F finds
# the marker family in the logs.
seed_marker() {
  local name="${1:-}"
  shift || true
  local line="$name"
  local kv
  for kv in "$@"; do
    line="$line $kv"
  done
  printf '%s\n' "$line"
}
