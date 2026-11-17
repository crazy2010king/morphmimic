#!/usr/bin/env python3
''''exec python3 -u -- "$0" "$@" # '''
"""repro/tests/test_seed_verify.py — offline unit tests for
repro/lib/seed_verify.py (the metadata <-> extracted tree reconciliation).

The file is a polyglot: it is a stdlib `unittest` module AND a runnable
script. Both invocations work and are equivalent:

    python3 repro/tests/test_seed_verify.py
    bash    repro/tests/test_seed_verify.py      # execs python3 on itself

No network access, no third-party import: every fixture (metadata CSV and
the fake extracted tree) is built in a temp dir.

Covered:
  1. a complete tree reconciles: matched == expected, missing/extra == 0, rc 0
  2. a missing clip is reported (missing > 0) and the exit code is non-zero
  3. an extra clip is reported (extra > 0) and the exit code is non-zero
  4. a 0 byte clip is counted and the exit code is non-zero
  5. a wrong session directory is reported as a session mismatch (rc != 0)
  6. malformed metadata (missing column / broken basename rule) is rejected
  7. an unreadable sample (csv without commas, bvh without HIERARCHY) fails
"""

import csv
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "lib", "seed_verify.py")

CSV_HEADER = ",".join(["filename", "move_g1_path", "move_soma_uniform_path"])


def write_metadata(path, rows):
    """rows: list of (filename, session) tuples."""
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(CSV_HEADER.split(","))
        for filename, session in rows:
            writer.writerow([
                filename,
                "g1/csv/%s/%s.csv" % (session, filename),
                "soma_uniform/bvh/%s/%s.bvh" % (session, filename),
            ])


def write_csv_clip(root, session, filename, content=None):
    path = os.path.join(root, session)
    os.makedirs(path, exist_ok=True)
    full = os.path.join(path, filename + ".csv")
    if content is None:
        content = ",".join("c%d" % i for i in range(12)) + "\n1,2,3,4,5,6,7,8,9,10,11,12\n"
    with open(full, "w", encoding="utf-8") as handle:
        handle.write(content)
    return full


def write_bvh_clip(root, session, filename, content=None):
    path = os.path.join(root, session)
    os.makedirs(path, exist_ok=True)
    full = os.path.join(path, filename + ".bvh")
    if content is None:
        content = "HIERARCHY\nROOT clip\n"
    with open(full, "w", encoding="utf-8") as handle:
        handle.write(content)
    return full


class SeedVerifyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="seed_verify_test_")
        self.metadata = os.path.join(self.tmp, "seed_metadata_v004.csv")
        self.g1 = os.path.join(self.tmp, "g1", "csv")
        self.soma = os.path.join(self.tmp, "soma_uniform", "bvh")
        os.makedirs(self.g1, exist_ok=True)
        os.makedirs(self.soma, exist_ok=True)
        self.rows = [("clip_a", "230509"), ("clip_b", "230509"), ("clip_c", "230510")]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def build_full_tree(self):
        write_metadata(self.metadata, self.rows)
        for filename, session in self.rows:
            write_csv_clip(self.g1, session, filename)
            write_bvh_clip(self.soma, session, filename)

    def run_verify(self, sessions=None):
        cmd = [
            sys.executable,
            SCRIPT,
            "--metadata", self.metadata,
            "--g1-csv", self.g1,
            "--soma-bvh", self.soma,
        ]
        if sessions:
            cmd += ["--sessions", sessions]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return proc.returncode, proc.stdout.decode("utf-8", "replace")

    # --- 1. complete match ---------------------------------------------------
    def test_complete_tree_matches(self):
        self.build_full_tree()
        rc, out = self.run_verify(sessions=self.g1)
        self.assertEqual(rc, 0, out)
        self.assertIn("SEED_META_MATCH matched=6 missing=0 extra=0", out)
        self.assertIn("SEED_EXTRACT_ZERO_BYTE count=0", out)
        self.assertIn("SEED_META_SESSION session=230509 expected=2 actual=2", out)
        self.assertIn("SEED_META_SESSION session=230510 expected=1 actual=1", out)
        self.assertIn("SEED_META_OK", out)
        self.assertNotIn("SEED_META_FAIL", out)

    # --- 2. missing clip -----------------------------------------------------
    def test_missing_clip_is_reported(self):
        self.build_full_tree()
        os.remove(os.path.join(self.g1, "230509", "clip_b.csv"))
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("missing=1", out)
        self.assertIn("SEED_META_FAIL", out)
        self.assertNotIn("SEED_META_OK", out)

    # --- 3. extra clip -------------------------------------------------------
    def test_extra_clip_is_reported(self):
        self.build_full_tree()
        write_csv_clip(self.g1, "230509", "clip_zzz")
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("extra=1", out)
        self.assertIn("SEED_META_FAIL", out)
        self.assertNotIn("SEED_META_OK", out)

    # --- 4. zero byte clip ---------------------------------------------------
    def test_zero_byte_clip_is_counted(self):
        self.build_full_tree()
        with open(os.path.join(self.g1, "230509", "clip_b.csv"), "w", encoding="utf-8"):
            pass
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_EXTRACT_ZERO_BYTE count=1", out)
        self.assertIn("SEED_META_FAIL", out)

    # --- 5. session mismatch -------------------------------------------------
    def test_session_mismatch_is_reported(self):
        self.build_full_tree()
        os.makedirs(os.path.join(self.g1, "230511"), exist_ok=True)
        os.rename(os.path.join(self.g1, "230510", "clip_c.csv"),
                  os.path.join(self.g1, "230511", "clip_c.csv"))
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_SESSION_MISMATCH", out)
        self.assertIn("missing=1", out)
        self.assertIn("extra=1", out)

    # --- 6. malformed metadata ----------------------------------------------
    def test_metadata_without_required_columns_is_rejected(self):
        with open(self.metadata, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(["filename", "other"])
            writer.writerow(["clip_a", "x"])
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_FAIL", out)
        self.assertIn("missing columns", out)

    def test_broken_basename_rule_is_rejected(self):
        with open(self.metadata, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(CSV_HEADER.split(","))
            writer.writerow(["clip_a", "g1/csv/230509/other_name.csv",
                             "soma_uniform/bvh/230509/other_name.bvh"])
        write_csv_clip(self.g1, "230509", "other_name")
        write_bvh_clip(self.soma, "230509", "other_name")
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_BASENAME_MISMATCH", out)

    def test_missing_metadata_file_is_rejected(self):
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_FAIL", out)

    # --- 7. unreadable samples ----------------------------------------------
    def test_malformed_csv_sample_is_rejected(self):
        self.build_full_tree()
        with open(os.path.join(self.g1, "230509", "clip_a.csv"), "w", encoding="utf-8") as handle:
            handle.write("no commas here at all\n")
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_SAMPLE_FAIL", out)

    def test_malformed_bvh_sample_is_rejected(self):
        self.build_full_tree()
        with open(os.path.join(self.soma, "230509", "clip_a.bvh"), "w", encoding="utf-8") as handle:
            handle.write("NOT A HIERARCHY\n")
        rc, out = self.run_verify()
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_SAMPLE_FAIL", out)

    # --- 8. missing session directory ---------------------------------------
    def test_missing_session_directory_is_reported(self):
        self.build_full_tree()
        rc, out = self.run_verify(sessions=os.path.join(self.tmp, "nowhere"))
        self.assertNotEqual(rc, 0, out)
        self.assertIn("SEED_META_SESSION_DIR_MISSING", out)


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SeedVerifyTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = result.wasSuccessful()
    print("SEED_TESTS_OK" if passed else "SEED_TESTS_FAILED")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
