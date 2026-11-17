#!/usr/bin/env bash
# repro/tests/test_proxy_hygiene_e2e.sh — end-to-end tests of
# repro/05_proxy_hygiene.sh INSIDE the remote ros_dev container.
#
#   bash repro/lib/remote.sh tests/test_proxy_hygiene_e2e.sh
#
# It covers the paths the local unit test cannot:
#   1. the script runs in the container and passes on the real system state
#      (PROXY_HYGIENE_OK + PROXY_HYGIENE_SELFTEST_OK);
#   2. the script FAILS (non-zero exit, PROXY_HYGIENE_FAIL) when the scan
#      target list points at a fixture that contains a proxy trace — the
#      failure path of the gate itself;
#   3. `--self-test` only runs the detector self-test and never touches a
#      system configuration file.
#
# The failure-path fixture lives in a temporary directory; no real system
# configuration file is ever written or modified.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/repro/05_proxy_hygiene.sh"

failures=0
checks=0

check() {  # check <description> <0|1 ok> [detail]
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 ${3:-}"
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/proxy_hygiene_e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- 1. the happy path on the real system state -----------------------------
log_normal="$WORK/normal.log"
rc=0
bash "$SCRIPT_UNDER_TEST" --log-file "$log_normal" > "$WORK/normal.out" 2>&1 || rc=$?
check "the hygiene script exits 0 on the real system state" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc"
check "the normal run reports PROXY_HYGIENE_OK" "$(grep -q '^PROXY_HYGIENE_OK$' "$log_normal" && echo 0 || echo 1)"
check "the normal run reports PROXY_HYGIENE_SELFTEST_OK" "$(grep -q '^PROXY_HYGIENE_SELFTEST_OK$' "$log_normal" && echo 0 || echo 1)"
check "the normal run scans at least one real system file" "$(grep -q '^SCAN FILE /etc/environment$' "$log_normal" && echo 0 || echo 1)"
check "the normal run finds no polluted target" "$(grep -q '^POLLUTED_TARGETS_0$' "$log_normal" && echo 0 || echo 1)"
check "the normal run confirms a proxy-free clean environment" "$(grep -q '^CLEAN_ENV_NO_PROXY_OK' "$log_normal" && echo 0 || echo 1)"
check "the normal run confirms a proxy-free container init env" "$(grep -q '^CONTAINER_INIT_NO_PROXY_OK' "$log_normal" && echo 0 || echo 1)"

# --- 2. the failure path ----------------------------------------------------
printf 'http_proxy=http://172.16.119.20:40381\n' > "$WORK/dirty.conf"
printf '%s\n' "$WORK/dirty.conf" > "$WORK/targets.txt"
log_dirty="$WORK/dirty.log"
rc=0
bash "$SCRIPT_UNDER_TEST" --targets-file "$WORK/targets.txt" --log-file "$log_dirty" \
  > "$WORK/dirty.out" 2>&1 || rc=$?
check "the hygiene script exits non-zero when a proxy trace is found" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "rc=$rc"
check "the failing run reports PROXY_HYGIENE_FAIL" "$(grep -q '^PROXY_HYGIENE_FAIL$' "$log_dirty" && echo 0 || echo 1)"
check "the failing run does NOT report PROXY_HYGIENE_OK" "$([ "$(grep -c '^PROXY_HYGIENE_OK$' "$log_dirty")" -eq 0 ] && echo 0 || echo 1)"
check "the failing run names the offending file and line" "$(grep -q "ADDR $WORK/dirty.conf:1:" "$log_dirty" && echo 0 || echo 1)"
check "the failing run still passes the detector self-test" "$(grep -q '^PROXY_HYGIENE_SELFTEST_OK$' "$log_dirty" && echo 0 || echo 1)"

# --- 3. --self-test only ----------------------------------------------------
log_selftest="$WORK/selftest.log"
rc=0
bash "$SCRIPT_UNDER_TEST" --self-test --log-file "$log_selftest" > "$WORK/selftest.out" 2>&1 || rc=$?
check "--self-test exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc"
check "--self-test reports PROXY_HYGIENE_SELFTEST_OK" "$(grep -q '^PROXY_HYGIENE_SELFTEST_OK$' "$log_selftest" && echo 0 || echo 1)"
check "--self-test does not scan any system configuration file" "$([ "$(grep -c '^SCAN ' "$log_selftest")" -eq 0 ] && echo 0 || echo 1)"
check "--self-test does not report PROXY_HYGIENE_OK" "$([ "$(grep -c '^PROXY_HYGIENE_OK$' "$log_selftest")" -eq 0 ] && echo 0 || echo 1)"

# --- 4. the real system state was not modified by the tests -----------------
# The fixture runs must not have written anything into the real targets.
for real in /etc/environment /etc/profile /root/.bashrc /root/.profile /etc/gitconfig; do
  [ -f "$real" ] || continue
  if grep -qiF -- '172.16.119.20' "$real"; then
    check "$real stayed free of the proxy address" 1 "found the proxy address in $real"
  else
    check "$real stayed free of the proxy address" 0
  fi
done

echo "checks=$checks failures=$failures"
if [ "$failures" -ne 0 ]; then
  echo "TESTS_FAILED"
  exit 1
fi
echo "TESTS_OK"
