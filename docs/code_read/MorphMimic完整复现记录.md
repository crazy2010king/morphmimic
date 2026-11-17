# MorphMimic 完整复现记录

> **流程复现，非数值等价复现。**
>
> 本记录复现的是 MorphMimic（v0.1，上游仓库 `morphmimic`，论文 *Morphology-Conditioned World
> Model and Policy Sharing Across Humanoids*）的**完整流程**：从空环境到数据获取、转换、训练、
> 导出、部署回放、双接口评测、官方权重的同口径对照，直到人接口通路回放。**它不声称数值等价**：
> 本次只训练了 g1_amber 单一形态学、只训到 26,413 迭代（官方发布策略为 60,000 迭代）、
> 只用了 1 h 子集，且换过学习率衰减长度与编译选项。把本文任何数字与官方论文/官方权重的结果
> 直接相减，都是**无效比较**。
>
> 受众假设：你**从未参与**本项目。你不需要读过上游代码，只需要能打开终端、进入
> `ros_dev` 容器、按下文给出的命令。

## 三个测量面（本记录严格分离，互不换算）

| 测量面 | 口径 | 规模 | 产物 | 说明 |
|---|---|---|---|---|
| sim2sim 部署回放（自训 vs 官方） | 逐 clip 的关节/身体/末端漂移误差 | **49 条**采样 | `runs/sim2sim/`、`runs/official/compare_self_vs_official.csv` | 1 h 子集 490 条**按清单顺序每 10 条取 1 条**（确定性，非随机） |
| eval 基准（双接口） | `failed` 列重算的 completion | **490 条 × 2 接口** | `runs/eval/eval_motion_1h.csv`、`runs/eval/eval_human_full_1h.csv` | motion 与 human 各 490 行 |
| 人接口通路 | 回放步数 / 跌倒数 / 位移 | **700 步** | `runs/human/` | session 的「操作者」是 G1 自身轨迹，只证明通路可执行 |

三者分母、指标定义与产物落点都不同，**不可互相换算**（依据见第 7 章）。

## completion 1.000000 是**未调参**结果

motion 与 human 两个接口在 490 条 clip 上 `failed` 列全为 `False`，由 `failed` 列**重算**得到的
completion 为 **1.000000**。这个数字**没有**为了追平任何阈值而调整训练超参：训练仍在
**26,413** 迭代处结束（`out/g1_amber/MANIFEST.txt` 的 `iteration 26413`），官方发布策略是
**60,000** 迭代，学习率衰减长度也被显式对齐到实际迭代数（见第 3 章偏离 #17）。若将来在更长子集
或别的形态学上 completion 低于 0.8，应如实写归因（单机器人 / 迭代更少 / 只见一种形态学），
**不得调参追平**。

## 失败路径被真实验过（不是"理论上会失败"）

本复现过程中至少三条失败路径是**实跑**出来的，原文留档：

1. **子模块落地失败路径**：`repro/02_submodules.sh` 在 GMR 缺失时把失败证据写入
   `logs/env/02_uv_sync_without_gmr.txt`（`logs/env/00_env.txt` 记录了该步 `EXIT 1`）。
2. **导出 staging 校验失败**：`EXPORT_NEG_FAIL reason=staging-verify-failed`
   （`logs/env/19_export_negatives.txt`）——staging 未通过则**不发布**正式产物。
3. **部署复核器三条真负例**：`DEPLOY_VERIFY_FAIL reason=official-sha-mismatch` /
   `reason=eval-row-count-mismatch` / `reason=video-missing`
   （`logs/env/26_deploy_verify_negatives.txt`）——复核器自行重算摘要、自行数行，**不是只会报 OK**。
4. **下载传输失败**：`SEED_DL_TRANSFER_FAIL`（`logs/env/08_seed_download_worker.log`），由指数退避重试覆盖。

## 本记录的机器可判定性

「每条结论可回溯到具体命令与输出证据」不是散文承诺：第 2 章给出阶段 → 命令 → marker → 日志的
总表，第 10 章给出**证据索引表**（逐行断言：证据文件存在 + 关键输出能在该文件中 grep 到）。
本文档本身由 `repro/28_doc_verify.sh verify` 校验，判定逻辑在 stdlib-only 的
`repro/lib/doc.py`；本文档里的所有关键数字（SHA-256、eval 行数、completion、Δ 均值、曲线 step
覆盖）都由该校验器**从磁盘产物重算比对**，不采信本文的自述。

---

<!-- DOC_SECTION:1 -->
## 1. 环境事实表

全部数值可在 `logs/env/snapshot.txt` 与 `logs/env/00_env.txt` 中逐值 grep 到。

| 项 | 实测值 | 证据文件 |
|---|---|---|
| GPU | NVIDIA GeForce RTX 4090，24564 MiB，驱动 595.99.02，CUDA 13.2 | `logs/env/snapshot.txt` |
| 主机内存 | 62 GiB 总量（训练期宿主峰值 7.00 GB） | `logs/env/snapshot.txt`、`logs/env/17_train.txt` |
| 磁盘 | NFS 导出 7.3T，已用 3.1T，可用 3.8T（45%） | `logs/env/snapshot.txt` |
| OS / 内核 | Ubuntu 22.04.4 LTS，Linux 6.8.0-138-generic x86_64，nproc = 32 | `logs/env/snapshot.txt` |
| 容器 | `ros_dev`（所有脚本在容器内执行，宿主侧通过 `repro/lib/remote.sh` 进入） | `logs/env/snapshot.txt`、`logs/env/00_env.txt` |
| 代理 | `http://172.16.119.20:40381`，**仅内联到进程环境**，系统配置零代理痕迹 | `logs/env/snapshot.txt` |
| Python / venv | venv Python 3.11.16，torch 2.11.0+cu128，onnx 1.23.2，onnxruntime 1.31.0，onnxscript 0.7.2 | `logs/env/19_export.txt` |
| 依赖锁 | `uv.lock` sha256 `9e46033eb80c8f4215b0043e15473603941958c32869ce024847bb7c57bc6b71`（306,963 B） | `logs/env/snapshot.txt` |
| 工具链 | `uv 0.12.6`；mjlab 1.6.0 / mujoco 3.11.0 / mujoco-warp 3.11.0 / warp-lang 1.17.0 | `logs/env/snapshot.txt` |

**代理纪律**：代理变量只存在于脚本进程内（`repro/lib/common.sh` 内联），**不写**任何系统配置
（`/etc/environment`、`/etc/profile*`、`~/.bashrc`、`uv.toml`、`pip.conf`、`gitconfig`）。
`logs/env/snapshot.txt` 的 `system_config_proxy_scan` 逐文件记录了扫描结论（全部 clean）。

**工作树与存储**：本仓库是 linked worktree，`logs/`、`runs/`、`out/`、`assets/`、`data/` 都是指向
共享 seed store 的**相对符号链接**；容器与宿主看到的是同一份 NFS 文件，本地修改 ≡ 远程修改。

> 唯一的例外是 `docs/code_doc`：它不是 store 链接，而是指向**用户文档仓库**（交付出口）的绝对软链，
> 因为那里的路径只有宿主机知道，容器侧不可解析。交付记录因此保留**三份副本**——
> git 内的 `docs/code_read/MorphMimic完整复现记录.md`（随仓库走）、store 内的
> `<store>/docs/code_doc/`（持久副本）、以及这个交付出口；三份由
> `bash repro/30_store_guard.sh doc` **逐字节**比对（`SEED_STORE_DOC_OK copies=3`）。
> 换句话说：**store 里的软链一律相对**（两侧可解析），**交付出口是绝对路径**（只在宿主侧可解析），
> 两者职责不同，不可混用。

**持久 store：重产物的固定位置（本次复现新增的硬契约）**

| 视角 | store 根 |
|---|---|
| 本地开发机 | `/mnt/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |
| 远端容器 | `/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |

同一份 NFS 导出、两个挂载前缀，因此 worktree 内的软链一律用**相对路径**
`../../../morphmimic-seed-data/repo/<name>`，两侧解析到同一批字节。store 根由
`repro/lib/seed_store.sh` 解析（`SEED_STORE_ROOT` → 前缀探测 → 脚本自身所在目录），
受保护目录为 `data` / `logs` / `out` / `assets` / `runs`（`SEED_PROTECTED`）。

**为什么必须是 store（两次真实事故，不是理论风险）**

| 日期 | 丢了什么 | 根因 |
|---|---|---|
| 2026-11-11 | `data/seed/_archives/g1.tar.gz` 的 23.5 GB + 已完成的 metadata CSV | GSD reconcile 递归删除「未注册 git 的残留 worktree」，未跟踪文件一并消失 |
| 2026-11-11 | 工具链探针的**全部**产物（`logs/toolchain/**`：三个克隆仓库、两个隔离 venv、pybind11 构建树） | 探针跑在 store 机制建立**之前**，产物写进了 worktree 的普通 `logs/` 目录 |

**现在的机制**

1. `repro/lib/seed_store.sh` 是 store 契约的单一事实源。旧实现 `if [ -e "$REPO_ROOT/$name" ]; then return 0; fi`
   会在 worktree 被重建（软链变回普通目录）时**继续把产物写进即将被删的目录**——这正是第二次事故的机制。
   现在软链状态被显式区分：`linked`（就绪）/ `diverged`（普通目录，拒绝并给出修复命令）/ `foreign`（指向别处，永不触碰）。
