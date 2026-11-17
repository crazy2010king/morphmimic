# TRAINING — g1_amber 训练与资源边界控制（Slice S06 实测记录）

> 本文件是 **Slice S06**（`01-ttwecz-morphmimic` / `01-06-PLAN.md`）的终局事实记录。
> 所有数值均为本仓库在远端 `ros_dev` 容器（RTX 4090 24 GB）上的**实测值**，
> 均可在文末「证据索引」的日志与 marker 中 grep 到；**不手抄、不臆测**。
> 简体中文叙述，技术标识（marker / 路径 / 变量名 / 数值）保留原文。
>
> **一句话结论**：本切片完成的是**训练流程复现**（可重跑、可 resume、可复核），
> **不是上游 60,000 迭代配方的数值等价复现**（迭代数、env 数、编译模式、LR 衰减长度均按本机资源边界下调）。
> 任何下游结论引用训练数值时，必须连同本文件第 4 节的「偏离清单」一起引用。

---

## 1. 事实表

### 1.1 训练契约（输入与环境）

| 项 | 实测值 | 来源 |
|----|--------|------|
| 机器人 | **g1_amber** | `--robot g1_amber`（上游 README：g1_amber = G1 抬高腰部 roll/pitch 阻尼 1.81 → 3.0） |
| 子集 yaml | `data/seed_g1_npz50/subsets/1h.yaml` | `17_train_plan.env: SUBSET_YAML=…`；`SEED_SUBSET_OK name=1h clips=490 hours=1.0014277778` |
| 子集规模 | **490 clips / 1.0014277778 h** | `logs/env/13_seed_convert.txt`、S04 文档 `docs/code_read/NPZ_CONVERSION.md` |
| human sidecar 根 | `data/seed_g1_npz50/human50` | `17_train_plan.env: HUMAN_ROOT=…`；`SEED_HUMAN_SIDECARS count=490` |
| sidecar 数 | **490**（与 clip 集合精确一一对应） | `TRAIN_ENV_OK … clips=490 sidecars=490`；`SEED_HUMAN_VERIFY_OK clips=490 sidecars=490 missing=0 extra=0` |
| 环境规模 | `--num-envs 1024` | `17_train_plan.env: NUM_ENVS=1024` |
| 动作库精度 | `--library-dtype float16` | `17_train_plan.env: LIBRARY_DTYPE=float16` |
| 编译模式 | `--compile none` | `17_train_plan.env: COMPILE=none` |
| 人接口 | `--kp-interface --kp-student copy --no-kp-preview-mix` | worker 日志 `### RUN …` 原始命令行 |
| wm-only 预热 | `--wm-only-iters 500` | `17_train_plan.env: WM_ONLY_ITERS=500` |
| 落盘间隔 | `--ckpt-every 3000`，`--log-every 50` | `17_train_plan.env: CKPT_EVERY=3000` |
| run 目录 | `logs/train/g1_amber_1h` | `17_train_plan.env: RUN_NAME=g1_amber_1h` |
| GPU | NVIDIA GeForce RTX 4090，24 GiB（24564 MB），CUDA 12.9 / Driver 13.2 | `TRAIN_ENV_OK … gpu_total_mb=24564`；worker 日志 Warp banner |
| 训练栈 | python 3.11.16 / torch 2.11.0+cu128 / warp 1.17.0 / mujoco_warp | `TRAIN_ENV_OK python=3.11.16 torch=2.11.0+cu128` |

**环境门（fail-closed）**：`bash repro/lib/remote.sh 17_train.sh env` →
`TRAIN_ENV_OK python=3.11.16 torch=2.11.0+cu128 clips=490 sidecars=490 gpu_total_mb=24564 free_gb=3881`。
失败时固定打印 `TRAIN_ENV_FAIL reason=<…>`，reason 集合固定为
`import-failed / cuda-unavailable / venv-drift / subset-missing / subset-unparsable / subset-count /
sidecar-missing / sidecar-count / npz-verify-failed / gpu-missing / disk-insufficient`。

**磁盘门**：worker 启动前要求空闲空间 ≥ 50 GB，实测 `free_gb=3881`（约 3.8 TB），通过。

### 1.2 实测吞吐 / 资源 / 产物（终局口径）

