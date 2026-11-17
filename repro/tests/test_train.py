#!/usr/bin/env python3
"""repro/tests/test_train.py — offline unit tests for the decision base of the
g1_amber training run (slice S06).

Standard library ONLY (unittest / math / os / shutil / sys / tempfile).
No network, no GPU, no training: every fixture is created on the fly in a
tempfile.mkdtemp() directory and removed afterwards.  The repository's real
payload (`data/`), the real logs (`logs/`) and `.gsd/` are NEVER read.

The container's system python3 has NO numpy — the library must therefore stay
importable with the bare interpreter.

Covered decisions:
  * iteration-line parsing (it / it/s / mem GB / wm loss / nonfinite / kp NaN)
  * log summarising incl. the `resumed <path> at iteration N` evidence
  * plan_iterations (normal case + fail-closed on 0 / negative / NaN)
  * plan_ckpt_every (>= min_ckpts checkpoints, multiple of 1000, >= 1000)
  * plan_lr_decay_iters (== iterations, MEM005)
  * budget_ok (inside / GPU over / host over / wall over / missing values)
  * parse_resource_csv (peaks / missing column / empty file / missing file)
  * nan_audit (whitelisted NaN / foreign NaN / nonfinite_steps > 0 / missing
    required tags)
  * write_status / read_status (round trip, fixed field order, atomic write
    leaves no .tmp behind)

Run locally:  python3 repro/tests/test_train.py
"""

from __future__ import annotations

import math
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(
  0,
  os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"),
)

import train  # noqa: E402


# --------------------------------------------------------------------------
# fixtures (stdlib only)
# --------------------------------------------------------------------------

# One real upstream iteration line (probe1.log, 2026-11-13), flattened.
REAL_IT_LINE = (
  "[morphmimic] it 20 | 1.09 it/s (0.054/0.294/0.568 s collect/wm/actor-critic)"
  " | env 2905/s imag 286039/s"
  " | wm loss 318.4488 bce 0.0071 pred8 0.4472 err8 pelvis 0.018 m"
  " joints 0.048 rad"
  " | J 0.8706 |g| 0.208 (max 0.394) critic 7.65e-03 V0 0.81 tclip 0.00%"
  " surv 0.273"
  " | rew 0.0358 nret 0.386 eplen 34.5 fail 350"
  " | nonfinite wm/pol/critic 0/0/0 | mem 17.09 GB"
  " | kp J nan act 0.0000 align 0.5910"
)

RESUME_LINE = (
  "[morphmimic] resumed logs/_probe/probe1/latest.pt at iteration 20;"
  " restored networks, normalisers, optimisers, schedule, sampler, rng,"
  " keypoint"
)


class TempDirCase(unittest.TestCase):
  """Base class handing out a throwaway directory."""

  def setUp(self):
    self.tmp = tempfile.mkdtemp(prefix="train-test-")
    self.addCleanup(shutil.rmtree, self.tmp, True)

  def path(self, *parts):
    return os.path.join(self.tmp, *parts)


class TestParseLogLine(unittest.TestCase):

  def test_real_line(self):
    parsed = train.parse_log_line(REAL_IT_LINE)
    self.assertIsNotNone(parsed)
    self.assertEqual(parsed["it"], 20)
    self.assertAlmostEqual(parsed["it_per_s"], 1.09, places=6)
    self.assertAlmostEqual(parsed["mem_gb"], 17.09, places=6)
    self.assertAlmostEqual(parsed["wm_loss"], 318.4488, places=4)
    self.assertEqual(parsed["nonfinite_wm"], 0)
    self.assertEqual(parsed["nonfinite_pol"], 0)
    self.assertEqual(parsed["nonfinite_critic"], 0)
    self.assertTrue(parsed["kp_j_nan"])

  def test_nonfinite_counts_are_read(self):
    line = (
      "[morphmimic] it 50 | 1.10 it/s | wm loss 1.0 | J 0.5 critic 1e-03"
      " | nonfinite wm/pol/critic 2/3/4 | mem 17.00 GB"
    )
    parsed = train.parse_log_line(line)
    self.assertEqual(parsed["nonfinite_wm"], 2)
    self.assertEqual(parsed["nonfinite_pol"], 3)
    self.assertEqual(parsed["nonfinite_critic"], 4)

  def test_unparsable_lines_return_none(self):
    for line in (
      "",
      "hello world",
      "[morphmimic] run dir: logs/_probe/probe1",
      "[morphmimic] resumed logs/x/latest.pt at iteration 20; restored x",
      None,
      123,
    ):
      self.assertIsNone(train.parse_log_line(line), line)


