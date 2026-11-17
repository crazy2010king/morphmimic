#!/usr/bin/env python3
"""repro/tests/test_deploy.py — offline unit tests of the deployment
verification decision base (repro/lib/deploy.py, slice S08).

Standard library only (unittest / tempfile / json / csv / os / zipfile).  No
network, no container, no numpy: the decision base must run with the
container's system python3 (3.10).

Every negative path of the fixed reason set is asserted, plus the positive
paths (a healthy summary, a healthy eval CSV, a healthy assets directory, a
healthy official directory, a healthy session and a healthy comparison
table).

Run locally:   python3 repro/tests/test_deploy.py
"""

import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(
  os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import deploy  # noqa: E402  (path set up above)

SUMMARY = {
  "robot": "g1_amber",
  "clip": "walk_forward_start_001__A021",
  "frames": 178,
  "result": "completed",
  "joint_err_rms_rad": 0.0312,
  "body_err_mean_m": 0.0417,
  "end_drift_m": 0.0553,
  "video": "",
}

EVAL_HEADER = "name,frames,failed,fail_frame,norm_return,steps"


def write_summary(root, payload=None, name="summary.json"):
  """Write a sim2sim summary JSON; returns its path."""
  os.makedirs(root, exist_ok=True)
  path = os.path.join(root, name)
  with open(path, "w", encoding="utf-8") as handle:
    if isinstance(payload, str):
      handle.write(payload)
    else:
      json.dump(payload if payload is not None else SUMMARY, handle)
  return path


def write_eval_csv(root, rows=2, failed=("False", "False"), name="eval.csv",
                   header=EVAL_HEADER):
  """Write a per-clip eval CSV; returns its path."""
  os.makedirs(root, exist_ok=True)
  path = os.path.join(root, name)
  with open(path, "w", encoding="utf-8", newline="") as handle:
    handle.write(header + "\n")
    for index in range(rows):
      flag = failed[index] if index < len(failed) else "False"
      handle.write("clip_%03d,178,%s,-1,0.5,178\n" % (index, flag))
  return path


def write_npy_member(archive, name, values, shape=None):
  """Write a minimal .npy member into an open zip archive."""
  shape = shape if shape is not None else (len(values),)
  shape_text = "(" + "".join("%d, " % dim for dim in shape) + ")"
  header = ("{'descr': '<f8', 'fortran_order': False, 'shape': %s, }"
            % shape_text)
  header_bytes = header.encode("latin-1")
  pad = (64 - ((10 + len(header_bytes) + 1) % 64)) % 64
  header_bytes += b" " * pad + b"\n"
  data = struct.pack("<%dd" % len(values), *values)
  archive.writestr(name, b"\x93NUMPY" + bytes([1, 0]) +
                   struct.pack("<H", len(header_bytes)) + header_bytes + data)


def write_session(root, name="session.npz", members=("t_ns.npy", "body.npy",
                                                      "buttons.npy")):
  """Write a fake PICO recording (an npz); returns its path."""
  os.makedirs(root, exist_ok=True)
  path = os.path.join(root, name)
  with zipfile.ZipFile(path, "w") as archive:
    for member in members:
      write_npy_member(archive, member, [0.0, 1.0, 2.0])
  return path


def write_pico_session(root, name="session.npz", samples=3, body=(24, 7),
                        buttons=(5,)):
  """Write a PICO recording with the REAL array shapes (body [N,24,7])."""
  os.makedirs(root, exist_ok=True)
  path = os.path.join(root, name)
  with zipfile.ZipFile(path, "w") as archive:
    count = samples
    for dim in body:
      count *= dim
    write_npy_member(archive, "body.npy", [0.0] * count, shape=(samples,) + body)
    write_npy_member(archive, "t_ns.npy", [0.0] * samples, shape=(samples,))
    write_npy_member(archive, "buttons.npy", [0.0] * (samples * buttons[0]),
                     shape=(samples,) + buttons)
  return path


def write_official_dir(root, names=("policy.onnx", "g1_amber.json")):
  """Write a fake official policy directory; returns its path."""
  os.makedirs(root, exist_ok=True)
  lines = []
  for name in names:
    payload = ("fake content of %s\n" % name).encode("utf-8")
    with open(os.path.join(root, name), "wb") as handle:
      handle.write(payload)
    import hashlib
    lines.append("%s  %s" % (hashlib.sha256(payload).hexdigest(), name))
  with open(os.path.join(root, "SHA256SUMS"), "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
  return root


def write_assets_dir(root, clips=2):
  """Write a fake export_assets directory; returns its path."""
  os.makedirs(os.path.join(root, "clips", "g1_amber"), exist_ok=True)
  with open(os.path.join(root, "g1_amber.xml"), "w", encoding="utf-8") as handle:
    handle.write("<mujoco/>\n")
  for index in range(clips):
    with open(os.path.join(root, "clips", "g1_amber", "clip_%03d.npz" % index),
              "wb") as handle:
      handle.write(b"fake npz bytes")
  return root


class TempCase(unittest.TestCase):

  def setUp(self):
    self.tmp = tempfile.mkdtemp(prefix="deploy-test-")
    self.addCleanup(shutil.rmtree, self.tmp, True)


class ParseSimSummaryTest(TempCase):

  def test_healthy_summary(self):
    path = write_summary(self.tmp)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(reason)
    self.assertEqual(facts["robot"], "g1_amber")
    self.assertEqual(facts["frames"], 178)
    self.assertEqual(facts["result"], "completed")
    self.assertAlmostEqual(facts["joint_err_rms_rad"], 0.0312)
    self.assertAlmostEqual(facts["body_err_mean_m"], 0.0417)
    self.assertAlmostEqual(facts["end_drift_m"], 0.0553)

  def test_missing_file(self):
    facts, reason = deploy.parse_sim_summary(os.path.join(self.tmp, "nope.json"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-missing")

  def test_broken_json(self):
    path = write_summary(self.tmp, payload="{not json")
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-parse-failed")

  def test_json_is_not_an_object(self):
    path = write_summary(self.tmp, payload="[1, 2, 3]")
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-parse-failed")

  def test_missing_field(self):
    payload = dict(SUMMARY)
    del payload["end_drift_m"]
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-field-missing")

  def test_none_value_is_empty(self):
    payload = dict(SUMMARY)
    payload["joint_err_rms_rad"] = None
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_nan_value_is_empty(self):
    payload = dict(SUMMARY)
    payload["end_drift_m"] = float("nan")
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_infinite_value_is_empty(self):
    payload = dict(SUMMARY)
    payload["body_err_mean_m"] = float("inf")
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_empty_string_value_is_empty(self):
    payload = dict(SUMMARY)
    payload["result"] = "   "
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_non_numeric_value_is_empty(self):
    payload = dict(SUMMARY)
    payload["joint_err_rms_rad"] = "not a number"
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_replay_fields_contract(self):
    payload = {"robot": "g1_amber", "mode": "teleop", "steps": 700}
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.parse_sim_summary(path, required=deploy.REPLAY_FIELDS)
    self.assertIsNone(reason)
    self.assertEqual(facts["steps"], 700)


class CheckVideoTest(TempCase):

  def test_missing_video(self):
    self.assertEqual(
      deploy.check_video(os.path.join(self.tmp, "none.mp4")), "video-missing")

  def test_empty_video(self):
    path = os.path.join(self.tmp, "empty.mp4")
    open(path, "wb").close()
    self.assertEqual(deploy.check_video(path), "video-empty")

  def test_non_empty_video(self):
    path = os.path.join(self.tmp, "clip.mp4")
    with open(path, "wb") as handle:
      handle.write(b"fake mp4 bytes")
    self.assertIsNone(deploy.check_video(path))

  def test_none_path(self):
    self.assertEqual(deploy.check_video(None), "video-missing")


class ReadEvalCsvTest(TempCase):

  def test_healthy_csv(self):
    path = write_eval_csv(self.tmp, rows=3)
    parsed, reason = deploy.read_eval_csv(path)
    self.assertIsNone(reason)
    header, rows = parsed
    self.assertEqual(header[0], "name")
    self.assertEqual(len(rows), 3)

  def test_missing_csv(self):
    parsed, reason = deploy.read_eval_csv(os.path.join(self.tmp, "none.csv"))
    self.assertIsNone(parsed)
    self.assertEqual(reason, "eval-csv-missing")

  def test_header_without_the_required_columns(self):
    path = write_eval_csv(self.tmp, rows=1, header="name,frames")
    parsed, reason = deploy.read_eval_csv(path)
    self.assertIsNone(parsed)
    self.assertEqual(reason, "eval-csv-parse-failed")

  def test_empty_file(self):
    path = os.path.join(self.tmp, "empty.csv")
    open(path, "w").close()
    parsed, reason = deploy.read_eval_csv(path)
    self.assertIsNone(parsed)
    self.assertEqual(reason, "eval-csv-parse-failed")


class EvalCompletionTest(unittest.TestCase):

  def test_no_failures(self):
    rows = [{"failed": "False"}, {"failed": "False"}]
    self.assertEqual(deploy.eval_completion(rows), (2, 0, 1.0))

  def test_one_failure(self):
    rows = [{"failed": "True"}, {"failed": "False"}, {"failed": "False"},
            {"failed": "False"}]
    clips, failures, completion = deploy.eval_completion(rows)
    self.assertEqual((clips, failures), (4, 1))
    self.assertAlmostEqual(completion, 0.75)

  def test_case_and_whitespace_are_tolerated(self):
    rows = [{"failed": " true "}, {"failed": "FALSE"}, {"failed": "False"}]
    clips, failures, completion = deploy.eval_completion(rows)
    self.assertEqual((clips, failures), (3, 1))
    self.assertAlmostEqual(completion, 2.0 / 3.0)

  def test_unparsable_value_fails_closed(self):
    rows = [{"failed": "maybe"}, {"failed": "False"}]
    _clips, failures, _completion = deploy.eval_completion(rows)
    self.assertEqual(failures, 1)

  def test_empty_table(self):
    self.assertEqual(deploy.eval_completion([]), (0, 0, 0.0))


class CsvRowCountTest(TempCase):

  def test_counts_the_data_rows(self):
    path = write_eval_csv(self.tmp, rows=4)
    self.assertEqual(deploy.csv_row_count(path), 4)

  def test_missing_file_is_zero(self):
    self.assertEqual(deploy.csv_row_count(os.path.join(self.tmp, "x.csv")), 0)


class BuildCompareCsvTest(unittest.TestCase):

  def test_header_is_the_fixed_one(self):
    text = deploy.build_compare_csv([], [])
    self.assertEqual(text.splitlines()[0], ",".join(deploy.COMPARE_COLUMNS))

  def test_deltas_are_self_minus_official(self):
    mine = [{"clip": "a", "frames": 10, "result": "completed",
             "joint_err_rms_rad": 0.5, "body_err_mean_m": 0.75,
             "end_drift_m": 0.25}]
    theirs = [{"clip": "a", "frames": 10, "result": "completed",
               "joint_err_rms_rad": 0.25, "body_err_mean_m": 0.25,
               "end_drift_m": 0.125}]
    text = deploy.build_compare_csv(mine, theirs)
    row = text.splitlines()[1].split(",")
    self.assertAlmostEqual(float(row[10]), 0.25)  # delta_joint_err_rms_rad
    self.assertAlmostEqual(float(row[11]), 0.5)  # delta_body_err_mean_m
    self.assertAlmostEqual(float(row[12]), 0.125)  # delta_end_drift_m
    self.assertEqual(row[3], "0.5")  # self_joint_err_rms_rad
    self.assertEqual(row[7], "0.25")  # official_joint_err_rms_rad

  def test_only_the_clips_of_both_sides_are_kept(self):
    mine = [{"clip": "a", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
             "end_drift_m": 1.0},
            {"clip": "b", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
             "end_drift_m": 1.0}]
    theirs = [{"clip": "a", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
               "end_drift_m": 1.0},
              {"clip": "c", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
               "end_drift_m": 1.0}]
    text = deploy.build_compare_csv(mine, theirs)
    lines = text.splitlines()
    self.assertEqual(len(lines), 2)  # the header plus one clip
    self.assertTrue(lines[1].startswith("a,"))

  def test_rows_are_sorted_by_clip_name(self):
    mine = [{"clip": "z", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
             "end_drift_m": 1.0},
            {"clip": "a", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
             "end_drift_m": 1.0}]
    theirs = list(mine)
    lines = deploy.build_compare_csv(mine, theirs).splitlines()
    self.assertTrue(lines[1].startswith("a,"))
    self.assertTrue(lines[2].startswith("z,"))

  def test_a_missing_metric_leaves_the_delta_empty(self):
    mine = [{"clip": "a", "joint_err_rms_rad": 1.0, "body_err_mean_m": None,
             "end_drift_m": 1.0}]
    theirs = [{"clip": "a", "joint_err_rms_rad": 1.0, "body_err_mean_m": 1.0,
               "end_drift_m": 1.0}]
    row = deploy.build_compare_csv(mine, theirs).splitlines()[1].split(",")
    self.assertEqual(row[11], "")  # delta_body_err_mean_m


class FormatMarkerTest(unittest.TestCase):

  def test_ok_marker(self):
    self.assertEqual(deploy.format_ok("DEPLOY_VERIFY", files=4, clips=490),
                     "DEPLOY_VERIFY_OK files=4 clips=490")

  def test_fail_marker(self):
    self.assertEqual(deploy.format_fail("DEPLOY_EVAL", "eval-csv-missing"),
                     "DEPLOY_EVAL_FAIL reason=eval-csv-missing")

  def test_unknown_reason_is_normalised(self):
    line = deploy.format_fail("DEPLOY_EVAL", "not-a-reason")
    self.assertIn("reason=", line)
    self.assertNotIn("not-a-reason", line)

  def test_the_fail_marker_never_carries_an_ok_marker(self):
    self.assertNotIn("_OK", deploy.format_fail("DEPLOY_SIM", "summary-missing"))


class VerifySimSummariesTest(TempCase):

  def test_healthy_directory(self):
    root = os.path.join(self.tmp, "summaries")
    write_summary(root, name="a.json")
    write_summary(root, name="b.json")
    facts, reason = deploy.verify_sim_summaries(root, 2)
    self.assertIsNone(reason)
    self.assertEqual(facts["count"], 2)

  def test_missing_directory(self):
    facts, reason = deploy.verify_sim_summaries(os.path.join(self.tmp, "nope"), 1)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-missing")

  def test_empty_directory(self):
    root = os.path.join(self.tmp, "summaries")
    os.makedirs(root)
    facts, reason = deploy.verify_sim_summaries(root, 1)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-missing")

  def test_count_mismatch(self):
    root = os.path.join(self.tmp, "summaries")
    write_summary(root, name="a.json")
    facts, reason = deploy.verify_sim_summaries(root, 490)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-count-mismatch")

  def test_a_broken_summary_fails_the_directory(self):
    root = os.path.join(self.tmp, "summaries")
    write_summary(root, name="a.json")
    write_summary(root, payload="{oops", name="b.json")
    facts, reason = deploy.verify_sim_summaries(root, 2)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-parse-failed")

  def test_a_missing_video_fails_the_directory(self):
    root = os.path.join(self.tmp, "summaries")
    payload = dict(SUMMARY)
    payload["video"] = os.path.join(root, "gone.mp4")
    write_summary(root, payload=payload, name="a.json")
    facts, reason = deploy.verify_sim_summaries(root, 1)
    self.assertIsNone(facts)
    self.assertEqual(reason, "video-missing")


class VerifyEvalCsvTest(TempCase):

  def test_healthy_csv(self):
    path = write_eval_csv(self.tmp, rows=490)
    facts, reason = deploy.verify_eval_csv(path, 490)
    self.assertIsNone(reason)
    self.assertEqual(facts["clips"], 490)
    self.assertAlmostEqual(facts["completion"], 1.0)

  def test_missing_csv(self):
    facts, reason = deploy.verify_eval_csv(os.path.join(self.tmp, "none.csv"), 490)
    self.assertIsNone(facts)
    self.assertEqual(reason, "eval-csv-missing")

  def test_row_count_mismatch(self):
    path = write_eval_csv(self.tmp, rows=489)
    facts, reason = deploy.verify_eval_csv(path, 490)
    self.assertIsNone(facts)
    self.assertEqual(reason, "eval-row-count-mismatch")

  def test_unparsable_failed_is_counted(self):
    path = write_eval_csv(self.tmp, rows=2, failed=("False", "maybe"))
    facts, reason = deploy.verify_eval_csv(path, 2)
    self.assertIsNone(reason)
    self.assertEqual(facts["unparsable_failed"], 1)
    # fail closed: an unparsable cell counts as a failure
    self.assertEqual(facts["failures"], 1)
    self.assertAlmostEqual(facts["completion"], 0.5)

  def test_unparsable_failed_is_refused_when_required(self):
    path = write_eval_csv(self.tmp, rows=2, failed=("False", "maybe"))
    facts, reason = deploy.verify_eval_csv(path, 2, require_parseable_failed=True)
    self.assertIsNone(facts)
    self.assertEqual(reason, "eval-csv-parse-failed")

  def test_parseable_failed_passes_the_strict_check(self):
    path = write_eval_csv(self.tmp, rows=2, failed=("True", "false"))
    facts, reason = deploy.verify_eval_csv(path, 2, require_parseable_failed=True)
    self.assertIsNone(reason)
    self.assertEqual(facts["unparsable_failed"], 0)
    self.assertEqual(facts["failures"], 1)


class ParseFailedCellTest(unittest.TestCase):

  def test_booleans_and_text(self):
    self.assertIs(deploy.parse_failed_cell(True), True)
    self.assertIs(deploy.parse_failed_cell(False), False)
    self.assertIs(deploy.parse_failed_cell("True"), True)
    self.assertIs(deploy.parse_failed_cell("  FALSE "), False)
    self.assertIsNone(deploy.parse_failed_cell("maybe"))
    self.assertIsNone(deploy.parse_failed_cell(None))
    self.assertIsNone(deploy.parse_failed_cell(""))

  def test_count_unparsable_failed(self):
    rows = [{"failed": "False"}, {"failed": "TRUE"}, {"failed": "n/a"},
            {"failed": ""}, {}]
    self.assertEqual(deploy.count_unparsable_failed(rows), 3)
    self.assertEqual(deploy.count_unparsable_failed([]), 0)


class ParseSubsetYamlTest(TempCase):

  def write_subset(self, text, name="subset.yaml"):
    path = os.path.join(self.tmp, name)
    with open(path, "w", encoding="utf-8") as handle:
      handle.write(text)
    return path

  def test_healthy_subset(self):
    path = self.write_subset(
      "root: /data/seed_g1_npz50\n"
      "hours: 1.0014\n"
      "clips:\n"
      "- 220713/a__A022.npz\n"
      "- 230301/b__A230_M.npz\n"
      "- 231117/c__A521_M.npz\n")
    info, reason = deploy.parse_subset_yaml(path)
    self.assertIsNone(reason)
    self.assertEqual(info["root"], "/data/seed_g1_npz50")
    self.assertEqual(info["hours"], "1.0014")
    self.assertEqual(len(info["clips"]), 3)
    self.assertEqual(deploy.count_subset_clips(path), 3)

  def test_missing_subset(self):
    info, reason = deploy.parse_subset_yaml(os.path.join(self.tmp, "none.yaml"))
    self.assertIsNone(info)
    self.assertEqual(reason, "subset-missing")
    self.assertEqual(deploy.count_subset_clips(
      os.path.join(self.tmp, "none.yaml")), 0)

  def test_subset_without_clips(self):
    path = self.write_subset("root: /data/seed_g1_npz50\nhours: 1.0\n")
    info, reason = deploy.parse_subset_yaml(path)
    self.assertIsNone(info)
    self.assertEqual(reason, "subset-parse-failed")

  def test_subset_with_a_stray_line(self):
    path = self.write_subset("root: /data\nclips:\n- a.npz\nnot a mapping\n")
    info, reason = deploy.parse_subset_yaml(path)
    self.assertIsNone(info)
    self.assertEqual(reason, "subset-parse-failed")

  def test_subset_with_a_stray_list_item(self):
    path = self.write_subset("root: /data\nclips:\n- a.npz\nother:\n- b.npz\n")
    info, reason = deploy.parse_subset_yaml(path)
    self.assertIsNone(info)
    self.assertEqual(reason, "subset-parse-failed")


class VerifyAssetsDirTest(TempCase):

  def test_healthy_directory(self):
    root = write_assets_dir(os.path.join(self.tmp, "assets"), clips=3)
    facts, reason = deploy.verify_assets_dir(root, 3)
    self.assertIsNone(reason)
    self.assertEqual(facts["count"], 3)

  def test_missing_directory(self):
    facts, reason = deploy.verify_assets_dir(os.path.join(self.tmp, "nope"), 1)
    self.assertIsNone(facts)
    self.assertEqual(reason, "assets-missing")

  def test_missing_xml(self):
    root = os.path.join(self.tmp, "assets")
    os.makedirs(os.path.join(root, "clips", "g1_amber"))
    with open(os.path.join(root, "clips", "g1_amber", "a.npz"), "wb") as handle:
      handle.write(b"x")
    facts, reason = deploy.verify_assets_dir(root, 1)
    self.assertIsNone(facts)
    self.assertEqual(reason, "assets-xml-missing")

  def test_missing_clips(self):
    root = os.path.join(self.tmp, "assets")
    os.makedirs(root)
    with open(os.path.join(root, "g1_amber.xml"), "w", encoding="utf-8") as handle:
      handle.write("<mujoco/>\n")
    facts, reason = deploy.verify_assets_dir(root, 1)
    self.assertIsNone(facts)
    self.assertEqual(reason, "assets-clips-missing")

  def test_clip_count_mismatch(self):
    root = write_assets_dir(os.path.join(self.tmp, "assets"), clips=2)
    facts, reason = deploy.verify_assets_dir(root, 490)
    self.assertIsNone(facts)
    self.assertEqual(reason, "assets-clips-mismatch")


class VerifyOfficialDirTest(TempCase):

  def test_healthy_directory(self):
    root = write_official_dir(os.path.join(self.tmp, "official"))
    facts, reason = deploy.verify_official_dir(root)
    self.assertIsNone(reason)
    self.assertEqual(len(facts["checked"]), 2)

  def test_missing_directory(self):
    facts, reason = deploy.verify_official_dir(os.path.join(self.tmp, "nope"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "official-dir-missing")

  def test_missing_sha256sums(self):
    root = os.path.join(self.tmp, "official")
    os.makedirs(root)
    facts, reason = deploy.verify_official_dir(root)
    self.assertIsNone(facts)
    self.assertEqual(reason, "official-sha-missing")

  def test_sha_mismatch(self):
    root = write_official_dir(os.path.join(self.tmp, "official"))
    with open(os.path.join(root, "policy.onnx"), "wb") as handle:
      handle.write(b"tampered")
    facts, reason = deploy.verify_official_dir(root)
    self.assertIsNone(facts)
    self.assertEqual(reason, "official-sha-mismatch")

  def test_missing_json(self):
    root = write_official_dir(os.path.join(self.tmp, "official"),
                               names=("policy.onnx",))
    facts, reason = deploy.verify_official_dir(root)
    self.assertIsNone(facts)
    self.assertEqual(reason, "official-json-missing")

  def test_a_listed_file_is_missing(self):
    root = write_official_dir(os.path.join(self.tmp, "official"))
    os.remove(os.path.join(root, "g1_amber.json"))
    facts, reason = deploy.verify_official_dir(root)
    self.assertIsNone(facts)
    self.assertEqual(reason, "official-sha-missing")


class VerifySessionTest(TempCase):

  def test_healthy_session(self):
    path = write_session(self.tmp)
    facts, reason = deploy.verify_session(path)
    self.assertIsNone(reason)
    self.assertEqual(len(facts["members"]), 3)

  def test_missing_session(self):
    facts, reason = deploy.verify_session(os.path.join(self.tmp, "none.npz"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-missing")

  def test_not_a_zip(self):
    path = os.path.join(self.tmp, "broken.npz")
    with open(path, "wb") as handle:
      handle.write(b"not a zip at all")
    facts, reason = deploy.verify_session(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-format-invalid")

  def test_missing_member(self):
    path = write_session(self.tmp, members=("t_ns.npy", "body.npy"))
    facts, reason = deploy.verify_session(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-format-invalid")


class VerifyReplaySummaryTest(TempCase):

  def test_healthy_replay_summary(self):
    path = write_summary(self.tmp, payload={"robot": "g1_amber", "steps": 700})
    facts, reason = deploy.verify_replay_summary(path)
    self.assertIsNone(reason)
    self.assertEqual(facts["steps"], 700)

  def test_missing_replay_summary(self):
    facts, reason = deploy.verify_replay_summary(os.path.join(self.tmp, "no.json"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "replay-summary-missing")

  def test_empty_replay_summary(self):
    path = os.path.join(self.tmp, "empty.json")
    open(path, "w").close()
    facts, reason = deploy.verify_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "replay-summary-empty")

  def test_replay_summary_without_the_replay_fields(self):
    path = write_summary(self.tmp, payload={"robot": "g1_amber"})
    facts, reason = deploy.verify_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "replay-summary-empty")


class VerifySessionArraysTest(TempCase):

  def test_healthy_pico_session(self):
    path = write_pico_session(self.tmp, samples=5)
    facts, reason = deploy.verify_session_arrays(path)
    self.assertIsNone(reason)
    self.assertEqual(facts["samples"], 5)
    self.assertEqual(facts["shapes"]["body"], (5, 24, 7))
    self.assertEqual(facts["shapes"]["buttons"], (5, 5))
    self.assertEqual(facts["shapes"]["t_ns"], (5,))

  def test_missing_session(self):
    facts, reason = deploy.verify_session_arrays(
      os.path.join(self.tmp, "none.npz"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-missing")

  def test_not_a_zip(self):
    path = os.path.join(self.tmp, "broken.npz")
    with open(path, "wb") as handle:
      handle.write(b"not a zip")
    facts, reason = deploy.verify_session_arrays(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-format-invalid")

  def test_a_wrong_body_shape_is_refused(self):
    path = write_pico_session(self.tmp, body=(24, 6))
    facts, reason = deploy.verify_session_arrays(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-shape-invalid")

  def test_an_empty_recording_is_refused(self):
    path = write_pico_session(self.tmp, samples=0)
    facts, reason = deploy.verify_session_arrays(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-shape-invalid")

  def test_a_wrong_button_width_is_refused(self):
    path = write_pico_session(self.tmp, buttons=(4,))
    facts, reason = deploy.verify_session_arrays(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "session-shape-invalid")

  def test_the_npy_shape_reader_reads_the_header(self):
    path = write_pico_session(self.tmp, samples=2)
    with zipfile.ZipFile(path) as archive:
      shape = deploy.read_npy_shape(archive.read("body.npy"))
    self.assertEqual(shape, (2, 24, 7))

  def test_the_npy_shape_reader_refuses_garbage(self):
    self.assertIsNone(deploy.read_npy_shape(b"not a npy"))


class VerifyHumanReplaySummaryTest(TempCase):

  def _payload(self, **overrides):
    payload = {"robot": "g1_amber", "mode": "teleop", "steps": 700,
               "falls": 0, "travel_along_m": 0.12, "travel_across_m": -0.03,
               "turn_deg": 1.5, "joint_err_rms_rad": None}
    payload.update(overrides)
    return payload

  def test_healthy_summary(self):
    path = write_summary(self.tmp, payload=self._payload())
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(reason)
    self.assertEqual(facts["steps"], 700)
    self.assertEqual(facts["falls"], 0)
    self.assertAlmostEqual(facts["travel_along_m"], 0.12)

  def test_a_null_joint_error_is_allowed(self):
    # under --interface human the policy node sends no reference window to
    # the sim, so the upstream summary carries joint_err_rms_rad = null
    path = write_summary(self.tmp, payload=self._payload(joint_err_rms_rad=None))
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(reason)
    self.assertIsNone(facts["joint_err_rms_rad"])

  def test_missing_summary(self):
    facts, reason = deploy.verify_human_replay_summary(
      os.path.join(self.tmp, "no.json"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "replay-summary-missing")

  def test_empty_summary(self):
    path = os.path.join(self.tmp, "empty.json")
    open(path, "w").close()
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "replay-summary-empty")

  def test_malformed_summary(self):
    path = write_summary(self.tmp, payload="{not json")
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "replay-summary-empty")

  def test_a_missing_field(self):
    payload = self._payload()
    del payload["travel_along_m"]
    path = write_summary(self.tmp, payload=payload)
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-field-missing")

  def test_an_empty_step_count(self):
    path = write_summary(self.tmp, payload=self._payload(steps=None))
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_a_zero_step_count(self):
    path = write_summary(self.tmp, payload=self._payload(steps=0))
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_a_nan_travel(self):
    path = write_summary(self.tmp, payload=self._payload(travel_along_m="nan"))
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "summary-value-empty")

  def test_a_missing_video(self):
    path = write_summary(self.tmp,
                         payload=self._payload(video=os.path.join(self.tmp, "no.mp4")))
    facts, reason = deploy.verify_human_replay_summary(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "video-missing")


class VerifyCompareCsvTest(TempCase):

  def _write(self, text, name="compare.csv"):
    path = os.path.join(self.tmp, name)
    with open(path, "w", encoding="utf-8", newline="") as handle:
      handle.write(text)
    return path

  def _good(self):
    mine = [{"clip": "a", "frames": 10, "result": "completed",
             "joint_err_rms_rad": 0.5, "body_err_mean_m": 0.6,
             "end_drift_m": 0.7}]
    theirs = [{"clip": "a", "frames": 10, "result": "completed",
               "joint_err_rms_rad": 0.2, "body_err_mean_m": 0.4,
               "end_drift_m": 0.5}]
    return deploy.build_compare_csv(mine, theirs)

  def test_healthy_table(self):
    path = self._write(self._good())
    facts, reason = deploy.verify_compare_csv(path, 1)
    self.assertIsNone(reason)
    self.assertEqual(facts["rows"], 1)

  def test_missing_table(self):
    facts, reason = deploy.verify_compare_csv(os.path.join(self.tmp, "no.csv"))
    self.assertIsNone(facts)
    self.assertEqual(reason, "compare-missing")

  def test_header_without_the_required_columns(self):
    path = self._write("clip,frames\n")
    facts, reason = deploy.verify_compare_csv(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "compare-parse-failed")

  def test_row_count_mismatch(self):
    path = self._write(self._good())
    facts, reason = deploy.verify_compare_csv(path, 49)
    self.assertIsNone(facts)
    self.assertEqual(reason, "compare-row-mismatch")

  def test_a_wrong_delta_is_detected(self):
    lines = self._good().splitlines()
    row = lines[1].split(",")
    row[10] = "9"  # a delta that is not self - official
    lines[1] = ",".join(row)
    path = self._write("\n".join(lines) + "\n")
    facts, reason = deploy.verify_compare_csv(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "compare-row-mismatch")

  def test_an_empty_delta_is_detected(self):
    lines = self._good().splitlines()
    row = lines[1].split(",")
    row[10] = ""
    lines[1] = ",".join(row)
    path = self._write("\n".join(lines) + "\n")
    facts, reason = deploy.verify_compare_csv(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "compare-row-mismatch")

  def test_an_empty_clip_name_is_detected(self):
    text = self._good().replace("a,10,", ",10,", 1)
    path = self._write(text)
    facts, reason = deploy.verify_compare_csv(path)
    self.assertIsNone(facts)
    self.assertEqual(reason, "compare-row-mismatch")


class CliTest(TempCase):

  def _capture(self, argv):
    import io
    import contextlib
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
      with contextlib.redirect_stderr(io.StringIO()):
        code = deploy.main(argv)
    return code, buffer.getvalue()

  def test_sim_prints_the_ok_marker(self):
    root = os.path.join(self.tmp, "summaries")
    write_summary(root, name="a.json")
    code, text = self._capture(["sim", "--dir", root, "--expect-count", "1"])
    self.assertEqual(code, 0)
    self.assertIn("DEPLOY_SIM_OK", text)

  def test_sim_prints_the_fail_marker(self):
    code, text = self._capture(
      ["sim", "--dir", os.path.join(self.tmp, "nope"), "--expect-count", "1"])
    self.assertEqual(code, 1)
    self.assertIn("DEPLOY_SIM_FAIL reason=summary-missing", text)
    self.assertNotIn("_OK", text)

  def test_eval_prints_the_completion(self):
    path = write_eval_csv(self.tmp, rows=4, failed=("True", "False", "False",
                                                    "False"))
    code, text = self._capture(["eval", "--path", path, "--expect-rows", "4"])
    self.assertEqual(code, 0)
    self.assertIn("DEPLOY_EVAL_OK", text)
    self.assertIn("failures=1", text)

  def test_compare_build_writes_the_table(self):
    mine = os.path.join(self.tmp, "self.csv")
    theirs = os.path.join(self.tmp, "official.csv")
    out = os.path.join(self.tmp, "compare.csv")
    for path, value in ((mine, 0.5), (theirs, 0.25)):
      with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write("clip,frames,result,joint_err_rms_rad,body_err_mean_m,"
                     "end_drift_m\n")
        handle.write("clip_a,178,completed,%s,%s,%s\n" % (value, value, value))
    code, _text = self._capture(
      ["compare-build", "--self-csv", mine, "--official-csv", theirs,
       "--out", out])
    self.assertEqual(code, 0)
    with open(out, "r", encoding="utf-8") as handle:
      written = handle.read()
    self.assertTrue(written.splitlines()[0].startswith("clip,frames,"))
    row = written.splitlines()[1].split(",")
    self.assertEqual(row[0], "clip_a")
    self.assertAlmostEqual(float(row[10]), 0.25)

  def test_compare_build_on_a_missing_input(self):
    code, text = self._capture(
      ["compare-build", "--self-csv", os.path.join(self.tmp, "no.csv"),
       "--official-csv", os.path.join(self.tmp, "no2.csv")])
    self.assertEqual(code, 1)
    self.assertIn("DEPLOY_VERIFY_FAIL reason=compare-missing", text)

  def test_no_command_prints_the_help(self):
    code, _text = self._capture([])
    self.assertEqual(code, 2)


class ReasonSetTest(unittest.TestCase):

  def test_every_planned_reason_is_present(self):
    planned = (
      "summary-missing", "summary-parse-failed", "summary-field-missing",
      "summary-value-empty", "video-missing", "video-empty",
      "eval-csv-missing", "eval-csv-parse-failed", "eval-row-count-mismatch",
      "assets-missing", "assets-xml-missing", "assets-clips-missing",
      "official-dir-missing", "official-sha-missing", "official-sha-mismatch",
      "official-json-missing", "compare-missing", "compare-row-mismatch",
      "session-missing", "session-format-invalid", "replay-summary-missing",
      "replay-summary-empty",
      # the human replay orchestrator (S08-T6)
      "session-shape-invalid", "deploy-dir-missing", "deploy-onnx-missing",
      "deploy-json-missing", "data-clip-missing", "mujoco-gl-unset",
      "session-make-failed", "replay-run-failed", "replay-timeout",
    )
    for reason in planned:
      self.assertIn(reason, deploy.REASONS)

  def test_the_reason_set_has_no_duplicates(self):
    self.assertEqual(len(deploy.REASONS), len(set(deploy.REASONS)))

  def test_the_module_imports_only_the_standard_library(self):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "lib", "deploy.py")
    with open(path, "r", encoding="utf-8") as handle:
      source = handle.read()
    for forbidden in ("import numpy", "import pandas", "import torch",
                      "import yaml", "from numpy", "from pandas"):
      self.assertNotIn(forbidden, source)


if __name__ == "__main__":
  unittest.main()