2. `bash repro/30_store_guard.sh migrate` 把普通目录的内容**递归归并**进 store：同名同内容去重（sha256 比对后），
   同名不同内容报 `CONFLICT` 并**原样保留**，绝不删除；随后把路径换成相对软链。
3. `bash repro/30_store_guard.sh check` 是 fail-closed 的体检；`manifest` 写 `<store>/MANIFEST.txt`
   （目录条目数 + 关键产物的 sha256 + seed 归档校验和 + 训练产物清单），用于**发现"没人看着时被删掉"**。
4. `repro/00_env.sh` 一键编排**以 store 体检为前置**，`repro/28_doc_verify.sh verify` 也先体检 store
   （本记录引用的证据文件全在 store 里）。store 不健康就不产出新产物。
5. 工具链探针的落点改为显式的 `$SEED_STORE_ROOT/logs/toolchain`，并在 probe 前做 store 守卫
   （`store_guard logs` 不通过即 `TOOLCHAIN_FAIL reason=store-not-linked`）。
6. 交付记录有三个副本：git 内的 `docs/code_read/MorphMimic完整复现记录.md`（随仓库走）、
   store 内的 `<store>/docs/code_doc/`（持久副本）、交付出口 `docs/code_doc`（用户文档仓库）。
   `bash repro/30_store_guard.sh doc` 同步并**逐字节**比对三份（`SEED_STORE_DOC_OK copies=3 sha256=…`）。

**当前存量**（`<store>/MANIFEST.txt`，2026-11-16 实测）：`data` 478 GB（seed 归档 64 GB、解包 390 GB、npz 88.5 GiB）、
`logs` 5.6 GB（训练产物 3.0 GB）、`out` 63 MB（`policy.onnx` sha256 `476a90cb…`）、`runs` 240 MB、`assets` 37 MB。
store 根在 NFS 导出（7.3 T，已用 3.1 T，可用 3.8 T）上，**不在任何 git worktree 内**。

**事实源只有一个**：仓库内的 `repro/` 与 `docs/code_read/` 是**唯一事实源**。store 里可能残留的
历史副本一律放在 `<store>/_quarantine/`（保留可回退，但**任何脚本都不得从中读取**）——
2026-11-16 已把两个陈旧快照（`repro-snapshot-*`、`docs-code_read-snapshot-*`）移入该目录。

**团队规范**：`docs/code_read/PERSISTENT_STORE.md` —— 持久 store 的使用规范（硬规则、受保护目录清单、
软链三态与处置、写脚本的禁止事项、故障处置手册、提交前自检清单）。写任何落盘脚本前先读它。

<!-- /DOC_SECTION:1 -->

<!-- DOC_SECTION:2 -->
## 2. 每阶段命令原文与关键输出

命令统一在 `ros_dev` 容器内执行；宿主侧用 `bash repro/lib/remote.sh <脚本>` 进入并透传退出码。
下表是**阶段 → 命令 → 终局 marker → 日志落点**的总表；每一行的 marker 原文都能在该行日志里
grep 到（见第 10 章证据索引表逐行断言）。

| 阶段 | 命令原文 | 关键输出（marker） | 日志文件 |
|---|---|---|---|
| 01 环境快照 | `bash repro/lib/remote.sh 01_snapshot.sh` | `SNAPSHOT_OK` | `logs/env/snapshot.txt` |
| 02 子模块落地 | `bash repro/lib/remote.sh 02_submodules.sh` | `SUBMODULES_OK` | `logs/env/02_submodules.txt` |
| 03 依赖同步 | `bash repro/lib/remote.sh 03_uv_sync.sh` | `UV_SYNC_OK` | `logs/env/03_uv_sync.txt` |
| 08 数据下载 | `bash repro/lib/remote.sh 08_seed_download.sh start` | `SEED_DOWNLOAD_OK files=3 bytes=68688061944` | `logs/env/08_seed_download.txt` |
| 09 归档校验 | `bash repro/lib/remote.sh 09_seed_verify.sh verify` | `SEED_VERIFY_OK archives=2 clips=284440` | `logs/env/09_seed_verify.txt` |
| 10 解包对账 | `bash repro/lib/remote.sh 10_seed_extract.sh verify` | `SEED_EXTRACT_OK files=284440` | `logs/env/10_seed_extract.txt` |
| 13 G1→npz 转换 | `bash repro/lib/remote.sh 13_seed_convert.sh verify` | `SEED_NPZ_CONVERT_OK clips=142220 rows=142220 kept=129398 errors=0 error_rate=0.0000000000 elapsed_s=7496` | `logs/env/13_seed_convert.txt` |
| 14 npz 复核 | `bash repro/lib/remote.sh 14_seed_npz_verify.sh verify` | `SEED_NPZ_VERIFY_OK rows=142220 errors=0 rate=0.0000000000 kept=129398 subsets=5 sampled=200` | `logs/env/14_seed_npz_verify.txt` |
| 15 人 sidecar 转换 | `bash repro/lib/remote.sh 15_seed_human.sh convert` | `SEED_HUMAN_CONVERT_OK clips=490 converted=490 skipped=0 failed=0 elapsed_s=22` | `logs/env/15_seed_human.txt` |
| 16 sidecar 复核 | `bash repro/lib/remote.sh 16_seed_human_verify.sh verify` | `SEED_HUMAN_VERIFY_OK clips=490 sidecars=490 missing=0 extra=0 frames_match=490 feet_off=11` | `logs/env/16_seed_human_verify.txt` |
| 17 训练 | `bash repro/lib/remote.sh 17_train.sh start` | `TRAIN_TRAIN_OK iterations=26413 it_per_s=1.1112 gpu_peak_gb=18.65 host_peak_gb=7.00 elapsed_s=2284` | `logs/env/17_train.txt`、`logs/env/17_train_worker.log` |
| 18 训练终局复核 | `bash repro/lib/remote.sh 18_train_verify.sh verify` | `TRAIN_VERIFY_OK ckpts=9 latest=1 tb_tags=52 nan_whitelist=2 resume_events=9 gpu_peak_mb=19094.0 host_peak_gb=7.0 wall_s=2284 iterations=26413 lr_decay_iters=26413` | `logs/env/18_train_verify.txt` |
| 19 ONNX 导出 | `bash repro/lib/remote.sh 19_export.sh export` | `EXPORT_EXPORT_OK` | `logs/env/19_export.txt` |
| 20 导出终局复核 | `bash repro/lib/remote.sh 20_export_verify.sh verify` | `EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber` | `logs/env/20_export_verify.txt` |
| 21 资产导出 | `bash repro/lib/remote.sh 21_assets.sh export` | `DEPLOY_ASSETS_OK clips=49 xml=assets/g1_amber.xml` | `logs/env/21_assets.txt` |
| 22 仿真回放 | `bash repro/lib/remote.sh 22_sim2sim.sh run` | `DEPLOY_SIM_OK clips=49 completed=49 video_ok=49 parity=49/49` | `logs/env/22_sim2sim.txt` |
| 23 双接口评测 | `bash repro/lib/remote.sh 23_eval.sh motion` / `human` | `DEPLOY_EVAL_OK interface=motion rows=490 completion=1.000000`、`DEPLOY_EVAL_OK interface=human rows=490 completion=1.000000` | `logs/env/23_eval.txt` |
| 24 官方权重与对照 | `bash repro/lib/remote.sh 24_official.sh download` / `compare` | `DEPLOY_OFFICIAL_OK files=6 sha_files=4`、`DEPLOY_OFFICIAL_COMPARE_OK rows=49` | `logs/env/24_official.txt` |
| 25 人接口回放 | `bash repro/lib/remote.sh 25_human_replay.sh run` | `DEPLOY_HUMAN_OK steps=700 falls=0` | `logs/env/25_human_replay.txt` |
| 26 部署终局复核 | `bash repro/lib/remote.sh 26_deploy_verify.sh verify` | `DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700` | `logs/env/26_deploy_verify.txt` |
| 27 训练曲线数据 | `bash repro/lib/remote.sh 27_train_curves.sh verify` | `TRAIN_CURVES_OK events_files=10 tags=52 rows=28120 steps=26413 csv=runs/train_curves/g1_amber_1h_curves.csv` | `logs/env/27_train_curves.txt` |
| 28 复现记录校验 | `bash repro/28_doc_verify.sh verify` | `DOC_VERIFY_OK sections=9 evidence_rows=48 sha_ok=1 eval_rows=490 compare_rows=49 curve_rows=28120` | `logs/env/28_doc_verify.txt` |

**每阶段都有独立的只读复核器**（`18` / `20` / `26` / `28`），它们**不采信编排器的自述**，只从磁盘
产物重新推导；失败路径只打印固定 reason 集合且**零 OK marker**。

<!-- /DOC_SECTION:2 -->

<!-- DOC_SECTION:3 -->
## 3. 对 README 的偏离清单

下表是**合并去重后**的全部偏离（上游 README / 上游 docstring / 原始切片计划 vs 本次实测做法）。
每条给出「README 原文 → 我们的做法 → 原因 → 代价」，并指向 `docs/code_read/` 下的来源锚点。
完整的分阶段细节见那 8 份实测文档，本章只给索引 + 结论。