class TestParseLogFile(TempDirCase):

  def _write_log(self):
    log = self.path("train.log")
    with open(log, "w", encoding="utf-8") as handle:
      handle.write("[morphmimic] run dir: logs/train/g1_amber_1h\n")
      handle.write(REAL_IT_LINE + "\n")
      handle.write(RESUME_LINE + "\n")
      handle.write(
        "[morphmimic] it 40 | 1.12 it/s | wm loss 2.0 | J 0.4 critic 1e-03"
        " | nonfinite wm/pol/critic 0/0/0 | mem 18.50 GB"
        " | kp J nan act 0.0 align 0.5\n")
    return log

  def test_summary(self):
    summary = train.parse_log_file(self._write_log())
    self.assertIsNotNone(summary)
    self.assertEqual(summary["max_it"], 40)
    self.assertEqual(summary["parsed_lines"], 2)
    self.assertEqual(summary["lines"], 4)
    self.assertEqual(summary["it_per_s"], [1.09, 1.12])
    self.assertAlmostEqual(summary["mem_gb_peak"], 18.50, places=6)
    self.assertEqual(summary["nonfinite"], {"wm": 0, "pol": 0, "critic": 0})
    self.assertEqual(
      summary["resume_events"],
      [("logs/_probe/probe1/latest.pt", 20)])

  def test_missing_file_returns_none(self):
    self.assertIsNone(train.parse_log_file(self.path("nope.log")))


class TestPlanIterations(unittest.TestCase):

  def test_normal_case(self):
    expected = math.floor(28800 * 1.09 * 0.85)
    self.assertEqual(train.plan_iterations(28800, 1.09, 0.85), expected)
    self.assertEqual(train.plan_iterations(28800, 1.09, 0.85), 26683)

  def test_fail_closed(self):
    for args in (
      (28800, 0.0, 0.85),
      (28800, -1.0, 0.85),
      (0, 1.09, 0.85),
      (-5, 1.09, 0.85),
      (28800, 1.09, 0.0),
      (28800, 1.09, -0.85),
      (float("nan"), 1.09, 0.85),
      (28800, float("nan"), 0.85),
      (28800, 1.09, float("inf")),
    ):
      value = train.plan_iterations(*args)
      self.assertEqual(value, 0, args)
      self.assertGreaterEqual(value, 0)

  def test_never_raises(self):
    self.assertEqual(train.plan_iterations(None, None, None), 0)
    self.assertEqual(train.plan_iterations("x", "y", "z"), 0)


class TestPlanCkptEvery(unittest.TestCase):

  def test_guarantees_min_ckpts(self):
    for iterations, min_ckpts in (
      (26000, 3),
      (26683, 3),
      (26000, 8),
      (12000, 5),
      (40000, 4),
    ):
      every = train.plan_ckpt_every(iterations, min_ckpts)
      self.assertGreaterEqual(every, 1000)
      self.assertEqual(every % 1000, 0)
      self.assertGreaterEqual(train.ckpt_count(iterations, every), min_ckpts)

  def test_degenerate_grid_collision(self):
    # 1000 iterations cannot yield 3 checkpoints when ckpt_every must be a
    # multiple of 1000 and >= 1000 -> the smallest legal value is returned.
    every = train.plan_ckpt_every(1000, 3)
    self.assertEqual(every, 1000)
    self.assertEqual(every % 1000, 0)

  def test_fail_closed(self):
    self.assertEqual(train.plan_ckpt_every(0, 3), 1000)
    self.assertEqual(train.plan_ckpt_every(-1, 3), 1000)
    self.assertEqual(train.plan_ckpt_every(26000, 0), 1000)


