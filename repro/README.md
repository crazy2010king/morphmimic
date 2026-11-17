# repro/ — 可重跑的环境复现脚本

本目录把「从零把 morphmimic 的运行环境装起来」这件事拆成若干**可重跑**的脚本，
每个脚本只做一件事、只依赖远端容器里的事实、并把产物落到 `logs/env/`。
任何人照抄下面的命令即可复现本切片（Slice S01）的结论。

## 持久 store：数据放在哪里，为什么不会被删掉

> **一句话**：所有重产物（68.8 GB 的 BONES-SEED、88.5 GiB 的 50 Hz npz、训练 checkpoint、
> 导出的 ONNX、回放 mp4、交付的复现记录）都在**仓库之外的一个固定目录**里，
> worktree 内只有**相对软链**指向它；GSD 删 worktree 时删不掉这些字节。

### 位置

| 视角 | store 根 |
|------|----------|
| 本地开发机 | `/mnt/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |
| 远端容器 | `/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |

同一个 NFS 导出、两个挂载前缀，所以软链一律用**相对路径** `../../../morphmimic-seed-data/repo/<name>`，
两侧都解析到同一份字节。store 根由 `repro/lib/seed_store.sh` 解析：
优先 `SEED_STORE_ROOT` 环境变量 → 再按 `SEED_STORE_PREFIXES` 逐个前缀探测 → 最后回退到脚本自身所在的 store。

### 为什么必须是 store（两次真实事故）

| 日期 | 丢了什么 | 原因 |
|------|----------|------|
| 2026-11-11 | `data/seed/_archives/g1.tar.gz` 的 23.5 GB + 已完成的 metadata CSV | GSD reconcile 删除「未注册 git 的残留 worktree」，递归删除连带未跟踪文件 |
| 2026-11-11 | 工具链探针的**全部**产物（`logs/toolchain/**`：三个克隆仓库、两个隔离 venv、pybind11 构建树） | 探针跑在 store 机制建立**之前**，产物写进了 worktree 的普通 `logs/` 目录 |

### 现在的契约

- **受保护目录**：`data` / `logs` / `out` / `assets` / `runs`（`SEED_PROTECTED`）——worktree 内一律是软链。
- **不再静默接受普通目录**：旧实现 `if [ -e "$REPO_ROOT/$name" ]; then return 0; fi` 会在 worktree
  被重建（软链变回普通目录）时**继续把产物写进即将被删的目录**。现在 `seed_store_link` 会区分三种状态：
  `linked`（就绪）/ `diverged`（普通目录，**拒绝**并给出修复命令）/ `foreign`（指向别处的软链，**永不触碰**）。
- **可修复**：`bash repro/30_store_guard.sh migrate` 把普通目录里的内容**递归归并**进 store
  （同名同内容去重、同名不同内容报 `CONFLICT` 并原样保留，绝不删），再把路径换成软链。
- **可发现**：`bash repro/30_store_guard.sh check` 是 fail-closed 的体检；
  `manifest` 写 `<store>/MANIFEST.txt`（目录条目数 + 关键产物的 sha256），用来发现"没人看着时被删掉"。
- **不变量**：`00_env.sh` 一键编排**以 store 体检为前置**；`28_doc_verify.sh verify` 也先体检 store
  （记录引用的证据文件全在 store 里）。store 不健康就不产出新产物。

### 交付记录的三个副本

| 副本 | 位置 | 角色 |
|------|------|------|
| git | `docs/code_read/MorphMimic完整复现记录.md` | 随仓库走，worktree 被删也不丢 |
| store | `<store>/docs/code_doc/MorphMimic完整复现记录.md` | 持久副本 |
| 交付 | `docs/code_doc` → 用户的文档仓库 | 交付出口 |

`bash repro/30_store_guard.sh doc` 把交付副本同步进 store，并**逐字节**比对三份
（`SEED_STORE_DOC_OK copies=3 sha256=…`）。

### 事实源与隔离区

- **唯一事实源**：仓库内的 `repro/` 与 `docs/code_read/`。
- **团队规范**：`docs/code_read/PERSISTENT_STORE.md`（持久 store 使用规范：硬规则、受保护目录、三态处置、日常工作流、禁止事项、故障处置手册、提交前自检清单）。**改 store 相关逻辑前先读它**，改完同步更新它与 `repro/tests/test_store_guard.sh`。
- `<store>/_quarantine/**` 是**陈旧副本的隔离区**（保留是为了可回退），**任何脚本都不得从中读取**；
  2026-11-16 已把两个 2026-11-11 的快照（`repro-snapshot-*`、`docs-code_read-snapshot-*`）移入。
  隔离区说明也在 store 内（`<store>/_quarantine/README.md`）——**删 store 即失**，所以本节是它在仓库侧的声明。

### 常用命令

```bash
bash repro/30_store_guard.sh check       # 体检（fail closed）
bash repro/30_store_guard.sh migrate     # 把普通目录归并回 store 并重新链接
bash repro/30_store_guard.sh manifest    # 写 <store>/MANIFEST.txt（存量清单）
bash repro/30_store_guard.sh doc         # 同步并比对交付记录的三个副本
bash repro/30_store_guard.sh doctor      # check + doc + manifest
bash repro/lib/seed_store.sh paths       # 打印解析出来的 store 路径
```

## 怎么跑

所有步骤都必须在远端 `ros_dev` 容器里执行（本地开发机没有 GPU、没有 `uv`、也没有外网）。
本地只需要一个入口脚本，它通过 ssh 把脚本送进容器并透传退出码：

```bash
bash repro/lib/remote.sh 01_snapshot.sh      # 单步
bash repro/lib/remote.sh 00_env.sh            # 一键跑全流程（T6 提供）
```

`bash repro/lib/remote.sh <script>` 接受 `01_snapshot.sh` 或 `repro/01_snapshot.sh` 两种写法。
可用环境变量覆盖远端参数：`REMOTE_HOST` / `REMOTE_PORT` / `REMOTE_USER` / `REMOTE_CONTAINER` / `REMOTE_REPO_ROOT`。

## 脚本一览

