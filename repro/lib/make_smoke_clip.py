#!/usr/bin/env python3
"""Build the synthetic standing clip that the 32-env simulation smoke test tracks.

Why a synthetic clip at all: the registered task ids cannot be used yet.
`MultiMotionCommand.__init__` raises `ValueError` when `subset_yaml` is empty
(src/morphmimic/env/commands.py), and the real npz clips only arrive in S03/S04.
So the smoke test ships its own one-clip library: the robot in its default
(knees bent) standing pose, held still for 2 s at 50 Hz.

The npz is written with exactly the key set of `seed_convert.convert_clip`, so
`MotionLibrary` reads it like a converted clip:

    fps, joint_pos, joint_vel, body_pos_w, body_quat_w, body_lin_vel_w,
    body_ang_vel_w, body_names, joint_names, z_min, foot_dist, robot, root_body

Foot placement: the root height is not taken from the keyframe (the keyframe's
0.76 m is the nominal standing height of the *model*, not of the flat-mesh
variant). Instead the foot clearance is measured with `mujoco.mj_geomDistance`
against the floor plane and the root is lowered until the lowest foot geom sits
`TARGET_FOOT_CLEARANCE_M` above the floor. A penetration (a foot below the
floor) would make the contact solver push the robot up on the first step and
would make the smoke numbers meaningless, so the clearance is asserted.

Usage (inside the ros_dev container):
    uv run --frozen --no-sync python repro/lib/make_smoke_clip.py
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import mujoco
import numpy as np
import yaml
from mjlab.utils.string import resolve_expr

from morphmimic.constants import FPS, NUM_JOINTS
from morphmimic.data.seed_convert import (
  body_names as model_body_names,
)
from morphmimic.data.seed_convert import (
  finite_diff_velocities,
  foot_geoms,
  forward_kinematics,
  make_model,
)
from morphmimic.robots import RobotSpec, get_robot

SMOKE_ROBOT = "g1_amber"
"""The robot of the S06 training target (the G1 with the waist damping at 3.0)."""

SMOKE_MODEL_ROBOT = "g1"
"""The model the FK runs on: `g1_amber` only changes an actuator's damping, so
the MJCF (and with it every body and joint) is the G1's."""

SMOKE_FRAMES = 100
"""2 s at 50 Hz: long enough for the motion library to cut a bin, short enough
to keep the smoke test quick."""

SMOKE_FPS = FPS
TARGET_FOOT_CLEARANCE_M = 0.001
"""How far above the floor the lowest foot geom rests (a hair above, so the
contact is stable and nothing penetrates)."""

PROBE_ROOT_Z_M = 1.0
"""Root height of the clearance probe: high enough that the feet are well
above the floor (the distance query stays in its valid range)."""

MOTION_KEYS: tuple[str, ...] = (
  "fps",
  "joint_pos",
  "joint_vel",
  "body_pos_w",
  "body_quat_w",
  "body_lin_vel_w",
  "body_ang_vel_w",
  "body_names",
  "joint_names",
  "z_min",
  "foot_dist",
  "robot",
  "root_body",
)


# --- the standing pose ------------------------------------------------------
def standing_joint_pos(spec: RobotSpec) -> np.ndarray:
  """The robot's default (knees bent) standing joint positions, in radians.

  mjlab's `init_state.joint_pos` is a regex -> value map, not an array; it is
  resolved against the robot's native joint order (`spec.joint_names`).
  """
  init = spec.entity_cfg_fn().init_state
  values = resolve_expr(init.joint_pos or {}, spec.joint_names, 0.0)
  out = np.asarray(values, dtype=np.float64)
  if out.shape != (len(spec.joint_names),):
    raise ValueError(
      f"{spec.name}: init_state.joint_pos resolved to {out.shape}, expected"
      f" {(len(spec.joint_names),)}"
    )
  return out


def _pose_data(
  model: mujoco.MjModel,
  root_pos: np.ndarray,
  root_quat: np.ndarray,
  joint_pos: np.ndarray,
) -> mujoco.MjData:
  """The kinematics of one pose (root at the origin, the given joint positions)."""
  data = mujoco.MjData(model)
  data.qpos[:] = np.concatenate([root_pos, root_quat, joint_pos])
  mujoco.mj_kinematics(model, data)
  mujoco.mj_comPos(model, data)
  return data


