# EXPORT — g1_amber ONNX 导出与 PyTorch parity 校验（Slice S07 实测记录）

> 本文件是 **Slice S07**（`01-ttwecz-morphmimic` / `01-07-PLAN.md`）的终局事实记录。
> 所有数值均为本仓库在远端 `ros_dev` 容器上的**实测值**，
> 均可在文末「证据索引」的日志、marker 与产物中 grep 到；**不手抄、不臆测**。
> 简体中文叙述，技术标识（marker / 路径 / 变量名 / 数值）保留原文。
>
> **一句话结论**：上游 `deploy.export_onnx` 在本仓库的终局 ckpt 上**一次导出成功**，
> parity（`max |ONNX - PyTorch|`）为 **motion 6.2e-06 / human 5.2e-06**，远低于门限 **1e-4**；
> 产物落在 `out/g1_amber/`（4 个文件），`sha256sum -c SHA256SUMS` **两行 OK**，
> 独立复核器 `repro/20_export_verify.sh verify` 输出
> `EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber`。
>
> **但上游不满足「parity 不通过则不产半成品」**：它的写入顺序是「先写 `policy.onnx` → 再跑 parity → 超限才 raise」，
> parity 失败会在 `out_dir` 留下一个半成品 `policy.onnx`。因此本切片用
> 「**导出到 staging → 全部门通过 → 原子 rename 发布**」的包装来兑现 R012，
> 失败路径一律**正式落点零文件、零 OK marker**。

---

## 1. 事实表

### 1.1 导出契约（输入 / 命令 / 产物）

| 项 | 实测值 | 来源 |
|----|--------|------|
| 机器人 | **g1_amber** | `EXPORT_ENV_OK … ckpt=…`；`out/g1_amber/g1_amber.json`：`"robot": "g1_amber"` |
| 源 checkpoint | `logs/train/g1_amber_1h/ckpt_26413.pt`（**文件**路径，见偏离 ①） | `EXPORT_REPORT_SOURCE_CKPT path=…/logs/train/g1_amber_1h/ckpt_26413.pt`；`MANIFEST.txt` 的 `Source checkpoints` 段 |
| 训练迭代 | **26,413**（终局 ckpt） | `out/g1_amber/MANIFEST.txt`：`run g1_amber_1h (--share wm), iteration 26413, goal version 2`；`g1_amber.json`：`"iteration": 26413` |
| goal anchor | **reference**（与训练一致） | `g1_amber.json`：`"goal_anchor": "reference"`；NEG-1 反证（传 `robot` 会 raise） |
| 人接口 | **开**（`human_interface: true`，ONNX 同时出 `action_motion` 与 `action_human`） | `g1_amber.json`：`"human_interface": true`；`MANIFEST.txt`：`-> action_motion [B, 29]` / `-> action_human [B, 29]` |
| 导出命令原文 | `uv run --frozen --no-sync --group export python -m deploy.export_onnx <ckpt 文件> <staging 目录>` | `logs/env/19_export.txt` 的 `  upstream command: …` 行 |
| 导出栈版本 | python **3.11.16** / torch **2.11.0+cu128** / onnx **1.23.2** / onnxruntime **1.31.0** / onnxscript **0.7.2** | `EXPORT_ENV_OK python=3.11.16 torch=2.11.0+cu128 onnx=1.23.2 onnxruntime=1.31.0 onnxscript=0.7.2` |
| 导出 GPU 占用 | **0**（纯 CPU 路径，torch.onnx dynamo exporter 不占 GPU 预算） | 导出命令不含 `--device cuda`；`nvidia-smi` 无该进程占用（导出期间 CPU-only 推理） |
| 上游一次性命令耗时（研究阶段 /tmp 试跑） | **real 6.6 s** | `01-07-RESEARCH.md` §0「RC=0，real 6.6s」 |
| `19_export.sh export` 全程耗时（含前置门禁 + staging 校验 + 发布） | **≈ 2 min**（04:10:34 起 → 04:12:38 `sha256sum -c` 完成） | `logs/env/19_export.txt` 的分段时间戳；其中含 `18_train_verify.sh verify` 前置门禁与 65 MB `policy.onnx` 的 sha256 重算 |

