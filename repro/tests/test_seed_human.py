#!/usr/bin/env python3
"""repro/tests/test_seed_human.py — offline unit tests for the library-level
decisions of the human50 sidecar check (slice S05).

Standard library ONLY (unittest / ast / os / shutil / tempfile / zipfile).
No network, no GPU, no 150 GB payload: every fixture is created on the fly in
a tempfile.mkdtemp() directory and removed afterwards.  The repository's real
payload (`data/`) and its logs are NEVER read.

The fake `.npz` files are written with `zipfile` + hand-written `.npy`
headers, because the container's system python3 has NO numpy — and the
sidecar checker must therefore stay importable with the bare interpreter.

Covered decisions:
  * the sidecar set equals the subset set        (missing=0, extra=0)
  * one sidecar missing                           (missing=1)
  * one sidecar too many                          (extra=1)
  * one sidecar one frame short                   (frames mismatch)
  * the BVH header trap                           (0.008333 -> a DIFFERENT
    frame count than the real one; the decision path must not use it)
  * the root identity                             (same root vs. two different
    roots)

Run locally:  python3 repro/tests/test_seed_human.py
"""

from __future__ import annotations

import ast
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(
  0,
  os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"),
)

import seed_human  # noqa: E402


# --------------------------------------------------------------------------
# fixture helpers (stdlib only)
# --------------------------------------------------------------------------


def npy_bytes(shape, descr="<f4"):
  """The bytes of a `.npy` file with the given shape (no numpy involved)."""
  header = "{'descr': '%s', 'fortran_order': False, 'shape': (%s), }" % (
    descr,
    ", ".join(str(int(dim)) for dim in shape),
  )
  prefix = 6 + 2 + 2
  pad = 64 - ((prefix + len(header) + 1) % 64)
  if pad == 64:
    pad = 0
  header = header + " " * pad + "\n"
  count = 1
  for dim in shape:
    count *= int(dim)
  body = b"\x00" * (count * 4)
  return (
    b"\x93NUMPY"
    + bytes([1, 0])
    + len(header).to_bytes(2, "little")
    + header.encode("latin1")
    + body
  )


def write_npz(path, arrays):
  """Write a fake `.npz` holding the given {name: shape} arrays."""
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
    for name, shape in arrays.items():
      archive.writestr(name + ".npy", npy_bytes(shape))
  return path


def write_bvh(path, frame_time="0.008333", frames=121):
  """Write a fake SOMA BVH header (only the header is ever read)."""
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with open(path, "w", encoding="utf-8") as handle:
    handle.write("HIERARCHY\n")
    handle.write("MOTION\n")
    handle.write("Frames: %d\n" % frames)
    handle.write("Frame Time: %s\n" % frame_time)
  return path


def write_subset_yaml(path, root, hours, clips):
  """Write a subset yaml in the upstream layout."""
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with open(path, "w", encoding="utf-8") as handle:
    handle.write("root: %s\n" % root)
    handle.write("hours: %.10f\n" % hours)
    handle.write("clips:\n")
    for clip in clips:
      handle.write("- %s\n" % clip)
  return path


