#!/usr/bin/env bash
# repro/tests/test_seed_finalize.sh — offline fixture battery for
# repro/11_seed_finalize.sh (the unattended terminal chain).
#
# No network and no real archives: the download status file is a fixture and
# the 09/10 scripts are STUBS that record their invocation and return a
# configured exit code.  The battery covers:
#
#   1. happy path          -> exit 0, SEED_FINALIZE_OK, every phase DONE
#   2. download not done   -> the worker WAITS (bounded by MAX_WAIT_S) and
#                             fails with reason=download-timeout, never OK
#   3. download FAILED     -> fails fast, reason=download-failed, never OK
#   4. dead download PID   -> a status file with a dead PID and no terminal
#                             state is FAILED (not "still running")
#   5. verifier fails      -> reason=step-failed phase=verify, never OK
#   6. extractor fails     -> reason=step-failed phase=extract, never OK
#   7. missing SHA256SUMS  -> reason=sha256sums-missing, never OK
#   8. sha256sum -c fails  -> reason=sha256-check-failed, never OK
#   9. `verify` subcommand -> asserts the terminal markers really landed
#  10. step ORDER          -> verify -> extract worker -> reconcile (the
#                             reconciliation must not run before the extract)
#
# EVERY failing case additionally asserts that SEED_FINALIZE_OK was NOT
# printed (same OK-marker buffering convention as repro/09_seed_verify.sh).
#
# Run locally:   bash repro/tests/test_seed_finalize.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_seed_finalize.sh
# (also reachable as `bash repro/lib/remote.sh 11_seed_finalize.sh selftest`)
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/repro/11_seed_finalize.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# CASE: the directory of the case under test (set by make_case, never
# captured through a command substitution: the fixture stubs write to it
# and a subshell would lose the variable).
CASE=""

# --- fixture ----------------------------------------------------------------
# make_case <name> — build an isolated case dir in $CASE.
#
# Layout:
#   <case>/repro/09_seed_verify.sh   stub
#   <case>/repro/10_seed_extract.sh   stub
#   <case>/archives/                  archive dir + SHA256SUMS
#   <case>/logs/                      status + log files
#
# The stubs append their invocation to <case>/calls.log and exit with the
# code in <case>/rc_verify / <case>/rc_extract (default 0).
make_case() {
  local name="$1"
  CASE="$TMP/$name"
  mkdir -p "$CASE/repro" "$CASE/archives" "$CASE/logs"

  cat >"$CASE/repro/09_seed_verify.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB 09 verify" >>"${CASE_DIR}/calls.log"
echo "SEED_VERIFY_OK"
exit "$(cat "${CASE_DIR}/rc_verify" 2>/dev/null || echo 0)"
STUB
  cat >"$CASE/repro/10_seed_extract.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB 10 ${1:-none}" >>"${CASE_DIR}/calls.log"
echo "SEED_META_MATCH matched=142220 missing=0 extra=0"
echo "SEED_EXTRACT_OK files=284440"
exit "$(cat "${CASE_DIR}/rc_extract" 2>/dev/null || echo 0)"
STUB
  chmod +x "$CASE/repro/09_seed_verify.sh" "$CASE/repro/10_seed_extract.sh"

  printf '0' >"$CASE/rc_verify"
  printf '0' >"$CASE/rc_extract"
}

# run_finalize [extra env assignments...] -> runs the worker foreground and
# captures the combined output in $OUT.
OUT=""
run_finalize() {
  # `env` (not a shell assignment prefix) so that "$@" really becomes
  # environment variables: a shell assignment word is recognised at PARSE
  # time, so `VAR=$v cmd` would set VAR to the literal string "v=...".
  OUT="$(env CASE_DIR="$CASE" \
    SEED_FINALIZE_ALLOW_LOCAL=1 \
    SEED_FINALIZE_REPRO_DIR="$CASE/repro" \
    SEED_FINALIZE_DOWNLOAD_STATUS="$CASE/logs/08_seed_download.status" \
    SEED_FINALIZE_SHA256SUMS="$CASE/archives/SHA256SUMS" \
    SEED_FINALIZE_ARCHIVE_DIR="$CASE/archives" \
    SEED_FINALIZE_LOG="$CASE/logs/11_seed_finalize.txt" \
    SEED_FINALIZE_STATUS="$CASE/logs/11_seed_finalize.status" \
    SEED_FINALIZE_WORKER_LOG="$CASE/logs/11_seed_finalize_worker.log" \
    SEED_FINALIZE_VERIFY_LOG="$CASE/logs/09_seed_verify.txt" \
    SEED_FINALIZE_EXTRACT_LOG="$CASE/logs/10_seed_extract.txt" \
    SEED_FINALIZE_POLL_S=1 \
    "$@" \
    bash "$SCRIPT" worker 2>&1)"
}

