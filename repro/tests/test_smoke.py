#!/usr/bin/env python3
"""Negative and edge-case tests for the smoke clip builder and the smoke env.

Run (inside the ros_dev container):
    bash repro/lib/remote.sh tests/test_smoke.sh

The tests need a CPU only (MuJoCo forward kinematics, no GPU, no network). They
cover the failure surfaces of `repro/lib/make_smoke_clip.py` and of the reader
it has to satisfy (`MotionLibrary`):

  1. the motion must carry exactly the npz key set of `convert_clip`
  2. a clip needs at least 2 frames (the reader's own rule)
  3. no NaN/inf anywhere in the motion
  4. the joint names must be the robot's native ones
  5. the tracked bodies and the root body must be in the clip
  6. the fps must be the library's fps
  7. the feet must rest on the floor, never below it
  8. the written npz + subset yaml are read back by `MotionLibrary`
  9. a 1-frame clip is rejected by the reader, not by us
 10. the foot clearance is affine in the root height (the placement maths)

Exit code 0 == all tests passed (the wrapper prints TESTS_OK).
"""

from __future__ import annotations

import copy
import shutil
import sys
import tempfile
import traceback
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from make_smoke_clip import (  # noqa: E402
  MOTION_KEYS,
  SMOKE_FPS,
  SMOKE_FRAMES,
  SMOKE_ROBOT,
  build_standing_motion,
  foot_lowest_z,
  root_height_for_feet,
  validate_motion,
  write_motion,
  write_subset,
)
from morphmimic.data.motion_library import MotionLibrary  # noqa: E402
from morphmimic.data.seed_convert import foot_geoms, make_model  # noqa: E402
from morphmimic.robots import get_robot  # noqa: E402

PASS = 0
FAIL = 0
SKIP = 0


def ok(msg: str) -> None:
  global PASS
  print(f"PASS  {msg}")
  PASS += 1


def bad(msg: str) -> None:
  global FAIL
  print(f"FAIL  {msg}")
  FAIL += 1


def skip(msg: str) -> None:
  global SKIP
  print(f"SKIP  {msg}")
  SKIP += 1


def expect_raises(msg: str, exc: type[Exception], fn) -> None:
  try:
    fn()
  except exc as e:  # noqa: BLE001
    ok(f"{msg} (raised {type(e).__name__}: {str(e)[:70]})")
    return
  except Exception as e:  # noqa: BLE001
    bad(f"{msg}: raised {type(e).__name__} instead of {exc.__name__}: {e}")
    return
  bad(f"{msg}: no error raised")


