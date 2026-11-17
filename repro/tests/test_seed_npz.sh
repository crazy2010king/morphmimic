#!/usr/bin/env bash
# repro/tests/test_seed_npz.sh — offline fixture battery for
# repro/lib/seed_npz.sh (the shell decision helpers of the G1 50 Hz npz
# conversion) and repro/lib/seed_npz.py (the python decision functions).
#
# No network, no GPU, no 150 GB payload: every fixture is synthetic and lives
# in a temp dir that is removed on exit.  The battery covers:
#
#   1. the shell library is sourceable and exposes every function
#   2. seed_npz_write_status writes STATE=/RC= and replaces atomically
#   3. seed_npz_expected_rows defaults to 142220 and honours the override
#   4. seed_npz_space_gate fails on an impossible threshold, passes on 0
#   5. seed_npz_sample_paths samples deterministically and spans the manifest
#   5b. the shell wrapper and the python module agree on the sampling
#   5c. seed_npz_parse_progress parses the upstream tqdm stderr output
#   6. the python unit tests (repro/tests/test_seed_npz.py) are all green
#   7. no backtick command substitution in the shell sources
#
# Run locally:   bash repro/tests/test_seed_npz.sh
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SH_LIB="$LIB_DIR/seed_npz.sh"
PY_LIB="$LIB_DIR/seed_npz.py"
PY_TEST="$REPO_ROOT/repro/tests/test_seed_npz.py"

PASS=0
FAIL=0
SKIP=0
python_bin="${SEED_NPZ_PYTHON:-python3}"

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# 1. the library is sourceable and complete
# ============================================================================
if [ ! -f "$SH_LIB" ]; then
  bad "shell library missing: $SH_LIB"
else
  # shellcheck source=../lib/seed_npz.sh
  if source "$SH_LIB"; then
    ok "shell library sources cleanly"
  else
    bad "shell library failed to source"
  fi
fi

MISSING=""
for fn in seed_npz_min_free_gb seed_npz_free_gb seed_npz_space_gate \
          seed_npz_expected_rows seed_npz_sample_paths seed_npz_write_status \
          seed_npz_parse_progress seed_npz_subset_names; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    MISSING="$MISSING $fn"
  fi
done
if [ -z "$MISSING" ]; then
  ok "every documented function is defined"
else
  bad "missing functions:$MISSING"
fi

# the library must be a pure function library: sourcing it must not execute
# anything (no output above except from the assertions themselves).
if [ ! -f "$PY_LIB" ]; then
  bad "python library missing: $PY_LIB"
else
  if grep -qE '^[[:space:]]*(python3?|uv run)' "$PY_LIB"; then
    bad "the python library must not spawn interpreters at import time"
  else
    ok "the python library spawns no subprocess at import time"
  fi
  if grep -qE '^[[:space:]]*(import|from)[[:space:]]+(numpy|pandas|scipy|yaml|mujoco|torch)\b' "$PY_LIB"; then
    bad "the python library must only use the standard library"
  else
    ok "the python library imports only the standard library"
  fi
fi

# ============================================================================
# 2. seed_npz_write_status: STATE=/RC= and an atomic replace
# ============================================================================
STATUS="$TMP/status/13_seed_convert.status"
mkdir -p "$(dirname "$STATUS")"
if seed_npz_write_status "$STATUS" RUNNING 0 "CLIPS=142220" "STARTED_AT=2026-01-01T00:00:00Z"; then
  ok "write_status succeeds"
else
  bad "write_status returned non-zero"
fi
if grep -q '^STATE=RUNNING$' "$STATUS"; then
  ok "status file carries STATE=RUNNING"
else
  bad "status file has no STATE=RUNNING"; sed 's/^/      | /' "$STATUS"
fi
if grep -q '^RC=0$' "$STATUS"; then
  ok "status file carries RC=0"
else
  bad "status file has no RC=0"; sed 's/^/      | /' "$STATUS"
fi
if grep -q '^CLIPS=142220$' "$STATUS"; then
  ok "status file carries the extra key=value pairs"
else
  bad "status file lost the extra key=value pairs"; sed 's/^/      | /' "$STATUS"
fi
if [ -f "$STATUS.tmp" ]; then
  bad "the .tmp file was left behind (not an atomic replace)"
else
  ok "no .tmp file left behind after the replace"
