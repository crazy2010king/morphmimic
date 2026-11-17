# DEPLOY — 部署验证：仿真回放、评测、官方对照与人接口回放（Slice S08 实测记录）

> 本文件是 **Slice S08**（`01-ttwecz-morphmimic` / `01-08-PLAN.md`）的终局事实记录。
> 所有数值均为本仓库在远端 `ros_dev` 容器上的**实测值**，
> 均可在文末「证据索引」的日志、marker 与产物中 grep 到；**不手抄、不臆测**。
> 简体中文叙述，技术标识（marker / 路径 / 变量名 / 数值）保留原文。
>
> **一句话结论**：S07 导出的 `out/g1_amber` 在远端容器里**跑通了全部五条工作线**——
> 资产导出（49 条抽样 clip）→ `deploy.run --interface motion` 的 egl 回放（49/49 完成、49 个 mp4）→
> `morphmimic.scripts.eval` 的 1h 子集双接口评测（motion 490 行、human 490 行，completion 均为 **1.0000**）→
> 官方 v0.1 `morphmimic_policy` 的同表 sim2sim 对照（49 行、两侧数值非空）→
> `make_gmr_session` + `--teleop --replay --interface human` 的人接口回放（700 步、0 跌倒）；
> 只读独立复核器 `repro/26_deploy_verify.sh verify` 在**容器内**与**宿主侧**给出同一结论：
> `DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700`。
>
> **但「官方对照」只成立于 sim2sim 侧**（见偏离 ①）：官方 v0.1 release 只发 ONNX，没有 PyTorch checkpoint，
> 而 `morphmimic.scripts.eval` 的 `load_policy` 只走 `torch.load`，
> 因此 eval 的两张 CSV **只代表自训权重**，两者**不得混算 completion**。

---

## 1. 事实表

### 1.1 资产（`assets/`，由 `repro/21_assets.sh export` 导出）

| 项 | 实测值 | 命令原文 / 关键输出 | 证据文件路径 |
|----|--------|------------------------|--------------|
| 导出命令 | 上游 `deploy.sim2sim.export_assets` | `bash repro/lib/remote.sh 21_assets.sh export` → `DEPLOY_ASSETS_OK clips=49 xml=assets/g1_amber.xml` | `logs/env/21_assets.txt` |
| 场景 XML | `assets/g1_amber.xml`，**35,186 B** | `DEPLOY_REPORT_XML path=assets/g1_amber.xml bytes=35186` | `assets/g1_amber.xml` |
| 网格 | `assets/meshes/g1_amber/`，**35** 个文件 | `DEPLOY_REPORT_MESH count=35` | `assets/meshes/g1_amber/` |
| 抽样规则 | 1h 子集 490 条 **每 10 条取 1 条**（indices 0,10,…,480）→ **49** 条 | `DEPLOY_REPORT_SAMPLE stride=10 rule=every-10th-clip-of-the-subset-list indices=0,10,...,480 subset_clips=490 sampled=49` | `assets/clips_g1_amber.txt`（49 行，每行一条相对路径） |
| clip 清单 | **49** 行（`clips/g1_amber/<stem>.npz`） | `DEPLOY_REPORT_CLIP_LIST_LINES count=49` | `assets/clips_g1_amber.txt` |
| 复核器侧 | 49 个 npz **逐个非空**、清单与落点一一对应 | `DEPLOY_VERIFY_OK assets_clips=49` | `assets/clips/g1_amber/` |

### 1.2 仿真回放（自训，`runs/sim2sim/`）

| 项 | 实测值 | 命令原文 / 关键输出 | 证据文件路径 |
|----|--------|------------------------|--------------|
| 回放命令 | `MUJOCO_GL=egl uv run --group export --frozen --offline python -m deploy.run --deploy out/g1_amber --assets assets --robot g1_amber --clip <stem> --interface motion --video runs/sim2sim/video/<stem>.mp4 --summary runs/sim2sim/summary/<stem>.json` | `logs/env/22_sim2sim.txt` 的 `  command: timeout 900 uv run …` 行 | `logs/env/22_sim2sim.txt` |
| 逐 clip 结果 | **49/49 completed**、49 个 mp4、49 份 summary | `DEPLOY_SIM_OK clips=49 completed=49 video_ok=49 parity=49/49` | `runs/sim2sim/summary/*.json`（49）、`runs/sim2sim/video/*.mp4`（49） |
| 墙钟 | 49 条共 **156 s**（均值 3 s / 条，最小 1 s，最大 7 s） | `DEPLOY_REPORT_WALLCLOCK clips=49 total_s=156 mean_s=3 min_s=1 max_s=7` | `logs/env/22_sim2sim.txt` |
| 均值（复核器重算） | joint_err_rms_rad **0.092518**、body_err_mean_m **0.041286**、end_drift_m **0.100472** | `DEPLOY_REPORT_SIM clips=49 completed=49 failed=0 mean_joint_err_rms_rad=0.09251793851045295 mean_body_err_mean_m=0.041285561636225 mean_end_drift_m=0.10047170241459458` | `runs/sim2sim/summary/*.json` |
| 字段非空 | 每份 summary 的 `result` / `joint_err_rms_rad` / `body_err_mean_m` / `end_drift_m` 均为有限数值 | `DEPLOY_VERIFY_OK sim_clips=49` | `runs/sim2sim/summary/*.json` |

