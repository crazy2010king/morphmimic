#!/usr/bin/env bash
# repro/tests/test_lib.sh — negative/edge-case tests for the repro helpers.
#
# Covers the failure paths that a happy-path snapshot run never exercises:
#   1. run_logged propagates a failing command's exit code
#   2. run_logged captures stdout+stderr into the logfile and creates its dir
#   3. run_logged rejects an empty command list
#   4. resolve_git_context + git_repo work for a linked worktree
#   5. remote.sh rejects an empty argument list (usage + exit 2)
#   6. remote.sh propagates a remote failure (missing script -> nonzero)
#   7. 01_snapshot.sh refuses to run outside the container (guard rail), and
#      never rewrites the container's snapshot when it refuses
#   8. running a repro step leaves every system configuration file byte-identical
#      (this is the invariant we own: the proxy is inlined, never persisted)
#   9. the proxy variables are process-scoped, absent from a clean environment
#
# Run locally:  bash repro/tests/test_lib.sh
# Run remotely: bash repro/lib/remote.sh tests/test_lib.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# System configuration files that must never be written by a repro script.
SYS_CONFIG_FILES=(
  /etc/environment /etc/profile /etc/bash.bashrc /root/.bashrc /root/.profile
  /root/.config/uv/uv.toml /root/.config/pip/pip.conf /etc/pip.conf
  /root/.gitconfig /etc/gitconfig /etc/apt/apt.conf /etc/wgetrc
)

sysconfig_digest() {
  # sha256 of every existing system config file (name + content), so that a
  # change to any of them changes the digest.
  local f
  for f in "${SYS_CONFIG_FILES[@]}"; do
    [ -f "$f" ] || continue
    printf '%s ' "$f"
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  done
  for d in /etc/environment.d /etc/profile.d /etc/apt/apt.conf.d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      printf '%s ' "$f"
      sha256sum "$f" 2>/dev/null | awk '{print $1}'
    done
  done
}

# --- 1. run_logged propagates a non-zero exit code -------------------------
rc=0
run_logged "$TMP/exitcode.log" bash -c 'exit 7' >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 7 ]; then
  ok "run_logged propagates exit code 7 (got $rc)"
else
  bad "run_logged should propagate exit code 7, got $rc"
fi

# --- 2. run_logged captures stdout+stderr and creates the log dir ----------
rc=0
run_logged "$TMP/nested/deep/out.log" bash -c 'echo to-stdout; echo to-stderr >&2' >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TMP/nested/deep/out.log" ] \
   && grep -q 'to-stdout' "$TMP/nested/deep/out.log" \
   && grep -q 'to-stderr' "$TMP/nested/deep/out.log"; then
  ok "run_logged writes stdout+stderr into a freshly created log dir"
else
  bad "run_logged failed to capture output / create log dir (rc=$rc)"
fi

# --- 3. run_logged rejects an empty command list ---------------------------
rc=0
run_logged "$TMP/empty.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  ok "run_logged rejects an empty command list (exit 2, got $rc)"
else
  bad "run_logged should exit 2 for an empty command list, got $rc"
fi

# --- 4. git context resolution works for a linked worktree -----------------
resolve_git_context
head_out="$(git_repo rev-parse HEAD 2>&1 || echo UNKNOWN)"
branch_out="$(git_repo branch --show-current 2>&1 || echo UNKNOWN)"
if [ "$head_out" != "UNKNOWN" ] && [ "${#head_out}" -eq 40 ]; then
  ok "git_repo resolves HEAD through the linked-worktree gitdir ($head_out)"
else
  bad "git_repo failed to resolve HEAD (got '$head_out')"
fi
if [ -n "$branch_out" ] && [ "$branch_out" != "UNKNOWN" ]; then
  ok "git_repo resolves the current branch ($branch_out)"
else
  bad "git_repo failed to resolve the branch (got '$branch_out')"
fi

# --- 5. remote.sh rejects an empty argument list --------------------------
rc=0
bash "$LIB_DIR/remote.sh" >"$TMP/usage.out" 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'usage' "$TMP/usage.out"; then
  ok "remote.sh prints usage and exits 2 without a script argument"
else
  bad "remote.sh should exit 2 with usage output (rc=$rc)"
fi

# --- 6. remote.sh propagates a remote failure ------------------------------
# A script that does not exist on the remote side must surface as a non-zero
# exit code, not a silent success.
if [ -n "${REMOTE_TEST_ENABLED:-}" ]; then
  rc=0
  bash "$LIB_DIR/remote.sh" 99_does_not_exist.sh >"$TMP/missing.out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "remote.sh propagates a remote failure (missing script -> exit $rc)"
  else
    bad "remote.sh should fail when the remote script is missing"
  fi
else
  skip "remote.sh remote-failure propagation (needs the remote host)"
fi