| 项 | 实测值 | 来源 |
|----|--------|------|
| 冒烟实测 it/s（**迭代数换算的唯一输入**） | **1.0790 it/s** | `TRAIN_SMOKE_OK iters=2000 it_per_s=1.0790 …` |
| 正式运行稳态 it/s（中位数，剔除 wm-only 预热） | **1.0800 it/s** | `logs/env/17_train_phase2.txt`：`it_per_s_median_steady_state=1.0800` |
| 正式运行 it/s（算术平均，含 ~2.9 it/s 的 wm-only 预热） | **1.1112 it/s** | `17_train.status: IT_PER_S=1.1112`；`TRAIN_REPORT_IT_PER_S=1.1112` |
| 峰值显存（**nvidia-smi `memory.used` 进程占用口径**） | **19,094 MB = 18.65 GiB** | `TRAIN_REPORT_GPU_PEAK_MB=19094.0`；`17_train.status: GPU_PEAK_MB=19094 GPU_PEAK_GB=18.65` |
| 峰值显存（torch `max_memory_allocated` 分配器口径） | **17.09 GB**（训练日志 `mem 17.09 GB`） | `logs/env/17_train_worker.log`；`18_train_report.txt` 口径差异说明 (a) |
| 峰值主机内存 | **7.00 GB** | `TRAIN_REPORT_HOST_PEAK_GB=7.0`；`17_train.status: HOST_PEAK_GB=7.00` |
| 单 ckpt 体积 | **314,656,571 B ≈ 300 MiB（≈ 301 MB）** | `ls -l logs/train/g1_amber_1h/ckpt_*.pt`；冒烟 `ckpt_mb=300` |
| `latest.pt` 体积 | 314,656,827 B（**ckpt 的完整副本**，每次落盘写两份） | `ls -l logs/train/g1_amber_1h/latest.pt` |
| ckpt 总数 | **9 个**（`ckpt_3000/6000/9000/12000/15000/18000/21000/24000/26413.pt`）+ `latest.pt` | `TRAIN_REPORT_CKPTS=9`；`TRAIN_VERIFY_OK … latest=1` |
| 最终迭代数 | **26,413** | `TRAIN_REPORT_ITERATIONS=26413`；训练日志最后一行 `it 26413` |
| LR 衰减长度 | `--lr-decay-iters 26413`（与 iterations 严格相等） | `17_train_plan.env: LR_DECAY_ITERS=26413`；`TRAIN_VERIFY_OK … iterations=26413 lr_decay_iters=26413` |
| 墙钟（验收门口径） | **2,284 s** | `TRAIN_REPORT_WALL_S=2284`；`17_train.status: ELAPSED=2284` |
| 墙钟（GPU 实际占用口径） | **25,483 s ≈ 7.08 h** | `18_train_report.txt` 口径差异说明 (d) |
| 墙钟（日历跨度，含 211,876 s 基础设施停机） | 237,359 s ≈ 65.9 h | `18_train_report.txt`；`17_train_phase2.txt: worktree_recovery=…` |
| resume 事件条数 | **9** | `TRAIN_REPORT_RESUME_EVENTS=9`；`TRAIN_VERIFY_OK … resume_events=9` |
| tensorboard tag 总数（聚合 10 个 events 文件） | **52** | `TRAIN_REPORT_TB_TAGS=52`；`TRAIN_VERIFY_OK … tb_tags=52` |
| 非白名单 NaN/Inf tag 数 | **0** | `TRAIN_REPORT_NONFINITE_TAGS=0`；`TRAIN_VERIFY_OK … nan_whitelist=2` |
| `wm/policy/critic/kp` 的 `nonfinite_steps` 计数 | 恒为 **0** | 训练日志每行 `nonfinite wm/pol/critic 0/0/0`；复核器 `tb-nonfinite-steps` 门 |

### 1.3 命令原文

**编排器（全部经 `repro/lib/remote.sh` 进容器执行）**：