fi
# a second write must fully replace the previous content
seed_npz_write_status "$STATUS" DONE 0 "ROWS=142220"
if grep -q '^STATE=DONE$' "$STATUS" && ! grep -q '^STATE=RUNNING$' "$STATUS"; then
  ok "a second write replaces the previous content"
else
  bad "a second write did not replace the previous content"; sed 's/^/      | /' "$STATUS"
fi
if grep -q '^RC=0$' "$STATUS"; then
  ok "status file carries RC=0 after the replace"
else
  bad "status file lost RC=0 after the replace"
fi

# ============================================================================
# 3. seed_npz_expected_rows: default 142220, override honoured
# ============================================================================
DEFAULT_ROWS="$(seed_npz_expected_rows)"
if [ "$DEFAULT_ROWS" = "142220" ]; then
  ok "expected_rows defaults to 142220"
else
  bad "expected_rows default is $DEFAULT_ROWS (expected 142220)"
fi
OVERRIDE="$(SEED_EXPECTED_ROWS=10 seed_npz_expected_rows)"
if [ "$OVERRIDE" = "10" ]; then
  ok "expected_rows honours SEED_EXPECTED_ROWS"
else
  bad "expected_rows override is $OVERRIDE (expected 10)"
fi

# ============================================================================
# 4. seed_npz_space_gate: fails closed, passes on a 0 GiB threshold
# ============================================================================
SPACE_DIR="$TMP/space"
mkdir -p "$SPACE_DIR"
FREE="$(seed_npz_free_gb "$SPACE_DIR")"
case "$FREE" in
  ''|*[!0-9]*)
    bad "free_gb did not print an integer for an existing dir: '$FREE'" ;;
  *)
    ok "free_gb prints an integer for an existing dir ($FREE GiB)" ;;
esac

set +e
SPACE_OUT="$(SEED_MIN_FREE_GB=99999999 seed_npz_space_gate "$SPACE_DIR" 2>&1)"
SPACE_RC=$?
if [ "$SPACE_RC" -ne 0 ]; then
  ok "space_gate fails on an impossible threshold (rc=$SPACE_RC)"
else
  bad "space_gate passed with an impossible threshold"
fi
case "$SPACE_OUT" in
  *空间不足*) ok "space_gate prints the explicit '空间不足' hint" ;;
  *) bad "space_gate printed no '空间不足' hint: $SPACE_OUT" ;;
esac

set +e
SPACE_OUT="$(SEED_MIN_FREE_GB=0 seed_npz_space_gate "$SPACE_DIR" 2>&1)"
SPACE_RC=$?
if [ "$SPACE_RC" -eq 0 ]; then
  ok "space_gate passes with a 0 GiB threshold"
else
  bad "space_gate failed with a 0 GiB threshold (rc=$SPACE_RC): $SPACE_OUT"
fi

set +e
SPACE_OUT="$(SEED_MIN_FREE_GB=0 seed_npz_space_gate "$TMP/does-not-exist" 2>&1)"
SPACE_RC=$?
if [ "$SPACE_RC" -ne 0 ]; then
  ok "space_gate fails closed for a non-existent dir"
else
  bad "space_gate passed for a non-existent dir"
fi

# ============================================================================
# 5. seed_npz_sample_paths: deterministic, evenly spread, path column
# ============================================================================
MANIFEST="$TMP/manifest.csv"
{
  printf 'name,path,session,frames,seconds,name_reject,feas_reject,category,package\n'
  for i in $(seq 1 20); do
    printf 'clip_%03d.npz,230509/clip_%03d.npz,230509,500,10.0,,,walk,p1\n' "$i" "$i"
  done
} >"$MANIFEST"

SAMPLE="$(seed_npz_sample_paths "$MANIFEST" 5)"
SAMPLE_COUNT="$(printf '%s\n' "$SAMPLE" | grep -c . )"
if [ "$SAMPLE_COUNT" -eq 5 ]; then
  ok "sample_paths prints the requested number of paths (5)"
else
  bad "sample_paths printed $SAMPLE_COUNT paths (expected 5)"
fi
SAMPLE2="$(seed_npz_sample_paths "$MANIFEST" 5)"
if [ "$SAMPLE" = "$SAMPLE2" ]; then
  ok "sample_paths is deterministic across calls"
else
  bad "sample_paths is not deterministic"
