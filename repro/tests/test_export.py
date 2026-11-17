#!/usr/bin/env python3
"""repro/tests/test_export.py — offline unit tests of the export decision
base (repro/lib/export.py, slice S07).

Standard library only (unittest / tempfile / hashlib / os).  No network, no
container, no numpy: the decision base must run with the container's system
python3.

Run locally:   python3 repro/tests/test_export.py
"""

import hashlib
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(
  os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import export  # noqa: E402  (path set up above)

ROBOT = "g1_amber"

MANIFEST_TEMPLATE = """\
MorphMimic export manifest
  run              g1_amber_1h
  written      2026-11-16 10:00 by deploy/export_onnx.py at deadbeef

Parity with PyTorch (each robot's own checkpoint, 64 random inputs):

  {robot:6s} max |ONNX - PyTorch|  motion {motion:.1e}  human {human:.1e}

Files (check with: sha256sum -c SHA256SUMS)

  {onnx_digest}  policy.onnx
  {json_digest}  g1_amber.json

Source checkpoints

  {robot:6s} logs/train/g1_amber_1h/ckpt_26413.pt
"""


def write_fixture(root, manifest=None, files=("policy.onnx", "g1_amber.json"),
                  sums=None, robot=ROBOT):
  """Create a fake export directory; returns (out_dir, digests)."""
  os.makedirs(root, exist_ok=True)
  digests = {}
  for name in files:
    payload = ("fake content of %s\n" % name).encode("utf-8")
    with open(os.path.join(root, name), "wb") as handle:
      handle.write(payload)
    digests[name] = hashlib.sha256(payload).hexdigest()
  if manifest is None:
    manifest = MANIFEST_TEMPLATE.format(
      robot=robot, motion=6.2e-06, human=5.2e-06,
      onnx_digest=digests.get("policy.onnx", "0" * 64),
      json_digest=digests.get("g1_amber.json", "0" * 64))
  if manifest is not False:
    with open(os.path.join(root, "MANIFEST.txt"), "w", encoding="utf-8") as h:
      h.write(manifest)
  if sums is None:
    sums = "".join("%s  %s\n" % (digests[name], name)
                   for name in ("policy.onnx", "g1_amber.json"))
  if sums is not False:
    with open(os.path.join(root, "SHA256SUMS"), "w", encoding="utf-8") as h:
      h.write(sums)
  return root, digests


class ParseManifestParityTest(unittest.TestCase):

  def test_parses_robot_and_interfaces(self):
    text = ("Parity with PyTorch:\n\n"
            "  g1_amber max |ONNX - PyTorch|  motion 6.2e-06  human 5.2e-06\n")
    parity, status = export.parse_manifest_parity(text)
    self.assertEqual(status, "ok")
    self.assertEqual(parity, {"g1_amber": {"motion": 6.2e-06,
                                            "human": 5.2e-06}})

  def test_missing_line_is_distinct_from_malformed(self):
    parity, status = export.parse_manifest_parity("nothing here\n")
    self.assertEqual(status, "no-parity-line")
    self.assertEqual(parity, {})

    parity, status = export.parse_manifest_parity(
      "  g1_amber max |ONNX - PyTorch|  motion 6.2e-06  oops\n")
    self.assertEqual(status, "malformed-parity-line")

  def test_malformed_line_is_sticky(self):
    text = ("  g1_amber max |ONNX - PyTorch|  motion 6.2e-06\n"
            "  g1_amber max |ONNX - PyTorch|  human\n")
    parity, status = export.parse_manifest_parity(text)
    self.assertEqual(status, "malformed-parity-line")

  def test_non_numeric_value_is_malformed(self):
    _, status = export.parse_manifest_parity(
      "  g1_amber max |ONNX - PyTorch|  motion not-a-number\n")
    self.assertEqual(status, "malformed-parity-line")

  def test_robot_name_is_padded_upstream(self):
    # upstream writes f"  {r:6s} max |ONNX - PyTorch|  ..." -> short names
    # are space padded; the parser must not keep the padding.
    text = "  g1     max |ONNX - PyTorch|  motion 6.2e-06\n"
    parity, status = export.parse_manifest_parity(text)
    self.assertEqual(status, "ok")
    self.assertEqual(parity, {"g1": {"motion": 6.2e-06}})

  def test_empty_text(self):
    parity, status = export.parse_manifest_parity("")
    self.assertEqual(status, "no-parity-line")
    self.assertEqual(parity, {})

  def test_non_string_input(self):
    parity, status = export.parse_manifest_parity(None)
    self.assertEqual(status, "no-parity-line")
    self.assertEqual(parity, {})


class ParseSha256SumsTest(unittest.TestCase):

  def test_parses_entries(self):
    digest = "a" * 64
    other = "b" * 64
    text = "%s  policy.onnx\n%s  g1_amber.json\n" % (digest, other)
    self.assertEqual(export.parse_sha256sums(text),
                     {"policy.onnx": digest, "g1_amber.json": other})

  def test_ignores_comments_blanks_and_garbage(self):
    digest = "c" * 64
    text = "# comment\n\n%s  policy.onnx\nnot-a-digest  x\n" % digest
    self.assertEqual(export.parse_sha256sums(text), {"policy.onnx": digest})

  def test_binary_mode_star_is_accepted(self):
    digest = "d" * 64
    text = "%s *policy.onnx\n" % digest
    self.assertEqual(export.parse_sha256sums(text), {"policy.onnx": digest})

  def test_empty_text(self):
    self.assertEqual(export.parse_sha256sums(""), {})


class Sha256FileTest(unittest.TestCase):

  def test_digest_matches_hashlib(self):
    tmp = tempfile.mkdtemp()
    try:
      path = os.path.join(tmp, "blob.bin")
      payload = b"morphmimic" * 1000
      with open(path, "wb") as handle:
        handle.write(payload)
      self.assertEqual(export.sha256_file(path),
                       hashlib.sha256(payload).hexdigest())
    finally:
      shutil.rmtree(tmp)

  def test_missing_file_raises(self):
    with self.assertRaises(OSError):
      export.sha256_file(os.path.join(tempfile.mkdtemp(), "nope"))


class VerifyExportDirTest(unittest.TestCase):

  def setUp(self):
    self.tmp = tempfile.mkdtemp()

  def tearDown(self):
    shutil.rmtree(self.tmp, ignore_errors=True)

  def _dir(self, name="out"):
    return os.path.join(self.tmp, name)

  def test_happy_path(self):
    out = self._dir()
    write_fixture(out)
    ok, reason, facts = export.verify_export_dir(out, ROBOT)
    self.assertTrue(ok, reason)
    self.assertIsNone(reason)
    self.assertEqual(len(facts["files"]), 4)
    self.assertEqual(len(facts["sha_checked"]), 2)
    self.assertAlmostEqual(facts["parity_max"], 6.2e-06)
    marker = export.format_verify_ok(facts)
    self.assertIn("EXPORT_VERIFY_OK", marker)
    self.assertIn("files=4", marker)
    self.assertIn("robot=g1_amber", marker)

  def test_parity_exactly_at_tolerance_passes(self):
    out = self._dir()
    manifest = MANIFEST_TEMPLATE.format(
      robot=ROBOT, motion=1e-04, human=1e-04,
      onnx_digest="0" * 64, json_digest="0" * 64)
    write_fixture(out, manifest=manifest)
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertTrue(ok, reason)

  def test_parity_above_tolerance_fails(self):
    out = self._dir()
    manifest = MANIFEST_TEMPLATE.format(
      robot=ROBOT, motion=1.0e-04, human=2e-04,
      onnx_digest="0" * 64, json_digest="0" * 64)
    write_fixture(out, manifest=manifest)
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "parity-over-tol")

  def test_missing_file(self):
    out = self._dir()
    write_fixture(out)
    os.remove(os.path.join(out, "policy.onnx"))
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "missing-file")

  def test_empty_file(self):
    out = self._dir()
    write_fixture(out)
    open(os.path.join(out, "g1_amber.json"), "w").close()
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "empty-file")

  def test_manifest_without_parity_line(self):
    out = self._dir()
    write_fixture(out, manifest="MorphMimic export manifest\nno parity here\n")
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "manifest-parse-failed")

  def test_manifest_with_malformed_parity_line(self):
    out = self._dir()
    write_fixture(
      out, manifest="  g1_amber max |ONNX - PyTorch|  motion oops\n")
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "manifest-parse-failed")

  def test_robot_mismatch(self):
    out = self._dir()
    manifest = MANIFEST_TEMPLATE.format(
      robot="g1_blue", motion=6.2e-06, human=5.2e-06,
      onnx_digest="0" * 64, json_digest="0" * 64)
    write_fixture(out, manifest=manifest)
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "robot-mismatch")

  def test_sha_digest_off_by_one_character_fails(self):
    out = self._dir()
    write_fixture(out)
    path = os.path.join(out, "SHA256SUMS")
    with open(path, "r", encoding="utf-8") as handle:
      text = handle.read()
    flipped = ("0" if text[0] != "0" else "1") + text[1:]
    with open(path, "w", encoding="utf-8") as handle:
      handle.write(flipped)
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "sha-mismatch")

  def test_sha_missing_policy_entry(self):
    out = self._dir()
    write_fixture(out)
    path = os.path.join(out, "SHA256SUMS")
    with open(path, "r", encoding="utf-8") as handle:
      lines = handle.readlines()
    with open(path, "w", encoding="utf-8") as handle:
      handle.writelines(line for line in lines
                        if "policy.onnx" not in line)
    ok, reason, _ = export.verify_export_dir(out, ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "sha-missing")

  def test_missing_export_dir(self):
    ok, reason, _ = export.verify_export_dir(self._dir("nope"), ROBOT)
    self.assertFalse(ok)
    self.assertEqual(reason, "missing-file")

  def test_reason_is_always_in_the_fixed_set(self):
    self.assertIn("parity-over-tol", export.REASONS)
    self.assertIn("sha-mismatch", export.REASONS)
    for bad in ("unknown", "", None):
      line = export.format_verify_fail(bad)
      self.assertIn("EXPORT_VERIFY_FAIL reason=", line)
      self.assertNotIn("EXPORT_VERIFY_OK", line)


class OutputFormatTest(unittest.TestCase):

  def test_fail_marker_never_contains_ok_marker(self):
    line = export.format_verify_fail("sha-mismatch")
    self.assertEqual(line, "EXPORT_VERIFY_FAIL reason=sha-mismatch")
    self.assertNotIn("OK", line.replace("EXPORT_VERIFY_FAIL", ""))

  def test_report_lines(self):
    tmp = tempfile.mkdtemp()
    try:
      out = os.path.join(tmp, "out")
      write_fixture(out)
      _, _, facts = export.verify_export_dir(out, ROBOT)
      with open(os.path.join(out, "MANIFEST.txt"),
                encoding="utf-8") as handle:
        facts["manifest_text"] = handle.read()
      lines = export.format_report_lines(facts)
      joined = "\n".join(lines)
      self.assertIn("EXPORT_REPORT_PARITY robot=g1_amber interface=motion",
                    joined)
      self.assertIn("EXPORT_REPORT_SIZE file=policy.onnx bytes=", joined)
      self.assertIn("EXPORT_REPORT_SHA file=policy.onnx sha256=", joined)
      self.assertIn("EXPORT_REPORT_SOURCE_CKPT", joined)
    finally:
      shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
  unittest.main()