```bash
bash repro/lib/remote.sh 17_train.sh env       # 环境门（fail-closed）：TRAIN_ENV_OK / TRAIN_ENV_FAIL reason=…
bash repro/lib/remote.sh 17_train.sh smoke     # 2k 迭代冒烟 + 200 迭代 compile 对照 + 计划文件
bash repro/lib/remote.sh 17_train.sh start     # 拉起 detached 训练 worker（立即返回）
bash repro/lib/remote.sh 17_train.sh status    # 只读状态（状态文件 + 资源峰值 + 日志尾），恒 exit 0
bash repro/lib/remote.sh 17_train.sh wait 600  # 有界等待：0=DONE / 1=FAILED / 75=超时（worker 继续跑）
bash repro/lib/remote.sh 17_train.sh worker    # 前台训练体
bash repro/lib/remote.sh 17_train.sh verify    # 委托给 18_train_verify.sh verify
bash repro/lib/remote.sh 17_train.sh selftest  # 离线电池（train.sh + orchestrator + verify + tb e2e）

bash repro/lib/remote.sh 18_train_verify.sh verify   # 终局门：TRAIN_VERIFY_OK（进宿主验证门）
bash repro/lib/remote.sh 18_train_verify.sh report   # 文档回填源：TRAIN_REPORT_*
```

**上游训练命令行（正式 run 的第 1 段，`logs/env/17_train_worker.log` 原文）**：

```bash
uv run --frozen --no-sync python -m morphmimic.scripts.train \
  --robot g1_amber \
  --subset-yaml data/seed_g1_npz50/subsets/1h.yaml \
  --human-root data/seed_g1_npz50/human50 \
  --kp-interface --kp-student copy --no-kp-preview-mix \
  --library-dtype float16 \
  --num-envs 1024 \
  --compile none \
  --iterations 3000 \
  --lr-decay-iters 26413 \
  --ckpt-every 3000 \
  --log-every 50 \
  --wm-only-iters 500 \
  --log-dir logs/train \
  --run-name g1_amber_1h
```

**分段 resume 的第 2 段及以后**（唯一差别是 `--iterations` 递增 + 多一个 `--resume`）：

```bash
uv run --frozen --no-sync python -m morphmimic.scripts.train \
  --robot g1_amber \
  --subset-yaml data/seed_g1_npz50/subsets/1h.yaml \
  --human-root data/seed_g1_npz50/human50 \
  --kp-interface --kp-student copy --no-kp-preview-mix \
  --library-dtype float16 \
  --num-envs 1024 \
  --compile none \
  --iterations 6000 \
  --lr-decay-iters 26413 \
  --ckpt-every 3000 \
  --log-every 50 \
  --wm-only-iters 500 \
  --log-dir logs/train \
  --run-name g1_amber_1h \
  --resume logs/train/g1_amber_1h/latest.pt
```

分段序列（`--iterations`）：3000 → 6000 → 9000 → 12000 → 15000 → 18000 → 21000 → 24000 → 26413。

**冒烟与 compile 对照**（`repro/17_train_smoke.sh`）：

```bash
# 2k 冒烟：--compile none，run 目录 logs/train/smoke_2k
# 200 迭代对照：--compile reduce-overhead，run 目录 logs/train/smoke_cmp_200
# 可选 batch 探针：--imag-batch 2048 --kp-imag-batch 2048
```

**仓库 README 原文（对照，见第 4 节偏离清单）**：

```bash
uv run python -m morphmimic.scripts.train --robot g1 --subset-yaml $G1 --gpu 0 \
  $COMMON --run-name single_g1
```

### 1.4 终局 marker 原文（逐条粘贴）

冒烟与 compile 对照（`logs/env/17_train_smoke.txt`）：

```
TRAIN_SMOKE_OK iters=2000 it_per_s=1.0790 gpu_peak_mb=18834 host_peak_gb=7.00 ckpt_mb=300 elapsed_s=1605
COMPILE_CMP_OK mode=reduce-overhead it_per_s=1.5100 gpu_peak_mb=22100 compile_s=279 verdict=use_none
BATCH_PROBE_SKIPPED reason=peak-below-budget
PLAN_SELF_CHECK PLAN_OK iterations=26413 ckpt_every=3000 segment_iters=3000 ckpt_count=9
SMOKE_DONE stage=done
PLAN_WRITTEN iterations=26413 ckpt_every=3000 segment_iters=3000 it_per_s=1.0790 source=smoke
```

正式训练收口（`logs/env/17_train_phase2.txt`、`logs/env/17_train.status`、`logs/env/17_train.txt`）：