fi
if printf '%s\n' "$SAMPLE" | grep -qv '^230509/clip_[0-9]*\.npz$'; then
  bad "sample_paths printed something that is not a manifest path"
  printf '%s\n' "$SAMPLE" | sed 's/^/      | /'
else
  ok "sample_paths prints the path column"
fi
# the sample must span the manifest, not cluster in its head
FIRST="$(printf '%s\n' "$SAMPLE" | head -n 1)"
LAST="$(printf '%s\n' "$SAMPLE" | tail -n 1)"
if [ "$FIRST" = "230509/clip_001.npz" ] && [ "$LAST" = "230509/clip_020.npz" ]; then
  ok "sample_paths spans the whole manifest (first=$FIRST last=$LAST)"
else
  bad "sample_paths does not span the manifest (first=$FIRST last=$LAST)"
fi
# asking for more paths than rows yields the rows that exist
SAMPLE_ALL="$(seed_npz_sample_paths "$MANIFEST" 1000)"
SAMPLE_ALL_COUNT="$(printf '%s\n' "$SAMPLE_ALL" | grep -c . )"
if [ "$SAMPLE_ALL_COUNT" -eq 20 ]; then
  ok "sample_paths clamps to the number of manifest rows"
else
  bad "sample_paths printed $SAMPLE_ALL_COUNT paths (expected 20)"
fi
# a missing manifest is an error, not an empty success
set +e
seed_npz_sample_paths "$TMP/nope.csv" 5 >/dev/null 2>&1
SAMPLE_RC=$?
if [ "$SAMPLE_RC" -ne 0 ]; then
  ok "sample_paths fails for a missing manifest"
else
  bad "sample_paths returned 0 for a missing manifest"
fi

# ============================================================================
# 5b. the shell wrapper and the python module agree on the sampling
# ============================================================================
PY_SAMPLE="$("$python_bin" "$PY_LIB" sample-paths "$MANIFEST" 5 2>/dev/null)"
if [ -n "$PY_SAMPLE" ]; then
  ok "the python CLI sample-paths command works"
else
  bad "the python CLI sample-paths command produced nothing"
fi
if [ "$SAMPLE" = "$PY_SAMPLE" ]; then
  ok "shell sample_paths and python sample_paths agree"
else
  bad "shell sample_paths and python sample_paths disagree"
  printf '      shell : %s\n' "$(printf '%s' "$SAMPLE" | tr '\n' ' ')"
  printf '      python: %s\n' "$(printf '%s' "$PY_SAMPLE" | tr '\n' ' ')"
fi

# a manifest whose `name` field contains a comma is written by pandas with
# the field quoted; the path column must still be read correctly (a naive
# `awk -F,` split would mis-align every following column)
QUOTED_MANIFEST="$TMP/quoted_manifest.csv"
{
  printf 'name,path,session,frames,seconds,name_reject,feas_reject,category,package\n'
  for i in $(seq 1 20); do
    printf '"clip, %03d.npz",230509/clip_%03d.npz,230509,500,10.0,,,walk,p1\n' "$i" "$i"
  done
} >"$QUOTED_MANIFEST"
QUOTED_SAMPLE="$(seed_npz_sample_paths "$QUOTED_MANIFEST" 6)"
QUOTED_COUNT="$(printf '%s\n' "$QUOTED_SAMPLE" | grep -c . )"
if [ "$QUOTED_COUNT" -eq 6 ]; then
  ok "sample_paths handles a manifest with quoted, comma-bearing fields"
else
  bad "sample_paths printed $QUOTED_COUNT paths for the quoted manifest (expected 6)"
fi
if printf '%s\n' "$QUOTED_SAMPLE" | grep -qv '^230509/clip_[0-9]*\.npz$'; then
  bad "sample_paths mis-aligned the columns of the quoted manifest"
  printf '%s\n' "$QUOTED_SAMPLE" | sed 's/^/      | /'
else
  ok "sample_paths keeps the path column aligned on a quoted manifest"
fi

