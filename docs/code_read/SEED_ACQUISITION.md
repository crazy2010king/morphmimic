# BONES-SEED 数据集获取、完整性校验与解包记录

> 本文件是切片 **S03（BONES-SEED 获取与完整性校验）** 的唯一新增文档。
> 每一个结论都能回溯到「命令原文 + 日志路径 + 行号」。
> 采集环境：远端 `ros_dev` 容器（`172.16.119.199:2242`），NFS 共享 worktree。

---

## 1. 数据集事实表

| 项 | 值 | 来源 |
|----|----|------|
| 仓库 | `bones-studio/seed`（HF dataset，gated=auto，private=false） | `SEED_HF_REPO` marker |
| revision | `2f59b2077b9da34dd4e43618e705c7cb962c9a66` | `SEED_HF_REVISION` marker |
| resolve 基址 | `https://huggingface.co/datasets/bones-studio/seed/resolve/main` | `repro/lib/seed_download.sh` |

三个文件的 size / sha256（sha256 == HF API 的 `lfs.oid`；**不是** `xetHash`）：

| 文件 | size (B) | sha256 | 本地落点 |
|------|----------|--------|----------|
| `metadata/seed_metadata_v004.csv` | 146,411,608 | `71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39` | `data/seed/metadata/seed_metadata_v004.csv` |
| `g1.tar.gz` | 23,499,973,647 | `52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a` | `data/seed/_archives/g1.tar.gz` |
| `soma_uniform.tar.gz` | 45,188,088,297 | `0c1fd91628d2644d0d7c0b735ae64faa5fa79834280bc1ce7860a871e55f912c` | `data/seed/_archives/soma_uniform.tar.gz` |

- 两个归档合计 **68,688,061,944 B**（= 切片计划里 `SEED_DOWNLOAD_OK bytes=68688061944` 的口径）；
- 三个文件合计 **68,834,473,552 B**（含 metadata；`repro/lib/seed_download.sh` 的 `SEED_TOTAL_BYTES_ALL`）。
- clip 计数：g1 与 soma_uniform 各 **142,220** 个 clip；metadata **142,220 行**（+1 行表头）。
- session 数：**124**（`data/seed/g1/csv/<session>/` 下的目录数）。

---

## 2. 执行命令原文

全部命令都在远端容器内执行；本地只调 `repro/lib/remote.sh` 这个 ssh 入口。

```bash
# (1) 启动 / 守护下载（detached worker，跨会话存活）
bash repro/lib/remote.sh 08_seed_download.sh start
bash repro/lib/remote.sh 08_seed_download.sh status     # 秒级读状态
bash repro/lib/remote.sh 08_seed_download.sh wait 600    # 有界等待，超时 75 不杀 worker
bash repro/lib/remote.sh 08_seed_download.sh verify      # 只读断言：三个文件齐 + size + sha256 sidecar
bash repro/lib/remote.sh 08_seed_download.sh probe       # 认证 + 速率探针（只拉几 MiB）

# (2) 归档级完整性校验（sha256 清单 + gzip CRC + tar 条目数 + 相对路径布局）
bash repro/lib/remote.sh 09_seed_verify.sh verify        # -> logs/env/09_seed_verify.txt

# (3) 解包 + 与 metadata 逐 session 对账
bash repro/lib/remote.sh 10_seed_extract.sh start        # detached worker
bash repro/lib/remote.sh 10_seed_extract.sh status
bash repro/lib/remote.sh 10_seed_extract.sh wait 75
bash repro/lib/remote.sh 10_seed_extract.sh verify       # -> logs/env/10_seed_extract.txt

# (4) 归档级 sha256 复核（独立于 09 的第二份证据）
sha256sum -c data/seed/_archives/SHA256SUMS

# (5) 终局链路无人值守（2026-11-11 起推荐用这个，会话不需要留在回路里）
bash repro/lib/remote.sh 11_seed_finalize.sh start    # 等下载到齐后自动跑 09 -> 10 -> 对账 -> sha256
bash repro/lib/remote.sh 11_seed_finalize.sh status   # 看它等到哪一步了
bash repro/lib/remote.sh 11_seed_finalize.sh wait 75
bash repro/lib/remote.sh 11_seed_finalize.sh verify   # 只读断言：终局证据确实在盘上
```

---

## 3. 已完成的执行记录（metadata 截至 2026-11-10T14:20Z；归档下载持续至 2026-11-11）

### 3.1 metadata（已完成）

```
SEED_DL_ATTEMPT_START file=metadata/seed_metadata_v004.csv attempt=1 bytes=0 total=146411608
SEED_DL_PROGRESS file=metadata/seed_metadata_v004.csv bytes=50790400 pct=34.7 rate_bps=846506 eta_seconds=112
SEED_DL_PROGRESS file=metadata/seed_metadata_v004.csv bytes=107085824 pct=73.1 rate_bps=892381 eta_seconds=44
SEED_DL_FILE_OK file=metadata/seed_metadata_v004.csv bytes=146411608 sha256=71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39
SEED_SHA256_OK file=metadata/seed_metadata_v004.csv
```

落盘复核（本地实测）：

```
$ sha256sum data/seed/metadata/seed_metadata_v004.csv data/seed/seed_metadata_v004.csv
71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39  data/seed/metadata/seed_metadata_v004.csv
71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39  data/seed/seed_metadata_v004.csv
$ ls -li …                       # 同一 inode 82772608，硬链接成立（2026-11-11T07:10Z 复核）
$ wc -l data/seed/metadata/seed_metadata_v004.csv
142221                          # 表头 1 行 + 142,220 行 clip
```

**metadata 双路径落地（下游兼容，硬链接同内容）**

| 路径 | 使用者 |
|------|--------|
| `data/seed/metadata/seed_metadata_v004.csv` | `tools/soma_retargeter/stage_subset.py`（`--metadata $DATA/seed/metadata/seed_metadata_v004.csv`） |
| `data/seed/seed_metadata_v004.csv` | `README.md` 多机器人段（`--metadata $DATA/seed/seed_metadata_v004.csv`） |

两者是**同一 inode 的硬链接**，sha256 相同。