```
TRAIN_PHASE2_DONE iterations=26413 target=26413 elapsed_s=2284 it_per_s=1.0800 gpu_peak_mb=19094 host_peak_gb=7.00 ckpts=9 resume_events=9 state=DONE reason=none
TRAIN_TRAIN_OK iterations=26413 it_per_s=1.1112 gpu_peak_gb=18.65 host_peak_gb=7.00 elapsed_s=2284
STATE=DONE
RC=0
ITER=26413
TARGET_ITER=26413
GPU_PEAK_MB=19094
GPU_PEAK_GB=18.65
HOST_PEAK_GB=7.00
ELAPSED=2284
IT_PER_S=1.1112
```

只读独立复核器（`logs/env/18_train_verify.txt`、`logs/env/18_train_report.txt`）：

```
TRAIN_VERIFY_OK ckpts=9 latest=1 tb_tags=52 nan_whitelist=2 resume_events=9 gpu_peak_mb=19094.0 host_peak_gb=7.0 wall_s=2284 iterations=26413 lr_decay_iters=26413
TRAIN_REPORT_CKPTS=9
TRAIN_REPORT_ITERATIONS=26413
TRAIN_REPORT_IT_PER_S=1.1112
TRAIN_REPORT_GPU_PEAK_MB=19094.0
TRAIN_REPORT_HOST_PEAK_GB=7.0
TRAIN_REPORT_WALL_S=2284
TRAIN_REPORT_TB_TAGS=52
TRAIN_REPORT_NONFINITE_TAGS=0
TRAIN_REPORT_RESUME_EVENTS=9
TRAIN_REPORT_OK=1
```

上游数据门复核（同一次终局复核里调用既有只读复核器）：

```
SEED_NPZ_VERIFY_OK rows=142220 errors=0 rate=0.0000000000 kept=129398 subsets=5 sampled=200
SEED_HUMAN_VERIFY_OK clips=490 sidecars=490 missing=0 extra=0 frames_match=490 feet_off=11
```

### 1.5 resume 证据（9 条，训练日志原文）

```
resumed logs/train/g1_amber_1h/latest.pt at iteration 3000
resumed logs/train/g1_amber_1h/latest.pt at iteration 6000
resumed logs/train/g1_amber_1h/latest.pt at iteration 9000
resumed logs/train/g1_amber_1h/latest.pt at iteration 12000
resumed logs/train/g1_amber_1h/latest.pt at iteration 15000
resumed logs/train/g1_amber_1h/latest.pt at iteration 18000
resumed /…/logs/train/g1_amber_1h/latest.pt at iteration 18000
resumed /…/logs/train/g1_amber_1h/latest.pt at iteration 21000
resumed /…/logs/train/g1_amber_1h/latest.pt at iteration 24000
```

（后 4 条使用容器内绝对路径；第 7 条是 worktree 被 GSD 清理删除后重建导致的一次**重入**，
训练从 iteration 18000 续跑，未丢 ckpt——详见第 5 节踩坑。）

---

## 2. 迭代数换算与 8 h 档选择理由

### 2.1 迭代数换算公式

```
ITERATIONS = floor(BUDGET_SECONDS × IT_PER_S_MEASURED × 0.85)
           = floor(28800 × 1.0790 × 0.85)
           = floor(26413.92)
           = 26413
```

- `IT_PER_S_MEASURED = 1.0790`：**只用 2k 冒烟的稳态实测值**，排除 wm-only 预热段（该段日志 it/s 约 2.9，
  不可用于换算，见第 5 节踩坑）。来源 `17_train_plan.env: IT_PER_S_MEASURED=1.0790 IT_PER_S_SOURCE=smoke`。
- 系数 `0.85`：留 15 % 余量给采样/落盘/段间 resume 开销。判定实现在 `repro/lib/train.py:plan_iterations()`
  （非正/非有限入参 fail-closed 返回 0），shell 入口 `bash repro/lib/train.sh plan --budget-seconds 28800 --it-per-s 1.0790`。
- **`--lr-decay-iters` 恒等于 `--iterations`**（MEM005 已定决策），故 `LR_DECAY_ITERS=26413`，
  避免上游 README 里「迭代只跑到 60,000、cosine 仍按 250,000 衰减 → 学习率全程偏高」的行为。

### 2.2 选的是 **8 h 档**（不是 R010 字面的 24 h 公式）

