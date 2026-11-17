# CODE_MAP — MorphMimic 工程阅读记录

> 本文件是 R005（完整通读工程并留下「每个模块的职责 / 关键调用链 / 入口命令 / 与本复现任务的关系」记录）
> 的落地产物，也是 S09《MorphMimic 完整复现记录.md》「代码地图」章节的原料。
>
> **这份记录不是散文**：它有一个可重跑的覆盖率门禁
> `repro/06_code_read.sh`（日志 `logs/env/06_code_read.txt`，标记 `CODE_READ_OK`），
> 任何缺条目、缺职责的行都会让门禁非零退出。单测：`repro/tests/test_coderead.sh`。
>
> 记录时间：2026-11-10（分支 M001-ttwecz，切片 S02/T2）。
> 覆盖集：**103 个模块**（README.md 1 + `src/morphmimic` 53 + `deploy` 41 + `tools/soma_retargeter` 顶层 8）。

---

## ① 仓库总览

### 1.1 这是什么

MorphMimic 是「让一个机器人模仿人类动作」的完整栈：把 SEED 格式的人类/机器人动作数据转成 50 Hz 的
npz 参考运动 → 在 mjlab 里训练一个**跨机器人共享**的跟踪策略（canonical 29 关节 + 14 被跟踪刚体）→
把策略导出成 ONNX → 在仿真（sim2sim）或真机（Unitree G1 / Booster T2 / AgiBot X2 Ultra）上以 50 Hz 闭环执行，
并支持 PICO VR 遥操作做人机接口。

策略本体是 SuperMimic 风格的「世界模型 + 想象式策略改进」：环境里收集转移，训练一个学习到的世界模型
（残差动力学 + 解析奖励头），再用冻结的世界模型做 H 步想象 rollout 来改进策略（Algorithm A.1）。

### 1.2 目录树（只画有行为的一层）

```
morphmimic/
├── README.md                     # 仓库总说明（安装 / 数据 / 训练 / 评测 / 部署）
├── pyproject.toml, uv.lock       # 依赖与 workspace（GMR 作为 editable workspace member）
├── src/morphmimic/               # 训练包（可安装，import morphmimic.*）
│   ├── constants.py              #   canonical 布局常量（关节名 / body 名 / 维度）
│   ├── data/                     #   数据转换与数据集（SEED CSV → npz、manifest、motion library）
│   ├── env/                      #   mjlab 环境（观测 / 动作 / 命令 / 终止 / cfg）
│   ├── model/                    #   网络与世界模型（policy / world model / human goal / 解析头）
│   ├── robots/                   #   机器人 spec 与原生→canonical 关节翻译器
│   ├── train/                    #   训练循环（collector / replay / imagination / trainer）
│   ├── eval/                     #   评测（benchmark / drift / policy loader / kp trace）
│   └── scripts/                  #   命令行入口（train / eval / play / render / convert_*）
├── deploy/                       # 部署栈（numpy + onnxruntime，不依赖 mjlab/torch）
│   ├── run.py                    #   一条命令起 sim2sim 或真机
│   ├── export_onnx.py, export_ckpt.py
│   ├── sim2sim/                  #   ZMQ 协议 + 仿真机器人 + 策略节点 + 遥操作参考
│   ├── hardware/                 #   真机节点（G1 / 通用）、按键、位姿来源
│   ├── vr_teleop/                #   PICO 头显 → GMR → 参考帧的遥操作链路
│   ├── onboard/                  #   机器人自带电脑上的部署（容器 / 脚本 / 自检）
│   └── tools/                    #   GMR 会话/算子工具
├── tools/soma_retargeter/        # SOMA 重定向器周边（分片 / 校验 / 机器人装配）
├── third_party/                  # 子模块：GMR、unitree_sdk2_wrapper
└── repro/                        # 本复现任务的可重跑脚本集（S01/S02 产物）
```

### 1.3 与切片 S01–S09 的映射

| 切片 | 做什么 | 主要涉及模块 |
|---|---|---|
| S01 | 远端容器环境就绪（快照 / 子模块 / uv sync / 冒烟 / 代理卫生） | `repro/**`、`third_party/**` |
| S02 | 工程通读基线、可重跑脚本集与工具链可用性验证 | 本文件、`repro/lib/coderead.sh`、`repro/06_code_read.sh` |
| S03 | BONES-SEED 获取与完整性校验 | `src/morphmimic/data/manifest.py`、`scripts/convert_seed.py`（元数据列） |
| S04 | G1 50 Hz npz 转换与子集构建 | `data/seed_convert.py`、`data/filters.py`、`data/manifest.py`、`scripts/convert_seed.py`、`scripts/build_subsets.py`、`robots/**` |
| S05 | human50 sidecar 生成与一致性校验 | `data/human_convert.py`、`data/bvh.py`、`scripts/convert_human.py`、`scripts/check_human.py`、`model/human.py` |
| S06 | g1_amber 训练与资源边界控制 | `env/**`、`model/**`、`train/**`、`scripts/train.py`、`robots/**` |
| S07 | ONNX 导出与 PyTorch parity 校验 | `scripts/train.py`、`model/policy.py`、`deploy/export_onnx.py`、`deploy/export_ckpt.py`、`eval/policy_loader.py` |
| S08 | 部署验证：仿真回放、评测、官方对照、人接口回放 | `deploy/**`、`eval/**`、`scripts/eval.py`、`scripts/drift.py`、`scripts/play.py`、`scripts/render.py` |
| S09 | 完整复现记录收口 | 本文件 + `docs/code_read/TOOLCHAIN.md` →《MorphMimic 完整复现记录.md》 |

---

## ② 模块清单（103 个模块，逐条覆盖）

列含义：**职责**（取自模块自身 docstring / 首部注释）、**关键调用链**（本模块参与的上下游）、
**入口命令**（可直接敲的命令；纯库模块写「—（库模块）」）、**与本复现任务的关系**、
**归属切片**（本复现任务里谁会真正用到它）。

<!-- CODE_READ_MODULE_TABLE_START -->