### 1.3 评测（自训 ckpt，`runs/eval/`）

| 项 | 实测值 | 命令原文 / 关键输出 | 证据文件路径 |
|----|--------|------------------------|--------------|
| 评测命令 | `uv run --frozen --offline python -m morphmimic.scripts.eval --ckpt logs/train/g1_amber_1h/ckpt_26413.pt --subset-yaml data/seed_g1_npz50/subsets/1h.yaml --interface {motion\|human} --out <csv> --num-envs <n>` | `DEPLOY_EVAL_OK interface=motion rows=490 completion=1.000000` / `DEPLOY_EVAL_OK interface=human rows=490 completion=1.000000` | `logs/env/23_eval.txt` |
| motion CSV | **490** 数据行（== 1h 子集 clip 数），失败 **0**，completion **1.000000** | `DEPLOY_REPORT_EVAL interface=motion csv=runs/eval/eval_motion_1h.csv rows=490 failures=0 completion=1.000000` | `runs/eval/eval_motion_1h.csv` |
| human CSV | **490** 数据行，失败 **0**，completion **1.000000** | `DEPLOY_REPORT_EVAL interface=human csv=runs/eval/eval_human_full_1h.csv rows=490 failures=0 completion=1.000000` | `runs/eval/eval_human_full_1h.csv` |
| 表头契约 | `name,frames,failed,fail_frame,norm_return,steps,…`（`failed` 逐行可解析） | 复核器 `verify_eval_pair` 重算 completion | `runs/eval/*.csv` |
| 墙钟 | motion 490 行 **85 s**、human 490 行 **88 s** | `DEPLOY_REPORT_WALLCLOCK interface=motion seconds=85 rows=490 …` / `… interface=human seconds=88 rows=490 …` | `logs/env/23_eval.txt` |
| 复核器侧 | 两张表各 490 行、completion 由 `failed` 列重算 | `DEPLOY_VERIFY_OK eval_motion_rows=490 eval_human_rows=490` | `runs/eval/*.csv` |

### 1.4 官方对照（`runs/official/`）

| 项 | 实测值 | 命令原文 / 关键输出 | 证据文件路径 |
|----|--------|------------------------|--------------|
| 下载 | `curl -sS -L --fail --max-time 900 -o runs/official/morphmimic_policy.zip https://github.com/lzyang2000/morphmimic/releases/download/v0.1/morphmimic_policy.zip` | `DEPLOY_OFFICIAL_DOWNLOAD_OK bytes=63372873 files=6` | `logs/env/24_official.txt` |
| 目录内容 | **6** 个文件（`policy.onnx` / `g1_amber.json` / `x2.json` / `t2.json` / `MANIFEST.txt` / `SHA256SUMS`） | `DEPLOY_OFFICIAL_OK files=6 sha_files=4` | `runs/official/morphmimic_policy/` |
| 摘要覆盖 | SHA256SUMS 覆盖 **4** 个文件，复核器**自行重算**摘要并逐条比对 | `sha256sum -c` 原文四行 OK：`policy.onnx: OK` / `g1_amber.json: OK` / `t2.json: OK` / `x2.json: OK` | `runs/official/morphmimic_policy/SHA256SUMS`、`logs/env/24_official.txt` |
| `policy.onnx` sha256 | `cf95194793e4732447f66432fc2381d82dd7c3d82c94da15ad074f2cfe295512` | `DEPLOY_REPORT_OFFICIAL … policy_onnx_sha=cf95194793e47324` | `runs/official/morphmimic_policy/SHA256SUMS` |
| `g1_amber.json` sha256 | `226eddf1ee7b2d1decce495f9c92da30c35bcd7c6e8dca12726cff0a24eaa055` | `DEPLOY_REPORT_OFFICIAL … g1_amber_json_sha=226eddf1ee7b2d1d` | `runs/official/morphmimic_policy/SHA256SUMS` |
| 对照命令 | 与自训**同一** assets、**同一** clip 清单、**同一** `deploy.run` 模板，只换 `--deploy runs/official/morphmimic_policy` | `DEPLOY_OFFICIAL_COMPARE_OK rows=49` | `logs/env/24_official.txt` |
| 对照表 | **49** 行；两侧四项数值非空；delta = self − official | `DEPLOY_REPORT_COMPARE_ROWS rows=49`；`DEPLOY_REPORT_COMPARE_MEAN_DELTA joint=0.012368 body=0.000147 drift=-0.049362` | `runs/official/compare_self_vs_official.csv` |
| 差值均值（复核器重算） | Δjoint **+0.012368**、Δbody **+0.000147**、Δdrift **−0.049362** | `DEPLOY_REPORT_COMPARE rows=49 mean_delta_joint_err_rms_rad=0.012368437774625983 mean_delta_body_err_mean_m=0.0001467573274732271 mean_delta_end_drift_m=-0.04936211525179602` | `runs/official/compare_self_vs_official.csv` |