| # | README / 计划原文 | 我们的做法 | 原因 | 代价 | 来源锚点 |
|---|---|---|---|---|---|
| 1 | G1 段让用户下载 `seed_metadata_v003.csv` | 实际用 `seed_metadata_v004.csv` | 数据集只提供 v004（README 多机器人段自己用的就是 v004），上游 `convert_seed` 的 docstring 仍写 v003 | 元数据版本错配会导致 clip 被**静默丢弃** | `SEED_ACQUISITION.md` §5；`CODE_MAP.md` ⑤-1 |
| 2 | 用 `hf download` 断点续传 | 自管 `curl -L -C -` + `.part` 文件 + 指数退避 | hf CLI 不可续传，且 Xet 路径对 23 GB / 45 GB 大 tar **挂死** | 多写了下载器与状态机，但获得了可续传与可观测 | `SEED_ACQUISITION.md` §5、§6 |
| 3 | 计划写三文件合计 68,688,061,944 B | 三文件合计 **68,834,473,552 B** | 计划口径是**两个归档**之和（不含 metadata） | 仅口径差，事实以 `SEED_TOTAL_BYTES_ALL` 为准 | `SEED_ACQUISITION.md` §5 |
| 4 | 解包到 `data/seed/` 下 | 解包到 `data/seed/_archives/` | 归档实际落点如此 | 与计划意图一致，落地结果等价 | `SEED_ACQUISITION.md` §5 |
| 5 | `convert_seed --workers 96` | `--workers 28` | 容器 `nproc = 32`，再高只加剧 NFS 小文件写竞争 | 18.97 clip/s 已在 CPU 饱和区间，转换总耗时 7,496 s | `NPZ_CONVERSION.md` §4 |
| 6 | npz 输出到 worktree 实体目录 | 输出到共享 store（88.46 GiB） | worktree 会被 GSD 清理删除 | 落点不再随 worktree 生命周期 | `NPZ_CONVERSION.md` §4 |
| 7 | 终局校验重算全量 sha256 | 校验用 manifest 行数 + 200 抽样；全量 sha256 单独跑 | 68.7 GB 重算实测 518 s，会顶满验证门超时 | 归档级 sha256 仍由 `logs/env/sha256sum_check.txt` 独立留证 | `NPZ_CONVERSION.md` §4；`SEED_ACQUISITION.md` §6 |
| 8 | `--limit` 语义未强调 | 明确为**排序后前 N 个**（上游实现如此） | 上游 docstring 原文即此语义 | 冒烟抽样不是随机采样，结论需按此理解 | `NPZ_CONVERSION.md` §4 |
| 9 | `build_subsets` 不传 seed | 显式 `--seed 0` | 保证 tiny ⊂ 1h ⊂ 7h ⊂ 40h ⊂ all 的嵌套可复现 | 无 | `NPZ_CONVERSION.md` §4 |
| 10 | `convert_human` 转全量 142,220 条 | 只转 1 h 子集 **490 条** | 本次范围只做 1 h | 全量按实测 48 it/s 折算约 50–65 min，留作 follow-up | `HUMAN_SIDECAR.md` §4 |
| 11 | `check_human` 只打印 | 额外加 `--out logs/env/check_human_1h.csv` | 上游不落文件 | 多一张 490 行逐 clip 证据表 | `HUMAN_SIDECAR.md` §4 |
| 12 | npz 文件计数包含 `human50/` | 复核计数**排除** `human50/` | sidecar 根不是机器人 npz 的一部分 | 不剪枝会破坏「npz 数 == manifest 行数 == 142,220」核心证据 | `HUMAN_SIDECAR.md` §4 |
| 13 | sidecar 体积「约 119 MB」（计划估算） | 实测 **122,433,164 B ≈ 116.8 MiB** | 计划值未按帧数分布加权 | 差约 3 MB，口径一致 | `HUMAN_SIDECAR.md` §4 |
| 14 | `--num-envs 4096`（README：4096 envs 约占 28 GB 显存） | `--num-envs 1024` | 24 GB 卡放不下 28 GB | 采样吞吐下降，但显存主因不是 env 数，代价有限 | `TRAINING.md` §4 |
| 15 | 默认编译 CUDA graph | `--compile none` | `reduce-overhead` 对照峰值 22,100 MB 逼近预算线，且每次 resume 都要重编译（279 s/次 × 9 段） | it/s 1.5100 → 1.0790（-28.5%），迭代数已按 1.0790 换算 | `TRAINING.md` §4 |
| 16 | `--lr-decay-iters` 默认 250,000 | 显式设为 **26,413**（= 实际迭代数） | 上游 README 明说该值下学习率仍偏高 | **LR schedule 总长远短于上游**，是数值不可比的根因之一 | `TRAINING.md` §4；`CODE_MAP.md` ⑤-2 |
| 17 | 训练预算 24 h 公式 | **8 h 档**（`BUDGET_SECONDS=28800`） | 与 S07/S08/S09 的串行耗时不相容 | 26,413 迭代仅为官方 60,000 的 44%，策略质量必然低于官方 | `TRAINING.md` §2、§4 |
| 18 | 降级阶梯先降 envs 再降 batch | 先降 `--imag-batch/--kp-imag-batch` → 再降 envs → 最后 `--compile none` | 实测证明显存主因是想象批（3.11 GB → 17.09 GB 的跃升发生在 actor-critic 启动瞬间） | 偏离 R011 字面顺序，但更省时间（batch 探针被跳过） | `TRAINING.md` §3、§4 |
| 19 | 训练用 `uv run python -m morphmimic.scripts.train` | `uv run --frozen --no-sync python -m morphmimic.scripts.train` | 保证容器离线可跑、依赖锁定在 `uv.lock` | 无 | `TRAINING.md` §4 |
| 20 | 一次跑完训练 | 拆成 **9 段**，每段 `--iterations` 递增并 `--resume latest.pt` | 便于有界轮询与断点续跑 | 9 次 resume 证据全部留档 | `TRAINING.md` §4、§1.5 |
| 21 | 导出传目录 + `--iteration 60000` | 传 ckpt **文件路径**（`ckpt_26413.pt`），不带 `--iteration` | 上游 `resolve_paths` 传目录时要求 `<robot>/ckpt_<it>.pt` 子目录结构，我们的 run 目录是扁平的 | 不能用 `--iteration` 挑迭代，迭代号隐含在文件名里 | `EXPORT.md` §2 |
| 22 | `.gitignore` 只有 `outputs/` | 追加一行 `/out/` | 65 MB 的 `policy.onnx` 不能进 git 状态 | 多一行配置 | `EXPORT.md` §2 |
| 23 | 上游直接写 `out_dir` | staging 导出 → 全部门通过 → **原子 rename** 发布 | 上游先写 `policy.onnx` 再跑 parity，失败会残留半成品 | 多一次 rename 与一次 65 MB sha256 重算 | `EXPORT.md` §2、NEG-3 |
| 24 | 确定性判据覆盖全部导出文件 | 只认 `policy.onnx` 与 `g1_amber.json` | `MANIFEST.txt` 含写入时间与 git commit，不是字节可复现的 | MANIFEST 不参与确定性判定 | `EXPORT.md` §2 |
| 25 | 导出可在 GPU 上跑 | 导出与 parity 探针走**纯 CPU** 路径 | 不占用评测的 GPU 预算 | 无 | `EXPORT.md` §2 |
| 26 | 导出与训练复核各自独立 | `19_export.sh export` **自动先跑** `18_train_verify.sh verify` | 前置门禁化 | 导出失败原因更明确 | `EXPORT.md` §2 |
| 27 | 导出显式带 `--goal-anchor` | 不带（用上游默认 `reference`） | 本 ckpt 就是用 `--goal-anchor reference` 训练的，显式传 `robot` 必然 raise | 无 | `EXPORT.md` §2、NEG-1 |
| 28 | 「用 eval 脚本同时评自训与官方」 | 官方对照改在 **sim2sim** 侧做 | 官方 release 只发 ONNX，`morphmimic.scripts.eval` 的 `load_policy` 只走 `torch.load` | eval 两张 CSV **只代表自训权重**，不得与官方对照数值混算 | `DEPLOY.md` §2 |
| 29 | sim2sim 对照跑全量 490 条 | **49 条**（清单顺序每 10 条取 1 条，indices 0,10,…,480） | 全量需 980 次 `deploy.run`（实测每次约 3 s），墙钟与 GPU 预算不可接受 | 对照统计口径是 49 条子集，结论必须携带该口径 | `DEPLOY.md` §2 |
| 30 | 人接口 session 用真人动作 | session 的「操作者」是 **G1 自身**轨迹（上游 `gmr_operator.g1_operator` 注释即如此） | 本环境无人动捕设备 | 700 步 / 0 跌倒只证明**通路可执行**，不评价动作质量 | `DEPLOY.md` §2 |
| 31 | `uv sync --locked` | `uv sync --frozen` | 本仓库 `pyproject.toml` 与 `uv.lock` 不是逐字对应的 workspace 解析结果，`--locked` 会失败 | 无 | `CODE_MAP.md` ⑤-4 |
| 32 | 临时装的包可以留着 | `uv sync` 会把 pip 装的包**摘掉**，必须装进 `.venv` | `uv sync` 让环境回到 lockfile 声明的状态 | 镜像层里装的东西不算数 | `CODE_MAP.md` ⑤-3 |
| 33 | 容器内直接 `git` | 通过 `repro/lib/common.sh:git_in` 以目录属主 uid 运行 git（`setpriv --reuid=…`） | NFS root-squash 触发 `dubious ownership`，`safe.directory=*` 与 `-c safe.directory=` 都无效 | 所有 git 操作必须走封装 | `CODE_MAP.md` ⑤-5 |
| 34 | `git submodule update --init` | 按锁定 SHA **直接 clone**（depth 1） | linked worktree 里 `.git` 指针指向宿主机路径，`submodule update` 在这种工作树上失败 | 子模块落地方式与上游不同 | `CODE_MAP.md` ⑤-7 |
| 35 | 代理写进系统配置 | 代理**只内联到进程**，系统配置零痕迹 | 避免污染共享环境 | 每个联网脚本都要显式带代理 | `CODE_MAP.md` ⑤-6 |
| 36 | 阅读记录写到 `docs/code_doc/` | 落到仓库内 `docs/code_read/` | `docs/code_doc` 是指向仓库外的符号链接，**容器内断链** | 记录在容器内可见、可被校验器比对 | `CODE_MAP.md` ⑤-8 |