- 计划文件：`17_train_plan.env: BUDGET_SECONDS=28800`（= 8 h）。
- **理由**：R011 规定「训练 ≤ 20 h + 4 h 余量」，而 S07（ONNX 导出）、S08（1h 子集评测）、
  S09（完整复现记录）都要在这之后串行完成；按 R010 字面的 24 h 预算公式换算会得到
  `floor(86400 × it/s × 0.85)` 量级的迭代数，训练实耗将逼近/突破 20 h 上限，
  与 S07/S08/S09 的实际耗时**不相容**。故选 8 h 档（⇒ 实测 20.4 h 是「24 h 档公式」的推论，
  不是本 run 的实耗；本 run 的实耗见第 1.2 节墙钟三口径）。
- **代价**：迭代数只有上游 60,000 配方（README 默认）的 **44 %**，且 `--lr-decay-iters` 被压到 26,413，
  因此**本 run 的策略不是上游 v0.1 发布策略的数值等价物**，只能作为「流程可复现」的证据，
  以及 S07 导出/S08 评测的**可运行起点**。
- 上游 README 默认 `--iterations 60000`（并注明 cosine 默认按 250,000 衰减），本 run 两者都改过。

### 2.3 ckpt 间隔与数量

`CKPT_EVERY=3000`、`SEGMENT_ITERS=3000`（一个 segment = 一个训练段 = 一个 ckpt 间隔），
`CKPT_COUNT=9`（3000/6000/…/24000 共 8 个 + 末段 `ckpt_26413.pt`），
`PLAN_OK iterations=26413 ckpt_every=3000 segment_iters=3000 ckpt_count=9`。
间隔取值由 `repro/lib/train.py:plan_ckpt_every()` 决定（保证 ckpt 数 ≥ `DEFAULT_MIN_CKPTS=3`）。

---

## 3. 显存 / 内存口径与降级阶梯

### 3.1 三口径对照（同一物理量，不同统计口径，不矛盾）

| 口径 | 数值 | 含义 | 用途 |
|------|------|------|------|
| nvidia-smi `memory.used` 进程占用 | **19,094 MB (18.65 GiB)** | 进程在 GPU 上的总占用（含 CUDA context / 驱动 / 分配器缓存） | **验收门口径**（上限 22 GiB = 22,528 MB） |
| torch `max_memory_allocated` | **17.09 GB** | 只统计 torch 已分配张量 | 训练日志 `mem 17.09 GB` |
| 主机内存 `host_used_gb` | **7.00 GB** | 宿主机整体已用内存 | 验收门上限 45 GB |

预算对照：19,094 MB < 22,528 MB（余量 3,434 MB ≈ 15 %）；7.00 GB ≪ 45 GB。

### 3.2 降级阶梯（**与 R011 字面顺序不同，此处标注**）

R011 字面的顺序是「先降 `--num-envs`，再降 batch，最后才 `--compile none`」。
**实测证明这个顺序是错的**：显存主因是**想象批**（`--imag-batch 4096` + `--kp-imag-batch 4096`，horizon 32），
**不是 env 数量**。

证据（`logs/env/17_train_smoke_train.log`）：wm-only 预热段（`--wm-only-iters 500`，
`actor-critic` 尚未启动）日志显示 `mem 3.11 GB`；一旦 policy/critic 启动，
内存从 **3.11 GB 跃升到 17.09 GB**（同一份 1024 env 的配置，env 数没变）。

因此本仓库采用的**降级阶梯**为：

```
先降 --imag-batch / --kp-imag-batch  →  再降 --num-envs  →  最后 --compile none
```

对应证据链：
1. 冒烟实测 `gpu_peak_mb=18834`（含 1024 env + 4096 imag batch）**已低于 22 GB 预算**，
   故 batch 探针被跳过：`BATCH_PROBE_SKIPPED reason=peak-below-budget`（即当前配置无需降 batch）。
2. `--compile reduce-overhead` 对照：`gpu_peak_mb=22100`（**逼近 22 GB 线**）、`compile_s=279`，
   判定 `COMPILE_CMP_OK … verdict=use_none` → 正式训练用 `--compile none`。
3. `--compile none` 的代价：it/s 从 1.5100 降到 1.0790（**吞吐降低约 28.5 %**），
   但省掉每次 resume 都要重编译 CUDA graph 的 279 s 开销，并留出显存余量（D024）。

---

## 4. 相对上游 README 的偏离清单（逐条含代价）