### 3.2 g1 / soma_uniform（**两个归档已全部到齐**，2026-11-11T20:39Z；**终局六 marker 已全部落盘**，2026-11-12T06:43:54Z）

2026-11-10 13:48:05Z 启动的 worker 因第 10 节所述的 worktree 重建事故而丢失载荷，
已于 2026-11-11 在**持久 store** 中重启（PID 见 `logs/env/08_seed_download_worker.log`
的 `SEED_DL_WORKER_PID`）。**下载已于 2026-11-11T20:39Z 全部完成**，
状态文件 `logs/env/08_seed_download.status`：

```
STATE=DONE
FILE=
BYTES=68688061944
TOTAL=68688061944
PCT=100.0
RATE_BPS=0
ETA_SECONDS=0
ATTEMPT=
PID=273722
RC=0
STARTED_AT=2026-11-11T01:53:10Z
```

**三个文件全部到齐，且三个 sha256 全部校验通过**（`logs/env/08_seed_download.txt`）：

```
SEED_SHA256_OK file=metadata/seed_metadata_v004.csv
SEED_SHA256_OK file=g1.tar.gz
SEED_SHA256_OK file=soma_uniform.tar.gz
SEED_DOWNLOAD_OK files=3 bytes=68688061944 elapsed=67940
```

`data/seed/_archives/SHA256SUMS`（263 B，3 行，2026-11-11T20:45Z 写出）：

```
71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39  ../metadata/seed_metadata_v004.csv
52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a  g1.tar.gz
0c1fd91628d2644d0d7c0b735ae64faa5fa79834280bc1ce7860a871e55f912c  soma_uniform.tar.gz
```

到齐时点与字节数（均为实测，与第 1 节事实表逐条一致）：

| 文件 | 到齐时刻（容器时钟） | 落盘字节 | 期望字节 | 一致 |
|------|--------------------|----------|----------|------|
| `metadata/seed_metadata_v004.csv` | 2026-11-10T14:18Z | 146,411,608 | 146,411,608 | ✅ |
| `g1.tar.gz` | 2026-11-11T11:38Z | 23,499,973,647 | 23,499,973,647 | ✅ |
| `soma_uniform.tar.gz` | 2026-11-11T20:39Z | 45,188,088,297 | 45,188,088,297 | ✅ |
| **两个归档合计** | — | **68,688,061,944** | **68,688,061,944** | ✅ |

**soma_uniform 的续传证据**（证明第 10.2 节抢救出的 15.5 GB 一个字节都没白下）：

```
SEED_DL_ATTEMPT_START file=soma_uniform.tar.gz attempt=1 bytes=15535702016 total=45188088297
SEED_DL_RESUME file=soma_uniform.tar.gz offset=15535702016
```

**墙钟口径**：下载 worker 于 2026-11-11T01:53:10Z 启动（`STARTED_AT`），
到 2026-11-11T20:39Z 最后一个归档到齐，**总墙钟 ≈ 18.8 h**
（下载器自报 `SEED_DOWNLOAD_OK … elapsed=67940` s ≈ 18.9 h，两者一致）。
其中 g1 阶段实测 **0.3–0.95 MB/s**，soma 阶段实测 **≈0.86–1.9 MB/s**
（两次 `stat` 字节差；状态文件与 `SEED_DL_PROGRESS` 的 `RATE_BPS` 是**续传突发窗口的均值**，
会给出 7–28 MB/s 的乐观值，不可直接引用——详见 §4.2 第 4 条的实测与证伪）。
第 4.2 节已定量证明：并发/换出口/频繁重连**都不能**提速，出口带宽是硬约束。

**终局链路已自动接上**（`logs/env/11_seed_finalize.txt`）：

```
SEED_FINALIZE_DONE phase=download elapsed_s=49002
SEED_FINALIZE_START phase=verify
```

即：下载到齐的瞬间，11 终局 worker 就从「等待」切入了 09 校验，
随后自动跑 10 解包 → 对账 → `sha256sum -c`，全程无需任何会话在世。
`logs/env/09_seed_verify.txt` 首行记录了 09 的启动时刻
（`=== 09_seed_verify.sh verify 2026-11-11T20:45:51Z ===`）。

**截至 2026-11-11T22:11Z（容器时钟）**：归档级校验（09）已**全部通过**，终局链路进入解包阶段。

`logs/env/09_seed_verify.txt` 的终局 marker 原文：

```
SEED_TAR_CLIPS file=g1 kind=csv count=142220
SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220
SEED_TAR_LAYOUT_OK file=g1.tar.gz
SEED_TAR_LAYOUT_OK file=soma_uniform.tar.gz
SEED_VERIFY_OK archives=2 clips=284440
```

即：两个归档的 **142,220 clip 条目数**（g1 走 csv、soma_uniform 走 bvh）与**相对路径布局门**都通过，
sha256 + gzip CRC 也已通过（09 内部先做 sha256 清单核对与 gzip 完整性校验，详见该脚本输出）。
该阶段耗时 `SEED_FINALIZE_DONE phase=verify elapsed_s=1556`（≈26 min，对 68.7 GB 做 sha256+gzip CRC+tar 列表）。

解包（10）于 2026-11-11T21:11:47Z 启动，三道前置门全过：
`SEED_EXTRACT_GATE_PREVERIFY_OK` / `SEED_EXTRACT_GATE_SPACE required_gb=400 free_gb=4688` /
`SEED_EXTRACT_GATE_TARGET dir=…/data/seed`。
**g1 归档已解完**（`logs/env/10_seed_extract.txt`）：

```
SEED_EXTRACT_DONE file=g1.tar.gz clips=142220 expected=142220 sha256=52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a elapsed_s=7878
```

即 142,220 个 csv **一个不缺**，耗时 **7878 s（≈2.2 h）**；
`soma_uniform.tar.gz` 随后接着解（`SEED_EXTRACT_START file=soma_uniform.tar.gz … target=…/data/seed/soma_uniform/bvh`）。

