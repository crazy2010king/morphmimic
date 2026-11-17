# HUMAN_SIDECAR — G1 50 Hz npz → 24 关节 SMPL human50 sidecar（Slice S05 实测记录）

> 本文件是 **Slice S05**（`01-ttwecz-morphmimic` / `01-05-PLAN.md`）的终局事实记录。
> 所有数值均为本仓库实测，均可由文末「证据索引」中的日志与 marker 复现；**不手抄、不臆测**。
> 简体中文叙述，技术标识（marker / 路径 / 变量名 / 数值）保留原文。
> 上游逻辑**不重写**：直接调用仓库自带的 `morphmimic.scripts.convert_human` / `check_human`，
> 本切片只加 fail-closed 的可观测包装层与**只读独立复核器**。

---

## 1. 事实表

### 1.1 输入

| 项 | 实测值 | 来源 |
|----|--------|------|
| 子集 yaml | `data/seed_g1_npz50/subsets/1h.yaml`（S04 产出的唯一子集契约） | `logs/env/16_seed_human_verify.txt` 的 `config:` 行 |
| 1h 子集 clip 数 | **490** | `subset: … clips=490` |
| 1h 子集时长 | **1.0014277778 h** | `subset: … hours=1.0014277778` |
| yaml 内的 `root:` | `/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo/data/seed_g1_npz50`（容器内绝对路径，指向持久 store） | `logs/env/15_seed_human.txt` 的 `subset: root=…` |
| SOMA Uniform BVH 根 | `data/seed/soma_uniform/bvh`（S03 解包产物，142,220 个 bvh） | `repro/15_seed_human.sh` 的 `BVH_ROOT` |
| 容器可用核 | `nproc = 32`（本切片取 `--workers 28`，见 §4 偏离 #1） | `docs/code_read/NPZ_CONVERSION.md` §4 |

### 1.2 输出（sidecar）

| 产物 | 实测值 |
|------|--------|
| sidecar 根 | `data/seed_g1_npz50/human50` —— **上游默认 `<npz_root>/human50`**，落在持久 store（worktree 内 `data/` 是软链） |
| sidecar 文件数 | **490**（`SEED_HUMAN_SIDECARS count=490 bytes=122433164`） |
| sidecar 总字节 | **122,433,164 B ≈ 116.8 MiB ≈ 122.4 MB**（`find … -printf '%s\n'` 汇总） |
| session 目录数 | **97**（`ls data/seed_g1_npz50/human50 \| wc -l`） |
| 单条 sidecar 路径 | `data/seed_g1_npz50/human50/<session>/<stem>.npz`，例如 `human50/210707/walk_fast_forward_grab_injured_R_leg_001__A005_M.npz` |
| 命名对应关系 | robot npz / BVH / sidecar 三者的 **session 目录名与 stem 完全一致** |

**单个 sidecar 的键集（实测，用 `zipfile` + 手读 `.npy` 头解析，不依赖 numpy）**：

| 键 | dtype | shape | 含义 |
|----|-------|-------|------|
| `human_pos_w` | `<f4` | `(T, 24, 3)` | 世界系人关节位置，24 关节 × 3 |
| `human_quat_w` | `<f4` | `(T, 24, 4)` | 世界系人关节四元数（w,x,y,z），24 关节 × 4 |
| `human_joint_names` | `<U14` | `(24,)` | 关节名（见下） |
| `fps` | `<i8` | 标量 | **50** |
| `source_frames` | `<i8` | 标量 | 上游 BVH 源帧数（**不是** 50 Hz 帧数） |

**24 个关节名（实测，按 sidecar 内顺序）**：

```
Pelvis, Left_Hip, Right_Hip, Spine1, Left_Knee, Right_Knee, Spine2,
Left_Ankle, Right_Ankle, Spine3, Left_Foot, Right_Foot, Neck,
Left_Collar, Right_Collar, Head, Left_Shoulder, Right_Shoulder,
Left_Elbow, Right_Elbow, Left_Wrist, Right_Wrist, Left_Hand, Right_Hand
```

> `T`（50 Hz 帧数）**恒等于**对应 robot npz 的 `joint_pos` 长度——这是 S05 唯一认可的帧数基准，
> 理由见 §5 踩坑 #1。`source_frames` 是 BVH 里的 120 Hz 源帧数，**不可**当帧数用。