| 路径 | 职责 | 关键调用链 | 入口命令 | 与本复现任务的关系 | 归属切片 |
|---|---|---|---|---|---|
| `README.md` | 仓库总说明：目录结构、安装、数据获取、训练、评测、机器人模型、部署、与 SuperMimic 的差异 | —（文档总入口，其余模块均在此被提及） | —（文档） | 全仓库的唯一人读入口；S03–S08 的操作步骤都以它为基准 | S02–S09 |
| `src/morphmimic/constants.py` | 机器人 / 观测 / 世界模型的布局常量：canonical 关节名、被跟踪 body 名、HUMAN_JOINTS、各维度 | 被 `env/*`、`model/*`、`train/*`、`robots/*` 共同引用 | —（库模块） | 定义一切布局，S04 的关节顺序、S06 的观测维度都依赖它 | S04, S06 |
| `src/morphmimic/data/bvh.py` | BVH 读取器：解析层级并做通道前向运动学，同时给出世界朝向 | `data/human_convert.py` → `data/bvh.py`；`deploy/vr_teleop/fit_gmr_configs.py` 另有副本 | —（库模块） | SOMA BVH → human50 sidecar 的解析底座 | S05 |
| `src/morphmimic/data/filters.py` | clip 过滤器（App. E）：名称关键字 + 运动学可行性；拒绝时返回原因字符串 | `data/seed_convert.py` → `data/filters.py` | —（库模块） | S04 转换阶段的 clip 准入判断 | S04 |
| `src/morphmimic/data/human_convert.py` | SOMA BVH → 24 个 SMPL 槽位的 50 Hz human sidecar（pos/quat/joint names/fps） | `scripts/convert_human.py` → `data/human_convert.py` → `data/bvh.py`；被 `model/human.py`、`train/trainer.py` 读 | `uv run python -m morphmimic.scripts.convert_human --npz-root ... --bvh-root ...` | S05 sidecar 生成与 `scripts/check_human.py` 校验的底座 | S05 |
| `src/morphmimic/data/manifest.py` | 转换清单与数据集子集：manifest.csv 的列定义、读取与子集 yaml 的生成/校验 | `scripts/convert_seed.py` → `data/manifest.py` → `scripts/build_subsets.py`；被 `eval/benchmark.py`、`train/trainer.py` 读 | `uv run python -m morphmimic.scripts.build_subsets --manifest ... --out-dir ...` | S03 完整性校验、S04 子集构建、训练/评测的数据入口 | S03, S04, S06, S08 |
| `src/morphmimic/data/motion_library.py` | 多 clip 参考运动库与重置采样分箱：全局帧轴拼接、frame→clip 映射 | `env/commands.py` → `data/motion_library.py` → `data/manifest.py`；`model/world_model.py` 也用它 | —（库模块） | S06 训练时的参考运动来源 | S06 |
| `src/morphmimic/data/seed_convert.py` | SEED 格式机器人 CSV → 50 Hz npz 全身体运动学（含 manifest 行） | `scripts/convert_seed.py` → `data/seed_convert.py` → `data/filters.py` | `uv run python -m morphmimic.scripts.convert_seed --csv-dir ... --out-dir ... --metadata ...` | S04 的核心转换器 | S04 |
| `src/morphmimic/env/actions.py` | canonical 关节位置动作项：把 29 维 canonical 动作翻译到机器人原生执行器 | `env/env_cfg.py` → `env/actions.py` → `robots/spec.py` | —（库模块） | S06 训练时的动作空间定义 | S06 |
| `src/morphmimic/env/commands.py` | 基于 motion library 的运动命令 + 基于回报的重置采样（与 mjlab MotionCommand 鸭子类型兼容） | `env/env_cfg.py` → `env/commands.py` → `data/motion_library.py` | —（库模块） | S06 环境的参考运动命令源 | S06 |
| `src/morphmimic/env/env_cfg.py` | 任意注册机器人的 flat tracking 环境配置（mjlab BeyondMimic cfg + 我们的命令/观测/终止） | `scripts/train.py` → `env/env_cfg.py` → `env/commands.py`、`env/observations.py`、`env/terminations.py` | —（库模块） | S06 训练环境装配点；S08 评测环境同源 | S06, S08 |
| `src/morphmimic/env/morphmimic_env.py` | `ManagerBasedRlEnv` 子类：让奖励与终止看到 step 之后的状态 | `env/env_cfg.py` → `env/morphmimic_env.py` → `env/commands.py` | —（库模块） | S06 训练/评测环境的基类 | S06, S08 |
| `src/morphmimic/env/observations.py` | SuperMimic 环境的观测项：全部 canonical（29 关节 / 14 body），关节项走机器人翻译器 | `env/env_cfg.py` → `env/observations.py` → `model/human.py`、`model/rewards_torch.py` | —（库模块） | S06 观测定义；S07 导出 ONNX 时的输入契约来源 | S06, S07 |
| `src/morphmimic/env/terminations.py` | MorphMimic 环境的终止项 | `env/env_cfg.py` → `env/terminations.py` → `env/commands.py` | —（库模块） | S06 训练终止条件 | S06 |
| `src/morphmimic/eval/benchmark.py` | 基准评测（论文 App. F）：子集里每个 clip 从首帧播一次，无 DR / 无噪声，摩擦 1.0 | `scripts/eval.py` → `eval/benchmark.py` → `eval/policy_loader.py`、`eval/drift.py` | `uv run python -m morphmimic.scripts.eval --ckpt ... --subset-yaml ...` | S08 的官方对照评测 | S08 |
| `src/morphmimic/eval/drift.py` | 漂移诊断：策略锚点相对参考锚点在整段 clip 上的 xy 与朝向误差 | `scripts/drift.py` → `eval/drift.py` → `eval/policy_loader.py`；`eval/benchmark.py` 也引用 | `uv run python -m morphmimic.scripts.drift --ckpt ... --subset-yaml ...` | S08 的失败模式定位手段 | S08 |
| `src/morphmimic/eval/kp_trace.py` | 渲染脚本的人体命令轨迹可视化（按点位掩码画球与亮线） | `scripts/render.py` → `eval/kp_trace.py` → `constants.py` | `uv run python -m morphmimic.scripts.render --ckpt ... --kp-trace` | S08 渲染人接口回放时的调试视图 | S08 |
| `src/morphmimic/eval/policy_loader.py` | 从训练 checkpoint 重建确定性策略（benchmark 与播放脚本共用） | `scripts/eval.py` → `eval/policy_loader.py` → `model/policy.py`、`train/normalizers.py` | —（库模块） | S07 parity 校验与 S08 评测共用的策略装载器 | S07, S08 |
| `src/morphmimic/model/human.py` | 人体骨架目标（keypoint goal v10）：特征、相对朝向、目标抖动与掩码 | `env/observations.py` → `model/human.py` → `model/state.py`；`train/imagination.py` 也用它 | —（库模块） | S05 人体 sidecar 与 S06 目标观测的接口定义 | S05, S06 |
| `src/morphmimic/model/nets.py` | 世界模型 / 策略 / critic 共用的 MLP 构造器 | `model/policy.py`、`model/world_model.py` → `model/nets.py` | —（库模块） | S06 网络结构基础 | S06 |
| `src/morphmimic/model/policy.py` | 策略（运动编码器 + 动作解码器）与 critic 网络（论文 Table A.4） | `train/trainer.py` → `model/policy.py` → `model/nets.py`；`deploy/export_onnx.py` 导出它 | —（库模块） | S06 训练对象、S07 导出对象 | S06, S07 |
| `src/morphmimic/model/rewards_torch.py` | 解析世界模型头：跟踪奖励、终止特征、观测与目标（纯张量版，镜像 mjlab 的 tracking 项） | `model/world_model.py`、`train/imagination.py` → `model/rewards_torch.py` → `model/state.py` | —（库模块） | S06 想象式策略改进的奖励来源 | S06 |
| `src/morphmimic/model/state.py` | 世界模型状态布局、canonical 坐标（heading / root）与 canonical 特征 | `model/world_model.py`、`model/rewards_torch.py` → `model/state.py` → `constants.py` | —（库模块） | S06 世界模型状态契约；S07 导出输入契约 | S06, S07 |
| `src/morphmimic/model/world_model.py` | 学习到的世界模型 f_omega：canonical 残差动力学 + 解析奖励/观测头 + 终止头 + k 步拟合损失 | `train/trainer.py` → `model/world_model.py` → `model/rewards_torch.py`、`model/state.py`、`train/replay.py` | —（库模块） | S06 训练的核心模型 | S06 |
| `src/morphmimic/robots/agibot_x2_ultra/x2_ultra_constants.py` | AgiBot X2 Ultra 的实体配置（MJCF 风格、DC 电机显式 PD、去掉延迟与 payload 辅助） | `robots/x2.py`、`tools/soma_retargeter/x2_limits_from_mjcf.py` → 本模块 | —（库模块） | S04 的关节限位来源；S06 多机器人训练的配置来源 | S04, S06 |
| `src/morphmimic/robots/booster_motor.py` | Booster 电机模型：显式 PD，转矩上限随关节速度下降（膝关节速度内保持，之后线性到空载速度归零） | `robots/t2_booster.py` → `robots/booster_motor.py` | —（库模块） | S06 中 T2 的执行器模型 | S06 |
| `src/morphmimic/robots/booster_t2/t2_constants.py` | Booster T2 实体配置（10 Hz 腿部 articulation，钉住上游 target_names_expr API） | `robots/t2.py`、`robots/t2_booster.py` → 本模块 | —（库模块） | S06 的 T2 机器人配置 | S06 |
| `src/morphmimic/robots/g1.py` | Unitree G1 spec：canonical 机器人，恒等翻译器 | `robots/spec.py` → `robots/g1.py` → `constants.py` | —（库模块） | S06 主线机器人（S06 训练对象就是 g1_amber，继承 G1） | S06 |
| `src/morphmimic/robots/g1_amber.py` | G1 Amber：腰部 roll/pitch 阻尼取 `WAIST_KD`，其余与 G1 相同 | `robots/g1.py` → `robots/g1_amber.py` → `robots/spec.py` | —（库模块） | **S06 的训练目标机器人** | S06 |
| `src/morphmimic/robots/morphology.py` | 每机器人静态形态向量（125 维：action scale / kp / kd / effort limit / 几何），供共享世界模型与策略使用 | `train/trainer.py` → `robots/morphology.py` → `robots/spec.py` | —（库模块） | S06 跨机器人共享策略的形态条件 | S06 |
| `src/morphmimic/robots/spec.py` | 每机器人 spec 与 canonical↔原生关节翻译器（置换 + 符号 + 零位偏置） | `env/actions.py`、`env/observations.py` → `robots/spec.py` → `robots/g1.py` | —（库模块） | S06 跨机器人训练的核心翻译层 | S06 |
| `src/morphmimic/robots/t2.py` | Booster T2 spec：躯干根、29 身体关节 + 2 头部关节，含前向运动学校验过的映射修正 | `robots/spec.py` → `robots/t2.py` → `robots/t2_booster.py`、`robots/booster_t2/t2_constants.py` | —（库模块） | S06 多机器人扩展点 | S06 |
| `src/morphmimic/robots/t2_booster.py` | Booster 官方 T2 执行器（PD 增益来自 BoosterRobotics 的 `booster_deploy`） | `robots/t2.py` → `robots/t2_booster.py` → `robots/booster_motor.py` | —（库模块） | S06 的 T2 执行器参数来源 | S06 |
| `src/morphmimic/robots/x2.py` | AgiBot X2 Ultra spec：29 身体关节 + 2 头部关节，手腕 yaw/roll 互换 | `robots/spec.py` → `robots/x2.py` → `robots/x2_agibot.py` | —（库模块） | S06 多机器人扩展点 | S06 |
| `src/morphmimic/robots/x2_agibot.py` | AgiBot 官方 X2 Ultra RL plant（来自 AimDK_X2 extra 的 motion_control.yaml 与 MJCF） | `robots/x2.py` → `robots/x2_agibot.py` → `robots/agibot_x2_ultra/x2_ultra_constants.py` | —（库模块） | S06 的 X2 执行器参数来源 | S06 |
| `src/morphmimic/scripts/build_subsets.py` | 按随机种子生成 tiny / 1h / 7h / 40h / all 五档子集 yaml | `data/manifest.py` → 本脚本（读 manifest.csv 写 subsets/*.yaml） | `uv run python -m morphmimic.scripts.build_subsets --manifest $DATA/seed_g1_npz50/manifest.csv --out-dir $DATA/seed_g1_npz50/subsets` | **S04 子集构建**；S06 训练与 S08 评测都以子集 yaml 为输入 | S04, S06, S08 |
| `src/morphmimic/scripts/check_human.py` | 用子集里的机器人 clip 校验 human sidecar 的一致性 | `data/human_convert.py`、`data/manifest.py` → 本脚本 | `uv run python -m morphmimic.scripts.check_human --subset-yaml subsets/1h.yaml --out ~/tmp/check_human.csv` | **S05 一致性校验**的入口 | S05 |
| `src/morphmimic/scripts/convert_human.py` | 把一个机器人 npz 集合对应的 SOMA BVH 转成 50 Hz human sidecar（多进程） | `data/human_convert.py` → `data/bvh.py` → `data/manifest.py` | `uv run python -m morphmimic.scripts.convert_human --npz-root $DATA/seed_g1_npz50 --bvh-root $DATA/seed/soma_uniform/bvh --workers 120` | **S05 sidecar 生成** | S05 |
| `src/morphmimic/scripts/convert_seed.py` | SEED 格式机器人 CSV → 50 Hz npz 运动 + 写 manifest（多进程） | `data/seed_convert.py` → `data/filters.py` → `data/manifest.py` | `uv run python -m morphmimic.scripts.convert_seed --csv-dir $DATA/seed/g1/csv --out-dir $DATA/seed_g1_npz50 --metadata $DATA/seed/seed_metadata_v003.csv --workers 120` | **S04 转换入口**；注意 README 里 v003 的元数据文件实际应取 v004（见⑤） | S04 |
| `src/morphmimic/scripts/drift.py` | 某 checkpoint 在某子集上的漂移诊断（逐 clip 从首帧、确定性策略、无 DR/噪声） | `eval/benchmark.py`、`eval/drift.py`、`eval/policy_loader.py` → 本脚本 | `uv run python -m morphmimic.scripts.drift --ckpt ... --subset-yaml ...` | S08 失败模式分析 | S08 |
| `src/morphmimic/scripts/eval.py` | 在子集上做基准评测（论文 App. F）：逐 clip、确定性策略、无 DR/噪声、地面摩擦 1.0 | `eval/benchmark.py` → `eval/policy_loader.py` → `env/env_cfg.py` | `uv run python -m morphmimic.scripts.eval --ckpt ... --subset-yaml ...` | **S08 官方对照评测入口** | S08 |
| `src/morphmimic/scripts/gpu_guard.py` | 脚本间共享的 GPU 选择：按 `CUDA_VISIBLE_DEVICES` 解析物理 GPU（单卡→cuda:0，数据并行第 i 卡→本进程 cuda:i） | `scripts/train.py`、`scripts/eval.py`、`scripts/play.py` 等 → 本模块 | —（库模块） | S06/S08 在 4090 上跑多任务时的设备选择 | S06, S08 |
| `src/morphmimic/scripts/play.py` | 在 mjlab viewer 里看一个 checkpoint 跟踪某个 clip（参考动作以 ghost 显示） | `env/env_cfg.py` + `eval/policy_loader.py` + `train/collector.py` → 本脚本 | `uv run python -m morphmimic.scripts.play --ckpt logs/smoke_tiny/latest.pt --subset-yaml ... --clip 0` | S08 仿真回放 | S08 |
| `src/morphmimic/scripts/render.py` | 把 checkpoint 播出的 clip 离屏渲染成 mp4（叠加 ghost 参考），支持 `--kp-trace` | `scripts/play.py` + `eval/kp_trace.py` + `eval/policy_loader.py` → 本脚本 | `uv run python -m morphmimic.scripts.render --ckpt logs/run/ckpt_8000.pt --subset-yaml ... --clips <name>` | S08 人接口回放的可视化产物 | S08 |
| `src/morphmimic/scripts/train.py` | 训练 SuperMimic 跟踪策略（Algorithm A.1），命令行参数对齐论文 Table A.5 | `train/trainer.py` → `train/collector.py` → `train/imagination.py` → `train/replay.py` | `uv run python -m morphmimic.scripts.train --subset-yaml $DATA/seed_g1_npz50/subsets/tiny.yaml --num-envs 512 --iterations 60 ...` | **S06 训练入口**（资源边界参数在这里收敛） | S06 |
| `src/morphmimic/train/collector.py` | 仿真数据采集（Algorithm A.1 步骤 1）：当前策略在堆叠的含噪 `policy` 观测上动作 | `train/trainer.py` → `train/collector.py` → `env/morphmimic_env.py`、`train/replay.py`、`train/obs_history.py` | —（库模块） | S06 采集阶段 | S06 |
| `src/morphmimic/train/distributed.py` | 数据并行训练帮助（每 GPU 一个进程，各自的 env / replay / collector / normalizer） | `train/trainer.py` → `train/distributed.py` | —（库模块） | S06 的多卡扩展（当前 S06 范围为单卡） | S06 |
| `src/morphmimic/train/imagination.py` | 用冻结世界模型做策略改进（论文 Eq.2/Eq.3）：从 replay 行出发做 H 步想象 rollout + BPTT | `train/trainer.py` → `train/imagination.py` → `model/world_model.py`、`model/rewards_torch.py`、`train/normalizers.py` | —（库模块） | S06 的想象阶段 | S06 |
| `src/morphmimic/train/multi_robot.py` | 多机器人训练时所有机器人共有的 clip 集合，以及跨机器人潜变量对齐的 (clip, frame) 抽样 | `train/trainer.py` → `train/multi_robot.py` → `data/manifest.py`、`train/distributed.py` | —（库模块） | S06 的多机器人扩展（x2/t2 链路的前置） | S06 |
| `src/morphmimic/train/normalizers.py` | 策略输入的运行期归一化（rsl_rl 的 EmpiricalNormalization：逐维运行均值方差） | `train/trainer.py`、`eval/policy_loader.py` → `train/normalizers.py` | —（库模块） | S07 导出 parity 校验必须复现归一化 | S06, S07 |
| `src/morphmimic/train/obs_history.py` | 策略观测历史堆叠（仿真侧堆含噪 policy 观测，想象侧恢复采样到的历史） | `train/collector.py`、`train/imagination.py` → `train/obs_history.py` | —（库模块） | S06 观测历史；S07 导出时的时序窗口契约 | S06, S07 |
| `src/morphmimic/train/replay.py` | 转移的环形缓冲：窗口采样与起始状态采样（含 s_t / o_t / a_t / r / d） | `train/collector.py` 写入 → `train/replay.py` → `train/imagination.py`、`model/world_model.py` | —（库模块） | S06 世界模型拟合与想象的样本来源 | S06 |
| `src/morphmimic/train/schedules.py` | 学习率调度（论文 Table A.5）：余弦衰减到某个比例后保持不变 | `train/trainer.py` → `train/schedules.py` | —（库模块） | S06 训练超参（注意 `--lr-decay-iters` 的含义，见⑤） | S06 |
| `src/morphmimic/train/trainer.py` | Algorithm A.1 训练循环：每次迭代采 1/UTD 步环境数据、k 步窗口拟合世界模型、H 步想象改进策略并拟合 critic | `scripts/train.py` → `train/trainer.py` → `train/collector.py`、`train/imagination.py`、`train/replay.py`、`train/multi_robot.py`、`model/world_model.py` | —（库模块） | **S06 训练主循环**（checkpoint 结构也由它定义） | S06, S07 |
| `deploy/export_ckpt.py` | 训练 checkpoint 的推理专用副本：`load_policy` 只读它（策略、normalizer、形态项、训练元信息） | `train/trainer.py` 的 checkpoint → `deploy/export_ckpt.py` → `deploy/export_onnx.py` | `uv run python deploy/export_ckpt.py --ckpt ... --out ...` | S07 导出链路的第一步 | S07 |
| `deploy/export_onnx.py` | 为共享策略运行导出「每个机器人一份输入 json + 一份 ONNX」，并给出共享策略的 manifest | `deploy/export_ckpt.py` → `deploy/export_onnx.py` → `model/policy.py`、`model/state.py` | `uv run python deploy/export_onnx.py --ckpt ... --out-dir ...` | **S07 ONNX 导出与 parity 校验** | S07 |
| `deploy/hardware/g1_node.py` | G1 真机侧：sim2sim 协议的机器人端，拥有 Unitree SDK（`unitree_interface`）与按键状态机 | `deploy/run.py --hardware g1` → `deploy/hardware/g1_node.py` → `deploy/sim2sim/protocol.py` | `uv run python deploy/run.py --hardware g1 --policy ...` | S08 真机链路（本任务只到工具链可用性验证） | S08 |
| `deploy/hardware/node.py` | 通用真机机器人端：按键状态机、50 Hz 策略循环与安全层，只依赖机器人提供的三件东西 | `deploy/hardware/g1_node.py` → `deploy/hardware/node.py` → `deploy/sim2sim/protocol.py` | —（库模块） | S08 真机节点的通用骨架 | S08 |
| `deploy/hardware/pad.py` | 按键来源：Linux joystick 与键盘回退；给出五个按键名（start / A / Y / B / select）的 held 集合 | `deploy/hardware/node.py` → `deploy/hardware/pad.py` | —（库模块） | S08 真机操作的输入层 | S08 |
| `deploy/hardware/pose_source.py` | 机器人位姿来源（`--goal-anchor robot` 时目标相对机器人自身锚点，需要机器人在参考世界里的位置与朝向） | `deploy/hardware/node.py` → `deploy/hardware/pose_source.py` | —（库模块） | S08 真机目标锚定 | S08 |
| `deploy/install_pico.sh` | 把 XRoboToolkit 的 PICO SDK（`xrobotoolkit_sdk`）装进本仓库的 `.venv`（克隆到 git-ignored 的 `deploy/third_party/`，用 scikit-build-core 而非 pybind11） | `deploy/install_pico.sh` → XRoboToolkit @ `XRT_REF` → `deploy/vr_teleop/pico_source.py` | `bash deploy/install_pico.sh` | S08 遥操作的设备依赖安装脚本；**S02 的 XRT 工具链探针依据** | S08 |
| `deploy/install_unitree_sdk.sh` | 把 Unitree SDK 的 python 绑定（`unitree_interface`）构建进本仓库的 uv 环境，供 G1 真机节点使用 | `deploy/install_unitree_sdk.sh` → `third_party/unitree_sdk2_wrapper` → `deploy/hardware/g1_node.py` | `bash deploy/install_unitree_sdk.sh` | S08 真机链路的 SDK 安装脚本；**S02 的 UNITREE 工具链探针依据**（构建拒绝 root、会弄脏子模块工作树） | S08 |
| `deploy/onboard/README.md` | 机器人自带电脑上的部署栈说明（容器、streamer、policy node、robot node 的接线图） | —（文档） | —（文档） | S08 真机部署的接线参考 | S08 |
| `deploy/onboard/g1/README.md` | G1 自带电脑上的文件分工：push.sh / install.sh / pico.sh / check_link.py | —（文档） | —（文档） | S08 真机部署的操作手册 | S08 |
| `deploy/onboard/g1/check_link.py` | 只读体检：运动模式、骨盆 IMU、每个关节编码器（温度与力矩）与遥控器 | —（脚本） | `uv run python deploy/onboard/g1/check_link.py` | S08 真机联调前的自检 | S08 |
| `deploy/onboard/g1/install.sh` | G1 Jetson 上构建部署环境 `.venv`（只用 policy node 与 g1_node 需要的包）与 Unitree SDK 绑定 | `deploy/install_unitree_sdk.sh` → 本脚本 | `bash deploy/onboard/g1/install.sh` | S08 真机环境准备 | S08 |
| `deploy/onboard/g1/pico.sh` | 一条命令起 G1 的 PICO 侧：询问头显 IP、加路由（sudo）、跑 PC 服务与 human streamer | `deploy/onboard/g1/pico.sh` → `deploy/onboard/pico/run.sh` | `bash deploy/onboard/g1/pico.sh [--record /data/session.npz]` | S08 人接口回放 | S08 |
| `deploy/onboard/g1/push.sh` | 从工作站把某个 commit（含子模块 pin 与可选导出）推到 G1 的 Jetson | `deploy/onboard/g1/push.sh` → ssh → 机器人 | `bash deploy/onboard/g1/push.sh [REV] [EXPORT_DIR]` | S08 真机部署分发 | S08 |
| `deploy/onboard/latency.py` | 无机器人时测量策略节点的状态→动作时延（50 Hz 固定站立状态） | `deploy/onboard/latency.py` ↔ 运行中的 `deploy/sim2sim/policy_node.py` | `uv run python deploy/onboard/latency.py` | S08 部署时延基线 | S08 |
| `deploy/onboard/pico/entrypoint.sh` | 容器内入口：起 PC 服务、等 SDK 端口、再跑 streamer | `deploy/onboard/pico/run.sh` → 本脚本 → `deploy/vr_teleop/streamer.py` | —（容器入口） | S08 人接口回放的容器内启动 | S08 |
| `deploy/onboard/pico/run.sh` | PICO 直连本机（机器人自带电脑）的 Docker 编排：构建镜像一次，跑 PC 服务与 streamer | `deploy/onboard/pico/run.sh` → `deploy/onboard/pico/entrypoint.sh` | `bash deploy/onboard/pico/run.sh --target human [--record /data/session.npz]` | S08 人接口回放的容器编排 | S08 |
| `deploy/run.py` | 一条命令的部署：`sim2sim/policy_node.py` 独立进程 + 机器人侧（`sim2sim/sim_node.py` 或 `--hardware g1`） | `deploy/run.py` → `deploy/sim2sim/policy_node.py` ↔ `deploy/sim2sim/sim_node.py`（经 `deploy/sim2sim/protocol.py`） | `uv run python deploy/run.py --policy deploy/ckpt/policy.onnx --scene ...` | **S08 部署总入口** | S08 |
| `deploy/sim2sim/export_assets.py` | 仿真侧需要的资产：从训练代码导出场景 XML 与每 clip 的 npz（CPU 仿真与策略侧共用） | `deploy/sim2sim/export_assets.py` → `env/env_cfg.py`、`deploy/sim2sim/loop_clip.py` | `uv run python deploy/sim2sim/export_assets.py --subset-yaml ... --out-dir ...` | S08 sim2sim 的资产准备 | S08 |
| `deploy/sim2sim/human.py` | 部署侧的人体骨架目标（keypoint goal v10），纯 numpy：特征构建与窗口操作 | `deploy/sim2sim/policy_node.py` → `deploy/sim2sim/human.py`（对照 `model/human.py`） | —（库模块） | S08 人接口；与训练侧特征一致性由测试保证 | S08 |
| `deploy/sim2sim/loop_clip.py` | 把导出的 clip 连播 N 次并合成一个 clip（canonical 参考状态、起始状态、ghost qpos） | `deploy/sim2sim/export_assets.py` → `deploy/sim2sim/loop_clip.py` | `uv run python deploy/sim2sim/loop_clip.py --clip ... --times N` | S08 sim2sim 循环片段 | S08 |
| `deploy/sim2sim/obs.py` | 从机器人测量构造策略输入，纯 numpy（无 torch / mjlab）：关节编码器、IMU 等 | `deploy/sim2sim/policy_node.py` → `deploy/sim2sim/obs.py` | —（库模块） | S08 部署侧观测构造（ONNX 输入契约） | S08, S07 |
| `deploy/sim2sim/policy_node.py` | 机器人侧策略进程：只用 numpy / onnx / onnxruntime；收到状态消息回关节目标 | `deploy/sim2sim/policy_node.py` ↔ `deploy/sim2sim/sim_node.py`（`deploy/sim2sim/protocol.py` 的 ZMQ 协议） | `uv run python deploy/sim2sim/policy_node.py --policy ... --source clip` | **S08 sim2sim 的策略侧**（与 `deploy/run.py` 联动） | S08 |
| `deploy/sim2sim/protocol.py` | 机器人（或 sim_node）与 policy_node 之间的 ZMQ 消息协议：两个小端 float32 帧消息 | `deploy/sim2sim/policy_node.py` ↔ `deploy/sim2sim/sim_node.py` / `deploy/hardware/node.py` | —（库模块） | S08 sim2sim 与真机共用的线上协议 | S08 |
| `deploy/sim2sim/sim_node.py` | 纯 CPU MuJoCo 里的机器人：加载导出的场景 XML，从 clip 首帧姿态起与策略锁步播放 | `deploy/sim2sim/sim_node.py` ↔ `deploy/sim2sim/policy_node.py`（`deploy/sim2sim/protocol.py`） | `uv run python deploy/sim2sim/sim_node.py --scene ... --clip ...` | **S08 sim2sim 的机器人侧** | S08 |
| `deploy/sim2sim/teleop.py` | 策略节点的实时参考：GMR streamer 帧 → 策略的 K 帧窗口（`TeleopReference` 取代 clip） | `deploy/vr_teleop/streamer.py` → `deploy/sim2sim/teleop.py` → `deploy/vr_teleop/timeline.py` | —（库模块） | S08 人接口回放（`--source teleop`） | S08 |
| `deploy/tools/gmr_operator.py` | 合成 PICO 采样，使 GMR 读出某个 G1 动作（GMR streamer 测试与会话用） | `deploy/tools/make_gmr_session.py` → `deploy/tools/gmr_operator.py` → `deploy/vr_teleop/gmr_streamer.py` | —（库模块） | S08 无头显测试人接口的夹具 | S08 |
| `deploy/tools/make_gmr_session.py` | 写出一个合成的 PICO 会话文件，让 GMR 读成一条 SEED clip（不需要头显） | `deploy/tools/make_gmr_session.py` → `deploy/tools/gmr_operator.py` | `uv run --group teleop python -m deploy.tools.make_gmr_session OUT.npz --clip $DATA/seed_g1_npz50/.../wave_R_001__A430.npz` | S08 人接口的离线回放夹具 | S08 |
| `deploy/vr_teleop/constants.py` | VR 遥操作的时间 / 网络 / 安全常量（streamer 与 sim2sim 策略节点共用，保证两端对流格式一致） | `deploy/vr_teleop/streamer.py`、`deploy/sim2sim/teleop.py` → 本模块 | —（库模块） | S08 人接口的流格式契约 | S08 |
| `deploy/vr_teleop/controller.py` | 接收端的遥操作模式逻辑（无 env、无 torch）：跟随消息里的模式，跌倒后锁 OFF 等复位 | `deploy/sim2sim/teleop.py` → `deploy/vr_teleop/controller.py` | —（库模块） | S08 人接口的模式/安全状态机 | S08 |
| `deploy/vr_teleop/controls.py` | PICO 按键状态机（OFF / IDLE / POSE / POSE_PAUSE），streamer 以约 100 Hz 轮询并调用 `Controls.update` | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/controls.py` | —（库模块） | S08 人接口的按键协议 | S08 |
| `deploy/vr_teleop/fit_gmr_configs.py` | 为 X2 与 T2 拟合 GMR 的 PICO→机器人 IK 配置（G1 的是上游自带的） | `deploy/vr_teleop/fit_gmr_configs.py` → `deploy/vr_teleop/gmr_retarget.py`（GMR 侧） | `uv run --group teleop python -m deploy.vr_teleop.fit_gmr_configs --robot x2` | S08 多机器人遥操作配置（GMR 工具链的落点） | S08 |
| `deploy/vr_teleop/gmr_retarget.py` | PICO 身体 → 完整机器人位姿（GMR，`third_party/GMR`）：逐帧 IK，把机器人身体拟合到操作者的 24 个 PICO 关节 | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/gmr_retarget.py` → `third_party/GMR` | —（库模块） | S08 人接口；**依赖 GMR 子模块（S02 工具链验证对象之一）** | S08 |
| `deploy/vr_teleop/gmr_streamer.py` | PICO 身体 → GMR → 机器人参考状态，供 sim2sim 策略节点使用 | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/gmr_streamer.py` → `deploy/vr_teleop/gmr_retarget.py` | —（库模块） | S08 人接口的机器人目标生成 | S08 |
| `deploy/vr_teleop/human_target.py` | PICO 身体 → 均匀骨架上的操作者（策略节点的人接口，`--target human`）：不走 GMR | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/human_target.py` → `deploy/sim2sim/human.py` | `uv run --group teleop python -m deploy.vr_teleop.human_target --replay session.npz` | S08 人接口回放（不需要 GMR） | S08 |
| `deploy/vr_teleop/pico_source.py` | PICO 采样的来源：头显或录制回放；后台线程读 XRoboToolkit SDK 的解算关节、时间戳与按键 | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/pico_source.py` → XRoboToolkit SDK | —（库模块） | S08 人接口的设备层；**依赖 XRoboToolkit（S02 工具链验证对象之一）** | S08 |
| `deploy/vr_teleop/protocol.py` | streamer → sim2sim 策略节点的线上格式：每个 ZMQ PUB 帧一条 msgpack `RefMessage`（模式、标定 id、设备时间、参考帧） | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/protocol.py` → `deploy/sim2sim/teleop.py` | —（库模块） | S08 人接口的线上协议 | S08 |
| `deploy/vr_teleop/resample.py` | 把抖动的 PICO 采样重采样到 50 Hz 设备时间栅格（`[24, 7]` 位姿，xyzw 四元数） | `deploy/vr_teleop/pico_source.py` → `deploy/vr_teleop/resample.py` → `deploy/vr_teleop/streamer.py` | —（库模块） | S08 人接口的时间栅格化 | S08 |
| `deploy/vr_teleop/skeleton_viz.py` | 头显腰部信息可视化：PICO 的 24 关节骨架（无 GMR、无物理） | `deploy/vr_teleop/pico_source.py` → `deploy/vr_teleop/skeleton_viz.py` | `uv run --group teleop python -m deploy.vr_teleop.skeleton_viz [--replay session.npz] [--no-viewer]` | S08 设备数据自检 | S08 |
| `deploy/vr_teleop/streamer.py` | PICO streamer 进程：头显采样 → 按键状态机 → 标定后的 50 Hz 帧 → ZMQ PUB 分片 | `deploy/vr_teleop/streamer.py` → `deploy/vr_teleop/pico_source.py` → `deploy/vr_teleop/gmr_streamer.py` / `human_target.py` → `deploy/vr_teleop/protocol.py` | `uv run --group teleop python -m deploy.vr_teleop.streamer --robot g1` | **S08 人接口的发送端** | S08 |
| `deploy/vr_teleop/timeline.py` | 接收端时间线：分片合并与抖动缓冲（合并 10 帧重叠分片，滞后 DELAY 帧播放） | `deploy/sim2sim/teleop.py` → `deploy/vr_teleop/timeline.py` | —（库模块） | S08 人接口的接收端时序 | S08 |
| `tools/soma_retargeter/assemble_robots.py` | 为 X2 与 T2 装配 SOMA Retargeter 的 `extra_robot_paths` 目录（URDF 关节限位替换为我们的 MJCF 限位） | `tools/soma_retargeter/x2_limits_from_mjcf.py` → `tools/soma_retargeter/assemble_robots.py` → NVIDIA/soma-retargeter | `uv run python tools/soma_retargeter/assemble_robots.py --retargeter <clone> --out $WORK/soma_robots` | S04 之后的重定向准备；**依赖 SOMA Retargeter（S02 工具链验证对象之一）** | S04, S08 |
| `tools/soma_retargeter/derive_t2.py` | 推导 Booster T2 的 scaler 标定（身高用 MuJoCo 前向运动学置脚底于 z=0） | `tools/soma_retargeter/derive_t2.py` → `robots/*` → NVIDIA/soma-retargeter 的 scaler 配置 | `uv run python tools/soma_retargeter/derive_t2.py --retargeter <clone>` | S04 重定向的 T2 标定 | S04 |
| `tools/soma_retargeter/limit_stats.py` | 重定向结果对仿真器限位的逐关节统计（硬限位/软限位占比） | `tools/soma_retargeter/limit_stats.py` → `data/seed_convert.py`、`robots/*` | `uv run python tools/soma_retargeter/limit_stats.py --motion ... --robot g1` | S04/S08 的重定向质量检查 | S04, S08 |
| `tools/soma_retargeter/shard_stage.py` | 把已 staged 的 BVH 树切成大小均衡的分片，供并行转换器运行 | `tools/soma_retargeter/stage_subset.py` → `tools/soma_retargeter/shard_stage.py` → `tools/soma_retargeter/launch_shards.sh` | `uv run python tools/soma_retargeter/shard_stage.py --subset-yaml ... --out ...` | S04 重定向的并行化 | S04 |
| `tools/soma_retargeter/stage_subset.py` | 把子集的 SOMA BVH 以符号链接树的形式 stage 出来，供重定向器读取 | `tools/soma_retargeter/stage_subset.py` → BONES-SEED 元数据 → NVIDIA/soma-retargeter | `uv run python tools/soma_retargeter/stage_subset.py --subset-yaml ... --bvh-root ... --out ...` | **S04→S05 的重定向入口**（与 `validate_csv.py` 成对） | S04, S05 |
| `tools/soma_retargeter/validate_csv.py` | 校验重定向后的 CSV：结尾换行、每 BVH 帧一行、38 列（Frame + 6 根 + 31 关节）在首/中/末行一致 | `tools/soma_retargeter/validate_csv.py` ← `tools/soma_retargeter/shard_stage.py`（按 `--done-csv-dir` 判完成） | `uv run python tools/soma_retargeter/validate_csv.py --bvh ... --csv ...` | S04/S05 的重定向产物校验 | S04, S05 |
| `tools/soma_retargeter/x2_limits_from_mjcf.py` | 从 X2 Ultra 的 MJCF 提取铰链关节限位，供重定向器的 X2 URDF 使用（腰/头/腕与 URDF 不同） | `tools/soma_retargeter/x2_limits_from_mjcf.py` → `robots/agibot_x2_ultra/x2_ultra_constants.py` | `uv run python tools/soma_retargeter/x2_limits_from_mjcf.py --out ...` | S04 重定向的限位来源 | S04 |
| `tools/soma_retargeter/launch_shards.sh` | 每个分片起一个脱离终端的 SOMA 转换器（按 GPU 列表轮转，batch 64） | `tools/soma_retargeter/shard_stage.py` → `tools/soma_retargeter/launch_shards.sh` → NVIDIA/soma-retargeter | `bash tools/soma_retargeter/launch_shards.sh <robot> <shard root> <export dir> <robots dir> <log dir> <gpu>...` | S04 重定向的批量执行（依赖 SOMA Retargeter 与外部数据） | S04 |

<!-- CODE_READ_MODULE_TABLE_END -->

> 表内 103 行与 `repro/lib/coderead.sh` 的发现规则一一对应；门禁 `repro/06_code_read.sh` 会断言
> `MODULES_TOTAL_103` / `MODULES_MISSING_0` / `MODULES_EMPTY_DUTY_0`，并打印 `CODE_READ_OK`。

---

## ③ 关键调用链详解（10 条）

### 链 1｜数据转换 → 子集构建

```
scripts/convert_seed.py
  └─ data/seed_convert.py   (SEED CSV: 120 Hz 的根平移/根旋转 + 每关节角度 → 50 Hz npz 全身体运动学)
       ├─ data/filters.py   (clip 准入：名称关键字 + 运动学可行性，拒绝时给原因)
       └─ data/manifest.py   (写 manifest.csv：每 clip 一行，path 相对 npz 根)
            └─ scripts/build_subsets.py  (按随机种子切 tiny / 1h / 7h / 40h / all 五个子集 yaml)
                 └─ env/commands.py → data/motion_library.py  (训练/评测时按子集加载参考运动)
```

- 入口：`uv run python -m morphmimic.scripts.convert_seed --csv-dir $DATA/seed/g1/csv --out-dir $DATA/seed_g1_npz50 --metadata $DATA/seed/seed_metadata_v003.csv --workers 120`
- 下一段：`uv run python -m morphmimic.scripts.build_subsets --manifest $DATA/seed_g1_npz50/manifest.csv --out-dir $DATA/seed_g1_npz50/subsets`
- 归属：S04（S03 提供原始数据与元数据校验）。

### 链 2｜训练主循环

```
scripts/train.py
  └─ train/trainer.py                       (Algorithm A.1：每次迭代采 1/UTD 步、拟合世界模型、想象式改进、拟合 critic)
       ├─ env/env_cfg.py → env/morphmimic_env.py → env/commands.py → data/motion_library.py
       ├─ train/collector.py                 (采 1/UTD 步；策略在含噪 policy 观测上动作)
       │    ├─ env/observations.py → model/human.py（目标侧）
       │    ├─ train/obs_history.py          (观测历史堆叠)
       │    └─ train/replay.py               (写 s_t / o_t / a_t / r / d)
       ├─ model/world_model.py               (k 步窗口拟合；残差动力学 + 解析奖励/观测头)
       │    ├─ model/state.py / model/rewards_torch.py / model/nets.py
       │    └─ train/replay.py               (窗口采样)
       └─ train/imagination.py               (冻结世界模型，H 步 rollout + BPTT 改进策略)
            ├─ model/policy.py / model/human.py / model/rewards_torch.py
            └─ train/normalizers.py / train/obs_history.py / train/replay.py
  辅助：train/schedules.py（余弦衰减 + 常数）、train/distributed.py（每 GPU 一进程）、
        train/multi_robot.py（跨机器人共有 clip 与潜变量对齐抽样）、robots/morphology.py（形态条件）
```

- 入口：`uv run python -m morphmimic.scripts.train --subset-yaml $DATA/seed_g1_npz50/subsets/tiny.yaml --num-envs 512 --iterations 60 --warmup-env-steps 20 --wm-batch 512 --imag-batch ...`
- 归属：S06。

### 链 3｜ONNX 导出

```
train/trainer.py 的 checkpoint
  └─ deploy/export_ckpt.py      (推理专用副本：策略 + normalizer + 形态项 + 训练元信息)
       └─ deploy/export_onnx.py  (每个机器人一份输入 json + 一份 ONNX + 共享策略 manifest)
            ├─ model/policy.py / model/state.py / model/human.py
            ├─ train/normalizers.py、train/imagination.py（导出时的接口依赖）
            └─ robots/*（每个机器人的输入布局）
```

- 入口：`uv run python deploy/export_ckpt.py --ckpt logs/run/latest.pt --out deploy/ckpt/`，
  `uv run python deploy/export_onnx.py --ckpt deploy/ckpt/ckpt.pt --out-dir deploy/ckpt/`
- 归属：S07（parity 校验用 `eval/policy_loader.py` 重建 PyTorch 策略与 ONNX 对拍）。

### 链 4｜sim2sim 部署

```
deploy/run.py
  ├─ (独立进程) deploy/sim2sim/policy_node.py     (numpy + onnxruntime；收状态回关节目标)
  └─ (本进程)   deploy/sim2sim/sim_node.py        (纯 CPU MuJoCo 机器人)
        两者只通过 deploy/sim2sim/protocol.py 的 ZMQ 消息通信
          （两个小端 float32 帧：机器人→策略 的状态，策略→机器人 的关节目标）
```

- 策略节点的观测构造：`deploy/sim2sim/obs.py`（关节编码器、IMU → ONNX 输入），
  人体目标侧：`deploy/sim2sim/human.py`（纯 numpy，与训练侧 `model/human.py` 对齐）。
- 入口：`uv run python deploy/run.py --policy deploy/ckpt/policy.onnx --scene deploy/ckpt/scene.xml --clip ...`
- 归属：S08。

### 链 5｜真机节点

```
deploy/run.py --hardware g1
  └─ deploy/hardware/g1_node.py   (G1 专用：拥有 Unitree SDK 的 unitree_interface)
       ├─ deploy/hardware/node.py     (通用机器人端：按键状态机 + 50 Hz 策略循环 + 安全层)
       │    ├─ deploy/hardware/pad.py         (joystick / 键盘按键来源)
       │    └─ deploy/hardware/pose_source.py (机器人自身位姿来源，供 --goal-anchor robot)
       └─ deploy/sim2sim/protocol.py    (与 policy_node 相同的 ZMQ 协议)
            ↔ deploy/sim2sim/policy_node.py
```

- 绑定安装：`deploy/install_unitree_sdk.sh` → `third_party/unitree_sdk2_wrapper` 的 pybind 绑定。
- 归属：S08（本复现只到「工具链可安装可用」）。

### 链 6｜PICO 遥操作

```
deploy/vr_teleop/streamer.py                     (streamer 进程)
  ├─ deploy/vr_teleop/pico_source.py             (头显 SDK / 录制回放，后台线程取解算关节 + 按钮)
  │    └─ deploy/vr_teleop/resample.py           (抖动采样 → 50 Hz 设备时间栅格)
  ├─ deploy/vr_teleop/controls.py                (OFF / IDLE / POSE / POSE_PAUSE 按键状态机)
  ├─ 目标二选一：
  │    ├─ deploy/vr_teleop/gmr_streamer.py → deploy/vr_teleop/gmr_retarget.py → third_party/GMR
  │    │      (PICO 身体 → 机器人参考状态；GMR 逐帧 IK)
  │    └─ deploy/vr_teleop/human_target.py        (PICO 身体 → 均匀骨架上的操作者，无 GMR)
  └─ deploy/vr_teleop/protocol.py                (msgpack RefMessage → ZMQ PUB 分片)
        ↓
deploy/sim2sim/teleop.py                         (策略节点的实时参考，取代 clip)
  ├─ deploy/vr_teleop/timeline.py               (分片合并 + 抖动缓冲，滞后 DELAY 帧)
  └─ deploy/vr_teleop/controller.py              (模式跟随 + 跌倒锁 OFF)
        ↓
deploy/sim2sim/policy_node.py                    (K 帧窗口 → ONNX → 关节目标)
```

- 依赖外部 SDK：XRoboToolkit（PICO 侧）、GMR（重定向侧）——见第 ④ 节。
- 归属：S08。

### 链 7｜评测与漂移

```
scripts/eval.py
  ├─ eval/policy_loader.py      (从 checkpoint 重建确定性策略 + normalizer)
  ├─ env/env_cfg.py → env/morphmimic_env.py → env/commands.py   (评测环境：无 DR、无噪声、摩擦 1.0)
  ├─ train/collector.py + train/obs_history.py                   (逐 clip 从首帧播一次)
  ├─ eval/benchmark.py → eval/drift.py                           (每个 clip 的回报 + 锚点漂移)
  └─ data/manifest.py                                             (子集解析)

scripts/drift.py  → eval/drift.py（锚点在 xy 与朝向上的漂移诊断）
scripts/play.py   → eval/policy_loader.py + env/*（viewer 里看一个 clip，ghost 参考）
scripts/render.py → scripts/play.py + eval/kp_trace.py（离屏渲染 mp4 + 人体命令轨迹）
```

- 入口：`uv run python -m morphmimic.scripts.eval --ckpt logs/run/latest.pt --subset-yaml $DATA/seed_g1_npz50/subsets/1h.yaml`
- 归属：S08。

### 链 8｜SOMA 重定向

```
tools/soma_retargeter/stage_subset.py            (子集 clip → 符号链接树 <out>/<date>/<stem>.bvh)
  └─ tools/soma_retargeter/shard_stage.py        (按大小均衡切片，跳过已完成 CSV 的 clip)
       └─ tools/soma_retargeter/launch_shards.sh  (每分片一个脱离终端的转换器进程，按 GPU 轮转)
            └─ NVIDIA/soma-retargeter @ cbdb2b4   (真正的重定向器：BVH → 机器人 CSV)
                 └─ tools/soma_retargeter/validate_csv.py  (行数/列数/结尾换行校验)
       机器人侧资产：
         tools/soma_retargeter/x2_limits_from_mjcf.py → tools/soma_retargeter/assemble_robots.py
         tools/soma_retargeter/derive_t2.py                                          (T2 scaler 标定)
       质量检查：tools/soma_retargeter/limit_stats.py（逐关节限位占比）
```

- 归属：S04（重定向本体）+ S05（sidecar 的输入）；依赖外部仓库 NVIDIA/soma-retargeter。

### 链 9｜评测环境 ↔ 训练环境（同一份 cfg）

```
env/env_cfg.py
  ├─ 训练：scripts/train.py → train/trainer.py → env/morphmimic_env.py
  └─ 评测：scripts/eval.py → eval/benchmark.py → env/morphmimic_env.py
              （同一套 env_cfg / observations / terminations / commands，
                评测只关掉 DR 与噪声并把地面摩擦设为 1.0）
```

- 这是 S08「官方对照」能成立的前提：训练与评测观测契约必须完全一致。
- 归属：S06 定义，S08 复用。

### 链 10｜部署栈的依赖隔离（为什么要分 sim2sim / hardware）

```
deploy/sim2sim/policy_node.py  ── 只依赖 numpy / onnx / onnxruntime
deploy/sim2sim/obs.py, human.py, protocol.py, teleop.py ── 同上（纯 numpy）
        ↕ ZMQ (deploy/sim2sim/protocol.py)
deploy/sim2sim/sim_node.py     ── 只依赖 mujoco + numpy（CPU 仿真，不需要 GPU / mjlab / torch）
deploy/hardware/node.py, g1_node.py, pad.py, pose_source.py ── 只依赖 numpy + Unitree SDK
```

- 分层约束由 `deploy/sim2sim/export_assets.py` 保证：只有它依赖 mjlab/torch（因为资产要从训练代码导出）。
- 归属：S08；也是 S07（ONNX）能在无 GPU 机器上验证的原因。

---

## ④ 外部依赖

| 依赖 | 锁定版本 | 本复现中的状态 | 原因 / 证据 |
|---|---|---|---|
| `third_party/GMR`（YanjieZe/GMR，General Motion Retargeting） | `25f56db79ac411258b377b6d4ccba0c8ff3372ac` | **VERIFIED（已验过）** | 子模块按 `.gitmodules` 的 gitlink 落地并校验 SHA；`uv sync --frozen --group export --group teleop` 退出 0（`logs/env/03_uv_sync.txt`）；缺 GMR 时同一条命令退出 2 的失败路径已归档（`logs/env/02_uv_sync_without_gmr.txt`） |
| `third_party/unitree_sdk2_wrapper`（Unitree SDK2 + pybind 绑定） | `6264cc1efd9e72d3c7fffa38a360aea9e43838f3` | **VERIFIED（已验过）** | 子模块按 gitlink 落地并校验 SHA；SDK 资产（`lib/x86_64/libunitree_sdk2.a`、`include/unitree/`、`python_binding/*.cpp`）齐全；pybind11 绑定在 `logs/toolchain/build/` 的副本里以 uid 1000 构建成功并可 `import unitree_interface`。真机通信回环需 G1 硬件，属 S08 范围（`logs/env/07_toolchain.txt`） |
| `NVIDIA/soma-retargeter` | `cbdb2b494a2af82137bf9b6f15122d60167281c4` | **VERIFIED（已验过）** | 按锁定提交克隆（`git_in` + `GIT_LFS_SKIP_SMUDGE=1`），依赖装进独立 Python ≥ 3.12 venv（`requires-python>=3.12` 与项目 venv 3.11 不兼容），`import soma_retargeter` 成功；项目侧 `stage_subset/assemble_robots/validate_csv` 三个脚本 `--help` 全部退出 0（`logs/env/07_toolchain.txt`） |
| `XR-Robotics/XRoboToolkit-PC-Service-Pybind` | `8941e1dbbf4313fe83846f82984eaa8c992690bf`（= `deploy/install_pico.sh` 的 `XRT_REF`） | **VERIFIED（已验过）** | 按锁定提交克隆，用 scikit-build-core 构建出 `xrobotoolkit_sdk-1.1.0-cp310-abi3-linux_x86_64.whl`（自拉 cmake ≥ 3.26，镜像 cmake 3.22.1 不够），装进隔离 venv 后 `import xrobotoolkit_sdk` 成功；未装进项目 venv（普通 `uv sync` 会删掉锁文件外的包）（`logs/env/07_toolchain.txt`） |

> **权威来源**：`docs/code_read/TOOLCHAIN.md`（S02/T3 产出）与 `logs/env/07_toolchain.txt` 里逐组的
> `TOOLCHAIN_<NAME>_VERDICT` / `_REASON` / `_EVIDENCE` 三行。本表是它在「代码地图」视角下的摘要，
> 两者结论必须一致；如有不一致，以 `TOOLCHAIN.md` 为准并回头修正本表。

---

## ⑤ README 偏离项与已知坑

1. **`seed_metadata_v003.csv` 不存在 → 实际用 `v004`**
   README 的 G1 段（第 99–105 行）让用户下载 `seed_metadata_v003.csv`，但数据实际只提供
   `seed_metadata_v004.csv`（README 第 145 行的多机器人段用的就是 v004）。
   `scripts/convert_seed.py` 的 docstring 仍写 v003。**转换前必须确认元数据文件版本**，
   否则元数据匹配不上，clip 会被静默丢掉。

2. **`--lr-decay-iters`（`train/trainer.py` 的 `lr_decay_iters`，默认 250 000）**
   README 第 231 行说明：250k 迭代时学习率仍然偏高，所以他们的做法是把它调小。
   复现训练时必须显式设置，否则长训的学习率曲线与论文不一致。

3. **`uv sync` 会摘掉 pip 装的包**
   `uv sync` 让环境回到 lockfile 声明的状态，任何用 `uv pip install` 临时装的包（例如额外装的
   构建工具）会在下一次 `uv sync` 后消失。容器的镜像层里装的东西不算，必须装进 `.venv`。

4. **`--frozen` vs `--locked`**
   用 `uv sync --frozen`（按现有 `uv.lock` 装，不重新解析、不改 lockfile），**不要**用 `--locked`
   （会重新校验 lockfile 是否与 `pyproject.toml` 一致；本仓库的 `pyproject.toml` 与 `uv.lock`
   不是逐字对应的 workspace 解析结果，`--locked` 会失败）。

5. **git `dubious ownership` 必须走 `common.sh:git_in`**
   NFS 导出是 root-squash 的，容器里以 root 跑 git 会看到
   `fatal: detected dubious ownership`；容器内 git 是 2.34.1，只读全局配置文件，
   `safe.directory=*` 通配与命令行 `-c safe.directory=<path>` 都无效。
   **唯一免配置的办法是以目录属主 uid 运行 git**：`repro/lib/common.sh` 的 `git_in`
   用 `setpriv --reuid=<uid> --regid=<gid> --clear-groups env HOME=/tmp git -C <dir> ...` 实现。

6. **代理只内联、不落系统配置**
   `repro/lib/common.sh` 只把 `http_proxy` / `https_proxy` / `HTTP_PROXY` / `HTTPS_PROXY` /
   `no_proxy` / `NO_PROXY` 导出到**当前进程**；绝不写 `/etc/environment`、`/etc/profile*`、
   `~/.bashrc`、`uv.toml`、`pip.conf`、`gitconfig`。`repro/05_proxy_hygiene.sh` 把这条约定变成
   机器断言（`PROXY_HYGIENE_OK`）。注意本地开发机本来就有自己的代理配置，
   代理卫生断言只在容器内成立。

7. **本工作树是 linked worktree，容器里的 `.git` 指针指向宿主机路径**
   容器内必须用 `GIT_DIR` / `GIT_WORK_TREE` 重映射（`common.sh:resolve_git_context()`），
   否则 `git` 报 `fatal: not a git repository`；`git submodule update --init` 在这种工作树上
   也会失败，所以 S01 改成「按 SHA 直接 clone」的方式落地子模块。

8. **`docs/code_doc` 是指向仓库外的符号链接**
   该链接在容器内是断链，所以本复现的阅读记录落在仓库内的 `docs/code_read/`。

---

## ⑥ 未决问题与 S03–S09 的交接事项

### 未决问题

| # | 问题 | 影响 | 处理建议 |
|---|---|---|---|
| Q1 | `third_party/unitree_sdk2_wrapper` 的 pybind 绑定尚未在容器内构建（构建脚本拒绝 root、且会弄脏子模块工作树） | 真机链路的工具链结论只能是「部分可用」 | 在 `logs/` 下的副本里以 `setpriv --reuid=1000` 构建；结论写入 `TOOLCHAIN.md` |
| Q2 | SOMA Retargeter 需要 Python ≥ 3.12，项目 venv 是 3.11.16 | x2/t2 的重定向链路暂不可跑 | 用 uv 托管的 cpython-3.12.14 建独立 venv；按 R017 延后到工具链切片 |
| Q3 | XRoboToolkit 需要外网克隆 + 自拉 cmake | PICO 遥操作的真机验证暂不可跑 | 走 `deploy/install_pico.sh`（`XRT_REF` 已钉死），结论写入 `TOOLCHAIN.md` |
| Q4 | 数据侧：`seed_metadata_v003.csv` 与实际的 v004 的差异尚需按真实数据核对 | 转换阶段可能静默丢 clip | S03 下载后先跑一遍元数据匹配统计再进 S04 |
| Q5 | `tools/soma_retargeter/` 引用的是外部仓库的目录布局（`$DATA/soma-retargeter`），本仓库内没有该目录 | 分片转换脚本无法离线自测 | 只能在有该 clone 的机器上跑；单测只覆盖本仓库内的纯逻辑 |

### 交接事项

- **→ S03**：用第 ⑤ 节第 1 条的元数据版本结论；数据完整性校验以 `data/manifest.py` 的列定义为准。
- **→ S04**：`scripts/convert_seed.py` → `scripts/build_subsets.py` 的参数与子集 yaml 位置；
  `tools/soma_retargeter/stage_subset.py` → `shard_stage.py` → `launch_shards.sh` → `validate_csv.py`
  的顺序；X2/T2 的限位来自 `robots/agibot_x2_ultra/x2_ultra_constants.py` 与 `x2_limits_from_mjcf.py`。
- **→ S05**：`scripts/convert_human.py` 的输入是 SOMA BVH（来自链 8），输出 sidecar 由
  `data/human_convert.py` 定义；`scripts/check_human.py` 是校验入口。
- **→ S06**：训练入口 `scripts/train.py` 与超参（Table A.5 + `--lr-decay-iters`）；
  机器人是 `robots/g1_amber.py`；资源边界的收敛点在 `scripts/train.py` 的命令行参数。
- **→ S07**：导出链 `deploy/export_ckpt.py` → `deploy/export_onnx.py`；
  parity 校验需复现 `train/normalizers.py` 的归一化与 `train/obs_history.py` 的历史窗口。
- **→ S08**：部署入口 `deploy/run.py`（sim2sim / `--hardware g1`）、人接口 `deploy/vr_teleop/streamer.py`
  与 `deploy/sim2sim/teleop.py`、评测 `scripts/eval.py` 与 `scripts/drift.py`；
  工具链可用性结论见 `docs/code_read/TOOLCHAIN.md`。
- **→ S09**：本文件的第 ① 节（总览与目录树）、第 ② 节（模块清单）、第 ③ 节（调用链）
  是《MorphMimic 完整复现记录.md》「代码地图」章节的原料；
  工具链结论取自 `docs/code_read/TOOLCHAIN.md`；环境事实取自 `logs/env/`。