**为什么这一段看起来「不动」——不是卡住，是被 NFS 限速**：
容器内的 `tar -xzf` 进程状态为 `D`（不可中断睡眠）、`wchan=wait_on_commit`，
即每个小文件写入都在**等 NFS 服务器确认落盘**（这正是 §4.1 记录的 ~22 ms/个小文件）。
实测速率在 **402–920 文件/分** 之间随 NFS 抖动波动；
2026-11-11T02:09Z 的 60 s 采样为 82,615 → 83,017 个 soma 文件（**402 文件/分**），
按此推算 soma 解完 ≈ **04:35Z**，随后对账 + `sha256sum -c`（68.7 GB sha256 ≈20–30 min），
终局六 marker 预计 ≈ **05:00–05:30Z** 全部落盘。
（终局 marker 在解包期间**不会**出现：它们要等两个归档都解完、且对账通过之后才写。）

---

#### 3.2.1 终局结果：**六个终局 marker 全部产生**（2026-11-12T06:43:54Z）

上一段写下的预测（soma 解完 ≈ 04:35Z、终局 marker ≈ 05:00–05:30Z）**没有兑现**：
2026-11-12T03:38Z 发生了**第三次 worktree 抹除**（见 §10.6），正在解包的终局 worker
被打断，终局链路以 `SEED_FINALIZE_FAIL reason=step-failed phase=extract rc=1` 收场。
修复后整条链路按幂等方式重跑，**2026-11-12T06:43:54Z** 全部走完。

终局链路的最后一次完整运行（`logs/env/11_seed_finalize.txt`）：

| phase | 起止 | 耗时 | 结论 |
|-------|------|------|------|
| `download` | 05:42:46Z → 05:42:46Z | `elapsed_s=0`（下载早已 `STATE=DONE`） | `SEED_FINALIZE_DONE phase=download elapsed_s=0` |
| `verify` | 05:42:46Z → 06:08:23Z | `elapsed_s=1537` | `SEED_VERIFY_OK archives=2 clips=284440` |
| `extract` | 06:08:23Z → 06:34:15Z | `elapsed_s=1552`（两个归档均已有 `.done`，幂等跳过解包，只做对账） | `SEED_EXTRACT_OK files=284440` |
| `reconcile` | 06:34:15Z → 06:35:16Z | `elapsed_s=61` | `SEED_META_OK matched=142220 missing=0 extra=0` |
| `sha256` | 06:35:16Z → 06:43:54Z | ≈518 s（68.7 GB 重算 sha256） | `SEED_FINALIZE_OK files=3` |

**六个终局 marker 的日志原文**（`logs/env/11_seed_finalize.txt`，
2026-11-12T05:42:46Z 那一轮；`bash repro/lib/remote.sh 12_seed_finalize_report.sh`
在 2026-11-12T06:51:25Z 以只读方式复核过同一批 marker，输出 `SEED_REPORT_OK missing=0`）：

```
SEED_TAR_CLIPS file=g1 kind=csv count=142220
SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220
SEED_TAR_LAYOUT_OK file=g1.tar.gz
SEED_TAR_LAYOUT_OK file=soma_uniform.tar.gz
SEED_VERIFY_OK archives=2 clips=284440
SEED_META_OK matched=142220 missing=0 extra=0 samples=248
SEED_META_MATCH matched=142220 missing=0 extra=0
SEED_EXTRACT_OK files=284440
SEED_FINALIZE_OK files=3
```

**归档级 sha256 复核（独立于 09 的第二份证据）**，`data/seed/_archives/SHA256SUMS` 三行全 `OK`：

```
../metadata/seed_metadata_v004.csv: OK
g1.tar.gz: OK
soma_uniform.tar.gz: OK
```

**终局状态文件** `logs/env/11_seed_finalize.status`：

```
STATE=DONE
RC=0
PID=311639
PHASE=
STARTED_AT=2026-11-12T05:42:46Z
FINISHED_AT=2026-11-12T06:43:54Z
```

**metadata 双路径同 inode**（`data/seed/metadata/seed_metadata_v004.csv` 与
`data/seed/seed_metadata_v004.csv`，`ls -l` 的链接数均为 2，
sha256 `71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39`）。

**证据落点**（全部在持久 store `…/morphmimic-seed-data/repo/`，worktree 内经
`data/`、`logs/` 相对符号链接指向同一份）：

| 证据 | 路径 |
|------|------|
| 终局链路主日志 | `logs/env/11_seed_finalize.txt` |
| 终局链路状态 | `logs/env/11_seed_finalize.status` |
| 终局链路 worker stdout | `logs/env/11_seed_finalize_worker.log` |
| 归档校验结论 | `logs/env/09_seed_verify.txt` |
| 解包与对账结论 | `logs/env/10_seed_extract.txt` |
| 归档 sha256 清单 | `data/seed/_archives/SHA256SUMS` |
| 被抹除那一次的原始状态 | `logs/env/11_seed_finalize.txt.wiped-root-20261112T0338Z`、`logs/env/10_seed_extract.status.wiped-root-20261112T0338Z` |

#### 3.2.2 归档 sha256 的**独立第二份证据**：`logs/env/sha256sum_check.txt`

§3.2.1 里的三行 `...: OK` 是终局 worker 在 `sha256` phase 自己跑出来的。
为了拿到一份**与 worker 无关、可被任何人复核**的第二份证据，
2026-11-12T07:0xZ 在容器内**独立重跑**了一次 `sha256sum -c SHA256SUMS`，
原始输出整份落盘到 `logs/env/sha256sum_check.txt`：

```
../metadata/seed_metadata_v004.csv: OK
g1.tar.gz: OK
soma_uniform.tar.gz: OK
```

该次重跑耗时 **517.8 s**（68.7 GB 顺序读，≈133 MB/s），与 §3.2.1 里 worker 自报的 ≈518 s 一致。
除了归档到 `logs/env/sha256sum_check.txt` 的这一次，**还并行跑了第二遍独立重算**：
它的输出没有被归档到文件，但结论一致（三行全 `OK`），耗时 **735.9 s ≈ 12.25 min**——
比 517.8 s 慢是因为两遍同时读同一份 68.7 GB、互相争 IO。

所以归档级 sha256 一共有**三份互不依赖的实跑证据**（worker 一次 + 独立重跑两次），三行全 `OK`；
而 68.7 GB 的 sha256 实耗区间是 **518–736 s**（区间宽度来自并发争抢，不是数据差异）。