class TestPlanLrDecayIters(unittest.TestCase):

  def test_equals_iterations(self):
    self.assertEqual(train.plan_lr_decay_iters(26683), 26683)
    self.assertEqual(train.plan_lr_decay_iters(0), 0)
    self.assertEqual(train.plan_lr_decay_iters(-3), 0)


class TestBudgetOk(unittest.TestCase):

  def test_inside_budget(self):
    ok, reasons = train.budget_ok(18000, 12.0, 28000, {"wall_max_s": 28800})
    self.assertTrue(ok)
    self.assertEqual(reasons, [])

  def test_gpu_over_budget(self):
    ok, reasons = train.budget_ok(23 * 1024, 12.0, 100, {"wall_max_s": 28800})
    self.assertFalse(ok)
    self.assertTrue(any("显存" in r for r in reasons), reasons)

  def test_host_over_budget(self):
    ok, reasons = train.budget_ok(18000, 46.0, 100, {"wall_max_s": 28800})
    self.assertFalse(ok)
    self.assertTrue(any("主机内存" in r for r in reasons), reasons)

  def test_wall_over_budget(self):
    ok, reasons = train.budget_ok(18000, 12.0, 30000, {"wall_max_s": 28800})
    self.assertFalse(ok)
    self.assertTrue(any("墙钟" in r for r in reasons), reasons)

  def test_missing_values_fail_closed(self):
    ok, reasons = train.budget_ok(None, None, None, {"wall_max_s": 100})
    self.assertFalse(ok)
    self.assertEqual(len(reasons), 3)


class TestParseResourceCsv(TempDirCase):

  def test_peaks(self):
    csv_path = self.path("resources.csv")
    with open(csv_path, "w", encoding="utf-8") as handle:
      handle.write(
        "ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,"
        "proc_rss_gb\n")
      handle.write("1700000000,100,12000,24564,10.5,51.0,8.2\n")
      handle.write("1700000030,200,18050,24564,12.5,49.0,9.1\n")
    parsed = train.parse_resource_csv(csv_path)
    self.assertIsNotNone(parsed)
    self.assertEqual(parsed["samples"], 2)
    self.assertAlmostEqual(parsed["gpu_used_mb_peak"], 18050.0)
    self.assertAlmostEqual(parsed["gpu_total_mb"], 24564.0)
    self.assertAlmostEqual(parsed["host_used_gb_peak"], 12.5)
    self.assertAlmostEqual(parsed["host_avail_gb_min"], 49.0)

  def test_missing_column_returns_none(self):
    csv_path = self.path("bad.csv")
    with open(csv_path, "w", encoding="utf-8") as handle:
      handle.write("ts,iter,gpu_used_mb\n")
      handle.write("1700000000,100,12000\n")
    self.assertIsNone(train.parse_resource_csv(csv_path))

  def test_empty_file_returns_none(self):
    csv_path = self.path("empty.csv")
    with open(csv_path, "w", encoding="utf-8") as handle:
      handle.write("")
    self.assertIsNone(train.parse_resource_csv(csv_path))

  def test_header_only_returns_none(self):
    csv_path = self.path("header.csv")
    with open(csv_path, "w", encoding="utf-8") as handle:
      handle.write(
        "ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,host_avail_gb,"
        "proc_rss_gb\n")
    self.assertIsNone(train.parse_resource_csv(csv_path))

  def test_missing_file_returns_none(self):
    self.assertIsNone(train.parse_resource_csv(self.path("nope.csv")))


