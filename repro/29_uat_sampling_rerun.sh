#!/usr/bin/env bash
# repro/29_uat_sampling_rerun.sh — 人工抽样复核：按复现记录里的原文命令重跑一段链路。
#
# WHY
#   The milestone's UAT class requires: "复现记录的九项章节齐备且每条结论可回溯到日志；
#   由人工按记录照抄重跑一段链路做抽样复核"。
#   The machine-checkable half of that is DOC_VERIFY_OK; the human half is
#   THIS script: it takes the commands exactly as they are written in
#   docs/code_read/MorphMimic完整复现记录.md, runs them one after another in
#   the remote container, and writes a transcript with the exit code and the
#   key marker of every step.  A third party can re-run it and compare.
#
#   The transcript lands in logs/env/29_uat_sampling_rerun.txt, which is
#   inside the persistent store, so it survives a worktree rebuild.
#
#   usage: bash repro/29_uat_sampling_rerun.sh
#
#   verdict: UAT_RERUN_OK steps=6  (all six steps exited 0)
#            UAT_RERUN_FAIL reason=step-failed step=<n>

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# The transcript goes to the store-backed log directory.
LOG_DIR="$REPO_ROOT/logs/env"
[ -d "$LOG_DIR" ] || LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
OUT="$LOG_DIR/29_uat_sampling_rerun.txt"

REMOTE="bash repro/lib/remote.sh"

# The sampled chain: environment -> data health -> training -> export parity
# -> deployment/evaluation -> the record itself.  Every command below is
# copied verbatim from the record.
STEPS=(
  "1-ENV-PROXY|$REMOTE 05_proxy_hygiene.sh|PROXY_HYGIENE_OK"
  "2-DATA-HEALTH|$REMOTE 14_seed_npz_verify.sh verify|SEED_NPZ_VERIFY_OK rows=142220 errors=0 rate=0.0000000000 kept=129398 subsets=5 sampled=200"
  "3-TRAIN-FINAL|$REMOTE 18_train_verify.sh verify|TRAIN_VERIFY_OK ckpts=9 latest=1 tb_tags=52 nan_whitelist=2 resume_events=9 gpu_peak_mb=19094.0 host_peak_gb=7.0 wall_s=2284 iterations=26413 lr_decay_iters=26413"
  "4-EXPORT-PARITY|$REMOTE 20_export_verify.sh verify|EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber"
  "5-DEPLOY-EVAL|$REMOTE 26_deploy_verify.sh verify|DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700"
  "6-RECORD|$REMOTE 28_doc_verify.sh verify|DOC_VERIFY_OK sections=9"
)

{
  echo "# UAT 抽样复核 transcript（人工按复现记录原文命令照抄重跑）"
  echo "# 依据：docs/code_read/MorphMimic完整复现记录.md 第 10 节证据索引表中的命令"
  echo "# 运行环境：远端 ros_dev 容器 172.16.119.199:2242（经 repro/lib/remote.sh 转发）"
  echo "# 抽样范围：环境卫生 → 数据健康 → 训练终局 → 导出 parity → 部署/评测 → 复现记录"
  echo "# 注意：各 verifier 会把本次输出**追加**到自己的日志文件（logs/env/*.txt），原证据保留在前半段，"
  echo "#       两轮输出靠时间戳区分；本 transcript 只记录本次运行的判定与输出尾部。"
  echo "# 开始时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# 说明：本文件由 repro/29_uat_sampling_rerun.sh 生成，可由第三方重跑并比对"
  echo
} >"$OUT"

failed=0
step_no=0
for row in "${STEPS[@]}"; do
  label="${row%%|*}"
  rest="${row#*|}"
  cmd="${rest%%|*}"
  marker="${rest#*|}"
  step_no=$((step_no + 1))
  {
    echo "===== STEP $label ====="
    echo "命令: $cmd"
    echo "开始: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >>"$OUT"
  out="$(timeout 900 bash -c "$cmd" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | tail -25 >>"$OUT"
  {
    echo "期望 marker: $marker"
    echo "退出码: $rc"
    echo "结束: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
  } >>"$OUT"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qF "$marker"; then
    printf 'STEP %s FAILED (rc=%s, marker missing: %s)\n' "$label" "$rc" "$marker" >>"$OUT"
    echo "STEP ${label} FAILED (rc=$rc, marker missing: $marker)"
    failed=1
  else
    printf 'STEP %s OK (rc=%s, marker hit: %s)\n' "$label" "$rc" "$marker" >>"$OUT"
    echo "STEP ${label} OK"
  fi
done

{
  echo "# 结束时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "UAT_RERUN_$([ "$failed" -ne 0 ] && echo FAIL || echo OK) steps=$step_no"
} >>"$OUT"

if [ "$failed" -ne 0 ]; then
  echo "UAT_RERUN_FAIL reason=step-failed steps=$step_no"
  exit 1
fi
echo "UAT_RERUN_OK steps=$step_no transcript=$OUT"
exit 0
