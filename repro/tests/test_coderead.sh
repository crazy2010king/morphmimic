#!/usr/bin/env bash
# repro/tests/test_coderead.sh — offline unit tests for the module coverage
# gate (repro/lib/coderead.sh) and for the record format of
# docs/code_read/CODE_MAP.md.
#
# The tests are pure-local: they build throwaway fixture trees and fixture
# record files under $TMPDIR, so they need neither network, GPU, container
# nor a real venv.  The only test that touches the real repository is the
# last one (the real record must cover the real modules) — it is a pure
# filesystem read.
#
# Covered failure surfaces:
#   1. discovery rules: README.md + src/morphmimic + deploy + tools/
#      soma_retargeter are in, __init__.py / __pycache__ / assets /
#      third_party/ are out
#   2. a record that covers everything  -> exit 0, MODULES_MISSING_0
#   3. a record that misses a module   -> non-zero exit + "MISSING <path>"
#   4. a record with a ghost entry     -> warning only, still exit 0
#   5. a record row without a duty     -> non-zero exit + "EMPTY_DUTY <path>"
#   6. path normalisation: "./x", backticks and whitespace must match "x"
#   7. the real repository: 103 modules, all covered by the real record
#
# Run locally:  bash repro/tests/test_coderead.sh
# Run remotely: bash repro/lib/remote.sh tests/test_coderead.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# shellcheck source=repro/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=repro/lib/coderead.sh
source "$LIB_DIR/coderead.sh"

# common.sh turns on `errexit`; this file drives commands that are EXPECTED
# to fail, so switch it back off for the assertions below.
set +e

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixture repository ----------------------------------------------------
FIX="$TMP/repo"
mkdir -p "$FIX/src/morphmimic/pkg" "$FIX/src/morphmimic/pkg/__pycache__" \
         "$FIX/deploy/sub" "$FIX/deploy/sub/__pycache__" \
         "$FIX/tools/soma_retargeter/sub" \
         "$FIX/third_party/GMR" "$FIX/data"
printf 'x\n' >"$FIX/README.md"
printf 'x\n' >"$FIX/src/morphmimic/pkg/mod_a.py"
printf 'x\n' >"$FIX/src/morphmimic/pkg/mod_b.py"
printf 'x\n' >"$FIX/src/morphmimic/pkg/__init__.py"
printf 'x\n' >"$FIX/src/morphmimic/pkg/__pycache__/mod_c.py"
printf 'x\n' >"$FIX/deploy/run.py"
printf 'x\n' >"$FIX/deploy/install.sh"
printf 'x\n' >"$FIX/deploy/README.md"
printf 'x\n' >"$FIX/deploy/__init__.py"
printf 'x\n' >"$FIX/deploy/sub/deep.py"
printf 'x\n' >"$FIX/deploy/sub/__pycache__/deep2.py"
printf 'x\n' >"$FIX/tools/soma_retargeter/tool.py"
printf 'x\n' >"$FIX/tools/soma_retargeter/tool.sh"
printf 'x\n' >"$FIX/tools/soma_retargeter/sub/not_top_level.py"
printf 'x\n' >"$FIX/tools/soma_retargeter/batch.json"
printf 'x\n' >"$FIX/third_party/GMR/upstream.py"
printf 'x\n' >"$FIX/data/clip.json"

# --- 1. discovery rules ----------------------------------------------------
scan_out="$(coderead_scan_modules "$FIX")"
expected="README.md
deploy/README.md
deploy/install.sh
deploy/run.py
deploy/sub/deep.py
src/morphmimic/pkg/mod_a.py
src/morphmimic/pkg/mod_b.py
tools/soma_retargeter/tool.py
tools/soma_retargeter/tool.sh"

if [ "$scan_out" = "$expected" ]; then
  ok "discovery rules: exactly the coverage set is scanned"
else
  bad "discovery rules: unexpected scan result"
  printf '  expected:\n%s\n  got:\n%s\n' "$expected" "$scan_out"
fi