<!-- /DOC_SECTION:3 -->

<!-- DOC_SECTION:4 -->
## 4. 「已分析未执行」清单

以下三项**已分析到可执行的粒度，但本环境不具备执行条件**。这里显式列出，不得默认为已完成。

| 项 | 已分析到的内容 | 为何未执行 |
|---|---|---|
| **PICO 头显实机佩戴** | session 的数据布局已经是 PICO 的 `Recorder`/`ReplaySource` 格式（`t_ns` / `body[N,24,7]` / `buttons[N,5]`），`deploy/vr_teleop/pico_source.py` 可直接消费；本次用 `--replay` 已验证该格式可以驱动 `action_human` 通路（700 步 / 0 跌倒）。 | 本环境**没有 PICO 头显**，实机佩戴的链路延迟、丢帧、追踪漂移都无法在此验证；需在带设备的现场按 `deploy.run --teleop --interface human`（**不带** `--replay`）执行。 |
| **真机 G1 物理联调** | 策略的输入输出契约（`obs_history [B,930]`、`goal_motion [B,670]`、`goal_human [B,2160]`、`action_motion/action_human [B,29]`）、normalizer（`g1_amber.json`）与 ONNX 图均已冻结并通过 PyTorch parity（max 6.2e-06）。 | 真机需要 GMR 全身动作捕捉设备与物理安全环境，本仓库只具备仿真与离线数据；安全层（`deploy/hardware/`）无法在此验证。 |
| **官方 x2 / t2 对照** | 官方 zip 内自带 `x2.json` / `t2.json`（各自 normalizer），`deploy.run --deploy <official dir> --robot x2` / `--robot t2` 的命令形态与 g1_amber 完全同构；本次已确认其 SHA256SUMS 覆盖这两个文件（4 行 OK）。 | 本次只为 **g1_amber** 做了对照（资产、clip 清单、自训策略都只有 g1_amber 一套），x2 / t2 没有对应资产与 clip 清单；强行跑只会得到「无资产」而非「无策略」的结论。 |

<!-- /DOC_SECTION:4 -->

<!-- DOC_SECTION:5 -->
## 5. 产物路径与 SHA-256

「自训」列的摘要由校验器**从字节重算**（`out/g1_amber/SHA256SUMS`），「官方」列同理
（`runs/official/morphmimic_policy/SHA256SUMS`）。

| 路径 | 字节数 | sha256 | 生成命令 |
|---|---|---|---|
| `out/g1_amber/policy.onnx` | 65,074,719 | `476a90cb25f901651684d6b6e6c1c02aee5d8cf5f405725a5a2e7624de95c155` | `bash repro/lib/remote.sh 19_export.sh export` |
| `out/g1_amber/g1_amber.json` | 153,786 | `218afa970a20bdc55252d67aa08bcb629756865cea5cb24c7c776e923e20746a` | 同上（normalizer 与契约） |
| `out/g1_amber/MANIFEST.txt` | 3,798 | （不参与确定性判定，含写入时间与 git commit） | 同上 |
| `out/g1_amber/SHA256SUMS` | 158 | — | 同上（2 条摘要） |
| `runs/official/morphmimic_policy/policy.onnx` | 69,994,291 | `cf95194793e4732447f66432fc2381d82dd7c3d82c94da15ad074f2cfe295512` | `bash repro/lib/remote.sh 24_official.sh download` |
| `runs/official/morphmimic_policy/g1_amber.json` | 155,524 | `226eddf1ee7b2d1decce495f9c92da30c35bcd7c6e8dca12726cff0a24eaa055` | 同上 |
| `runs/official/morphmimic_policy/t2.json` | 157,429 | `7ab8dcd5072d5e1f15dbc8fef53c30f585f6adfba584084101ff675cf9201bbf` | 同上（未用于对照，见第 4 章） |
| `runs/official/morphmimic_policy/x2.json` | 154,609 | `ae73baa250cfb537d94d955776645a17bc4d7b790fe8d13cb0e9957d21fff44b` | 同上（未用于对照，见第 4 章） |
| `runs/official/morphmimic_policy.zip` | 63,372,873 | — | `24_official.sh download`（官方 v0.1 release 包） |
| `runs/eval/eval_motion_1h.csv` | 114,381 | — | `bash repro/lib/remote.sh 23_eval.sh motion`（490 行） |
| `runs/eval/eval_human_full_1h.csv` | 114,362 | — | `bash repro/lib/remote.sh 23_eval.sh human`（490 行） |
| `runs/official/compare_self_vs_official.csv` | 12,192 | — | `bash repro/lib/remote.sh 24_official.sh compare`（49 行） |
| `assets/g1_amber.xml` | 35,236 | — | `bash repro/lib/remote.sh 21_assets.sh export` |
| `assets/clips_g1_amber.txt` | 2,662 | — | 同上（49 条抽样清单） |
| `runs/train_curves/g1_amber_1h_curves.csv` | 1,067,423 | — | `bash repro/lib/remote.sh 27_train_curves.sh verify`（28,120 行） |
| `runs/train_curves/g1_amber_1h_curves_summary.csv` | 4,103 | — | 同上（52 个 tag 的逐 tag 统计） |
| `runs/train_curves/g1_amber_1h_curves.png` | 110,508 | — | 同上（matplotlib 可用时绘制，不可用时跳过且不算失败） |
| `runs/human/session.npz` | 1,298,040 | — | `bash repro/lib/remote.sh 25_human_replay.sh run`（956 帧） |
| `runs/human/replay.mp4` | 1,391,924 | — | 同上 |
| `runs/human/replay_summary.json` | 446 | — | 同上 |

**注意**：`out/`、`runs/`、`assets/`、`logs/` 是指向共享 seed store 的符号链接，不是本仓库的普通目录。

<!-- /DOC_SECTION:5 -->

<!-- DOC_SECTION:6 -->
## 6. 训练曲线数据

### 6.1 数据产物与覆盖

| 项 | 值 |
|---|---|
| 曲线 CSV | `runs/train_curves/g1_amber_1h_curves.csv`（列：`step,tag,value`） |
| 逐 tag 统计 | `runs/train_curves/g1_amber_1h_curves_summary.csv`（列：`tag,n,first_step,last_step,min,max,mean`） |
| 图（可选） | `runs/train_curves/g1_amber_1h_curves.png` |
| events 文件数 | **10**（每次进程 start 写一个；缺一即漏数据） |
| tag 数 | **52** |
| 数据点 | **28,120** 个 `(step, tag, value)` |
| step 覆盖 | **50 → 26,413**（与训练终止迭代一致） |
| 生成命令 | `bash repro/lib/remote.sh 27_train_curves.sh verify` |
| 终局 marker | `TRAIN_CURVES_OK events_files=10 tags=52 rows=28120 steps=26413 csv=runs/train_curves/g1_amber_1h_curves.csv` |

### 6.2 NaN 口径（唯一判定源）

NaN 的判定**只有两个来源**：`repro/lib/train.py` 的 `nan_audit` 与
`DEFAULT_WHITELIST = ("kp/return", "kp/scale_return")`。编排器**不实现任何 NaN 规则**。

- **非白名单 tag 出现非有限值即失败**：`TRAIN_CURVES_FAIL reason=<固定集合>` 且**零 OK marker**。
- 本次实测：仅 `kp/return` 与 `kp/scale_return` 两个 tag 含非有限值（这两个是「关键点接口」的
  回报量，上游本身允许 NaN），其余 50 个 tag 全为有限值。
- 训练终局复核用同一口径：`TRAIN_VERIFY_OK … tb_tags=52 nan_whitelist=2 …`。

### 6.3 采样表（摘自 `g1_amber_1h_curves_summary.csv`，权威值以 CSV 为准）

