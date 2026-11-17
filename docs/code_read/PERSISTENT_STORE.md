# PERSISTENT_STORE — 持久 store 使用规范

> **一句话**：本项目的所有重产物只允许存在**一个固定位置**（持久 store），仓库内只允许出现**指向它的相对软链**。
> 违反这条规则不会立刻报错，但会在某次 worktree 重建后**无声地丢掉几十上百 GB**。
>
> **适用范围**：任何要往磁盘写东西的脚本（数据、模型、checkpoint、日志、视频、交付件）。
> **契约实现**：`repro/lib/seed_store.sh`（单一事实源）、`repro/30_store_guard.sh`（体检与修复）、`repro/lib/common.sh`（脚本侧守卫）。
> **事故背景**：2026-11-11 发生过两次——23.5 GB 归档 + metadata CSV、以及工具链探针的全部产物（`logs/toolchain/**`）。详见 `docs/code_read/SEED_ACQUISITION.md` 与复现记录 §1。

---

## 0. 硬规则（十条，先看这个）

1. **重产物只写 store**，路径一律经 `SEED_STORE_ROOT` 或 `$REPO_ROOT/<protected>` 解析，**不写死绝对路径**。
2. **store 必须在任何 git worktree 之外**。worktree 会被 GSD 删除，未跟踪文件随之消失。
3. **worktree 内只有相对软链**：`../../../morphmimic-seed-data/repo/<name>`。相对，才能在宿主与容器两个挂载前缀下都解析到同一份字节。
4. **不写普通目录**。写重产物前先 `store_guard <name>`，不通过就退出（fail closed）。
5. **库文件不改变调用方的 shell 选项**。被 `source` 的文件不得 `set -e`（见 §6.4）。
6. **import 期不做搬目录这类副作用**。搬目录只允许在显式入口（`30_store_guard.sh migrate`、`00_env.sh` 前置）里发生。
7. **迁移永不删文件**。同名同内容需 sha256 证明后才去重；同名不同内容报 `CONFLICT` 并原样保留。
8. **回归结果也要落进 store**。只活在会话里的 PASS 数等于没有 PASS 数。
9. **结论不等于一手日志**。文档里引用结论时，要注明一手日志是否还在。
10. **事实源只有一个**：仓库内的 `repro/` 与 `docs/code_read/`。`<store>/_quarantine/**` 是隔离区，任何脚本不得从中读取。

---

## 1. store 在哪

| 视角 | 路径 |
|---|---|
| 本地开发机 | `/mnt/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |
| 远端容器 `ros_dev` | `/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |

同一个 NFS 导出、两个挂载前缀，所以**不要用绝对路径**，用相对软链。

**解析顺序**（`repro/lib/seed_store.sh` 的 `seed_store_resolve_root`）：

1. 环境变量 `SEED_STORE_ROOT`（显式覆盖，最高优先级）
2. 按 `SEED_STORE_PREFIXES` 逐个前缀探测 `/mnt/test_cc_dev` 与 `/home/ubuntu/work_dev/wqq/nfs/test_cc_dev` 下的 `SEED_STORE_REL`
3. 回退：脚本自身所在的目录（`<store>/repro/lib/seed_store.sh` → `<store>`）

`SEED_STORE_REL` 默认 `git_source/groot_nvidia/morphmimic-seed-data/repo`，是**相对导出根**的路径——这是跨前缀可解析的关键。

```bash
bash repro/lib/seed_store.sh paths
# SEED_STORE_ROOT=/mnt/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo
# SEED_STORE_ARCHIVES=…/data/seed/_archives
# SEED_STORE_LOGS=…/logs/env
```

---

## 2. 受保护目录清单

`SEED_PROTECTED`（`repro/lib/seed_store.sh`，单一事实源）：

| 名字 | 放什么 | 体量 |
|---|---|---|
| `data` | BONES-SEED 归档/解包、50 Hz npz、human50 sidecar | 478 GB（归档 64 G + 解包 390 G + npz 88.5 GiB） |
| `logs` | 阶段日志、状态文件、训练产物（ckpt/events）、资源采样、探针产物 | 5.6 GB（训练 3.0 G） |
| `out` | ONNX 导出物（policy.onnx 65 MB + json + MANIFEST + SHA256SUMS） | 63 MB |
| `assets` | 导出的 MuJoCo 场景（XML + meshes + 每 clip 的 npz） | 37 MB |
| `runs` | 回放/评测产物（summary json、mp4、eval CSV、对照表、曲线 CSV） | 240 MB |
| `docs/code_doc` | 交付文档的持久副本（**不是** worktree 软链，见 §7） | 124 KB |