| # | 偏离 | README 默认 | 本次实测 | 理由 | 代价 |
|---|------|-------------|----------|------|------|
| ① | `--num-envs 1024` | 4096（README：「Memory at 4096 envs: about 28 GB per GPU on the 1 h subset」） | 1024 | 24 GB 卡放不下 28 GB 占用 | 采样吞吐下降（`env 2780/s` @1024 env）；但因显存主因是想象批而非 env 数，代价有限 |
| ② | `--compile none` | README 默认编译 CUDA graph（README：「The first iterations compile the updates into CUDA graphs… `--compile none` runs eagerly instead.」） | none | ① `reduce-overhead` 对照峰值 22,100 MB 逼近 22 GB 预算线；② 每次 resume 都要重编译（实测 279 s/次 × 9 段） | it/s 1.5100 → 1.0790（-28.5 %）；但迭代数已按 1.0790 换算，结论自洽 |
| ③ | `--lr-decay-iters` 显式对齐实际迭代数 | 默认 250,000（README 明说「The cosine decay still runs over its default 250,000 … so the learning rate is still high there」） | 26413（= `--iterations`） | MEM005 已定决策：LR 衰减与实际迭代对齐，避免学习率全程偏高 | LR schedule 的**总长度**远短于上游，等价于把「衰减到 0」的进度压缩到 26,413 步内——**这是与上游策略数值不可比的根因之一** |
| ④ | 训练预算 8 h 档 | R010 字面 24 h 公式 | `BUDGET_SECONDS=28800`（8 h） | R011 的「20 h 训练上限 + 4 h 余量」与 S07/S08/S09 串行耗时不相容（见 2.2） | 迭代数 26,413 仅为上游 60,000 的 44 %，策略质量必然低于上游发布策略 |
| ⑤ | 降级阶梯顺序（先 batch 后 envs） | R011 字面：先 envs 后 batch | 先 `--imag-batch/--kp-imag-batch` → 再 `--num-envs` → 最后 `--compile none` | 实测证明显存主因是想象批（3.11 GB → 17.09 GB 的跃升发生在 actor-critic 启动瞬间，env 数未变） | 偏离了 R011 的字面契约，但更省时间：本次 batch 探针直接被跳过（`BATCH_PROBE_SKIPPED`） |
| ⑥ | 最终迭代数偏差 | 计划 26,413 | **实测 26,413（delta=0）** | — | **无偏差**：`17_train_phase2.txt: deviation_vs_iterations: measured_max_it=26413 target=26413 delta=0`；若将来复跑出现偏差，必须在此处如实记录偏差原因 |

补充偏离（不影响训练数值、但影响复现路径）：

- 训练用 `uv run --frozen --no-sync python -m morphmimic.scripts.train`（README 是 `uv run python -m …`），
  以保证容器离线可跑、依赖锁定在 `uv.lock`。
- 运行目录落在共享 store（`logs/` 是软链），不是 worktree 本体（worktree 被 GSD 清理删除过一次，见第 5 节）。
- 训练被拆成 9 个 segment，每段 `--iterations` 递增并 `--resume latest.pt`；上游是一次性跑完。

---

## 5. 踩坑

1. **`--iterations` 是「跑到第几迭代」，不是「再跑多少」**。上游 `src/morphmimic/train/trainer.py:2192`
   是 `while self.it < cfg.iterations:`。所以 resume 段必须把 `--iterations` 递增到**目标值**，
   否则会立即空转退出。
2. **每次 resume 会新增一个 tensorboard events 文件**。本次 run 目录里有 **10 个**
   `events.out.tfevents.*`（9 段 + 冒烟/对照各一），复核必须**聚合全部 events 文件**再看 NaN；
   只看最后一个文件会漏掉前 8 段的曲线。复核器即按目录聚合全部 events（`TRAIN_VERIFY_OK … tb_tags=52`）。
3. **`kp/return` 与 `kp/scale_return` 在 copy 学生下按设计就是 NaN**（`src/morphmimic/train/trainer.py:1935`
   注释：`` `kp/return` (J; NaN under copy) ``；`trainer.py:2002` 直接写 `nan`）。
   判定必须白名单化：`repro/lib/train.py: DEFAULT_WHITELIST = ("kp/return", "kp/scale_return")`，
   白名单外的任何 NaN/Inf 才算失败（`TRAIN_VERIFY_OK … nan_whitelist=2`）。
