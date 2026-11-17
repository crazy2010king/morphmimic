# NPZ_CONVERSION — BONES-SEED G1 → 50 Hz npz 与子集构建（Slice S04 实测记录）

> 本文件是 **Slice S04**（`01-ttwecz-morphmimic` / `01-04-PLAN.md`）的终局事实记录。
> 所有数值均为本仓库实测，均可由文末「证据索引」中的日志与 marker 复现；**不手抄、不臆测**。
> 简体中文叙述，技术标识（marker / 路径 / 变量名 / 数值）保留原文。

---

## 1. 事实表

### 1.1 输入

| 项 | 实测值 | 来源 |
|----|--------|------|
| G1 CSV clip 数 | **142,220** | `SEED_TAR_CLIPS file=g1 kind=csv count=142220`、`SEED_EXTRACT_FILES file=g1 count=142220` |
| G1 session 数 | **124** | `SEED_META_SESSION session=<id> …` 共 124 个去重 session（`logs/env/10_seed_extract.txt`） |
| SOMA uniform BVH clip 数 | 142,220（本切片未使用，供 S05 human50 sidecar 用） | `SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220` |
| metadata 行数 | **142,220**（文件 `seed_metadata_v004.csv` 共 142,221 行 = 表头 + 142,220 行） | `SEED_META_MATCH matched=142220 missing=0 extra=0` |
| CSV 根目录 | `data/seed/g1/csv/<session>/*.csv` | worktree `data/` → store 软链 |

### 1.2 上游调用方式与命令原文

上游逻辑 **不重写**，直接调用仓库自带的 `morphmimic.scripts.*`；本切片只加可观测包装层。

**实际执行（本仓库 worker 内，容器 `ros_dev`，cwd = worktree 根）**：

```bash
# 转换（repro/13_seed_convert_worker.sh 第 3 步）
uv run --frozen --no-sync python -m morphmimic.scripts.convert_seed \
    --csv-dir data/seed/g1/csv \
    --metadata data/seed/metadata/seed_metadata_v004.csv \
    --out-dir data/seed_g1_npz50 \
    --workers 28

# 子集构建（repro/13_seed_convert_worker.sh 第 4 步）
uv run --frozen --no-sync python -m morphmimic.scripts.build_subsets \
    --manifest data/seed_g1_npz50/manifest.csv \
    --out-dir data/seed_g1_npz50/subsets \
    --seed 0
```

**仓库 README 原文（对照）**：

```bash
uv run python -m morphmimic.scripts.convert_seed \
  --csv-dir $DATA/seed/g1/csv --metadata $DATA/seed/seed_metadata_v003.csv \
  --out-dir $DATA/seed_g1_npz50 --workers 96
uv run python -m morphmimic.scripts.build_subsets \
  --manifest $DATA/seed_g1_npz50/manifest.csv --out-dir $DATA/seed_g1_npz50/subsets
```

### 1.3 输出

| 产物 | 实测值 |
|------|--------|
| `data/seed_g1_npz50/manifest.csv` | **142,220 行**（含表头 142,221 行） |
| npz 文件数 | **142,220**（`SEED_NPZ_FILES count=142220`） |
| npz 总字节 | **94,982,502,872 B ≈ 88.46 GiB**（`SEED_NPZ_FILES count=142220 bytes=94982502872`） |
| npz 平均单 clip | **667,856 B ≈ 652.2 KiB**（94982502872 / 142220） |
| kept（`name_reject==""` 且 `feas_reject==""`） | **129,398** |
| error（`feas_reject` 以 `"error: "` 开头） | **0**，error_rate = 0.0000000000（上限 1%） |
| kept 总时长 | 946,204.640 s = **262.834622 h** |
| 全量时长（含被过滤 clip） | 1,038,307.160 s = 288.418656 h |

**五个子集 yaml**（`data/seed_g1_npz50/subsets/`，由上游 `build_subsets --seed 0` 写出）：

| 子集 | clips | hours | 文件行数 |
|------|-------|-------|----------|
| `tiny.yaml` | 50 | 0.1000611111 | 53 |
| `1h.yaml` | **490** | **1.0014277778** | 493 |
| `7h.yaml` | 3,433 | 7.0008388889 | 3,436 |
| `40h.yaml` | 19,632 | 40.0039000000 | 19,635 |
| `all.yaml` | 129,398 | 262.8346222222 | 129,401 |