# run_verify_cmd -> runs the `verify` subcommand, captures output in $OUT
# and the exit code in $RC.
RC=0
run_verify_cmd() {
  OUT="$(env CASE_DIR="$CASE" \
    SEED_FINALIZE_ALLOW_LOCAL=1 \
    SEED_FINALIZE_DOWNLOAD_STATUS="$CASE/logs/08_seed_download.status" \
    SEED_FINALIZE_SHA256SUMS="$CASE/archives/SHA256SUMS" \
    SEED_FINALIZE_LOG="$CASE/logs/11_seed_finalize.txt" \
    SEED_FINALIZE_STATUS="$CASE/logs/11_seed_finalize.status" \
    SEED_FINALIZE_VERIFY_LOG="$CASE/logs/09_seed_verify.txt" \
    SEED_FINALIZE_EXTRACT_LOG="$CASE/logs/10_seed_extract.txt" \
    bash "$SCRIPT" verify 2>&1)"
  RC=$?
}

# write_status <state> [pid]
write_status() {
  local state="$1" pid="${2:-$$}"
  {
    printf 'STATE=%s\n' "$state"
    printf 'PID=%s\n' "$pid"
    printf 'FILE=g1.tar.gz\n'
  } >"$CASE/logs/08_seed_download.status"
}

# make_sha256sums — a real SHA256SUMS over one real file.
make_sha256sums() {
  printf 'seed payload\n' >"$CASE/archives/g1.tar.gz"
  ( cd "$CASE/archives" && sha256sum g1.tar.gz >SHA256SUMS )
}

# assert_no_ok <label>
assert_no_ok() {
  if printf '%s' "$OUT" | grep -q "SEED_FINALIZE_OK"; then
    bad "$1: SEED_FINALIZE_OK was printed on a failing path"
  else
    ok "$1: no SEED_FINALIZE_OK on the failing path"
  fi
}

# --- 1. happy path ----------------------------------------------------------
make_case happy
write_status DONE
make_sha256sums
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "SEED_FINALIZE_OK"; then
  ok "happy path: SEED_FINALIZE_OK printed"
else
  bad "happy path: SEED_FINALIZE_OK missing"
fi
if printf '%s' "$OUT" | grep -q "SEED_FINALIZE_DONE phase=verify" \
   && printf '%s' "$OUT" | grep -q "SEED_FINALIZE_DONE phase=extract" \
   && printf '%s' "$OUT" | grep -q "SEED_FINALIZE_DONE phase=reconcile" \
   && printf '%s' "$OUT" | grep -q "SEED_FINALIZE_DONE phase=sha256"; then
  ok "happy path: every phase reported DONE"
else
  bad "happy path: a phase did not report DONE"
fi
if [ -f "$CASE/logs/11_seed_finalize.status" ] \
   && grep -q "^STATE=DONE" "$CASE/logs/11_seed_finalize.status"; then
  ok "happy path: status file says DONE"
else
  bad "happy path: status file does not say DONE"
fi

# --- 10. step order ---------------------------------------------------------
calls="$(cat "$CASE/calls.log" 2>/dev/null)"
verify_pos="$(printf '%s\n' "$calls" | grep -n "STUB 09 verify" | head -n1 | cut -d: -f1)"
extract_pos="$(printf '%s\n' "$calls" | grep -n "STUB 10 worker" | head -n1 | cut -d: -f1)"
recon_pos="$(printf '%s\n' "$calls" | grep -n "STUB 10 verify" | head -n1 | cut -d: -f1)"
if [ -n "$verify_pos" ] && [ -n "$extract_pos" ] && [ -n "$recon_pos" ] \
   && [ "$verify_pos" -lt "$extract_pos" ] && [ "$extract_pos" -lt "$recon_pos" ]; then
  ok "step order: verify -> extract worker -> reconcile"
else
  bad "step order: wrong call order (verify=$verify_pos extract=$extract_pos reconcile=$recon_pos)"
fi