4. **`wm/policy/critic/kp` 的 `nonfinite_steps` 恒为 0**：训练日志每行都打印
   `nonfinite wm/pol/critic 0/0/0`，复核器另有 `tb-nonfinite-steps` 门（任何 `*/nonfinite_steps > 0` 即失败）。
5. **wm-only 预热段的 it/s 虚高（~2.9–2.97 it/s），不可用于换算**。预热段 `actor-critic` 尚未启动，
   显存也只有 3.11 GB；换算必须用剔除预热后的稳态值（冒烟实测 1.0790 / 正式稳态中位数 1.0800）。
6. **`latest.pt` 是 ckpt 的完整副本**：每次落盘写两份（`ckpt_<it>.pt` + `latest.pt`），各约 300 MiB。
   磁盘预算要按「2 × ckpt 数」算；本次 9 ckpt + 1 latest ≈ 3.0 GB。
7. **venv 漂移的离线修复命令必须带 `--offline`**（容器无外网）：
   `uv sync --frozen --offline --group export --group teleop`。
   环境门会把它作为 `venv-drift` 的修复提示打印出来。
8. **`--compile reduce-overhead` 每次 resume 都要重编译 CUDA graph**（实测 279 s/次），
   且显存峰值 22,100 MB 逼近预算线；正式训练因此选 `--compile none`（D024）。
9. **worktree 被 GSD 清理删除会打断 detached worker**：本次 run 中段（segment 3）曾因
   `Current directory does not exist` 退出 1（worktree 被清理），重建 worktree 并 re-arm 后
   从 iteration 18000/24000 续跑完成；该停机在资源 CSV 中留下 **211,876 s 的时间断档**，
   是日历跨度 237,359 s 与 GPU 实占 25,483 s 的差值来源，**不计入训练预算**。
   已如实记录于 `logs/env/17_train_phase2.txt: worktree_recovery=…`。
10. **只读复核器必须独立于训练脚本**：验收采信 `repro/18_train_verify.sh` 的判定，
    不采信训练脚本自报的 `TRAIN_TRAIN_OK`；复核器自身有 37 项离线 fixture 负向电池
    （`repro/tests/test_train_verify.sh`），失败路径零 OK marker。

---

## 6. 只读独立复核器（`repro/18_train_verify.sh`）

- `verify`：终局门，成功打印唯一一行
  `TRAIN_VERIFY_OK ckpts=… latest=… tb_tags=… nan_whitelist=2 resume_events=… gpu_peak_mb=… host_peak_gb=… wall_s=… iterations=… lr_decay_iters=…`；
  失败打印 `TRAIN_VERIFY_FAIL reason=<固定 reason 集合>` 并非零退出，**失败路径绝不打印 OK marker**。
- `report`：打印 `TRAIN_REPORT_*` 数值（**本文件的文档回填源**）。
- 固定 reason 集合（可 grep）：
  `ckpt-count / ckpt-missing / ckpt-unloadable / latest-missing / tb-no-events / tb-tag-missing /
  tb-nonfinite / tb-nonfinite-steps / resume-missing / resume-iteration / resource-csv-missing /
  gpu-over-budget / host-over-budget / wall-over-budget / iterations-mismatch / npz-verify-failed /
  human-verify-failed`。
- 判定源唯一：`repro/lib/train.py`（`nan_audit` / `DEFAULT_WHITELIST` / `budget_ok` / `parse_log_file` /
  `parse_resource_csv`）；复核器自己不另造第二套解析逻辑。
- 资源口径：显存取**采样 CSV 的 `gpu_used_mb`**（进程占用），**不是** torch `max_memory_allocated`。
- 自检（证明不是「只会报 OK」）：`bash repro/tests/test_train_verify.sh` → `PASS=37 FAIL=0`（本地与容器内一致）。

---

## 7. 下游交接契约

- **S07（ONNX 导出）**：从 `logs/train/g1_amber_1h/latest.pt`（或任一 `ckpt_*.pt`）导出；
  checkpoint 内记录了 anchor 模式（本 run 为默认 motion 目标），导出时不要换 interface 模式。
- **S08（评测）**：必须用**同一份** `data/seed_g1_npz50/subsets/1h.yaml`（490 clips / 1.0014 h）
  与同一个 human50 根 `data/seed_g1_npz50/human50`；
  评测的 `--num-envs` 与训练一致用 1024（上游 README 的评测示例也用 1024）。