嵌套关系 **tiny ⊂ 1h ⊂ 7h ⊂ 40h ⊂ all** 成立（上游 `build_subsets` 用同一 `--seed 0` 洗牌取子集，
本切片另用 `repro/lib/seed_npz.py nested` 独立复核，见 `SEED_SUBSET_NESTED ok`）。

`1h.yaml` 的 `root:` 字段指向 npz 根目录（容器内绝对路径）：

```
root: /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo/data/seed_g1_npz50
```

### 1.4 终局 marker 原文（逐条粘贴）

来自 `logs/env/13_seed_convert.txt` / `logs/env/13_seed_convert_worker.log` / `logs/env/14_seed_npz_verify.txt`：

```
SEED_NPZ_ENV_OK python=3.11 torch=2.11.0+cu128 mujoco=3.11.0 scipy=1.17.1 workers=28
space gate ok: /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz/data/seed_g1_npz50 free=3965 GiB min=250 GiB
SEED_NPZ_START clips=142220 workers=28
SEED_SUBSET_OK name=tiny clips=50 hours=0.1000611111
SEED_SUBSET_OK name=1h clips=490 hours=1.0014277778
SEED_SUBSET_OK name=7h clips=3433 hours=7.0008388889
SEED_SUBSET_OK name=40h clips=19632 hours=40.0039000000
SEED_SUBSET_OK name=all clips=129398 hours=262.8346222222
SEED_SUBSET_NESTED ok
SEED_NPZ_CONVERT_OK clips=142220 rows=142220 kept=129398 errors=0 error_rate=0.0000000000 elapsed_s=7496
SEED_NPZ_FILES count=142220 bytes=94982502872
SEED_NPZ_VERIFY_OK rows=142220 errors=0 rate=0.0000000000 kept=129398 subsets=5 sampled=200
SEED_REPORT_NPZ_ROWS=142220
SEED_REPORT_NPZ_ERRORS=0
SEED_REPORT_NPZ_ERROR_RATE=0.0000000000
SEED_REPORT_NPZ_KEPT=129398
SEED_REPORT_NPZ_SUBSETS=5
SEED_REPORT_NPZ_SAMPLED=200
SEED_REPORT_NPZ_ALL_CLIPS=129398
SEED_REPORT_NPZ_1H_CLIPS=490
SEED_REPORT_NPZ_1H_HOURS=1.0014277778
SEED_REPORT_NPZ_OK=1
```

### 1.5 1h 子集（下游 S05 / S06 / S08 的共同输入前提）

- **clips = 490**，**hours = 1.0014277778**（yaml 内 `hours: 1.0014277777777778`）。
- clip 列表形如 `220713/kneeling_start_004__A022.npz`，共 490 条，路径相对 npz 根目录。
- **S05 / S06 / S08 必须共用这一份 `subsets/1h.yaml`**，不要各自重建子集
  （`build_subsets` 的洗牌由 `--seed` 决定，不同 seed 会得到不同的 490 条 clip 集合）。

---

## 2. 实测耗时与体积

| 阶段 | 实测值 | 证据 |
|------|--------|------|
| 环境门（`13_seed_convert.sh env`） | **≈ 5 s**（同一次 run 内 env 段 `11:10:14Z` → smoke 段 `11:10:19Z`；主体是 torch import） | `logs/env/13_seed_convert.txt` |
| 冒烟（30 clip，`--limit 30`，workers=4） | **elapsed_s = 8**，npz 合计 33,087,504 B，平均 1,102,916 B/clip，上游 tqdm 稳态 22.27 it/s | `SEED_NPZ_SMOKE_EXTRACT clips=30 elapsed_s=8 npz_bytes=33087504 avg_bytes=1102916 rate=3.75` |
| 全量转换（142,220 clip，workers=28） | **elapsed_s = 7,496 s ≈ 2 h 05 min**，速率 **≈ 18.97 clip/s**；`2026-11-13T00:42:03Z` → `2026-11-13T02:47:10Z`，**单次运行、restarts=0** | `SEED_NPZ_CONVERT_OK … elapsed_s=7496` + `logs/env/13_seed_convert.status` |
| 全量 npz 体积 | **94,982,502,872 B ≈ 88.46 GiB** | `SEED_NPZ_FILES count=142220 bytes=94982502872` |
| 终局复核（`14_seed_npz_verify.sh verify`，只读） | **≈ 1.5 s**（本地 ssh + 容器内全部检查） | 本任务实测 `gsd_exec` duration 1454 ms |
| 全量文件计数（`14_seed_npz_verify.sh audit`） | **≈ 70 s**（NFS 上 `find` 全量遍历；不计入宿主验证门） | `SEED_NPZ_FILES` 行时间戳 `02:48:32Z` → `02:49:43Z` |
| store 剩余空间（转换启动时） | **free = 3,965 GiB**（空间门阈值 250 GiB） | `space gate ok: … free=3965 GiB min=250 GiB` |
| store 剩余空间（本次收口时实测） | `/mnt` 7.3 TiB 总量，已用 3.1 TiB（45%），**可用 3.8 TiB** | `df -h /mnt` |