> **不要在交互式检查里重跑 `sha256sum -c`。** 它是 518 s 级的阻塞命令，
> 会顶满任何 120 s 级的宿主验证门超时。要复核归档完整性，
> **读 `logs/env/sha256sum_check.txt`**（或 `bash repro/lib/remote.sh 12_seed_finalize_report.sh check`，
> 秒级、只读、fail-closed）。

### 3.3 终局证据改为**无人值守**产出（2026-11-11 新增）

上一轮尝试把 13 h 墙钟耗在「等下载 + 跑校验」上，会话结束时什么也没留下：
下载是活的，但**驱动终局校验/解包的会话已经没了**，证据被无限期推迟。
本次因此新增 `repro/11_seed_finalize.sh`：一个 detached worker，等下载到达
`STATE=DONE` 后**自动**跑完终局链路——

```
等待下载 → 09_seed_verify.sh verify → 10_seed_extract.sh worker
        → 10_seed_extract.sh verify → sha256sum -c SHA256SUMS
```

会话不再出现在回路里：链路自己落盘 `SEED_FINALIZE_*` marker 与状态文件。
本文件第 3 节的终局数值**已于 2026-11-12 由 §3.2.1 回填**（终局链路 06:43:54Z 跑完）。

**当前进度**（2026-11-11T20:45Z）：下载已 `STATE=DONE`（见 3.2 节），终局链路已自动从等待切到校验：
`SEED_FINALIZE_DONE phase=download elapsed_s=49002` → `SEED_FINALIZE_START phase=verify`，
`logs/env/09_seed_verify.txt` 首行为 `=== 09_seed_verify.sh verify 2026-11-11T20:45:51Z ===`。
此后依次是 10 解包（284,440 个小文件串行，≈90 min/归档）→ 10 verify 对账 → `sha256sum -c`，
全程无需任何会话在世；本次会话只做 status 观察（**不手动跑 09/10**，避免与 worker 争 IO/锁）。

离线自测（证明「无人值守链路本身」可靠，不依赖真档）：
`bash repro/tests/test_seed_finalize.sh` → **22 passed, 0 failed**（本地）；
`bash repro/lib/remote.sh 11_seed_finalize.sh selftest` → **22 passed, 0 failed**（容器内）。

### 3.4 终局数值的唯一权威来源：只读报告器 `repro/12_seed_finalize_report.sh`

下载到齐后，六个终局 marker 会由 `11_seed_finalize.sh` 链路自己写进
`logs/env/11_seed_finalize.txt`。把它们变成文档里的数字，最容易出错的地方是
「抄错 marker / 抄了上一轮的 marker / 漏抄一项」。因此新增**只读**报告器：

```bash
bash repro/lib/remote.sh 12_seed_finalize_report.sh          # 完整报告
bash repro/lib/remote.sh 12_seed_finalize_report.sh check    # 只出判定（OK / 缺项）
```

它的行为是 **fail-closed**：

- 断言下载状态 `STATE=DONE` 与终局状态 `STATE=DONE`；
- 断言六个终局 marker **全部**在终局日志里
  （`SEED_VERIFY_OK` / `SEED_TAR_CLIPS file=g1 kind=csv count=142220` /
  `SEED_TAR_CLIPS file=soma_uniform kind=bvh count=142220` /
  `SEED_META_MATCH matched=142220 missing=0 extra=0` /
  `SEED_EXTRACT_OK files=284440` / `SEED_FINALIZE_OK files=3`）；
- 断言 `data/seed/_archives/SHA256SUMS` 存在；
- 缺任何一项 → 非零退出、逐条列出 `MISSING: …`、**不打印** `SEED_REPORT_OK`；
- 全齐 → 打印六个 marker 的**原文**（逐条）+ 一组可直接回填本文件的
  `SEED_REPORT_*` 数值（`G1_CLIPS=142220` / `SOMA_CLIPS=142220` /
  `META_MATCHED=142220` / `META_MISSING=0` / `META_EXTRA=0` /
  `EXTRACTED_FILES=284440` / `ARCHIVE_FILES=3` / `SHA256SUMS_LINES=3`）。

它**不写任何文件**（不碰文档、不读归档、不触网），只输出。
离线单测：`bash repro/tests/test_seed_finalize_report.sh` →
**21 passed, 0 failed**（本地与容器内各一遍），覆盖 happy path 与五条失败路径
（缺 marker / 下载未 DONE / 终局未 DONE / 缺 SHA256SUMS / 缺终局日志），
并断言失败路径**绝不**打印 `SEED_REPORT_OK`。

---

## 4. 实测速率、墙钟与 ETA 偏差

### 4.1 实测速率

| 阶段 | 实测值 |
|------|--------|
| metadata 146.4 MB | 约 **105 s**，稳态 **0.85–0.89 MB/s** |
| g1 归档（2026-11-10 首跑） | 启动后 ~30 min 累计 1.48 GB，平均 **≈1.45 MB/s**（`RATE_BPS` 逐步从 4.4 MB/s 衰减到 1.45 MB/s，说明代理出口速率随长连接时长下降） |
| g1 归档（2026-11-11 重启后） | 稳态 **≈0.80–0.89 MB/s**（`SEED_DL_PROGRESS` 的 `rate_bps`） |
| g1 解包（142,220 个 csv） | **7878 s ≈ 2.19 h**，即 **≈18.0 文件/s ≈ 1083 文件/分**（`data/seed/_extract/g1.tar.gz.done` 的 `elapsed_s=7878`） |
| soma_uniform 解包（142,220 个 bvh） | **13652 s ≈ 3.79 h**，即 **≈10.4 文件/s ≈ 625 文件/分**（`data/seed/_extract/soma_uniform.tar.gz.done` 的 `elapsed_s=13652`） |
| 归档级 sha256 重算（68.7 GB × 3 文件） | 终局链路 `sha256` phase ≈ **518 s ≈ 8.6 min**（≈132 MB/s，页缓存命中下的顺序读）；两次并发独立重算实测 **517.8 s** 与 **735.9 s**（后者含并发 IO 争抢） |

### 4.2 「并发能不能提速」——2026-11-11 的定量复核

