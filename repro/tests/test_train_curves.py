#!/usr/bin/env python3
"""repro/tests/test_train_curves.py — offline unit tests for the training
curve extraction (slice S09, task T1).

Standard library ONLY (unittest / json / math / os / shutil / subprocess /
sys / tempfile).  No network, no GPU, no tensorboard, no run directory:
every fixture is created on the fly in a tempfile.mkdtemp() directory and
removed afterwards.  The repository's real payload (`data/`), the real logs
(`logs/`) and `.gsd/` are NEVER read.

The container's system python3 has NO numpy — the decision base must
therefore stay importable with the bare interpreter.

Covered decisions:
  * curve_rows_from_scalars (normal, NaN/Inf encodings, malformed entries
    dropped instead of raising, ordering by (step, tag))
  * curve_summary_rows (n / first_step / last_step / min / max / mean; the
    non-finite values are counted in n but excluded from min/max/mean)
  * curve_step_coverage (min / max / n_steps / n_rows)
  * write_curve_csv / write_curve_summary_csv (atomic: no .tmp residue) and
    the read-back (read_curve_csv / read_curve_summary_csv)
  * check_curve_artifacts: the healthy case AND every negative reason
    (curve-csv-missing, curve-csv-malformed, curve-summary-mismatch,
    nan-nonwhitelist, nonfinite-steps, tag-missing, tag-count-mismatch,
    curve-step-mismatch, curve-row-count-mismatch, curve-empty)
  * the CLI of the decision base (`curves` and `curves-verify`): a healthy
    payload writes the artefacts and exits 0, a foreign NaN exits 1 with
    REASON=nan-nonwhitelist and NO OK marker.

Run locally:  python3 repro/tests/test_train_curves.py
"""

from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(
  0,
  os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"),
)

import train  # noqa: E402


TRAIN_PY = os.path.join(
  os.path.dirname(os.path.abspath(__file__)), "..", "lib", "train.py")

#: Every required tag of `train.REQUIRED_TAGS` with a finite value, plus the
#: two tags that are NaN BY DESIGN and one extra tag.
def healthy_scalars():
  scalars = {}
  for tag in train.REQUIRED_TAGS:
    if tag.endswith("nonfinite_steps"):
      scalars[tag] = [[50, 0], [100, 0]]
    else:
      scalars[tag] = [[50, 1.0], [100, 2.0]]
  scalars["kp/return"] = [[50, "nan"], [100, "nan"]]
  scalars["kp/scale_return"] = [[50, "nan"], [100, "nan"]]
  scalars["custom/tag"] = [[50, 0.0], [100, 3.0]]
  return scalars


class CurveRowTest(unittest.TestCase):

  def test_rows_are_sorted_and_complete(self):
    rows = train.curve_rows_from_scalars(healthy_scalars())
    self.assertEqual(len(rows), 24)
    self.assertEqual(rows[0][0], 50)
    self.assertEqual(rows[-1][0], 100)
    steps = [row[0] for row in rows]
    self.assertEqual(steps, sorted(steps))

  def test_nan_string_becomes_nan_float(self):
    rows = train.curve_rows_from_scalars({"kp/return": [[50, "nan"]]})
    self.assertEqual(len(rows), 1)
    self.assertTrue(math.isnan(rows[0][2]))

  def test_inf_strings_become_infinities(self):
    rows = train.curve_rows_from_scalars(
      {"t": [[1, "inf"], [2, "-inf"], [3, "Infinity"]]})
    values = [row[2] for row in rows]
    self.assertEqual(values[0], float("inf"))
    self.assertEqual(values[1], float("-inf"))
    self.assertEqual(values[2], float("inf"))

  def test_malformed_entries_are_dropped_not_raised(self):
    rows = train.curve_rows_from_scalars(
      {"t": [["x", 1.0], [1, "not-a-number"], [2, 3.0], [3]]})
    self.assertEqual(rows, [(2, "t", 3.0)])

  def test_empty_input(self):
    self.assertEqual(train.curve_rows_from_scalars({}), [])
    self.assertEqual(train.curve_rows_from_scalars(None), [])


class CurveSummaryTest(unittest.TestCase):

  def test_summary_ignores_non_finite_values(self):
    rows = train.curve_rows_from_scalars(healthy_scalars())
    summary = {row["tag"]: row for row in train.curve_summary_rows(rows)}
    self.assertEqual(summary["custom/tag"]["n"], 2)
    self.assertEqual(summary["custom/tag"]["first_step"], 50)
    self.assertEqual(summary["custom/tag"]["last_step"], 100)
    self.assertAlmostEqual(summary["custom/tag"]["min"], 0.0)
    self.assertAlmostEqual(summary["custom/tag"]["max"], 3.0)
    self.assertAlmostEqual(summary["custom/tag"]["mean"], 1.5)
    # the design NaN tag: counted, but no finite statistics
    self.assertEqual(summary["kp/return"]["n"], 2)
    self.assertIsNone(summary["kp/return"]["min"])
    self.assertIsNone(summary["kp/return"]["mean"])

  def test_summary_is_sorted_by_tag(self):
    rows = train.curve_rows_from_scalars(healthy_scalars())
    tags = [row["tag"] for row in train.curve_summary_rows(rows)]
    self.assertEqual(tags, sorted(tags))