> 单 clip 平均体积（652 KiB）明显小于冒烟样本（1.05 MiB）：冒烟取的是**按路径排序后的前 30 个 clip**
> （`--limit 30` 是排序取前 N，**不是随机采样**），恰好都是 610 帧的长 clip；全量 142,220 条的长度分布更分散。

---

## 3. 过滤统计

`repro/lib/seed_npz.py stats` 的实测输出（与 `logs/env/14_seed_npz_verify.txt` 一致）：

```
manifest: rows=142220
manifest: kept=129398
manifest: errors=0
manifest: error_rate=0.0000000000
manifest: total_seconds=1038307.160
manifest: total_hours=288.418656
manifest: kept_seconds=946204.640
manifest: kept_hours=262.834622
manifest: named=129691
manifest: error_rate_ok=1
```

**name_reject（动作名不在允许集合内）分布，共 12,529 条**：

| 原因 | 数量 | 原因 | 数量 |
|------|------|------|------|
| sitting | 3,719 | horse riding | 258 |
| box | 3,624 | 50cm | 22 |
| sit | 1,750 | on the edge | 240 |
| chair | 702 | leaning | 432 |
| table | 502 | jump off | 84 |
| crutch | 494 | ladder | 136 |
| crutches | 436 | stairs | 84 |
| stair | 14 | look over fence | 24 |
| seat | 8 | | |

**feas_reject（可行性过滤）分布，共 4,937 条**：

| 原因 | 数量 |
|------|------|
| elevated_support | 3,948 |
| ground_penetration | 873 |
| floating_feet | 116 |

**与 README 宣称的对照**（README：「The filters keep 129,398 clips (262.8 h)」）：

| 项 | README 宣称 | 本次实测 | 结论 |
|----|------------|----------|------|
| kept clips | 129,398 | **129,398** | **完全一致** |
| kept 时长 | 262.8 h | **262.834622 h** | 四舍五入后一致（README 取一位小数） |

差异说明（不掩盖）：

- `named = 129,691`（`name_reject == ""` 的行数）→ 名字过滤掉 **12,529** 条；
- 可行性过滤在「名字通过」的集合上再掉 **293** 条 → 293 = 4,937 − 4,644，其中
  **4,644 条同时命中了名字拒绝与可行性拒绝**（两个计数器有重叠，不能直接相加）；
- 因此被拒总量 = 142,220 − 129,398 = **12,822**，而不是 12,529 + 4,937 = 17,466。
- **error 数为 0**：没有任何 clip 因 `feas_reject` 以 `"error: "` 开头而失败
  （这类错误本应是 torch 不可导入时全部 clip 集体失败的信号）。

---

## 4. 相对 README 的偏离清单