| 脚本 | 作用 | 产物日志 |
|------|------|----------|
| `lib/seed_store.sh` | 持久 store 的单一事实源：store 根解析（跨挂载前缀）、受保护目录清单、软链状态机（linked / diverged / foreign）、`--migrate` 递归归并、`check` / `manifest` / `doc` 体检与交付记录三方比对 | `<store>/MANIFEST.txt` |
| `29_uat_sampling_rerun.sh` | 人工抽样复核：按复现记录第 10 节的原文命令在远端容器内照抄重跑一段链路（环境→数据→训练→导出→部署→记录），逐步记下退出码与期望 marker，产出 transcript（transcript 末尾有总判定 `UAT_RERUN_OK steps=N`） | `logs/env/29_uat_sampling_rerun.txt` |
| `31_test_batteries.sh` | 把全部**离线**测试电池跑一遍并把输出落到持久 store（`TEST_BATTERIES_OK suites=N`）；回归不再只存在于会话里 | `logs/env/31_test_batteries.txt` |
| `30_store_guard.sh` | store 的体检与修复入口：`check` / `migrate` / `manifest` / `doc` / `doctor`；`STORE_GUARD_OK` / `STORE_GUARD_FAIL reason=…` | `logs/env/30_store_guard.txt` |
| `lib/common.sh` | 被各脚本 source：推导 `REPO_ROOT`、内联代理、建 `LOG_DIR`、**强制把重产物路径绑到 store**（`seed_store_link --migrate` + `store_guard`）、提供 `run_logged` 与 git 安全兜底（`COMMON_PROXY_INLINE=0` 可只取前两项而不导出代理变量，供 `00_env.sh` 使用） | — |
| `lib/remote.sh` | 本地侧入口：ssh → `docker exec ros_dev` → 执行脚本，透传退出码 | — |
| `lib/submodules.sh` | 子模块落地逻辑（`land_submodule` / `verify_submodule`）+ 锁定的 SHA 常量，可被单测直接调用 | — |
| `lib/proxy_hygiene.sh` | 代理痕迹检测器（纯函数、只读）：`proxy_hygiene_scan_file` / `scan_path` / `targets`，被 `05_proxy_hygiene.sh` 与两套单测共用 | — |
| `01_snapshot.sh` | 采集机器事实快照（git / uv.lock / GPU / OS / 磁盘 / 工具链 / 代理配置基线） | `logs/env/snapshot.txt` |
| `02_submodules.sh` | 子模块落地（GMR 阻塞项、unitree SDK best-effort）+ 缺 GMR 的失败路径取证 | `logs/env/02_submodules.txt`、`logs/env/02_uv_sync_without_gmr.txt` |
| `03_uv_sync.sh` | `uv sync --frozen`（含 export/teleop 分组）+ torch/mjlab/warp 版本与 CUDA 自检 | `logs/env/03_uv_sync.txt` |
| `04_smoke.sh` | 合成站立 clip + 32-env 仿真冒烟 | `logs/env/04_smoke.txt` |
| `05_proxy_hygiene.sh` | 代理卫生断言（系统配置零代理痕迹）+ 检测器自检 | `logs/env/05_proxy_hygiene.txt` |
| `06_code_read.sh` | 工程阅读记录（`docs/code_read/CODE_MAP.md`）的模块覆盖率门禁：覆盖集每个模块都要有非空职责，否则非零退出并逐条列出 `MISSING` / `EMPTY_DUTY` | `logs/env/06_code_read.txt` |
| `07_toolchain.sh` | 四条三方工具链（GMR / SOMA / XRT / UNITREE）可用性探针；`probe`（默认）跑真实探针，`verify` 只做一致性断言（不触网、不重跑构建） | `logs/env/07_toolchain.txt` |
| `00_env.sh` | 一键编排：01 → 02 → 03 → 04 → 05 → 06（自子命令驱动：`start` / `status` / `wait` / `verify`） | `logs/env/00_env.txt`（`logs/env/00_env.prev.txt` 为上一次运行） |
| `lib/seed_download.sh` | BONES-SEED 下载的纯函数库（无网络）：期望文件表 size+sha256（取 HF `lfs.oid`，排除 `xetHash`）、token 解析、`curl -L -C -` 参数、指数退避、状态文件、进度/ETA | — |
| `lib/seed_archive.sh` | 归档与解包的纯函数库：期望 clip 数、归档目录/解包根、空间门（`seed_min_free_gb` / `seed_free_gb`） | — |
| `lib/seed_verify.py` | metadata ↔ 解包树对账（stdlib only）：`--mode files`（默认，计文件）/ `--mode clips`（clip 需同时具备 CSV 与 BVH），输出 `SEED_META_MATCH` / `SEED_META_SESSION` | — |
| `08_seed_download.sh` | BONES-SEED（68.8 GB）可续传下载器，子命令 `start` / `status` / `wait` / `verify` / `probe` / `segment` / `run`；传输体在 detached worker 里 | `logs/env/08_seed_download.txt`、`logs/env/08_seed_download.status`、`logs/env/08_seed_download_worker.log` |
| `09_seed_verify.sh` | 归档级完整性校验（sha256 清单 + gzip CRC + tar 条目数 142,220 + 相对路径布局门）；`verify` 子命令 | `logs/env/09_seed_verify.txt`、`logs/env/09_seed_verify.status` |
| `10_seed_extract.sh` | 解包 + 与 metadata 逐 session 对账，子命令 `start` / `status` / `wait` / `worker` / `verify` / `selftest` | `logs/env/10_seed_extract.txt`、`logs/env/10_seed_extract.status`、`logs/env/10_seed_extract_worker.log` |
| `11_seed_finalize.sh` | **无人值守终局链路**：等下载到齐后自动跑 09 → 10 → 对账 → `sha256sum -c`；子命令 `start` / `status` / `wait` / `worker` / `verify` / `selftest` | `logs/env/11_seed_finalize.txt`、`logs/env/11_seed_finalize.status`、`logs/env/11_seed_finalize_worker.log` |
| `12_seed_finalize_report.sh` | **只读终局报告器**：断言下载/终局 STATE=DONE + 六个终局 marker 齐全，把 marker 原文与可直接回填文档的 `SEED_REPORT_*` 数值打印出来；缺任何一项即失败并列出缺项（fail-closed）；子命令 `report`（默认）/ `check`（只出判定） | stdout（`SEED_REPORT_OK` / `SEED_REPORT_FAIL`） |
| `lib/seed_npz.py` | S04 的纯函数库（stdlib only）：`manifest_stats`（行数 / kept / errors / error_rate / name_reject 与 feas_reject 分布 / 总时长）、`error_rate_ok`、`subset_spec`（无 pyyaml 的最小 YAML 读取）、`subsets_nested`、`subset_hours_consistent`、`sample_paths` | — |
| `lib/seed_npz.sh` | S04 的可 source shell 纯函数库（无网络）：`seed_npz_space_gate`（默认 250 GiB，`SEED_MIN_FREE_GB` 可覆盖）、`seed_npz_expected_rows`（默认 142220，`SEED_EXPECTED_ROWS` 可覆盖）、`seed_npz_sample_paths`、`seed_npz_write_status`（原子写：先 `.tmp` 再 `mv`）、`seed_npz_parse_progress` | — |
| `13_seed_convert.sh` | **G1 CSV → 50 Hz npz 编排器**：调用上游 `morphmimic.scripts.convert_seed` + `build_subsets`；子命令 `env`（环境门，fail-closed）/ `smoke`（30 clip 冒烟）/ `start`（拉起 detached worker）/ `status`（秒级读状态文件）/ `wait`（有界等待）/ `worker`（detached worker 体）/ `verify`（幂等终局复核）/ `selftest` | `logs/env/13_seed_convert.txt`、`logs/env/13_seed_convert.status`、`logs/env/13_seed_convert_worker.log` |
| `13_seed_convert_worker.sh` | detached 转换体：环境门 → 空间门 → 上游 `convert_seed --workers 28` → manifest 行数/error 率门 → 上游 `build_subsets --seed 0` → 子集嵌套 → 终局 marker + 原子状态文件；失败路径零 `*_OK` marker | `logs/env/13_seed_convert.txt`、`logs/env/13_seed_convert.status` |
| `14_seed_npz_verify.sh` | **只读终局复核器**：`verify`（秒级，进宿主验证门：manifest 行数 / error 率 / kept 与 `all.yaml` 对账 / 五个 yaml 嵌套 / `1h.yaml` root / 200 抽样 npz 存在且 `fps==50`）/ `audit`（全量 `find` 计数，长命令，不进验证门）/ `report`（打印 `SEED_REPORT_NPZ_*`） | `logs/env/14_seed_npz_verify.txt` |
| `lib/seed_human.py` | S05 的纯函数库（**stdlib only**，容器系统 `python3` 无 numpy 也能跑）：`subset_spec` / `clip_rel_paths` / `sidecar_rel_path` / `expected_sidecars` / `actual_sidecars` / `diff_sets`（双向差集）/ `npz_array_shape`（`zipfile` + 手读 `.npy` 头，不依赖 numpy）/ `robot_frames`（`joint_pos` 长度）/ `sidecar_frames`（`human_pos_w` 长度）/ `bvh_header_frame_time`（**仅供单测证明 BVH 头截断陷阱，判定路径禁止调用**） | — |
| `lib/seed_human.sh` | `seed_human.py` 的薄封装（选解释器 + 转发），不重复实现判定逻辑 | — |
| `15_seed_human.sh` | **human50 sidecar 转换编排器**（fail-closed）：调用上游 `morphmimic.scripts.convert_human`（**必须**带 `--subset-yaml`，否则自噬）+ 上游 `check_human`（额外加 `--out` 留 CSV 证据）；子命令 `env`（秒级环境门）/ `convert`（真实转换 + sidecar 计数 + check 对账）/ `status`（只读，永远 exit 0） | `logs/env/15_seed_human.txt`、`logs/env/15_seed_human.status`、`logs/env/check_human_1h.csv` |
| `16_seed_human_verify.sh` | **只读独立复核器**（不信任上游输出）：`verify`（sidecar 集合与 `subsets/1h.yaml` 双向精确一致 + 逐条帧数与 robot npz `joint_pos` 对齐 + yaml root 与本机 npz 根同一 inode）/ `report`（打印 `SEED_REPORT_HUMAN_*`）；失败路径只打印 `SEED_HUMAN_VERIFY_FAIL reason=<…>`，**零 OK marker** | `logs/env/16_seed_human_verify.txt` |
| `17_train.sh` | **g1_amber 训练编排器**（fail-closed 环境门 → 冒烟 → detached worker → 有界轮询）：子命令 `env`（环境门）/ `smoke`（2k 冒烟 + 200 迭代 compile 对照 + 计划文件）/ `start`（拉起 detached worker）/ `status`（只读，永远 exit 0）/ `wait [秒]`（0=DONE / 1=FAILED / 75=超时且 worker 存活）/ `worker`（前台训练体）/ `verify`（委托 18_train_verify.sh）/ `selftest`（离线电池） | `logs/env/17_train.txt`、`logs/env/17_train.status` |
| `17_train_worker.sh` | detached 训练体：环境门 → 磁盘门 → 计划门 → 30 s 资源采样器 → 分段 resume 训练循环（每段 `--iterations` 递增 + `--resume logs/train/g1_amber_1h/latest.pt`）→ 终局状态/marker；失败路径零 `*_OK` marker | `logs/env/17_train_worker.log`、`logs/env/17_train_resources.csv` |
| `18_train_verify.sh` | **只读终局复核器**（不信任训练脚本自报）：`verify`（ckpt 数 / latest 存在 / tensorboard 全 events 聚合 + NaN 白名单 / resume 证据 / 资源峰值 / 墙钟 / iterations 与 lr-decay-iters 对齐）/ `report`（打印 `TRAIN_REPORT_*` 文档回填源）；失败只打印 `TRAIN_VERIFY_FAIL reason=<固定 reason 集合>`，**零 OK marker** | `logs/env/18_train_verify.txt`、`logs/env/18_train_report.txt` |
| `lib/export.py` | S07 导出判定的**纯函数底座**（stdlib only，容器系统 `python3` 无 numpy 也能跑）：`parse_manifest_parity`（解析 MANIFEST 的 parity 行，区分行缺失与格式不符）/ `parse_sha256sums` / `sha256_file`（重算摘要）/ `verify_export_dir`（唯一判定入口：4 产物齐备非空 + parity ≤ atol + SHA256SUMS 覆盖且摘要一致）/ `format_verify_ok` / `format_verify_fail` / `format_report_lines`（`EXPORT_VERIFY_*` / `EXPORT_REPORT_*` 输出格式的唯一来源） | — |
| `lib/export.sh` | `export.py` 的薄壳：只做「选解释器（`EXPORT_PY`，默认 `python3`）→ 定位 `export.py` → 转发参数」，**不含任何判定逻辑** | — |
| `19_export.sh` | **ONNX 导出编排器**（fail-closed）：子命令 `env`（环境门：venv 可 import torch/onnx/onnxruntime/onnxscript、源 ckpt 存在且 `torch.load` 成功、落点可写）/ `export`（**先**自动跑 `18_train_verify.sh verify` 前置门禁 → 导出到 staging → 判定底座复核 staging → **原子 rename 发布**到 `out/g1_amber`）/ `report`（导出侧自述，标 `EXPORT_REPORT_SIDE=export`）/ `selftest`（离线电池）；失败路径只打印固定 reason 集合且**零 OK marker** | `logs/env/19_export.txt` |
| `20_export_verify.sh` | **只读独立复核器**（不信任导出脚本自述，只从磁盘产物重新推导）：`verify`（4 产物存在非空 + parity ≤ 1e-4 + SHA256SUMS 覆盖且摘要**重算**一致）/ `report`（打印 `EXPORT_REPORT_*` 供文档回填）；失败只打印 `EXPORT_VERIFY_FAIL reason=<固定集合>`，**零 OK marker**；只写自己的日志，不写 `out/g1_amber/` | `logs/env/20_export_verify.txt` |
| `lib/deploy.py` | S08 部署验证判定的**纯函数底座**（stdlib only，容器系统 `python3` 无 numpy 也能跑）：`parse_sim_summary`（summary 契约：字段缺失 vs 值为空分开判）/ `check_video` / `read_eval_csv` / `eval_completion`（由 `failed` 列**重算** completion）/ `parse_subset_yaml` + `count_subset_clips` / `build_compare_csv`（self − official 的 delta）/ `verify_assets_dir` / `verify_sim_summaries` / `verify_eval_csv` / `verify_official_dir`（**自行重算** SHA-256）/ `verify_compare_csv` / `verify_session` + `verify_session_arrays`（PICO 布局 `body[N,24,7]`，用 `zipfile` + 手读 `.npy` 头）/ `verify_human_replay_summary` / `read_clip_list` / `verify_assets_for_review` / `verify_sim_replay` / `verify_eval_pair` / `verify_human_artifacts` / `verify_deploy_artifacts`（终局链：assets → sim2sim → eval → official → compare → human）/ `format_ok` / `format_fail` / `format_verify_ok` / `format_report_lines`（`DEPLOY_*_OK` / `DEPLOY_*_FAIL` / `DEPLOY_REPORT_*` 输出格式的唯一来源） | — |
| `lib/deploy.sh` | `deploy.py` 的薄壳：只做「选解释器（`DEPLOY_PY`，默认 `python3`）→ 定位 `deploy.py` → 转发参数」，**不含任何判定逻辑** | — |
| `lib/train.py` | S06/S09 训练侧判定的**纯函数底座**（stdlib only）：日志解析 / 迭代换算 / ckpt 网格 / 预算判定 / `nan_audit`（NaN 白名单唯一来源）/ `curve_rows_from_scalars` / `curve_summary_rows` / `curve_step_coverage` / `write_curve_csv`（原子写） | — |
| `lib/doc.py` | **S09 复现记录校验器的判定底座**（stdlib only，**不 import numpy/pandas/torch/yaml**）：九章 `DOC_SECTION:<n>` 圈定解析 / 证据索引表四列逐行断言（证据文件存在 + 关键输出串可 grep）/ SHA-256 **重算** / eval 行数与 `failed` 列重算 completion / 对照表 49 行与 Δ 均值重算 / 曲线 step 覆盖 / token 泄漏扫描 / `format_ok` / `format_fail` / 固定 `REASONS` 集合 | — |
| `lib/doc.sh` | `doc.py` 的薄壳：只做「选解释器（`DOC_PY`，默认 `python3`）→ 定位 `doc.py` → 转发参数」，**零判定逻辑** | — |
| `21_assets.sh` | **资产导出编排器**（fail-closed 环境门 → staging 导出 → 判定 → **原子发布**）：上游 `deploy.sim2sim.export_assets` 导出 `g1_amber.xml` + `meshes/` + 抽样 clip；抽样规则写死并落进 report（1h 子集 490 条**每 10 条取 1 条** = 49 条，清单落 `assets/clips_g1_amber.txt`）；子命令 `env` / `export` / `report` / `selftest`；失败路径只打印固定 reason 集合且**零 OK marker** | `logs/env/21_assets.txt` |
| `22_sim2sim.sh` | **仿真回放编排器**（`MUJOCO_GL=egl` 由本脚本显式 export，上游 `deploy.run` 不设）：`deploy.run --interface motion` 逐 clip 产出 `runs/sim2sim/summary/*.json` + `runs/sim2sim/video/*.mp4`；子命令 `env` / `run`（支持 `--limit` 冒烟与 `--clip-list`）/ `report` / `selftest`；**跌倒的 clip 不算编排失败**（数值非空 + mp4 存在即计入 `failed=`），只有基础设施失败才非零退出 | `logs/env/22_sim2sim.txt` |
| `23_eval.sh` | **评测编排器**：上游 `morphmimic.scripts.eval --interface motion\|human` 在 1h 子集上产出两张逐 clip CSV；判定用 `deploy.py`（表头契约 + 行数 == 子集实读 clip 数 + `failed` 列可解析 + completion 重算）；先用 `tiny.yaml` 冒烟再跑 1h；子命令 `env` / `motion` / `human` / `report` / `selftest` | `logs/env/23_eval.txt` |
| `24_official.sh` | **官方 v0.1 权重下载校验与同表对照**：`download`（进程级代理，不落任何系统配置）/ `verify`（目录 + `policy.onnx` + `g1_amber.json` + SHA256SUMS 覆盖且**重算**一致）/ `compare`（同一 assets、同一 clip 清单、同一 `deploy.run`，只换 `--deploy` 目录，产出 `runs/official/compare_self_vs_official.csv`）；**严禁**官方 `policy.onnx` 与我们的 `g1_amber.json` 混搭 | `logs/env/24_official.txt` |
| `25_human_replay.sh` | **人接口回放编排器**：`make_gmr_session` 造 PICO 布局 session（`body[N,24,7]`）+ `deploy.run --teleop --replay --interface human --human-points full` 回放；判定用 `deploy.py` 的 `verify_session` / `verify_session_arrays` / `verify_human_replay_summary` / `check_video`（**人接口 summary 无误差块**，字段与 motion 分支不同） | `logs/env/25_human_replay.txt` |
| `26_deploy_verify.sh` | **只读独立复核器**（不信任 21..25 的自述，只从磁盘重新推导）：`verify`（资产 ↔ 抽样清单 ↔ sim2sim summary+mp4 ↔ eval 两张表 ↔ 官方摘要**重算** ↔ 对照表 ↔ 人接口 session/summary/mp4，七个计数一行 `DEPLOY_VERIFY_OK`）/ `report`（打印 `DEPLOY_REPORT_*` 供文档回填，并保留 `sha256sum -c` 原文作为旁证）/ `selftest`（离线电池）；失败只打印 `DEPLOY_VERIFY_FAIL reason=<固定集合>`，**零 OK marker**；**只写自己的日志**，不写 `assets/` / `runs/` / `out/` | `logs/env/26_deploy_verify.txt`、`logs/env/26_deploy_verify_negatives.txt` |
| `27_train_curves.sh` | **训练曲线数据编排器**（S09 T1）：子命令 `env` / `run`（容器内用 `EventAccumulator` 聚合整个 `logs/train/g1_amber_1h/` 的 10 个 events 文件，产出 `runs/train_curves/g1_amber_1h_curves.csv` 与 `_summary.csv`，原子写）/ `report` / `selftest`；NaN 判定只认 `train.nan_audit` + `DEFAULT_WHITELIST`（`kp/return` / `kp/scale_return`），非白名单出现非有限值即 `TRAIN_CURVES_FAIL reason=<固定集合>` 且**零 OK marker**；matplotlib 可用时额外出 PNG，不可用时跳过且**不算失败** | `logs/env/27_train_curves.txt` |
| `28_doc_verify.sh` | **复现记录只读校验器**（S09 T2/T4/T5）：子命令 `verify`（九章齐备 + 证据可回溯 + 数字可重算 + token 不泄漏 → `DOC_VERIFY_OK sections=9 evidence_rows=<n> sha_ok=1 eval_rows=490 compare_rows=49 curve_rows=<m>`，失败 `DOC_VERIFY_FAIL reason=<固定集合>` 且**零 OK marker**）/ `mirror`（镜像与 `docs/code_doc/` 主交付逐字节一致 → `DOC_MIRROR_OK mirror_match=1`）/ `report`（打印 `DOC_REPORT_*`）/ `selftest`（离线负例电池）；**只写自己的日志**，不写 `docs/` / `runs/` / `out/`；`verify` **不依赖** `docs/code_doc/`（容器内该软链断链） | `logs/env/28_doc_verify.txt`、`logs/env/28_doc_verify_negatives.txt` |
| `29_doc_verify_negatives.sh` | **真负例电池**（S09 T5）：把真实记录与真实产物**复制**到临时目录（`/tmp/doc_neg.*`，产物树以软链接入，**正式落点零改动**）后再破坏副本，三条各断言「rc=1 + reason 正确 + **零** `DOC_VERIFY_OK` / `DOC_MIRROR_OK`」：改证据表里的一个数字 → `evidence-marker-missing`；删第 4 章 → `section-missing`；注入假 token → `token-leaked`；子命令 `run`（写 `logs/env/28_doc_verify_negatives.txt`）/ `both`（宿主侧与容器侧终局门逐字一致 → `DOC_TWO_SIDES_OK markers_identical=1`）/ `check`（收口自查：落点摘要 + `.staging-*` 残留） | `logs/env/28_doc_verify_negatives.txt` |
| `tests/test_doc.py` | S09 复现记录判定底座的 **stdlib unittest**（63 项，fixture 驱动）：章节 marker 解析 / 证据表解析 / SHA 与行数重算 / Δ 均值 / 曲线覆盖 / token 扫描 / marker 格式 / 固定 reason 集合 | stdout（`OK`） |
| `tests/test_doc_verify.sh` | S09 校验器的**离线负例电池**（21 类负例，每条断言「非零退出 + reason 正确 + **零** `DOC_VERIFY_OK` / `DOC_MIRROR_OK`」）：缺章 / 删表 / 证据路径不存在 / marker 串不匹配 / sha 不一致 / eval 行数错 / 对照行数错 / 曲线缺失 / 曲线 step 缺失 / token 注入 / 缺流程复现声明 / 缺未执行清单 / 缺偏离清单 / 镜像缺失 / 镜像不一致等 | stdout（`TESTS_OK`） |
| `tests/test_doc_negatives.sh` | S09 **真负例**电池的包装测试（14 项断言）：三条真负例各 rc=1 + reason 正确 + transcript 留档 + 正式落点摘要前后一致 + `.staging-*` 残留为 0 + transcript 内**零** OK marker；另断言宿主侧与容器侧终局门 marker 逐字一致（容器不可达时 SKIP） | stdout（`TESTS_OK`） |
| `tests/test_deploy.sh` | S08 判定底座的库级离线电池（shell fixture：summary/eval CSV/mp4/assets/官方目录，每条负例断言 reason 正确） | stdout（`TESTS_OK`） |
| `tests/test_deploy_assets.sh` | S08 资产编排器的离线负向电池（stub `export_assets`：staging 失败不发布、正式落点文件数正确、失败路径零 `DEPLOY_ASSETS_OK`） | stdout（`TESTS_OK`） |
| `tests/test_deploy_sim2sim.sh` | S08 回放编排器的离线负向电池（字段缺失/值为空/视频空/退出非零四类负例） | stdout（`TESTS_OK`） |
| `tests/test_deploy_eval.sh` | S08 评测编排器的离线负向电池（行数不足/缺 `failed` 列/`failed` 不可解析/CSV 缺失） | stdout（`TESTS_OK`） |
| `tests/test_deploy_official.sh` | S08 官方对照编排器的离线负向电池（zip 缺失/sha 不符/json 缺失/对照行数不符/混搭 json 被拒） | stdout（`TESTS_OK`） |
| `tests/test_deploy_human.sh` | S08 人接口编排器的离线负向电池（session 缺失/形状错/summary 缺失或字段空/mp4 空/退出非零） | stdout（`TESTS_OK`） |
| `tests/test_deploy_verify.sh` | **S08 只读复核器的离线负向电池（136 项断言）**：两 clip 的离线 fixture（假 assets / 假 summary / 假 CSV / 假官方目录 / 假 npz，npz 用 `struct` + `zipfile` 手写）覆盖 **38 类**负例，每类断言「非零退出 + reason 正确 + **零** `DEPLOY_VERIFY_OK`」；正例断言「退出 0 + **只有一行** OK marker」与「复核器不改动被审产物」 | stdout（`TESTS_OK`） |
| `tests/test_seed_human_lib.sh` | 判定底座的库级离线电池（手写 `.npy` 头 + `zipfile` 造假 npz，**只用 python3 标准库**）：集合一致 / 缺 1 / 多 1 / 帧数少 1 / BVH 头截断陷阱 | stdout（`TESTS_OK`） |
| `tests/test_seed_human.sh` | 复核器的离线负向 fixture 单测（mktemp 造假 npz 根 + 假 `1h.yaml` + 假 sidecar 根 + 假 CSV + 假 BVH 头），每个负向场景同时断言「rc≠0 + 输出无 OK marker + reason 属于固定集合」；驱动 `tests/test_seed_human.py`（stdlib unittest，14 用例） | stdout（`TESTS_OK`） |
| `tests/test_seed_npz.sh` | `seed_npz` 纯函数库的离线单测（35 项 shell 断言 + 驱动 `test_seed_npz.py` 的 44 项用例） | stdout（`TESTS_OK`） |
| `tests/test_seed_npz_verify.sh` | 复核器的负向 fixture 单测（1 正向 + 6 负向：行数不符 / error 率超限 / 嵌套被破坏 / 抽样缺失 / root 指错 / manifest 缺失），每个负向都断言「非零退出 + 无 `SEED_NPZ_VERIFY_OK`」 | stdout（`TESTS_OK`） |
| `tests/test_lib.sh` | 共享 helper 的反向/边界测试（退出码透传、git 上下文、容器守卫、配置零修改） | stdout（`TESTS_OK`） |
| `tests/test_submodules.sh` | 子模块落地逻辑的反向/边界测试（未知 SHA、远端不可达、SHA 不匹配重落地、幂等、脏工作树、失败路径证据不被覆盖） | stdout（`TESTS_OK`） |
| `tests/test_smoke.sh` | 合成站立 clip 的反向/边界测试（npz 键集、帧数、NaN/inf、关节名/刚体名、fps、脚底不穿地、npz+subset 回读、1 帧 clip 被 reader 拒绝） | stdout（`TESTS_OK`） |
| `tests/test_proxy_hygiene.sh` | 代理痕迹检测器的本地单测（干净文件不误报、大小写/冒号/apt 风格/注释风格、注释内出现代理地址也算污染、strict 模式、目录扫描） | stdout（`TESTS_OK`） |
| `tests/test_proxy_hygiene_e2e.sh` | `05_proxy_hygiene.sh` 的容器内端到端测试（真实系统干净 → 退出 0；fixture 含代理痕迹 → 非零退出 + `PROXY_HYGIENE_FAIL`；`--self-test` 不碰系统文件；跑完后真实系统文件仍无代理地址） | stdout（`TESTS_OK`） |
| `tests/test_00_env.sh` | `00_env.sh` 编排器的反向/边界测试（步骤失败、标记缺失、旧运行遗留的标记不得算数、uv-sync worker FAILED / 超时、步骤脚本缺失、编排器自身不得携带代理变量、步骤表含 `06_code_read` 且期望 marker 含 `CODE_READ_OK`） | stdout（`TESTS_OK`） |
| `tests/test_coderead.sh` | 模块覆盖率门禁的离线单测（全覆盖→通过、缺模块→非零并列出 missing、幽灵模块→只告警、职责字段为空→失败、扫描规则排除 `__pycache__` / `__init__.py` / 资产 / `third_party/`） | stdout（`TESTS_OK`） |
| `tests/test_toolchain.sh` | 工具链 verdict 契约的离线单测（格式合法、SKIPPED 必须带 reason、reason/EVIDENCE 为空判失败、四组 verdict 齐全才算 OK、缺任一组判失败） | stdout（`TESTS_OK`） |
| `tests/test_seed_finalize_report.sh` | 终局报告器的反向/边界单测（happy path 回显六个 marker；缺 marker / 下载未 DONE / 终局未 DONE / 缺 SHA256SUMS / 缺日志 → 必须非零退出且不得打印 `SEED_REPORT_OK`；`check` 不得输出 key=value 数值） | stdout（`TESTS_OK`） |
| `tests/test_train.sh` | S06 判定底座的库级离线电池（47 项 shell 断言 + 驱动 `test_train.py` 的 31 项 stdlib unittest）：迭代数换算 / LR 衰减对齐 / ckpt 网格 / 预算判定 / 日志解析 / NaN 白名单 | stdout（`TESTS_OK`） |
| `tests/test_train_orchestrator.sh` | S06 编排器的离线负向电池（67 项）：环境门各 reason / 磁盘门 / 计划门 / 状态文件原子写 / 有界等待 / 失败路径零 OK marker | stdout（`TESTS_OK`） |
| `tests/test_train_verify.sh` | S06 终局复核器的离线 fixture 负向电池（37 项）：ckpt 缺失/数量不足/unloadable、events 缺失、tag 缺失、非白名单 NaN、nonfinite_steps>0、resume 缺失/迭代为 0、CSV 缺失、三类超预算、iterations 与 lr-decay-iters 不对齐 | stdout（`TESTS_OK`） |
| `tests/test_export.sh` | S07 判定底座的库级离线电池（34 项 shell 断言 + 驱动 `test_export.py` 的 27 项 stdlib unittest）：parity 恰等 1e-4 视为通过/超过即失败、摘要改 1 位即失败、缺文件/空文件即失败、MANIFEST 缺 parity 行即失败、底座不 import numpy/torch/onnx | stdout（`TESTS_OK`） |
| `tests/test_export_verify.sh` | S07 复核器的离线负向 fixture 电池（70 项）：缺 `policy.onnx` / 缺 `MANIFEST.txt` / 空文件 / MANIFEST 缺 parity 行 / parity 超 1e-4 / SHA256SUMS 篡改摘要 / SHA256SUMS 缺 `policy.onnx` 条目，每例断言「非零退出 + 无 `EXPORT_VERIFY_OK` + reason 属于固定集合」 | stdout（`TESTS_OK`） |
| `tests/test_export_orchestrator.sh` | S07 编排器的离线负向电池（103 项）：env 门各 reason、前置 18_train_verify 失败时不导出、上游命令失败时不产正式产物、staging 校验失败（parity 超阈/缺文件/摘要不符）时不发布、发布后正式落点恰为 4 个文件、失败路径零 `EXPORT_EXPORT_OK` | stdout（`TESTS_OK`） |
| `tests/test_export_published.sh` | 已发布产物的**只读回归**：在真实 `out/g1_amber/` 上跑判定底座与复核器，不写任何文件 | stdout（`TESTS_OK`） |