class CurveCoverageTest(unittest.TestCase):

  def test_coverage(self):
    rows = train.curve_rows_from_scalars(healthy_scalars())
    coverage = train.curve_step_coverage(rows)
    self.assertEqual(coverage["min_step"], 50)
    self.assertEqual(coverage["max_step"], 100)
    self.assertEqual(coverage["n_steps"], 2)
    self.assertEqual(coverage["n_rows"], 24)

  def test_coverage_of_empty_curve(self):
    coverage = train.curve_step_coverage([])
    self.assertIsNone(coverage["min_step"])
    self.assertIsNone(coverage["max_step"])
    self.assertEqual(coverage["n_rows"], 0)


class CurveArtefactTest(unittest.TestCase):

  def setUp(self):
    self.dir = tempfile.mkdtemp(prefix="train_curves_")
    self.csv = os.path.join(self.dir, "g1_amber_1h_curves.csv")
    self.summary = os.path.join(self.dir, "g1_amber_1h_curves_summary.csv")
    self.rows = train.curve_rows_from_scalars(healthy_scalars())

  def tearDown(self):
    shutil.rmtree(self.dir, ignore_errors=True)

  def test_write_is_atomic_and_leaves_no_tmp(self):
    train.write_curve_csv(self.csv, self.rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(self.rows))
    self.assertTrue(os.path.isfile(self.csv))
    self.assertTrue(os.path.isfile(self.summary))
    self.assertFalse(os.path.exists(self.csv + ".tmp"))
    self.assertFalse(os.path.exists(self.summary + ".tmp"))

  def test_read_back_round_trip(self):
    train.write_curve_csv(self.csv, self.rows)
    read_back = train.read_curve_csv(self.csv)
    self.assertEqual(len(read_back), len(self.rows))
    nan_rows = [row for row in read_back if row[1] == "kp/return"]
    self.assertEqual(len(nan_rows), 2)
    self.assertTrue(all(math.isnan(row[2]) for row in nan_rows))
    parsed = train.read_curve_summary_csv(self.summary)
    self.assertIsNone(parsed)  # the summary was not written in this test

  def test_missing_and_malformed_csv(self):
    self.assertIsNone(train.read_curve_csv(os.path.join(self.dir, "nope.csv")))
    with open(self.csv, "w", encoding="utf-8") as handle:
      handle.write("step,tag\n50,x\n")
    self.assertIsNone(train.read_curve_csv(self.csv))

  def test_check_curve_artifacts_accepts_the_healthy_case(self):
    train.write_curve_csv(self.csv, self.rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(self.rows))
    ok, reasons, metrics = train.check_curve_artifacts(
      self.csv, self.summary, expected_tags=12, expected_max_step=100,
      expected_min_step=50, expected_rows=24)
    self.assertTrue(ok, reasons)
    self.assertEqual(reasons, [])
    self.assertEqual(metrics["rows"], 24)
    self.assertEqual(metrics["tags"], 12)
    self.assertEqual(metrics["max_step"], 100)
    self.assertEqual(metrics["nan_tags"], 0)
    self.assertEqual(metrics["summary_ok"], 1)

  def test_check_curve_artifacts_reports_the_missing_csv(self):
    ok, reasons, _ = train.check_curve_artifacts(
      os.path.join(self.dir, "nope.csv"))
    self.assertFalse(ok)
    self.assertEqual(reasons, ["curve-csv-missing"])

  def test_check_curve_artifacts_reports_a_malformed_csv(self):
    with open(self.csv, "w", encoding="utf-8") as handle:
      handle.write("a,b,c\n1,2,3\n")
    ok, reasons, _ = train.check_curve_artifacts(self.csv)
    self.assertFalse(ok)
    self.assertEqual(reasons, ["curve-csv-malformed"])

  def test_check_curve_artifacts_reports_a_foreign_nan(self):
    scalars = healthy_scalars()
    scalars["foreign/tag"] = [[50, "nan"], [100, "nan"]]
    rows = train.curve_rows_from_scalars(scalars)
    train.write_curve_csv(self.csv, rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(rows))
    ok, reasons, metrics = train.check_curve_artifacts(self.csv, self.summary)
    self.assertFalse(ok)
    self.assertIn("nan-nonwhitelist", reasons)
    self.assertEqual(metrics["nan_tags"], 1)

  def test_check_curve_artifacts_reports_a_nonfinite_counter(self):
    scalars = healthy_scalars()
    scalars["wm/nonfinite_steps"] = [[50, 0], [100, 3]]
    rows = train.curve_rows_from_scalars(scalars)
    train.write_curve_csv(self.csv, rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(rows))
    ok, reasons, _ = train.check_curve_artifacts(self.csv, self.summary)
    self.assertFalse(ok)
    self.assertIn("nonfinite-steps", reasons)

  def test_check_curve_artifacts_reports_a_missing_required_tag(self):
    scalars = healthy_scalars()
    del scalars["perf/it_per_s"]
    rows = train.curve_rows_from_scalars(scalars)
    train.write_curve_csv(self.csv, rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(rows))
    ok, reasons, _ = train.check_curve_artifacts(self.csv, self.summary)
    self.assertFalse(ok)
    self.assertIn("tag-missing", reasons)

  def test_check_curve_artifacts_reports_the_count_and_step_mismatches(self):
    train.write_curve_csv(self.csv, self.rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(self.rows))
    ok, reasons, _ = train.check_curve_artifacts(
      self.csv, self.summary, expected_tags=99, expected_rows=1,
      expected_max_step=999, expected_min_step=0)
    self.assertFalse(ok)
    self.assertIn("tag-count-mismatch", reasons)
    self.assertIn("curve-row-count-mismatch", reasons)
    self.assertIn("curve-step-mismatch", reasons)

  def test_check_curve_artifacts_reports_a_stale_summary(self):
    train.write_curve_csv(self.csv, self.rows)
    train.write_curve_summary_csv(
      self.summary, train.curve_summary_rows(self.rows))
    with open(self.summary, "r", encoding="utf-8") as handle:
      text = handle.read()
    with open(self.summary, "w", encoding="utf-8") as handle:
      handle.write(text.replace("custom/tag,2,50,100,0.0,3.0,1.5",
                                "custom/tag,2,50,100,0.0,9.0,1.5"))
    ok, reasons, metrics = train.check_curve_artifacts(self.csv, self.summary)
    self.assertFalse(ok)
    self.assertIn("curve-summary-mismatch", reasons)
    self.assertEqual(metrics["summary_ok"], 0)


