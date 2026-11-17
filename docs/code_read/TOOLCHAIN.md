# 四条外部工具链的可用性结论（GMR / soma-retargeter / XRoboToolkit / Unitree SDK）

> 切片：**S02 / T3**（`docs/code_read/CODE_MAP.md` 第 ④ 节「外部依赖」的权威来源）
> 探针脚本：`repro/07_toolchain.sh`（`probe` / `verify`）　纯函数库：`repro/lib/toolchain.sh`
> 离线单测：`repro/tests/test_toolchain.sh`
> 运行日志：`logs/env/07_toolchain.txt`（容器内 `ros_dev` 产出）

---

## ① 这份文档解决什么问题

R002 要求「`tools/soma_retargeter/` 周边工具链可安装可用」，但**不允许**「既没验、也没写原因」。
因此每个工具链在探针里都会产出一组固定三行（`<NAME>` ∈ `GMR` / `SOMA` / `XRT` / `UNITREE`）：

```
TOOLCHAIN_<NAME>_VERDICT=VERIFIED|SKIPPED
TOOLCHAIN_<NAME>_REASON=<非空说明>
TOOLCHAIN_<NAME>_EVIDENCE=<日志 / 产物路径或命令>
```

- `VERIFIED` = 真的动手跑过，`REASON` 写「验了什么」；
- `SKIPPED` = 没跑成，`REASON` 写「为什么」（版本、权限、网络、硬件……），原始报错摘要也一并记下；
- `REASON` 或 `EVIDENCE` 为空 = 契约违约，`repro/lib/toolchain.sh` 的 `tc_emit_verdict` 会直接拒绝输出。

**三行同时出现在**运行日志 `logs/env/07_toolchain.txt` **与本文件**里；
`bash repro/07_toolchain.sh verify` 会交叉断言两者完全一致（verdict / reason / evidence 逐字段比对），
不一致即退出非零。文档里下面的代码块就是从日志里逐字拷贝的，**不要手改**。

---

## ② 结论一览

| 工具链 | 上游 | 锁定版本 | 结论 | 依据 |
|---|---|---|---|---|
| GMR | `YanjieZe/GMR`（子模块 `third_party/GMR`） | `25f56db` | 见下方三行块 | 子模块 SHA + 项目 venv 内 `import general_motion_retargeting` |
| soma-retargeter | `NVIDIA/soma-retargeter` | `cbdb2b4` | 见下方三行块 | 克隆 + 独立 Python ≥ 3.12 venv + `import soma_retargeter` |
| XRoboToolkit | `XR-Robotics/XRoboToolkit-PC-Service-Pybind` | `8941e1d`（= `deploy/install_pico.sh` 的 `XRT_REF`） | 见下方三行块 | scikit-build-core 构建 cp310-abi3 wheel + `import xrobotoolkit_sdk` |
| Unitree SDK | `third_party/unitree_sdk2_wrapper`（子模块） | `6264cc1` | 见下方三行块 | SDK 资产核验 + pybind11 绑定构建 + `import unitree_interface` |

---

## ③ 机器可 grep 的结论块