### 1.2 产物（4 个文件，落在 `out/g1_amber/`）

| 文件 | 实测字节数 | 内容 | 来源 |
|------|------------|------|------|
| `policy.onnx` | **65,074,719 B**（≈ 62.1 MiB） | 共享策略图（motion 接口 + human 接口） | `EXPORT_REPORT_SIZE file=policy.onnx bytes=65074719`；`ls -l out/g1_amber` |
| `g1_amber.json` | **153,786 B** | 逐机器人输入（obs / goal / human / heading 的 mean·var）+ 机器人常量 | `EXPORT_REPORT_SIZE file=g1_amber.json bytes=153786` |
| `MANIFEST.txt` | **3,798 B** | 网络指纹、逐机器人条目、ONNX 输入输出、**parity 行**、文件 sha256 列表、源 checkpoint 路径 | `EXPORT_REPORT_SIZE file=MANIFEST.txt bytes=3798` |
| `SHA256SUMS` | **158 B** | **只有 2 行**：`policy.onnx` 与 `g1_amber.json`（不含 MANIFEST.txt） | `EXPORT_REPORT_SIZE file=SHA256SUMS bytes=158` |

> **与研究阶段预估的差异**（以实测为准，见偏离 ⑤）：
> 研究阶段在 `/tmp` 试跑得到 `g1_amber.json` 153,682 B / `MANIFEST.txt` 3,694 B，
> 本次正式导出为 **153,786 B / 3,798 B**。差异来源是这两个文件内嵌了**本次运行的绝对路径**
> （`/home/ubuntu/work_dev/…/.gsd-worktrees/M001-ttwecz/…`，研究阶段用的是 `/tmp/s07_probe_out` 的相对形态），
> 路径长度不同 → 字节数与摘要随之不同；`policy.onnx` 的字节数（65,074,719 B）与摘要完全一致，未受影响。

### 1.3 parity 与摘要（终局口径）

| 项 | 实测值 | 来源 |
|----|--------|------|
| parity 门限 | **1e-4**（上游 `PARITY_ATOL`，也是本切片判定底座的默认 `atol`） | `repro/lib/export.py` 的 `DEFAULT_ATOL`；`20_export_verify.txt` 的 `atol: 1e-4` |
| parity 实测（motion 接口） | **max \|ONNX - PyTorch\| = 6.2e-06** | `MANIFEST.txt`：`g1_amber max |ONNX - PyTorch|  motion 6.2e-06  human 5.2e-06`；`EXPORT_REPORT_PARITY robot=g1_amber interface=motion max_abs_diff=6.2e-06` |
| parity 实测（human 接口） | **max \|ONNX - PyTorch\| = 5.2e-06** | 同上；`EXPORT_REPORT_PARITY robot=g1_amber interface=human max_abs_diff=5.2e-06` |
| parity 最大值（判定口径） | **6.2e-06** | `EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber` |
| `policy.onnx` sha256 | `476a90cb25f901651684d6b6e6c1c02aee5d8cf5f405725a5a2e7624de95c155`（前 12 位 **476a90cb25f9**） | `EXPORT_REPORT_SHA file=policy.onnx sha256_12=476a90cb25f9`；`out/g1_amber/SHA256SUMS` |
| `g1_amber.json` sha256 | `218afa970a20bdc55252d67aa08bcb629756865cea5cb24c7c776e923e20746a`（前 12 位 **218afa970a20**） | `EXPORT_REPORT_SHA file=g1_amber.json sha256_12=218afa970a20`；`out/g1_amber/SHA256SUMS` |
| `sha256sum -c SHA256SUMS` | **两行 OK**：`policy.onnx: OK` / `g1_amber.json: OK` | `logs/env/19_export.txt` 的 `=== sha256sum -c SHA256SUMS (out/g1_amber) ===` 段原文 |
| 确定性（两次独立导出） | **逐字节一致**：`policy.onnx` 与 `g1_amber.json` 两个文件两次 sha256 完全相同 | `EXPORT_DETERMINISM_OK policy.onnx=identical g1_amber.json=identical (MANIFEST.txt excluded: it carries the write time)` |

### 1.4 命令原文

**编排器（全部经 `repro/lib/remote.sh` 进容器执行）**：