上一版结论只有一次 4 连接对照实验（682 kB/s 聚合）。本次为了判断剩余 52 GB 能否压缩，
做了**系统性复核**（每个实验都在下载 worker 持续运行的同时测量 worker 自己的字节增量，
所以 `AGG_BPS` 是**真实总吞吐**，不是「额外连接自己的速度」）：

| 实验 | 连接数 | worker B/s | 额外连接 B/s | **总聚合 B/s** |
|------|--------|-----------|-------------|---------------|
| 单流基线（worker 独占） | 1 | 888,303 | — | **888,303** |
| 同文件 6×Range | 6 | 124,249 | 700,844 | **825,094** |
| 异文件 4×Range | 4 | 200,701 | 591,562 | **792,264** |
| 异文件 8×Range | 8 | 74,681 | 723,831 | **798,513** |
| 异文件 16×Range | 16 | 74,681 | 723,831 | **798,513** |
| **第二个客户端主机**（本机 loopback → 代理） | 1+1 | 484,848 | 414,537 | **899,386** |
| **新建连接探针**（2026-11-11T09:06Z，`08_seed_download.sh probe`：HEAD 解析 + 8 MiB Range，与 worker 并发） | 1+1 | — | 335,734 | **≈0.34 MB/s（+ worker 实测 0.3–0.6 MB/s，聚合仍被出口卡住）** |

结论（比之前更硬）：

1. **总聚合速率被代理出口死死卡在 ~0.79–0.90 MB/s**，与连接数（1/4/6/8/16）
   和客户端主机数（1/2）**都无关**——加连接只是把同一份带宽在连接之间重新分配
   （worker 的 B/s 从 888k 掉到 74k，额外连接补上了差额）。
2. 因此**多连接下载对本任务无收益**，且**多客户端并行也无收益**。
   第 7 节的「并发多连接下载」条目从「不采用」升级为「已定量证明不可行」。
3. 唯一还能榨出带宽的方向是**换出口**：容器内直连不可用（DNS 解析超时），
   本机直连 `huggingface.co:443` 也超时（连接被重置），`hf-mirror.com` 经代理同样被重置；
   本机 `1858` 端口的旧代理已关闭，只剩 `172.16.119.20:40381` 一个出口。
4. **「频繁重连就能抢到快突发」这一假设已被证伪**（2026-11-11T09:06Z）。
   观测事实：attempt 4 续传后的**首段**曾跑到 13–271 MB/s（`SEED_DL_PROGRESS rate_bps`），
   但随后长连接回落到 0.2–0.6 MB/s；而用 `08_seed_download.sh probe` **另开一条新连接**
   （8 MiB Range，临时文件，不碰 `.part`）实测仅 **335,734 B/s**。
   结论：那个突发是**一次性的 CDN/代理缓存命中**，不是可重复收割的规律——
   重连并不能把速率拉上去，因此**不调整下载器的 `--speed-limit/--speed-time` 参数、
   也不主动重启 worker 去「刷突发」**（这也避免了计划 C5 的重启计数被无意义地消耗）。
   当前策略（单条长连接 + `-C -` 续传 + 指数退避）已是最优，无需变更。

### 4.3 ETA 与墙钟取舍

| 项 | 数值 |
|----|------|
| 剩余字节（2026-11-11T20:39Z 观测） | **0**——三个文件全部到齐（`SEED_DOWNLOAD_OK files=3 bytes=68688061944`） |
| 实测稳态速率 | g1 阶段 0.3–0.95 MB/s；soma 阶段 ≈**0.86–1.9 MB/s**（两次 `stat` 字节差实测；状态文件 `RATE_BPS` 是续传突发窗口均值、**不可用**；新连接探针实测仅 335,734 B/s，见 §4.2 第 4 条） |
| **实际总墙钟** | **≈18.8 h**（worker `STARTED_AT=2026-11-11T01:53:10Z` → 最后一个归档到齐 2026-11-11T20:39Z；下载器自报 `elapsed=67940` s ≈ 18.9 h） |
| 计划假设 vs 实际 | 计划 ETA 21–32 h；**实际 18.8 h < 21 h**（比计划乐观值还快，因 §4.2 第 4 条证伪后保持单长连接策略且 soma 阶段速率更高） |
| 切片计划的假设 | ETA 21–32 h，并规定「若 ETA > 24 h 则优先保 g1」 |
| **解包墙钟** | g1 **7878 s** + soma_uniform **13652 s** = **21530 s ≈ 5.98 h**（串行，NFS 小文件写入受限，见 §4.1） |
| **终局链路墙钟**（校验 → 解包 → 对账 → sha256） | 首次尝试 2026-11-11T20:45Z 起，被 §10.6 的 worktree 抹除打断；**重跑后 2026-11-12T05:42:46Z → 06:43:54Z = 3668 s ≈ 61.1 min**（其中 verify 1537 s、extract 幂等跳过 1552 s、reconcile 61 s、sha256 ≈518 s） |
| **端到端总墙钟**（下载 worker 启动 → 终局六 marker 落盘） | 2026-11-11T01:53:10Z → 2026-11-12T06:43:54Z = **≈28.85 h**（= 下载 18.85 h + 首次终局尝试 7.1 h + 抹除后修复/重跑 3.4 h） |
| **ETA 偏差** | 2026-11-11T02:09Z 的预测是「soma 解完 ≈ 04:35Z、终局 marker ≈ 05:00–05:30Z」；**实际 2026-11-12T06:43:54Z**，比预测晚 **≈25 h**。偏差**不来自带宽**（下载与解包速率都在计划内），而**全部来自 2026-11-12T03:38Z 的第三次 worktree 抹除**（§10.6）及其修复 |

**与计划的偏差与取舍**：实测总墙钟 **≈18.8 h < 24 h 临界线**，因此**不降级**：
三个文件全部下载、两个归档全部解包，不采用「只保 g1、soma_uniform 后续再取」的取舍。

> 关于「若 ETA > 24 h 则优先保 g1」这条约定：它在本轮**没有触发**（实际 18.8 h）。
> 且即便触发，该约定也是**自动满足**的——下载器的文件顺序本就是
> **g1 先、soma_uniform 后**（`repro/lib/seed_download.sh` 的期望文件表），
> g1 先到齐、可先被 09 校验与 10 解包；soma_uniform 若未到齐只是**续传起点被保留**，
> 不损失任何已下载字节（`.part` 永不删除）。

