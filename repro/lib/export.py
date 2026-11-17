#!/usr/bin/env python3
"""repro/lib/export.py — the decision base of the ONNX export / parity gate
(slice S07).

Standard library ONLY (argparse / hashlib / os / re / sys).  The python3 on the
PATH inside the ros_dev container has NO numpy, and the project venv is not
guaranteed to be alive, so every decision used by the export orchestrator
(`repro/19_export.sh`) and by the read-only independent verifier
(`repro/20_export_verify.sh`) lives here, as a pure function that can be
driven offline by fixtures.

Why a pure-function library (project convention, see MEM059 / P001):
the shell used to parse the very same numbers in awk/grep while python
parsed them again -> two parsers drifted.  Here there is exactly ONE
parser; `repro/lib/export.sh` is a thin wrapper that only selects the
interpreter and forwards arguments.

Upstream artefacts this module reads (see deploy/export_onnx.py):

  MANIFEST.txt   parity line, written as
                   "  {robot:6s} max |ONNX - PyTorch|  motion 6.2e-06  human 5.2e-06"
                 file digest list, written as
                   "  {digest}  {name}"
  SHA256SUMS     one "<digest>  <name>" line per exported file
                 (policy.onnx and <robot>.json -- MANIFEST.txt is NOT covered)

Pure functions
  parse_manifest_parity(text)   -> (parity, status)
  parse_sha256sums(text)        -> {name: digest}
  sha256_file(path)             -> hex digest
  verify_export_dir(out_dir, robot, atol=1e-4) -> (ok, reason, facts)
  format_verify_ok(facts)       -> str   (EXPORT_VERIFY_OK ...)
  format_verify_fail(reason, facts) -> str (EXPORT_VERIFY_FAIL reason=...)
  format_report_lines(facts)    -> [str] (EXPORT_REPORT_* ...)

Thin CLI (for the shell wrappers):
  export.py verify --out-dir DIR --robot ROBOT [--atol 1e-4]
  export.py report --out-dir DIR --robot ROBOT [--atol 1e-4]

Exit code 0 == the decision is positive; 1 == the decision is negative (the
fixed reason set is printed on stdout as `reason=...`).
"""

import argparse
import hashlib
import os
import re
import sys

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------

#: Default parity tolerance.  Upstream deploy/export_onnx.py uses PARITY_ATOL
#: = 1e-4 as well; our gate must not be laxer than upstream.
DEFAULT_ATOL = 1e-4

#: The four artefacts every export directory must contain.
POLICY_ONNX = "policy.onnx"
MANIFEST_NAME = "MANIFEST.txt"
SHA256SUMS_NAME = "SHA256SUMS"

#: The fixed failure-reason set.  Every negative path must use one of these.
REASONS = (
  "missing-file",
  "empty-file",
  "manifest-parse-failed",
  "parity-over-tol",
  "sha-missing",
  "sha-mismatch",
  "robot-mismatch",
)

#: A manifest parity line: two leading spaces, the robot name, the fixed
#: marker, then whitespace separated "<interface> <value>" pairs.
_RE_PARITY = re.compile(
  r"^\s*(?P<robot>\S+)\s+max\s+\|ONNX\s*-\s*PyTorch\|\s*(?P<rest>.*)$")

#: The name of an interface inside a parity line.
_RE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

#: A "<digest>  <name>" line (GNU coreutils format; the optional '*' marks
#: binary mode).
_RE_SHA = re.compile(r"^(?P<digest>[0-9a-fA-F]{64})\s+\*?(?P<name>\S.*?)\s*$")

#: A source-checkpoint line: "  g1_amber logs/train/g1_amber_1h/ckpt_26413.pt"
_RE_CKPT = re.compile(r"^\s*(?P<robot>\S+)\s+(?P<path>\S+\.pt)\s*$")


# --------------------------------------------------------------------------
# parsing helpers
# --------------------------------------------------------------------------


