#!/usr/bin/env bash
# repro/tests/test_doc_verify.sh — the OFFLINE battery of the reproduction
# record verifier (repro/28_doc_verify.sh, slice S09 task T2).
#
# The battery drives the REAL verifier with FAKE artefacts: a compliant
# record (nine chapters, the front-matter declaration, the deviation list,
# the three unexecuted items, the evidence index table), two eval CSVs, a
# comparison table, a training curve CSV, two policy directories with real
# SHA256SUMS, and a published mirror.  Every artefact is written with the
# plain python3 (stdlib only), so neither the container, nor a GPU, nor the
# real seed store are needed.
#
# Every negative scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# The decisions themselves are NOT stubbed: the chapter contract, the
# evidence index table, the SHA-256 recomputation, the eval row count and
# the recomputed completion, the comparison table, the training curve
# coverage and the plaintext-token scan are all decided by the real
# decision base (repro/lib/doc.py).
#
# usage: bash repro/tests/test_doc_verify.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$REPO_ROOT/repro/28_doc_verify.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '     %s\n' "$2"
  return 0
}

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi
}
assert_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing=[$3] in=[$2]" ;;
  esac
}
assert_not_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) fail "$1" "unexpected=[$3] in=[$2]" ;;
    *) pass "$1" ;;
  esac
}
assert_rc_zero() { # <label> <rc>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "rc=$2"; fi
}
assert_rc_nonzero() { # <label> <rc>
  if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "rc=0"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="$TMP/base"
WORK="$TMP/work"

# ---------------------------------------------------------------------------
# the fixture
# ---------------------------------------------------------------------------
build_fixture() { # <root>
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  python3 - "$root" <<'PY'
import hashlib, os, sys

root = sys.argv[1]
RECORD = "MorphMimic完整复现记录.md"
EVAL_ROWS = 3
COMPARE_ROWS = 2
CURVE_MIN_STEP = 50
CURVE_MAX_STEP = 26413


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def digest(path):
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        sha.update(handle.read())
    return sha.hexdigest()


# --- the evidence files ---------------------------------------------------
write(root + "/logs/env/evidence_env.txt", "GPU_RTX_4090\nMEM_TOTAL_GB=245\n")
write(root + "/logs/env/evidence_train.txt",
      "TRAIN_CURVES_OK events_files=10 tags=52 rows=28120 steps=26413\n")
write(root + "/logs/env/evidence_eval.txt", "EVAL_VERIFY_OK eval_rows=3\n")

# --- the exported policy + its digests ------------------------------------
for directory in ("out/g1_amber", "runs/official/morphmimic_policy"):
    base = root + "/" + directory
    write(base + "/policy.onnx", "fake-onnx-bytes\n")
    write(base + "/g1_amber.json", '{"robot": "g1_amber"}\n')
    lines = []
    for name in ("g1_amber.json", "policy.onnx"):
        lines.append("%s  %s" % (digest(base + "/" + name), name))
    write(base + "/SHA256SUMS", "\n".join(lines) + "\n")

# --- the eval tables -------------------------------------------------------
header = "name,frames,failed,fail_frame,norm_return,steps\n"
for name in ("eval_motion_1h.csv", "eval_human_full_1h.csv"):
    rows = []
    for index in range(EVAL_ROWS):
        rows.append("clip_%02d__A000,%d,False,-1,0.5,%d\n"
                    % (index, 100 + index, 99 + index))
    write(root + "/runs/eval/" + name, header + "".join(rows))

# --- the comparison table --------------------------------------------------
compare_header = ("clip,frames,self_result,self_joint_err_rms_rad,"
                  "self_body_err_mean_m,self_end_drift_m,official_result,"
                  "official_joint_err_rms_rad,official_body_err_mean_m,"
                  "official_end_drift_m,delta_joint_err_rms_rad,"
                  "delta_body_err_mean_m,delta_end_drift_m\n")
compare_rows = []
for index in range(COMPARE_ROWS):
    mine = 0.1 + 0.01 * index
    theirs = 0.2 + 0.01 * index
    compare_rows.append(
        "clip_%02d,100,completed,%f,%f,%f,completed,%f,%f,%f,%f,%f,%f\n"
        % (index, mine, mine, mine, theirs, theirs, theirs,
           mine - theirs, mine - theirs, mine - theirs))
write(root + "/runs/official/compare_self_vs_official.csv",
      compare_header + "".join(compare_rows))

# --- the training curve ----------------------------------------------------
curve = ["step,tag,value\n"]
for step in (CURVE_MIN_STEP, CURVE_MAX_STEP):
    curve.append("%d,wm/state_loss,0.5\n" % step)
write(root + "/runs/train_curves/g1_amber_1h_curves.csv", "".join(curve))

# --- the record -----------------------------------------------------------
means = {}
rows = []
for line in compare_header.strip().splitlines():
    rows.append(line)
raw = open(root + "/runs/official/compare_self_vs_official.csv",
           encoding="utf-8").read().splitlines()
header_cells = raw[0].split(",")
for metric in ("joint_err_rms_rad", "body_err_mean_m", "end_drift_m"):
    index = header_cells.index("delta_" + metric)
    values = [float(line.split(",")[index]) for line in raw[1:]]
    means[metric] = sum(values) / float(len(values))

body = []
body.append("# MorphMimic 完整复现记录\n")
body.append("\n**流程复现，非数值等价复现**。\n")
body.append("\n<!-- DOC_SECTION:1 -->\n## 1. 环境事实表\n\n正文\n")
body.append("<!-- /DOC_SECTION:1 -->\n")
body.append("\n<!-- DOC_SECTION:2 -->\n## 2. 每阶段命令原文与关键输出\n\n正文\n")
body.append("<!-- /DOC_SECTION:2 -->\n")
body.append("\n<!-- DOC_SECTION:3 -->\n## 3. 对 README 的偏离清单\n\n")
body.append("| 序号 | README 原文 | 我们的做法 | 原因 | 代价 |\n")
body.append("|---|---|---|---|---|\n")
for index in range(20):
    body.append("| %d | README 原文 | 我们的做法 | 原因 | 代价 |\n" % (index + 1))
body.append("<!-- /DOC_SECTION:3 -->\n")
body.append("\n<!-- DOC_SECTION:4 -->\n## 4. 已分析未执行清单\n\n")
body.append("| 项 | 已分析到的内容 | 为何未执行 |\n|---|---|---|\n")
body.append("| PICO 头显实机佩戴 | 佩戴流程 | 无头显 |\n")
body.append("| 真机 G1 物理联调 | 联调接口 | 无真机 |\n")
body.append("| 官方 x2-t2 对照 | 对照口径 | 官方无权重 |\n")
body.append("<!-- /DOC_SECTION:4 -->\n")
body.append("\n<!-- DOC_SECTION:5 -->\n## 5. 产物路径与 SHA-256\n\n正文\n")
body.append("<!-- /DOC_SECTION:5 -->\n")
body.append("\n<!-- DOC_SECTION:6 -->\n## 6. 训练曲线数据\n\n正文\n")
body.append("<!-- /DOC_SECTION:6 -->\n")
body.append("\n<!-- DOC_SECTION:7 -->\n## 7. eval 对照表\n\n")
body.append("| 指标 | Δ 均值 |\n|---|---|\n")
for metric in ("joint_err_rms_rad", "body_err_mean_m", "end_drift_m"):
    body.append("| %s | %.6f |\n" % (metric, means[metric]))
body.append("<!-- /DOC_SECTION:7 -->\n")
body.append("\n<!-- DOC_SECTION:8 -->\n## 8. 踩坑记录\n\n正文\n")
body.append("<!-- /DOC_SECTION:8 -->\n")
body.append("\n<!-- DOC_SECTION:9 -->\n## 9. 明文 token 撤销提醒\n\n正文\n")
body.append("<!-- /DOC_SECTION:9 -->\n")
body.append("\n<!-- DOC_EVIDENCE_TABLE_START -->\n")
body.append("| 结论 | 复现命令 | 证据文件（相对仓库根） | 关键输出 |\n")
body.append("|---|---|---|---|\n")
body.append("| 环境为 RTX 4090 | bash repro/00_env.sh | "
            "logs/env/evidence_env.txt | GPU_RTX_4090 |\n")
body.append("| 训练止于 26413 迭代 | bash repro/27_train_curves.sh verify | "
            "logs/env/evidence_train.txt | TRAIN_CURVES_OK |\n")
body.append("| eval 两接口 490 行 | bash repro/23_eval.sh | "
            "logs/env/evidence_eval.txt | EVAL_VERIFY_OK |\n")
body.append("<!-- DOC_EVIDENCE_TABLE_END -->\n")
text = "".join(body)
write(root + "/docs/code_read/" + RECORD, text)
write(root + "/docs/code_doc/" + RECORD, text)
PY
}

# ---------------------------------------------------------------------------
# running the verifier against a fixture
# ---------------------------------------------------------------------------
run_verify() { # <root> [subcommand]
  local root="$1"
  local subcommand="${2:-verify}"
  local out rc
  out="$(DOC_REPO_ROOT="$root" \
    DOC_EXPECT_EVAL_ROWS=3 \
    DOC_EXPECT_COMPARE_ROWS=2 \
    DOC_EXPECT_CURVE_MIN_STEP=50 \
    DOC_EXPECT_CURVE_MAX_STEP=26413 \
    DOC_EXPECT_COMPLETION=1.0 \
    DOC_MIN_DEVIATIONS=20 \
    DOC_LOG_DIR="$root/logs/env" \
    bash "$VERIFIER" "$subcommand" 2>&1)"
  rc=$?
  OUT="$out"
  RC=$rc
}

# negative_case <label> <expected reason> <mutation function>
negative_case() {
  local label="$1"
  local reason="$2"
  local mutation="$3"
  rm -rf "$WORK"
  cp -r "$BASE" "$WORK"
  "$mutation" "$WORK"
  run_verify "$WORK" verify
  assert_rc_nonzero "$label exits non-zero" "$RC"
  assert_contains "$label reports reason=$reason" "$OUT" "reason=$reason"
  assert_not_contains "$label prints no OK marker" "$OUT" "DOC_VERIFY_OK"
  assert_not_contains "$label prints no mirror marker" "$OUT" "DOC_MIRROR_OK"
}

# ---------------------------------------------------------------------------
# the mutations
# ---------------------------------------------------------------------------
mut_missing_doc() { rm -f "$1/docs/code_read/MorphMimic完整复现记录.md"; }
mut_empty_doc() { : >"$1/docs/code_read/MorphMimic完整复现记录.md"; }
mut_missing_section() {
  python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("<!-- DOC_SECTION:4 -->", "").replace("<!-- /DOC_SECTION:4 -->", "")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_missing_evidence_table() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("<!-- DOC_EVIDENCE_TABLE_START -->", "")
text = text.replace("<!-- DOC_EVIDENCE_TABLE_END -->", "")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_missing_evidence_path() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("logs/env/evidence_env.txt", "logs/env/no-such-evidence.txt")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_evidence_marker_mismatch() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("| GPU_RTX_4090 |", "| GPU_RTX_5090_NOT_IN_THE_FILE |")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_sha_mismatch() {
  printf 'tampered\n' >>"$1/out/g1_amber/policy.onnx"
}
mut_sha_missing() { rm -f "$1/out/g1_amber/SHA256SUMS"; }
mut_eval_row_count() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/runs/eval/eval_motion_1h.csv"
lines = open(path, encoding="utf-8").read().splitlines()
open(path, "w", encoding="utf-8").write("\n".join(lines[:-1]) + "\n")
PY
}
mut_eval_missing() { rm -f "$1/runs/eval/eval_motion_1h.csv"; }
mut_completion_mismatch() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/runs/eval/eval_motion_1h.csv"
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(",False,-1,", ",True,7,", 1))
PY
}
mut_compare_row_count() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/runs/official/compare_self_vs_official.csv"
lines = open(path, encoding="utf-8").read().splitlines()
open(path, "w", encoding="utf-8").write("\n".join(lines[:-1]) + "\n")
PY
}
mut_compare_delta_wrong() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("| joint_err_rms_rad | -0.100000 |",
                    "| joint_err_rms_rad | 0.000000 |")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_curve_missing() { rm -f "$1/runs/train_curves/g1_amber_1h_curves.csv"; }