### 1.3 实测耗时

| 阶段 | 实测值 | 证据 |
|------|--------|------|
| 环境门（`15_seed_human.sh env`，含 morphmimic/numpy/scipy 探针） | **秒级（实测 ≈ 3–5 s）** | `logs/env/15_seed_human.txt` 的 `env` 段（`probe:` 行 + `SEED_HUMAN_ENV_OK`） |
| 转换（490 clip，冷：490 个全部新生成） | **elapsed_s = 22**（上游 tqdm 稳态 ≈ 48 it/s） | `SEED_HUMAN_CONVERT_OK … elapsed_s=22` |
| 转换（幂等重跑：490 个全部 skipped） | **elapsed_s = 9**（上游 tqdm ≈ 62124 it/s，只做存在性检查） | `SEED_HUMAN_CONVERT_OK … elapsed_s=9` |
| 上游 `check_human`（490 clip 全量对账） | **≈ 3 s**（tqdm ≈ 174 it/s） | `logs/env/15_seed_human.txt` 的 `check:` 段 |
| 只读独立复核（`16_seed_human_verify.sh verify`） | **≈ 5 s**（含 ssh + 容器内全部检查） | `logs/env/16_seed_human_verify.txt` 的时间戳 |

### 1.4 上游调用方式与命令原文

**本仓库包装层（实际执行）**：

```bash
# 转换（repro/15_seed_human.sh convert）
uv run --frozen --no-sync python -m morphmimic.scripts.convert_human \
    --npz-root data/seed_g1_npz50 \
    --bvh-root data/seed/soma_uniform/bvh \
    --human-root data/seed_g1_npz50/human50 \
    --subset-yaml data/seed_g1_npz50/subsets/1h.yaml \
    --workers 28

# 对账（repro/15_seed_human.sh convert 内）
uv run --frozen --no-sync python -m morphmimic.scripts.check_human \
    --subset-yaml data/seed_g1_npz50/subsets/1h.yaml \
    --human-root data/seed_g1_npz50/human50 \
    --out logs/env/check_human_1h.csv
```

**仓库 README 原文（对照）**：

```bash
uv run python -m morphmimic.scripts.convert_human --npz-root $DATA/seed_g1_npz50 \
  --bvh-root $DATA/seed/soma_uniform/bvh --workers 96
uv run python -m morphmimic.scripts.check_human \
  --subset-yaml $DATA/seed_g1_npz50/subsets/1h.yaml      # sidecars against their clips
```

注意 README 的 `convert_human` **没有** `--subset-yaml`（= 转全量），`check_human` 也**没有**
`--human-root`（= 用上游默认的 `<npz_root>/human50`）与 `--out`（= 不落 CSV）。

**上游 `convert_human.py` 文档字符串原文**：

```bash
uv run python -m morphmimic.scripts.convert_human --npz-root $DATA/seed_g1_npz50 \
  --bvh-root $DATA/seed/soma_uniform/bvh --workers 120
```

上游 `convert_human.py` 的文档字符串明说：`human_root` 默认 `<npz_root>/human50`，
「where `MotionLibrary` looks」——所以 sidecar 落在 `data/seed_g1_npz50/human50`，
下游 `MotionLibrary` / `env_cfg` / `eval` / `deploy` **不需要**到处显式传 `--human-root`。

### 1.5 终局 marker 原文（逐条粘贴）

来自 `logs/env/15_seed_human.txt` / `logs/env/15_seed_human.status` /
`logs/env/16_seed_human_verify.txt`：

```
SEED_HUMAN_ENV_OK clips=490 workers=28 python=3.11.16 numpy=2.4.6 scipy=1.17.1
SEED_HUMAN_CONVERT_OK clips=490 converted=490 skipped=0 failed=0 elapsed_s=22
SEED_HUMAN_SIDECARS count=490 bytes=122433164
SEED_HUMAN_CHECK_OK clips=490 missing=0 mismatch=0 feet_off=11
SEED_HUMAN_OK sidecars=490
SEED_HUMAN_VERIFY_OK clips=490 sidecars=490 missing=0 extra=0 frames_match=490 feet_off=11
SEED_REPORT_HUMAN_CLIPS=490
SEED_REPORT_HUMAN_SIDECARS=490
SEED_REPORT_HUMAN_MISSING=0
SEED_REPORT_HUMAN_EXTRA=0
SEED_REPORT_HUMAN_FRAMES_MATCH=490
SEED_REPORT_HUMAN_FEET_OFF=11
SEED_REPORT_HUMAN_OK=1
```