每份日志以 `*_OK` 标记行收尾，便于脚本化断言（例如 `grep -q SNAPSHOT_OK logs/env/snapshot.txt`）。

## 日志落点

所有日志写在 `$REPO_ROOT/logs/env/`（`logs/` 已被 `.gitignore` 忽略，不进版本库）。
`logs/` 位于 NFS 共享目录上，因此本地与容器看到的是同一份文件。

| 日志 | 内容 |
|------|------|
| `logs/env/00_env.txt` | 一键编排的完整链路（01→06 每一步的标记行），末尾 `ENV_READY` |
| `logs/env/00_env.prev.txt` | 上一次一键编排的日志 |
| `logs/env/06_code_read.txt` | 模块覆盖率门禁产物：`MODULES_TOTAL_` / `MODULES_RECORDED_` / `MODULES_MISSING_` / `MODULES_STALE_` / `MODULES_EMPTY_DUTY_`，全通过时 `CODE_READ_OK` |
| `logs/env/08_seed_download.txt` | BONES-SEED 下载的 marker 流（`SEED_FILE_PLAN` / `SEED_DL_ATTEMPT_START` / `SEED_DL_RESUME` / `SEED_DL_PROGRESS` / `SEED_DL_FILE_OK` / `SEED_SHA256_OK` / `SEED_DOWNLOAD_OK`） |
| `logs/env/08_seed_download.status` | 下载状态文件（原子写）：`STATE` / `FILE` / `BYTES` / `TOTAL` / `PCT` / `RATE_BPS` / `ETA_SECONDS` / `ATTEMPT` / `PID` / `RC` / `STARTED_AT` |
| `logs/env/08_seed_download_worker.log` | detached 下载 worker 的 stdout（worker 自己也在主日志里写同一批 marker） |
| `logs/env/09_seed_verify.txt` | 归档校验结论：`SEED_SHA256_OK` / `SEED_TAR_CLIPS file=g1 kind=csv count=142220` / `SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220` / `SEED_VERIFY_OK` |
| `logs/env/10_seed_extract.txt` | 解包与对账结论：`SEED_EXTRACT_FILES file=g1 count=142220` / `SEED_EXTRACT_FILES file=soma_uniform count=142220` / `SEED_EXTRACT_ZERO_BYTE count=0` / `SEED_META_MATCH matched=142220 missing=0 extra=0` / `SEED_EXTRACT_OK files=284440` |
| `logs/env/11_seed_finalize.txt` | 无人值守终局链路的主日志：每个 phase 的 `SEED_FINALIZE_START` / `SEED_FINALIZE_DONE` / `SEED_FINALIZE_FAIL` + 09/10 的全部 marker |
| `logs/env/11_seed_finalize.status` | 终局链路状态文件（原子写）：`STATE=RUNNING\|DONE\|FAILED` / `RC=` / `PHASE=download\|verify\|extract\|reconcile\|sha256` / `PID=` |
| `logs/env/11_seed_finalize_worker.log` | 终局链路 detached worker 的 stdout/stderr |
| `logs/env/07_toolchain.txt` | 四条工具链探针结论：`TOOLCHAIN_<NAME>_VERDICT` / `_REASON` / `_EVIDENCE`（NAME ∈ GMR / SOMA / XRT / UNITREE），齐全后 `TOOLCHAIN_OK` |
| `logs/env/17_train.txt` / `logs/env/17_train.status` | 训练编排器主日志与原子状态文件（`STATE=DONE RC=0 ITER=26413 GPU_PEAK_MB=19094 HOST_PEAK_GB=7.00 ELAPSED=2284 IT_PER_S=1.1112`） |
| `logs/env/17_train_plan.env` | 训练计划文件（`ITERATIONS=26413 LR_DECAY_ITERS=26413 CKPT_EVERY=3000 SEGMENT_ITERS=3000 BUDGET_SECONDS=28800 COMPILE=none NUM_ENVS=1024 CKPT_COUNT=9 IT_PER_S_MEASURED=1.0790`） |
| `logs/env/17_train_worker.log` / `logs/env/17_train_resources.csv` | 训练日志本体（每段 `resumed … at iteration N`、逐行 it/s / `mem` / `nonfinite`）与 30 s 资源采样 CSV（`gpu_used_mb` / `host_used_gb`） |
| `logs/env/18_train_verify.txt` / `logs/env/18_train_report.txt` | 终局复核器原始输出（`TRAIN_VERIFY_OK` / `TRAIN_REPORT_*`）与文档回填源（三方数字交叉核对 + 口径差异说明） |
| `logs/env/19_export.txt` | 导出编排器主日志（分段头 `=== 19_export.sh <sub> <ts> ===`）：前置门禁输出、上游命令原文与上游 stdout、`EXPORT_ENV_OK` / `EXPORT_EXPORT_OK` / `EXPORT_EXPORT_FAIL` / `EXPORT_NEG_FAIL`、`sha256sum -c` 两行 OK、`EXPORT_DETERMINISM_OK` |
| `logs/env/20_export_verify.txt` | 独立复核器原始输出：`EXPORT_VERIFY_OK files=4 parity_max=… sha_files=2 robot=g1_amber` / `EXPORT_VERIFY_FAIL reason=<…>`（含三条真负例）与 `EXPORT_REPORT_*` 明细 |
| `logs/env/21_assets.txt` | 资产导出主日志：`DEPLOY_ASSETS_ENV_OK` / `DEPLOY_ASSETS_OK clips=49 xml=assets/g1_amber.xml` / `DEPLOY_REPORT_SAMPLE stride=10 rule=every-10th-clip-of-the-subset-list indices=0,10,…,480 subset_clips=490 sampled=49` / `DEPLOY_REPORT_XML` / `DEPLOY_REPORT_MESH count=35` / `DEPLOY_REPORT_CLIP_LIST_LINES count=49` |
| `logs/env/22_sim2sim.txt` | 自训 sim2sim 回放主日志：逐 clip 的 `command:` 原文与 summary 判定、`DEPLOY_SIM_OK clips=49 completed=49 video_ok=49 parity=49/49`、`DEPLOY_REPORT_WALLCLOCK clips=49 total_s=156 mean_s=3 min_s=1 max_s=7` |
| `logs/env/23_eval.txt` | 双接口评测主日志：上游 `morphmimic.scripts.eval` 的逐 clip 输出、`DEPLOY_EVAL_OK interface=motion rows=490 completion=1.000000` / `interface=human rows=490 completion=1.000000`、`DEPLOY_REPORT_EVAL`（两张 CSV 的行数/失败数/completion）与 `DEPLOY_REPORT_WALLCLOCK` |
| `logs/env/24_official.txt` | 官方权重与对照主日志：`DEPLOY_OFFICIAL_DOWNLOAD_OK bytes=63372873 files=6`、`sha256sum -c` 四行 OK、`DEPLOY_OFFICIAL_OK files=6 sha_files=4`、`DEPLOY_OFFICIAL_COMPARE_OK rows=49`、`DEPLOY_REPORT_COMPARE_MEAN_DELTA joint=0.012368 body=0.000147 drift=-0.049362` |
| `logs/env/25_human_replay.txt` | 人接口回放主日志：`DEPLOY_HUMAN_ENV_OK` / `DEPLOY_HUMAN_SESSION_OK samples=956` / `DEPLOY_HUMAN_OK steps=700 falls=0`、`DEPLOY_REPORT_SESSION samples=956 body_shape=956x24x7` / `DEPLOY_REPORT_REPLAY` / `DEPLOY_REPORT_BYTES` |
| `logs/env/26_deploy_verify.txt` | **只读独立复核器**原始输出：`DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700` / `DEPLOY_VERIFY_FAIL reason=<…>` 与 `DEPLOY_REPORT_*` 六行明细 |
| `logs/env/26_deploy_verify_negatives.txt` | 三条**真负例** transcript（官方摘要被篡改 → `official-sha-mismatch`；eval 少一行 → `eval-row-count-mismatch`；少一个 mp4 → `video-missing`），每条含原文与退出码，**零** `DEPLOY_VERIFY_OK` |

