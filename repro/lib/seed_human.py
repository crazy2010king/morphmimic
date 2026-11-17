#!/usr/bin/env python3
"""repro/lib/seed_human.py — pure decision functions for the human50 sidecar
consistency check (slice S05).

Standard library ONLY (ast / math / os / re / sys / zipfile): the python3 on
the PATH inside the ros_dev container has no numpy/pyyaml, and the sidecar
checker must also run in a bare container (the verification scripts of S05 run
outside the project venv), so no third-party import may be used here.

The functions below are pure: they only READ files, never write, never touch
the network and never spawn a subprocess.  The whole "is the sidecar set
exactly the subset's clips and does every sidecar have the robot clip's frame
count?" decision lives here, so that it can be unit-tested offline and so that
the shell layer (repro/15_seed_human.sh, repro/16_seed_human_verify.sh) cannot
drift away from it.

Upstream contracts this module encodes (src/morphmimic/data/human_convert.py,
src/morphmimic/scripts/check_human.py):

  * a subset yaml is {"root": <abs npz root>, "hours": h, "clips": [rel paths]}
    and `load_subset` turns every clip into `<root>/<rel>`.
  * a sidecar of `<npz root>/<date>/<stem>.npz` lives at
    `<human root>/<date>/<stem>.npz`; the default human root is
    `<npz root>/human50` (that is where `MotionLibrary` looks).
  * a sidecar holds `human_pos_w [T, 24, 3]`, `human_quat_w [T, 24, 4]`,
    `human_joint_names`, `fps` (50) and `source_frames`; the robot clip holds
    `joint_pos [T, J, 3]`.  The frame count of a sidecar is
    `len(human_pos_w)` and the frame count of a robot clip is
    `len(joint_pos)`; they must be equal.

TRAP (do not use the BVH header to derive the expected frame count)
------------------------------------------------------------------
The SOMA BVH header carries `Frame Time: 0.008333`, which is 1/120 s
TRUNCATED to 6 decimals (1/120 = 0.0083333...).  Deriving the expected 50 Hz
frame count from that truncated value loses one frame for every clip whose
`(source_frames - 1)` is a multiple of 12 (40 of the 490 clips of the 1h
subset).
`bvh_header_frame_time` / `frames_from_bvh_header` exist ONLY so that the
offline unit test can prove this trap; the decision path below never calls
them.  The ONLY frame-count baseline is the robot npz's `joint_pos` length.
"""

from __future__ import annotations

import ast
import math
import os
import re
import sys
import zipfile

# The subset parser is the canonical one of slice S04 — reuse it instead of
# re-implementing the yaml subset parsing here.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
  sys.path.insert(0, _LIB_DIR)

from seed_npz import subset_spec  # noqa: E402  (stdlib-only sibling module)

__all__ = [
  "subset_spec",
  "clip_rel_paths",
  "sidecar_rel_path",
  "expected_sidecars",
  "actual_sidecars",
  "diff_sets",
  "npz_array_shape",
  "robot_frames",
  "sidecar_frames",
  "bvh_header_frame_time",
  "frames_from_bvh_header",
  "compare_frames",
  "same_root",
]

#: The upstream default sidecar root, relative to the npz root.
HUMAN_ROOT_NAME = "human50"

#: The upstream output frame rate of a sidecar.
SIDECAR_FPS = 50

#: The upstream source frame rate of a SOMA BVH.
SOMA_FPS = 120

_NPY_MAGIC = b"\x93NUMPY"
_FRAME_TIME_RE = re.compile(r"Frame\s+Time\s*:\s*([0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)")


# --------------------------------------------------------------------------
# subset / paths
# --------------------------------------------------------------------------


def clip_rel_paths(spec):
  """The subset's clip paths, relative to the npz root.

  `spec` is a subset spec (as returned by `subset_spec`).  The paths are
  normalised (`./x` -> `x`, backslashes -> slashes) so that the set
  comparison against the sidecar root is not disturbed by cosmetics.
  """
  if not isinstance(spec, dict):
    raise ValueError("subset spec must be a dict")
  clips = spec.get("clips")
  if not isinstance(clips, list):
    raise ValueError("subset spec has no clips list")
  result = []
  for clip in clips:
    rel = str(clip).replace("\\", "/").strip()
    while rel.startswith("./"):
      rel = rel[2:]
    rel = rel.strip("/")
    if rel:
      result.append(rel)
  return result