```bash
# 1) 环境门（秒级，fail-closed）
bash repro/lib/remote.sh 19_export.sh env
# → EXPORT_ENV_OK python=3.11.16 torch=2.11.0+cu128 onnx=1.23.2 onnxruntime=1.31.0 onnxscript=0.7.2 ckpt=…/logs/train/g1_amber_1h/ckpt_26413.pt

# 2) 正式导出（自动先跑 18_train_verify.sh verify 作为前置门禁）
bash repro/lib/remote.sh 19_export.sh export
# → EXPORT_EXPORT_OK out=…/out/g1_amber files=4 parity_max=6.2e-06

# 3) 独立复核（只读，不信任上面的自述）
bash repro/lib/remote.sh 20_export_verify.sh verify
# → EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber
bash repro/lib/remote.sh 20_export_verify.sh report
# → EXPORT_REPORT_* （本文件的文档回填源）

# 4) 摘要核验（必须 cd 进 out 目录）
cd out/g1_amber && sha256sum -c SHA256SUMS
# policy.onnx: OK
# g1_amber.json: OK
```

**上游导出命令原文（`logs/env/19_export.txt` 逐字粘贴）**：

```text
  upstream command: uv run --frozen --no-sync --group export python -m deploy.export_onnx /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz/logs/train/g1_amber_1h/ckpt_26413.pt /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz/out/.staging-440337/g1_amber
```

**等价的“直接调用上游”形态（研究阶段实测 6.6 s 的那条，**注意它会绕过我们的原子发布包装**）**：

```bash
uv run --frozen --no-sync --group export python -m deploy.export_onnx \
    logs/train/g1_amber_1h/ckpt_26413.pt out/g1_amber
```

### 1.5 终局 marker 原文（逐条粘贴）

来自 `logs/env/20_export_verify.txt`：

```text
EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber
EXPORT_REPORT_PARITY robot=g1_amber interface=human max_abs_diff=5.2e-06
EXPORT_REPORT_PARITY robot=g1_amber interface=motion max_abs_diff=6.2e-06
EXPORT_REPORT_SIZE file=MANIFEST.txt bytes=3798
EXPORT_REPORT_SIZE file=SHA256SUMS bytes=158
EXPORT_REPORT_SIZE file=g1_amber.json bytes=153786
EXPORT_REPORT_SIZE file=policy.onnx bytes=65074719
EXPORT_REPORT_SHA file=g1_amber.json sha256=218afa970a20bdc55252d67aa08bcb629756865cea5cb24c7c776e923e20746a sha256_12=218afa970a20
EXPORT_REPORT_SHA file=policy.onnx sha256=476a90cb25f901651684d6b6e6c1c02aee5d8cf5f405725a5a2e7624de95c155 sha256_12=476a90cb25f9
EXPORT_REPORT_PARITY_MAX robot=g1_amber parity_max=6.2e-06
EXPORT_REPORT_SOURCE_CKPT path=/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz/logs/train/g1_amber_1h/ckpt_26413.pt
EXPORT_REPORT_OK=1
```

来自 `logs/env/19_export.txt`：

```text
EXPORT_ENV_OK python=3.11.16 torch=2.11.0+cu128 onnx=1.23.2 onnxruntime=1.31.0 onnxscript=0.7.2 ckpt=/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz/logs/train/g1_amber_1h/ckpt_26413.pt
EXPORT_EXPORT_OK out=/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz/out/g1_amber files=4 parity_max=6.2e-06
policy.onnx: OK
g1_amber.json: OK
EXPORT_DETERMINISM_OK policy.onnx=identical g1_amber.json=identical (MANIFEST.txt excluded: it carries the write time)
```

---

## 2. 相对上游 README / 研究阶段的偏离清单（逐条含理由）