| `logs/env/27_train_curves.txt` | 训练曲线数据编排器主日志：`TRAIN_CURVES_OK events_files=10 tags=52 rows=28120 steps=26413 csv=runs/train_curves/g1_amber_1h_curves.csv` / `TRAIN_CURVES_FAIL reason=<固定 reason 集合>`（失败路径零 OK marker）与 `TRAIN_CURVES_REPORT_*` 明细 |
| `logs/env/28_doc_verify.txt` | **复现记录只读校验器**原始输出：`DOC_VERIFY_OK sections=9 evidence_rows=43 sha_ok=1 eval_rows=490 compare_rows=49 curve_rows=28120` / `DOC_VERIFY_FAIL reason=<…>` 与 `DOC_MIRROR_OK mirror_match=1` / `DOC_MIRROR_FAIL reason=mirror-missing|mirror-mismatch` |
| `logs/env/28_doc_verify_negatives.txt` | 三条**真负例** transcript（副本破坏，正式落点零改动）：改一个数字使证据 marker 串不匹配 → `reason=evidence-marker-missing`；删第 4 章 → `reason=section-missing`；注入形如 `hf_` + 20 位以上字母数字的假 token → `reason=token-leaked`；每条含原文与退出码，**零** `DOC_VERIFY_OK` / `DOC_MIRROR_OK` |

## 阅读记录与工具链结论

