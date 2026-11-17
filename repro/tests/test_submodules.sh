#!/usr/bin/env bash
# repro/tests/test_submodules.sh — negative/edge-case tests for the
# submodule landing logic (repro/lib/submodules.sh) and for the failure-path
# evidence collected by repro/02_submodules.sh.
#
# The tests use a throwaway LOCAL git remote (a bare repo in a temp dir) as
# the "origin", so they need no network and never touch the real worktree's
# third_party/ directories.
#
# Covered failure surfaces:
#   1. land_submodule lands the pinned SHA from a remote
#   2. land_submodule is idempotent (second run = "already at pinned SHA")
#   3. land_submodule re-lands a checkout that sits on a DIFFERENT SHA
#   4. land_submodule FAILS (non-zero) when the remote has no such SHA
#   5. land_submodule FAILS (non-zero) when the remote is unreachable
#   6. verify_submodule accepts the pinned SHA and rejects:
#      wrong SHA / missing directory / dirty working tree
#   7. the archived failure-path evidence really contains the
#      "GMR missing -> uv sync fails" raw error, and re-running
#      02_submodules.sh does NOT overwrite it (container only)
#
# Run locally:  bash repro/tests/test_submodules.sh
# Run remotely: bash repro/lib/remote.sh tests/test_submodules.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=repro/lib/submodules.sh
source "$LIB_DIR/submodules.sh"

# common.sh turns on `errexit`; this test file drives commands that are
# EXPECTED to fail, so switch it back off for the assertions below.
set +e

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- build a throwaway "origin" with one commit on a branch ---------------
REMOTE="$TMP/origin.git"
WORK="$TMP/work"
mkdir -p "$WORK"
git_in "$WORK" init -q -b main 2>/dev/null || git_in "$WORK" init -q
git_in "$WORK" config user.email "repro-test@example.invalid"
git_in "$WORK" config user.name "repro test"
echo "pinned content" >"$WORK/file.txt"
git_in "$WORK" add file.txt
git_in "$WORK" commit -q -m "pinned commit"
PINNED_SHA="$(git_in "$WORK" rev-parse --verify HEAD)"
# A second commit on another branch, to be used as the "wrong SHA".
git_in "$WORK" checkout -q -b other
echo "other content" >"$WORK/other.txt"
git_in "$WORK" add other.txt
git_in "$WORK" commit -q -m "other commit"
OTHER_SHA="$(git_in "$WORK" rev-parse --verify HEAD)"
git_in "$WORK" checkout -q main
git clone -q --bare "$WORK" "$REMOTE" 2>/dev/null || git clone -q --bare "$WORK" "$REMOTE"

if [ -z "${PINNED_SHA:-}" ] || [ "${#PINNED_SHA}" -ne 40 ]; then
  bad "could not build the throwaway origin repo (PINNED_SHA='${PINNED_SHA:-}')"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi
ok "throwaway origin built at $PINNED_SHA (other branch $OTHER_SHA)"

# --- 1. land_submodule lands the pinned SHA -------------------------------
TARGET="$TMP/landed"
rc=0
land_submodule "$TARGET" "$REMOTE" "$PINNED_SHA" >/dev/null 2>&1 || rc=$?
head_via_git_in="$(git_in "$TARGET" rev-parse --verify HEAD 2>/dev/null || echo '<none>')"
if [ "$rc" -eq 0 ] && [ "$head_via_git_in" = "$PINNED_SHA" ]; then
  ok "land_submodule lands the pinned SHA (HEAD=$head_via_git_in)"
else
  bad "land_submodule failed to land the pinned SHA (rc=$rc HEAD=$head_via_git_in)"
fi

# --- 2. idempotency: second run must not re-clone -------------------------
out="$TMP/idem.out"
rc=0
land_submodule "$TARGET" "$REMOTE" "$PINNED_SHA" >"$out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q "already at pinned SHA" "$out"; then
  ok "land_submodule is idempotent (second run reports 'already at pinned SHA')"
else
  bad "land_submodule is not idempotent (rc=$rc out=$(tr '\n' ' ' <"$out"))"
fi

# --- 3. a checkout on a DIFFERENT SHA is re-landed ------------------------
# Land the other commit first, then ask for the pinned SHA: the mismatch must
# be detected and the checkout re-landed at the pinned SHA.
MISMATCH="$TMP/mismatched"
rc=0
land_submodule "$MISMATCH" "$REMOTE" "$OTHER_SHA" >/dev/null 2>&1 || rc=$?
mismatched_head="$(git_in "$MISMATCH" rev-parse --verify HEAD 2>/dev/null || echo '<none>')"
if [ "$rc" -ne 0 ] || [ "$mismatched_head" != "$OTHER_SHA" ]; then
  bad "could not set up the mismatching checkout (rc=$rc HEAD=$mismatched_head)"