for excluded in "__init__.py" "__pycache__" "third_party/" "batch.json" "clip.json" "not_top_level"; do
  if printf '%s\n' "$scan_out" | grep -q "$excluded"; then
    bad "discovery rules: '$excluded' must not be scanned"
  else
    ok "discovery rules: '$excluded' is excluded"
  fi
done

# --- record fixtures -------------------------------------------------------
# A complete record for the fixture repository.
REC_FULL="$TMP/record_full.md"
cat >"$REC_FULL" <<'EOF'
# fixture record

<!-- CODE_READ_MODULE_TABLE_START -->
| 路径 | 职责 | 调用链 | 入口 | 关系 | 切片 |
|---|---|---|---|---|---|
| `README.md` | 仓库说明 | — | — | 基础 | S02 |
| `src/morphmimic/pkg/mod_a.py` | 模块 A | mod_a -> mod_b | `python -m mod_a` | 基础 | S04 |
| `src/morphmimic/pkg/mod_b.py` | 模块 B | mod_a -> mod_b | `python -m mod_b` | 基础 | S04 |
| `deploy/run.py` | 部署入口 | run -> policy_node | `python deploy/run.py` | 基础 | S08 |
| `deploy/install.sh` | 安装脚本 | — | `bash deploy/install.sh` | 基础 | S08 |
| `deploy/README.md` | 部署说明 | — | — | 基础 | S08 |
| `deploy/sub/deep.py` | 子目录模块 | deep -> run | `python deploy/sub/deep.py` | 基础 | S08 |
| `tools/soma_retargeter/tool.py` | 工具 | tool -> deep | `python tools/soma_retargeter/tool.py` | 基础 | S04 |
| `tools/soma_retargeter/tool.sh` | 工具脚本 | — | `bash tools/soma_retargeter/tool.sh` | 基础 | S04 |
<!-- CODE_READ_MODULE_TABLE_END -->
EOF

MODULES_FILE="$TMP/modules.txt"
coderead_scan_modules "$FIX" >"$MODULES_FILE"

# --- 2. a complete record passes ------------------------------------------
out="$(coderead_compare "$MODULES_FILE" "$REC_FULL")"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a complete record passes (exit 0)"
else
  bad "a complete record must pass (exit $rc): $out"
fi
if printf '%s\n' "$out" | grep -qx "MODULES_MISSING_0"; then
  ok "a complete record reports MODULES_MISSING_0"
else
  bad "a complete record must report MODULES_MISSING_0: $out"
fi
if printf '%s\n' "$out" | grep -qx "MODULES_TOTAL_9"; then
  ok "the fixture repository has 9 modules"
else
  bad "the fixture repository must have 9 modules: $out"
fi

# --- 3. a missing module fails and is listed -------------------------------
REC_MISSING="$TMP/record_missing.md"
grep -v 'mod_b.py' "$REC_FULL" >"$REC_MISSING"
out="$(coderead_compare "$MODULES_FILE" "$REC_MISSING")"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a missing module makes the comparison fail"
else
  bad "a missing module must make the comparison fail: $out"
fi
if printf '%s\n' "$out" | grep -qx "MISSING src/morphmimic/pkg/mod_b.py"; then
  ok "the missing module is listed (MISSING <path>)"
else
  bad "the missing module must be listed: $out"
fi
if printf '%s\n' "$out" | grep -qx "MODULES_MISSING_1"; then
  ok "the missing module is counted (MODULES_MISSING_1)"
else
  bad "the missing module must be counted: $out"
fi

# --- 4. a ghost entry is a warning, not a failure --------------------------
REC_GHOST="$TMP/record_ghost.md"
# the ghost row goes INSIDE the module table (a record entry for a module that
# does not exist on disk any more)
awk '{ if ($0 ~ /CODE_READ_MODULE_TABLE_END/) print "| `src/morphmimic/pkg/ghost.py` | 已经删除的模块 | — | — | — | S04 |"; print }' \
  "$REC_FULL" >"$REC_GHOST"
