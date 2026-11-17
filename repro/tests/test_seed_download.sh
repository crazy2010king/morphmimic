#!/usr/bin/env bash
# repro/tests/test_seed_download.sh — offline unit tests for
# repro/lib/seed_download.sh (the pure-function side of the BONES-SEED
# downloader).
#
# No network access: the library only *describes* the transfer.
#
# Covered:
#   1. the expected file table (name / size / sha256) is exactly the measured one
#   2. resolve URLs and the SEED_FILE_PLAN marker
#   3. token resolution order (env wins over file, missing file -> empty,
#      the function never leaks anything but the token itself)
#   4. the transfer flags (resumable, stall watchdog, no curl-internal retry)
#   5. the backoff sequence 30/60/120/240/300 s with +/-20 % jitter
#   6. atomic status file write + read back of every contract key
#   7. progress / rate / ETA boundaries
#   8. the marker helper prints exactly one greppable line
#   9. the library contains no network invocation at all
#
# Run locally:  bash repro/tests/test_seed_download.sh
# Run remotely: bash repro/lib/remote.sh tests/test_seed_download.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=repro/lib/seed_download.sh
source "$LIB_DIR/seed_download.sh"
# common.sh turns on `errexit`; these tests drive commands that are EXPECTED
# to fail, so switch it back off.
set +e

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. expected file table -------------------------------------------------
expected_table=$(cat <<'EOF'
metadata/seed_metadata_v004.csv	146411608	71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39
g1.tar.gz	23499973647	52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a
soma_uniform.tar.gz	45188088297	0c1fd91628d2644d0d7c0b735ae64faa5fa79834280bc1ce7860a871e55f912c
EOF
)
actual_table="$(seed_expected_files | cut -f1,2,3)"
if [ "$actual_table" = "$expected_table" ]; then
  ok "expected file table matches the measured name/size/sha256 values"
else
  bad "expected file table mismatch"
  printf '      expected:\n%s\n      actual:\n%s\n' "$expected_table" "$actual_table"
fi

n_files="$(seed_expected_files | wc -l)"
if [ "$n_files" -eq 3 ]; then
  ok "expected file table has exactly 3 rows"
else
  bad "expected file table has $n_files rows, expected 3"
fi

# remote paths
url="$(seed_remote_path g1.tar.gz)"
if [ "$url" = "https://huggingface.co/datasets/bones-studio/seed/resolve/main/g1.tar.gz" ]; then
  ok "seed_remote_path builds the resolve URL"
else
  bad "seed_remote_path produced: $url"
fi

url_meta="$(seed_remote_path metadata/seed_metadata_v004.csv)"
if [ "$url_meta" = "https://huggingface.co/datasets/bones-studio/seed/resolve/main/metadata/seed_metadata_v004.csv" ]; then
  ok "seed_remote_path handles the metadata path"
else
  bad "seed_remote_path produced: $url_meta"
fi

# total byte sums: the two archives and all three files
archives_sum=0
all_sum=0
while IFS=$'\t' read -r _n size _s _u _d; do
  all_sum=$((all_sum + size))
  case "$_n" in
    *.tar.gz) archives_sum=$((archives_sum + size)) ;;
  esac
done < <(seed_expected_files)
if [ "$archives_sum" -eq 68688061944 ]; then
  ok "the two archive sizes sum to 68688061944 bytes (the plan's marker value)"
else
  bad "the two archive sizes sum to $archives_sum, expected 68688061944"
fi
if [ "$all_sum" -eq 68834473552 ]; then
  ok "all three file sizes sum to 68834473552 bytes (metadata included)"
else
  bad "all three file sizes sum to $all_sum, expected 68834473552"
fi
if [ "$SEED_TOTAL_BYTES" -eq 68688061944 ] && [ "$SEED_TOTAL_BYTES_ALL" -eq 68834473552 ]; then
  ok "the exported total byte constants match the file table"
else
  bad "SEED_TOTAL_BYTES=$SEED_TOTAL_BYTES / SEED_TOTAL_BYTES_ALL=$SEED_TOTAL_BYTES_ALL"
fi

# --- 2. plan marker ---------------------------------------------------------
plan="$(seed_file_plan_line g1.tar.gz)"
if [ "$plan" = "SEED_FILE_PLAN file=g1.tar.gz size=23499973647 sha256=52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a" ]; then
  ok "seed_file_plan_line emits the exact greppable plan marker"
else
  bad "seed_file_plan_line emitted: $plan"
fi

rc=0
seed_file_plan_line nonexistent.tar.gz >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "seed_file_plan_line fails for an unknown file (rc=$rc)"
else
  bad "seed_file_plan_line should fail for an unknown file"
fi

# --- 3. token resolution ----------------------------------------------------
TOKEN_FILE="$TMP/token"
printf 'hf_secret_value\n' >"$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

saved_hf_token="${HF_TOKEN:-}"
unset HF_TOKEN

got="$(HF_TOKEN_PATH="$TOKEN_FILE" seed_resolve_token)"
if [ "$got" = "hf_secret_value" ]; then
  ok "seed_resolve_token reads the token file when HF_TOKEN is unset"