| # | 偏离 | 实测值 | 原因 |
|---|------|--------|------|
| 1 | 不使用 HF CLI 下载 | 数据由 S03 的 `08_seed_download.sh` 取得 | S03 的偏离（代理出口 0.85–1.45 MB/s），本切片沿用其产物 |
| 2 | `--workers 28`，非 README 的 96 | 28 | 容器 `ros_dev` 实测 `nproc = 32`；再高只会加剧 NFS 小文件写竞争（详见 §5 的 198 文件/分钟实测）。实测 18.97 clip/s 已在容器 CPU 饱和区间 |
| 3 | metadata 用 `seed_metadata_v004.csv`，README 写 `v003.csv` | v004 | 本仓库数据落地的版本是 v004（`data/seed/metadata/seed_metadata_v004.csv`）；上游 `convert_seed --metadata` 可接受任意 metadata 路径 |
| 4 | 输出目录名 `seed_g1_npz50` | 与 README 同名，但落在**共享 store**（`morphmimic-seed-data/repo/data/`）而非 worktree 实体目录 | npz 共 88.46 GiB，必须落在 store；worktree 内 `data/`、`logs/` 都是指向 store 的符号链接 |
| 5 | 终局复核**不重算全量文件 sha256 / 不在验证门内做全量 `find`** | `verify` 用 manifest 行数为主证据 + 200 抽样；`audit` 单独跑 | 68.7 GB 的 sha256 重算实测 518 s（MEM052 教训）；142,220 个文件的 `find` 计数约 70 s |
| 6 | `--limit` 语义按上游实现 | **排序后前 N 个**，不是随机采样 | 上游 `convert_seed` 文档字符串原文：*「limit: convert only the first `limit` clips (sorted by path)」* |
| 7 | 子集构建显式传 `--seed 0` | README 未传（默认也是 0） | 显式化以保证 tiny ⊂ 1h ⊂ 7h ⊂ 40h ⊂ all 的嵌套可复现 |

---

## 5. 踩坑

1. **容器 venv 的 `torch._vendor` 缺失导致 `import torch` 失败**（规划期实测）：
   worktree 挂在 NFS（`nfs4`，无异步回写）上，小文件写入被同步提交；detached 的
   `uv sync --frozen` 实测只有 **198 文件/分钟**，跑约 50 min 后 torch 仍是半拷贝状态
   （`torch/version.py`、`torch/_vendor`、`torch-2.11.0+cu128.dist-info` 缺失），
   `import torch` 报 `ModuleNotFoundError: No module named 'torch._vendor'`。
   **修复**（内容与 `uv.lock` 锁定的 torch 2.11.0+cu128 逐字节一致）：
   从 uv cache 已解包的轮子（`/root/.cache/uv/archive-v0/u5Gw-loVgrxX17Yn`）复制到
   容器本地 ext4（`/home/morphmimic-pkgs`，0.55 s），再以符号链接把
   `torch` / `functorch` / `torchgen` / `torch-2.11.0+cu128.dist-info` 接回
   `<repo>/.venv`；venv 本体与 `sys.prefix` 不变，环境门的路径断言仍然成立。
   完整记录：`logs/env/13_seed_convert_env_repair.txt`。
   **警告**：转换跑完前**不要**在容器内重跑 `uv sync --frozen`（会删掉符号链接并以约 3 文件/秒重拷）。
2. **上游 `convert_all` 只在收尾写 manifest**：中途崩溃 → **没有 manifest.csv**，
   前期已转换的 npz 变成「看不见的产物」。这正是本切片把转换放进 detached worker、
   并以「状态文件 = 唯一真相源」轮询的原因。
3. **`--limit` 不是随机采样**：它是**按路径排序后的前 N 个**。用它做冒烟时抽到的样本
   不具代表性（本次 30 个恰好都是长 clip，平均体积 1.05 MiB vs 全量均值 652 KiB）。
4. **npz 不写进 worktree，而落 store**：worktree 内的 `data/`、`logs/` 都是指向
   `morphmimic-seed-data/repo/` 的符号链接；88.46 GiB 的产物必须落在 store 的 ext4/NFS 卷上。
   本地路径（`/mnt/test_cc_dev/...`）与容器路径（`/home/ubuntu/work_dev/...`）是**同一份文件**。
5. **`audit` 字节汇总必须用 `awk '%.0f'`**：`%d` 在总量 > `INT_MAX` 时饱和成 `2147483647`，
   曾静默误报「2 GiB」。日志 `logs/env/14_seed_npz_verify.txt` 里倒数第二条
   `SEED_NPZ_FILES count=142220 bytes=2147483647` 是**作废值**（修复前的输出），
   **有效值取最后一条 `bytes=94982502872`**。该修复有配套离线回归（`repro/tests/test_seed_npz_verify.sh`）。