<!-- TOOLCHAIN_VERDICT_BLOCK_START -->
TOOLCHAIN_GMR_VERDICT=VERIFIED
TOOLCHAIN_GMR_REASON=third_party/GMR 落在锁定的提交 25f56db79ac411258b377b6d4ccba0c8ff3372ac，且项目 venv 可导入 general_motion_retargeting（S01 的 teleop 组未退化）
TOOLCHAIN_GMR_EVIDENCE=logs/env/07_toolchain.txt; third_party/GMR@25f56db79ac411258b377b6d4ccba0c8ff3372ac; GMR_IMPORT_OK third_party/GMR/general_motion_retargeting/__init__.py
TOOLCHAIN_SOMA_VERDICT=VERIFIED
TOOLCHAIN_SOMA_REASON=NVIDIA/soma-retargeter@cbdb2b494a2af82137bf9b6f15122d60167281c4 已克隆并钉住该提交，依赖装进独立 Python>=3.12 venv（logs/toolchain/venvs/soma，未污染项目 venv），soma_retargeter 可导入并能列出机器人目标，项目侧 stage_subset/assemble_robots/validate_csv 三个脚本 --help 全部退出 0
TOOLCHAIN_SOMA_EVIDENCE=logs/env/07_toolchain.txt; logs/toolchain/src/soma-retargeter@cbdb2b494a2af82137bf9b6f15122d60167281c4; SOMA_IMPORT_OK logs/toolchain/src/soma-retargeter/soma_retargeter/__init__.py; SOMA_TARGETS 未公开; logs/toolchain/diag/soma_import.log
TOOLCHAIN_XRT_VERDICT=VERIFIED
TOOLCHAIN_XRT_REASON=XRoboToolkit-PC-Service-Pybind@8941e1dbbf4313fe83846f82984eaa8c992690bf 已克隆并钉住该提交，用 scikit-build-core 构建出 xrobotoolkit_sdk-1.1.0-cp310-abi3-linux_x86_64.whl（cp310-abi3），装进隔离 venv logs/toolchain/venvs/xrt 后 xrobotoolkit_sdk 可导入；未装进项目 venv（普通 uv sync 会把它当锁文件外的包删掉）
TOOLCHAIN_XRT_EVIDENCE=logs/env/07_toolchain.txt; logs/toolchain/src/XRoboToolkit-PC-Service-Pybind@8941e1dbbf4313fe83846f82984eaa8c992690bf; XRT_IMPORT_OK logs/toolchain/venvs/xrt/lib/python3.11/site-packages/xrobotoolkit_sdk/__init__.py; logs/toolchain/diag/xrt_build.log
TOOLCHAIN_UNITREE_VERDICT=VERIFIED
TOOLCHAIN_UNITREE_REASON=third_party/unitree_sdk2_wrapper@6264cc1efd9e72d3c7fffa38a360aea9e43838f3 的 SDK 资产齐全，pybind11 绑定在 logs/toolchain/build 的副本里以 uid 1000 构建成功（unitree_interface.cpython-311-x86_64-linux-gnu.so），在 Python 3.11 下可导入；真机通信回环需要 G1 硬件，属 S08 部署验证范围
TOOLCHAIN_UNITREE_EVIDENCE=logs/env/07_toolchain.txt; logs/toolchain/build/unitree_sdk2_wrapper/python_binding/build/lib/unitree_interface.cpython-311-x86_64-linux-gnu.so; UNITREE_IMPORT_OK logs/toolchain/build/unitree_sdk2_wrapper/python_binding/build/lib/unitree_interface.cpython-311-x86_64-linux-gnu.so; logs/toolchain/diag/unitree_build.log
<!-- TOOLCHAIN_VERDICT_BLOCK_END -->

### 探针落点与当前状态（必读）

- **落点**：探针产物（三个克隆仓库、两个隔离 venv、pybind11 构建树、诊断日志）写在**持久 store** 的
  `logs/toolchain/**` 下（`repro/lib/toolchain.sh` 的 `TC_ROOT=${SEED_STORE_ROOT:-$REPO_ROOT}/logs/toolchain`），
  不再写进 worktree；`repro/07_toolchain.sh probe` 开跑前做 store 守卫
  （`store_guard logs` 不通过即 `TOOLCHAIN_FAIL reason=store-not-linked`）。
- **结论块里的路径一律是 store 相对路径**（`logs/toolchain/...`）或仓库相对路径（`third_party/GMR/...`），
  因此宿主与容器（同一 NFS、不同挂载前缀）跑出来的结论块逐字相同，`verify` 的逐字段比对才能成立。
- **当前状态：一手探针日志已缺失。** `logs/env/07_toolchain.txt` 与 `logs/toolchain/**` 在 2026-11-11 的
  worktree 重建中丢失（当时探针产物写在 worktree 的普通 `logs/` 目录里）。重跑 `probe` 需要外网克隆三个仓库
  并构建 XRT wheel；在此之前 `bash repro/07_toolchain.sh verify` 返回
  `TOOLCHAIN_VERIFY_FAIL reason=probe-log-missing`（退出码 1）。
  上面 ③ 的结论块是**当时实跑产出的结论**，保留在仓库里并被复现记录第 10 节引用，
  但它**不是**当前可一键复算的一手日志——这一点不得含糊。

<!-- TOOLCHAIN_PROBE_LOG_MISSING 一手探针日志已于 2026-11-11 随 worktree 重建丢失；结论块保留，verify 当前报 reason=probe-log-missing -->

---

## ④ 逐条说明

### 4.1 GMR（基线）