else
  ok "mismatching checkout prepared at $OTHER_SHA"
fi
rc=0
land_submodule "$MISMATCH" "$REMOTE" "$PINNED_SHA" >/dev/null 2>&1 || rc=$?
head_after="$(git_in "$MISMATCH" rev-parse --verify HEAD 2>/dev/null || echo '<none>')"
if [ "$rc" -eq 0 ] && [ "$head_after" = "$PINNED_SHA" ]; then
  ok "land_submodule re-lands a checkout sitting on a different SHA"
else
  bad "land_submodule did not re-land a mismatching checkout (rc=$rc HEAD=$head_after)"
fi

# --- 4. a SHA that does not exist on the remote must fail -----------------
BOGUS_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
rc=0
land_submodule "$TMP/bogus" "$REMOTE" "$BOGUS_SHA" >"$TMP/bogus.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "land_submodule fails on an unknown SHA (exit $rc)"
else
  bad "land_submodule must fail when the remote does not contain the SHA"
fi

# --- 5. an unreachable remote must fail -----------------------------------
rc=0
land_submodule "$TMP/unreachable" "$TMP/does-not-exist.git" "$PINNED_SHA" >"$TMP/unreach.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "land_submodule fails on an unreachable remote (exit $rc)"
else
  bad "land_submodule must fail when the remote is unreachable"
fi

# --- 6. verify_submodule accepts/rejects ----------------------------------
rc=0
verify_submodule "$TARGET" "$PINNED_SHA" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "verify_submodule accepts the pinned SHA"
else
  bad "verify_submodule rejected the pinned SHA (rc=$rc)"
fi

rc=0
verify_submodule "$TARGET" "$OTHER_SHA" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "verify_submodule rejects a mismatching SHA"
else
  bad "verify_submodule accepted a mismatching SHA"
fi

rc=0
verify_submodule "$TMP/not-a-repo" "$PINNED_SHA" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "verify_submodule rejects a missing directory"
else
  bad "verify_submodule accepted a missing directory"
fi

echo "dirt" >>"$TARGET/file.txt"
rc=0
verify_submodule "$TARGET" "$PINNED_SHA" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "verify_submodule rejects a dirty working tree"
else
  bad "verify_submodule accepted a dirty working tree"
fi
git_in "$TARGET" checkout -q -- file.txt 2>/dev/null || true

# --- 7. failure-path evidence is genuine and is not overwritten -----------
FAILURE_LOG="$LOG_DIR/02_uv_sync_without_gmr.txt"
if [ -f "$FAILURE_LOG" ]; then
  if grep -q "Distribution not found at" "$FAILURE_LOG" \
     && grep -qE "exit code B: [1-9]" "$FAILURE_LOG"; then
    ok "failure-path evidence contains the real 'GMR missing -> uv sync fails' error"
  else
    bad "failure-path evidence does not contain the expected raw uv error"
  fi

  before_hash="$(sha256sum "$FAILURE_LOG" | awk '{print $1}')"
  rc=0
  bash "$REPO_ROOT/repro/02_submodules.sh" >/dev/null 2>&1 || rc=$?
  after_hash="$(sha256sum "$FAILURE_LOG" | awk '{print $1}')"
  if in_container; then
    if [ "$rc" -eq 0 ] && [ "$before_hash" = "$after_hash" ]; then
      ok "re-running 02_submodules.sh succeeds and leaves the archived failure evidence untouched"
    else
      bad "re-running 02_submodules.sh failed (rc=$rc) or overwrote the failure evidence"
    fi
  else
    # Outside the container the script must refuse (exit 3) and must not
    # rewrite the container-produced evidence file.
    if [ "$rc" -eq 3 ] && [ "$before_hash" = "$after_hash" ]; then
      ok "02_submodules.sh refuses to run outside the container and leaves the archived evidence untouched"
    else
      bad "02_submodules.sh outside the container: expected exit 3 + untouched evidence (rc=$rc)"
    fi
  fi
else
  skip "failure-path evidence checks (logs/env/02_uv_sync_without_gmr.txt not present yet)"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
echo "TESTS_OK"