def _to_float(text):
  """Return a finite float, or None when the text is not a finite number."""
  try:
    value = float(text)
  except (TypeError, ValueError):
    return None
  if value != value or value in (float("inf"), float("-inf")):
    return None
  return value


def parse_manifest_parity(text):
  """Parse the parity block of an upstream MANIFEST.txt.

  Returns a tuple (parity, status)

    parity  {robot: {interface: max_abs_diff}}   (empty dict when status != ok)
    status  "ok"               -- at least one parity line was parsed
            "no-parity-line"   -- no line matching the parity marker at all
            "malformed-parity-line" -- a parity marker line exists but its
                                    "<interface> <value>" pairs do not parse

  The two negative statuses are kept apart on purpose: "the manifest has no
  parity block" and "the manifest has a broken parity block" are different
  defects and the caller may want to report them differently.
  """
  parity = {}
  status = "no-parity-line"
  malformed = False
  if not text or not isinstance(text, str):
    return parity, status
  for raw in text.splitlines():
    line = raw.rstrip()
    if not line.strip():
      continue
    match = _RE_PARITY.match(line)
    if not match:
      continue
    robot = match.group("robot")
    rest = match.group("rest").strip()
    interfaces = _parse_parity_pairs(rest)
    if not interfaces:
      # a broken parity line is sticky: even when other lines parse, the
      # manifest is not trustworthy -> fail closed.
      malformed = True
      continue
    parity.setdefault(robot, {}).update(interfaces)
  if malformed:
    return parity, "malformed-parity-line"
  if parity:
    status = "ok"
  return parity, status


def _parse_parity_pairs(rest):
  """Parse the "<interface> <value> ..." tail of a parity line.

  The whole tail must consist of "<interface> <value>" pairs -- a trailing
  garbage token makes the line malformed (that is the difference between
  "no parity line" and "broken parity line").
  """
  interfaces = {}
  if not rest:
    return interfaces
  tokens = rest.split()
  if len(tokens) % 2 != 0:
    return {}
  for index in range(0, len(tokens), 2):
    name = tokens[index]
    if not _RE_NAME.match(name):
      return {}
    value = _to_float(tokens[index + 1])
    if value is None:
      return {}
    interfaces[name] = value
  return interfaces


def parse_sha256sums(text):
  """Parse a GNU-style SHA256SUMS file into {name: digest}.

  Blank lines and '#' comments are ignored; lines that do not look like
  "<64 hex digest>  <name>" are ignored as well (the upstream file only
  contains such lines).  Digests are lower-cased.
  """
  result = {}
  if not text or not isinstance(text, str):
    return result
  for raw in text.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
      continue
    match = _RE_SHA.match(line)
    if not match:
      continue
    result[match.group("name").strip()] = match.group("digest").lower()
  return result