上游 `check_human` 的 stdout 原文：

```
490 clips, 0 missing sidecars, 0 mismatches, 11 feet_min_z outside [-0.05, 0.1] m
height ratio (robot / human pelvis): median 0.785, min 0.769, max 0.801
pelvis xy rms at that scale (m): median 0.004, max 0.072
```

状态文件 `logs/env/15_seed_human.status`（原子写，当前值来自幂等重跑那一轮）：

```
STATE=DONE
RC=0
CLIPS=490
CONVERTED=0
SKIPPED=490
FAILED=0
SIDECARS=490
FEET_OFF=11
ELAPSED=9
FINISHED_AT=2026-11-13T03:31:55Z
```

只读复核器的判定轨迹（`logs/env/16_seed_human_verify.txt`）：

```
subset: root=…/morphmimic-seed-data/repo/data/seed_g1_npz50 hours=1.0014277778 clips=490
root: yaml_root=…/morphmimic-seed-data/repo/data/seed_g1_npz50 npz_root=…/M001-ttwecz/data/seed_g1_npz50 same_root=1
sidecars: on_disk=490 expected=490 missing=0 extra=0
frames: frames_match=490 mismatch=0 errors=0
```

---

## 2. 上游语义缺口与已知限制：足部 z 越界 11 条

### 2.1 上游语义（原文）

`src/morphmimic/scripts/check_human.py`：

```python
FEET_Z_RANGE = (-0.05, 0.10)
...
feet_off = found[~found["feet_min_z"].between(lo, hi)]
...
f" {len(feet_off)} feet_min_z outside [{lo}, {hi}] m")
```

即：**上游对足部 z 越界只统计、只打印，不影响退出码**。
本次 490 条中越界 **11 条 = 2.24 %**，上游 `check_human` 仍以 **退出码 0** 结束。

本切片的处理原则：

- **不**改阈值（`[-0.05, 0.10] m` 是上游语义，不是本仓库的自由度）；
- **不**改数据（不删 clip、不重转、不动 BVH）；
- **不**把 `feet_off` 伪装成 0 —— 它以 `FEET_OFF=11` / `SEED_REPORT_HUMAN_FEET_OFF=11`
  如实记录、上报，**但不参与退出码判定**（与上游语义一致）。

### 2.2 11 条越界 clip 的真实数值（取自 `logs/env/check_human_1h.csv`）

阈值区间为 `[-0.05, 0.10] m`；本次 11 条**全部是上界越界**（`feet_min_z > 0.10`），
**没有一条**下界越界（`feet_min_z < -0.05`）。

| # | clip（`name` 列） | `feet_min_z` (m) | `robot_frames` | `human_frames` |
|---|-------------------|------------------|----------------|----------------|
| 1 | `crawl_ff_loop_360_002__A130_M` | 0.10506277531385422 | 229 | 229 |
| 2 | `crawl_ff_start_180_R_002__A215` | 0.10054933279752731 | 458 | 458 |
| 3 | `crawl_ff_start_315_R_003__A215` | 0.1055298000574112 | 566 | 566 |
| 4 | `crawl_ff_stop_360_R_001__A214_M` | 0.13133415579795837 | 688 | 688 |
| 5 | `elbow_plank_001__A360_M` | 0.12738943099975586 | 408 | 408 |
| 6 | `kneeling_loop_002__A047` | 0.2189899981021881 | 617 | 617 |
| 7 | `kneeling_loop_003__A034_M` | 0.14825831353664398 | 556 | 556 |
| 8 | `mohak_backward_start_001__A128_M` | 0.15498672425746918 | 287 | 287 |
| 9 | `mohak_forward_loop_101__A124` | 0.1285829246044159 | 181 | 181 |
| 10 | `mohak_forward_stop_003__A123_M` | 0.1128617376089096 | 350 | 350 |
| 11 | `on_all_fours_idle_loop_001__A203` | 0.15517130494117737 | 821 | 821 |

**数值区间**：`feet_min_z ∈ [0.10054933279752731, 0.2189899981021881] m`，
即全部落在「略微超过 0.10 m 上界」到「0.219 m」之间。