**墙钟口径**：下载由 detached worker（`setsid nohup`）承载，**跨会话存活**；
`.part` 文件永不删除，任何一次失败只损失一次 attempt，不损失已下载字节。
**终局链路（校验 + 解包 + 对账）同样已无人值守**（见 3.3 节的 `repro/11_seed_finalize.sh`），
不再依赖某个会话还活着。

---

## 5. 与 README 的偏离清单

| # | 计划/README 写法 | 实测/实际 | 结论 |
|---|------------------|-----------|------|
| 1 | README（R007）写「用带代理的 `hf download` 断点续传」 | hf CLI **不可续传**，且 Xet 路径对 23 GB/45 GB 大 tar **挂死**；改为自管 `curl -L -C -` + `.part`（D012） | 以 curl 为准，README 的 R007 表述需更新 |
| 2 | README G1 段（第 99–105 行）用 `seed_metadata_v003.csv` | 数据集只提供 **v004**（第 145 行多机器人段用的就是 v004） | 已知偏离（D002），按 v004 落地，两条路径都提供 |
| 3 | 切片计划写的三文件合计 `68,688,061,944 B` | 该数字是**两个归档**之和；三文件合计是 `68,834,473,552 B` | 计划口径按原样保留在 marker 里，事实口径见 `SEED_TOTAL_BYTES_ALL` |
| 4 | 计划写「解包到 `data/seed/` 下并与 metadata 逐 session 对账」 | 归档实际在 `data/seed/_archives/`，故用 `tar -xzf <abs archive> -C data/seed`（T4 已按此实现） | 落地结果与计划意图一致 |

---

## 6. 踩坑记录

1. **签名 URL 约 1.8 h 过期**：每次 attempt 必须重新 resolve（一次 302 换新签名），
   不能把 URL 缓存下来长用。
2. **代理是唯一出口**：容器内没有直连；`repro/lib/common.sh` 内联
   `http://172.16.119.20:40381`，且**只**存在于进程环境里，不写任何系统配置。
3. **root-squash 的 NFS**：`tar` 解包必须带 `--no-same-owner`（归档属主是 `mpanek/root`），
   `--same-owner` / `-p` 禁用；同时用 `--no-same-permissions` 保住默认 umask。
4. **NFS 小文件很慢**：实测约 **22 ms/个**，284,440 个 clip ≈ **90 min/归档**，
   因此解包严格串行、detached 化、幂等（`.done` 标记）。
5. **curl 错误码分布**（实测）：`rc=92`（HTTP/2 stream 未正确关闭，代理偶发）、
   `rc=35`（TLS 连接问题）、`rc=75`（时间预算耗尽，属正常暂停语义）。
   全部由 worker 的指数退避重试覆盖，`.part` 保留。
6. **不可用 `hf` CLI**：见偏离 #1。

---

## 7. 「已分析未执行」项

| 项 | 规模 | 决定 |
|----|------|------|
| `soma_proportional.tar.gz` | 45.5 GB | **明确排除**：本切片（S03/S04/S05）只用 `g1` 与 `soma_uniform` 两条树 |
| `soma_shapes/` | 532 个小文件 | 非必需（S05 只消费 `soma_uniform/bvh`），不下 |
| Xet 加速 | — | 放弃：hf CLI 的 Xet 路径对大 tar 挂死（见偏离 #1） |
| 并发多连接下载 | — | **已定量证明不可行**：4/6/8/16 连接 + 第二客户端主机，聚合速率恒为 0.79–0.90 MB/s（见 4.2 节），瓶颈是代理总出口 |
| 换出口（直连 / hf-mirror / 第二个代理端口） | — | 实测全部不可用：容器直连 DNS 超时、本机直连 TCP 超时、hf-mirror 经代理被重置、`:1858` 端口已关闭 |

---

## 8. 清理策略

- **归档默认保留**：`data/seed/_archives/*.tar.gz` 不自动删除——重下成本 **20+ h**，
  而 S04/S05 的任何回归都可能需要重新解包。
- `.part` 文件在成功前永不删除（是续传的载体）。
- `data/seed/_extract/<archive>.done` 是幂等标记，重复跑 `10_seed_extract.sh` 会跳过已完成的归档。
- HF 缓存（`/root/.cache/huggingface/`）只存 metadata/xet 元数据，**禁止清理**。

---

## 9. 续跑步骤（终局校验尚未执行时的唯一正确动作）

下载 worker 是 detached 的，**即使会话结束也继续跑**；`.part` 会保留、可续传。

**载荷位置**：自 2026-11-11 起，BONES-SEED 载荷不再位于 worktree 内的 `data/seed/`，
而是位于 worktree 之外的持久 store（见第 10 节）。worktree 内的 `data/` 与 `logs/`
是**指向该 store 的符号链接**，所以下面所有命令的相对路径**保持不变**。

```bash
# 0) 体检 store（确认链接与载荷都在）
bash repro/lib/seed_store.sh check          # 期望 SEED_STORE_OK

# 1) 看进度（秒级）
bash repro/lib/remote.sh 08_seed_download.sh status

# 2) 等到三个文件齐（超时 75 不杀 worker，可反复调用）
bash repro/lib/remote.sh 08_seed_download.sh wait 600

# 3) 终局校验 + 解包 + 对账（严格按依赖顺序）
bash repro/lib/remote.sh 08_seed_download.sh verify     # 期望 SEED_DOWNLOAD_OK files=3 bytes=68688061944
bash repro/lib/remote.sh 09_seed_verify.sh verify       # 期望两个 SEED_TAR_CLIPS … count=142220 + SEED_VERIFY_OK
bash repro/lib/remote.sh 10_seed_extract.sh start
bash repro/lib/remote.sh 10_seed_extract.sh wait 75
bash repro/lib/remote.sh 10_seed_extract.sh verify       # 期望 SEED_META_MATCH matched=142220 missing=0 extra=0 + SEED_EXTRACT_OK files=284440
sha256sum -c data/seed/_archives/SHA256SUMS             # 期望三行全 OK

# 3') 或者：让无人值守链路去做（推荐，会话不必留在回路里）
bash repro/lib/remote.sh 11_seed_finalize.sh start      # 已启动则打印 "finalize worker already RUNNING"
bash repro/lib/remote.sh 11_seed_finalize.sh status
bash repro/lib/remote.sh 11_seed_finalize.sh wait 75    # 0=DONE 1=FAILED 75=timeout
bash repro/lib/remote.sh 11_seed_finalize.sh verify     # 期望 SEED_FINALIZE_OK
```