| tag | n | first_step | last_step | min | max | mean |
|---|---|---|---|---|---|---|
| `collect/env_steps` | 545 | 50 | 26413 | 32768.0 | 128000.0 | 127825.2623853211 |
| `collect/episodes_finished` | 545 | 50 | 26413 | 260.0 | 3467.0 | 981.4733944954129 |
| `collect/mean_reward` | 545 | 50 | 26413 | 0.03654675930738449 | 0.08785692602396011 | 0.08312903443060883 |
| `wm/state_loss` | 545 | 50 | 26413 | 18.25682258605957 | 319.6434631347656 | 28.9583272076528 |
| `wm/term_acc` | 545 | 50 | 26413 | 0.9980330467224121 | 0.9999998211860657 | 0.9999586979183582 |
| `wm/term_bce` | 545 | 50 | 26413 | 1.4843111557638622e-06 | 0.007740841247141361 | 0.00016521751417838108 |
| `kp/return` | 535 | 550 | 26413 | （空 = 全程非有限） | （空） | （空） |
| `kp/scale_return` | 535 | 550 | 26413 | （空 = 全程非有限） | （空） | （空） |

> 上表的 52 个 tag 全量清单见 `runs/train_curves/g1_amber_1h_curves_summary.csv`；
> 上游还提供 `perf/it_per_s`、`perf/gpu_mem_gb`、`policy/objective`、`kp/loss` 等性能与学习指标，
> 本文不逐条手抄，按需查 CSV。

<!-- /DOC_SECTION:6 -->

<!-- DOC_SECTION:7 -->
## 7. eval 对照表

### 7.1 双接口 completion 汇总（completion 由 `failed` 列重算）

| 接口 | CSV | 行数 | 失败数 | completion |
|---|---|---|---|---|
| motion | `runs/eval/eval_motion_1h.csv` | 490 | 0 | **1.000000** |
| human | `runs/eval/eval_human_full_1h.csv` | 490 | 0 | **1.000000** |

marker：`DEPLOY_EVAL_OK interface=motion rows=490 completion=1.000000` /
`DEPLOY_EVAL_OK interface=human rows=490 completion=1.000000`。

### 7.2 sim2sim 逐 clip 对照：自训 vs 官方（49 条）

对照口径：**同一套 assets、同一份 49 条 clip 清单（`assets/clips_g1_amber.txt`）、同一个
`deploy.run` 模板，只换 `--deploy` 目录**。指标为部署回放面的测量，与 7.1 的 completion
**分母不同、不可换算**。

均值（self − official，49 条，由校验器从 CSV 重算）：

| 指标 | Δ 均值（self − official） | self 均值 | official 均值 |
|---|---|---|---|
| joint_err_rms_rad | 0.012368 | 0.092518 | 0.080150 |
| body_err_mean_m | 0.000147 | 0.041286 | 0.041139 |
| end_drift_m | -0.049362 | 0.100472 | 0.149834 |

读法：自训策略的**关节误差均值比官方略高**（Δ = 0.012368 rad），**身体误差基本持平**
（Δ = 0.000147 m），但**末端漂移显著更小**（Δ = -0.049362 m，即自训的末端漂移比官方**低**约 5 cm）。
单 clip 的最大 |Δ| 分别为 0.204296 rad / 0.034338 m / 0.618574 m。

### 7.3 49 行逐 clip 对照表

下表为**6 位小数展示**；权威原值（全精度）在 `runs/official/compare_self_vs_official.csv`
（列：`clip,frames,self_result,self_joint_err_rms_rad,self_body_err_mean_m,self_end_drift_m,official_result,official_joint_err_rms_rad,official_body_err_mean_m,official_end_drift_m,delta_joint_err_rms_rad,delta_body_err_mean_m,delta_end_drift_m`），
校验器按该 CSV 重算并与本节数值比对。

| clip | frames | self_result | self_joint_err_rms_rad | self_body_err_mean_m | self_end_drift_m | official_result | official_joint_err_rms_rad | official_body_err_mean_m | official_end_drift_m |
|---|---|---|---|---|---|---|---|---|---|
| angry_look_000_R_001__A451 | 306 | completed | 0.040989 | 0.015259 | 0.024538 | completed | 0.050306 | 0.016332 | 0.018600 |
| big_light_two_hands_behind_medium_to_right_side_medium_R_001__A522 | 270 | completed | 0.080787 | 0.070882 | 0.067210 | completed | 0.076730 | 0.069120 | 0.071878 |
| crouch_ff_start_180_R_003__A248 | 358 | completed | 0.119360 | 0.033979 | 0.044449 | completed | 0.093889 | 0.036293 | 0.387810 |
| dance_hiphop_bounce_to_feet_R_loop_002__A325 | 579 | completed | 0.095715 | 0.024718 | 0.083085 | completed | 0.089844 | 0.027210 | 0.098509 |
| dance_latino_kick_kick_R_fast_002__A311_M | 253 | completed | 0.133645 | 0.054530 | 0.400405 | completed | 0.112807 | 0.054213 | 0.140487 |
| dance_retro_jazz_cross_step_180_R_fast_001__A314_M | 356 | completed | 0.117312 | 0.018470 | 0.176274 | completed | 0.093645 | 0.020122 | 0.108714 |
| dance_vouge_boogle_180_R_001__A324 | 261 | completed | 0.125030 | 0.035032 | 0.117625 | completed | 0.136210 | 0.039123 | 0.233928 |
| dancing_routine_V001_004__A198_M | 751 | completed | 0.055126 | 0.023275 | 0.160204 | completed | 0.052962 | 0.023580 | 0.076530 |
| egypt_dance_R_002__A237_M | 199 | completed | 0.082205 | 0.019703 | 0.057980 | completed | 0.082864 | 0.023094 | 0.064860 |
| elbow_plank_001__A360_M | 408 | completed | 0.164407 | 0.602097 | 0.022193 | completed | 0.162232 | 0.593567 | 0.094620 |
| greetings_hat_R_002__A260_M | 230 | completed | 0.055459 | 0.014928 | 0.018489 | completed | 0.059808 | 0.014104 | 0.036595 |
| hurry_idle_loop_001__A169 | 626 | completed | 0.039003 | 0.011488 | 0.068384 | completed | 0.036168 | 0.012423 | 0.033824 |
| idle_hands_on_back_stop_001__A237 | 265 | completed | 0.050284 | 0.010167 | 0.022861 | completed | 0.061218 | 0.018763 | 0.050533 |
| injured_R_leg_jump_ff_180_R_003__A231_M | 193 | completed | 0.097929 | 0.036900 | 0.100798 | completed | 0.089452 | 0.042176 | 0.059294 |
| injured_torso_jog_ff_loop_315_R_003__A216_M | 176 | completed | 0.107147 | 0.026713 | 0.195429 | completed | 0.093429 | 0.028566 | 0.128549 |
| injured_torso_kick_trash_004__A057 | 445 | completed | 0.058179 | 0.017359 | 0.106217 | completed | 0.055112 | 0.018324 | 0.291713 |
| injured_torso_turn_jump_360_R_003__A340_M | 219 | completed | 0.081197 | 0.035346 | 0.013633 | completed | 0.060856 | 0.032092 | 0.103356 |
| injured_torso_walk_ff_stop_270_R_003__A214_M | 378 | completed | 0.087802 | 0.037578 | 0.059135 | completed | 0.075090 | 0.029584 | 0.210457 |
| itching_left_arm_R_003__A068_M | 176 | completed | 0.060276 | 0.011961 | 0.002124 | completed | 0.045807 | 0.012604 | 0.021245 |
| jog_ff_start_180_R_002__A405 | 247 | completed | 0.098052 | 0.033189 | 0.156606 | completed | 0.071660 | 0.032260 | 0.305975 |
| jog_ff_start_270_R_002__A236 | 171 | completed | 0.110605 | 0.030332 | 0.135145 | completed | 0.081896 | 0.030814 | 0.100759 |
| jog_ff_stop_180_R_001__A255_M | 190 | completed | 0.094559 | 0.024350 | 0.141221 | completed | 0.075950 | 0.025019 | 0.303824 |
| jog_ff_stop_180_R_005__A147_M | 166 | completed | 0.118780 | 0.028139 | 0.090220 | completed | 0.086918 | 0.024216 | 0.185255 |
| jog_sideway_045_stop_003__A032_M | 276 | completed | 0.083725 | 0.028155 | 0.070902 | completed | 0.071782 | 0.025521 | 0.052189 |
| jump_ff_270_002__A079_M | 121 | completed | 0.087253 | 0.022717 | 0.097338 | completed | 0.074773 | 0.023067 | 0.056323 |
| jump_ff_360_001__A081_M | 132 | completed | 0.068842 | 0.024219 | 0.032593 | completed | 0.058880 | 0.026405 | 0.060382 |
| jump_over_obstacle_0_75m_R_101__A305_M | 213 | completed | 0.146525 | 0.052450 | 0.099646 | completed | 0.158254 | 0.061061 | 0.478222 |
| kneeling_start_004__A022 | 178 | completed | 0.365827 | 0.073519 | 0.128728 | completed | 0.161531 | 0.039181 | 0.388872 |
| maybe_002__A407_M | 272 | completed | 0.043540 | 0.010038 | 0.019076 | completed | 0.043511 | 0.011631 | 0.000862 |
| medium_big_heavy_two_hands_right_side_high_to_behind_high_R_001__A524_M | 440 | completed | 0.086839 | 0.050257 | 0.043153 | completed | 0.092816 | 0.050117 | 0.014336 |
| mid_horizontal_handle_vertical_lever_over_front_001__A486 | 188 | completed | 0.084754 | 0.036786 | 0.026696 | completed | 0.071634 | 0.036842 | 0.026585 |
| neutral_idle_turn_360_002__A086_M | 269 | completed | 0.051153 | 0.011541 | 0.027596 | completed | 0.044337 | 0.012514 | 0.067085 |
| puke_R_002__A187 | 121 | completed | 0.067922 | 0.020892 | 0.025297 | completed | 0.065287 | 0.018424 | 0.025697 |
| rubbing_hands_004__A165 | 122 | completed | 0.062318 | 0.011989 | 0.033931 | completed | 0.050288 | 0.010309 | 0.011773 |
| run_start_180_R_001__A345_M | 151 | completed | 0.107012 | 0.042777 | 0.220651 | completed | 0.102771 | 0.043041 | 0.092689 |
| small_light_one_hand_front_high_to_front_high_R_001__A516_M | 164 | completed | 0.104375 | 0.019517 | 0.021422 | completed | 0.072483 | 0.019150 | 0.018406 |
| smoke_turn_jog_ff_270_start_R_001__A549 | 237 | completed | 0.101094 | 0.026649 | 0.167587 | completed | 0.079376 | 0.030405 | 0.252445 |
| street_avoid_car_180_jog_R_001__A429 | 334 | completed | 0.093616 | 0.043613 | 0.221680 | completed | 0.080361 | 0.041916 | 0.095003 |
| turn_jump_045_003__A039_M | 206 | completed | 0.058196 | 0.021042 | 0.116463 | completed | 0.055668 | 0.019795 | 0.051230 |
| turn_start_jog_0090_003__A026 | 163 | completed | 0.121685 | 0.040039 | 0.071606 | completed | 0.093683 | 0.037116 | 0.148006 |
| turn_start_walk_000_003__A032 | 251 | completed | 0.080532 | 0.025257 | 0.091075 | completed | 0.067567 | 0.025527 | 0.106919 |
| turn_start_walk_045_002__A034_M | 220 | completed | 0.073162 | 0.018895 | 0.066395 | completed | 0.057187 | 0.020450 | 0.050421 |
| walk_arc_cw_stop_003__A051_M | 274 | completed | 0.068162 | 0.019686 | 0.039892 | completed | 0.066064 | 0.023531 | 0.061385 |
| walk_big_dog_ff_225_stop_R_001__A492 | 303 | completed | 0.110168 | 0.066371 | 0.127808 | completed | 0.124545 | 0.075340 | 0.244808 |
| walk_fast_forward_grab_injured_R_leg_001__A005_M | 541 | completed | 0.092874 | 0.050236 | 0.448451 | completed | 0.091261 | 0.055646 | 0.204399 |
| walk_hands_on_back_loop_003__A095_M | 312 | completed | 0.079741 | 0.021662 | 0.081108 | completed | 0.068668 | 0.016073 | 0.254472 |
| walk_sideway_135_loop_001__A030_M | 363 | completed | 0.103400 | 0.030539 | 0.194181 | completed | 0.074326 | 0.022623 | 0.517158 |
| walking_on_edge_ff_270_R_003__A412_M | 876 | completed | 0.061641 | 0.017268 | 0.128951 | completed | 0.085131 | 0.022077 | 0.747525 |
| watering_plants_high_R_001__A500 | 876 | completed | 0.055174 | 0.020487 | 0.056662 | completed | 0.070293 | 0.024441 | 0.187352 |