> `docs` **不在** `SEED_PROTECTED` 里：仓库内的 `docs/` 装着**被 git 跟踪**的内容（`docs/code_read/*.md`），绝不能被换成软链。

---

## 3. 软链三态与处置

`seed_store_state <name>` 只认三种状态，**没有"存在即算好"**：

| 状态 | 含义 | 谁该动手 | 处置 |
|---|---|---|---|
| `linked` | worktree 内是指向 store 的相对软链 | — | 正常 |
| `diverged` | worktree 内是**真实目录** | 人或编排器 | `bash repro/30_store_guard.sh migrate`（把内容搬回 store 并重新变软链） |
| `foreign` | worktree 内是指向**别处**的软链 | **人** | 工具永不自动改动；先确认那是不是你想要的 |

**为什么 `diverged` 这么危险**：旧实现是 `if [ -e "$REPO_ROOT/$name" ]; then return 0; fi`——`-e` 对真实目录同样为真。于是 worktree 被重建（软链变回普通目录）后，链接**不再被修复**，后续脚本照常往这个注定被删的目录里写东西。这就是 2026-11-11 两次事故的共同机制。

**为什么工具不自动删**：迁移时同名不同内容一律 `CONFLICT` + 原样保留，绝不覆盖、绝不删除。宁可停下来让人看一眼。

---

## 4. 日常工作流

### 4.1 我要写一个重产物

```bash
# 1) source common.sh（会自动解析 store、保证 logs/env 可写）
source repro/lib/common.sh

# 2) 写之前先守卫：不通过就非零退出，别硬写
store_guard data logs

# 3) 写。用 $REPO_ROOT/<name> 访问（worktree 内是软链，宿主/容器都能解析）
out="$REPO_ROOT/out/g1_amber/policy.onnx"
```

`store_guard` 失败时输出：

```
STORE_GUARD_FAIL name=out state=diverged path=/…/morphmimic/out
  the store is /…/morphmimic-seed-data/repo
  fix: bash repro/30_store_guard.sh migrate
```

### 4.2 我要新增一类受保护目录

按顺序做完这 5 步，缺一步下次 worktree 重建就会重演事故：

1. `SEED_PROTECTED` 里加上目录名（`repro/lib/seed_store.sh`）
2. `seed_store_ensure_dirs()` 里加上它的建目录语句
3. `seed_store_link` 覆盖它（`SEED_PROTECTED` 是循环驱动的，通常自动覆盖）
4. `cmd_manifest` 的「关键产物」清单里给它加条目
5. 在 `repro/lib/seed_store.sh` 的 `_seed_store_required()`（硬不变量）或 `_seed_store_advisory()`（缺失只 WARN）里登记

### 4.3 worktree 被重建之后

```bash
bash repro/30_store_guard.sh migrate   # 显式搬回 + 重新链接
bash repro/30_store_guard.sh check     # 体检
```

`00_env.sh` 的一键编排会**自动做前两步**（migrate → check），不健康就整链不启动。

---

## 5. 命令速查

| 命令 | 作用 | 成功标记 | 失败标记 |
|---|---|---|---|
| `bash repro/30_store_guard.sh check` | 结构 + 载荷体检（fail closed） | `SEED_STORE_OK` + `STORE_GUARD_OK` | `SEED_STORE_FAIL reason=<set>` + `STORE_GUARD_FAIL reason=store-incomplete` |
| `bash repro/30_store_guard.sh migrate` | 把分叉目录归并回 store 并重新链接 | `SEED_STORE_MIGRATE_OK` + `STORE_GUARD_OK` | `STORE_GUARD_FAIL reason=migrate-failed` |
| `bash repro/30_store_guard.sh manifest` | 写 `<store>/MANIFEST.txt`（存量清单） | `SEED_STORE_MANIFEST_OK path=…` | — |
| `bash repro/30_store_guard.sh doc` | 同步并逐字节比对交付记录三副本 | `SEED_STORE_DOC_OK copies=3 sha256=…` | `SEED_STORE_DOC_FAIL reason=copies-differ|copy-missing` |
| `bash repro/30_store_guard.sh doctor` | check + doc + manifest | `STORE_GUARD_OK` | `STORE_GUARD_FAIL reason=…` |
| `bash repro/lib/seed_store.sh paths` | 打印解析出的 store 路径 | — | — |