- **S09（完整复现记录）**：引用本文件的 marker 与数值
  （`TRAIN_SMOKE_OK` / `TRAIN_VERIFY_OK` / `TRAIN_REPORT_*`）、本文件的偏离清单与降级阶梯，
  并明确写出「**训练只是流程复现，不是数值等价复现**」。
- **ckpt 选择提示**：末段 `ckpt_26413.pt` 是跑满计划的最后一个 ckpt；
  若 S08 评测需要「训练中途」的对照点，`ckpt_18000.pt`（对应 T5 收口时的 iteration 18,800 附近）可用。

---

## 8. 证据索引

| 证据 | 内容 |
|------|------|
| `logs/env/17_train_env.txt` | 环境门输出（`TRAIN_ENV_OK`） |
| `logs/env/17_train.txt` | 编排器主日志（`TRAIN_ENV_OK` / `TRAIN_TRAIN_OK` / `STATE=`） |
| `logs/env/17_train.status` | 原子状态文件：`STATE=DONE RC=0 ITER=26413 GPU_PEAK_MB=19094 GPU_PEAK_GB=18.65 HOST_PEAK_GB=7.00 ELAPSED=2284 IT_PER_S=1.1112 TARGET_ITER=26413` |
| `logs/env/17_train_plan.env` | 计划文件：`ITERATIONS=26413 LR_DECAY_ITERS=26413 CKPT_EVERY=3000 SEGMENT_ITERS=3000 BUDGET_SECONDS=28800 COMPILE=none NUM_ENVS=1024 CKPT_COUNT=9 WM_ONLY_ITERS=500 IT_PER_S_MEASURED=1.0790` |
| `logs/env/17_train_worker.log` | 训练日志本体：9 条 `resumed … at iteration N`、逐行 it/s / `mem` / `nonfinite`、训练命令行原文 |
| `logs/env/17_train_resources.csv` | 30 s 资源采样：`gpu_used_mb` 峰值 19,094、`host_used_gb` 峰值 7.00、849 个样本 |
| `logs/env/17_train_smoke.txt` | `TRAIN_SMOKE_OK` / `COMPILE_CMP_OK` / `BATCH_PROBE_SKIPPED` / `PLAN_OK` |
| `logs/env/17_train_smoke.state` | 冒烟状态文件（`STATE=DONE RC=0 STAGE=done`） |
| `logs/env/17_train_smoke_driver.log` | 冒烟各阶段摘要（`smoke rc=0 …` / `cmp rc=0 …` / `batch probe skipped`） |
| `logs/env/17_train_smoke_train.log` | 2k 冒烟训练日志（wm-only 预热段 `mem 3.11 GB` / it/s 2.97 的证据） |
| `logs/env/17_train_phase2.txt` | 收口摘要（`TRAIN_PHASE2_DONE` / 稳态中位数 1.0800 / resume 明细 / `worktree_recovery`） |
| `logs/env/18_train_verify.txt` | 复核器 verify/report 原始输出（`TRAIN_VERIFY_OK` / `TRAIN_REPORT_*`） |
| `logs/env/18_train_report.txt` | 文档回填源：三方数字交叉核对 + 口径差异说明 (a)–(e) |
| `logs/env/tb_quick_audit.sh` | T5 只读 tensorboard 快速普查脚本（判定源 = `repro/lib/train.py`） |
| `logs/train/g1_amber_1h/` | run 目录：9 个 `ckpt_*.pt` + `latest.pt` + 10 个 `events.out.tfevents.*` |
| `repro/17_train.sh` / `repro/17_train_worker.sh` / `repro/17_train_smoke.sh` | 编排器 / detached 训练体 / 冒烟与 compile 对照 |
| `repro/18_train_verify.sh` | 只读终局复核器 |
| `repro/lib/train.py` / `repro/lib/train.sh` | 判定底座（纯函数 + 薄 CLI） |
| `repro/tests/test_train.sh` / `test_train.py` | 判定底座离线电池（47 项 shell 断言 + 31 项 unittest） |
| `repro/tests/test_train_orchestrator.sh` | 编排器离线负向电池（67 项） |
| `repro/tests/test_train_verify.sh` / `test_train_verify_tb_e2e.sh` | 复核器离线 fixture 负向电池（37 项）+ tensorboard 端到端 |