| # | 偏离 | 理由与代价 | 证据 |
|---|------|-----------|------|
| ① | **必须传 ckpt 的「文件路径」**（`logs/train/g1_amber_1h/ckpt_26413.pt`），而不是上游 README 示例里的目录（`... deploy.export_onnx logs/unified out/unified --iteration 60000`）；`--iteration` 开关对文件入参**无效** | 上游 `resolve_paths` 传目录时要求该目录下存在 `<robot>/ckpt_<it>.pt` 的**机器人子目录结构**，而我们的 run 目录是**扁平**的 `ckpt_*.pt`（S06 自己定的落点），传目录会直接 `ValueError: no <robot>/ckpt_<it>.pt checkpoints`。代价：不能用 `--iteration` 挑迭代，迭代号隐含在文件名里（`ckpt_26413.pt`） | `01-07-RESEARCH.md` §1.2；`out/g1_amber/MANIFEST.txt` 的 `iteration 26413`；`out/g1_amber/g1_amber.json` 的 `"iteration": 26413` |
| ② | `.gitignore` **追加一行 `/out/`**（唯一一行改动，其余条目不动） | 里程碑上下文声明「`out/` 是 gitignored 的产物目录」，而仓库 `.gitignore` 原本只有 `outputs/`（没有 `out/`）。不补这一行，65 MB 的 `policy.onnx` 会进 git 状态 | `grep -n '^/out/$' .gitignore` → `/out/` |
| ③ | **导出产物实体放在 seed store，worktree 内 `out` 是软链** | GSD 会删除未注册 worktree 及其未跟踪文件（MEM043），重活产物不放 worktree。worktree 内 `out -> ../../../morphmimic-seed-data/repo/out`，与既有 `data` / `logs` 软链同机制（`repro/lib/seed_store.sh` 的 `cmd_link` 同时链接 `data logs out`）。代价：worktree 内 `out` 不是普通目录，删它等于删 store 里的产物 | `ls -ld out` → `out -> ../../../morphmimic-seed-data/repo/out`；`repro/lib/seed_store.sh` 第 87–99 行 |
| ④ | 用「**staging 导出 → 全部门通过 → 原子 rename 发布**」包装上游 | 上游写入顺序是「先 `_export_onnx()` 写 `policy.onnx` → **再**跑 parity → 超限才 raise」，parity 失败会在 `out_dir` **残留半成品 `policy.onnx`**（json / MANIFEST / SHA256SUMS 不会生成），与 R012「不通过则不产半成品」直接冲突。本切片把上游输出指向 `out/.staging-<pid>/g1_amber`，用判定底座复核 staging（4 文件齐备且非空 + parity ≤ 1e-4 + 摘要重算一致），**全通过**才 `mv` 到 `out/g1_amber`。代价：多一次 rename 与一次 65 MB sha256 重算 | `repro/19_export.sh` 的 `cmd_export`（staging → 复核 → `mv`）；负例 NEG-3 的 `EXPORT_EXPORT_FAIL reason=staging-verify-failed` |
| ⑤ | **确定性指纹只认 `policy.onnx` 与 `g1_amber.json`** 两个文件；`MANIFEST.txt` 不参与 | `MANIFEST.txt` 内含写入时间（`written 2026-11-16 12:10`）与 git commit，**不是**字节可复现的；`SHA256SUMS` 也只覆盖这两个文件（158 B / 2 行）。本切片的确定性判据因此是「这两个文件两次独立导出 sha256 一致」，MANIFEST 除外 | `EXPORT_DETERMINISM_OK … (MANIFEST.txt excluded: it carries the write time)`；`out/g1_amber/SHA256SUMS` 只有 2 行 |
| ⑥ | 导出为**纯 CPU 路径**，不占 GPU 预算 | `torch.onnx.export(dynamo=True)` + onnxruntime parity 探针都在 CPU 上跑（parity 输入由 `np.random.default_rng(0)` 生成，64 组随机输入，确定性）。因此 S08 评测的 GPU 预算不受导出影响 | `MANIFEST.txt` 的 `Parity with PyTorch (each robot's own checkpoint, 64 random inputs)`；`01-07-RESEARCH.md` §1.4 |
| ⑦ | `19_export.sh export` **自动先跑 `18_train_verify.sh verify`** 作为前置门禁 | S06 的 follow-up：把训练终局复核接成 S07 的**自动**前置，而不是人工触发。前置失败即终止、不导出、不发布、零 OK marker | `logs/env/19_export.txt`：`--- precondition gate: bash …/18_train_verify.sh verify (rc=0) ---` 与 `TRAIN_VERIFY_OK ckpts=9 … iterations=26413` |
| ⑧ | 正式导出命令**不带** `--goal-anchor`（用上游默认 `reference`） | 本 ckpt 是用 `--goal-anchor reference` 训练的，上游 `check_goal_anchor` 会在 anchor 不匹配时 raise。NEG-1 反证：显式传 `--goal-anchor robot` 必然失败 | NEG-1 的 `ValueError: checkpoint … was trained with --goal-anchor reference; pass --goal-anchor reference` |