class HumanFixture(object):
  """A synthetic npz root / sidecar root / subset yaml / BVH tree."""

  def __init__(self, clips=(("220713", "clip_a", 121), ("230301", "clip_b", 100))):
    self.tmp = tempfile.mkdtemp(prefix="seed_human_test_")
    self.npz_root = os.path.join(self.tmp, "npz")
    self.human_root = os.path.join(self.npz_root, "human50")
    self.bvh_root = os.path.join(self.tmp, "bvh")
    self.yaml_path = os.path.join(self.npz_root, "subsets", "1h.yaml")
    self.rel_clips = []
    for session, stem, frames in clips:
      rel = "%s/%s.npz" % (session, stem)
      self.rel_clips.append(rel)
      write_npz(
        os.path.join(self.npz_root, rel), {"joint_pos": (frames, 29, 3)}
      )
      write_npz(
        os.path.join(self.human_root, rel), {"human_pos_w": (frames, 24, 3)}
      )
      write_bvh(os.path.join(self.bvh_root, "%s/%s.bvh" % (session, stem)))
    write_subset_yaml(self.yaml_path, self.npz_root, 0.5, self.rel_clips)

  def spec(self):
    return seed_human.subset_spec(self.yaml_path)

  def cleanup(self):
    shutil.rmtree(self.tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# tests
# --------------------------------------------------------------------------


class SeedHumanLibraryTest(unittest.TestCase):

  def setUp(self):
    self.fixture = HumanFixture()
    self.addCleanup(self.fixture.cleanup)

  # -- the positive set decision ------------------------------------------

  def test_subset_spec_reads_root_hours_and_clips(self):
    spec = self.fixture.spec()
    self.assertEqual(spec["clips"], self.fixture.rel_clips)
    self.assertAlmostEqual(spec["hours"], 0.5, places=6)
    self.assertEqual(spec["root"], self.fixture.npz_root)

  def test_matching_sidecar_set_has_no_missing_and_no_extra(self):
    spec = self.fixture.spec()
    clips = seed_human.clip_rel_paths(spec)
    expected = seed_human.expected_sidecars(self.fixture.human_root, clips)
    actual = seed_human.actual_sidecars(self.fixture.human_root)
    missing, extra = seed_human.diff_sets(expected, actual)
    self.assertEqual(missing, set())
    self.assertEqual(extra, set())
    self.assertEqual(len(actual), 2)

  def test_sidecar_rel_path_keeps_session_and_stem(self):
    self.assertEqual(
      seed_human.sidecar_rel_path("220713/clip_a.npz"), "220713/clip_a.npz"
    )
    self.assertEqual(
      seed_human.sidecar_rel_path("./220713/clip_a.npz"), "220713/clip_a.npz"
    )

  # -- the negative set decisions -----------------------------------------

  def test_one_missing_sidecar_is_reported(self):
    spec = self.fixture.spec()
    clips = seed_human.clip_rel_paths(spec)
    victim = os.path.join(self.fixture.human_root, self.fixture.rel_clips[1])
    os.remove(victim)
    expected = seed_human.expected_sidecars(self.fixture.human_root, clips)
    actual = seed_human.actual_sidecars(self.fixture.human_root)
    missing, extra = seed_human.diff_sets(expected, actual)
    self.assertEqual(len(missing), 1)
    self.assertEqual(extra, set())
    self.assertIn("230301/clip_b.npz", missing)

  def test_one_extra_sidecar_is_reported(self):
    spec = self.fixture.spec()
    clips = seed_human.clip_rel_paths(spec)
    write_npz(
      os.path.join(self.fixture.human_root, "220713", "clip_extra.npz"),
      {"human_pos_w": (10, 24, 3)},
    )
    expected = seed_human.expected_sidecars(self.fixture.human_root, clips)
    actual = seed_human.actual_sidecars(self.fixture.human_root)
    missing, extra = seed_human.diff_sets(expected, actual)
    self.assertEqual(missing, set())
    self.assertEqual(len(extra), 1)
    self.assertIn("220713/clip_extra.npz", extra)

  # -- the frame decisions -------------------------------------------------

  def test_matching_frame_counts_are_reported_as_a_match(self):
    spec = self.fixture.spec()
    clips = seed_human.clip_rel_paths(spec)
    result = seed_human.compare_frames(
      self.fixture.npz_root, self.fixture.human_root, clips
    )
    self.assertEqual(len(result["match"]), 2)
    self.assertEqual(result["mismatch"], [])
    self.assertEqual(result["errors"], [])

  def test_one_short_sidecar_is_a_frame_mismatch(self):
    spec = self.fixture.spec()
    clips = seed_human.clip_rel_paths(spec)
    write_npz(
      os.path.join(self.fixture.human_root, self.fixture.rel_clips[1]),
      {"human_pos_w": (99, 24, 3)},
    )
    result = seed_human.compare_frames(
      self.fixture.npz_root, self.fixture.human_root, clips
    )
    self.assertEqual(len(result["match"]), 1)
    self.assertEqual(len(result["mismatch"]), 1)
    self.assertEqual(result["mismatch"][0]["robot_frames"], 100)
    self.assertEqual(result["mismatch"][0]["human_frames"], 99)

  def test_a_missing_sidecar_is_an_error_not_a_match(self):
    spec = self.fixture.spec()
    clips = seed_human.clip_rel_paths(spec)
    os.remove(os.path.join(self.fixture.human_root, self.fixture.rel_clips[0]))
    result = seed_human.compare_frames(
      self.fixture.npz_root, self.fixture.human_root, clips
    )
    self.assertEqual(len(result["match"]), 1)
    self.assertEqual(len(result["errors"]), 1)
    self.assertIn("sidecar not found", result["errors"][0]["error"])

  def test_robot_and_sidecar_frame_counts_come_from_the_npz(self):
    robot = os.path.join(self.fixture.npz_root, self.fixture.rel_clips[0])
    sidecar = os.path.join(self.fixture.human_root, self.fixture.rel_clips[0])
    self.assertEqual(seed_human.robot_frames(robot), 121)
    self.assertEqual(seed_human.sidecar_frames(sidecar), 121)
    self.assertEqual(
      seed_human.npz_array_shape(robot, "joint_pos"), (121, 29, 3)
    )

  # -- the BVH header trap -------------------------------------------------

  def test_bvh_header_trap_yields_a_different_frame_count(self):
    bvh = os.path.join(self.fixture.bvh_root, "220713", "clip_a.bvh")
    frame_time = seed_human.bvh_header_frame_time(bvh)
    self.assertAlmostEqual(frame_time, 0.008333, places=6)
    # 121 source frames at 120 Hz -> 51 frames at 50 Hz with the exact rate,
    # but only 50 with the truncated header value: one frame LOST.
    trapped = seed_human.frames_from_bvh_header(121, frame_time, 50)
    exact = seed_human.frames_from_bvh_header(121, 1.0 / 120.0, 50)
    self.assertEqual(exact, 51)
    self.assertEqual(trapped, 50)
    self.assertNotEqual(trapped, exact)

  def test_the_decision_path_never_calls_the_bvh_helpers(self):
    lib_path = os.path.join(
      os.path.dirname(os.path.abspath(__file__)), "..", "lib", "seed_human.py"
    )
    with open(lib_path, "r", encoding="utf-8") as handle:
      source = handle.read()
    tree = ast.parse(source)
    trap_functions = {"bvh_header_frame_time", "frames_from_bvh_header"}
    callers = {}
    for node in ast.walk(tree):
      if isinstance(node, ast.FunctionDef):
        for inner in ast.walk(node):
          if isinstance(inner, ast.Call) and isinstance(inner.func, ast.Name):
            if inner.func.id in trap_functions:
              callers.setdefault(inner.func.id, set()).add(node.name)
    for name in trap_functions:
      self.assertEqual(
        callers.get(name, set()),
        set(),
        "%s must not be used on the decision path" % name,
      )

  # -- the root identity ---------------------------------------------------

  def test_same_root_accepts_the_same_directory(self):
    self.assertTrue(seed_human.same_root(self.fixture.npz_root, self.fixture.npz_root))

  def test_same_root_rejects_two_different_directories(self):
    other = os.path.join(self.fixture.tmp, "other_root")
    os.makedirs(other, exist_ok=True)
    self.assertFalse(seed_human.same_root(self.fixture.npz_root, other))

  def test_same_root_rejects_a_missing_directory(self):
    self.assertFalse(
      seed_human.same_root(
        self.fixture.npz_root, os.path.join(self.fixture.tmp, "does_not_exist")
      )
    )


if __name__ == "__main__":
  unittest.main(verbosity=2)