### 1.5 人接口回放（`runs/human/`）

| 项 | 实测值 | 命令原文 / 关键输出 | 证据文件路径 |
|----|--------|------------------------|--------------|
| session 造数 | `uv run --frozen --offline --group teleop python -m deploy.tools.make_gmr_session runs/human/session.npz --clip <G1 clip npz>` | `DEPLOY_HUMAN_SESSION_OK samples=956` | `logs/env/25_human_replay.txt` |
| session 结构 | PICO 布局：`body[956,24,7]`、`buttons[956,5]`、`t_ns[956]`，**1,298,040 B** | `DEPLOY_REPORT_SESSION samples=956 body_shape=956x24x7` | `runs/human/session.npz` |
| 回放命令 | `MUJOCO_GL=egl uv run --frozen --offline --group export --group teleop python -m deploy.run --deploy out/g1_amber --assets assets --robot g1_amber --teleop --replay runs/human/session.npz --interface human --human-points full --max-steps 700 --video runs/human/replay.mp4 --summary runs/human/replay_summary.json` | `DEPLOY_HUMAN_OK steps=700 falls=0` | `logs/env/25_human_replay.txt` |
| 回放结果 | **700** 步、**0** 跌倒、travel_along_m **−0.168236 m** | `DEPLOY_REPORT_HUMAN steps=700 falls=0 travel_along_m=-0.1682355027882646 session_bytes=1298040 video_bytes=1449397 interface=human full` | `runs/human/replay_summary.json` |
| 视频 | `runs/human/replay.mp4`，**1,449,397 B**（> 0） | 复核器 `check_video` | `runs/human/replay.mp4` |
| 语义 | session 里的「操作者」是 **G1 本体**（见偏离 ④） | `deploy/tools/gmr_operator.py` 的 `g1_operator` 注释 | `runs/human/replay_summary.json`（`interface: human full`，`mode: teleop`） |

### 1.6 终局 marker 原文（逐条粘贴）

```
# 容器内（ros_dev）
$ bash repro/lib/remote.sh 26_deploy_verify.sh verify
DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700

# 宿主侧（同一份 NFS 文件，DEPLOY_ALLOW_LOCAL=1）
$ DEPLOY_ALLOW_LOCAL=1 bash repro/26_deploy_verify.sh verify
DEPLOY_VERIFY_OK assets_clips=49 sim_clips=49 eval_motion_rows=490 eval_human_rows=490 official_sha_files=4 compare_rows=49 human_steps=700

# 报告（DEPLOY_REPORT_*，供本文档回填）
$ bash repro/lib/remote.sh 26_deploy_verify.sh report
DEPLOY_REPORT_ASSETS clips=49 xml=…/assets/g1_amber.xml xml_bytes=35186 meshes=35 list=…/assets/clips_g1_amber.txt
DEPLOY_REPORT_SIM clips=49 completed=49 failed=0 mean_joint_err_rms_rad=0.09251793851045295 mean_body_err_mean_m=0.041285561636225 mean_end_drift_m=0.10047170241459458
DEPLOY_REPORT_EVAL motion_rows=490 motion_failures=0 motion_completion=1.0000 human_rows=490 human_failures=0 human_completion=1.0000
DEPLOY_REPORT_OFFICIAL dir=…/runs/official/morphmimic_policy files=6 sha_files=4 policy_onnx_sha=cf95194793e47324 g1_amber_json_sha=226eddf1ee7b2d1d
DEPLOY_REPORT_COMPARE rows=49 mean_delta_joint_err_rms_rad=0.012368437774625983 mean_delta_body_err_mean_m=0.0001467573274732271 mean_delta_end_drift_m=-0.04936211525179602
DEPLOY_REPORT_HUMAN steps=700 falls=0 travel_along_m=-0.1682355027882646 session_bytes=1298040 video_bytes=1449397 interface=human full
  policy.onnx: OK
  g1_amber.json: OK
  t2.json: OK
  x2.json: OK
DEPLOY_REPORT_OK=1
```