**语义解读**：这 11 条的动作名全部是**语义上就该四肢/双足着地**的动作
（`crawl_*` 爬行、`kneeling_*` 跪姿、`elbow_plank_*` 肘撑平板、`mohak_*` 匍匐、
`on_all_fours_*` 四足着地）。这类动作里「人」的最低足部 z 高于 0.10 m 阈值是
**动作语义正常**的结果，不是 retarget 缺陷。帧数一栏全部 `robot_frames == human_frames`，
说明这 11 条的**帧数对齐没有问题**，越界只发生在足部 z 的取值上。

> **不做的事**：不调阈值、不剔除这 11 条、不重转、不把 11 写成 0。
> 这 11 条**必须**作为「已知限制」原样传给下游（S06 训练、S08 人接口评测）。

---

## 3. 只读独立复核器（不信任上游输出）

`repro/16_seed_human_verify.sh`（子命令 `verify` / `report`）**不调用上游 `check_human`**，
自己用 `repro/lib/seed_human.py`（**纯标准库**，容器系统 `python3` 无 numpy 也能跑）证明三件事：

| 断言 | 判据 | 实测 |
|------|------|------|
| (a) sidecar 集合与 `subsets/1h.yaml` **双向精确一致** | `missing == 0 且 extra == 0` | missing=0 / extra=0 |
| (b) 每条 sidecar 的帧数 == 对应 robot npz 的 `joint_pos` 长度 | 逐条比较，`frames_match == 490` | frames_match=490 / mismatch=0 / errors=0 |
| (c) yaml 的 `root:` 与本机 npz 根指向同一份数据 | `realpath` 比较（yaml 写的是持久 store 绝对路径，与 worktree 路径不同但同 inode） | `same_root=1` |

失败路径只打印 `SEED_HUMAN_VERIFY_FAIL reason=<…>`（固定 reason 集合：
`sidecar-count` / `sidecar-missing` / `sidecar-extra` / `frames-mismatch` /
`subset-root-mismatch` / `subset-missing` / `subset-unparsable`）并返回非零，
**绝不打印任何 OK marker**（S03/S04 的「失败路径零 OK marker」约定）。

`report` 子命令打印可直接回填本文档的 `SEED_REPORT_HUMAN_*` 数值。

---

## 4. 相对上游 README 的偏离清单

| # | 偏离 | 实测值 | 代价 / 原因 |
|---|------|--------|------------|
| 1 | `--workers 28`，非 README 的 96 / 上游 docstring 的 120 | 28 | 容器 `ros_dev` 实测 `nproc = 32`；再高只会加剧 NFS 小文件写竞争。490 条实测 22 s，远未触到瓶颈 |
| 2 | **只转 1h 子集 490 条**，非上游默认的全量 142,220 | 490 | 本切片按 R009 只做 1h；按实测 48 it/s 折算全量约 **50–65 min**，留作 follow-up，**不在 S05 范围** |
| 3 | `check_human` 额外加 `--out logs/env/check_human_1h.csv` | 490 行 + 表头 | 上游不写文件；加 `--out` 才能留下**逐 clip** 的 `feet_min_z` / `height_ratio` / `pelvis_xy_rms` 表作为 §2.2 的证据 |
| 4 | 审计口径：`repro/14_seed_npz_verify.sh` 的 npz 计数**排除** `human50/` | `SEED_NPZ_FILES count=142220`（未剪枝会是 142,710） | `human50/` 是 S05 的 sidecar 根，**不是**机器人 npz 的一部分；不剪枝会破坏 S04 的「npz 文件数 == manifest 行数 == 142,220」核心证据 |
| 5 | sidecar 落 `data/seed_g1_npz50/human50`（= 上游默认 `<npz_root>/human50`） | 落在持久 store | 与上游默认一致，因此下游无需显式传 `--human-root`；落在 store 而非 worktree 实体目录，与 S03/S04 的载荷策略一致 |
| 6 | sidecar 总体积实测 **122,433,164 B ≈ 116.8 MiB**，切片计划里估的是「约 119 MB」 | 差 ≈ 3 MB | 计划值是**估算**（未按实际帧数分布加权）；实测值以 `SEED_HUMAN_SIDECARS count=490 bytes=122433164` 为准。两者口径一致（同一 `find -printf '%s'` 汇总），仅绝对值有偏差 |

