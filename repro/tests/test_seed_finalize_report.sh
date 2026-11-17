#!/usr/bin/env bash
# repro/tests/test_seed_finalize_report.sh — offline fixture battery for
# repro/12_seed_finalize_report.sh (the read-only terminal report).
#
# No network, no real archives: the download/finalize status files and the
# finalize log are fixtures, and SHA256SUMS is a two-line stub.  The battery
# covers:
#
#   1. happy path            -> exit 0, SEED_REPORT_OK, all six markers echoed
#                               verbatim, the key=value numbers present
#   2. a missing marker      -> exit 1, SEED_REPORT_FAIL, the missing marker
#                               is NAMED, and NO SEED_REPORT_OK is printed
#   3. download not DONE     -> exit 1 (the report must not claim a terminal
#                               state while the download is still running)
#   4. finalize not DONE     -> exit 1
#   5. SHA256SUMS missing    -> exit 1
#   6. finalize log missing  -> exit 1
#   7. `check` subcommand    -> prints the verdict only, no key=value dump
#
# Run locally:   bash repro/tests/test_seed_finalize_report.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_seed_finalize_report.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/repro/12_seed_finalize_report.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CASE=""

# make_case <name> — build an isolated fixture case dir in $CASE.
#
# Layout:
#   <case>/logs/08_seed_download.status
#   <case>/logs/11_seed_finalize.status
#   <case>/logs/11_seed_finalize.txt
#   <case>/archives/SHA256SUMS
make_case() {
  local name="$1"
  CASE="$TMP/$name"
  mkdir -p "$CASE/logs" "$CASE/archives"

  printf 'STATE=DONE\nBYTES=23499973647\nTOTAL=23499973647\n' \
    >"$CASE/logs/08_seed_download.status"
  printf 'STATE=DONE\nRC=0\nPHASE=\n' >"$CASE/logs/11_seed_finalize.status"
  cat >"$CASE/logs/11_seed_finalize.txt" <<'LOG'
SEED_FINALIZE_START phase=verify
SEED_VERIFY_OK
SEED_TAR_CLIPS file=g1 kind=csv count=142220
SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220
SEED_FINALIZE_START phase=extract
SEED_EXTRACT_FILES file=g1 count=142220
SEED_EXTRACT_FILES file=soma_uniform count=142220
SEED_META_MATCH matched=142220 missing=0 extra=0
SEED_EXTRACT_OK files=284440
SEED_FINALIZE_OK files=3
LOG
  printf 'aaa  g1.tar.gz\nbbb  soma_uniform.tar.gz\nccc  seed_metadata_v004.csv\n' \
    >"$CASE/archives/SHA256SUMS"
}

# run_report <args...> — run the script under test against the current case.
# The output goes to $CASE/out, the exit code to $CASE/rc.
run_report() {
  ( cd "$REPO_ROOT" && SEED_REPORT_LOG_DIR="$CASE/logs" \
      SEED_REPORT_SHA256SUMS="$CASE/archives/SHA256SUMS" \
      bash "$SCRIPT" "$@" ) >"$CASE/out" 2>&1
  echo $? >"$CASE/rc"
}

# --- CASE 1: happy path -----------------------------------------------------
make_case happy
run_report
rc="$(cat "$CASE/rc")"
if [ "$rc" = "0" ]; then ok "happy path: exit 0"; else bad "happy path: exit $rc"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then ok "happy path: SEED_REPORT_OK printed"; else bad "happy path: SEED_REPORT_OK missing"; fi
if grep -qF "SEED_REPORT_FAIL" "$CASE/out"; then bad "happy path: unexpected SEED_REPORT_FAIL"; else ok "happy path: no SEED_REPORT_FAIL"; fi
missing_marker=""
for m in "SEED_VERIFY_OK" \
         "SEED_TAR_CLIPS file=g1 kind=csv count=142220" \
         "SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220" \
         "SEED_META_MATCH matched=142220 missing=0 extra=0" \
         "SEED_EXTRACT_OK files=284440" \
         "SEED_FINALIZE_OK files=3"; do
  grep -qF "$m" "$CASE/out" || missing_marker="$missing_marker|$m"
done
if [ -z "$missing_marker" ]; then
  ok "happy path: all six markers echoed verbatim"
else
  bad "happy path: markers not echoed:$missing_marker"