---

## 2. 偏离清单

| # | 偏离 | 理由与实测证据 | 影响 |
|---|------|----------------|------|
| ① | **官方对照面定在 sim2sim，而不是 eval** | 官方 v0.1 release 的 `morphmimic_policy.zip` **只发 ONNX**（`policy.onnx` + 各机器人 `<robot>.json` + `MANIFEST.txt` + `SHA256SUMS`，共 6 个文件，**没有 PyTorch checkpoint**）；而 `morphmimic.scripts.eval` 的 `load_policy` **只走 `torch.load`**，无法加载 ONNX。因此「用 eval 脚本同时评自训与官方」在物理上不可行，「同口径对照」只能在 sim2sim 侧成立（同一 assets、同一 clip 清单、同一 `deploy.run` 模板，只换 `--deploy` 目录）。 | eval 的 motion/human 两张 CSV **只代表自训权重**，其 completion **不得**与官方对照表的数值混算；对照结论只以 `runs/official/compare_self_vs_official.csv` 为准。 |
| ② | **sim2sim 对照用 49 条确定性采样，不是全量 490** | 1h 子集 490 条，按**清单顺序每 10 条取 1 条**（indices 0,10,…,480，共 **49** 条），清单固化在 `assets/clips_g1_amber.txt`，自训侧与官方侧**共用同一份清单**。全量需要 490×2 = 980 次 `deploy.run`（实测每次约 3 s，纯渲染 + 推理，实测 49 条 = 156 s），墙钟与 GPU 预算不可接受。采样规则是**确定性**的（不随机），可由清单逐条回查。 | 对照表的统计口径是「每 10 条取 1 条」的 49 条子集，不是 490 条全集；文档与后续结论必须携带这一口径。 |
| ③ | **eval CSV 行数 == 1h 子集 490 条** | motion 与 human 两张表各 **490** 数据行（`DEPLOY_EVAL_OK interface=motion rows=490` / `interface=human rows=490`），行数由复核器对照 1h 子集 yaml 实读（`count_subset_clips` → 490）判定，不是写死的常量。 | 复核器 `DEPLOY_VERIFY_OK eval_motion_rows=490 eval_human_rows=490`；行数不符即 `eval-row-count-mismatch`。 |
| ④ | **人接口 session 的「操作者」是 G1 本体** | `deploy/tools/gmr_operator.py` 的 `g1_operator` 注释写明 *The operator is the G1 itself*：session 里的「人」通道数据由 G1 自身的运动轨迹录制而成。因此本切片验证的是 **`action_human` 通路可执行性**（能否把 PICO 布局的 session 喂进 policy node 并驱动 MuJoCo），**不是**人的动作质量。另外，`--interface human` 与 `--clip` 互斥（上游 `parser.error`），人接口不适用 motion 分支。 | §1.5 的 700 步 / 0 跌倒只能证明「人接口通路跑通」，不能用于评价动作质量或与 §1.3 的 completion 混算。 |
| ⑤ | **R014 的 completion ≥ 0.8 阈值：实测 completion = 1.0000，阈值满足，且未做任何调参** | motion 与 human 两个接口在 490 条 clip 上 `failed` 列**全为 False**（`failures=0`），completion 由 `failed` 列重算得 **1.0000 ≥ 0.8**，**不需要**归因或阈值调整；本次**没有**为了追平任何阈值而调整训练超参（训练仍在 **26,413** 迭代处结束，见 `out/g1_amber/MANIFEST.txt`）。若将来在更长子集或别的形态学上低于 0.8，归因方向为：单机器人（仅 g1_amber）、迭代更少（**26,413 vs 60,000**）、只见一种形态学；届时应如实写归因并说明阈值理由，**不得调参追平**。 | 阈值口径成立：实测 completion 1.0000，两张 CSV 均为 490 行、0 失败。 |

> **补充说明（口径边界）**：§1.2 的 sim2sim 指标（joint_err_rms_rad / body_err_mean_m / end_drift_m）是
> **部署回放**面的测量（自训 vs 官方，49 条），§1.3 的 completion 是 **eval 基准**面的测量（490 条），
> §1.5 是 **人接口通路**面的测量（700 步）。三者的分母、指标定义与产物落点都不同，**互不换算**。

---

## 3. 失败路径实录（三条真负例，均为**实跑**）

> 复核器 `repro/26_deploy_verify.sh` 是**只读**的：它不写 `assets/` / `runs/` / `out/`。
> 因此真负例的做法是「把真实产物**复制**一份到临时目录并做一处真实破坏」，
> 再用同一份复核器判定——产物本身不被改动。原始 transcript 见
> `logs/env/26_deploy_verify_negatives.txt`。

### NEG-1 —— 官方 `policy.onnx` 被篡改（复核器自行重算 SHA-256）