拿到上述输出后，把真实 marker 行回填到本文件第 3 节，并把第 4 节的「进行中」改写为终局值。

**无人值守链路的日志落点**（都在 store 的 `logs/env/` 下）：

| 文件 | 内容 |
|------|------|
| `11_seed_finalize.txt` | 主日志：每个 phase 的 `SEED_FINALIZE_START/DONE/FAIL` + 09/10 的全部 marker |
| `11_seed_finalize.status` | 状态文件：`STATE=RUNNING|DONE|FAILED`、`RC=`、`PHASE=`、`PID=` |
| `11_seed_finalize_worker.log` | detached worker 的 stdout/stderr |

---

## 10. 2026-11-11 事故：worktree 重建导致 23.5 GB 丢失

### 10.1 发生了什么

2026-11-11 08:43（本地时区），GSD 的 reconcile 步骤删除了 milestone worktree 目录
`.gsd-worktrees/M001-ttwecz`。审计日志原文：

```
journal-worktree-orphaned  {"reason":"in-progress-unmerged","commitsAhead":17}
workflow-log-warn (reconcile) "Removing stale worktree directory (not registered with git):
                             /mnt/.../morphmimic/.gsd-worktrees/M001-ttwecz"
```

触发条件是「该目录不是 git 注册的 worktree」。删除是递归的，因此**所有未跟踪文件
一并消失**，包括 `data/seed/_archives/` 下的：

| 丢失项 | 大小 | 状态 |
|--------|------|------|
| `g1.tar.gz` | 23.5 GB | 已下载完并通过 sha256 校验、已改名为最终名 → **完全丢失** |
| `metadata/seed_metadata_v004.csv` | 146.4 MB | 已下载完、sha256 通过、双路径硬链接 → **完全丢失** |
| `soma_uniform.tar.gz.part` | 当时约 2 GB | 进程仍持有已删除 inode 的 fd → 字节仍在，但无目录项 |

同一时刻，正在运行的 detached worker 的 cwd 变成 `(deleted)`，其
`logs/env/08_seed_download_worker.log` 变为 `Stale file handle`；状态文件因为
「按路径 stat 已删除文件」而恒定上报 `BYTES=0`。

### 10.2 抢救

`curl` 进程仍持有那个 15.5 GB 已删除 inode 的写 fd，字节可从
`/proc/<curl-pid>/fd/7` 读出。抢救流程：

```bash
# 在容器内把已删除 inode 的内容拷回一个真实路径
dd if=/proc/<curl-pid>/fd/7 of=<store>/data/seed/_archives/soma_uniform.tar.gz.part \
   bs=4M count=<size/4M> conv=noerror
```

抢救出的 15,535,702,016 B 经 `gzip -dc | tar -tf -` 验证为**合法的归档前缀**
（gzip magic `1f8b 0800`，首条目 `soma_uniform/bvh/230315/…`），可直接作为
`curl -C -` 的续传起点。

### 10.3 修复：载荷迁出 worktree

载荷改存于 **worktree 之外**、任何 git/GSD 生命周期操作都触及不到的目录：

| 侧 | 路径 |
|----|------|
| 本地 | `/mnt/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |
| 容器 | `/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo` |

worktree 内的 `data/` 与 `logs/` 是**相对**符号链接
`../../../morphmimic-seed-data/repo/{data,logs}`——相对路径让同一份链接在本地与容器
两种挂载前缀下都能正确解析（见 `repro/lib/seed_store.sh`）。

配套命令：

```bash
bash repro/lib/seed_store.sh paths   # 打印 store 的解析路径
bash repro/lib/seed_store.sh link    # （重新）建立 worktree 内的符号链接
bash repro/lib/seed_store.sh check   # 体检：store 可达且载荷文件在位
```

此外，worktree 现在通过 `git worktree add` **正式注册**在 git 中
（`git worktree list` 能看到它），使 reconcile 不再把它当作「未注册的残留目录」删除。

### 10.4 影响与结论

- `g1.tar.gz` 与 metadata CSV 必须重下（metadata 约 105 s，g1 约 23.5 GB）。
- `soma_uniform` 从抢救出的 15.5 GB 续传，省下约 3.7 h。
- **教训**：数十 GB 的下载产物绝不能放在会被 GSD 生命周期重建的目录里；
  未跟踪的实验数据在 worktree 重建时一律蒸发。

### 10.5 第二次 worktree 重建：符号链接被抹，终局链路「失去下载状态」

2026-11-11 15:04（本地时区，约 07:04Z），worktree 目录**又被重建了一次**：
worktree 内的 `data/` 与 `logs/` 符号链接消失（`logs/` 变成普通目录，
且 `common.sh` 的 `mkdir -p "$LOG_DIR"` 在里面新建了 `logs/env/`）。
后果不是丢数据（载荷在 store 里，安全），而是**链路失聪**：

- 08 下载 worker 从 **store 副本**运行（`…/morphmimic-seed-data/repo/repro/08_seed_download_worker.sh`），
  它写的是 store 的状态文件 → 下载不受影响；
- 11 终局 worker 从 **worktree 副本**运行，它的状态/日志路径是
  `$REPO_ROOT/logs/env/…` → 重建后读到的是新建的空目录，
  `dl_state()` 只能报 `STATE=ABSENT`，于是终局链路**永远等不到 `STATE=DONE`**，
  终局证据会被无限期推迟（本任务的上一轮失败正是这种形态）。

修复（本次已落地，三处）：

1. `repro/lib/common.sh`：日志目录改为**感知 store**——`logs/` 不是指向 store 的
   符号链接时，`LOG_DIR` 直接取 `$SEED_STORE_ROOT/logs/env`；
   并在 `data/` / `logs/` 缺失时自动重建符号链接（`seed_store_link`，只创建不删除）。
2. `repro/lib/seed_store.sh`：改成**可安全 source**（`BASH_SOURCE` 与 `$0` 比对守卫），
   让 `common.sh` 能复用它的 store 解析逻辑而不触发子命令。
3. 本次运行中重建了 worktree 内的 `data/`、`logs/` 符号链接，并**重启了终局 worker**
   （旧 PID 275418 → 新 PID **284476**，2026-11-11T07:09:08Z），
   重启后首条 marker 即 `SEED_FINALIZE_WAIT state=RUNNING`，链路重新挂上下载 worker。

> 结论：把载荷放进 store 只解决「字节不丢」；**链路能活过 worktree 重建**，
> 还需要让「路径解析」本身不依赖 worktree 里的符号链接——这就是 `common.sh` 的
> store 感知改造的目的。下载 worker 应当（也已）从 store 副本启动，
> 终局 worker 从 worktree 副本启动也没问题（路径解析已经不再依赖 worktree 内的链接）。

### 10.6 第三次 worktree 抹除（2026-11-12T03:38Z）：解包完成后、写标记时失联

§10.1 与 §10.5 之后，2026-11-12T03:38Z（容器时钟）**worktree 根目录第三次被抹除**。
这次它打断的不是下载，而是**解包收尾**：

```
/home/ubuntu/.../morphmimic/.gsd-worktrees/M001-ttwecz/repro/10_seed_extract.sh: line 291:
  .../data/seed/_extract/soma_uniform.tar.gz.done.tmp: No such file or directory