fi
if grep -qF "SEED_REPORT_META_MATCHED=142220" "$CASE/out" \
   && grep -qF "SEED_REPORT_EXTRACTED_FILES=284440" "$CASE/out" \
   && grep -qF "SEED_REPORT_ARCHIVE_FILES=3" "$CASE/out" \
   && grep -qF "SEED_REPORT_SHA256SUMS_LINES=3" "$CASE/out"; then
  ok "happy path: key=value numbers present"
else
  bad "happy path: key=value numbers incomplete"
fi

# --- CASE 2: a missing marker ----------------------------------------------
make_case missing_marker
grep -v "SEED_META_MATCH matched=142220 missing=0 extra=0" \
  "$CASE/logs/11_seed_finalize.txt" >"$CASE/logs/11.tmp" \
  && mv "$CASE/logs/11.tmp" "$CASE/logs/11_seed_finalize.txt"
run_report
rc="$(cat "$CASE/rc")"
if [ "$rc" != "0" ]; then ok "missing marker: exit non-zero"; else bad "missing marker: exit 0"; fi
if grep -qF "SEED_REPORT_FAIL" "$CASE/out"; then ok "missing marker: SEED_REPORT_FAIL printed"; else bad "missing marker: SEED_REPORT_FAIL missing"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then bad "missing marker: SEED_REPORT_OK must NOT be printed"; else ok "missing marker: no SEED_REPORT_OK"; fi
if grep -qF "MISSING: marker 'SEED_META_MATCH matched=142220 missing=0 extra=0'" "$CASE/out"; then
  ok "missing marker: the missing marker is named"
else
  bad "missing marker: the missing marker is not named"
fi
# the marker must not be echoed as an achieved fact
if grep -qE "^SEED_META_MATCH matched=142220" "$CASE/out"; then
  bad "missing marker: the marker must not be echoed as achieved"
else
  ok "missing marker: the marker is not echoed as achieved"
fi

# --- CASE 3: download not DONE ---------------------------------------------
make_case download_running
printf 'STATE=DOWNLOADING\n' >"$CASE/logs/08_seed_download.status"
run_report
rc="$(cat "$CASE/rc")"
if [ "$rc" != "0" ]; then ok "download running: exit non-zero"; else bad "download running: exit 0"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then bad "download running: SEED_REPORT_OK must NOT be printed"; else ok "download running: no SEED_REPORT_OK"; fi

# --- CASE 4: finalize not DONE ---------------------------------------------
make_case finalize_running
printf 'STATE=RUNNING\nPHASE=download\n' >"$CASE/logs/11_seed_finalize.status"
run_report
rc="$(cat "$CASE/rc")"
if [ "$rc" != "0" ]; then ok "finalize running: exit non-zero"; else bad "finalize running: exit 0"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then bad "finalize running: SEED_REPORT_OK must NOT be printed"; else ok "finalize running: no SEED_REPORT_OK"; fi

# --- CASE 5: SHA256SUMS missing --------------------------------------------
make_case no_sums
rm -f "$CASE/archives/SHA256SUMS"
run_report
rc="$(cat "$CASE/rc")"
if [ "$rc" != "0" ]; then ok "no SHA256SUMS: exit non-zero"; else bad "no SHA256SUMS: exit 0"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then bad "no SHA256SUMS: SEED_REPORT_OK must NOT be printed"; else ok "no SHA256SUMS: no SEED_REPORT_OK"; fi

# --- CASE 6: finalize log missing ------------------------------------------
make_case no_log
rm -f "$CASE/logs/11_seed_finalize.txt"
run_report
rc="$(cat "$CASE/rc")"
if [ "$rc" != "0" ]; then ok "no finalize log: exit non-zero"; else bad "no finalize log: exit 0"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then bad "no finalize log: SEED_REPORT_OK must NOT be printed"; else ok "no finalize log: no SEED_REPORT_OK"; fi

# --- CASE 7: `check` prints the verdict only -------------------------------
make_case check_mode
run_report check
rc="$(cat "$CASE/rc")"
if [ "$rc" = "0" ]; then ok "check mode: exit 0"; else bad "check mode: exit $rc"; fi
if grep -qF "SEED_REPORT_OK" "$CASE/out"; then ok "check mode: verdict printed"; else bad "check mode: verdict missing"; fi
if grep -qF "SEED_REPORT_META_MATCHED=" "$CASE/out"; then bad "check mode: must not dump key=value"; else ok "check mode: no key=value dump"; fi

echo "--- test_seed_finalize_report.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