```text
--- N1: the official policy.onnx was tampered with (the SHA-256 is recomputed by the reviewer) ---
=== 26_deploy_verify.sh verify 2026-11-16T08:01:13Z ===
…
DEPLOY_VERIFY_FAIL reason=official-sha-mismatch
N1 rc=1
```

* 破坏方式：`cp -aL runs/official/morphmimic_policy /tmp/…/` 后 `printf 'tamper' >> policy.onnx`。
* 判定：**不是**采信 `sha256sum -c` 的自述，而是复核器**从字节重算**摘要后与 `SHA256SUMS` 比对。
* 退出码 **1**，**零** `DEPLOY_VERIFY_OK`。

### NEG-2 —— motion eval CSV 少一行（490 → 489）

```text
--- N2: the motion eval CSV lost one data row (490 -> 489) ---
=== 26_deploy_verify.sh verify 2026-11-16T08:01:13Z ===
…
DEPLOY_VERIFY_FAIL reason=eval-row-count-mismatch
N2 rc=1
```

* 破坏方式：复制真实 CSV 后 `head -n 490`（保留表头 + 489 数据行）。
* 判定：行数与 1h 子集实读 clip 数（490）不符。
* 退出码 **1**，**零** `DEPLOY_VERIFY_OK`。

### NEG-3 —— 少一个 sim2sim mp4

```text
--- N3: one sim2sim mp4 was removed ---
=== 26_deploy_verify.sh verify 2026-11-16T08:01:13Z ===
…
DEPLOY_VERIFY_FAIL reason=video-missing
N3 rc=1
```

* 破坏方式：把 49 个 mp4 软链进临时目录后删掉其中一条。
* 判定：summary 在、mp4 不在 → `video-missing`。
* 退出码 **1**，**零** `DEPLOY_VERIFY_OK`。

### 正式落点无半成品

* 资产导出走 **staging → 原子发布**（`assets/.staging-<pid>/` → 校验通过才 `mv` 到 `assets/`）：
  失败即删 staging 并非零退出，`assets/` 正式落点**不留半成品**（`repro/21_assets.sh`，`DEPLOY_REPORT_OK=1` 只在全通过时出现）。
* 官方 zip 的下载与解包分离：`download` 产出 `runs/official/morphmimic_policy.zip`，
  `verify` 失败时**不解包成正式目录**（解包目录只有在校验通过后才存在）。
* 本切片的**失败路径一律零 `DEPLOY_VERIFY_OK`**：OK marker 是**缓冲**的（项目约定 P004），
  只有全部门通过才 flush；失败路径只打印一行 `DEPLOY_VERIFY_FAIL reason=<固定集合>`。

### 离线 fixture 负向电池（证明复核器与编排器「不是只会报 OK」）

`bash repro/tests/test_deploy_verify.sh` 用**离线 fixture**（两 clip 的假 assets / 假 summary / 假 CSV /
假官方目录 / 假 npz）覆盖 **38 类**负例（缺失、空值、行数不符、摘要不符、形状错、坏 CSV、缺视频……），
每条都断言「**非零退出 + reason 正确 + 零 `DEPLOY_VERIFY_OK`**」，
外加正例断言「退出 0 且**只有一行** `DEPLOY_VERIFY_OK`」与「复核器不改动被审产物」。
实测：**PASS=136 FAIL=0**。

---

## 4. 只读独立复核器（`repro/26_deploy_verify.sh`）

### 4.1 语义

| marker | 语义 |
|--------|------|
| `DEPLOY_VERIFY_OK assets_clips=<n> sim_clips=<n> eval_motion_rows=<n> eval_human_rows=<n> official_sha_files=<n> compare_rows=<n> human_steps=<n>` | **唯一**一行成功标记；七个计数分别是资产 clip 数、sim2sim summary 数、motion/human eval 数据行数、官方 SHA256SUMS 覆盖条数、对照表行数、人接口步数。**缓冲输出，全部门通过才 flush。** |
| `DEPLOY_VERIFY_FAIL reason=<固定集合>` | **唯一**一行失败标记；`reason` 取自 `repro/lib/deploy.py` 的 `REASONS`（41 条），**绝不**打印任何 OK marker，进程**非零退出**。 |
| `DEPLOY_REPORT_*` | 报告形态（资产 / sim2sim / eval / 官方 / 对照 / 人接口六行），供文档回填；**不含** gate marker，`DEPLOY_REPORT_OK=1|0` 表示报告本身是否成立。 |

### 4.2 reason 固定集合（`repro/lib/deploy.py: REASONS`，41 条）