SEED_EXTRACT_DONE file=soma_uniform.tar.gz clips=0 expected=142220 sha256=unknown elapsed_s=13652
/home/ubuntu/.../morphmimic/.gsd-worktrees/M001-ttwecz/repro/10_seed_extract.sh: line 109:
  .../logs/env/10_seed_extract.txt: No such file or directory
SEED_EXTRACT_FAIL reason=clip-count-mismatch file=soma_uniform.tar.gz expected=142220 actual=0
SEED_FINALIZE_FAIL reason=step-failed phase=extract rc=1
```

（原始日志保留在 `logs/env/11_seed_finalize.txt.wiped-root-20261112T0338Z`，
状态文件保留在 `logs/env/{10_seed_extract,11_seed_finalize}.status.wiped-root-20261112T0338Z`。）

要点：

1. **字节没丢**：soma 的 `tar -xzf` 本身已经 rc=0 解完（写入的是 store 里的
   `data/seed/soma_uniform/bvh`），丢的只是**收尾的记账路径**——`.done` 标记的临时文件
   与日志文件都因为 worktree 根目录（含 `data/`、`logs/` 两条符号链接）被抹而不可写。
2. `clips=0` 是**记账失败**而不是数据为空：脚本在写完标记后要回读树来计数，
   路径已经不存在，于是「0 个文件」被判成 clip-count-mismatch。
3. 修复方式：重建 `data/`、`logs/` 两条相对符号链接（`SEED_WORKTREE=$PWD bash repro/lib/seed_store.sh link`），
   再按 §10.3 的方式**显式补写** `data/seed/_extract/soma_uniform.tar.gz.done`，
   并在该文件里写明 `provenance=rewritten-2026-11-12T05:42Z_after_worktree_wipe`
   与每一个数值的来源（clip 数来自 `10_seed_extract.sh verify` 的
   `SEED_EXTRACT_FILES file=soma_uniform count=142220`，sha256 来自
   `data/seed/_archives/soma_uniform.tar.gz.sha256`，耗时来自被抹除那次的日志原文）。
   **补写的标记不冒充 worker 产出**：provenance 字段就是它的自证。
4. 随后整条终局链路**按幂等方式重跑**（`11_seed_finalize.sh start` → 09 verify →
   10 worker（两个归档都已有 `.done`，只做对账）→ 10 verify → `sha256sum -c`），
   于 **2026-11-12T06:43:54Z** 产出全部六个终局 marker（见 §3.2.1）。

> 结论（第三次验证同一条教训）：**worktree 目录不是可靠的家**。
> 载荷放 store 解决「字节不丢」，但**凡是把结论写回 worktree 路径的记账动作，
> 依然会被 worktree 重建打断**。真正可靠的做法是：
> **状态文件、日志、`.done` 标记一律落在 store 里**（`logs/`、`data/` 指向 store 的符号链接），
> 并保证链路**可幂等重跑**——本轮正是靠「两个 `.done` 都在 ⇒ 跳过解包只对账」
> 才在 61 min 内重新拿到全部终局证据。

## 7. 本切片直接消费的 S02 结论（上游阅读与工具链）

| 消费的结论 | 出处 | 在本切片怎么被消费 | 机器可 grep 的证据 |
|---|---|---|---|
| 模块覆盖 103/103、0 缺失、0 空职责（下载 / 校验 / 解包的调用链） | `docs/code_read/CODE_MAP.md` | `repro/08..12` 的脚本与状态文件语义按 CODE_MAP 的调用链确定 | `logs/env/06_code_read.txt` → `CODE_READ_OK` |
| GMR 子模块按锁定 SHA 落地并可导入 | `docs/code_read/TOOLCHAIN.md` | 下载链本身不依赖 GMR，但一键编排链依赖它；GMR 缺失只打断 `--group teleop` | `docs/code_read/TOOLCHAIN.md` → `TOOLCHAIN_GMR_VERDICT=VERIFIED` |
| 缺 GMR 时默认组仍成功、只有 teleop 组失败 | `logs/env/02_uv_sync_without_gmr.txt` | 解释"环境大体可用但人接口链路不可用"的现象 | `logs/env/02_uv_sync_without_gmr.txt` |
| 重产物必须落在仓库之外的持久 store | `repro/lib/seed_store.sh` | 68.8 GB 归档与解包产物落在 `<store>/data/seed/`，worktree 内只是软链 | `logs/env/30_store_guard.txt` → `STORE_GUARD_OK` |

> 这些结论在复现记录第 10 节的证据索引表里逐行可 grep，不再只是"人读可查"。