# ============================================================================
# 5c. seed_npz_parse_progress: the tqdm stderr parser
# ============================================================================
# The upstream converter writes its progress with tqdm on stderr, using
# carriage returns.  The parser must return the LAST progress line and must
# stay silent on a file that holds no progress line at all (fail closed: a
# bogus done count would corrupt the progress markers).
PROG="$TMP/progress.err"
printf 'convert:   0%%|          | 0/142220 [00:00<?, ?it/s]\rconvert:  45%%|####      | 64000/142220 [00:30<00:40,  2.1kit/s]\rconvert: 100%%|##########| 142220/142220 [01:00<00:00, 2370.00it/s]\n' >"$PROG"
PARSED="$(seed_npz_parse_progress "$PROG")"
P_DONE="$(printf '%s\n' "$PARSED" | awk '{print $1}')"
P_TOTAL="$(printf '%s\n' "$PARSED" | awk '{print $2}')"
P_RATE="$(printf '%s\n' "$PARSED" | awk '{print $3}')"
if [ "$P_DONE" = "142220" ] && [ "$P_TOTAL" = "142220" ]; then
  ok "parse_progress reads the last tqdm line (done=$P_DONE total=$P_TOTAL)"
else
  bad "parse_progress returned '$PARSED' (expected done=142220 total=142220)"
fi
if [ -n "$P_RATE" ] && [ "$P_RATE" != "?" ]; then
  ok "parse_progress extracts the rate ($P_RATE)"
else
  bad "parse_progress did not extract a rate: '$PARSED'"
fi

EMPTY_PROG="$TMP/empty_progress.err"
: >"$EMPTY_PROG"
PARSED_EMPTY="$(seed_npz_parse_progress "$EMPTY_PROG")"
if [ -z "$PARSED_EMPTY" ]; then
  ok "parse_progress stays silent on a file without a progress line"
else
  bad "parse_progress returned '$PARSED_EMPTY' for an empty file"
fi

if seed_npz_parse_progress "$TMP/no-such-progress.err" >/dev/null 2>&1; then
  bad "parse_progress succeeded for a missing file"
else
  ok "parse_progress fails for a missing file"
fi

# ============================================================================
# 6. the python unit tests are green
# ============================================================================
if [ ! -f "$PY_TEST" ]; then
  bad "python test file missing: $PY_TEST"
else
  PY_OUT="$TMP/py_test.out"
  set +e
  python3 "$PY_TEST" >"$PY_OUT" 2>&1
  PY_RC=$?
  if [ "$PY_RC" -eq 0 ]; then
    ok "repro/tests/test_seed_npz.py passes (rc=0)"
  else
    bad "repro/tests/test_seed_npz.py failed (rc=$PY_RC)"
    sed 's/^/      | /' "$PY_OUT" | tail -n 40
  fi
  PY_COUNT="$(grep -cE '^(test_|  test_)' "$PY_OUT" || true)"
  if [ "${PY_COUNT:-0}" -ge 20 ]; then
    ok "the python battery runs a meaningful number of cases ($PY_COUNT)"
  else
    bad "the python battery only ran $PY_COUNT case lines"
  fi
fi

# ============================================================================
# 7. no backtick command substitution in the shell sources
# ============================================================================
# A stray backtick inside a double-quoted string is a COMMAND SUBSTITUTION:
# `ok "prints the \`path\` column"` silently runs a command named `path` and
# makes bash print "path: command not found" on stderr.  The exit code stays
# 0, so the suite stays green — but the GSD verification gate reads stderr,
# classifies the run as `command-not-found` and reports the Verify command as
# "not runnable on this platform" (#T01 gate trip).  The suite cannot capture
# its own stderr, so the rule is enforced statically: a backtick may only
# appear in a comment line or in a single-quoted string.
BACKTICK_HITS=""
for src in "$SH_LIB" "$0"; do
  [ -f "$src" ] || continue
  while IFS= read -r line; do
    case "$line" in
      '#'*) continue ;;
    esac
    # strip single-quoted spans (their backticks are literal)
    stripped="$(printf '%s' "$line" | sed "s/'[^']*'//g")"
    case "$stripped" in
      *'`'*) BACKTICK_HITS="$BACKTICK_HITS $src:$line" ;;
    esac
  done <"$src"
done
if [ -z "$BACKTICK_HITS" ]; then
  ok "no backtick command substitution in the shell sources"
else
  bad "backtick command substitution found in a shell source:"
  printf '%s\n' "$BACKTICK_HITS" | sed 's/^/      | /'
fi

# ============================================================================
# summary
# ============================================================================
printf '\n== test_seed_npz.sh: PASS=%d FAIL=%d SKIP=%d ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "ERROR: $SKIP test(s) were skipped — a SKIP must never mask a failure." >&2
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