```text
summary-missing        summary-parse-failed   summary-field-missing
summary-value-empty    summary-count-mismatch summary-clip-unknown
video-missing          video-empty
eval-csv-missing       eval-csv-parse-failed  eval-row-count-mismatch
assets-missing         assets-xml-missing     assets-xml-empty
assets-clips-missing   assets-clips-mismatch  assets-clip-empty
assets-meshes-missing  clip-list-missing      clip-list-empty
official-dir-missing   official-sha-missing   official-sha-mismatch
official-json-missing  official-onnx-missing
compare-missing        compare-parse-failed   compare-row-mismatch
session-missing        session-format-invalid session-shape-invalid
replay-summary-missing replay-summary-empty
deploy-dir-missing     deploy-onnx-missing    deploy-json-missing
data-clip-missing      mujoco-gl-unset        session-make-failed
replay-run-failed      replay-timeout
```

### 4.3 只读性与判定来源

* **判定来源唯一**：`repro/lib/deploy.py`（stdlib only：argparse/csv/json/math/os/struct/hashlib/zipfile/ast）。
  复核器脚本 `repro/26_deploy_verify.sh` 只是**薄壳**（选解释器、拼路径、缓冲 marker、写自己的日志），
  与编排器 21..25、离线 fixture 电池**共用同一套判定与同一套 reason**。
* **只读**：除自己的日志 `logs/env/26_deploy_verify.txt` 外不写任何文件；
  `assets/`、`runs/`、`out/` **只读不写**（离线电池断言复核前后被审目录的文件清单与大小**逐字节一致**）。
* **不信任自述**：视频按 **clip 名**在 `runs/sim2sim/video/` 里定位（summary 里存的是容器绝对路径
  `/home/ubuntu/…`，宿主侧不可解析）；官方摘要**自行重算**（`sha256sum -c` 的原文只作为旁证留档）。

### 4.4 健康 / 告警 / 恢复信号

| 级别 | 信号 | 判读与动作 |
|------|------|------------|
| 健康 | `DEPLOY_VERIFY_OK …`（单行） | 全部七项通过；可进入 S09 的复现记录。 |
| 告警 | `DEPLOY_REPORT_SIM … failed=<n>（n>0）` 或 `DEPLOY_REPORT_EVAL … failures=<n>（n>0）` | **基础设施正常、策略有跌倒**：不是验收失败（marker 仍为 OK），但必须在文档中如实写出跌倒条数。 |
| 告警 | `DEPLOY_REPORT_COMPARE` 的 \|Δdrift\| 显著大于 0 且方向一致 | 自训与官方 v0.1 的漂移存在系统性差异，属**结论层面**的告警，必须写进偏离清单。 |
| 失败 | `DEPLOY_VERIFY_FAIL reason=<r>` + 退出码 1 | 复核器 fail-closed：按 `r` 定位第一处断链（assets → sim2sim → eval → official → compare → human 的**判定顺序**，先坏的先报）。 |
| 恢复 | 修复该 reason 对应的那一处产物后**重跑同一条命令** | 复核器无状态：只有磁盘上的事实算数，重跑即恢复；**不需要**清缓存或重跑上游训练/导出。 |
| 恢复 | 复核器自身无法给出 verdict（解释器缺失等） | fail-closed 到 `reason=summary-parse-failed`，并在日志里保留决策底座的原始输出（`| ` 前缀行）。 |

### 4.5 复核器不改变的判定链顺序

```text
assets ──▶ sim2sim ──▶ eval ──▶ official ──▶ compare ──▶ human
```

任何一环断裂时，`DEPLOY_VERIFY_FAIL` 报出的都是**第一处**断链的 reason，
因此「离线负向电池的 38 条 reason」与「真负例的 3 条 reason」可以互相印证。

---

## 5. S09 交接契约

### 5.1 本切片产出的全部路径

| 产物 | 路径（相对仓库根） |
|------|--------------------|
| 场景与网格 | `assets/g1_amber.xml`、`assets/meshes/g1_amber/`（35 文件） |
| 抽样 clip | `assets/clips/g1_amber/`（49 个 npz）、清单 `assets/clips_g1_amber.txt`（49 行） |
| 自训 sim2sim | `runs/sim2sim/summary/*.json`（49）、`runs/sim2sim/video/*.mp4`（49）、`runs/sim2sim/timings.tsv` |
| 官方 sim2sim | `runs/official/sim2sim/summary/*.json`（49）、`runs/official/sim2sim/video/*.mp4`（49） |
| 评测表 | `runs/eval/eval_motion_1h.csv`（490 行）、`runs/eval/eval_human_full_1h.csv`（490 行）、`runs/eval/timings.tsv` |
| 官方权重 | `runs/official/morphmimic_policy/`（6 文件）、`runs/official/morphmimic_policy.zip`（63,372,873 B） |
| 对照表 | `runs/official/compare_self_vs_official.csv`（49 行，13 列） |
| 人接口 | `runs/human/session.npz`、`runs/human/replay_summary.json`、`runs/human/replay.mp4`、`runs/human/stderr.log` |
| 脚本与判定 | `repro/21_assets.sh`、`repro/22_sim2sim.sh`、`repro/23_eval.sh`、`repro/24_official.sh`、`repro/25_human_replay.sh`、`repro/26_deploy_verify.sh`、`repro/lib/deploy.py`、`repro/lib/deploy.sh` |
| 日志 | `logs/env/21_assets.txt`、`22_sim2sim.txt`、`23_eval.txt`、`24_official.txt`、`25_human_replay.txt`、`26_deploy_verify.txt`、`26_deploy_verify_negatives.txt` |

