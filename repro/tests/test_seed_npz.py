#!/usr/bin/env python3
"""repro/tests/test_seed_npz.py — offline unit tests for
repro/lib/seed_npz.py (the G1 50 Hz npz conversion decision logic).

Standard library only (unittest / csv / os / shutil / tempfile).  No network,
no GPU, no 150 GB payload: every fixture is created on the fly in a
tempfile.mkdtemp() directory and removed afterwards.  The repository data is
never read.

Run locally:  python3 repro/tests/test_seed_npz.py
"""

from __future__ import annotations

import csv
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(
  0,
  os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"),
)

import seed_npz  # noqa: E402


MANIFEST_HEADER = list(seed_npz.MANIFEST_COLUMNS)


def write_manifest(path, rows):
  """Write a manifest csv with the upstream 9-column layout.

  `rows` is a list of dicts; missing keys default to "".
  """
  with open(path, "w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle)
    writer.writerow(MANIFEST_HEADER)
    for row in rows:
      writer.writerow([row.get(column, "") for column in MANIFEST_HEADER])
  return path


def manifest_row(path, seconds=10.0, name_reject="", feas_reject=""):
  return {
    "name": os.path.basename(path),
    "path": path,
    "session": path.split("/")[0],
    "frames": str(int(seconds * 50)),
    "seconds": str(seconds),
    "name_reject": name_reject,
    "feas_reject": feas_reject,
    "category": "walk",
    "package": "p1",
  }


def write_subset_yaml(path, root, hours, clips):
  """Write a subset yaml in the exact shape upstream `yaml.safe_dump` uses."""
  lines = ["root: %s" % root, "hours: %s" % hours, "clips:"]
  for clip in clips:
    lines.append("- %s" % clip)
  with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
  return path


class TempDirCase(unittest.TestCase):
  """Base class giving every test a private, auto-cleaned temp dir."""

  def setUp(self):
    self.tmp = tempfile.mkdtemp(prefix="seed_npz_test_")
    self.addCleanup(shutil.rmtree, self.tmp, True)

  def path(self, *parts):
    return os.path.join(self.tmp, *parts)


# ===========================================================================
# manifest statistics
# ===========================================================================


class ManifestStatsTest(TempDirCase):
  def test_clean_manifest(self):
    manifest = write_manifest(
      self.path("manifest.csv"),
      [
        manifest_row("230509/a.npz", seconds=10.0),
        manifest_row("230509/b.npz", seconds=20.0),
        manifest_row("230509/c.npz", seconds=30.0),
      ],
    )
    stats = seed_npz.manifest_stats(manifest)
    self.assertEqual(stats["rows"], 3)
    self.assertEqual(stats["kept"], 3)
    self.assertEqual(stats["errors"], 0)
    self.assertEqual(stats["error_rate"], 0.0)
    self.assertAlmostEqual(stats["total_seconds"], 60.0)
    self.assertAlmostEqual(stats["total_hours"], 60.0 / 3600.0)
    self.assertAlmostEqual(stats["kept_hours"], 60.0 / 3600.0)
    self.assertEqual(stats["name_rejects"], {})
    self.assertEqual(stats["feas_rejects"], {})
    self.assertEqual(stats["named"], 3)

  def test_one_error_row(self):
    manifest = write_manifest(
      self.path("manifest.csv"),
      [
        manifest_row("230509/a.npz", seconds=10.0),
        manifest_row("230509/b.npz", seconds=10.0, feas_reject="error: FK failed"),
        manifest_row("230509/c.npz", seconds=10.0),
        manifest_row("230509/d.npz", seconds=10.0),
      ],
    )
    stats = seed_npz.manifest_stats(manifest)
    self.assertEqual(stats["rows"], 4)
    self.assertEqual(stats["errors"], 1)
    self.assertEqual(stats["kept"], 3)
    self.assertAlmostEqual(stats["error_rate"], 0.25)
    self.assertEqual(stats["feas_rejects"], {"error: FK failed": 1})
    self.assertAlmostEqual(stats["kept_seconds"], 30.0)

  def test_name_reject_is_not_an_error(self):
    # A clip rejected by the NAME filter is not a conversion error: it must
    # not be counted in `errors`, only in the name_reject distribution.
    manifest = write_manifest(
      self.path("manifest.csv"),
      [
        manifest_row("230509/a.npz", name_reject="box"),
        manifest_row("230509/b.npz", seconds=10.0),
      ],
    )
    stats = seed_npz.manifest_stats(manifest)
    self.assertEqual(stats["rows"], 2)
    self.assertEqual(stats["errors"], 0)
    self.assertEqual(stats["error_rate"], 0.0)
    self.assertEqual(stats["kept"], 1)
    self.assertEqual(stats["name_rejects"], {"box": 1})
    self.assertEqual(stats["feas_rejects"], {})
    self.assertEqual(stats["named"], 1)

  def test_feasibility_reject_is_not_an_error(self):
    # A feasibility FILTER verdict (e.g. "floating_feet") is not an error.
    manifest = write_manifest(
      self.path("manifest.csv"),
      [
        manifest_row("230509/a.npz", feas_reject="floating_feet"),
        manifest_row("230509/b.npz", seconds=10.0),
      ],
    )
    stats = seed_npz.manifest_stats(manifest)
    self.assertEqual(stats["errors"], 0)
    self.assertEqual(stats["kept"], 1)
    self.assertEqual(stats["feas_rejects"], {"floating_feet": 1})

  def test_empty_manifest(self):
    manifest = write_manifest(self.path("manifest.csv"), [])
    stats = seed_npz.manifest_stats(manifest)
    self.assertEqual(stats["rows"], 0)
    self.assertEqual(stats["kept"], 0)
    self.assertEqual(stats["error_rate"], 0.0)

  def test_missing_manifest_raises(self):
    with self.assertRaises(ValueError):
      seed_npz.manifest_stats(self.path("nope.csv"))

  def test_missing_column_raises(self):
    path = self.path("bad.csv")
    with open(path, "w", encoding="utf-8") as handle:
      handle.write("name,path\nx,y\n")
    with self.assertRaises(ValueError):
      seed_npz.manifest_stats(path)

  def test_seconds_by_path(self):
    manifest = write_manifest(
      self.path("manifest.csv"),
      [
        manifest_row("230509/a.npz", seconds=12.5),
        manifest_row("230509/b.npz", seconds=7.5),
      ],
    )
    seconds = seed_npz.manifest_seconds_by_path(manifest)
    self.assertAlmostEqual(seconds["230509/a.npz"], 12.5)
    self.assertAlmostEqual(seconds["230509/b.npz"], 7.5)


# ===========================================================================
# error rate gate
# ===========================================================================


class ErrorRateTest(unittest.TestCase):
  def test_zero_errors_passes(self):
    self.assertTrue(seed_npz.error_rate_ok(100, 0))
    self.assertTrue(seed_npz.error_rate_ok(142220, 0))

  def test_exactly_one_percent_passes(self):
    # the limit is inclusive: exactly 1% is still acceptable
    self.assertTrue(seed_npz.error_rate_ok(100, 1))
    self.assertTrue(seed_npz.error_rate_ok(10000, 100))
    self.assertTrue(seed_npz.error_rate_ok(142220, 1422))

  def test_above_one_percent_fails(self):
    self.assertFalse(seed_npz.error_rate_ok(100, 2))
    self.assertFalse(seed_npz.error_rate_ok(10000, 101))
    self.assertFalse(seed_npz.error_rate_ok(142220, 1423))

  def test_custom_limit(self):
    self.assertTrue(seed_npz.error_rate_ok(10, 1, limit=0.1))
    self.assertFalse(seed_npz.error_rate_ok(10, 2, limit=0.1))

  def test_empty_manifest_fails_closed(self):
    # "no data" must never pass a gate
    self.assertFalse(seed_npz.error_rate_ok(0, 0))

  def test_negative_inputs_fail_closed(self):
    self.assertFalse(seed_npz.error_rate_ok(-1, 0))
    self.assertFalse(seed_npz.error_rate_ok(100, -1))
    self.assertFalse(seed_npz.error_rate_ok(None, 0))


# ===========================================================================
# subset yamls
# ===========================================================================


class SubsetSpecTest(TempDirCase):
  def test_reads_upstream_shape(self):
    path = write_subset_yaml(
      self.path("1h.yaml"),
      "/data/seed_g1_npz50",
      1.0,
      ["230509/a.npz", "230509/b.npz"],
    )
    spec = seed_npz.subset_spec(path)
    self.assertEqual(spec["root"], "/data/seed_g1_npz50")
    self.assertAlmostEqual(spec["hours"], 1.0)
    self.assertEqual(spec["clips"], ["230509/a.npz", "230509/b.npz"])

  def test_flow_style_clips(self):
    path = self.path("tiny.yaml")
    with open(path, "w", encoding="utf-8") as handle:
      handle.write("root: /root\nhours: 0.1\nclips: [a.npz, 'b c.npz']\n")
    spec = seed_npz.subset_spec(path)
    self.assertEqual(spec["clips"], ["a.npz", "b c.npz"])

  def test_missing_file_raises(self):
    with self.assertRaises(ValueError):
      seed_npz.subset_spec(self.path("nope.yaml"))

  def test_missing_key_raises(self):
    path = self.path("bad.yaml")
    with open(path, "w", encoding="utf-8") as handle:
      handle.write("root: /root\nclips: []\n")
    with self.assertRaises(ValueError):
      seed_npz.subset_spec(path)

  def test_unparsable_yaml_raises(self):
    path = self.path("bad.yaml")
    with open(path, "w", encoding="utf-8") as handle:
      handle.write("this is not yaml\n")
    with self.assertRaises(ValueError):
      seed_npz.subset_spec(path)


class SubsetsNestedTest(TempDirCase):
  def _specs(self, clips_by_name, root="/data/seed_g1_npz50"):
    specs = {}
    for name, clips in clips_by_name.items():
      path = write_subset_yaml(
        self.path("%s.yaml" % name), root, 1.0, clips
      )
      specs[name] = seed_npz.subset_spec(path)
    return specs

  def test_nested_chain_is_true(self):
    specs = self._specs(
      {
        "tiny": ["a.npz"],
        "1h": ["a.npz", "b.npz"],
        "all": ["a.npz", "b.npz", "c.npz"],
      }
    )
    self.assertTrue(
      seed_npz.subsets_nested(specs, required=("tiny", "1h", "all"))
    )

  def test_full_chain_is_true(self):
    specs = self._specs(
      {
        "tiny": ["a.npz"],
        "1h": ["a.npz", "b.npz"],
        "7h": ["a.npz", "b.npz", "c.npz"],
        "40h": ["a.npz", "b.npz", "c.npz", "d.npz"],
        "all": ["a.npz", "b.npz", "c.npz", "d.npz", "e.npz"],
      }
    )
    self.assertTrue(seed_npz.subsets_nested(specs))

  def test_broken_nesting_is_false(self):
    # "1h" holds a clip that "all" does not have -> not nested
    specs = self._specs(
      {
        "tiny": ["a.npz"],
        "1h": ["a.npz", "zz.npz"],
        "all": ["a.npz", "b.npz", "c.npz"],
      }
    )
    self.assertFalse(
      seed_npz.subsets_nested(specs, required=("tiny", "1h", "all"))
    )

  def test_shuffled_nesting_is_false(self):
    # the chain order is broken (1h is smaller than tiny)
    specs = self._specs(
      {
        "tiny": ["a.npz", "b.npz"],
        "1h": ["a.npz"],
        "all": ["a.npz", "b.npz"],
      }
    )
    self.assertFalse(
      seed_npz.subsets_nested(specs, required=("tiny", "1h", "all"))
    )

  def test_missing_subset_is_false(self):
    specs = self._specs({"tiny": ["a.npz"], "all": ["a.npz", "b.npz"]})
    self.assertFalse(
      seed_npz.subsets_nested(specs, required=("tiny", "1h", "all"))
    )

  def test_unknown_subset_name_raises(self):
    specs = self._specs({"tiny": ["a.npz"]})
    with self.assertRaises(ValueError):
      seed_npz.subsets_nested(specs, required=("tiny", "nope"))

  def test_required_chain_must_follow_canonical_order(self):
    specs = self._specs(
      {"tiny": ["a.npz"], "1h": ["a.npz"], "all": ["a.npz"]}
    )
    self.assertFalse(
      seed_npz.subsets_nested(specs, required=("all", "tiny", "1h"))
    )


class SubsetHoursTest(TempDirCase):
  def test_consistent(self):
    spec = {
      "root": "/r",
      "hours": 1.0,
      "clips": ["a.npz", "b.npz"],
    }
    seconds = {"a.npz": 1800.0, "b.npz": 1800.0}
    self.assertTrue(seed_npz.subset_hours_consistent(spec, seconds))

  def test_inconsistent(self):
    spec = {
      "root": "/r",
      "hours": 1.0,
      "clips": ["a.npz", "b.npz"],
    }
    seconds = {"a.npz": 1800.0, "b.npz": 600.0}
    self.assertFalse(seed_npz.subset_hours_consistent(spec, seconds))

  def test_missing_clip_is_inconsistent(self):
    spec = {"root": "/r", "hours": 1.0, "clips": ["a.npz", "missing.npz"]}
    self.assertFalse(
      seed_npz.subset_hours_consistent(spec, {"a.npz": 3600.0})
    )

  def test_tolerance(self):
    # 1e-6 h = 3.6 ms tolerance
    spec = {"root": "/r", "hours": 1.0, "clips": ["a.npz"]}
    self.assertTrue(
      seed_npz.subset_hours_consistent(spec, {"a.npz": 3600.0 + 0.003})
    )
    self.assertFalse(
      seed_npz.subset_hours_consistent(spec, {"a.npz": 3600.0 + 0.1})
    )

  def test_malformed_spec_is_inconsistent(self):
    self.assertFalse(seed_npz.subset_hours_consistent(None, {}))
    self.assertFalse(seed_npz.subset_hours_consistent({"clips": []}, {}))


class SamplePathsTest(TempDirCase):
  def _manifest(self, count=20, quoted=False):
    rows = []
    for i in range(1, count + 1):
      path = "230509/clip_%03d.npz" % i
      name = path.split("/")[1]
      if quoted and i % 2 == 0:
        # pandas quotes a field that contains the delimiter
        name = '"clip, %03d.npz"' % i
      rows.append(
        {
          "name": name,
          "path": path,
          "session": "230509",
          "frames": "500",
          "seconds": "10.0",
          "name_reject": "",
          "feas_reject": "",
          "category": "walk",
          "package": "p1",
        }
      )
    return write_manifest(self.path("manifest.csv"), rows)

  def test_count_and_span(self):
    manifest = self._manifest(20)
    paths = seed_npz.sample_paths(manifest, 5)
    self.assertEqual(len(paths), 5)
    self.assertEqual(paths[0], "230509/clip_001.npz")
    self.assertEqual(paths[-1], "230509/clip_020.npz")

  def test_deterministic(self):
    manifest = self._manifest(20)
    self.assertEqual(
      seed_npz.sample_paths(manifest, 7), seed_npz.sample_paths(manifest, 7)
    )

  def test_clamps_to_row_count(self):
    manifest = self._manifest(20)
    self.assertEqual(len(seed_npz.sample_paths(manifest, 1000)), 20)

  def test_zero_and_negative(self):
    manifest = self._manifest(20)
    self.assertEqual(seed_npz.sample_paths(manifest, 0), [])
    self.assertEqual(seed_npz.sample_paths(manifest, -3), [])

  def test_single_sample(self):
    manifest = self._manifest(20)
    self.assertEqual(seed_npz.sample_paths(manifest, 1), ["230509/clip_001.npz"])

  def test_quoted_fields_are_parsed_correctly(self):
    # a `name` field containing a comma is quoted by pandas; the path column
    # must still be read correctly (an awk -F, split would mis-align it)
    manifest = self._manifest(20, quoted=True)
    paths = seed_npz.sample_paths(manifest, 4)
    self.assertEqual(len(paths), 4)
    for path in paths:
      self.assertRegex(path, r"^230509/clip_\d{3}\.npz$")

  def test_empty_manifest(self):
    manifest = write_manifest(self.path("manifest.csv"), [])
    self.assertEqual(seed_npz.sample_paths(manifest, 5), [])

  def test_missing_manifest_raises(self):
    with self.assertRaises(ValueError):
      seed_npz.sample_paths(self.path("nope.csv"), 5)


class CliTest(TempDirCase):
  def test_stats_command(self):
    manifest = write_manifest(
      self.path("manifest.csv"),
      [
        manifest_row("230509/a.npz", seconds=10.0),
        manifest_row("230509/b.npz", seconds=10.0, feas_reject="error: boom"),
      ],
    )
    import io
    import contextlib

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
      code = seed_npz.main(["stats", manifest])
    output = buffer.getvalue()
    self.assertEqual(code, 0)
    self.assertIn("rows=2", output)
    self.assertIn("kept=1", output)
    self.assertIn("errors=1", output)
    self.assertIn("error_rate_ok=0", output)

  def test_sample_paths_command(self):
    manifest = write_manifest(
      self.path("manifest.csv"),
      [manifest_row("230509/a.npz"), manifest_row("230509/b.npz")],
    )
    import io
    import contextlib

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
      code = seed_npz.main(["sample-paths", manifest, "1"])
    self.assertEqual(code, 0)
    self.assertEqual(buffer.getvalue().strip(), "230509/a.npz")

  def test_nested_command_reports_failure_with_exit_code(self):
    tiny = write_subset_yaml(self.path("tiny.yaml"), "/r", 0.1, ["a.npz"])
    allh = write_subset_yaml(self.path("all.yaml"), "/r", 1.0, ["b.npz"])
    import io
    import contextlib

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
      code = seed_npz.main(["nested", "tiny=%s" % tiny, "all=%s" % allh])
    self.assertEqual(code, 1)
    self.assertIn("nested=0", buffer.getvalue())

  def test_unknown_command_returns_usage(self):
    import io
    import contextlib

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
      code = seed_npz.main(["nope"])
    self.assertEqual(code, 2)

  def test_missing_manifest_is_reported_not_raised(self):
    import io
    import contextlib

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
      code = seed_npz.main(["stats", self.path("nope.csv")])
    self.assertEqual(code, 1)


if __name__ == "__main__":
  unittest.main(verbosity=2)