def sidecar_rel_path(rel):
  """The sidecar path of a robot clip, relative to the sidecar root.

  `<session>/<stem>.npz` -> `<session>/<stem>.npz`: the robot npz, the SOMA
  BVH and the sidecar share the session directory name and the clip stem
  (upstream `sidecar_path`).
  """
  rel = str(rel).replace("\\", "/").strip()
  while rel.startswith("./"):
    rel = rel[2:]
  rel = rel.strip("/")
  if not rel:
    raise ValueError("empty clip path")
  head, _, name = rel.rpartition("/")
  stem, _, ext = name.rpartition(".")
  if not stem:
    raise ValueError("clip path without a file name: %r" % rel)
  sidecar_name = stem + ".npz" if ext else name
  return ("%s/%s" % (head, sidecar_name)) if head else sidecar_name


def expected_sidecars(root, clips):
  """The sidecar paths the subset implies, as absolute paths under `root`.

  `root` is the SIDECAR root (upstream default: `<npz root>/human50`) and
  `clips` are the subset's clip paths relative to the npz root.
  """
  root = os.path.abspath(str(root))
  return set(os.path.join(root, sidecar_rel_path(clip)) for clip in clips)


def actual_sidecars(root):
  """Every `*.npz` under the sidecar root, as paths relative to that root.

  The walk is recursive and deterministic (sorted); a missing root yields an
  empty set (the caller then reports the sidecars as missing).
  """
  root = str(root)
  found = set()
  if not os.path.isdir(root):
    return found
  for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
      if not name.endswith(".npz"):
        continue
      absolute = os.path.join(dirpath, name)
      found.add(os.path.relpath(absolute, root).replace("\\", "/"))
  return found


def sidecar_key(path):
  """The comparable key of a sidecar path: `<session>/<stem>.npz`.

  `expected_sidecars` yields absolute paths and `actual_sidecars` yields
  paths relative to the sidecar root; both are reduced to this key before the
  two sets are compared.
  """
  text = str(path).replace("\\", "/").rstrip("/")
  parts = [p for p in text.split("/") if p]
  if len(parts) >= 2:
    return "%s/%s" % (parts[-2], parts[-1])
  return parts[-1] if parts else text


def diff_sets(expected, actual):
  """The bidirectional difference of two sidecar sets.

  Returns `(missing, extra)` as sets of `<session>/<stem>.npz` keys:
  `missing` are the sidecars the subset implies but that do not exist,
  `extra` are the sidecars that exist but are not in the subset.
  """
  expected_keys = set(sidecar_key(p) for p in expected)
  actual_keys = set(sidecar_key(p) for p in actual)
  return (expected_keys - actual_keys, actual_keys - expected_keys)


# --------------------------------------------------------------------------
# npz reading (numpy-free)
# --------------------------------------------------------------------------


def _read_npy_header(handle):
  """Read a `.npy` header from a binary file handle (numpy-free).

  Returns the header dict {"descr": ..., "fortran_order": ..., "shape": ...}.
  """
  magic = handle.read(6)
  if magic != _NPY_MAGIC:
    raise ValueError("not a .npy file (bad magic)")
  version = handle.read(2)
  if len(version) != 2:
    raise ValueError("truncated .npy version")
  major = version[0]
  if major == 1:
    length = handle.read(2)
  else:
    length = handle.read(4)
  if len(length) not in (2, 4):
    raise ValueError("truncated .npy header length")
  header_len = int.from_bytes(length, "little")
  raw = handle.read(header_len)
  if len(raw) != header_len:
    raise ValueError("truncated .npy header")
  header = ast.literal_eval(raw.decode("latin1").strip())
  if not isinstance(header, dict):
    raise ValueError("malformed .npy header")
  return header


def npz_array_shape(path, key):
  """The shape of the array `key` of the npz file `path` (numpy-free).

  The npz is a zip archive; every member is a `.npy` stream whose header
  holds the shape.  Only the header is read.

  Raises:
    OSError: the file does not exist.
    zipfile.BadZipFile: the file is not a zip archive.
    KeyError: the npz holds no array named `key`.
    ValueError: the header is malformed.
  """
  if not os.path.isfile(str(path)):
    raise OSError("npz not found: %s" % path)
  member = "%s.npy" % key
  with zipfile.ZipFile(str(path), "r") as archive:
    names = archive.namelist()
    if member not in names:
      raise KeyError("npz %s has no array %r (members: %s)" % (path, key, ", ".join(names)))
    with archive.open(member, "r") as handle:
      header = _read_npy_header(handle)
  shape = header.get("shape")
  if shape is None:
    raise ValueError("npz %s: array %r has no shape" % (path, key))
  return tuple(int(dim) for dim in shape)