---

## 5. 踩坑

1. **BVH 头 `Frame Time: 0.008333` 是 1/120 被截断到 6 位的值**，用它反推期望帧数会让 490 条里 **40 条**差 −1。
   因此**判定路径禁止**用 BVH 头推导期望帧数，帧数基准**唯一**取 robot npz 的 `joint_pos` 长度。
   这个陷阱被固化在 `repro/lib/seed_human.py` 的 `bvh_header_frame_time` /
   `frames_from_bvh_header`（**仅供单测证明陷阱**）与 `repro/tests/test_seed_human.py` 的用例里。
2. **上游 `convert_human` 失败仍 exit 0**：单个 clip 失败被隔离成 `[FAILED] …`，
   汇总行是 `converted N, skipped M, failed K`，**进程退出码仍是 0**。
   直接调用上游会拿到「failed=12 也算成功」的**假绿**。
   `repro/15_seed_human.sh` 因此**解析 stdout 的汇总行并断言 `failed == 0` 且 `converted + skipped == 490`**。
3. **不带 `--subset-yaml` 会自噬**：上游会走 `Path(npz_root).glob("*/*.npz")`，
   一旦 `human50/` 建好就会把自己的 sidecar 当成待转 clip，产生大量 `[FAILED]`。
   `repro/15_seed_human.sh` 因此**必须**传 `--subset-yaml`（离线单测里有源码级断言锁住这一点）。
4. **容器解释器选择**：系统 `python3` **没有 numpy**，`repro/lib/seed_human.py` 必须保持**纯标准库**；
   需要 numpy/scipy/morphmimic 的活儿走容器 venv（`.venv/bin/python` 或 `uv run --frozen --no-sync python`）。
   `SEED_HUMAN_PY` 环境变量是复核器指定解释器的覆盖点（默认 `python3`）。
5. **上游 `check_human` 对足部 z 只统计不判失败**（见 §2.1）：足部结论**必须**单独打点写进文档，
   **不能**用退出码表达，也不能因为退出码是 0 就当 11 条不存在。
6. **`sidecar` 的 `T` 与 `source_frames` 不是一回事**：`source_frames` 是 BVH 的 120 Hz 源帧数
   （实测例：541 帧的 sidecar 对应 `source_frames=1299`），50 Hz 帧数 `T` 才与 `joint_pos` 对齐。

---

## 6. 下游交接契约

- **S06（训练）与 S08（人接口评测）必须使用同一份 `data/seed_g1_npz50/subsets/1h.yaml`
  与同一个 sidecar 根 `data/seed_g1_npz50/human50`**。
  不要另起子集（`build_subsets` 的洗牌由 `--seed` 决定，不同 seed 会得到不同的 490 条集合）。
- **490/490 是硬约束**：`MotionLibrary` 要求「每个 clip 都有 sidecar 或都没有」
  （部分有、部分没有会让 loader 行为不可预期）。当前实测 `missing=0 / extra=0`，即两侧都严格齐平。
- 帧数契约：sidecar 的 `T` == robot npz 的 `joint_pos` 长度（490/490 逐条相等）。
- 足部契约：这 11 条 `feet_min_z` 越界是**已知限制**，下游评测时按上游语义
  **只报告不判失败**；不要在 S06/S08 私自改阈值或剔除 clip（那样会让 S05 的
  `SEED_REPORT_HUMAN_*` 与下游结果对不上）。
- 训练侧若要加 `--kp-interface`，需要 `--human-root`；因为 sidecar 落在上游默认位置
  `<npz_root>/human50`，通常可以直接省略。

---

## 7. 证据索引