out="$(coderead_compare "$MODULES_FILE" "$REC_GHOST")"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a ghost entry only warns (exit 0)"
else
  bad "a ghost entry must only warn (exit $rc): $out"
fi
if printf '%s\n' "$out" | grep -qx "STALE src/morphmimic/pkg/ghost.py"; then
  ok "the ghost entry is reported (STALE <path>)"
else
  bad "the ghost entry must be reported: $out"
fi
if printf '%s\n' "$out" | grep -qx "MODULES_STALE_1"; then
  ok "the ghost entry is counted (MODULES_STALE_1)"
else
  bad "the ghost entry must be counted: $out"
fi

# --- 5. an empty responsibility fails --------------------------------------
REC_EMPTY="$TMP/record_empty.md"
sed 's/| `src\/morphmimic\/pkg\/mod_a.py` | 模块 A |/| `src\/morphmimic\/pkg\/mod_a.py` | |/' \
  "$REC_FULL" >"$REC_EMPTY"
out="$(coderead_compare "$MODULES_FILE" "$REC_EMPTY")"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an empty responsibility makes the comparison fail"
else
  bad "an empty responsibility must make the comparison fail: $out"
fi
if printf '%s\n' "$out" | grep -qx "EMPTY_DUTY src/morphmimic/pkg/mod_a.py"; then
  ok "the empty responsibility is listed (EMPTY_DUTY <path>)"
else
  bad "the empty responsibility must be listed: $out"
fi

# a placeholder is not a responsibility either
REC_PLACEHOLDER="$TMP/record_placeholder.md"
sed 's/| `src\/morphmimic\/pkg\/mod_a.py` | 模块 A |/| `src\/morphmimic\/pkg\/mod_a.py` | - |/' \
  "$REC_FULL" >"$REC_PLACEHOLDER"
out="$(coderead_compare "$MODULES_FILE" "$REC_PLACEHOLDER")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qx "EMPTY_DUTY src/morphmimic/pkg/mod_a.py"; then
  ok "a placeholder ('-') is not a responsibility"
else
  bad "a placeholder ('-') must not count as a responsibility: $out"
fi

# --- 6. path normalisation -------------------------------------------------
REC_NORMALISED="$TMP/record_normalised.md"
sed -e 's|`README.md`|  ./README.md  |' -e 's|`deploy/run.py`|`./deploy/run.py`|' \
  "$REC_FULL" >"$REC_NORMALISED"
out="$(coderead_compare "$MODULES_FILE" "$REC_NORMALISED")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "MODULES_MISSING_0"; then
  ok "paths are normalised ('./x' and backticks match 'x')"
else
  bad "paths must be normalised: $out"
fi

# --- 7. the real repository ------------------------------------------------
real_modules="$TMP/real_modules.txt"
coderead_scan_modules "$REPO_ROOT" >"$real_modules"
real_total="$(wc -l <"$real_modules" | tr -d ' ')"
if [ "$real_total" = "103" ]; then
  ok "the real repository has 103 modules"
else
  bad "the real repository must have 103 modules, has $real_total"
fi

REAL_RECORD="$REPO_ROOT/docs/code_read/CODE_MAP.md"
if [ ! -f "$REAL_RECORD" ]; then
  bad "the real read record does not exist: $REAL_RECORD"
else
  out="$(coderead_compare "$real_modules" "$REAL_RECORD")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "the real read record covers every module of the real repository"
  else
    bad "the real read record does not cover every module: $out"
  fi
  if printf '%s\n' "$out" | grep -qx "MODULES_MISSING_0"; then
    ok "the real read record reports MODULES_MISSING_0"
  else
    bad "the real read record must report MODULES_MISSING_0: $out"
  fi
  if printf '%s\n' "$out" | grep -qx "MODULES_EMPTY_DUTY_0"; then
    ok "every recorded module carries a responsibility"
  else
    bad "every recorded module must carry a responsibility: $out"
  fi
fi

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "TESTS_FAILED"
  exit 1
fi
echo "TESTS_OK"
exit 0