### 7.4 人接口回放（第三个测量面）

`runs/human/replay_summary.json`：`steps = 700`、`falls = 0`、`seconds = 14.1`、
`travel_along_m = 0.0035360427722080606`、`travel_across_m = -0.331855066155786`、
`turn_deg = 12.767966785521129`、`joint_err_rms_rad = null`（人接口分支无误差块，字段与 motion
分支不同）、`delay_ms = 0.0`、`interface = "human full"`。marker：`DEPLOY_HUMAN_OK steps=700 falls=0`。

<!-- /DOC_SECTION:7 -->

<!-- DOC_SECTION:8 -->
## 8. 踩坑记录

每条给出「现象 / 根因 / 处理 / 是否复发」，并挂到具体日志或真负例 transcript。

| # | 现象 | 根因 | 处理 | 是否复发 | 证据 |
|---|---|---|---|---|---|
| 1 | `uv sync --locked` 失败 | 本仓库 `pyproject.toml` 与 `uv.lock` 不是逐字对应的 workspace 解析结果 | 改用 `uv sync --frozen`（不重新解析、不改 lockfile） | 未复发（已固定为唯一写法） | `logs/env/03_uv_sync.txt` |
| 2 | 容器内 git 报 `fatal: detected dubious ownership` | NFS root-squash，容器以 root 跑 git；容器 git 2.34.1 只读全局配置，`safe.directory=*` 与 `-c safe.directory=` 均无效 | 以目录属主 uid 运行：`setpriv --reuid=<uid> --regid=<gid> --clear-groups env HOME=/tmp git -C <dir> …`（`repro/lib/common.sh:git_in`） | 未复发 | `logs/env/snapshot.txt`、`logs/env/02_submodules.txt` |
| 3 | `git submodule update --init` 在 linked worktree 失败 | worktree 的 `.git` 指针指向宿主机路径，容器内不成立 | 改为按锁定 SHA 直接 clone（depth 1） | 未复发 | `logs/env/02_submodules.txt` |
| 4 | 大 tar 下载反复中断（`rc=56` / `rc=92` / `rc=35`） | 代理是容器唯一出口；`rc=92` 为 HTTP/2 stream 未正确关闭，`rc=35` 为 TLS，`rc=75` 为时间预算耗尽（正常暂停语义） | `curl -L -C -` + `.part` 保留 + 指数退避重试 | 未复发（下载最终 `SEED_DOWNLOAD_OK files=3 bytes=68688061944`） | `logs/env/08_seed_download_worker.log` |
| 5 | 签名 URL 约 1.8 h 后失效 | 每次 attempt 必须重新 resolve（一次 302 换新签名） | 不缓存签名 URL，每次 attempt 重新 resolve | 未复发 | `logs/env/08_seed_download.txt` |
| 6 | NFS 解包报属主/权限错误 | 归档属主是 `mpanek/root`，NFS 是 root-squash | `tar --no-same-owner --no-same-permissions`，并禁用 `-p` | 未复发 | `logs/env/10_seed_extract.txt` |
| 7 | 解包极慢（NFS 小文件约 22 ms/个，284,440 个 clip ≈ 90 min/归档） | NFS 小文件写竞争 | 解包严格串行、detached 化、幂等（`.done` 标记），重跑只对账不解包 | 未复发 | `logs/env/10_seed_extract.txt` |
| 8 | 验证门内重算 68.7 GB sha256 超时 | 单文件全量摘要约 518 s，远超单命令超时 | 归档级 sha256 单独跑并留证 `logs/env/sha256sum_check.txt`，验证门改用 manifest 行数 + 抽样 | 未复发（已写入契约） | `logs/env/sha256sum_check.txt` |
| 9 | 训练显存逼近预算线 | 显存主因是**想象批**（`--imag-batch 4096` + `--kp-imag-batch 4096`，horizon 32），不是 env 数量 | 降级阶梯改为先降 batch、再降 envs、最后 `--compile none`；本次 `--compile none` 保住 26,413 迭代 | 未复发 | `logs/env/17_train.txt`、`logs/env/18_train_report.txt` |
| 10 | 每次 resume 都要重编译（约 279 s/次 × 9 段） | `--compile reduce-overhead` 的 CUDA graph 不可跨进程复用 | 训练用 `--compile none`；代价是 it/s 1.5100 → 1.0790，迭代数按 1.0790 换算 | 未复发 | `logs/env/17_train_worker.log` |
| 11 | 导出失败时 `out_dir` 残留半成品 `policy.onnx` | 上游先写 onnx 再跑 parity，超限才 raise，json/MANIFEST/SHA256SUMS 不会生成 | staging 导出 → 判定底座复核 → 全通过才原子 rename 发布 | 未复发（NEG-3 复现过：`EXPORT_NEG_FAIL reason=staging-verify-failed`） | `logs/env/19_export_negatives.txt` |
| 12 | 导出时 goal anchor 不匹配抛 ValueError | 上游 `check_goal_anchor` 会检查 checkpoint 训练时的 anchor | 不带 `--goal-anchor`（用默认 `reference`），与训练一致 | 未复发（NEG-1 复现过） | `logs/env/19_export_negatives.txt` |
| 13 | 官方 `policy.onnx` 与我们的 `g1_amber.json` 混搭会得到错误结论 | 官方 release 只发 ONNX；eval 的 `load_policy` 只走 `torch.load` | 对照改在 sim2sim 侧做，且严禁混搭 normalizer | 未复发（NEG-1 复现过：`DEPLOY_VERIFY_FAIL reason=official-sha-mismatch`） | `logs/env/26_deploy_verify_negatives.txt` |
| 14 | worktree 被重建导致 23.5 GB 载荷丢失、符号链接被抹 | GSD 会清理未注册 worktree 及其未跟踪文件 | 把重活产物迁出 worktree（共享 store + 相对软链），并记录三次事故的抢救过程 | 未复发（已迁出） | `SEED_ACQUISITION.md` §10 |
| 15 | `docs/code_doc` 在容器内是断链 | 该路径是仓库内指向**外部** doc 仓库的相对软链，容器内看不到 | 阅读记录与复现记录都落在仓库内 `docs/code_read/`（容器可见、git 跟踪、可被校验器比对），发布到 `docs/code_doc` 由宿主侧完成 | 未复发（已在契约中显式声明） | `docs/code_read/CODE_MAP.md` ⑤-8 |
| 16 | 训练曲线数据缺失（只有审计结论，没有可引用的数据） | 此前从未把 tensorboard events 落成面向文档的 CSV | 新增 `repro/27_train_curves.sh`（容器内 `EventAccumulator` 聚合全部 10 个 events 文件），产出可重算的 CSV + 逐 tag 统计 | 未复发 | `logs/env/27_train_curves.txt` |