def foot_lowest_z(
  model: mujoco.MjModel,
  data: mujoco.MjData,
  foot_geom_ids: tuple[int, ...],
  floor_id: int,
) -> float:
  """Height of the lowest point of the foot geoms above the floor plane.

  `mujoco.mj_geomDistance` fills `fromto` with the closest points of the two
  geoms: `fromto[0:3]` on the foot, `fromto[3:6]` on the floor plane (whose
  closest point is at z = 0), so `fromto[2]` is the foot's lowest height.
  """
  lowest = float("inf")
  for geom_id in foot_geom_ids:
    fromto = np.zeros(6)
    dist = float(mujoco.mj_geomDistance(model, data, geom_id, floor_id, 2.0, fromto))
    if dist >= 2.0:
      # Too far to be the closest pair (the probe pose is well above the floor);
      # skip it rather than trusting the untouched `fromto`.
      continue
    lowest = min(lowest, float(fromto[2]))
  if not np.isfinite(lowest):
    raise RuntimeError("no foot geom within 2 m of the floor plane")
  return lowest


def root_height_for_feet(
  model: mujoco.MjModel,
  joint_pos: np.ndarray,
  foot_geom_ids: tuple[int, ...],
  floor_id: int,
  target_clearance: float = TARGET_FOOT_CLEARANCE_M,
) -> tuple[float, float]:
  """(root height, resulting foot clearance) that rests the feet on the floor.

  The pose is static, so the clearance is affine in the root height with slope
  1: one probe at `PROBE_ROOT_Z_M` is enough.
  """
  probe = _pose_data(
    model,
    np.array([0.0, 0.0, PROBE_ROOT_Z_M]),
    np.array([1.0, 0.0, 0.0, 0.0]),
    joint_pos,
  )
  clearance = foot_lowest_z(model, probe, foot_geom_ids, floor_id)
  root_z = PROBE_ROOT_Z_M + (target_clearance - clearance)
  return float(root_z), float(clearance + (root_z - PROBE_ROOT_Z_M))


# --- the motion -------------------------------------------------------------
def build_standing_motion(
  robot: str = SMOKE_ROBOT,
  frames: int = SMOKE_FRAMES,
) -> dict[str, np.ndarray]:
  """The synthetic standing clip as the npz key set of `convert_clip`."""
  spec = get_robot(robot)
  model = make_model(SMOKE_MODEL_ROBOT)

  body_names = model_body_names(model)
  if len(body_names) == 0:
    raise ValueError(f"{SMOKE_MODEL_ROBOT}: the model has no bodies")
  missing = [b for b in (*spec.tracked_bodies, spec.root_body) if b not in body_names]
  if missing:
    raise ValueError(f"{SMOKE_MODEL_ROBOT}: the model has no bodies {missing}")
  if len(spec.joint_names) != NUM_JOINTS:
    raise ValueError(
      f"{robot}: {len(spec.joint_names)} native joints, expected {NUM_JOINTS}"
    )

  joint_pos = standing_joint_pos(spec)
  feet = foot_geoms(model, spec.foot_geom_regex)
  foot_geom_ids = tuple(model.geom(name).id for side in feet for name in side)
  floor_id = model.geom("floor").id

  root_z, clearance = root_height_for_feet(
    model, joint_pos, foot_geom_ids, floor_id
  )
  if clearance < -1e-6:
    raise RuntimeError(
      f"the feet penetrate the floor by {-clearance:.4f} m; the root height is wrong"
    )

  root_pos = np.tile(np.array([0.0, 0.0, root_z]), (frames, 1))
  root_quat = np.tile(np.array([1.0, 0.0, 0.0, 0.0]), (frames, 1))
  joint_pos_t = np.tile(joint_pos, (frames, 1))

  fk = forward_kinematics(model, root_pos, root_quat, joint_pos_t, feet=feet)
  joint_vel, body_lin_vel_w, body_ang_vel_w = finite_diff_velocities(
    joint_pos_t, fk.body_pos_w, fk.body_quat_w, SMOKE_FPS
  )

  f32 = np.float32
  motion = {
    "fps": np.array(SMOKE_FPS, dtype=np.int64),
    "joint_pos": joint_pos_t.astype(f32),
    "joint_vel": joint_vel.astype(f32),
    "body_pos_w": fk.body_pos_w.astype(f32),
    "body_quat_w": fk.body_quat_w.astype(f32),
    "body_lin_vel_w": body_lin_vel_w.astype(f32),
    "body_ang_vel_w": body_ang_vel_w.astype(f32),
    "body_names": np.array(body_names),
    "joint_names": np.array(spec.joint_names),
    "z_min": fk.z_min.astype(f32),
    "foot_dist": fk.foot_dist.astype(f32),
    "robot": np.array(spec.name),
    "root_body": np.array(spec.root_body),
  }
  validate_motion(motion, spec)
  return motion