**固定 reason 集合**（便于 grep / 告警）：

```
store-root-missing   store-incomplete   migrate-failed   copies-differ   copy-missing
```

**可观测警告**（不算失败，但必须被看见）：

```
STORE_GUARD_WARN name=toolchain-probe-output reason=not-generated
```

### 5.1 清单必须便宜

`<store>/MANIFEST.txt` 用来**发现删除**，所以它必须能秒级生成。store 有 ~484 GB / ~30 万文件：

- 目录大小用 `stat`（不跑全量 `du`——实测会超过 300 s）；
- 摘要只对 ≤ 100 MB 的文件计算；
- 两个大归档（g1.tar.gz 23.5 GB、soma_uniform.tar.gz 45 GB）用**大小 + `09_seed_verify.sh` 已记录的 SHA256SUMS** 描述。

实测生成耗时 **626 ms**。

---

## 6. 写脚本时的禁止事项

### 6.1 禁止写死 store 的绝对路径

```bash
# ✗ 错：宿主与容器前缀不同，两边会落到不同目录
VENV="/mnt/test_cc_dev/.../logs/toolchain/venvs/soma"

# ✓ 对：store 相对 → 两侧逐字相同
VENV="${SEED_STORE_ROOT:-$REPO_ROOT}/logs/toolchain/venvs/soma"
```

结论块、文档、marker 里如果要塞路径，**一律用相对形式**（store 相对或仓库相对）。绝对路径会让宿主的结论和容器的结论永远对不上。

### 6.2 禁止在 import 期搬目录

`repro/lib/common.sh` 被 35+ 个脚本 source（含只读探查脚本）。它**只创建缺失的软链**，不搬目录、不改写已存在的路径。搬目录只在 `30_store_guard.sh migrate` 和 `00_env.sh` 的前置里做。

### 6.3 禁止直接 `rm -rf` store 里的东西

清理用 `migrate` 的归并语义：同内容去重、异内容 `CONFLICT` 保留。手工删 store 里的目录 = 制造下一次 18.8 h 的下载。

### 6.4 禁止被 source 的文件改 shell 选项

```bash
# ✗ 错：28_doc_verify.sh 故意用 `set -uo pipefail`（不用 -e），
#        被 source 后 -e 泄漏进去，脚本在第一个非零命令处退出，
#        永远打不出 verdict —— 实测导致 19 条负例用例失真
set -euo pipefail

# ✓ 对：库文件不改选项；严格模式只在"作为程序直接执行"时开启
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  ...
fi
```

需要跑严格模式的子逻辑，在**子进程**里做：

```bash
out="$(bash -c 'source "$1/repro/lib/seed_store.sh" >/dev/null 2>&1; seed_store_check_impl' _ "$REPO_ROOT" 2>&1)" || true
```

### 6.5 禁止把 store 放进 git worktree

`cmd_check` 会断言 store 根不在任何 `.git` 仓库内。worktree 内的 store 等于没有 store。

---

## 7. 交付记录的三副本

交付件（复现记录、对外文档）有三个副本，**必须逐字节一致**：

| 副本 | 位置 | 角色 |
|---|---|---|
| git | `docs/code_read/<name>.md` | 随仓库走，worktree 被删也不丢 |
| store | `<store>/docs/code_doc/<name>.md` | 持久副本（在受保护目录内） |
| 交付出口 | `docs/code_doc` → 用户文档仓库（**绝对软链**，只在宿主侧可解析） | 对外交付 |

```bash
bash repro/30_store_guard.sh doc
# → SEED_STORE_DOC_OK copies=3 sha256=52e8ca15…
```