<!-- /DOC_SECTION:8 -->

<!-- DOC_SECTION:9 -->
## 9. 明文 token 撤销提醒

本节**不含任何 token 值**。本文档与校验器都禁止出现形如 `hf_` + 20 位以上字母数字的字符串
（`repro/lib/doc.py` 用正则 `hf_[A-Za-z0-9]{20,}` 扫描全文，命中即 `reason=token-leaked`）。

### 9.1 泄露位置

| 位置 | 状态 | 说明 |
|---|---|---|
| 外部 doc 仓库 `docs/code_doc/session.md` | **明文出现** | 该文件第 2 行含一个明文 token（复核确认：全文命中 1 处，长度 37 字符）。这是本项目已知的一次明文 token 落盘。 |
| 容器内 `~/.cache/huggingface/token`（HF CLI 凭据缓存） | 存在 | 下载器的凭据解析顺序是 `${HF_TOKEN}` → `${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}`（见 `repro/lib/seed_download.sh`）。 |
| 本仓库 `repro/`、日志 `logs/env/`、本记录 `docs/code_read/` | **未出现** | 下载器只把 token 放进请求头，**不写日志**；`logs/env/` 与本文档均经正则扫描，零命中。 |

### 9.2 撤销 / 重签步骤（在凭据提供方侧执行）

1. 登录 Hugging Face 账号 → **Settings → Access Tokens**（或组织/团队的 token 管理页）。
2. 找到对应 token（按**创建时间与使用记录**定位，**不要**把 token 本身抄进任何工单/聊天/文档），
   点击 **Revoke / Delete** 立即吊销。
3. 若不确定是哪一个：**全部吊销**，重新签发一个最小权限的 **read** token（下载公开数据集只需要读权限）。
4. 新 token 只写入**运行者的本地凭据缓存**或 secret 存储（`HF_TOKEN` 环境变量 /
   `HF_TOKEN_PATH` 指向的文件），**不写进仓库、不写进文档、不写进日志**。
5. 旧 token 一旦吊销，依赖它的一切自动化（下载器、CI）会立刻 401 —— 吊销后请重跑
   `bash repro/lib/remote.sh 08_seed_download.sh probe` 确认新凭据可用。

### 9.3 危害面

- 明文 token 一旦进入任何**可被他人读取**的位置（文档、聊天记录、日志、issue、CI 产物），
  就应视为**已泄露**，无论是否被检索到。
- 本项目的数据集是公开的，最坏情况下攻击者可用该 token 以受害者身份**写入/删除**仓库内容、
  消耗组织配额，或访问该账号下**其它私有**资源。
- 危害与「是否真的被人看到」无关，只与「是否落盘且落盘处是否可控」有关。

### 9.4 检查清单（可逐条执行）

- [ ] 吊销所有疑似泄露的 token，并确认吊销生效（用旧 token 访问一次应 401）。
- [ ] 重新签发最小权限（read）token，只放在本地凭据缓存 / secret 存储。
- [ ] 清理外部 doc 仓库 `docs/code_doc/session.md` 第 2 行的明文 token（用占位符替换），
      **不要**把旧值粘到删除操作的记录里。
- [ ] 复查本仓库全部被跟踪文件与 `logs/`：正则 `hf_[A-Za-z0-9]{20,}` 零命中
      （本记录自身即由该正则守护）。
- [ ] 检查 git 历史（`git log -p` / `git grep` 历史版本）是否含旧 token；含则按「凭据已泄露」
      处理，不需要改写历史，但必须确认已吊销。
- [ ] 若凭据曾进入 CI 产物或第三方镜像，同样按泄露处理并吊销。

<!-- /DOC_SECTION:9 -->

<!-- DOC_SECTION:10 -->
## 10. 证据索引表

下表逐行可被 `bash repro/28_doc_verify.sh verify` 断言：证据文件相对**仓库根**解析并必须存在
（`logs/` `runs/` `out/` `assets/` 的 seed store 软链会被跟随），「关键输出」必须能在该证据文件中
**grep 到**（大小写不敏感子串）。