class CurveCliTest(unittest.TestCase):

  def setUp(self):
    self.dir = tempfile.mkdtemp(prefix="train_curves_cli_")
    self.payload = os.path.join(self.dir, "payload.json")

  def tearDown(self):
    shutil.rmtree(self.dir, ignore_errors=True)

  def _write_payload(self, scalars, events_files=10):
    with open(self.payload, "w", encoding="utf-8") as handle:
      json.dump({"error": None, "events_files": events_files,
                 "scalars": scalars}, handle)

  def _run(self, *args):
    return subprocess.run(
      [sys.executable, TRAIN_PY, *args],
      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)

  def test_cli_writes_the_artefacts_and_exits_zero(self):
    self._write_payload(healthy_scalars())
    out = self._run("curves", "--scalars-json", self.payload,
                    "--out-dir", self.dir, "--name", "fixture",
                    "--expected-tags", "12", "--expected-max-step", "100",
                    "--expected-min-step", "50", "--expected-events-files", "10")
    self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
    self.assertIn("REASON=-", out.stdout)
    self.assertTrue(os.path.isfile(
      os.path.join(self.dir, "fixture_curves.csv")))
    self.assertTrue(os.path.isfile(
      os.path.join(self.dir, "fixture_curves_summary.csv")))

  def test_cli_fails_closed_on_a_foreign_nan(self):
    scalars = healthy_scalars()
    scalars["foreign/tag"] = [[50, "nan"]]
    self._write_payload(scalars)
    out = self._run("curves", "--scalars-json", self.payload,
                    "--out-dir", self.dir, "--name", "fixture")
    self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
    self.assertIn("REASON=nan-nonwhitelist", out.stdout)
    self.assertNotIn("OK", out.stdout.replace("NONFINITE", ""))

  def test_cli_fails_closed_on_a_missing_run_directory(self):
    with open(self.payload, "w", encoding="utf-8") as handle:
      json.dump({"error": "run-dir-missing: /nope", "events_files": 0,
                 "scalars": {}}, handle)
    out = self._run("curves", "--scalars-json", self.payload,
                    "--out-dir", self.dir, "--name", "fixture")
    self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
    self.assertIn("REASON=run-dir-missing", out.stdout)

  def test_cli_fails_closed_on_an_unreadable_payload(self):
    out = self._run("curves", "--scalars-json",
                    os.path.join(self.dir, "nope.json"),
                    "--out-dir", self.dir, "--name", "fixture")
    self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
    self.assertIn("REASON=extraction-failed", out.stdout)

  def test_curves_verify_detects_a_broken_artefact(self):
    self._write_payload(healthy_scalars())
    self._run("curves", "--scalars-json", self.payload,
              "--out-dir", self.dir, "--name", "fixture")
    csv = os.path.join(self.dir, "fixture_curves.csv")
    with open(csv, "a", encoding="utf-8") as handle:
      handle.write("150,foreign/tag,nan\n")
    out = self._run("curves-verify", "--csv", csv,
                    "--summary", os.path.join(self.dir,
                                             "fixture_curves_summary.csv"))
    self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
    self.assertIn("REASON=nan-nonwhitelist", out.stdout)


if __name__ == "__main__":
  unittest.main(verbosity=2)