> **口径澄清**：store 里的软链一律**相对**（两侧可解析）；`docs/code_doc` 这个**交付出口是绝对路径**（指向仓库外的用户 doc 仓库，容器侧不可解析）。两者职责不同，不可混用。

---

## 8. 事实源与隔离区

- **唯一事实源**：仓库内的 `repro/` 与 `docs/code_read/`。
- `<store>/_quarantine/**` 是**陈旧副本的隔离区**（保留是为了可回退），**任何脚本都不得从中读取**。2026-11-16 已把两个 2026-11-11 的旧快照（`repro-snapshot-*`、`docs-code_read-snapshot-*`）移入。
- 隔离区说明本身也在 store 里（删 store 即失），所以**仓库侧必须有一份声明**——见 `repro/README.md`「事实源与隔离区」与复现记录 §1。

---

## 9. 故障处置手册

| 症状 | 原因 | 处置 |
|---|---|---|
| `STORE_GUARD_FAIL name=X state=diverged` | worktree 被重建，X 变回普通目录 | `bash repro/30_store_guard.sh migrate` |
| `SEED_STORE_FAIL reason=store-root-missing` | store 目录不见了（换机 / 挂载点变了） | 用 `SEED_STORE_ROOT=` 显式指向；确认真实位置后再迁 |
| 产物"凭空消失"、日志却还在 | 旧机制：日志有 store 回落，数据没有 | 立刻 `migrate`，并确认脚本已 `store_guard` |
| `SEED_STORE_DOC_FAIL reason=copies-differ` | 交付件三副本不一致 | 决定哪份权威，同步其余两份，再 `doc` 复验 |
| `SEED_STORE_FAIL reason=store-incomplete` | 必需载荷缺失（归档 / manifest.csv / 1h.yaml / logs/env） | 按 `08 → 09 → 10` 重建（下载 68.8 GB 约 18.8 h） |
| `STORE_GUARD_WARN name=toolchain-probe-output` | 工具链探针产物没生成 | 需外网：`bash repro/lib/remote.sh 07_toolchain.sh probe` |
| 脚本在容器里报"must run inside the ros_dev container" | 本地没有 GPU / uv / 外网 | 用 `bash repro/lib/remote.sh <script>` 转发到容器 |

---

## 10. 提交前自检清单

- [ ] 新脚本要写的东西在 `SEED_PROTECTED` 覆盖范围内？不在就先登记（§4.2）
- [ ] 写之前调了 `store_guard`？
- [ ] 路径全是相对/store 相对，没有写死绝对路径？
- [ ] 结论或 marker 里没有嵌绝对路径？
- [ ] 没有在 `source` 的文件里改 shell 选项？
- [ ] 新增/改动的脚本都跑过 `bash repro/31_test_batteries.sh`？
- [ ] 回归输出落进了 `logs/env/`（在 store 内）？
- [ ] 若涉及交付件：三副本同步 + `bash repro/30_store_guard.sh doc` 通过？
- [ ] `bash repro/30_store_guard.sh check` 仍然 `STORE_GUARD_OK`？

---

## 11. 相关文件

| 文件 | 作用 |
|---|---|
| `repro/lib/seed_store.sh` | 契约的单一事实源（解析、状态机、归并、体检、清单、三副本比对） |
| `repro/30_store_guard.sh` | 体检与修复入口（check / migrate / manifest / doc / doctor） |
| `repro/lib/common.sh` | 脚本侧入口：解析 store、建链、`store_guard` 包装 |
| `repro/tests/test_store_guard.sh` | 契约的 30 条离线断言（改 store 逻辑后必须跑） |
| `repro/31_test_batteries.sh` | 全部离线电池汇总，落进 store |
| `repro/README.md` §持久 store | 团队速查（本文的浓缩版） |
| `docs/code_read/SEED_ACQUISITION.md` | 事故复盘与下载链路的完整记录 |
| `docs/code_read/MorphMimic完整复现记录.md` §1 | 面向读者的事实与存量（本文的工程背景） |

---

*规范版本：2026-11-16（随 M001-ttwecz 的验证修复同步落地）。改契约时，请同时更新：本文、`repro/lib/seed_store.sh` 的头注释、`repro/README.md`「持久 store」小节、以及 `repro/tests/test_store_guard.sh` 的断言。*