> `assets/` 与 `runs/` 是 seed store 里的**软链**（二进制产物不进 git，见 `repro/lib/seed_store.sh`）。

### 5.2 命令（可直接复制）

```bash
# 1) 资产导出
bash repro/lib/remote.sh 21_assets.sh export        # → DEPLOY_ASSETS_OK clips=49
# 2) 自训 sim2sim 回放（egl）
bash repro/lib/remote.sh 22_sim2sim.sh run          # → DEPLOY_SIM_OK clips=49 completed=49 video_ok=49
# 3) 双接口评测（1h 子集）
bash repro/lib/remote.sh 23_eval.sh motion           # → DEPLOY_EVAL_OK interface=motion rows=490
bash repro/lib/remote.sh 23_eval.sh human            # → DEPLOY_EVAL_OK interface=human rows=490
# 4) 官方权重 + 对照
bash repro/lib/remote.sh 24_official.sh download     # → DEPLOY_OFFICIAL_DOWNLOAD_OK bytes=63372873
bash repro/lib/remote.sh 24_official.sh verify       # → DEPLOY_OFFICIAL_OK files=6 sha_files=4
bash repro/lib/remote.sh 24_official.sh compare      # → DEPLOY_OFFICIAL_COMPARE_OK rows=49
# 5) 人接口回放
bash repro/lib/remote.sh 25_human_replay.sh session  # → DEPLOY_HUMAN_SESSION_OK samples=956
bash repro/lib/remote.sh 25_human_replay.sh run      # → DEPLOY_HUMAN_OK steps=700 falls=0
# 6) 只读独立复核（终局门）
bash repro/lib/remote.sh 26_deploy_verify.sh verify  # → DEPLOY_VERIFY_OK assets_clips=49 … human_steps=700
bash repro/lib/remote.sh 26_deploy_verify.sh report  # → DEPLOY_REPORT_*（文档回填源）
# 7) 离线负向电池（不需要容器 / GPU / 网络）
bash repro/tests/test_deploy_verify.sh              # → PASS=136 FAIL=0
```

### 5.3 SHA-256 与关键数值

| 项 | 值 |
|----|----|
| 官方 `policy.onnx` | `cf95194793e4732447f66432fc2381d82dd7c3d82c94da15ad074f2cfe295512` |
| 官方 `g1_amber.json` | `226eddf1ee7b2d1decce495f9c92da30c35bcd7c6e8dca12726cff0a24eaa055` |
| 官方 `t2.json` | `7ab8dcd5072d5e1f15dbc8fef53c30f585f6adfba584084101ff675cf9201bbf` |
| 官方 `x2.json` | `ae73baa250cfb537d94d955776645a17bc4d7b790fe8d13cb0e9957d21fff44b` |
| 自训 `out/g1_amber/policy.onnx` | `476a90cb25f901651684d6b6e6c1c02aee5d8cf5f405725a5a2e7624de95c155` |
| 自训 `out/g1_amber/g1_amber.json` | `218afa970a20bdc55252d67aa08bcb629756865cea5cb24c7c776e923e20746a` |
| eval completion（motion / human） | **1.0000 / 1.0000**（490 / 490 行，失败 0 / 0） |
| sim2sim 均值（自训，49 条） | joint_err_rms_rad **0.092518**、body_err_mean_m **0.041286**、end_drift_m **0.100472** |
| 对照均值差（self − official，49 条） | Δjoint **+0.012368**、Δbody **+0.000147**、Δdrift **−0.049362** |
| 人接口回放 | **700** 步、**0** 跌倒、travel_along_m **−0.168236 m**、session **956** 帧 |

### 5.4 「已分析未执行」清单（S09 必须显式声明，不得默认完成）