| 路径 | 内容 |
|------|------|
| `logs/env/15_seed_human.txt` | 转换编排器主日志：`SEED_HUMAN_ENV_OK` / `SEED_HUMAN_CONVERT_OK` / `SEED_HUMAN_SIDECARS` / `SEED_HUMAN_CHECK_OK` / `SEED_HUMAN_OK`，以及上游 `convert human` / `check human` 的 tqdm 原始输出 |
| `logs/env/15_seed_human.status` | 状态真相源（原子写）：`STATE=DONE` / `RC=0` / `CLIPS=490` / `CONVERTED` / `SKIPPED` / `FAILED` / `SIDECARS=490` / `FEET_OFF=11` / `ELAPSED` / `FINISHED_AT` |
| `logs/env/16_seed_human_verify.txt` | 只读复核器判定轨迹：config / subset / root / sidecars / frames 汇总行 + `SEED_HUMAN_VERIFY_OK` + `SEED_REPORT_HUMAN_*` |
| `logs/env/check_human_1h.csv` | 上游逐 clip 表（490 行 + 表头）：`name, robot_frames, human_frames, frames_match, feet_min_z, height_ratio, pelvis_xy_rms_m, sidecar`；§2.2 的 11 条数值取自此文件 |
| `data/seed_g1_npz50/human50/` | sidecar 本体（490 个 npz / 97 个 session 目录 / 122,433,164 B），落在持久 store |
| `repro/15_seed_human.sh` | fail-closed 转换编排器（`env` / `convert` / `status`） |
| `repro/16_seed_human_verify.sh` | 只读独立复核器（`verify` / `report`） |
| `repro/lib/seed_human.py` | 纯标准库判定底座（sidecar 集合双向差集、numpy-free npz 帧数读取、BVH 头陷阱隔离） |
| `repro/tests/test_seed_human.sh` / `repro/tests/test_seed_human.py` | 离线负向 fixture 单测（bash 电池 + stdlib unittest） |

**诊断命令（只读、秒级）**：

```bash
bash repro/lib/remote.sh 15_seed_human.sh status                    # STATE/RC/CLIPS/SIDECARS/FEET_OFF
bash repro/lib/remote.sh 16_seed_human_verify.sh verify              # SEED_HUMAN_VERIFY_OK（进宿主验证门）
bash repro/lib/remote.sh 16_seed_human_verify.sh report              # SEED_REPORT_HUMAN_* 数值
bash repro/lib/remote.sh 15_seed_human.sh env                       # SEED_HUMAN_ENV_OK（环境门）
```

**离线单测（本地即可，零网络零载荷）**：

```bash
bash repro/tests/test_seed_human_lib.sh   # 判定底座的库级电池（32 PASS / 0 FAIL）
bash repro/tests/test_seed_human.sh        # 复核器负向 fixture（36 PASS / 0 FAIL）
```

---

## 8. 相对同族文档的衔接

- `docs/code_read/SEED_ACQUISITION.md` —— 数据从哪来（下载 / 校验 / 解包 / 对账）。
- `docs/code_read/NPZ_CONVERSION.md` —— G1 CSV → 50 Hz npz 与五档子集（`1h.yaml` 的来源）。
- `docs/code_read/HUMAN_SIDECAR.md`（本文件）—— npz → 24 关节 SMPL human50 sidecar 与一致性校验。

### 本切片直接消费的 S02 结论

| 消费的结论 | 出处 | 在本切片怎么被消费 | 机器可 grep 的证据 |
|---|---|---|---|
| 模块覆盖 103/103、0 缺失、0 空职责（调用链与职责以 CODE_MAP.md 为准） | `docs/code_read/CODE_MAP.md` | `convert_human` / `check_human` 的调用链与参数语义按 CODE_MAP 的 10 条关键调用链确定 | `logs/env/06_code_read.txt` → `CODE_READ_OK` |
| GMR 子模块已按锁定 SHA 落地并可导入（teleop 组依赖它） | `docs/code_read/TOOLCHAIN.md` | 人接口链路（`--kp-interface` → teleop 组 → GMR）的前提；缺失时 `uv sync --frozen --group teleop` 直接失败 | `docs/code_read/TOOLCHAIN.md` → `TOOLCHAIN_GMR_VERDICT=VERIFIED` |
| 缺 GMR 时**只有 teleop 组**失败，默认组仍成功 | `logs/env/02_uv_sync_without_gmr.txt` | 解释 S05 首次复跑时的 venv 漂移现象（默认组可用 ≠ 全链路可用） | `logs/env/02_uv_sync_without_gmr.txt` |
| 重产物必须落在仓库之外的持久 store（否则会被 worktree 重建删除） | `repro/lib/seed_store.sh` | sidecar（490 个 npz，116.8 MiB）落在 `<store>/data/seed_g1_npz50/human50/` | `logs/env/30_store_guard.txt` → `STORE_GUARD_OK` |

> 这四条结论现在也是**机器可判定**的：复现记录第 10 节的证据索引表逐行引用了上表的证据文件与 marker。