- `docs/code_read/CODE_MAP.md` —— 工程阅读记录：103 个模块逐条职责 + 关键调用链 + 外部依赖 + 已知坑 + 交接事项；
  其覆盖率由 `repro/06_code_read.sh` 门禁。
- `docs/code_read/TOOLCHAIN.md` —— 四条三方工具链的「验过 / 跳过 + 具体原因 + 证据路径」结论，
  与 `logs/env/07_toolchain.txt` 的 verdict 交叉断言（`repro/07_toolchain.sh verify`）。
- `docs/code_read/SEED_ACQUISITION.md` —— BONES-SEED 数据集的事实表、下载/校验/解包/对账的命令原文、
  实测速率与 ETA 偏差、与 README 的偏离清单、踩坑记录与续跑步骤。
- `docs/code_read/HUMAN_SIDECAR.md` —— npz → 24 关节 SMPL human50 sidecar 的事实表（1h 子集 490 clip /
  490 sidecar / 122,433,164 B）、终局 marker 原文、上游 `convert_human` / `check_human` 命令原文、
  偏离清单、足部 z 越界 11 条的逐条数值与语义、踩坑、证据索引与 S06/S08 的交接契约。
- `docs/code_read/NPZ_CONVERSION.md` —— G1 CSV → 50 Hz npz 与子集构建的事实表（142,220 clip /
  129,398 kept / 88.46 GiB / 五档子集 clips 与 hours）、终局 marker 原文、实测耗时与体积、
  过滤统计与 README 对照、偏离清单、踩坑、证据索引与 S05/S06/S08 的交接契约。
- `docs/code_read/TRAINING.md` —— g1_amber 训练与资源边界控制的事实表（1h 子集 490 clip / 490 sidecar /
  num_envs 1024 / float16 / compile none / 实测 1.0790 it/s / 峰值显存 19,094 MB / 峰值主机内存 7.00 GB /
  9 个 ckpt / 26,413 迭代 / 9 条 resume 证据 / 52 个 tb tag）、命令原文、迭代数换算与 8 h 档选择理由、
  降级阶梯、偏离清单、踩坑、S07/S08/S09 的交接契约。
- `docs/code_read/EXPORT.md` —— g1_amber ONNX 导出与 PyTorch parity 校验的事实表（源 ckpt ckpt_26413.pt /
  4 个产物实测字节数 / parity motion 6.2e-06、human 5.2e-06 ≤ 1e-4 / sha256sum -c 两行 OK /
  摘要前 12 位 476a90cb25f9、218afa970a20）、命令原文、三条真负例（NEG-1/NEG-2/NEG-3）、
  相对上游 README 的偏离清单（文件入参、/out/ 忽略、seed store 软链、staging 原子发布、MANIFEST 非字节可复现、纯 CPU）、
  证据索引与 S08/S09 的交接契约。

> **为什么落在 `docs/code_read/`**：仓库里原本的 `docs/code_doc` 是一个**指向仓库外的符号链接**，
> 在容器内是断链（指向宿主路径，容器看不到），因此阅读记录与工具链结论改落**仓库内**的
> `docs/code_read/`，这样本地与容器读到的是同一份文件，也才能被 `06_code_read.sh` 门禁校验。

## 代理约定（硬性）

代理**只以内联环境变量的形式存在于当前进程**：`repro/lib/common.sh` 里
`PROXY="${PROXY:-http://172.16.119.20:40381}"` 导出 `http_proxy` / `https_proxy` /
`HTTP_PROXY` / `HTTPS_PROXY` 与 `no_proxy` / `NO_PROXY`
（uv 认大写、git/curl 认小写，两套都给）。

脚本**绝不**把代理写入 `/etc/environment`、`/etc/profile*`、`~/.bashrc`、`~/.profile`、
`uv.toml`、`pip.conf`、`gitconfig` 等任何系统配置文件。`repro/05_proxy_hygiene.sh`
会用「逐文件扫描 + 非零退出」把这条约定变成机器断言：

```bash
bash repro/lib/remote.sh 05_proxy_hygiene.sh              # 正常模式（扫真实系统配置）
bash repro/lib/remote.sh 05_proxy_hygiene.sh --self-test  # 只跑检测器自检（负向测试）
```

判定规则（见 `repro/lib/proxy_hygiene.sh`）：

- **ADDR**：文件里出现本项目的代理地址 `172.16.119.20`——即使在注释里也算污染；
- **HIT**：生效中的代理设置（`(http|https|ftp|no|all)_proxy[:=]`、`proxy=`、apt 风格
  `Acquire::http::Proxy "http://..."` 等）；
- **COMMENT**：被注释掉的示例（`/etc/wgetrc` 里发行版自带的 `#https_proxy = ...`）——
  不生效，只记录不判失败；设 `PROXY_HYGIENE_STRICT=1` 可把它们也判为污染。

除文件扫描外，脚本还断言三件事：进程里的代理变量**只**是 `lib/common.sh` 内联的那一套、
`env -i` 的干净环境里没有任何代理变量、容器 init 进程（`/proc/1/environ`）与
整条 ssh → docker exec → bash 祖先链的环境里也没有代理变量。

> 编排器 `repro/00_env.sh` 是这条约定的一个特殊点：它自己**不导出**任何代理变量
> （`COMMON_PROXY_INLINE=0`），因为它是 `05_proxy_hygiene.sh` 的祖先进程，而后者会断言
> 「祖先进程链里没有代理变量」；每个步骤脚本自己 source `lib/common.sh`，
> 因此代理只存在于**步骤进程**内——这正是本项目要的语义。

## 环境事实基线（详见 `logs/env/snapshot.txt`）

- 远端：`172.16.119.199:2242`，ssh 用户 `ubuntu`，容器 `ros_dev`（无 TTY，用 `docker exec` 而非 `-it`）
- 容器 worktree 路径：`/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz`
  （与本地 `/mnt/test_cc_dev/.../M001-ttwecz` 是同一份 NFS 文件）
- GPU：NVIDIA GeForce RTX 4090（24564 MiB），驱动 595.99.02
- 工具链：uv 0.12.6；系统 python 3.12.13；uv 托管 cpython-3.11.16 已在位
- 磁盘：worktree 位于 `nfs4` 挂载 `172.16.119.20:/mnt/sdb1/work_dev/git_nfs`

## 一键复现

```bash
bash repro/lib/remote.sh 00_env.sh          # 一键跑完 01 → 02 → 03 → 04 → 05 → 06
```

`00_env.sh` 按 01 → 02 → 03 → 04 → 05 → 06 顺序执行，任一步失败即整体非零退出；
重复运行时子模块已就位、`uv sync` 走缓存、warp 内核走 `~/.cache/warp` 缓存。
其中 **06 是本地覆盖率检查**（纯文件系统操作，秒级，不需要 GPU / uv / 网络）：
它校验 `docs/code_read/CODE_MAP.md` 是否覆盖了全部 103 个模块且每条都有非空职责，
只有通过才会在编排日志里写下 `CODE_READ_OK`。
（门禁本身是 O(模块数) 的：记录只解析一次再进内存查找；早期实现每个模块重解析一遍
记录文件，在 NFS 上要 22 s，会把整条一键链路顶到超时区间。）

`07_toolchain.sh` **不进入一键编排**，必须独立运行：

```bash
bash repro/lib/remote.sh 07_toolchain.sh probe    # 跑真实探针（首次约十分钟级）
bash repro/lib/remote.sh 07_toolchain.sh verify   # 只做一致性断言，不触网、不重跑构建
```

原因是它要**触网克隆三方仓库并构建原生绑定**（XRoboToolkit 的 scikit-build-core 编译、
Unitree SDK 的 pybind11 绑定），一旦并入一键编排，「一键跑绿」就变成一条依赖外网、
耗时十分钟级的脆弱长链路。它的结论独立落在 `logs/env/07_toolchain.txt` 与
`docs/code_read/TOOLCHAIN.md`，由 `verify` 做交叉断言。

编排器本身跑在一个**脱离 ssh 会话的后台 worker** 里（`setsid nohup`），
所以即使本地会话被杀掉，流水线也会继续跑完：

```bash
bash repro/lib/remote.sh 00_env.sh start    # 立即返回（打印 worker PID）
bash repro/lib/remote.sh 00_env.sh status   # 秒级：STATE= / 已完成的 STEP / 日志尾部
bash repro/lib/remote.sh 00_env.sh wait 600 # 有界等待：0=DONE 1=FAILED 2=超时
bash repro/lib/remote.sh 00_env.sh verify   # 只做标记断言，不触发任何步骤
```

`logs/env/00_env.txt` 是**每次运行一份**（上一次运行保留在 `logs/env/00_env.prev.txt`），
里面能看到 01→06 每一步的标记行（`SNAPSHOT_OK` / `SUBMODULES_OK` /
`TORCH_VERSION_2.11.0+cu128` / `CUDA_AVAILABLE_TRUE` /
`CUDA_DEVICE_NVIDIA GeForce RTX 4090` / `UV_SYNC_OK` / `NUM_ENVS_32` /
`REWARD_MEAN_FINITE` / `SMOKE_OK` / `PROXY_HYGIENE_OK` / `PROXY_HYGIENE_SELFTEST_OK` /
`CODE_READ_OK`），
末尾是 `ENV_READY` 以及一行结论汇总。

### 实测耗时

本切片在 `172.16.119.199:2242` 的 `ros_dev` 容器内的实测值：

| 阶段 | 冷启动（首次） | 命中缓存（重复运行） |
|------|----------------|----------------------|
| `uv sync --frozen`（torch 2.11.0+cu128 + nvidia-* 全家桶） | **2024 s ≈ 34 min** | 19–20 s |
| `uv sync --frozen --group export --group teleop` | 86 s | 20–27 s |
| 32-env 冒烟（含合成 clip 生成 + 50 步仿真） | 13 s | 11–12 s |
| 其中 warp 内核 JIT（49 个 mujoco-warp 模块编译） | 一次约 20 s（编译本身约 8 s） | 命中 `~/.cache/warp`（34 MB）后 < 0.1 s/模块 |
| `06_code_read.sh` 模块覆盖率门禁 | — | **1 s**（记录只解析一次；早期实现每个模块重解析一遍 57 KB 记录，NFS 上要 22 s） |
| `00_env.sh` 全流程（01→06） | — | **71–95 s**（实测 71 s / 91 s / 94 s，波动主要来自 `uv sync` 与 torch 首次 import） |

> 冷启动的 2024 s 是**必须走网络**的那一步：torch 与 nvidia-* 的 wheel 全部经代理下载，
> uv 缓存 `/root/.cache/uv` 实测已涨到 **38 GB**（**禁止清理**，清理后重跑要重新付这 34 分钟）。
> 容器重启会丢 `~/.cache/warp`（34 MB），下一次 32-env 冒烟会重新付一次 JIT 的钱。

> `logs/env/02_uv_sync_without_gmr.txt` 保存的是「GMR 缺失 → `uv sync` 失败」的真实报错原文，
> 属于**首次失败路径证据**，`02_submodules.sh` 重复运行时不会覆盖它。
> 实测（uv 0.12.6）：默认依赖组不含 `general-motion-retargeting`，所以
> `uv sync --frozen`（默认组）在 GMR 缺失时**仍然成功**；真正失败的是 `teleop` 组：
> `error: Failed to determine installation plan / Distribution not found at: .../third_party/GMR`（exit 2）。
> 该文件同时记录了默认组（exit 0）与 `teleop` 组（exit 2）两条命令的原文。

## BONES-SEED 获取与校验（长任务，独立于一键编排）