---

## 3. 失败路径记录（三条真负例，均在容器内**实跑**）

三条负例的原文都追加在 `logs/env/19_export.txt`（标记为 `EXPORT_NEG_FAIL reason=<…>`），
复核器侧负例追加在 `logs/env/20_export_verify.txt`。
**共同的结论：每条负例都非零退出、该次 run 内零 `EXPORT_EXPORT_OK` / 零 `EXPORT_VERIFY_OK`、
正式落点 `out/g1_amber/` 未被污染（无半成品）。**

### NEG-1 —— goal anchor 不匹配（上游 ValueError）

- **触发方式**：`bash repro/19_export.sh export --goal-anchor robot`（追加参数透传给上游）。
- **实跑输出要点**：

```text
  upstream command: uv run --frozen --no-sync --group export python -m deploy.export_onnx …/ckpt_26413.pt …/out/.staging-441010/g1_amber --goal-anchor robot
  File "/…/deploy/export_onnx.py", line 731, in export
    check_goal_anchor(ckpt["cfg"], goal_anchor, ckpt["_path"])
  File "/…/src/morphmimic/train/trainer.py", line 1031, in check_goal_anchor
    raise ValueError(
ValueError: checkpoint /…/logs/train/g1_amber_1h/ckpt_26413.pt was trained with --goal-anchor reference; pass --goal-anchor reference
  the upstream exporter failed (rc=1)
EXPORT_EXPORT_FAIL reason=export-failed
EXPORT_NEG_FAIL reason=export-failed
```

- **结论**：上游在写任何文件之前就 fail-closed；staging 目录被删除，**正式落点无半成品**。

### NEG-2 —— 截断的 checkpoint（上游 RuntimeError）

- **触发方式**：`head -c 1000 logs/train/g1_amber_1h/ckpt_26413.pt > /tmp/t4_ckpt_trunc.pt`，
  再 `EXPORT_CKPT=/tmp/t4_ckpt_trunc.pt bash repro/19_export.sh export`。
- **实跑输出要点**：

```text
RuntimeError: PytorchStreamReader failed reading zip archive: failed finding central directory. This is an internal miniz error. If you are seeing this error, there is a high likelihood that your checkpoint file is corrupted. …
EXPORT_EXPORT_FAIL reason=export-failed
EXPORT_NEG_FAIL reason=export-failed
```

- **结论**：同上；坏 ckpt 在上游侧即被拒，**正式落点无半成品**。

### NEG-3 —— staging 校验失败（复核器拒绝，不发布）

- **触发方式**：把正式产物复制到 `/tmp/t4_neg3_copy`，**分别**篡改
  ① `MANIFEST.txt` 的 parity 行使其超过 1e-4，② `SHA256SUMS` 里的摘要，
  再用 `EXPORT_OUT_DIR=/tmp/t4_neg3_copy bash repro/20_export_verify.sh verify` 驱动复核器。
- **实跑输出要点**（`logs/env/20_export_verify.txt`）：

```text
out dir: /tmp/t4_neg3_copy
EXPORT_VERIFY_FAIL reason=parity-over-tol
EXPORT_VERIFY_FAIL reason=sha-missing      # 篡改 parity 行后重算摘要时，SHA256SUMS 与磁盘不再匹配
EXPORT_VERIFY_FAIL reason=sha-mismatch
```

- **结论**：复核器**独立重算**摘要并独立解析 parity，不信任导出脚本的自述；
  失败路径**零 OK marker**；`/tmp/t4_neg3_copy` 之外的正式落点 `out/g1_amber/` 未被改动
  （负例全部在临时副本上做，不动正式产物）。

### 离线 fixture 负向电池（证明复核器与编排器「不是只会报 OK」）