def sha256_file(path):
  """Return the hex sha256 digest of the file at `path`.

  Raises OSError when the file cannot be read -- the caller decides how to
  turn that into a fail-closed reason.
  """
  digest = hashlib.sha256()
  with open(path, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
      digest.update(chunk)
  return digest.hexdigest()


def read_text(path):
  """Read a text file, returning None when it cannot be read."""
  try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
      return handle.read()
  except OSError:
    return None


# --------------------------------------------------------------------------
# the single decision entry point
# --------------------------------------------------------------------------


def _required_names(robot):
  """The four artefact names for `robot`."""
  return [POLICY_ONNX, "%s.json" % robot, MANIFEST_NAME, SHA256SUMS_NAME]


def verify_export_dir(out_dir, robot, atol=DEFAULT_ATOL):
  """Verify an export directory.  This is the ONLY decision entry point.

  Checks (in order):
    1. the four artefacts (policy.onnx / <robot>.json / MANIFEST.txt /
       SHA256SUMS) exist            -> "missing-file"
    2. all four are non-empty       -> "empty-file"
    3. MANIFEST.txt has a parsable parity block -> "manifest-parse-failed"
    4. the parity block mentions `robot`         -> "robot-mismatch"
    5. every interface parity <= atol             -> "parity-over-tol"
    6. SHA256SUMS covers policy.onnx and <robot>.json -> "sha-missing"
    7. the recomputed digests match SHA256SUMS     -> "sha-mismatch"

  Returns (ok, reason, facts)

    ok     bool
    reason None when ok, otherwise one of REASONS
    facts  dict with the observed facts (files, sizes, parity, digests, ...)

  Fail-closed: every unreadable / unparsable artefact yields a negative
  decision, never an exception.
  """
  facts = {
    "out_dir": str(out_dir),
    "robot": robot,
    "atol": float(atol),
    "files": [],
    "sizes": {},
    "parity": {},
    "parity_max": None,
    "sha_files": {},
    "sha_checked": [],
    "manifest_status": None,
  }
  if not out_dir or not robot:
    return False, "missing-file", facts

  names = _required_names(robot)

  # 1. existence
  for name in names:
    path = os.path.join(str(out_dir), name)
    if not os.path.isfile(path):
      facts["missing"] = name
      return False, "missing-file", facts

  # 2. non-empty
  for name in names:
    path = os.path.join(str(out_dir), name)
    size = os.path.getsize(path)
    facts["sizes"][name] = size
    if size <= 0:
      facts["empty"] = name
      return False, "empty-file", facts
  facts["files"] = list(names)

  # 3. manifest parity block
  manifest_text = read_text(os.path.join(str(out_dir), MANIFEST_NAME))
  if manifest_text is None:
    return False, "manifest-parse-failed", facts
  parity, status = parse_manifest_parity(manifest_text)
  facts["manifest_status"] = status
  facts["parity"] = parity
  if status != "ok" or not parity:
    return False, "manifest-parse-failed", facts

  # 4. the requested robot must be present in the parity block
  if robot not in parity or not parity[robot]:
    facts["parity_robots"] = sorted(parity.keys())
    return False, "robot-mismatch", facts

  # 5. every interface parity must be within tolerance
  robot_parity = parity[robot]
  worst = None
  for interface in sorted(robot_parity):
    value = robot_parity[interface]
    if worst is None or value > worst:
      worst = value
  facts["parity_max"] = worst
  for interface in sorted(robot_parity):
    value = robot_parity[interface]
    if value > float(atol):
      facts["parity_over"] = "%s=%g" % (interface, value)
      return False, "parity-over-tol", facts

  # 6. SHA256SUMS must cover the two exported files
  sums_text = read_text(os.path.join(str(out_dir), SHA256SUMS_NAME))
  if sums_text is None:
    return False, "sha-missing", facts
  sums = parse_sha256sums(sums_text)
  facts["sha_files"] = dict(sums)
  for name in (POLICY_ONNX, "%s.json" % robot):
    if name not in sums:
      facts["sha_missing_entry"] = name
      return False, "sha-missing", facts

  # 7. recompute the digests
  for name in (POLICY_ONNX, "%s.json" % robot):
    try:
      digest = sha256_file(os.path.join(str(out_dir), name))
    except OSError:
      facts["sha_unreadable"] = name
      return False, "sha-mismatch", facts
    facts["sha_checked"].append(name)
    if digest != sums[name]:
      facts["sha_mismatch_file"] = name
      facts["sha_expected"] = sums[name]
      facts["sha_actual"] = digest
      return False, "sha-mismatch", facts

  return True, None, facts


# --------------------------------------------------------------------------
# output line formats (single source of truth for the shell wrappers)
# --------------------------------------------------------------------------


def format_verify_ok(facts):
  """The one-line EXPORT_VERIFY_OK marker."""
  parity_max = facts.get("parity_max")
  parity_text = "none" if parity_max is None else "%g" % parity_max
  return ("EXPORT_VERIFY_OK files=%d parity_max=%s sha_files=%d robot=%s"
          % (len(facts.get("files") or []), parity_text,
             len(facts.get("sha_checked") or []), facts.get("robot", "")))


def format_verify_fail(reason, facts=None):
  """The one-line EXPORT_VERIFY_FAIL marker (never contains an OK marker)."""
  if reason not in REASONS:
    reason = "manifest-parse-failed"
  return "EXPORT_VERIFY_FAIL reason=%s" % reason


def format_report_lines(facts, source_ckpt=None):
  """The EXPORT_REPORT_* lines (parity detail, sizes, digests, source ckpt)."""
  lines = []
  parity = facts.get("parity") or {}
  robot = facts.get("robot", "")
  robot_parity = parity.get(robot) or {}
  for interface in sorted(robot_parity):
    lines.append("EXPORT_REPORT_PARITY robot=%s interface=%s max_abs_diff=%g"
                 % (robot, interface, robot_parity[interface]))
  sizes = facts.get("sizes") or {}
  for name in sorted(sizes):
    lines.append("EXPORT_REPORT_SIZE file=%s bytes=%d" % (name, sizes[name]))
  sums = facts.get("sha_files") or {}
  for name in sorted(sums):
    lines.append("EXPORT_REPORT_SHA file=%s sha256=%s sha256_12=%s"
                 % (name, sums[name], sums[name][:12]))
  lines.append("EXPORT_REPORT_PARITY_MAX robot=%s parity_max=%g"
               % (robot, facts.get("parity_max") or 0.0))
  ckpt = source_ckpt or _source_ckpt_from_manifest(facts)
  if ckpt:
    lines.append("EXPORT_REPORT_SOURCE_CKPT path=%s" % ckpt)
  return lines


def _source_ckpt_from_manifest(facts):
  """Recover the source checkpoint path from the manifest text, if recorded."""
  text = facts.get("manifest_text")
  if not text:
    return None
  for raw in text.splitlines():
    match = _RE_CKPT.match(raw)
    if match:
      return match.group("path")
  return None


# --------------------------------------------------------------------------
# thin CLI
# --------------------------------------------------------------------------


def _cmd_verify(args):
  ok, reason, facts = verify_export_dir(args.out_dir, args.robot, args.atol)
  if ok:
    print(format_verify_ok(facts))
    return 0
  print(format_verify_fail(reason, facts))
  return 1


def _cmd_report(args):
  ok, reason, facts = verify_export_dir(args.out_dir, args.robot, args.atol)
  facts["manifest_text"] = read_text(
    os.path.join(str(args.out_dir), MANIFEST_NAME))
  for line in format_report_lines(facts):
    print(line)
  if ok:
    print(format_verify_ok(facts))
    return 0
  print(format_verify_fail(reason, facts))
  return 1


def build_parser():
  parser = argparse.ArgumentParser(
    prog="export.py",
    description="Decision base of the g1_amber ONNX export (stdlib only).")
  sub = parser.add_subparsers(dest="command")

  verify = sub.add_parser("verify", help="verify an export directory")
  verify.add_argument("--out-dir", required=True)
  verify.add_argument("--robot", required=True)
  verify.add_argument("--atol", type=float, default=DEFAULT_ATOL)
  verify.set_defaults(func=_cmd_verify)

  report = sub.add_parser("report", help="print EXPORT_REPORT_* lines")
  report.add_argument("--out-dir", required=True)
  report.add_argument("--robot", required=True)
  report.add_argument("--atol", type=float, default=DEFAULT_ATOL)
  report.set_defaults(func=_cmd_report)

  return parser


def main(argv=None):
  parser = build_parser()
  args = parser.parse_args(argv)
  if not getattr(args, "func", None):
    parser.print_help()
    return 2
  return args.func(args)


if __name__ == "__main__":
  sys.exit(main())