6. **环境门必须 fail-closed**：torch 坏掉时，上游转换会把 142,220 个 clip **全部**标成
   `feas_reject="error: ..."`，而 manifest 看上去仍然「成功」。因此环境门先断言
   `import torch` + venv 规范路径 + `data/`/`logs/` store 软链，通过才允许进入转换。
7. **`logs/env/03_uv_sync.status` 的当前值是一次真实成功运行的结果**（`STATE=DONE` / `RC=0`，
   `FINISHED_AT=2026-11-13T02:58:50Z`）。此前 S02/S03 阶段那次 `uv sync --frozen` 因 NFS
   小文件写入过慢被人工终止（`EXIT 143 / Terminated`），当时该状态文件被如实标为 `FAILED/137`；
   后续在 torch 符号链接修好、uv cache 已就位的情况下重跑，`uv sync --frozen` **真实成功**
   （`UV_SYNC_OK`，torch 2.11.0+cu128 自检通过），状态文件随之被覆盖为 `DONE/0`。
   **两段历史都保留在 `logs/env/03_uv_sync.txt`**（该文件是追加写的）：早段为失败原文
   （`EXIT 143` + `ERROR: 'uv sync --frozen' failed`），后段为成功原文（`UV_SYNC_OK`）。
   torch 的符号链接时间戳未变（`Nov 12 20:28`），说明本次重跑**没有**破坏 S02 的环境修复。

---

## 6. 证据索引

| 路径 | 内容 |
|------|------|
| `logs/env/13_seed_convert.txt` | 转换主日志：`SEED_NPZ_ENV_OK` / `SEED_NPZ_START` / `SEED_NPZ_PROGRESS` / `SEED_SUBSET_OK`×5 / `SEED_SUBSET_NESTED` / `SEED_NPZ_CONVERT_OK`，以及 64 轮 `SEED_NPZ_NOTE round=<n> state=<S> done=<n> total=<n> pid=<p> restarts=<k>` 续跑锚点 |
| `logs/env/13_seed_convert.status` | 状态真相源（原子写）：`STATE=DONE` / `RC=0` / `PID=333027` / `CLIPS=142220` / `ROWS=142220` / `ERRORS=0` / `RATE=0.0000000000` / `ELAPSED=7496` / `STARTED_AT` / `FINISHED_AT` |
| `logs/env/13_seed_convert_worker.log` | detached worker 的 stdout：`space gate ok: … free=3965 GiB min=250 GiB`、`SEED_NPZ_START`、每 ~200 clip 一条 `SEED_NPZ_PROGRESS`、末尾 `SEED_NPZ_CONVERT_OK` |
| `logs/env/13_seed_convert_env_repair.txt` | 容器 torch 半拷贝事故的**症状 / 根因 / 修复 / 复验 / 警告**原文 |
| `logs/env/13_seed_convert_smoke.log` | 30 clip 冒烟的上游 stdout（tqdm 进度、过滤统计） |
| `logs/env/14_seed_npz_verify.txt` | 复核器输出：`SEED_NPZ_VERIFY_OK` / `SEED_NPZ_VERIFY_FAIL` / `SEED_NPZ_FILES` / `SEED_REPORT_NPZ_*`（`verify` 与 `audit` 共用此文件） |
| `logs/env/10_seed_extract.txt` | 上游证据链：`SEED_EXTRACT_FILES file=g1 count=142220`、124 条 `SEED_META_SESSION`、`SEED_META_MATCH matched=142220 missing=0 extra=0` |
| `logs/env/03_uv_sync.txt` | 环境同步日志（**追加**写入）：早期失败段 `EXIT 143 / Terminated / ERROR: 'uv sync --frozen' failed` 与后来的成功段 `UV_SYNC_OK` 同时保留 |
| `logs/env/03_uv_sync.status` | 最近一次 `uv sync --frozen` 的状态（当前为 `STATE=DONE` / `RC=0`）；**注意**它会被后续重跑覆盖，历史失败证据只在 `03_uv_sync.txt` 里（见 §5.7） |

**诊断命令（只读、秒级）**：