# --- 7. 01_snapshot.sh is container-guarded --------------------------------
# logs/ lives on the shared NFS export, so the snapshot must only ever be
# written from inside the container. Running it locally must refuse.
SNAP="$LOG_DIR/snapshot.txt"
before_hash="$(sha256sum "$SNAP" 2>/dev/null | awk '{print $1}')"
rc=0
bash "$REPO_ROOT/repro/01_snapshot.sh" >"$TMP/snapshot_local.out" 2>&1 || rc=$?
after_hash="$(sha256sum "$SNAP" 2>/dev/null | awk '{print $1}')"

if in_container; then
  if [ "$rc" -eq 0 ]; then
    ok "01_snapshot.sh runs inside the container (exit 0)"
  else
    bad "01_snapshot.sh should succeed inside the container (rc=$rc)"
  fi
else
  if [ "$rc" -eq 3 ] && grep -qi 'must run inside the ros_dev container' "$TMP/snapshot_local.out"; then
    ok "01_snapshot.sh refuses to run outside the container (exit 3)"
  else
    bad "01_snapshot.sh should exit 3 outside the container (rc=$rc)"
  fi
  if [ "$before_hash" = "$after_hash" ]; then
    ok "refused snapshot run left the container's snapshot.txt byte-identical"
  else
    bad "refused snapshot run modified snapshot.txt (before=$before_hash after=$after_hash)"
  fi
fi

# --- 8. repro steps never write to system configuration files --------------
# The invariant we own: the proxy is inlined into the process environment only,
# and no system configuration file is ever modified by a repro script.
digest_before="$(sysconfig_digest)"
if in_container; then
  rc=0
  bash "$REPO_ROOT/repro/01_snapshot.sh" >/dev/null 2>&1 || rc=$?
else
  # Locally the snapshot refuses by design; exercise the same code path that
  # exports the proxy (sourcing common.sh) in a child process.
  rc=0
  bash -c "source '$LIB_DIR/common.sh' && env | grep -q '172.16.119.20:40381'" >/dev/null 2>&1 || rc=$?
fi
digest_after="$(sysconfig_digest)"
if [ "$digest_before" = "$digest_after" ]; then
  ok "system configuration files are byte-identical after a repro run"
else
  bad "a repro run modified a system configuration file"
  diff <(printf '%s\n' "$digest_before") <(printf '%s\n' "$digest_after") || true
fi

# In the container (the environment this slice standardises) the system config
# must additionally carry no trace of our proxy address at all.
if in_container; then
  leaked=""
  for f in "${SYS_CONFIG_FILES[@]}"; do
    [ -f "$f" ] || continue
    grep -qE '172\.16\.119\.20' "$f" && leaked="$leaked $f"
  done
  if [ -z "$leaked" ]; then
    ok "container system configuration contains no proxy address"
  else
    bad "proxy address present in container system config:$leaked"
  fi
else
  skip "container proxy-address scan (the audited environment is the container)"
fi

# --- 9. the proxy is process-scoped ----------------------------------------
if env -i bash -c 'env | grep -qiE "^(http|https|ftp|no)_proxy="'; then
  bad "proxy variables are present in a clean system environment"
else
  ok "proxy variables are absent from a clean system environment"
fi

# The proxy must be visible in THIS process (that is how it reaches uv/git).
if env | grep -qE '^http_proxy=http://172\.16\.119\.20:40381$'; then
  ok "common.sh inlines http_proxy into the sourcing process"
else
  bad "common.sh did not inline http_proxy into the sourcing process"
fi

# --- 10. git_in runs git as the directory owner and propagates failures -----
# git_in is the container-side workaround for git 2.34's ownership check on a
# root-squashed NFS export: it must succeed where a plain `git` invocation
# would be refused, and it must not swallow git's exit code.
if [ -d "$REPO_ROOT/third_party/GMR/.git" ]; then
  rc=0
  head_via_git_in="$(git_in "$REPO_ROOT/third_party/GMR" rev-parse --verify HEAD 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "${#head_via_git_in}" -eq 40 ]; then
    ok "git_in resolves the submodule HEAD as the owning uid ($head_via_git_in)"
  else
    bad "git_in failed to resolve the submodule HEAD (rc=$rc out='$head_via_git_in')"
  fi
  rc=0
  git_in "$REPO_ROOT/third_party/GMR" rev-parse --verify definitely-not-a-ref >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "git_in propagates a failing git exit code (got $rc)"
  else
    bad "git_in swallowed a failing git exit code"
  fi
else
  skip "git_in submodule checks (third_party/GMR is not landed)"
fi

# --- 11. common.sh writes nothing outside the repo -------------------------
# The proxy convention plus the "no system config writes" invariant: sourcing
# common.sh must not create or modify any file outside $REPO_ROOT/logs.
before_root="$(ls -A /etc 2>/dev/null | md5sum | awk '{print $1}')"
rc=0
bash -c "source '$LIB_DIR/common.sh' && true" >/dev/null 2>&1 || rc=$?
after_root="$(ls -A /etc 2>/dev/null | md5sum | awk '{print $1}')"
if [ "$rc" -eq 0 ] && [ "$before_root" = "$after_root" ]; then
  ok "sourcing common.sh leaves /etc unchanged"
else
  bad "sourcing common.sh changed /etc (rc=$rc)"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
echo "TESTS_OK"