mut_curve_step_missing() {
  printf 'step,tag,value\n50,wm/state_loss,0.5\n' \
    >"$1/runs/train_curves/g1_amber_1h_curves.csv"
}
mut_token_leaked() {
  printf '\n令牌：hf_abcdefghij0123456789ABCDEF\n' \
    >>"$1/docs/code_read/MorphMimic完整复现记录.md"
}
mut_missing_process_declaration() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("**流程复现，非数值等价复现**", "只是一份记录")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_missing_unexecuted_list() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("PICO 头显实机佩戴", "头显佩戴")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_missing_deviation_list() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1] + "/docs/code_read/MorphMimic完整复现记录.md"
text = open(path, encoding="utf-8").read()
text = text.replace("| 20 | README 原文 | 我们的做法 | 原因 | 代价 |\n", "")
open(path, "w", encoding="utf-8").write(text)
PY
}
mut_mirror_missing() { rm -f "$1/docs/code_doc/MorphMimic完整复现记录.md"; }
mut_mirror_mismatch() {
  printf '\ndifferent\n' >>"$1/docs/code_doc/MorphMimic完整复现记录.md"
}

# ---------------------------------------------------------------------------
# the positive case
# ---------------------------------------------------------------------------
build_fixture "$BASE"
run_verify "$BASE" verify
assert_rc_zero "the positive fixture exits 0" "$RC"
assert_contains "the positive fixture prints the OK marker" "$OUT" "DOC_VERIFY_OK"
assert_contains "the OK marker reports the chapter count" "$OUT" "sections=9"
assert_contains "the OK marker reports the evidence rows" "$OUT" "evidence_rows=3"
assert_contains "the OK marker reports the recomputed digests" "$OUT" "sha_ok=1"
assert_contains "the OK marker reports the eval rows" "$OUT" "eval_rows=3"
assert_contains "the OK marker reports the comparison rows" "$OUT" "compare_rows=2"
assert_contains "the OK marker reports the curve rows" "$OUT" "curve_rows=2"
assert_eq "the positive fixture prints exactly one OK marker" "1" \
  "$(printf '%s\n' "$OUT" | grep -c '^DOC_VERIFY_OK ')"