```bash
bash repro/lib/remote.sh 13_seed_convert.sh status        # STATE / PHASE / DONE / TOTAL / PID
bash repro/lib/remote.sh 13_seed_convert.sh env           # SEED_NPZ_ENV_OK（环境门）
bash repro/lib/remote.sh 13_seed_convert.sh verify        # 幂等终局复核
bash repro/lib/remote.sh 14_seed_npz_verify.sh verify     # 只读终局复核（秒级，进验证门）
bash repro/lib/remote.sh 14_seed_npz_verify.sh audit      # 全量文件计数（长命令，不进验证门）
bash repro/lib/remote.sh 14_seed_npz_verify.sh report     # 打印 SEED_REPORT_NPZ_* 数值
```

**离线单测（本地即可，零网络零载荷）**：

```bash
bash repro/tests/test_seed_npz.sh          # 纯函数库与 shell 库（35 项 shell 断言 + 44 项 python 用例）
bash repro/tests/test_seed_npz_verify.sh   # 复核器：1 正向 + 6 负向 fixture（10 passed / 0 failed）
```

---

## 7. 下游交接契约

- **S05（human50 sidecar）**：用 **本目录 `1h.yaml` 的 490 条 clip 列表**生成 human sidecar
  （上游 `morphmimic.scripts.convert_human --npz-root data/seed_g1_npz50 --bvh-root data/seed/soma_uniform/bvh`，
  再用 `check_human --subset-yaml data/seed_g1_npz50/subsets/1h.yaml` 对账）。
  sidecar 必须与 **同一份 `1h.yaml`** 对齐，不要另起子集。
- **S06（训练）**：训练读取 **`subsets/1h.yaml`**（`root:` 字段指向 npz 根目录，
  `clips:` 为相对路径）。
- **S08（评测）**：评测读取**同一份 `subsets/1h.yaml`**，与 S05/S06 完全一致——
  这是 S04 交付的**唯一子集契约**。
- **npz 的 `joint_names` 是 G1 的 29 个关节**（实测：`left_hip_pitch_joint` … `right_wrist_yaw_joint`），
  与 `g1_amber` 同集合（`g1_amber` 只是 `g1_spec()` 换了腰部阻尼，见
  `src/morphmimic/robots/g1_amber.py`），**可直接喂训练**。
- **npz 的 `body_names` 是 30 项**（实测：`pelvis` + 29 条 `*_link`），
  **不要按 29 硬编码**——29 是关节数，30 是刚体数。
- npz 的键集（实测）：
  `body_ang_vel_w, body_lin_vel_w, body_names, body_pos_w, body_quat_w, foot_dist, fps, joint_names, joint_pos, joint_vel, robot, root_body, z_min`；
  `fps == 50`（复核器抽样 200 条逐个断言）。

## 8. 本切片直接消费的 S02 结论（上游阅读与工具链）

| 消费的结论 | 出处 | 在本切片怎么被消费 | 机器可 grep 的证据 |
|---|---|---|---|
| 模块覆盖 103/103、0 缺失、0 空职责（`convert_seed` / `build_subsets` 的调用链与参数语义） | `docs/code_read/CODE_MAP.md` | `repro/13_seed_convert.sh` 的参数与失败语义按 CODE_MAP 的调用链确定 | `logs/env/06_code_read.txt` → `CODE_READ_OK` |
| GMR 子模块按锁定 SHA 落地并可导入 | `docs/code_read/TOOLCHAIN.md` | 转换链不依赖 GMR，但**同一条一键编排链**依赖它（GMR 缺失只打断 `--group teleop`） | `docs/code_read/TOOLCHAIN.md` → `TOOLCHAIN_GMR_VERDICT=VERIFIED` |
| 缺 GMR 时默认组仍成功、只有 teleop 组失败 | `logs/env/02_uv_sync_without_gmr.txt` | 解释"venv 看起来是好的但人接口链路不可用"的现象 | `logs/env/02_uv_sync_without_gmr.txt` |
| 重产物必须落在仓库之外的持久 store | `repro/lib/seed_store.sh` | 88.5 GiB 的 npz 落在 `<store>/data/seed_g1_npz50/`，worktree 内只是软链 | `logs/env/30_store_guard.txt` → `STORE_GUARD_OK` |

> 这些结论在复现记录第 10 节的证据索引表里逐行可 grep，不再只是"人读可查"。