`08_seed_download.sh` / `09_seed_verify.sh` / `10_seed_extract.sh` **不进入 `repro/00_env.sh` 一键编排**，
与 `07_toolchain.sh` 同理：它们要把 68.8 GB 数据经唯一的代理出口拉下来（实测 0.85–1.45 MB/s，
两个归档合计约 **13 h** 墙钟），并把 284,440 个 clip 解包到 NFS（实测约 22 ms/文件、约 90 min/归档）。
把它们并进一键编排，「一键跑绿」就会变成一条依赖 13 h 外网、且随时可能被代理打断的脆弱长链路。
结论独立落在 `logs/env/08_seed_download*.txt`、`logs/env/09_seed_verify.txt`、
`logs/env/10_seed_extract.txt` 与 `docs/code_read/SEED_ACQUISITION.md`。

```bash
# 下载（detached worker：跨会话存活，.part 永不删除，可续传）
bash repro/lib/remote.sh 08_seed_download.sh start
bash repro/lib/remote.sh 08_seed_download.sh status     # 秒级：STATE/FILE/BYTES/TOTAL/PCT/RATE_BPS/ETA_SECONDS/ATTEMPT
bash repro/lib/remote.sh 08_seed_download.sh wait 600    # 有界等待；超时返回 75 且不杀 worker
bash repro/lib/remote.sh 08_seed_download.sh verify      # 只读：三个文件齐 + size + sha256 sidecar
bash repro/lib/remote.sh 08_seed_download.sh probe       # 认证 + 速率探针（只拉几 MiB）

# 归档级完整性校验 -> 解包 -> 与 metadata 逐 session 对账（严格按此依赖顺序）
bash repro/lib/remote.sh 09_seed_verify.sh verify
bash repro/lib/remote.sh 10_seed_extract.sh start
bash repro/lib/remote.sh 10_seed_extract.sh wait 75
bash repro/lib/remote.sh 10_seed_extract.sh verify
sha256sum -c data/seed/_archives/SHA256SUMS
```

关键 marker：`SEED_DOWNLOAD_OK files=3 bytes=68688061944`、
`SEED_VERIFY_OK` + 两个 `SEED_TAR_CLIPS … count=142220`、
`SEED_EXTRACT_OK files=284440` + `SEED_META_MATCH matched=142220 missing=0 extra=0`。

**无人值守收口**：终局证据由 detached 的 `11_seed_finalize.sh` 链路自己产出，
不需要任何会话在世；下载到齐后，用**只读报告器**把终局数值一次性取出来
（它缺任何一项都会非零退出并列出缺项，绝不会给出「看似成功」的报告）：

```bash
bash repro/lib/remote.sh 11_seed_finalize.sh status      # STATE=DONE?
bash repro/lib/remote.sh 12_seed_finalize_report.sh       # 六个 marker 原文 + SEED_REPORT_* 数值
```

**代理约定**：这三个脚本与其它 repro 脚本同规则——代理只由 `repro/lib/common.sh` 内联到**当前进程**
（`http://172.16.119.20:40381`），不写任何系统配置；HF token 只写进 0600 的临时 header 文件，
通过 `-H @file` 传给 curl，绝不出现在命令行、日志或 `ps` 里。

**清理策略**：`data/seed/_archives/*.tar.gz` **默认保留不自动删除**（重下成本 20+ h，S04/S05 回归可能需要重新解包）；
`.part` 在成功前永不删除；`data/seed/_extract/<archive>.done` 是幂等标记，重复跑会跳过已完成的归档。

## G1 50 Hz npz 转换与子集构建（长任务，独立于一键编排）

`13_seed_convert.sh` / `14_seed_npz_verify.sh` **不进入 `repro/00_env.sh` 一键编排**（与 `07_toolchain.sh`、
`08_seed_download.sh` 同理）：它要把 142,220 个 G1 clip 写成 50 Hz npz，产出约 **88.46 GiB**
（`SEED_NPZ_FILES count=142220 bytes=94982502872`），实测全量墙钟 **7,496 s ≈ 2 h 05 min**
（速率 ≈ 18.97 clip/s，`--workers 28`）。
结论独立落在 `logs/env/13_seed_convert*.txt`、`logs/env/14_seed_npz_verify.txt`
与 `docs/code_read/NPZ_CONVERSION.md`。

```bash
# 环境门（fail-closed：torch 坏掉会把 142,220 个 clip 全标成 error）
bash repro/lib/remote.sh 13_seed_convert.sh env
# 冒烟（30 clip，不碰真实产物目录）
bash repro/lib/remote.sh 13_seed_convert.sh smoke
# detached worker（跨会话存活；上游复用已存在 npz，重启只补剩余量）
bash repro/lib/remote.sh 13_seed_convert.sh start
bash repro/lib/remote.sh 13_seed_convert.sh status     # 秒级：STATE/RC/PID/CLIPS/ROWS/ERRORS/RATE/ELAPSED
bash repro/lib/remote.sh 13_seed_convert.sh wait 600    # 有界等待；超时返回 75 且不杀 worker
# 终局复核（只读、幂等、秒级）
bash repro/lib/remote.sh 13_seed_convert.sh verify
bash repro/lib/remote.sh 14_seed_npz_verify.sh verify   # SEED_NPZ_VERIFY_OK（进宿主验证门）
bash repro/lib/remote.sh 14_seed_npz_verify.sh audit    # 全量 find 计数（长命令，不进验证门）
bash repro/lib/remote.sh 14_seed_npz_verify.sh report   # SEED_REPORT_NPZ_* 数值
```

关键 marker：`SEED_NPZ_START clips=142220 workers=28`、
`SEED_NPZ_CONVERT_OK clips=142220 rows=142220 kept=129398 errors=0 error_rate=0.0000000000 elapsed_s=7496`、
`SEED_SUBSET_OK name=1h clips=490 hours=1.0014277778`（tiny/7h/40h/all 各一条）、`SEED_SUBSET_NESTED ok`、
`SEED_NPZ_VERIFY_OK rows=142220 errors=0 rate=0.0000000000 kept=129398 subsets=5 sampled=200`。

**`subsets/1h.yaml` 是 S05（human50 sidecar）、S06（训练）、S08（评测）共同使用的唯一子集契约**
（490 clips / 1.0014 h）。

**偏离上游 README**：不使用 HF CLI（沿用 S03 的下载产物）；`--workers 28`（README 写 96，容器 `nproc=32`）；
metadata 用 `seed_metadata_v004.csv`（README 写 v003）；输出落在共享 store（`data/`、`logs/` 是软链）；
终局复核以 manifest 行数为主证据 + 200 抽样，**不重算全量 sha256 / 不把全量 `find` 放进验证门**。
详见 `docs/code_read/NPZ_CONVERSION.md`。

## human50 sidecar 生成与一致性校验（1h 子集，独立于一键编排）

`15_seed_human.sh` / `16_seed_human_verify.sh` **不进入 `repro/00_env.sh` 一键编排**（同 `13`/`14` 的理由）：
它们要在容器 venv 里跑上游 `morphmimic.scripts.convert_human`（BVH → 24 关节 SMPL human sidecar），
产物落在 `data/seed_g1_npz50/human50`（= **上游默认的 `<npz_root>/human50`**，也是 `MotionLibrary` 查找的位置）。
结论独立落在 `logs/env/15_seed_human.txt`、`logs/env/15_seed_human.status`、
`logs/env/check_human_1h.csv`、`logs/env/16_seed_human_verify.txt`
与 `docs/code_read/HUMAN_SIDECAR.md`。

```bash
# 环境门（fail-closed：秒级，容器 venv 解释器 + morphmimic/numpy/scipy 探针 + 子集可解析 + BVH 根 + sidecar 根可写）
bash repro/lib/remote.sh 15_seed_human.sh env
# 真实转换（上游 convert_human --subset-yaml … + 上游 check_human --out … + sidecar 计数）
bash repro/lib/remote.sh 15_seed_human.sh convert
# 只读状态（永远 exit 0）
bash repro/lib/remote.sh 15_seed_human.sh status
# 只读独立复核（不信任上游输出：集合双向差集 + 逐条帧数 + root 一致性）
bash repro/lib/remote.sh 16_seed_human_verify.sh verify   # SEED_HUMAN_VERIFY_OK（进宿主验证门）
bash repro/lib/remote.sh 16_seed_human_verify.sh report   # SEED_REPORT_HUMAN_* 数值
```

关键 marker：`SEED_HUMAN_ENV_OK clips=490 workers=28 python=3.11.16 numpy=2.4.6 scipy=1.17.1`、
`SEED_HUMAN_CONVERT_OK clips=490 converted=490 skipped=0 failed=0 elapsed_s=22`、
`SEED_HUMAN_SIDECARS count=490 bytes=122433164`、
`SEED_HUMAN_CHECK_OK clips=490 missing=0 mismatch=0 feet_off=11`、
`SEED_HUMAN_VERIFY_OK clips=490 sidecars=490 missing=0 extra=0 frames_match=490 feet_off=11`、
`SEED_REPORT_HUMAN_OK=1`。

**sidecar 根与 1h 子集契约**：sidecar 落在 `data/seed_g1_npz50/human50/<session>/<clip>.npz`，
**必须**与 S04 产出的同一份 `data/seed_g1_npz50/subsets/1h.yaml`（490 clips / 1.0014 h）对齐——
上游 `MotionLibrary` 要求「每个 clip 都有 sidecar 或都没有」，所以 **490/490 是硬约束**；
S06（训练）与 S08（人接口评测）必须复用这同一份 yaml 与同一个 human50 根，不要另起子集。

**上游语义缺口（如实记录，不改阈值不改数据）**：上游 `check_human` 对足部 z **只统计不判失败**
（`feet_min_z` 落在 `[-0.05, 0.10] m` 之外只打印计数，退出码仍为 0）。本次 490 条中有 **11 条（2.2 %）**
越界（全部是爬行 / 跪姿 / 匍匐 / 四足着地等语义上就该着地的动作），
以 `FEET_OFF=11` / `SEED_REPORT_HUMAN_FEET_OFF=11` 如实上报，**不**伪装成 0，**不**参与退出码判定。

**踩坑**：BVH 头 `Frame Time: 0.008333` 是 1/120 截断值，据此推导期望帧数会让 490 条里 40 条差 −1
（帧数基准只能取 robot npz 的 `joint_pos` 长度）；上游 `convert_human` 单 clip 失败仍 **exit 0**
（必须解析 `converted N, skipped M, failed K` 汇总行并断言 `failed == 0`）；
不带 `--subset-yaml` 会让上游把自己的 sidecar 当待转 clip 而自噬；
容器系统 `python3` 无 numpy，故 `repro/lib/seed_human.py` 保持**纯标准库**。
详见 `docs/code_read/HUMAN_SIDECAR.md`。

## g1_amber 训练与资源边界控制（1h 子集，独立于一键编排）

`17_train.sh` / `17_train_worker.sh` / `18_train_verify.sh` **不进入 `repro/00_env.sh` 一键编排**
（同 `13`/`14`/`15`/`16` 的理由）：它要在 RTX 4090 上跑上游 `morphmimic.scripts.train`，
是分钟级到小时级的 GPU 作业，且需要前序的 npz 与 human50 产物齐备。
结论独立落在 `logs/env/17_train*.txt`、`logs/env/17_train.status`、
`logs/env/17_train_worker.log`、`logs/env/17_train_resources.csv`、
`logs/env/18_train_verify.txt`、`logs/env/18_train_report.txt`
与 `docs/code_read/TRAINING.md`。

```bash
# 环境门（fail-closed：venv / CUDA / 1h.yaml 490 clip / human50 490 sidecar / npz 可验 / GPU 存在 / 磁盘足够）
bash repro/lib/remote.sh 17_train.sh env       # TRAIN_ENV_OK；失败 TRAIN_ENV_FAIL reason=<固定集合>
# 2k 冒烟 + 200 迭代 --compile reduce-overhead 对照 + 计划文件
bash repro/lib/remote.sh 17_train.sh smoke     # TRAIN_SMOKE_OK / COMPILE_CMP_OK / PLAN_OK
# detached 训练 worker（跨会话存活，分段 resume）
bash repro/lib/remote.sh 17_train.sh start
bash repro/lib/remote.sh 17_train.sh status    # 秒级：STATE / ITER / 资源峰值 / 日志尾，恒 exit 0
bash repro/lib/remote.sh 17_train.sh wait 600  # 有界等待；超时返回 75 且不杀 worker
# 终局复核（只读、独立于训练脚本自报）
bash repro/lib/remote.sh 18_train_verify.sh verify   # TRAIN_VERIFY_OK（进宿主验证门）
bash repro/lib/remote.sh 18_train_verify.sh report   # TRAIN_REPORT_* 数值（文档回填源）
```