# the mirror of a healthy fixture
run_verify "$BASE" mirror
assert_rc_zero "the healthy mirror exits 0" "$RC"
assert_contains "the healthy mirror prints the OK marker" "$OUT" "DOC_MIRROR_OK mirror_match=1"

# the report sub-command prints the facts, never the gate marker
run_verify "$BASE" report
assert_contains "the report prints the eval line" "$OUT" "DOC_REPORT_EVAL"
assert_contains "the report prints the compare line" "$OUT" "DOC_REPORT_COMPARE"
assert_contains "the report prints the curve line" "$OUT" "DOC_REPORT_CURVE"
assert_not_contains "the report prints no gate marker" "$OUT" "DOC_VERIFY_OK"

# the verifier never writes into the artefacts it inspects
BEFORE="$(find "$BASE" -type f ! -path '*/logs/*' -printf '%p %s\n' | sort | md5sum)"
run_verify "$BASE" verify
AFTER="$(find "$BASE" -type f ! -path '*/logs/*' -printf '%p %s\n' | sort | md5sum)"
assert_eq "the verifier does not touch the artefacts" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
# the negative battery
# ---------------------------------------------------------------------------
negative_case "the record is missing" "doc-missing" mut_missing_doc
negative_case "the record is empty" "doc-empty" mut_empty_doc
negative_case "a chapter is missing" "section-missing" mut_missing_section
negative_case "the evidence table is missing" "evidence-table-missing" \
  mut_missing_evidence_table