class TestNanAudit(unittest.TestCase):

  def _healthy(self):
    return {
      "wm/state_loss": [1.0, 0.9],
      "wm/nonfinite_steps": [0, 0],
      "policy/objective": [0.5, 0.4],
      "policy/nonfinite_steps": [0, 0],
      "critic/loss": [0.001, 0.002],
      "critic/nonfinite_steps": [0, 0],
      "kp/nonfinite_steps": [0, 0],
      "perf/it_per_s": [1.09, 1.1],
      "perf/gpu_mem_gb": [17.09, 18.0],
      "kp/return": [float("nan"), float("nan")],
      "kp/scale_return": [float("nan")],
    }

  def test_whitelisted_nan_is_ok(self):
    ok, bad, missing, violations = train.nan_audit(self._healthy())
    self.assertTrue(ok)
    self.assertEqual(bad, [])
    self.assertEqual(missing, [])
    self.assertEqual(violations, [])

  def test_foreign_nan_is_bad(self):
    scalars = self._healthy()
    scalars["wm/state_loss"] = [1.0, float("nan")]
    ok, bad, missing, violations = train.nan_audit(scalars)
    self.assertFalse(ok)
    self.assertIn("wm/state_loss", bad)
    self.assertEqual(missing, [])
    self.assertEqual(violations, [])

  def test_inf_is_bad(self):
    scalars = self._healthy()
    scalars["critic/loss"] = [float("inf")]
    ok, bad, _, _ = train.nan_audit(scalars)
    self.assertFalse(ok)
    self.assertIn("critic/loss", bad)

  def test_nonfinite_steps_violation(self):
    scalars = self._healthy()
    scalars["policy/nonfinite_steps"] = [0, 1]
    ok, bad, missing, violations = train.nan_audit(scalars)
    self.assertFalse(ok)
    self.assertEqual(bad, [])
    self.assertEqual(missing, [])
    self.assertTrue(any("policy/nonfinite_steps" in v for v in violations))

  def test_missing_required_tags(self):
    scalars = self._healthy()
    del scalars["perf/gpu_mem_gb"]
    del scalars["kp/nonfinite_steps"]
    ok, bad, missing, violations = train.nan_audit(scalars)
    self.assertFalse(ok)
    self.assertIn("perf/gpu_mem_gb", missing)
    self.assertIn("kp/nonfinite_steps", missing)

  def test_custom_whitelist_is_honoured(self):
    scalars = self._healthy()
    scalars["kp/return"] = [1.0]
    ok, _, _, _ = train.nan_audit(scalars, whitelist=())
    self.assertFalse(ok)


class TestStatusFiles(TempDirCase):

  def test_round_trip_and_order(self):
    status = self.path("17_train.status")
    train.write_status(
      status,
      "DONE",
      0,
      {"IT_PER_S": "1.09", "ITER": "26683", "STARTED_AT": "2026-11-13T00:00:00Z"},
    )
    parsed = train.read_status(status)
    self.assertEqual(parsed["STATE"], "DONE")
    self.assertEqual(parsed["RC"], "0")
    self.assertEqual(parsed["IT_PER_S"], "1.09")
    self.assertEqual(parsed["ITER"], "26683")
    self.assertEqual(parsed["STARTED_AT"], "2026-11-13T00:00:00Z")
    self.assertTrue(parsed["FINISHED_AT"])

    with open(status, "r", encoding="utf-8") as handle:
      lines = [line.split("=", 1)[0] for line in handle if line.strip()]
    self.assertEqual(lines[0], "STATE")
    self.assertEqual(lines[1], "RC")
    self.assertEqual(lines[2], "STARTED_AT")
    self.assertEqual(lines[-1], "FINISHED_AT")

  def test_no_tmp_residue(self):
    status = self.path("17_train.status")
    train.write_status(status, "FAILED", 1, {"REASON": "oom"})
    self.assertTrue(os.path.isfile(status))
    self.assertFalse(os.path.exists(status + ".tmp"))
    self.assertEqual(train.read_status(status)["REASON"], "oom")

  def test_missing_status_returns_empty(self):
    self.assertEqual(train.read_status(self.path("nope.status")), {})


if __name__ == "__main__":
  unittest.main(verbosity=2)
