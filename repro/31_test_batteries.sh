#!/usr/bin/env bash
# repro/31_test_batteries.sh — 跑完所有**离线**测试电池，把结果落到持久 store。
#
# WHY
#   The batteries are the evidence that the re-runnable scripts still behave.
#   Their output used to live only in the agent's session (a .gsd/exec file
#   inside the worktree) — which disappears with the next worktree rebuild.
#   A regression that is not written down is a regression nobody notices.
#
#   This script runs the batteries, writes their output to
#   logs/env/31_test_batteries.txt (inside the persistent store) and ends
#   with a machine-greppable verdict:
#
#     TEST_BATTERIES_OK suites=<n>
#     TEST_BATTERIES_FAIL reason=suite-failed suite=<name>
#
#   usage: bash repro/31_test_batteries.sh
#
#   The batteries are OFFLINE (no network, no GPU, no payload) and take
#   seconds; they must run on the host, not in the container.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="$REPO_ROOT/logs/env"
[ -d "$LOG_DIR" ] || LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
OUT="$LOG_DIR/31_test_batteries.txt"

# suite | expected verdict substring in the battery's own output
SUITES=(
  "test_store_guard.sh|PASS=30 FAIL=0"
  "test_doc_verify.sh|PASS=100 FAIL=0"
  "test_seed_npz.sh|PASS=35 FAIL=0"
  "test_seed_human.sh|PASS=36 FAIL=0"
  "test_seed_npz_verify.sh|13 passed, 0 failed"
  "test_00_env.sh|TESTS_OK"
  "test_toolchain.sh|TESTS_OK"
)

{
  echo "# 离线测试电池汇总（repro/31_test_batteries.sh）"
  echo "# 时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# 说明：全部为离线电池（无网络 / 无 GPU / 无载荷），运行在宿主侧。"
  echo
} >"$OUT"

failed=0
count=0
for row in "${SUITES[@]}"; do
  suite="${row%%|*}"
  expect="${row#*|}"
  count=$((count + 1))
  {
    echo "===== $suite (expect: $expect) ====="
    echo "command: bash repro/tests/$suite"
  } >>"$OUT"
  out="$(bash "repro/tests/$suite" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | tail -12 >>"$OUT"
  {
    echo "exit code: $rc"
    echo
  } >>"$OUT"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qF "$expect"; then
    printf 'SUITE %s FAILED (rc=%s, expected "%s")\n' "$suite" "$rc" "$expect"
    failed=1
  else
    printf 'SUITE %s OK\n' "$suite"
  fi
done

# the python battery
count=$((count + 1))
{
  echo "===== test_doc.py (expect: OK) ====="
  echo "command: python3 repro/tests/test_doc.py"
} >>"$OUT"
out="$(python3 repro/tests/test_doc.py 2>&1)"
rc=$?
printf '%s\n' "$out" | tail -6 >>"$OUT"
{
  echo "exit code: $rc"
  echo
} >>"$OUT"
if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -q '^OK$'; then
  printf 'SUITE test_doc.py FAILED (rc=%s)\n' "$rc"
  failed=1
else
  printf 'SUITE test_doc.py OK\n'
fi

{
  echo "TEST_BATTERIES_$([ "$failed" -ne 0 ] && echo FAIL || echo OK) suites=$count"
} >>"$OUT"

if [ "$failed" -ne 0 ]; then
  echo "TEST_BATTERIES_FAIL reason=suite-failed suites=$count"
  exit 1
fi
echo "TEST_BATTERIES_OK suites=$count"
exit 0