negative_case "an evidence file does not exist" "evidence-path-missing" \
  mut_missing_evidence_path
negative_case "an evidence key output does not match" "evidence-marker-missing" \
  mut_evidence_marker_mismatch
negative_case "a digest does not match" "sha-mismatch" mut_sha_mismatch
negative_case "the SHA256SUMS is missing" "sha-missing" mut_sha_missing
negative_case "the eval row count differs" "eval-row-count-mismatch" \
  mut_eval_row_count
negative_case "the eval table is missing" "eval-csv-missing" mut_eval_missing
negative_case "the recomputed completion differs" "completion-mismatch" \
  mut_completion_mismatch
negative_case "the comparison row count differs" "compare-row-count-mismatch" \
  mut_compare_row_count
negative_case "a quoted delta mean is wrong" "compare-delta-mismatch" \
  mut_compare_delta_wrong
negative_case "the training curve is missing" "curve-missing" mut_curve_missing
negative_case "the training curve stops early" "curve-step-missing" \
  mut_curve_step_missing
negative_case "a plaintext token is injected" "token-leaked" mut_token_leaked
negative_case "the process-replication declaration is missing" \
  "process-replication-missing" mut_missing_process_declaration
negative_case "the unexecuted list is incomplete" "unexecuted-section-missing" \
  mut_missing_unexecuted_list
negative_case "the deviation list is too short" "deviation-section-missing" \
  mut_missing_deviation_list

# ---------------------------------------------------------------------------
# the negative mirror battery
# ---------------------------------------------------------------------------
mirror_negative_case() { # <label> <expected reason> <mutation>
  local label="$1"
  local reason="$2"
  local mutation="$3"
  rm -rf "$WORK"
  cp -r "$BASE" "$WORK"
  "$mutation" "$WORK"
  run_verify "$WORK" mirror
  assert_rc_nonzero "$label exits non-zero" "$RC"
  assert_contains "$label reports reason=$reason" "$OUT" "reason=$reason"
  assert_not_contains "$label prints no OK marker" "$OUT" "DOC_MIRROR_OK"
  assert_not_contains "$label prints no verify marker" "$OUT" "DOC_VERIFY_OK"
}

mirror_negative_case "the published mirror is missing" "mirror-missing" \
  mut_mirror_missing
mirror_negative_case "the published mirror differs" "mirror-mismatch" \
  mut_mirror_mismatch

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