else
  bad "seed_resolve_token returned '$got' instead of the file content"
fi

got_env="$(HF_TOKEN=env_wins HF_TOKEN_PATH="$TOKEN_FILE" seed_resolve_token)"
if [ "$got_env" = "env_wins" ]; then
  ok "HF_TOKEN takes precedence over the token file"
else
  bad "HF_TOKEN did not take precedence (got '$got_env')"
fi

got_missing="$(HF_TOKEN_PATH="$TMP/does_not_exist" seed_resolve_token)"
if [ -z "$got_missing" ]; then
  ok "seed_resolve_token returns empty when no token file exists"
else
  bad "seed_resolve_token returned '$got_missing' for a missing token file"
fi

# the output must be the token and nothing else (no path, no diagnostics)
if printf '%s' "$got" | grep -qF "$TOKEN_FILE"; then
  bad "seed_resolve_token leaked the token file path"
else
  ok "seed_resolve_token does not leak the token file path"
fi
lines="$(HF_TOKEN_PATH="$TOKEN_FILE" seed_resolve_token | wc -l)"
if [ "$lines" -le 1 ]; then
  ok "seed_resolve_token prints the token on a single line (no diagnostics)"
else
  bad "seed_resolve_token printed $lines lines, expected 1"
fi

if [ -n "$saved_hf_token" ]; then
  export HF_TOKEN="$saved_hf_token"
fi

# --- 4. transfer flags ------------------------------------------------------
seed_curl_args "$TMP/g1.tar.gz" "https://example.invalid/g1.tar.gz" "$TMP/hdr" >/dev/null
args="${SEED_CURL_ARGS[*]}"
need_args=(-L -C - --connect-timeout 20 --speed-limit 32768 --speed-time 300 --retry 0)
missing=""
for a in "${need_args[@]}"; do
  case " $args " in
    *" $a "*) : ;;
    *) missing="$missing $a" ;;
  esac
done
if [ -z "$missing" ]; then
  ok "seed_curl_args carries every mandatory transfer flag"
else
  bad "seed_curl_args is missing:$missing (got: $args)"
fi
case " $args " in
  *"-o $TMP/g1.tar.gz.part"*) ok "seed_curl_args writes to <dest>.part (resumable)" ;;
  *) bad "seed_curl_args does not write to <dest>.part (got: $args)" ;;
esac
case " $args " in
  *"-H @$TMP/hdr"*) ok "seed_curl_args reads the token from the header file" ;;
  *) bad "seed_curl_args does not use the header file (got: $args)" ;;
esac
case " $args " in
  *"https://example.invalid/g1.tar.gz"*) ok "seed_curl_args carries the URL last" ;;
  *) bad "seed_curl_args does not carry the URL (got: $args)" ;;
esac

# --- 5. backoff -------------------------------------------------------------
check_range() {
  local attempt="$1" lo="$2" hi="$3" i d bad_count=0
  for i in $(seq 1 40); do
    d="$(seed_backoff_delay "$attempt")"
    if [ "$d" -lt "$lo" ] || [ "$d" -gt "$hi" ]; then
      bad_count=$((bad_count + 1))
    fi
  done
  if [ "$bad_count" -eq 0 ]; then
    ok "backoff attempt $attempt stays in [$lo,$hi] over 40 samples"
  else
    bad "backoff attempt $attempt left [$lo,$hi] in $bad_count/40 samples"
  fi
}
check_range 1 24 36
check_range 2 48 72
check_range 3 96 144
check_range 4 192 288
check_range 5 240 360
check_range 9 240 360

d="$(seed_backoff_delay 0)"
if [ "$d" -ge 24 ] && [ "$d" -le 36 ]; then
  ok "backoff attempt 0 is clamped to the first step ($d s)"
else
  bad "backoff attempt 0 produced $d s"
fi

d="$(seed_backoff_delay notanumber)"
if [ "$d" -ge 24 ] && [ "$d" -le 36 ]; then
  ok "backoff with a non-numeric attempt falls back to the first step ($d s)"
else
  bad "backoff with a non-numeric attempt produced $d s"
fi

# --- 6. status file ---------------------------------------------------------
STATUS="$TMP/status/08_seed_download.status"
seed_status_write "$STATUS" \
  "STATE=RUNNING" "FILE=g1.tar.gz" "BYTES=123456" "TOTAL=23499973647" \
  "PCT=0.5" "RATE_BPS=712345" "ETA_SECONDS=32973" "ATTEMPT=3" "RC=0" \
  "STARTED_AT=2026-11-10T00:00:00Z"
if [ -f "$STATUS" ]; then
  ok "seed_status_write created the status file"
else
  bad "seed_status_write did not create the status file"
fi
leftovers="$(find "$(dirname "$STATUS")" -name '*.tmp.*' | wc -l)"
if [ "$leftovers" -eq 0 ]; then
  ok "seed_status_write left no temporary file behind (atomic rename)"