- **验了什么**：子模块 `third_party/GMR` 是否落在仓库锁定的提交上；S01 用
  `uv sync --frozen --group export --group teleop` 装好的项目 venv 里，
  `import general_motion_retargeting` 是否仍然可用（teleop 组没有退化）。
- **为什么它重要**：GMR 是 PICO teleop 链路（`deploy/vr_teleop/gmr_retarget.py` →
  `gmr_streamer.py`）的依赖，也是 S01 基线的对照组。
- **已知噪声**：`general_motion_retargeting/__init__.py` 在找不到 `xrobotoolkit_sdk` 时会打印一句
  「xrobotoolkit_sdk not found, skip for now」——那是 XRoboToolkit 尚未装进**项目 venv** 的正常提示，
  不是 GMR 不可用；探针只把 `GMR_IMPORT_OK` 那一行当作证据。

### 4.2 soma-retargeter

- **验了什么**：按锁定提交克隆 `NVIDIA/soma-retargeter`；把它的依赖装进**独立 venv**
  （`requires-python >= 3.12`，而项目 venv 是 3.11.16，所以绝不能装进项目 venv）；
  `import soma_retargeter` 并列出机器人目标；再确认项目侧 `tools/soma_retargeter/` 的
  `stage_subset.py` / `assemble_robots.py` / `validate_csv.py` 三个脚本可执行（`--help` 退出 0）。
- **容器内的硬约束**（探针已按此设计）：
  - 网络只走代理内联（`repro/lib/common.sh`），直连 pypi.org 会出现 `SSL unexpected eof`；
  - 克隆必须走 `git_in`（以目录属主 uid 用 `setpriv` 运行），否则 NFS root-squash 下必然
    `fatal: detected dubious ownership`；
  - git index 必须放在容器本地盘（`GIT_INDEX_FILE`）：NFS 上写 index 会
    `fatal: unable to write new index file`（clone 成功但 checkout 失败）；
  - LFS 资产（示例 BVH / 机器人网格）在工具链可用性验证里**不需要**
    （`GIT_LFS_SKIP_SMUDGE=1`），批量重定向属后续切片；
  - 依赖很重：`newton==1.3.0`、`usd-core==26.3`、`imgui-bundle==1.92.4`、`pyglet==2.1.13`、
    `numpy==2.4.3`、`scipy==1.17.1`，代理下单请求约 12 s → 安装是**分钟级**，且探针带超时，
    超时会如实降级为 `SKIPPED` 并写明超时。

### 4.3 XRoboToolkit

- **验了什么**：按 `8941e1d`（= `deploy/install_pico.sh` 的 `XRT_REF`）克隆；
  用 **scikit-build-core**（不是 pybind11）构建 wheel；装进**隔离 venv** 后 `import xrobotoolkit_sdk`。
- **容器内的硬约束**：
  - 镜像里的系统 cmake 只有 **3.22.1 < 3.26**，必须让 scikit-build-core 自己从 PyPI 拉 cmake；
  - 产物是 **cp310-abi3** wheel（Python 3.10+ 通用），装进 3.11 venv 也能导入；
  - `vendor/linux_x86_64/libPXREARobotSDK.so` 是真实的 23 MB 文件（不是 LFS 指针），容器有 git-lfs 3.7.0；
  - **不要照抄 `deploy/install_pico.sh` 的 git 调用**：它用裸 `git -C`，容器里必然 dubious ownership；
    探针复刻了它的步骤但改用 `git_in`；
  - 探针把 wheel 装进**隔离 venv**（`logs/toolchain/venvs/xrt`），**不装进项目 venv**：
    普通 `uv sync`（不带 `--inexact`）会把锁文件外的 `xrobotoolkit_sdk` 当成多余包删掉；
    真要装进项目 venv，必须用 `uv sync --group teleop --inexact` 保住它。

### 4.4 Unitree SDK

- **验了什么**：`third_party/unitree_sdk2_wrapper` 是否在锁定提交 `6264cc1` 上、工作树干净；
  SDK 资产（`lib/x86_64/libunitree_sdk2.a`、`include/unitree/`、`python_binding/*.cpp`）是否齐全；
  pybind11 绑定能否构建并 `import unitree_interface`。