<!-- DOC_EVIDENCE_TABLE_START -->
| 结论 | 复现命令 | 证据文件（相对仓库根） | 关键输出（须能在证据文件中 grep 到） |
|---|---|---|---|
| 环境快照采集成功，GPU/OS/磁盘/工具链事实齐备 | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | SNAPSHOT_OK |
| 关键 wheel 的 sha256 来自 uv.lock（第三方可据此校验自取 wheel） | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | wheel_hashes: |
| 实际安装的 venv 包版本（含 protobuf 7.36.2） | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | protobuf==7.36.2 |
| 快照自身可重校验（正文 sha256） | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | snapshot_body_sha256: |
| 依赖锁定在 uv.lock，sha256 固定 | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | uv_lock_sha256: 9e46033eb80c8f4215b0043e15473603941958c32869ce024847bb7c57bc6b71 |
| GPU 为 RTX 4090 24 GB | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | NVIDIA GeForce RTX 4090 |
| 宿主 OS 为 Ubuntu 22.04.4 LTS | bash repro/lib/remote.sh 01_snapshot.sh | logs/env/snapshot.txt | Ubuntu 22.04.4 LTS |
| 子模块按锁定 SHA 落地 | bash repro/lib/remote.sh 02_submodules.sh | logs/env/02_submodules.txt | SUBMODULES_OK |
| 依赖同步成功（torch 2.11.0+cu128 自检通过） | bash repro/lib/remote.sh 03_uv_sync.sh | logs/env/03_uv_sync.txt | UV_SYNC_OK |
| BONES-SEED 三个文件下载完成，共 68,688,061,944 B | bash repro/lib/remote.sh 08_seed_download.sh wait | logs/env/08_seed_download.txt | SEED_DOWNLOAD_OK files=3 bytes=68688061944 |
| 归档级完整性校验通过（两个归档 / 284,440 clip） | bash repro/lib/remote.sh 09_seed_verify.sh verify | logs/env/09_seed_verify.txt | SEED_VERIFY_OK archives=2 clips=284440 |
| 解包并与 metadata 逐 session 对账通过 | bash repro/lib/remote.sh 10_seed_extract.sh verify | logs/env/10_seed_extract.txt | SEED_EXTRACT_OK files=284440 |
| G1 CSV 转 50 Hz npz：142,220 行、kept 129,398、零错误 | bash repro/lib/remote.sh 13_seed_convert.sh verify | logs/env/13_seed_convert.txt | SEED_NPZ_CONVERT_OK clips=142220 rows=142220 kept=129398 errors=0 error_rate=0.0000000000 elapsed_s=7496 |
| npz 独立复核通过（5 个子集嵌套 + 200 抽样） | bash repro/lib/remote.sh 14_seed_npz_verify.sh verify | logs/env/14_seed_npz_verify.txt | SEED_NPZ_VERIFY_OK rows=142220 errors=0 rate=0.0000000000 kept=129398 subsets=5 sampled=200 |
| 490 条 human50 sidecar 转换完成 | bash repro/lib/remote.sh 15_seed_human.sh convert | logs/env/15_seed_human.txt | SEED_HUMAN_CONVERT_OK clips=490 converted=490 skipped=0 failed=0 elapsed_s=22 |
| sidecar 独立复核：490 条一一对应、帧数对齐、足部越界 11 条 | bash repro/lib/remote.sh 16_seed_human_verify.sh verify | logs/env/16_seed_human_verify.txt | SEED_HUMAN_VERIFY_OK clips=490 sidecars=490 missing=0 extra=0 frames_match=490 feet_off=11 |
| 训练完成：26,413 迭代、1.1112 it/s、GPU 峰值 18.65 GiB | bash repro/lib/remote.sh 17_train.sh wait | logs/env/17_train.txt | TRAIN_TRAIN_OK iterations=26413 it_per_s=1.1112 gpu_peak_gb=18.65 host_peak_gb=7.00 elapsed_s=2284 |
| 训练终局复核：9 个 ckpt、52 个 tb tag、NaN 白名单 2 条、9 次 resume | bash repro/lib/remote.sh 18_train_verify.sh verify | logs/env/18_train_verify.txt | TRAIN_VERIFY_OK ckpts=9 latest=1 tb_tags=52 nan_whitelist=2 resume_events=9 gpu_peak_mb=19094.0 host_peak_gb=7.0 wall_s=2284 iterations=26413 lr_decay_iters=26413 |
| ONNX 导出成功（staging 复核后原子发布） | bash repro/lib/remote.sh 19_export.sh export | logs/env/19_export.txt | EXPORT_EXPORT_OK |
| 导出环境门：venv python 3.11.16 + torch 2.11.0+cu128 | bash repro/lib/remote.sh 19_export.sh env | logs/env/19_export.txt | EXPORT_ENV_OK python=3.11.16 |
| 导出确定性成立（policy.onnx 与 g1_amber.json 两次导出一致） | bash repro/lib/remote.sh 19_export.sh export | logs/env/19_export.txt | EXPORT_DETERMINISM_OK |
| 导出独立复核：4 产物、parity 最大 6.2e-06 | bash repro/lib/remote.sh 20_export_verify.sh verify | logs/env/20_export_verify.txt | EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber |
| 导出失败路径：staging 校验不过则不发布（真负例） | bash repro/lib/remote.sh 19_export.sh selftest | logs/env/19_export_negatives.txt | EXPORT_NEG_FAIL reason=staging-verify-failed |
| 资产导出：1h 子集 490 条中确定性抽样 49 条 | bash repro/lib/remote.sh 21_assets.sh export | logs/env/21_assets.txt | DEPLOY_ASSETS_OK clips=49 xml=assets/g1_amber.xml |
| 49 条 clip 清单固化（每 10 条取 1 条） | bash repro/lib/remote.sh 21_assets.sh export | logs/env/21_assets.txt | DEPLOY_ASSETS_ENV_OK clips=490 sampled=49 robot=g1_amber |
| 仿真回放：49/49 完成、49 个视频齐备 | bash repro/lib/remote.sh 22_sim2sim.sh run | logs/env/22_sim2sim.txt | DEPLOY_SIM_OK clips=49 completed=49 video_ok=49 parity=49/49 |
| motion 接口评测：490 行、completion 1.000000 | bash repro/lib/remote.sh 23_eval.sh motion | logs/env/23_eval.txt | DEPLOY_EVAL_OK interface=motion rows=490 completion=1.000000 |
| human 接口评测：490 行、completion 1.000000 | bash repro/lib/remote.sh 23_eval.sh human | logs/env/23_eval.txt | DEPLOY_EVAL_OK interface=human rows=490 completion=1.000000 |
| 官方 v0.1 权重下载并重算 SHA-256（6 文件 / 4 摘要） | bash repro/lib/remote.sh 24_official.sh verify | logs/env/24_official.txt | DEPLOY_OFFICIAL_OK files=6 sha_files=4 |
| 同口径对照产出 49 行 self vs official 表 | bash repro/lib/remote.sh 24_official.sh compare | logs/env/24_official.txt | DEPLOY_OFFICIAL_COMPARE_OK rows=49 |
| 人接口回放：700 步、0 跌倒 | bash repro/lib/remote.sh 25_human_replay.sh run | logs/env/25_human_replay.txt | DEPLOY_HUMAN_OK steps=700 falls=0 |
| 人接口 session 为 PICO 布局，956 帧 | bash repro/lib/remote.sh 25_human_replay.sh run | logs/env/25_human_replay.txt | DEPLOY_HUMAN_SESSION_OK samples=956 |
| 部署终局复核七项计数齐备 | bash repro/lib/remote.sh 26_deploy_verify.sh verify | logs/env/26_deploy_verify.txt | DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700 |
| 真负例：官方摘要被篡改即失败 | bash repro/tests/test_deploy_verify.sh | logs/env/26_deploy_verify_negatives.txt | DEPLOY_VERIFY_FAIL reason=official-sha-mismatch |
| 真负例：eval 行数少一行即失败 | bash repro/tests/test_deploy_verify.sh | logs/env/26_deploy_verify_negatives.txt | DEPLOY_VERIFY_FAIL reason=eval-row-count-mismatch |
| 真负例：少一个 sim2sim 视频即失败 | bash repro/tests/test_deploy_verify.sh | logs/env/26_deploy_verify_negatives.txt | DEPLOY_VERIFY_FAIL reason=video-missing |
| 训练曲线数据落地：10 个 events 文件、52 tag、28,120 行 | bash repro/lib/remote.sh 27_train_curves.sh verify | logs/env/27_train_curves.txt | TRAIN_CURVES_OK events_files=10 tags=52 rows=28120 steps=26413 csv=runs/train_curves/g1_amber_1h_curves.csv |
| 自训 policy.onnx 的 SHA-256 | cd out/g1_amber && sha256sum -c SHA256SUMS | out/g1_amber/SHA256SUMS | 476a90cb25f901651684d6b6e6c1c02aee5d8cf5f405725a5a2e7624de95c155 |
| 官方 policy.onnx 的 SHA-256 | cd runs/official/morphmimic_policy && sha256sum -c SHA256SUMS | runs/official/morphmimic_policy/SHA256SUMS | cf95194793e4732447f66432fc2381d82dd7c3d82c94da15ad074f2cfe295512 |
| 对照表含三列 delta，均值由校验器重算 | bash repro/lib/remote.sh 24_official.sh compare | runs/official/compare_self_vs_official.csv | delta_joint_err_rms_rad |
| motion eval 逐 clip 表（490 行） | bash repro/lib/remote.sh 23_eval.sh motion | runs/eval/eval_motion_1h.csv | kneeling_start_004__A022 |
| human eval 逐 clip 表（490 行） | bash repro/lib/remote.sh 23_eval.sh human | runs/eval/eval_human_full_1h.csv | kneeling_start_004__A022 |
| 训练曲线 CSV 含白名单 NaN tag kp/return | bash repro/lib/remote.sh 27_train_curves.sh verify | runs/train_curves/g1_amber_1h_curves.csv | kp/return |
| 逐 tag 统计 CSV 覆盖 52 个 tag | bash repro/lib/remote.sh 27_train_curves.sh verify | runs/train_curves/g1_amber_1h_curves_summary.csv | collect/mean_reward |
| 49 条抽样 clip 清单 | cat assets/clips_g1_amber.txt | assets/clips_g1_amber.txt | clips/g1_amber/kneeling_start_004__A022.npz |
| 人接口回放 summary：700 步、位移与朝向 | cat runs/human/replay_summary.json | runs/human/replay_summary.json | travel_along_m |
| 持久 store 体检通过：受保护目录齐备且均为指向 store 的软链 | bash repro/30_store_guard.sh check | logs/env/30_store_guard.txt | STORE_GUARD_OK |
| 持久 store 体检在远端容器内结论一致（同一 NFS、另一挂载前缀） | bash repro/lib/remote.sh 30_store_guard.sh check | logs/env/30_store_guard.txt | SEED_STORE_OK |
| 交付记录的三个副本（git 镜像 / store 持久副本 / 交付出口）逐字节一致 | bash repro/30_store_guard.sh doc | logs/env/30_store_guard.txt | SEED_STORE_DOC_OK copies=3 |
| 人工按记录照抄重跑一段链路（逐步判定写在 transcript 里，末尾为总判定 `UAT_RERUN_OK steps=6`） | bash repro/29_uat_sampling_rerun.sh | logs/env/29_uat_sampling_rerun.txt | STEP 1-ENV-PROXY OK |
| 全部离线测试电池绿（8 套，含 store 契约与记录校验器） | bash repro/31_test_batteries.sh | logs/env/31_test_batteries.txt | TEST_BATTERIES_OK suites=8 |
| 工程阅读覆盖 103/103 模块、0 缺失、0 空职责（门禁可复算） | bash repro/lib/remote.sh 06_code_read.sh | logs/env/06_code_read.txt | CODE_READ_OK |
| 四条外部工具链结论均为 VERIFIED（结论块留存；一手探针日志已缺失，见下一行） | grep TOOLCHAIN_GMR_VERDICT docs/code_read/TOOLCHAIN.md | docs/code_read/TOOLCHAIN.md | TOOLCHAIN_GMR_VERDICT=VERIFIED |
| 一手工具链探针日志缺失：2026-11-11 worktree 重建所致，`verify` 当前返回 reason=probe-log-missing | bash repro/07_toolchain.sh verify | docs/code_read/TOOLCHAIN.md | TOOLCHAIN_PROBE_LOG_MISSING |
<!-- DOC_EVIDENCE_TABLE_END -->

<!-- /DOC_SECTION:10 -->

---

## 参考的实测文档（本文只给索引与关键数字，不复制全文）

| 文档 | 覆盖范围 |
|---|---|
| `docs/code_read/CODE_MAP.md` | 103 个模块的职责清单、10 条关键调用链、README 偏离项与已知坑 |
| `docs/code_read/TOOLCHAIN.md` | GMR / soma-retargeter / XRoboToolkit / Unitree SDK 四条外部工具链的可用性结论 |
| `docs/code_read/SEED_ACQUISITION.md` | BONES-SEED 下载、完整性校验、解包与三次 worktree 事故的完整记录 |
| `docs/code_read/NPZ_CONVERSION.md` | G1 CSV → 50 Hz npz 转换与子集构建、过滤统计与耗时 |
| `docs/code_read/HUMAN_SIDECAR.md` | human50 sidecar 转换、足部 z 越界 11 条的逐 clip 数值 |
| `docs/code_read/EXPORT.md` | ONNX 导出、PyTorch parity、确定性指纹与三条真负例 |
| `docs/code_read/DEPLOY.md` | 资产导出、sim2sim 回放、双接口评测、官方对照、人接口回放 |
| `docs/code_read/TRAINING.md` | g1_amber 训练契约、迭代数换算、显存三口径与降级阶梯 |
| `docs/code_read/复现记录写作契约.md` | 本文档的机器可判定契约（校验器口径的人类可读镜像） |