| 项 | 已分析到的内容 | 为什么未执行 |
|----|----------------|--------------|
| **PICO 头显实机佩戴** | session 的数据布局已经是 PICO 的 `Recorder`/`ReplaySource` 格式（`t_ns` / `body[N,24,7]` / `buttons[N,5]`），`deploy/vr_teleop/pico_source.py` 可直接消费；`--replay` 已验证该格式可驱动 `action_human`。 | 本环境**没有 PICO 头显与真机 G1**，实机佩戴与链路延迟/丢帧无法在此验证；需在带设备的现场按 `deploy.run --teleop --interface human`（无 `--replay`）执行。 |
| **真机 G1 物理联调** | 策略的输入输出契约、normalizer（`g1_amber.json`）与 ONNX 图均已冻结并通过 parity（见 `EXPORT.md`）。 | 真机需要 GMR 全身动作捕捉设备与物理安全环境，本仓库只具备仿真与离线数据。 |
| **官方 x2 / t2 策略的 sim2sim 对照** | 官方 zip 内自带 `x2.json` / `t2.json`（各自 normalizer），`deploy.run --deploy <official dir> --robot x2/t2` 的**命令形态**与 g1_amber 完全同构；本切片已确认其 SHA256SUMS 覆盖这两个文件（4 行 OK）。 | 本切片只对 **g1_amber** 做了对照（资产、clip 与自训策略都只有 g1_amber 一套），x2/t2 没有对应的资产与 clip 清单；强行跑会得到「无资产」而非「无策略」的结论，故列为未执行。 |

---

## 6. 证据索引与回查命令

```bash
# 1) 终局门（容器内）
bash repro/lib/remote.sh 26_deploy_verify.sh verify

# 2) 终局门（宿主侧，结论必须一致）
DEPLOY_ALLOW_LOCAL=1 bash repro/26_deploy_verify.sh verify

# 3) 报告（文档回填源，含 sha256sum 原文）
bash repro/lib/remote.sh 26_deploy_verify.sh report

# 4) 离线负向电池（38 类负例 + 正例）
bash repro/tests/test_deploy_verify.sh

# 5) 资产清单（49 行）与抽样规则
cat assets/clips_g1_amber.txt | head -3; wc -l assets/clips_g1_amber.txt
grep -n "DEPLOY_REPORT_SAMPLE" logs/env/21_assets.txt

# 6) sim2sim 逐 clip summary 与视频计数
ls runs/sim2sim/summary | wc -l; ls runs/sim2sim/video | wc -l
python3 -c "import json;print(json.load(open('runs/sim2sim/summary/kneeling_start_004__A022.json')))"

# 7) eval 两张表的行数与 completion（failed 列重算）
python3 - <<'PY'
import csv
for name in ("eval_motion_1h.csv", "eval_human_full_1h.csv"):
    rows = list(csv.DictReader(open("runs/eval/" + name)))
    failed = sum(1 for r in rows if r["failed"].strip().lower() == "true")
    print(name, len(rows), failed, 1 - failed / len(rows))
PY

# 8) 官方权重摘要（清单 + 复核器重算 + sha256sum 原文）
cat runs/official/morphmimic_policy/SHA256SUMS
python3 repro/lib/deploy.py official --dir runs/official/morphmimic_policy --require policy.onnx --require g1_amber.json
(cd runs/official/morphmimic_policy && sha256sum -c SHA256SUMS)

# 9) 对照表（49 行、两侧数值、delta = self − official）
head -2 runs/official/compare_self_vs_official.csv; wc -l runs/official/compare_self_vs_official.csv   # 50 = 1 表头 + 49 数据行
python3 repro/lib/deploy.py compare --path runs/official/compare_self_vs_official.csv --expect-rows 49

# 10) 人接口产物（session 结构 + 回放摘要 + 视频字节）
python3 repro/lib/deploy.py session --path runs/human/session.npz --require-shape
cat runs/human/replay_summary.json
ls -l runs/human/replay.mp4

# 11) 三条真负例 transcript（零 OK marker）
grep -n "DEPLOY_VERIFY_FAIL\|rc=" logs/env/26_deploy_verify_negatives.txt

# 12) 上游命令原文（逐条可查）
grep -n "command:" logs/env/22_sim2sim.txt logs/env/24_official.txt
grep -n "DEPLOY_EVAL_OK\|DEPLOY_HUMAN_OK\|DEPLOY_OFFICIAL_COMPARE_OK" logs/env/23_eval.txt logs/env/24_official.txt logs/env/25_human_replay.txt
```

---

## 附：与相邻切片的关系

* **S07（EXPORT.md）** 产出 `out/g1_amber/`（policy.onnx + g1_amber.json + parity），本切片直接消费它作为 sim2sim 的 `--deploy` 目录。
* **S04（1h 子集 yaml）/ S05（human50 sidecar）/ S06（ckpt_26413.pt）** 分别是本切片的三条输入（clip 列表、评测输入、策略权重）。
* **S09** 直接引用本文件的事实表、偏离清单与交接契约；本文件不重复 S07 的导出细节，也不重复 S06 的训练细节。