- **容器内的硬约束**（探针已按此设计）：
  - `python_binding/build.sh` **拒绝以 root 运行**（`EUID -eq 0` → exit 1），而且它会在子模块目录里
    建 `build/` **弄脏工作树**（S01 的 `verify_submodule` 拒绝脏工作树）
    → 探针先把 wrapper 复制到 `logs/toolchain/build/` 再在副本里构建；
  - uv 托管的解释器在 `/root/.local/share/uv/python/` 下，而 `/root` 是 **700**：
    uid 1000 读不到 → 探针先把 3.11 解释器**复制**到 `logs/toolchain/python/` 再建构建 venv；
  - 系统 `pybind11-dev` 是 2.9.1（不支持 Python 3.11），要用 venv 里 pip 装的 pybind11，
    并通过 `CMAKE_PREFIX_PATH` 指给 CMake；
  - apt 依赖（`build-essential cmake python3-dev pybind11-dev libspdlog-dev libboost-all-dev
    libyaml-cpp-dev libfmt-dev`）在镜像里已就绪，`sudo -n true` 可用。

---

## ⑤ 对本复现任务的影响

| 工具链 | 影响 |
|---|---|
| GMR | 基线可用，S01 的 teleop 组未退化；PICO teleop 相关切片（S06/S08）可直接依赖它 |
| soma-retargeter | x2/t2 的 BVH→机器人 CSV 重定向按 R017 延后；若结论是 `SKIPPED`，则 T2/T3 的重定向链路必须显式标注「工具链未验」 |
| XRoboToolkit | PICO PC Service 的 Python 绑定；若为 `VERIFIED`，`deploy/install_pico.sh` 只需把裸 `git` 换成 `git_in` 即可在容器内复现；若为 `SKIPPED`，PICO 相关切片需先补这一步 |
| Unitree SDK | 真机节点（`deploy/hardware/node.py`、`g1_node.py`）的绑定；**真机通信回环需要 G1 硬件，属 S08 部署验证范围**，本次不验 |

---

## ⑥ 怎么复跑

```bash
# 容器内跑真实探针（克隆 / 建 venv / 构建，分钟级，依赖外网）
bash repro/lib/remote.sh 07_toolchain.sh probe
#   -> 日志 logs/env/07_toolchain.txt，尾部 TOOLCHAIN_OK

# 交叉断言：日志与本文档的 verdict / reason / evidence 必须一致（不触网、不构建）
bash repro/lib/remote.sh 07_toolchain.sh verify
#   -> TOOLCHAIN_VERIFY_OK

# 离线单测（verdict 契约本身）
bash repro/tests/test_toolchain.sh
#   -> TESTS_OK
```

**为什么 `07_toolchain.sh` 不进 `repro/00_env.sh` 的一键编排**：它要触网、克隆三方仓库、
从 PyPI 拉 cmake、编译 pybind11 绑定，是十分钟级且强依赖外网的长链路；混进编排会把
「一键跑绿」变成脆弱链路。所以它独立运行，结论落在本文件 + `logs/env/07_toolchain.txt`，
由 `verify` 子命令守住一致性。

---

## ⑦ 与 `docs/code_read/CODE_MAP.md` 第 ④ 节的关系

`CODE_MAP.md` 的「④ 外部依赖」小节是同一批结论在「代码地图」视角下的摘要；
两处不一致时**以本文件为准**，并回头修正 `CODE_MAP.md`。

---

## ⑧ 交接事项（S08 / S09）

1. S08 真机部署：`unitree_interface` 的 `.so` 目前构建在 `logs/toolchain/build/` 的副本里，
   **没有**装进项目 `.venv`；真机部署前需要把 cp311 的 `.so` 放进 `.venv` 的 site-packages
   （并在每次 `uv sync` 后重放）。
2. S08 PICO：`xrobotoolkit_sdk` 只在隔离 venv 里验过；进项目 venv 必须用
   `uv sync --group teleop --inexact`，否则会被 `uv sync` 摘掉。
3. S09《MorphMimic完整复现记录.md》：工具链状态以本文件的四组 verdict 为准，
   并引用 `logs/env/07_toolchain.txt` 作为原始证据。
4. 若要把 `07_toolchain.sh` 纳入一键编排，需要给 `repro/00_env.sh` 增加一个 `mode=toolchain`
   的 step（沿用 `03_uv_sync.sh` 的 start/status/wait/verify 协议），并把编排器的超时预算调大。