关键 marker：`TRAIN_ENV_OK python=3.11.16 torch=2.11.0+cu128 clips=490 sidecars=490`、
`TRAIN_SMOKE_OK iters=2000 it_per_s=1.0790 gpu_peak_mb=18834 host_peak_gb=7.00 ckpt_mb=300`、
`COMPILE_CMP_OK mode=reduce-overhead it_per_s=1.5100 gpu_peak_mb=22100 verdict=use_none`、
`TRAIN_TRAIN_OK iterations=26413 it_per_s=1.1112 gpu_peak_gb=18.65 host_peak_gb=7.00 elapsed_s=2284`、
`TRAIN_VERIFY_OK ckpts=9 latest=1 tb_tags=52 nan_whitelist=2 resume_events=9 gpu_peak_mb=19094.0 host_peak_gb=7.0 wall_s=2284 iterations=26413 lr_decay_iters=26413`。

**训练 run 目录与 1h 子集契约**：产物落在 `logs/train/g1_amber_1h/`（**9 个 `ckpt_*.pt` + `latest.pt`**，
每个 ckpt 约 300 MiB，`latest.pt` 是 ckpt 的完整副本），
训练必须复用 S04 的同一份 `data/seed_g1_npz50/subsets/1h.yaml`（490 clips / 1.0014 h）
与 S05 的同一个 human50 根 `data/seed_g1_npz50/human50`（490 sidecar）。

**迭代数换算**：`ITERATIONS = floor(BUDGET_SECONDS × 实测 it/s × 0.85) = floor(28800 × 1.0790 × 0.85) = 26413`，
且 `--lr-decay-iters` 恒等于 `--iterations`（26413）。it/s 必须用剔除 wm-only 预热段（~2.9 it/s）后的稳态值。

**偏离上游 README**：`--num-envs 1024`（README 默认 4096，24 GB 卡放不下）、
`--compile none`（README 默认编译 CUDA graph：对照实测峰值 22,100 MB 逼近 22 GB 预算线，且每次 resume 重编译 279 s）、
`--lr-decay-iters 26413`（README 默认 250,000）、训练预算取 **8 h 档**而非 R010 字面 24 h 公式。
降级阶梯按实测改为「先降 `--imag-batch/--kp-imag-batch` → 再降 `--num-envs` → 最后 `--compile none`」，
因为显存主因是想象批（policy/critic 启动瞬间 3.11 GB → 17.09 GB），不是 env 数量。
**本 run 是流程复现，不是上游 60,000 迭代配方的数值等价复现**。详见 `docs/code_read/TRAINING.md`。

**踩坑**：`--iterations` 是「跑到第几迭代」而非「再跑多少」（`trainer.py: while self.it < cfg.iterations`）；
每次 resume 新增一个 tensorboard events 文件（本次共 10 个），复核必须聚合全部；
`kp/return` 与 `kp/scale_return` 在 copy 学生下按设计为 NaN（必须白名单化）；
`latest.pt` 与 ckpt 每次落盘写两份；venv 漂移的离线修复命令必须带 `--offline`：
`uv sync --frozen --offline --group export --group teleop`。

## ONNX 导出与 parity 校验（独立于一键编排）

`19_export.sh` / `20_export_verify.sh` **不进入 `repro/00_env.sh` 一键编排**（同 `17`/`18` 的理由）：
它要在容器 venv 里跑上游 `deploy.export_onnx`，产出 65 MB 的 `policy.onnx`，
且必须先有 S06 的终局 ckpt（`logs/train/g1_amber_1h/ckpt_26413.pt`）。
结论独立落在 `logs/env/19_export.txt`、`logs/env/20_export_verify.txt`、
`out/g1_amber/`（4 个产物）与 `docs/code_read/EXPORT.md`。

```bash
# 环境门（fail-closed：venv 可 import torch/onnx/onnxruntime/onnxscript + 源 ckpt 可 torch.load + 落点可写）
bash repro/lib/remote.sh 19_export.sh env       # EXPORT_ENV_OK；失败 EXPORT_ENV_FAIL reason=<固定集合>
# 正式导出（自动先跑 18_train_verify.sh verify 作前置门禁 → staging 导出 → 判定 → 原子发布到 out/g1_amber）
bash repro/lib/remote.sh 19_export.sh export     # EXPORT_EXPORT_OK out=…/out/g1_amber files=4 parity_max=6.2e-06
# 只读独立复核（不信任导出脚本自述：重算摘要 + 独立解析 parity）
bash repro/lib/remote.sh 20_export_verify.sh verify   # EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber
bash repro/lib/remote.sh 20_export_verify.sh report   # EXPORT_REPORT_* 数值（文档回填源）
# 摘要核验（必须 cd 进 out 目录）
(cd out/g1_amber && sha256sum -c SHA256SUMS)    # policy.onnx: OK / g1_amber.json: OK
```

关键 marker：`EXPORT_ENV_OK python=3.11.16 torch=2.11.0+cu128 onnx=1.23.2 onnxruntime=1.31.0 onnxscript=0.7.2 ckpt=…`、
`EXPORT_EXPORT_OK out=…/out/g1_amber files=4 parity_max=6.2e-06`、
`EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber`、
`EXPORT_DETERMINISM_OK policy.onnx=identical g1_amber.json=identical`（MANIFEST.txt 含写入时间，不参与判据）。

**parity 与产物契约**：`MANIFEST.txt` 的 `max |ONNX - PyTorch|` 为 **motion 6.2e-06 / human 5.2e-06**（门限 1e-4）；
4 个产物 `policy.onnx`（65,074,719 B）/ `g1_amber.json`（153,786 B）/ `MANIFEST.txt`（3,798 B）/ `SHA256SUMS`（158 B）。

**「不产半成品」靠我们的包装兑现**：上游写入顺序是「先写 `policy.onnx` → 再跑 parity → 超限才 raise」，
parity 失败会残留半成品。因此 `19_export.sh export` 把上游输出指向 **staging** 目录，
用判定底座复核 staging（4 文件齐备非空 + parity ≤ 1e-4 + 摘要重算一致），
**全通过**才 `mv` 到正式落点；任一环节失败即删 staging、正式落点**零文件**、**零 OK marker**。
判定源唯一是 `repro/lib/export.py`（纯标准库，shell 只做转发与 marker 编排）。

**偏离上游 README**：必须传 ckpt 的**文件路径**（上游传目录要求 `<robot>/ckpt_<it>.pt` 子目录结构，
我们的 run 目录是扁平的，`--iteration` 对文件入参无效）；`.gitignore` 追加 `/out/` 一行；
产物实体在 seed store、worktree 内 `out` 为软链（规避 worktree 重建删未跟踪文件）；
`MANIFEST.txt` 含写入时间故**非字节可复现**，确定性指纹只认 `policy.onnx` 与 `g1_amber.json`；
导出为纯 CPU 路径，不占 GPU 预算。详见 `docs/code_read/EXPORT.md`。

## 部署验证（仿真回放 / 评测 / 官方对照 / 人接口）

`21_assets.sh` … `26_deploy_verify.sh` **不进入 `repro/00_env.sh` 一键编排**（同 `17`…`20` 的理由）：
它们要跑上游 `deploy.run` / `morphmimic.scripts.eval`（需要 EGL、GPU、真实资产与真实 clip），
产出 `assets/`（软链到 seed store）与 `runs/`（软链到 seed store）里的二进制产物。
结论独立落在 `logs/env/21_assets.txt` … `logs/env/26_deploy_verify.txt`、
`runs/` 下的逐 clip 产物与 `docs/code_read/DEPLOY.md`。

```bash
# 1) 资产导出（staging → 判定 → 原子发布；抽样 = 1h 子集每 10 条取 1 条 = 49 条）
bash repro/lib/remote.sh 21_assets.sh env          # DEPLOY_ASSETS_ENV_OK clips=490 robot=g1_amber
bash repro/lib/remote.sh 21_assets.sh export        # DEPLOY_ASSETS_OK clips=49 xml=assets/g1_amber.xml
# 2) 自训 sim2sim 回放（MUJOCO_GL=egl 由脚本显式 export）
bash repro/lib/remote.sh 22_sim2sim.sh run --limit 1   # DEPLOY_SIM_OK clips=1 completed=1 video_ok=1
bash repro/lib/remote.sh 22_sim2sim.sh run             # DEPLOY_SIM_OK clips=49 completed=49 video_ok=49
# 3) 双接口评测（1h 子集 490 条，两张表各 490 行）
bash repro/lib/remote.sh 23_eval.sh motion         # DEPLOY_EVAL_OK interface=motion rows=490 completion=1.000000
bash repro/lib/remote.sh 23_eval.sh human          # DEPLOY_EVAL_OK interface=human rows=490 completion=1.000000
# 4) 官方 v0.1 权重 + 同表 sim2sim 对照（只换 --deploy 目录）
bash repro/lib/remote.sh 24_official.sh download   # DEPLOY_OFFICIAL_DOWNLOAD_OK bytes=63372873 files=6
bash repro/lib/remote.sh 24_official.sh verify     # DEPLOY_OFFICIAL_OK files=6 sha_files=4（4 行 OK）
bash repro/lib/remote.sh 24_official.sh compare    # DEPLOY_OFFICIAL_COMPARE_OK rows=49
# 5) 人接口回放（PICO 布局 session → --teleop --replay --interface human）
bash repro/lib/remote.sh 25_human_replay.sh session # DEPLOY_HUMAN_SESSION_OK samples=956
bash repro/lib/remote.sh 25_human_replay.sh run     # DEPLOY_HUMAN_OK steps=700 falls=0
# 6) 只读独立复核（终局门；容器内与宿主侧结论必须一致）
bash repro/lib/remote.sh 26_deploy_verify.sh verify # DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700
DEPLOY_ALLOW_LOCAL=1 bash repro/26_deploy_verify.sh verify   # 宿主侧同一结论
bash repro/lib/remote.sh 26_deploy_verify.sh report # DEPLOY_REPORT_* 数值（文档回填源）
```

关键 marker：`DEPLOY_ASSETS_OK clips=49`、`DEPLOY_SIM_OK clips=49 completed=49 video_ok=49 parity=49/49`、
`DEPLOY_EVAL_OK interface={motion|human} rows=490 completion=1.000000`、`DEPLOY_OFFICIAL_OK files=6 sha_files=4`、
`DEPLOY_OFFICIAL_COMPARE_OK rows=49`、`DEPLOY_HUMAN_OK steps=700 falls=0`、
`DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700`。

**判定源唯一**：S08 的五条工作线共用 `repro/lib/deploy.py`（stdlib only，无 numpy/torch），
`21`…`25` 是编排器（各自跑各的活，失败只打印固定 reason 集合且**零 OK marker**），
`26` 是**只读**复核器（从磁盘重新推导全部事实，只写自己的日志，
**不写** `assets/` / `runs/` / `out/`；官方摘要**自行重算**，不信 `sha256sum -c` 的自述）。

**偏离上游（务必随结论一起引用）**：官方 v0.1 只发 ONNX、没有 PyTorch checkpoint，
而 `morphmimic.scripts.eval` 的 `load_policy` 只走 `torch.load`——
所以「同口径官方对照」**只能定在 sim2sim 侧**，eval 的两张 CSV **只代表自训权重**，两者不得混算 completion；
sim2sim 对照用 1h 子集**每 10 条取 1 条**的 49 条确定性采样（全量 490×2 次 `deploy.run` 墙钟不可接受）；
人接口 session 的「操作者」是 **G1 本体**，验证的是 `action_human` 通路的**可执行性**，不是人的动作质量。
详见 `docs/code_read/DEPLOY.md`。