def validate_motion(motion: dict[str, np.ndarray], spec: RobotSpec) -> None:
  """Raises `ValueError` when the motion does not satisfy the reader's contract.

  The checks mirror `MotionLibrary.__init__`: the key set, the frame count, the
  body and joint names and finite numbers everywhere. A clip that violates them
  is rejected here, with a readable message, instead of deep inside the env.
  """
  missing = [k for k in MOTION_KEYS if k not in motion]
  if missing:
    raise ValueError(f"the motion misses the keys {missing}")
  extra = [k for k in motion if k not in MOTION_KEYS]
  if extra:
    raise ValueError(f"the motion has the unexpected keys {extra}")

  frames = len(motion["joint_pos"])
  if frames < 2:
    raise ValueError(f"the motion has {frames} frame(s); a clip needs at least 2")

  joints = tuple(str(n) for n in motion["joint_names"])
  if joints != tuple(spec.joint_names):
    raise ValueError(
      f"the motion's joints do not match {spec.name}: {sorted(set(joints) ^ set(spec.joint_names))}"
    )
  bodies = tuple(str(n) for n in motion["body_names"])
  missing_bodies = [b for b in (*spec.tracked_bodies, spec.root_body) if b not in bodies]
  if missing_bodies:
    raise ValueError(f"the motion misses the bodies {missing_bodies}")

  if int(motion["fps"]) != SMOKE_FPS:
    raise ValueError(f"the motion's fps is {int(motion['fps'])}, expected {SMOKE_FPS}")

  for key in ("joint_pos", "joint_vel", "body_pos_w", "body_quat_w",
              "body_lin_vel_w", "body_ang_vel_w", "z_min", "foot_dist"):
    array = np.asarray(motion[key], dtype=np.float64)
    if not np.isfinite(array).all():
      raise ValueError(f"the motion's {key} has non-finite values")
  if motion["joint_pos"].shape != (frames, len(spec.joint_names)):
    raise ValueError(f"the motion's joint_pos has shape {motion['joint_pos'].shape}")
  if motion["body_pos_w"].shape[:2] != (frames, len(bodies)):
    raise ValueError(f"the motion's body_pos_w has shape {motion['body_pos_w'].shape}")


# --- writing ----------------------------------------------------------------
def write_motion(path: str | Path, motion: dict[str, np.ndarray]) -> Path:
  """Writes the npz (write-then-rename, like `convert_clip`)."""
  out = Path(path)
  out.parent.mkdir(parents=True, exist_ok=True)
  tmp = out.with_name(out.name + ".tmp")
  with open(tmp, "wb") as f:
    np.savez(f, **motion)
  os.replace(tmp, out)
  return out


def write_subset(
  path: str | Path, root: str | Path, hours: float, clips: list[str]
) -> Path:
  """Writes the subset yaml in the format of `manifest.build_subset`."""
  out = Path(path)
  out.parent.mkdir(parents=True, exist_ok=True)
  spec = {"root": str(root), "hours": float(hours), "clips": list(clips)}
  tmp = out.with_name(out.name + ".tmp")
  with open(tmp, "w") as f:
    yaml.safe_dump(spec, f, sort_keys=False)
  os.replace(tmp, out)
  return out


def main() -> None:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--robot", default=SMOKE_ROBOT)
  parser.add_argument("--frames", type=int, default=SMOKE_FRAMES)
  parser.add_argument(
    "--out-root",
    default=str(
      Path(__file__).resolve().parents[2] / "data" / "smoke" / "seed_g1_npz50"
    ),
    help="the npz root of the smoke library (the subset yaml's `root`)",
  )
  args = parser.parse_args()

  out_root = Path(args.out_root).resolve()
  clip_rel = "smoke_stand/stand.npz"
  clip_path = out_root / clip_rel
  subset_path = out_root / "subsets" / "smoke.yaml"

  motion = build_standing_motion(args.robot, args.frames)
  write_motion(clip_path, motion)

  hours = args.frames / SMOKE_FPS / 3600.0
  write_subset(subset_path, out_root, hours, [clip_rel])

  frames = len(motion["joint_pos"])
  print(f"CLIP_PATH_{clip_path}")
  print(f"CLIP_FRAMES_{frames}")
  print(f"CLIP_FPS_{int(motion['fps'])}")
  print(f"CLIP_BODIES_{len(motion['body_names'])}")
  print(f"CLIP_JOINTS_{len(motion['joint_names'])}")
  print(f"CLIP_BODY0_Z_{float(motion['body_pos_w'][0, 0, 2]):.6f}")
  print(f"CLIP_ZMIN_MIN_{float(np.min(motion['z_min'])):.6f}")
  print(f"CLIP_FOOT_DIST_MIN_{float(np.min(motion['foot_dist'])):.6f}")
  print(f"CLIP_HOURS_{hours:.8f}")
  print(f"SUBSET_PATH_{subset_path}")
  print("SMOKE_CLIP_OK")


if __name__ == "__main__":
  main()