# --- 2. download not done ---------------------------------------------------
make_case waiting
write_status DOWNLOADING
make_sha256sums
run_finalize SEED_FINALIZE_MAX_WAIT_S=3
if printf '%s' "$OUT" | grep -q "SEED_FINALIZE_WAIT state=RUNNING"; then
  ok "download not done: the worker waited instead of proceeding"
else
  bad "download not done: the worker did not report a wait"
fi
if printf '%s' "$OUT" | grep -q "reason=download-timeout"; then
  ok "download not done: bounded wait failed with reason=download-timeout"
else
  bad "download not done: expected reason=download-timeout"
fi
assert_no_ok "download not done"
if [ -f "$CASE/logs/11_seed_finalize.status" ] \
   && grep -q "^STATE=FAILED" "$CASE/logs/11_seed_finalize.status"; then
  ok "download not done: status file says FAILED"
else
  bad "download not done: status file does not say FAILED"
fi

# --- 3. download FAILED -----------------------------------------------------
make_case dlfailed
write_status FAILED
make_sha256sums
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "reason=download-failed"; then
  ok "download FAILED: failed fast with reason=download-failed"
else
  bad "download FAILED: expected reason=download-failed"
fi
assert_no_ok "download FAILED"

# --- 4. dead download PID ---------------------------------------------------
make_case deadpid
# A PID that cannot exist: the worker must treat it as FAILED, not RUNNING.
write_status DOWNLOADING 999999
make_sha256sums
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "reason=download-failed"; then
  ok "dead download PID: treated as FAILED"
else
  bad "dead download PID: expected reason=download-failed"
fi
assert_no_ok "dead download PID"

# --- 5. verifier fails ------------------------------------------------------
make_case verifyfail
write_status DONE
make_sha256sums
printf '3' >"$CASE/rc_verify"
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "reason=step-failed" \
   && printf '%s' "$OUT" | grep -q "phase=verify"; then
  ok "verifier fails: reason=step-failed phase=verify"
else
  bad "verifier fails: expected reason=step-failed phase=verify"
fi
assert_no_ok "verifier fails"

# --- 6. extractor fails -----------------------------------------------------
make_case extractfail
write_status DONE
make_sha256sums
printf '4' >"$CASE/rc_extract"
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "reason=step-failed" \
   && printf '%s' "$OUT" | grep -q "phase=extract"; then
  ok "extractor fails: reason=step-failed phase=extract"
else
  bad "extractor fails: expected reason=step-failed phase=extract"
fi
assert_no_ok "extractor fails"

# --- 7. missing SHA256SUMS --------------------------------------------------
make_case nosums
write_status DONE
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "reason=sha256sums-missing"; then
  ok "missing SHA256SUMS: reason=sha256sums-missing"
else
  bad "missing SHA256SUMS: expected reason=sha256sums-missing"
fi
assert_no_ok "missing SHA256SUMS"

# --- 8. sha256sum -c fails --------------------------------------------------
make_case shabad
write_status DONE
make_sha256sums
# Corrupt the payload so `sha256sum -c` must fail.
printf 'tampered\n' >"$CASE/archives/g1.tar.gz"
run_finalize SEED_FINALIZE_MAX_WAIT_S=30
if printf '%s' "$OUT" | grep -q "reason=sha256-check-failed"; then
  ok "sha256sum -c fails: reason=sha256-check-failed"
else
  bad "sha256sum -c fails: expected reason=sha256-check-failed"
fi
assert_no_ok "sha256sum -c fails"

# --- 9. the `verify` subcommand --------------------------------------------
make_case verifycmd
write_status DONE
make_sha256sums
# The evidence logs are missing -> verify must fail.
run_verify_cmd
if [ "$RC" -ne 0 ]; then
  ok "verify: exits non-zero when the terminal evidence is missing"
else
  bad "verify: exited 0 although the evidence is missing"
fi
# Now provide the evidence -> verify must pass.
printf 'SEED_VERIFY_OK\n' >"$CASE/logs/09_seed_verify.txt"
printf 'SEED_META_MATCH matched=142220 missing=0 extra=0\nSEED_EXTRACT_OK files=284440\n' \
  >"$CASE/logs/10_seed_extract.txt"
run_verify_cmd
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "SEED_FINALIZE_OK"; then
  ok "verify: exits 0 and prints SEED_FINALIZE_OK when the evidence is present"
else
  bad "verify: did not pass although the evidence is present"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s\n' "--- test_seed_finalize.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