## 复现记录收口（S09）

`docs/code_read/MorphMimic完整复现记录.md` 是**仓库内镜像**（git 跟踪、容器可见）；
`docs/code_doc/MorphMimic完整复现记录.md` 是**用户指定的主交付落点**——
`docs/code_doc` 是仓库内的相对符号链接，指向仓库外的用户 doc 仓库。
两者**逐字节一致**（sha256 相同），由 `28_doc_verify.sh mirror` 断言。

### 终局门命令与 marker 原文

```bash
# 宿主侧：校验仓库内镜像（九章 + 证据可回溯 + 数字可重算 + token 不泄漏）
bash repro/28_doc_verify.sh verify
# DOC_VERIFY_OK sections=9 evidence_rows=43 sha_ok=1 eval_rows=490 compare_rows=49 curve_rows=28120

# 镜像与主交付的逐字节一致性
bash repro/28_doc_verify.sh mirror
# DOC_MIRROR_OK mirror_match=1

# 容器侧：结论必须与宿主侧逐字一致
bash repro/lib/remote.sh 28_doc_verify.sh verify
# DOC_VERIFY_OK sections=9 evidence_rows=43 sha_ok=1 eval_rows=490 compare_rows=49 curve_rows=28120

# 两端逐字一致的机器断言（宿主侧驱动容器侧）
bash repro/29_doc_verify_negatives.sh both
# DOC_TWO_SIDES_OK markers_identical=1
```

### 真负例（校验器不是只会报 OK）

```bash
bash repro/29_doc_verify_negatives.sh run
# NEG-1 -> DOC_VERIFY_FAIL reason=evidence-marker-missing   (rc=1)
# NEG-2 -> DOC_VERIFY_FAIL reason=section-missing            (rc=1)
# NEG-3 -> DOC_VERIFY_FAIL reason=token-leaked               (rc=1)
# DOC_NEGATIVES_OK negatives=3 reasons=evidence-marker-missing,section-missing,token-leaked
```

真负例只在**副本**上破坏（`/tmp/doc_neg.*`）：正式落点（`docs/code_read/`、`docs/code_doc/`、
`runs/`、`out/`）在电池前后的摘要**逐字节一致**，且全仓无 `.staging-*` 残留；
transcript 落 `logs/env/28_doc_verify_negatives.txt`。

失败路径只打印固定 reason 集合的**单行** `DOC_VERIFY_FAIL reason=<…>`（退出码 1），
**stdout 零 OK marker**；镜像不一致为 `DOC_MIRROR_FAIL reason=mirror-missing|mirror-mismatch`。

### 位置与限制

| 项 | 位置 | 说明 |
|------|------|------|
| 仓库内镜像 | `docs/code_read/MorphMimic完整复现记录.md` | git 跟踪、宿主与容器共用；**校验器只信这一份** |
| 用户指定主交付 | `docs/code_doc/MorphMimic完整复现记录.md` | 经 `docs/code_doc` 相对软链写入仓库外 doc 仓库的 `code_doc/` 目录 |
| 写作契约 | `docs/code_read/复现记录写作契约.md` | T2 立的机器可判定写作口径（章节 marker / 证据表四列 / 数字只引用不手抄） |
| 训练曲线数据 | `runs/train_curves/g1_amber_1h_curves.csv` / `_summary.csv` | 第 6 章引用的可复算曲线产物（28,120 行） |

**限制（容器 ros_dev 内 `docs/code_doc` 软链断链，MEM023 / D009 已实测）**：
容器里 `docs/code_doc/` 指向宿主绝对路径，容器看不到，因此
`28_doc_verify.sh verify` **绝不依赖** `docs/code_doc/` 存在——容器侧只校验仓库内镜像，
`mirror` 子命令只在宿主侧（软链可解析处）运行。发布动作**不 git add / commit 到任一仓库**，
也**不改**外部 doc 目录的其它文件（如 `session.md`）。

## 跑测试

```bash
bash repro/tests/test_lib.sh                 # 本地
bash repro/lib/remote.sh tests/test_lib.sh   # 容器内
bash repro/tests/test_submodules.sh          # 本地
bash repro/lib/remote.sh tests/test_submodules.sh   # 容器内
bash repro/lib/remote.sh tests/test_smoke.sh         # 容器内（只需 CPU）
bash repro/tests/test_proxy_hygiene.sh               # 本地（纯本地单测）
bash repro/lib/remote.sh tests/test_proxy_hygiene_e2e.sh   # 容器内（端到端 + 失败路径）
bash repro/tests/test_00_env.sh                     # 本地（编排器的反向/边界测试，无需网络与 GPU）
bash repro/tests/test_coderead.sh                  # 本地（模块覆盖率门禁的离线单测）
bash repro/tests/test_toolchain.sh                 # 本地（工具链 verdict 契约的离线单测）
bash repro/tests/test_seed_finalize.sh             # 本地（无人值守终局链路的离线 fixture 单测）
bash repro/lib/remote.sh 11_seed_finalize.sh selftest   # 容器内（同一套单测）
bash repro/tests/test_seed_finalize_report.sh      # 本地（终局报告器的离线 fixture 单测）
bash repro/lib/remote.sh tests/test_seed_finalize_report.sh   # 容器内
bash repro/tests/test_seed_npz.sh                 # 本地（S04 纯函数库与 shell 库的离线单测）
bash repro/tests/test_seed_npz_verify.sh          # 本地（S04 终局复核器的 1 正向 + 6 负向 fixture 单测）
bash repro/tests/test_seed_human_lib.sh          # 本地（S05 判定底座的库级离线电池，纯 python3 标准库）
bash repro/tests/test_seed_human.sh               # 本地（S05 复核器的负向 fixture 单测 + stdlib unittest）
bash repro/lib/remote.sh repro/tests/test_seed_human.sh   # 容器内（同一套单测，证明只依赖标准库）
bash repro/tests/test_train.sh                # 本地（S06 判定底座的 47 项离线电池 + 31 项 stdlib unittest）
bash repro/tests/test_train_orchestrator.sh   # 本地（S06 编排器的 67 项离线负向电池）
bash repro/tests/test_train_verify.sh         # 本地（S06 终局复核器的 37 项离线 fixture 负向电池）
bash repro/lib/remote.sh repro/tests/test_train_verify.sh   # 容器内（同一套单测）
bash repro/lib/remote.sh 17_train.sh selftest # 容器内（train.sh + orchestrator + verify + tb e2e 四套一起跑）
bash repro/tests/test_export.sh                 # 本地（S07 判定底座的 34 项离线电池 + 27 项 stdlib unittest）
bash repro/tests/test_export_verify.sh          # 本地（S07 复核器的 70 项离线 fixture 负向电池）
bash repro/tests/test_export_orchestrator.sh     # 本地（S07 编排器的 103 项离线负向电池）
bash repro/tests/test_export_published.sh        # 本地（已发布产物的只读回归）
bash repro/tests/test_deploy.sh                  # 本地（S08 判定底座的库级离线电池）
bash repro/tests/test_deploy_assets.sh          # 本地（S08 资产编排器的离线负向电池）
bash repro/tests/test_deploy_sim2sim.sh         # 本地（S08 回放编排器的离线负向电池）
bash repro/tests/test_deploy_eval.sh            # 本地（S08 评测编排器的离线负向电池）
bash repro/tests/test_deploy_official.sh        # 本地（S08 官方对照编排器的离线负向电池）
bash repro/tests/test_deploy_human.sh           # 本地（S08 人接口编排器的离线负向电池）
bash repro/tests/test_deploy_verify.sh          # 本地（S08 只读复核器的 136 项离线负向电池）
bash repro/tests/test_doc.py                    # 本地（S09 复现记录判定底座的 63 项 stdlib unittest）
bash repro/tests/test_doc_verify.sh             # 本地（S09 校验器的 21 类离线负例电池）
bash repro/tests/test_doc_negatives.sh          # 本地（S09 校验器的真负例电池：真实文档 + 真实产物，副本破坏）
```

测试覆盖的是 happy path 跑不到的失败面：`run_logged` 的退出码透传与空命令列表、
linked worktree 的 git 上下文解析、`remote.sh` 的 usage 与远端失败透传、
`01_snapshot.sh` 的容器守卫（本地误跑必须退出码 3 且不得改动容器产出的 snapshot.txt），
以及「跑完一轮 repro 后所有系统配置文件逐字节不变」这条硬约定。

`tests/test_submodules.sh` 用一个临时 **本地** bare 仓库当「远端」，不需要网络、
不碰真实的 `third_party/`，覆盖：锁定 SHA 正常落地、二次运行幂等（不重复 clone）、
checkout 停在别的 SHA 时重新落地、**远端没有该 SHA 时必须非零退出**、
**远端不可达时必须非零退出**、`verify_submodule` 拒绝错误 SHA / 缺失目录 / 脏工作树，
以及「失败路径证据文件不会被重复运行覆盖」（容器内跑 `02_submodules.sh` 前后比对 sha256）。

## 已知环境坑（容器 ros_dev）

1. **git 属主检查**：容器内 git 是 **2.34.1**，既不支持 `safe.directory=*` 通配符，
   也不认命令行上的 `-c safe.directory=<path>`（只读全局配置文件）；而 NFS 导出是
   root-squashed 的，root 创建的文件显示为 uid 1000，于是 root 的 git 会报
   `fatal: detected dubious ownership`。
   解决方式：`repro/lib/common.sh` 的 `git_in <dir> <args...>` 用 `setpriv` 以目录属主
   uid 运行 git，**不写任何全局/系统配置**（不碰 `safe.directory`，因此不污染
   `05_proxy_hygiene.sh` 的「系统配置零改动」断言）。
2. **linked worktree 无法用 `git submodule`**：worktree 的 `.git` 文件指向宿主本地路径，
   容器内解析不到，`git submodule update --init` 直接报
   `git-submodule cannot be used without a working tree`。
   因此 `02_submodules.sh` 按 `.gitmodules` 锁定的 SHA 手工落地（init → remote add →
   fetch → checkout），并校验 `HEAD` 与父仓库 staged 的 gitlink 一致。
   锁定 SHA 与上游 `origin/main` 的 gitlink 完全一致（实测）：
   `third_party/GMR` = `25f56db79ac411258b377b6d4ccba0c8ff3372ac`，
   `third_party/unitree_sdk2_wrapper` = `6264cc1efd9e72d3c7fffa38a360aea9e43838f3`；
   父仓库工作树的 index 与 `HEAD` 树里记录的也是这两个 SHA（`git ls-tree HEAD third_party/`）。
3. **`logs/` 在 NFS 上**：本地与容器看到同一份文件，所以只有容器才允许写
   `logs/env/`（`require_container` 守卫），本地误跑会退出码 3。
4. **env 配了 `auto_reset=False`**：`MorphMimicEnv.step` 在有环境待复位时会直接抛
   `Environments [...] must be reset via reset(env_ids=...)`。因此 `repro/lib/smoke_env.py`
   每步检查 `(terminated | truncated)` 并对结束的 env 调 `env.reset(env_ids=...)`；
   50 步里实测有 33~38 次复位。冒烟不用注册好的 task id：`MultiMotionCommand.__init__`
   在 `subset_yaml` 为空时 raise ValueError，真实 npz 要到 S03/S04 才有，
   所以 `repro/lib/make_smoke_clip.py` 自带一条合成站立 clip。
5. **warp 内核 JIT**：`mujoco-warp` 的内核第一次运行要 JIT 编译进 `~/.cache/warp`
   （实测冷启动约 20 s，日志里有 `Module ... (compiled)` 行），之后命中缓存；
   容器重启会丢缓存，下一次运行重新付这笔开销（S09 参考 `logs/env/04_smoke.txt`）。