def robot_frames(npz_path):
  """The frame count of a robot clip: `len(joint_pos)`."""
  shape = npz_array_shape(npz_path, "joint_pos")
  if not shape:
    raise ValueError("robot clip %s: joint_pos is a scalar" % npz_path)
  return shape[0]


def sidecar_frames(npz_path):
  """The frame count of a sidecar: `len(human_pos_w)`."""
  shape = npz_array_shape(npz_path, "human_pos_w")
  if not shape:
    raise ValueError("sidecar %s: human_pos_w is a scalar" % npz_path)
  return shape[0]


# --------------------------------------------------------------------------
# the BVH header trap (unit-test only — NEVER on the decision path)
# --------------------------------------------------------------------------


def bvh_header_frame_time(path):
  """The `Frame Time:` value of a BVH header (float), or None when absent.

  WARNING: this is the TRUNCATED 1/120 s value (0.008333).  It exists only
  so that the offline unit test can prove that deriving the expected frame
  count from it is wrong; the decision path must not use it.
  """
  if not os.path.isfile(str(path)):
    raise OSError("bvh not found: %s" % path)
  with open(str(path), "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
      match = _FRAME_TIME_RE.search(line)
      if match:
        return float(match.group(1))
  return None


def frames_from_bvh_header(frames_in, frame_time, out_fps=SIDECAR_FPS):
  """The frame count a BVH header would imply for a resample to `out_fps`.

  This mirrors upstream `resample_poses` (t_k = k / out_fps,
  k = 0..floor(duration * out_fps)) but derives `duration` from the
  TRUNCATED `frame_time` of the header instead of the exact source rate.
  `frames_in` is the number of SOURCE frames of the BVH (120 Hz).
  With `frame_time = 0.008333` the result is one frame SHORT for every clip
  whose `(frames_in - 1)` is a multiple of 12.

  Unit-test only — the decision path never calls this.
  """
  frames_in = int(frames_in)
  frame_time = float(frame_time)
  if frames_in <= 0:
    raise ValueError("frames_in must be positive")
  if frame_time <= 0:
    raise ValueError("frame_time must be positive")
  duration = (frames_in - 1) * frame_time
  return int(math.floor(duration * out_fps + 1e-9)) + 1


# --------------------------------------------------------------------------
# frame comparison / root identity
# --------------------------------------------------------------------------


def compare_frames(npz_root, human_root, clips):
  """Compare the frame count of every clip's sidecar with the robot clip.

  `clips` are the subset's clip paths relative to `npz_root`.  The robot clip
  is read from `<npz_root>/<clip>`, the sidecar from
  `<human_root>/<sidecar_rel_path(clip)>`.

  Returns {"match": [...], "mismatch": [...], "errors": [...]} where the
  mismatch entries are {"clip", "robot_frames", "human_frames"} and the error
  entries are {"clip", "error"} (a missing sidecar or an unreadable npz).
  """
  match = []
  mismatch = []
  errors = []
  for clip in clips:
    robot_path = os.path.join(str(npz_root), clip)
    sidecar_path_ = os.path.join(str(human_root), sidecar_rel_path(clip))
    try:
      if not os.path.isfile(sidecar_path_):
        raise OSError("sidecar not found: %s" % sidecar_path_)
      robot = robot_frames(robot_path)
      human = sidecar_frames(sidecar_path_)
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as error:
      errors.append({"clip": clip, "error": str(error)})
      continue
    if robot == human:
      match.append(clip)
    else:
      mismatch.append({"clip": clip, "robot_frames": robot, "human_frames": human})
  return {"match": match, "mismatch": mismatch, "errors": errors}


def same_root(path_a, path_b):
  """True when two roots are the same directory.

  The comparison is done on the device/inode pair (not on the path strings):
  the subset yaml stores the persistent-store absolute path
  (`/home/ubuntu/work_dev/.../morphmimic-seed-data/...`) while the worktree
  reaches the same payload through another mount prefix
  (`/mnt/test_cc_dev/.../morphmimic-seed-data/...`).  The realpaths therefore
  differ while the directories are the very same one.
  """
  a = str(path_a)
  b = str(path_b)
  if not os.path.isdir(a) or not os.path.isdir(b):
    return False
  try:
    stat_a = os.stat(a)
    stat_b = os.stat(b)
  except OSError:
    return False
  if stat_a.st_dev == stat_b.st_dev and stat_a.st_ino == stat_b.st_ino:
    return True
  return os.path.realpath(a) == os.path.realpath(b)


# --------------------------------------------------------------------------
# command line interface
# --------------------------------------------------------------------------
#
# A THIN shell over the functions above so that the bash layer can reuse the
# exact same logic instead of re-implementing it.

_CLI_USAGE = """usage: seed_human.py <command> [args]

commands:
  subset <subset.yaml>
      print the subset spec (root / hours / clips)

  diff --root <npz_root> --yaml <subset.yaml> [--human-root <dir>]
      print the sidecar set comparison (sidecars / missing / extra)

  frames --root <npz_root> --yaml <subset.yaml> [--human-root <dir>]
      print the per-clip frame comparison (frames_match / mismatch)
"""


def _parse_args(argv):
  options = {"root": None, "yaml": None, "human_root": None}
  positional = []
  index = 0
  while index < len(argv):
    token = argv[index]
    if token in ("--root", "--yaml", "--human-root"):
      if index + 1 >= len(argv):
        raise ValueError("%s needs a value" % token)
      options[token[2:].replace("-", "_")] = argv[index + 1]
      index += 2
      continue
    if token.startswith("--") and "=" in token:
      key, _, value = token[2:].partition("=")
      options[key.replace("-", "_")] = value
      index += 1
      continue
    positional.append(token)
    index += 1
  return positional, options


def _resolve_roots(options):
  yaml_path = options.get("yaml")
  if not yaml_path:
    raise ValueError("--yaml is required")
  spec = subset_spec(yaml_path)
  npz_root = options.get("root") or spec["root"]
  human_root = options.get("human_root") or os.path.join(str(npz_root), HUMAN_ROOT_NAME)
  return spec, str(npz_root), str(human_root)


def _cli_subset(yaml_path):
  spec = subset_spec(yaml_path)
  print("root=%s" % spec["root"])
  print("hours=%.10f" % spec["hours"])
  print("clips=%d" % len(spec["clips"]))
  return 0


def _cli_diff(options):
  spec, npz_root, human_root = _resolve_roots(options)
  clips = clip_rel_paths(spec)
  expected = expected_sidecars(human_root, clips)
  actual = actual_sidecars(human_root)
  missing, extra = diff_sets(expected, actual)
  print("sidecars=%d" % len(actual))
  print("expected=%d" % len(expected))
  print("missing=%d" % len(missing))
  print("extra=%d" % len(extra))
  for key in sorted(missing):
    print("missing_clip=%s" % key)
  for key in sorted(extra):
    print("extra_clip=%s" % key)
  return 0


def _cli_frames(options):
  spec, npz_root, human_root = _resolve_roots(options)
  clips = clip_rel_paths(spec)
  result = compare_frames(npz_root, human_root, clips)
  print("frames_match=%d" % len(result["match"]))
  print("mismatch=%d" % len(result["mismatch"]))
  print("errors=%d" % len(result["errors"]))
  for entry in result["mismatch"]:
    print("mismatch_clip=%s robot=%d human=%d" % (
      entry["clip"], entry["robot_frames"], entry["human_frames"]))
  for entry in result["errors"]:
    print("error_clip=%s error=%s" % (entry["clip"], entry["error"]))
  return 0


def main(argv=None):
  """Entry point of the CLI. Returns the process exit code."""
  argv = list(sys.argv[1:] if argv is None else argv)
  if not argv:
    sys.stderr.write(_CLI_USAGE)
    return 2
  command = argv[0]
  positional, options = _parse_args(argv[1:])
  try:
    if command == "subset" and len(positional) == 1:
      return _cli_subset(positional[0])
    if command == "diff":
      return _cli_diff(options)
    if command == "frames":
      return _cli_frames(options)
  except ValueError as error:
    sys.stderr.write("seed_human: %s\n" % error)
    return 1
  except (OSError, KeyError, zipfile.BadZipFile) as error:
    sys.stderr.write("seed_human: %s\n" % error)
    return 1
  sys.stderr.write(_CLI_USAGE)
  return 2


if __name__ == "__main__":
  sys.exit(main())