def main() -> int:
  spec = get_robot(SMOKE_ROBOT)
  model = make_model("g1")
  feet = foot_geoms(model, spec.foot_geom_regex)
  foot_geom_ids = tuple(model.geom(name).id for side in feet for name in side)
  floor_id = model.geom("floor").id

  print("--- building the real standing motion ---")
  motion = build_standing_motion(SMOKE_ROBOT, SMOKE_FRAMES)

  # --- 1) the key set -------------------------------------------------------
  try:
    validate_motion(motion, spec)
    ok("the built motion satisfies the reader's contract")
  except Exception as e:  # noqa: BLE001
    bad(f"the built motion is invalid: {e}")

  broken = copy.deepcopy(motion)
  broken.pop("foot_dist")
  expect_raises("a motion without foot_dist is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  broken = copy.deepcopy(motion)
  broken["surprise"] = np.zeros(1)
  expect_raises("a motion with an unexpected key is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  # --- 2) the frame count --------------------------------------------------
  broken = copy.deepcopy(motion)
  for key in ("joint_pos", "joint_vel"):
    broken[key] = broken[key][:1]
  expect_raises("a 1-frame motion is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  # --- 3) non-finite numbers ----------------------------------------------
  broken = copy.deepcopy(motion)
  broken["joint_pos"] = broken["joint_pos"].copy()
  broken["joint_pos"][3, 2] = np.nan
  expect_raises("a NaN in joint_pos is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  broken = copy.deepcopy(motion)
  broken["body_quat_w"] = broken["body_quat_w"].copy()
  broken["body_quat_w"][0, 0, 0] = np.inf
  expect_raises("an inf in body_quat_w is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  # --- 4) the joint names --------------------------------------------------
  broken = copy.deepcopy(motion)
  broken["joint_names"] = np.array([f"joint_{i}" for i in range(len(spec.joint_names))])
  expect_raises("foreign joint names are rejected", ValueError,
                lambda: validate_motion(broken, spec))

  # --- 5) the bodies -------------------------------------------------------
  broken = copy.deepcopy(motion)
  broken["body_names"] = np.array(["nobody"])
  expect_raises("a clip without the tracked bodies is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  # --- 6) the fps ----------------------------------------------------------
  broken = copy.deepcopy(motion)
  broken["fps"] = np.array(30, dtype=np.int64)
  expect_raises("a clip with the wrong fps is rejected", ValueError,
                lambda: validate_motion(broken, spec))

  # --- 7) the feet rest on the floor --------------------------------------
  foot_dist_min = float(np.min(motion["foot_dist"]))
  if foot_dist_min >= -1e-6:
    ok(f"the feet rest on the floor (min foot distance {foot_dist_min:.6f} m)")
  else:
    bad(f"the feet penetrate the floor by {-foot_dist_min:.6f} m")

  # --- 8) the written artefacts are read back -----------------------------
  tmp = Path(tempfile.mkdtemp(prefix="smoke-clip-test-"))
  try:
    clip_path = tmp / "smoke_stand" / "stand.npz"
    write_motion(clip_path, motion)
    subset_path = tmp / "subsets" / "smoke.yaml"
    write_subset(subset_path, tmp, SMOKE_FRAMES / SMOKE_FPS / 3600.0,
                 ["smoke_stand/stand.npz"])

    with np.load(clip_path) as z:
      keys = set(z.files)
    if keys == set(MOTION_KEYS):
      ok(f"the written npz has exactly the {len(MOTION_KEYS)} expected keys")
    else:
      bad(f"the written npz has the keys {sorted(keys)}")

    library = MotionLibrary.from_yaml(str(subset_path), device="cpu", robot=spec)
    if library.num_clips == 1 and library.joint_pos.shape == (SMOKE_FRAMES, 29):
      ok(f"the motion library reads the clip (clips={library.num_clips}, "
         f"frames={library.joint_pos.shape[0]}, joints=29)")
    else:
      bad(f"the motion library read {library.num_clips} clip(s) with shape "
          f"{tuple(library.joint_pos.shape)}")
    if library.body_pos_w.shape == (SMOKE_FRAMES, len(spec.tracked_bodies), 3):
      ok("the library holds the 14 tracked bodies of the robot")
    else:
      bad(f"the library's body tensor has shape {tuple(library.body_pos_w.shape)}")

    # --- 9) the reader rejects a 1-frame clip -----------------------------
    one_frame = tmp / "smoke_stand" / "one.npz"
    short = copy.deepcopy(motion)
    for key in ("joint_pos", "joint_vel", "body_pos_w", "body_quat_w",
                "body_lin_vel_w", "body_ang_vel_w", "z_min", "foot_dist"):
      short[key] = short[key][:1]
    write_motion(one_frame, short)
    bad_subset = tmp / "subsets" / "one.yaml"
    write_subset(bad_subset, tmp, 1 / SMOKE_FPS / 3600.0, ["smoke_stand/one.npz"])
    expect_raises("the motion library rejects a 1-frame clip", ValueError,
                  lambda: MotionLibrary.from_yaml(str(bad_subset), device="cpu",
                                                  robot=spec))
  finally:
    shutil.rmtree(tmp, ignore_errors=True)

  # --- 10) the placement maths --------------------------------------------
  from make_smoke_clip import standing_joint_pos  # noqa: PLC0415

  joint_pos = standing_joint_pos(spec)
  root_z, clearance = root_height_for_feet(model, joint_pos, foot_geom_ids, floor_id)
  if abs(clearance - 0.001) < 1e-4:
    ok(f"the root height {root_z:.4f} m puts the feet {clearance:.6f} m above the floor")
  else:
    bad(f"the root height {root_z:.4f} m leaves a clearance of {clearance:.6f} m")

  # The clearance is affine in the root height (slope 1): a root that is
  # 5 cm lower penetrates the floor, which is what the guard catches.
  from make_smoke_clip import _pose_data  # noqa: PLC0415

  lowered = _pose_data(model, np.array([0.0, 0.0, root_z - 0.05]),
                        np.array([1.0, 0.0, 0.0, 0.0]), joint_pos)
  lower_clearance = foot_lowest_z(model, lowered, foot_geom_ids, floor_id)
  if abs((lower_clearance - clearance) + 0.05) < 1e-4:
    ok("the foot clearance is affine in the root height (slope 1)")
  else:
    bad(f"the clearance moved by {lower_clearance - clearance:+.6f} m for a "
        f"-5 cm root change")

  print(f"\n{PASS} passed, {FAIL} failed, {SKIP} skipped")
  return 0 if FAIL == 0 else 1


if __name__ == "__main__":
  try:
    rc = main()
  except Exception:  # noqa: BLE001
    traceback.print_exc()
    rc = 1
  sys.exit(rc)