| 电池 | 断言数 | 结果 | 覆盖的负例 |
|------|--------|------|-----------|
| `repro/tests/test_export.sh` | 34 | `PASS=34 FAIL=0` | 判定底座纯函数边界（parity 恰等于 1e-4 视为通过、超过即失败；摘要改 1 位即失败；缺文件即失败；MANIFEST 缺 parity 行即失败） |
| `repro/tests/test_export_verify.sh` | 70 | `PASS=70 FAIL=0` | 复核器 7 类负例：缺 `policy.onnx` / 缺 `MANIFEST.txt` / 空文件 / MANIFEST 缺 parity 行 / parity 超 1e-4 / SHA256SUMS 篡改摘要 / SHA256SUMS 缺 `policy.onnx` 条目（每例断言「非零退出 + 无 `EXPORT_VERIFY_OK` + reason 属于固定集合」） |
| `repro/tests/test_export_orchestrator.sh` | 103 | `PASS=103 FAIL=0` | 编排器负例：env 门各 reason、**前置 18_train_verify 失败时不导出**、上游命令失败时不产正式产物、staging 校验失败（parity 超阈 / 缺文件 / 摘要不符）时不发布、发布成功后正式落点恰为 4 个文件、失败路径零 `EXPORT_EXPORT_OK` |

失败 reason 固定集合（可 grep，`repro/lib/export.py` 与 `repro/19_export.sh` 头部注释同源）：
`missing-file / empty-file / manifest-parse-failed / parity-over-tol / sha-missing / sha-mismatch / robot-mismatch`
（复核器侧）；编排器侧为
`ckpt-verify-failed / export-failed / staging-verify-failed / publish-failed`，env 门为
`interpreter-missing / import-failed / ckpt-missing / ckpt-unloadable / out-not-writable`。

---

## 4. 只读独立复核器（`repro/20_export_verify.sh`）

- `verify`：终局门，成功打印**唯一一行**
  `EXPORT_VERIFY_OK files=4 parity_max=6.2e-06 sha_files=2 robot=g1_amber`；
  失败打印 `EXPORT_VERIFY_FAIL reason=<固定 reason 集合>` 并非零退出，**失败路径绝不打印 OK marker**
  （OK marker 缓冲到全部检查通过才 flush，项目约定 P004）。
- `report`：打印 `EXPORT_REPORT_*` 数值（**本文件的文档回填源**）。
- **只读契约**：不写 `out/g1_amber/` 下任何文件，只写自己的日志 `logs/env/20_export_verify.txt`；不触网、不占 GPU。
- 判定源唯一：`repro/lib/export.py`（`parse_manifest_parity` / `parse_sha256sums` / `sha256_file` /
  `verify_export_dir` / `format_verify_ok` / `format_verify_fail` / `format_report_lines`）；
  **纯标准库**（不 import numpy / torch / onnx），容器系统 `python3` 可直接跑。
  复核器 shell 侧只做解释器选择与 marker 编排，**不另写第二套解析逻辑**
  （这正是 S04 / S06 踩过的「双解析漂移」被规避的原因）。

---

## 5. S08 交接契约

- **`out/g1_amber/` 就是 `deploy.run --deploy <dir>` 的 `<deploy_dir>`**：

```bash
uv run --group export python -m deploy.run --deploy out/g1_amber …
```

  上游 `deploy/run.py` 从 `<deploy_dir>/<robot>.json` 读机器人常量、从 `<deploy_dir>/policy.onnx` 读策略图，
  与本切片的 4 文件布局一致（`policy.onnx` + `g1_amber.json` 是它真正消费的两个文件）。
- **ONNX 是 motion + human 双接口**（因为训练开了 `--kp-interface`，
  `g1_amber.json` 的 `human_interface: true`）：
  `-> action_motion [B, 29]`（motion goal 路径）与 `-> action_human [B, 29]`
  （human skeleton goal 路径：human_norm + heading_norm + mask_human_goal + human encoder）。
  **S08 的 human 接口回放有真实可用的 `action_human`**，不是占位。
- **动作/观测都是 canonical 29 关节序**（G1 的），见 `g1_amber.json` 的 `canonical_joint_order`；
  其他机器人需用自己的 translator。
- **`assets/`（`*.xml`）属 S08 范围，不在本切片**：
  `deploy/sim2sim/export_assets.py --bake` 产出的 `assets/*.xml` 尚未生成；
  机器人常量 JSON 已由上游随导出落在 `g1_amber.json` 的 `robot` 段里。
