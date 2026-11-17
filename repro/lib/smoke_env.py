#!/usr/bin/env python3
"""Run the 32-env simulation smoke test on the synthetic standing clip.

This is the first proof that the simulation stack really runs on this machine:
the MJCF assets are shipped by the wheel, the warp/mujoco-warp kernels compile
(JIT) on the GPU, the GPU simulation steps, and the reward is a finite number.

Two traps this script handles explicitly:

  * `auto_reset=False`. `MorphMimicEnv.step` refuses to step while an env is
    pending a reset ("Environments [...] must be reset via reset(env_ids=...)"),
    so every finished env is reset right after the step that finished it.
  * a silent NaN. "No exception was raised" is weak evidence; the reward mean
    being finite is the stronger one, and it is asserted.

Usage (inside the ros_dev container):
    uv run --frozen --no-sync python repro/lib/smoke_env.py
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import torch
from mjlab.utils.torch import configure_torch_backends

from morphmimic.constants import NUM_JOINTS
from morphmimic.env.commands import MultiMotionCommand
from morphmimic.env.env_cfg import COMMAND_NAME, morphmimic_env_cfg
from morphmimic.env.morphmimic_env import MorphMimicEnv
from morphmimic.scripts.gpu_guard import select_gpu

SMOKE_ROBOT = "g1_amber"
SMOKE_NUM_ENVS = 32
SMOKE_STEPS = 50


def _warp_cache_dir() -> str:
  """Warp's kernel cache (the first run compiles, the later ones hit it)."""
  import warp as wp

  return str(getattr(wp.config, "kernel_cache_dir", "") or "~/.cache/warp")


def main() -> None:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument(
    "--subset-yaml",
    default=str(
      Path(__file__).resolve().parents[2]
      / "data"
      / "smoke"
      / "seed_g1_npz50"
      / "subsets"
      / "smoke.yaml"
    ),
  )
  parser.add_argument("--robot", default=SMOKE_ROBOT)
  parser.add_argument("--num-envs", type=int, default=SMOKE_NUM_ENVS)
  parser.add_argument("--steps", type=int, default=SMOKE_STEPS)
  parser.add_argument("--gpu", type=int, default=0)
  args = parser.parse_args()

  subset_yaml = str(Path(args.subset_yaml).resolve())
  if not Path(subset_yaml).exists():
    raise SystemExit(
      f"the subset yaml {subset_yaml} does not exist; run repro/lib/make_smoke_clip.py"
      " first (repro/04_smoke.sh does both)"
    )

  # The GPU must be selected before CUDA is initialised.
  select_gpu(args.gpu)
  configure_torch_backends()
  device = "cuda:0"

  cfg = morphmimic_env_cfg(
    args.robot, subset_yaml=subset_yaml, num_envs=args.num_envs
  )
  t_env = time.perf_counter()
  env = MorphMimicEnv(cfg, device=device)
  env_build_seconds = time.perf_counter() - t_env

  print(f"NUM_ENVS_{env.num_envs}")
  if env.num_envs != args.num_envs:
    raise SystemExit(f"the env has {env.num_envs} envs, expected {args.num_envs}")
  print(f"CUDA_DEVICE_{torch.cuda.get_device_name(0)}")
  print(f"CUDA_AVAILABLE_{str(torch.cuda.is_available()).upper()}")
  print(f"ENV_BUILD_SECONDS_{env_build_seconds:.3f}")
  print(f"WARP_CACHE_DIR_{_warp_cache_dir()}")

  command = env.command_manager.get_term(COMMAND_NAME)
  assert isinstance(command, MultiMotionCommand)
  library = command.library
  print(f"LIB_CLIPS_{library.num_clips}")
  print(f"LIB_FRAMES_{int(library.joint_pos.shape[0])}")
  print(f"LIB_NUM_BINS_{command.library.num_bins}")

  obs, _extras = env.reset()
  print(f"OBS_KEYS_{','.join(sorted(obs.keys()))}")

  action_dim = int(env.action_manager.total_action_dim)
  print(f"ACTION_DIM_{action_dim}")
  if action_dim != NUM_JOINTS:
    raise SystemExit(f"the action dim is {action_dim}, expected {NUM_JOINTS}")

  reward_sum = 0.0
  reward_count = 0
  resets = 0
  first_step_seconds = float("nan")
  second_step_seconds = float("nan")

  for step in range(args.steps):
    action = torch.zeros(
      env.num_envs, action_dim, device=env.device, dtype=torch.float32
    )
    t0 = time.perf_counter()
    obs, reward, terminated, truncated, _extras = env.step(action)
    elapsed = time.perf_counter() - t0
    if step == 0:
      first_step_seconds = elapsed
    elif step == 1:
      second_step_seconds = elapsed

    if not torch.isfinite(reward).all():
      raise SystemExit(
        f"step {step}: the reward is not finite (nan/inf) — the simulation diverged"
      )
    reward_sum += float(reward.mean().item())
    reward_count += 1

    # auto_reset=False: every finished env has to be reset explicitly.
    done = terminated | truncated
    done_ids = done.nonzero(as_tuple=False).squeeze(-1)
    if done_ids.numel() > 0:
      env.reset(env_ids=done_ids)
      resets += int(done_ids.numel())

  reward_mean = reward_sum / max(reward_count, 1)
  print(f"STEPS_{args.steps}")
  print(f"REWARD_MEAN_{reward_mean:.6f}")
  print("REWARD_MEAN_FINITE")
  print(f"RESET_ENVS_{resets}")
  print(f"FIRST_STEP_SECONDS_{first_step_seconds:.3f}")
  print(f"SECOND_STEP_SECONDS_{second_step_seconds:.3f}")

  env.close()
  print("SMOKE_ENV_OK")


if __name__ == "__main__":
  main()