else
  bad "seed_status_write left $leftovers temporary files behind"
fi

missing_keys=""
for k in STATE FILE BYTES TOTAL PCT RATE_BPS ETA_SECONDS ATTEMPT RC STARTED_AT; do
  v="$(seed_status_get "$STATUS" "$k")"
  [ -n "$v" ] || missing_keys="$missing_keys $k"
done
if [ -z "$missing_keys" ]; then
  ok "every status contract key can be read back"
else
  bad "status keys missing after write/read:$missing_keys"
fi
v="$(seed_status_get "$STATUS" TOTAL)"
if [ "$v" = "23499973647" ]; then
  ok "seed_status_get returns the written value"
else
  bad "seed_status_get returned '$v' for TOTAL"
fi
read_lines="$(seed_status_read "$STATUS" | wc -l)"
if [ "$read_lines" -eq 10 ]; then
  ok "seed_status_read prints all 10 key/value lines"
else
  bad "seed_status_read printed $read_lines lines, expected 10"
fi
seed_status_write "$STATUS" "STATE=DONE" "FILE=g1.tar.gz"
v="$(seed_status_get "$STATUS" STATE)"
if [ "$v" = "DONE" ]; then
  ok "seed_status_write overwrites the previous state atomically"
else
  bad "seed_status_write did not overwrite the state (got '$v')"
fi

# --- 7. progress / rate / ETA ----------------------------------------------
out="$(seed_progress 0 100 10)"
pct="$(printf '%s' "$out" | sed -n 's/.*PCT=\([0-9.]*\).*/\1/p')"
rate="$(printf '%s' "$out" | sed -n 's/.*RATE_BPS=\([0-9]*\).*/\1/p')"
eta="$(printf '%s' "$out" | sed -n 's/.*ETA_SECONDS=\([0-9]*\).*/\1/p')"
if [ "$pct" = "0.0" ] && [ "$rate" = "0" ] && [ "$eta" = "0" ]; then
  ok "seed_progress with 0 bytes reports 0.0/0/0"
else
  bad "seed_progress with 0 bytes reported: $out"
fi

out="$(seed_progress 12345 0 10)"
pct="$(printf '%s' "$out" | sed -n 's/.*PCT=\([0-9.]*\).*/\1/p')"
rate="$(printf '%s' "$out" | sed -n 's/.*RATE_BPS=\([0-9]*\).*/\1/p')"
eta="$(printf '%s' "$out" | sed -n 's/.*ETA_SECONDS=\([0-9]*\).*/\1/p')"
if [ "$pct" = "0.0" ] && [ "$rate" = "0" ] && [ "$eta" = "0" ]; then
  ok "seed_progress with an unknown total reports 0.0/0/0"
else
  bad "seed_progress with an unknown total reported: $out"
fi

out="$(seed_progress 50 100 10)"
pct="$(printf '%s' "$out" | sed -n 's/.*PCT=\([0-9.]*\).*/\1/p')"
rate="$(printf '%s' "$out" | sed -n 's/.*RATE_BPS=\([0-9]*\).*/\1/p')"
eta="$(printf '%s' "$out" | sed -n 's/.*ETA_SECONDS=\([0-9]*\).*/\1/p')"
if [ "$pct" = "50.0" ] && [ "$rate" = "5" ] && [ "$eta" = "10" ]; then
  ok "seed_progress computes pct/rate/eta for a normal mid-transfer value"
else
  bad "seed_progress computed: $out (expected PCT=50.0 RATE_BPS=5 ETA_SECONDS=10)"
fi

out="$(seed_progress 200 100 10)"
pct="$(printf '%s' "$out" | sed -n 's/.*PCT=\([0-9.]*\).*/\1/p')"
if [ "$pct" = "100.0" ]; then
  ok "seed_progress clamps the percentage at 100.0"
else
  bad "seed_progress reported PCT=$pct for an over-complete transfer"
fi

# --- 8. marker helper -------------------------------------------------------
m="$(seed_marker SEED_DL_FILE_OK file=g1.tar.gz bytes=42 sha256=abc)"
if [ "$m" = "SEED_DL_FILE_OK file=g1.tar.gz bytes=42 sha256=abc" ]; then
  ok "seed_marker prints one greppable marker line"
else
  bad "seed_marker printed: $m"
fi
if printf '%s' "$m" | grep -qF "SEED_DL_FILE_OK"; then
  ok "the marker is findable with grep -F"
else
  bad "the marker is not findable with grep -F"
fi

# --- 9. the library must not touch the network ------------------------------
net_hits="$(grep -nE 'curl[[:space:]]|requests|urllib\.request\.urlopen|wget[[:space:]]|http\.client' \
  "$LIB_DIR/seed_download.sh" | grep -v '^\s*#' || true)"
if [ -z "$net_hits" ]; then
  ok "seed_download.sh contains no network invocation"
else
  bad "seed_download.sh contains a network invocation: $net_hits"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo "SEED_TESTS_FAILED"
  exit 1
fi
echo "SEED_TESTS_OK"
exit 0