- **换 ckpt 必须重测 parity**：parity 数值与具体 ckpt 绑定（研究阶段风险清单 R6）。
  本切片的终局 ckpt 是 `ckpt_26413.pt`（iteration 26,413）；
  若 S08 要用训练中途的对照点（如 `ckpt_18000.pt`），必须重跑
  `19_export.sh export` + `20_export_verify.sh verify` 并更新本文件的数字。
- **依赖版本漂移会改变 parity 数值**（风险 R7）：`uv.lock` 固定了
  torch 2.11.0+cu128 / onnx 1.23.2 / onnxruntime 1.31.0 / onnxscript 0.7.2；
  换版本必须重测。

---

## 6. 证据索引与回查命令

| 证据 | 内容 |
|------|------|
| `logs/env/19_export.txt` | 导出编排日志：分段头 `=== 19_export.sh <sub> <ts> ===`、前置门禁输出、上游命令原文与上游 stdout、`EXPORT_ENV_OK` / `EXPORT_EXPORT_OK` / `EXPORT_EXPORT_FAIL` / `EXPORT_NEG_FAIL`、`sha256sum -c` 两行 OK、`EXPORT_DETERMINISM_OK` |
| `logs/env/20_export_verify.txt` | 独立复核日志：`EXPORT_VERIFY_OK` / `EXPORT_VERIFY_FAIL reason=…`（含三条 NEG-3 的失败 reason）与 `EXPORT_REPORT_*` 全量明细 |
| `out/g1_amber/policy.onnx` | 65,074,719 B；sha256 `476a90cb…c155` |
| `out/g1_amber/g1_amber.json` | 153,786 B；sha256 `218afa97…0746a`；含 `iteration` / `goal_anchor` / `human_interface` / `canonical_joint_order` / `robot` 段 |
| `out/g1_amber/MANIFEST.txt` | 3,798 B；含 parity 行、ONNX 输入输出契约、源 checkpoint 路径 |
| `out/g1_amber/SHA256SUMS` | 158 B / 2 行（`policy.onnx`、`g1_amber.json`） |
| `repro/19_export.sh` | 导出编排器（`env` / `export` / `report` / `selftest`）：前置门禁 → staging 导出 → 判定底座复核 → 原子发布 |
| `repro/20_export_verify.sh` | 只读独立复核器（`verify` / `report`） |
| `repro/lib/export.py` / `repro/lib/export.sh` | 判定底座（纯函数 + 薄壳）：`parse_manifest_parity` / `parse_sha256sums` / `sha256_file` / `verify_export_dir` / 输出行格式 |
| `repro/tests/test_export.py` / `test_export.sh` | 判定底座离线电池（27 项 unittest + 34 项 shell 断言） |
| `repro/tests/test_export_verify.sh` | 复核器负向 fixture 电池（70 项） |
| `repro/tests/test_export_orchestrator.sh` | 编排器负向电池（103 项） |
| `repro/tests/test_export_published.sh` | 已发布产物的只读回归 |
| `.gsd/phases/01-ttwecz-morphmimic/01-07-RESEARCH.md` | 研究阶段结论（上游契约通读、6.6 s 一次性导出、失败路径先验） |

**每个关键数字的回查命令**（在仓库根执行）：

```bash
# parity 与摘要
grep 'max |ONNX - PyTorch|' out/g1_amber/MANIFEST.txt
grep EXPORT_REPORT_SHA logs/env/20_export_verify.txt
grep EXPORT_REPORT_SIZE logs/env/20_export_verify.txt
grep EXPORT_VERIFY_OK logs/env/20_export_verify.txt
grep EXPORT_EXPORT_OK logs/env/19_export.txt
grep EXPORT_NEG_FAIL logs/env/19_export.txt
grep EXPORT_DETERMINISM_OK logs/env/19_export.txt
grep EXPORT_ENV_OK logs/env/19_export.txt
# 摘要核验（必须 cd 进 out 目录）
(cd out/g1_amber && sha256sum -c SHA256SUMS)
# 产物体积与落点
ls -l out/g1_amber && ls -ld out && grep -n '^/out/$' .gitignore
```
