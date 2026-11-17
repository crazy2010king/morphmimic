#!/usr/bin/env python3
"""repro/tests/test_doc.py — offline unit tests for the reproduction record
verifier (slice S09, task T2).

Standard library ONLY (unittest / os / shutil / subprocess / sys /
tempfile).  No network, no GPU, no container: every fixture is created on
the fly in a tempfile.mkdtemp() directory and removed afterwards.  The
repository's real payload (data/, logs/, runs/, out/) and .gsd/ are NEVER
read or written.

The container's system python3 has NO numpy — the decision base must
therefore stay importable with the bare interpreter.

Covered decisions:
  * parse_sections (front matter + nine chapters, unterminated chapters)
  * extract_evidence_table (missing markers, malformed table, header row)
  * check_evidence_rows (missing file, absent key output, empty columns)
  * count_deviation_rows (header/separator rows never count)
  * scan_tokens (the plaintext token pattern)
  * read_sha256sums / verify_sha256sums (missing file, digest mismatch)
  * read_eval_csv / eval_completion (unparsable `failed` counts as failure)
  * read_compare_csv / compare_delta_means
  * read_curve_csv / curve_step_coverage
  * verify_document: the healthy case AND every negative reason
  * verify_mirror (missing mirror, differing mirror, identical mirror)
  * format_ok / format_fail (a FAIL line never carries an OK marker)
  * the CLI of the decision base (`verify` / `mirror` / `report`)

Run locally:  python3 repro/tests/test_doc.py
"""

from __future__ import annotations

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

import doc  # noqa: E402


DOC_PY = os.path.join(
  os.path.dirname(os.path.abspath(__file__)), "..", "lib", "doc.py")

RECORD_NAME = "MorphMimic完整复现记录.md"

#: The number of eval rows / comparison rows of the fixture.
EVAL_ROWS = 3
COMPARE_ROWS = 2
CURVE_MIN_STEP = 50
CURVE_MAX_STEP = 26413


def _write(path, text):
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)


def build_fixture(root):
  """Build a COMPLETE, compliant fixture repository under `root`."""
  record = os.path.join(root, "docs", "code_read", RECORD_NAME)
  mirror = os.path.join(root, "docs", "code_doc", RECORD_NAME)

  # --- the evidence files --------------------------------------------------
  _write(os.path.join(root, "logs", "env", "evidence_env.txt"),
         "GPU_RTX_4090\nMEM_TOTAL_GB=245\n")
  _write(os.path.join(root, "logs", "env", "evidence_train.txt"),
         "TRAIN_CURVES_OK events_files=10 tags=52 rows=28120 steps=26413\n")
  _write(os.path.join(root, "logs", "env", "evidence_eval.txt"),
         "EVAL_VERIFY_OK eval_rows=3 compare_rows=2\n")

  # --- the exported policy + its digests -----------------------------------
  for directory in ("out/g1_amber", "runs/official/morphmimic_policy"):
    base = os.path.join(root, directory)
    _write(os.path.join(base, "policy.onnx"), "fake-onnx-bytes\n")
    _write(os.path.join(base, "g1_amber.json"), '{"robot": "g1_amber"}\n')
    digests = []
    for name in ("g1_amber.json", "policy.onnx"):
      digests.append("%s  %s" % (doc.sha256_file(os.path.join(base, name)),
                                 name))
    _write(os.path.join(base, "SHA256SUMS"), "\n".join(digests) + "\n")

  # --- the eval tables -----------------------------------------------------
  header = "name,frames,failed,fail_frame,norm_return,steps\n"
  for name in ("eval_motion_1h.csv", "eval_human_full_1h.csv"):
    rows = []
    for index in range(EVAL_ROWS):
      rows.append("clip_%02d__A000,%d,False,-1,0.5,%d\n" % (index, 100 + index,
                                                             99 + index))
    _write(os.path.join(root, "runs", "eval", name), header + "".join(rows))

  # --- the comparison table ------------------------------------------------
  compare_header = ("clip,frames,self_result,self_joint_err_rms_rad,"
                    "self_body_err_mean_m,self_end_drift_m,official_result,"
                    "official_joint_err_rms_rad,official_body_err_mean_m,"
                    "official_end_drift_m,delta_joint_err_rms_rad,"
                    "delta_body_err_mean_m,delta_end_drift_m\n")
  compare_rows = []
  for index in range(COMPARE_ROWS):
    mine = 0.1 + 0.01 * index
    theirs = 0.2 + 0.01 * index
    compare_rows.append(
      "clip_%02d,100,completed,%f,%f,%f,completed,%f,%f,%f,%f,%f,%f\n" % (
        index, mine, mine, mine, theirs, theirs, theirs,
        mine - theirs, mine - theirs, mine - theirs))
  _write(os.path.join(root, "runs", "official", "compare_self_vs_official.csv"),
         compare_header + "".join(compare_rows))

  # --- the training curve --------------------------------------------------
  curve = ["step,tag,value\n"]
  for step in (CURVE_MIN_STEP, CURVE_MAX_STEP):
    curve.append("%d,wm/state_loss,0.5\n" % step)
  _write(os.path.join(root, "runs", "train_curves",
                      "g1_amber_1h_curves.csv"), "".join(curve))

  # --- the record ----------------------------------------------------------
  compare_rows, _reason = doc.read_compare_csv(
    os.path.join(root, "runs", "official", "compare_self_vs_official.csv"))
  means = doc.compare_delta_means(compare_rows)
  deviations = []
  for index in range(20):
    deviations.append("| %d | README 原文 | 我们的做法 | 原因 | 代价 |"
                      % (index + 1))
  body = []
  body.append("# MorphMimic 完整复现记录\n")
  body.append("\n**流程复现，非数值等价复现**。\n")
  body.append("\n<!-- DOC_SECTION:1 -->\n## 1. 环境事实表\n\n正文\n")
  body.append("<!-- /DOC_SECTION:1 -->\n")
  body.append("\n<!-- DOC_SECTION:2 -->\n## 2. 每阶段命令原文与关键输出\n\n正文\n")
  body.append("<!-- /DOC_SECTION:2 -->\n")
  body.append("\n<!-- DOC_SECTION:3 -->\n## 3. 对 README 的偏离清单\n\n")
  body.append("| 序号 | README 原文 | 我们的做法 | 原因 | 代价 |\n")
  body.append("|---|---|---|---|---|\n")
  body.append("\n".join(deviations) + "\n")
  body.append("<!-- /DOC_SECTION:3 -->\n")
  body.append("\n<!-- DOC_SECTION:4 -->\n## 4. 已分析未执行清单\n\n")
  body.append("| 项 | 已分析到的内容 | 为何未执行 |\n|---|---|---|\n")
  body.append("| PICO 头显实机佩戴 | 佩戴流程 | 无头显 |\n")
  body.append("| 真机 G1 物理联调 | 联调接口 | 无真机 |\n")
  body.append("| 官方 x2-t2 对照 | 对照口径 | 官方无权重 |\n")
  body.append("<!-- /DOC_SECTION:4 -->\n")
  body.append("\n<!-- DOC_SECTION:5 -->\n## 5. 产物路径与 SHA-256\n\n正文\n")
  body.append("<!-- /DOC_SECTION:5 -->\n")
  body.append("\n<!-- DOC_SECTION:6 -->\n## 6. 训练曲线数据\n\n正文\n")
  body.append("<!-- /DOC_SECTION:6 -->\n")
  body.append("\n<!-- DOC_SECTION:7 -->\n## 7. eval 对照表\n\n")
  body.append("Δ 均值（逐指标单独成行，便于逐项重算比对）：\n")
  body.append("| 指标 | Δ 均值 |\n|---|---|\n")
  for metric in doc.DELTA_METRICS:
    body.append("| %s | %s |\n" % (metric, doc._fmt_number(means[metric])))
  body.append("<!-- /DOC_SECTION:7 -->\n")
  body.append("\n<!-- DOC_SECTION:8 -->\n## 8. 踩坑记录\n\n正文\n")
  body.append("<!-- /DOC_SECTION:8 -->\n")
  body.append("\n<!-- DOC_SECTION:9 -->\n## 9. 明文 token 撤销提醒\n\n正文\n")
  body.append("<!-- /DOC_SECTION:9 -->\n")
  body.append("\n<!-- DOC_EVIDENCE_TABLE_START -->\n")
  body.append("| 结论 | 复现命令 | 证据文件（相对仓库根） | 关键输出 |\n")
  body.append("|---|---|---|---|\n")
  body.append("| 环境为 RTX 4090 | bash repro/00_env.sh | "
              "logs/env/evidence_env.txt | GPU_RTX_4090 |\n")
  body.append("| 训练止于 26413 迭代 | bash repro/27_train_curves.sh verify | "
              "logs/env/evidence_train.txt | TRAIN_CURVES_OK |\n")
  body.append("| eval 两接口 490 行 | bash repro/23_eval.sh | "
              "logs/env/evidence_eval.txt | EVAL_VERIFY_OK |\n")
  body.append("<!-- DOC_EVIDENCE_TABLE_END -->\n")
  _write(record, "".join(body))
  _write(mirror, "".join(body))
  return record, mirror


class FixtureCase(unittest.TestCase):
  """A test case with a throwaway fixture repository."""

  def setUp(self):
    self.root = tempfile.mkdtemp(prefix="doc_fixture_")
    self.addCleanup(shutil.rmtree, self.root, True)
    self.record, self.mirror = build_fixture(self.root)

  # -- helpers --------------------------------------------------------------
  def read_record(self):
    with open(self.record, encoding="utf-8") as handle:
      return handle.read()

  def verify(self, **kwargs):
    options = dict(
      doc_path=self.record,
      repo_root=self.root,
      eval_motion_csv=os.path.join(self.root, "runs", "eval", "eval_motion_1h.csv"),
      eval_human_csv=os.path.join(self.root, "runs", "eval", "eval_human_full_1h.csv"),
      compare_csv=os.path.join(self.root, "runs", "official",
                               "compare_self_vs_official.csv"),
      curve_csv=os.path.join(self.root, "runs", "train_curves",
                             "g1_amber_1h_curves.csv"),
      self_sha_dir=os.path.join(self.root, "out", "g1_amber"),
      official_sha_dir=os.path.join(self.root, "runs", "official",
                                    "morphmimic_policy"),
      expect_eval_rows=EVAL_ROWS,
      expect_compare_rows=COMPARE_ROWS,
      expect_curve_min_step=CURVE_MIN_STEP,
      expect_curve_max_step=CURVE_MAX_STEP,
      expect_completion=1.0,
      min_deviations=20)
    options.update(kwargs)
    return doc.verify_document(**options)

  def rewrite_record(self, transform):
    with open(self.record, "r", encoding="utf-8") as handle:
      text = handle.read()
    with open(self.record, "w", encoding="utf-8") as handle:
      handle.write(transform(text))


class ParseSectionsTest(unittest.TestCase):

  def test_front_matter_and_nine_chapters(self):
    text = ("前言\n<!-- DOC_SECTION:1 -->\nA\n<!-- /DOC_SECTION:1 -->\n"
            "<!-- DOC_SECTION:2 -->\nB\n<!-- /DOC_SECTION:2 -->\n")
    sections = doc.parse_sections(text)
    self.assertIn("前言", sections[0])
    self.assertIn("A", sections[1])
    self.assertIn("B", sections[2])

  def test_unterminated_chapter_runs_until_the_next_marker(self):
    text = ("<!-- DOC_SECTION:1 -->\nA\n<!-- DOC_SECTION:2 -->\nB\n")
    sections = doc.parse_sections(text)
    self.assertIn("A", sections[1])
    self.assertIn("B", sections[2])

  def test_text_without_markers_is_the_front_matter(self):
    sections = doc.parse_sections("just prose")
    self.assertEqual(list(sections.keys()), [0])


class EvidenceTableTest(unittest.TestCase):

  def test_missing_markers(self):
    rows, reason = doc.extract_evidence_table("no table here")
    self.assertIsNone(rows)
    self.assertEqual(reason, "evidence-table-missing")

  def test_malformed_table(self):
    text = (doc.EVIDENCE_TABLE_START + "\n| a | b |\n|---|---|\n"
            + doc.EVIDENCE_TABLE_END)
    rows, reason = doc.extract_evidence_table(text)
    self.assertIsNone(rows)
    self.assertEqual(reason, "evidence-table-malformed")

  def test_header_row_is_dropped(self):
    text = (doc.EVIDENCE_TABLE_START + "\n"
            "| 结论 | 复现命令 | 证据文件 | 关键输出 |\n|---|---|---|---|\n"
            "| 结论 A | cmd | logs/a.txt | MARK |\n"
            + doc.EVIDENCE_TABLE_END)
    rows, reason = doc.extract_evidence_table(text)
    self.assertIsNone(reason)
    self.assertEqual(len(rows), 1)
    self.assertEqual(rows[0]["conclusion"], "结论 A")
    self.assertEqual(rows[0]["path"], "logs/a.txt")


class EvidenceRowsTest(FixtureCase):

  def test_healthy_rows(self):
    rows, reason = doc.extract_evidence_table(
      self.read_record())
    self.assertIsNone(reason)
    facts, reason = doc.check_evidence_rows(self.root, rows)
    self.assertIsNone(reason)
    self.assertEqual(facts["rows"], 3)

  def test_missing_evidence_file(self):
    rows, _ = doc.extract_evidence_table(
      self.read_record())
    rows[0]["path"] = "logs/env/no-such-file.txt"
    facts, reason = doc.check_evidence_rows(self.root, rows)
    self.assertEqual(reason, "evidence-path-missing")
    self.assertEqual(facts["bad"], 0)

  def test_absent_key_output(self):
    rows, _ = doc.extract_evidence_table(
      self.read_record())
    rows[0]["output"] = "THIS_STRING_IS_NOT_IN_THE_FILE"
    facts, reason = doc.check_evidence_rows(self.root, rows)
    self.assertEqual(reason, "evidence-marker-missing")

  def test_empty_conclusion(self):
    rows, _ = doc.extract_evidence_table(
      self.read_record())
    rows[0]["conclusion"] = "  "
    facts, reason = doc.check_evidence_rows(self.root, rows)
    self.assertEqual(reason, "evidence-row-invalid")

  def test_empty_command(self):
    rows, _ = doc.extract_evidence_table(
      self.read_record())
    rows[0]["command"] = ""
    facts, reason = doc.check_evidence_rows(self.root, rows)
    self.assertEqual(reason, "evidence-row-invalid")

  def test_the_marker_match_is_case_insensitive(self):
    rows, _ = doc.extract_evidence_table(
      self.read_record())
    rows[0]["output"] = "gpu_rtx_4090"
    facts, reason = doc.check_evidence_rows(self.root, rows)
    self.assertIsNone(reason)


class DeviationRowsTest(unittest.TestCase):

  def test_header_and_separator_never_count(self):
    body = ("| a | b |\n|---|---|\n| 1 | x |\n| 2 | y |\n")
    self.assertEqual(doc.count_deviation_rows(body), 2)

  def test_empty_body(self):
    self.assertEqual(doc.count_deviation_rows(""), 0)
    self.assertEqual(doc.count_deviation_rows(None), 0)

  def test_several_tables(self):
    body = ("| a |\n|---|\n| 1 |\n| 2 |\n\ntext\n\n| b |\n|---|\n| 3 |\n")
    self.assertEqual(doc.count_deviation_rows(body), 3)


class TokenScanTest(unittest.TestCase):

  def test_a_token_is_detected(self):
    self.assertEqual(len(doc.scan_tokens("key hf_abcdefghij0123456789 end")), 1)

  def test_a_short_suffix_is_not_a_token(self):
    self.assertEqual(doc.scan_tokens("hf_short"), [])

  def test_the_pattern_itself_is_not_a_token(self):
    self.assertEqual(doc.scan_tokens("正则 hf_[A-Za-z0-9]{20,}"), [])


class ShaTest(FixtureCase):

  def test_healthy_digests(self):
    facts, reason = doc.verify_sha256sums(
      os.path.join(self.root, "out", "g1_amber"))
    self.assertIsNone(reason)
    self.assertEqual(len(facts["checked"]), 2)

  def test_a_tampered_file(self):
    target = os.path.join(self.root, "out", "g1_amber", "policy.onnx")
    with open(target, "a", encoding="utf-8") as handle:
      handle.write("tampered\n")
    facts, reason = doc.verify_sha256sums(
      os.path.join(self.root, "out", "g1_amber"))
    self.assertEqual(reason, "sha-mismatch")
    self.assertEqual(facts["mismatch"], "policy.onnx")

  def test_a_missing_file(self):
    os.remove(os.path.join(self.root, "out", "g1_amber", "policy.onnx"))
    facts, reason = doc.verify_sha256sums(
      os.path.join(self.root, "out", "g1_amber"))
    self.assertEqual(reason, "sha-missing")

  def test_a_missing_directory(self):
    facts, reason = doc.verify_sha256sums(os.path.join(self.root, "no-such"))
    self.assertEqual(reason, "sha-missing")


class EvalTest(FixtureCase):

  def test_healthy_table(self):
    rows, reason = doc.read_eval_csv(
      os.path.join(self.root, "runs", "eval", "eval_motion_1h.csv"))
    self.assertIsNone(reason)
    self.assertEqual(len(rows), EVAL_ROWS)
    clips, failures, completion = doc.eval_completion(rows)
    self.assertEqual(clips, EVAL_ROWS)
    self.assertEqual(failures, 0)
    self.assertAlmostEqual(completion, 1.0)

  def test_an_unparsable_failed_cell_counts_as_a_failure(self):
    clips, failures, completion = doc.eval_completion(
      [{"failed": "maybe"}, {"failed": "False"}])
    self.assertEqual(clips, 2)
    self.assertEqual(failures, 1)
    self.assertAlmostEqual(completion, 0.5)

  def test_a_missing_file(self):
    rows, reason = doc.read_eval_csv(os.path.join(self.root, "no.csv"))
    self.assertIsNone(rows)
    self.assertEqual(reason, "eval-csv-missing")

  def test_a_table_without_the_failed_column(self):
    path = os.path.join(self.root, "runs", "eval", "broken.csv")
    _write(path, "name,frames\nclip,10\n")
    rows, reason = doc.read_eval_csv(path)
    self.assertIsNone(rows)
    self.assertEqual(reason, "eval-csv-parse-failed")


class CompareTest(FixtureCase):

  def test_healthy_table(self):
    rows, reason = doc.read_compare_csv(
      os.path.join(self.root, "runs", "official",
                   "compare_self_vs_official.csv"))
    self.assertIsNone(reason)
    self.assertEqual(len(rows), COMPARE_ROWS)
    means = doc.compare_delta_means(rows)
    self.assertAlmostEqual(means["joint_err_rms_rad"], -0.1, places=6)

  def test_a_missing_file(self):
    rows, reason = doc.read_compare_csv(os.path.join(self.root, "no.csv"))
    self.assertIsNone(rows)
    self.assertEqual(reason, "compare-missing")

  def test_a_table_without_a_delta_column(self):
    path = os.path.join(self.root, "runs", "official", "broken.csv")
    _write(path, "clip,frames\nclip,10\n")
    rows, reason = doc.read_compare_csv(path)
    self.assertIsNone(rows)
    self.assertEqual(reason, "compare-parse-failed")


class CurveTest(FixtureCase):

  def test_healthy_curve(self):
    rows, reason = doc.read_curve_csv(
      os.path.join(self.root, "runs", "train_curves",
                   "g1_amber_1h_curves.csv"))
    self.assertIsNone(reason)
    coverage = doc.curve_step_coverage(rows)
    self.assertEqual(coverage["min_step"], CURVE_MIN_STEP)
    self.assertEqual(coverage["max_step"], CURVE_MAX_STEP)
    self.assertEqual(coverage["n_rows"], 2)

  def test_a_missing_curve(self):
    rows, reason = doc.read_curve_csv(os.path.join(self.root, "no.csv"))
    self.assertIsNone(rows)
    self.assertEqual(reason, "curve-missing")

  def test_a_malformed_curve(self):
    path = os.path.join(self.root, "runs", "train_curves", "broken.csv")
    _write(path, "a,b,c\n1,2,3\n")
    rows, reason = doc.read_curve_csv(path)
    self.assertIsNone(rows)
    self.assertEqual(reason, "curve-parse-failed")


class VerifyDocumentTest(FixtureCase):

  def test_the_healthy_record(self):
    facts, reason = self.verify()
    self.assertIsNone(reason)
    self.assertEqual(facts["sections"], 9)
    self.assertEqual(facts["evidence_rows"], 3)
    self.assertEqual(facts["sha_ok"], 1)
    self.assertEqual(facts["eval_rows"], EVAL_ROWS)
    self.assertEqual(facts["compare_rows"], COMPARE_ROWS)
    self.assertEqual(facts["curve_rows"], 2)

  def test_a_missing_record(self):
    os.remove(self.record)
    facts, reason = self.verify()
    self.assertEqual(reason, "doc-missing")

  def test_an_empty_record(self):
    _write(self.record, "   \n")
    facts, reason = self.verify()
    self.assertEqual(reason, "doc-empty")

  def test_a_missing_chapter(self):
    self.rewrite_record(
      lambda text: text.replace("<!-- DOC_SECTION:4 -->", "")
                       .replace("<!-- /DOC_SECTION:4 -->", ""))
    facts, reason = self.verify()
    self.assertEqual(reason, "section-missing")

  def test_a_missing_process_declaration(self):
    self.rewrite_record(
      lambda text: text.replace("**流程复现，非数值等价复现**", "只是一份记录"))
    facts, reason = self.verify()
    self.assertEqual(reason, "process-replication-missing")

  def test_a_missing_unexecuted_item(self):
    self.rewrite_record(lambda text: text.replace("PICO", "头显"))
    facts, reason = self.verify()
    self.assertEqual(reason, "unexecuted-section-missing")

  def test_a_too_short_deviation_list(self):
    self.rewrite_record(
      lambda text: text.replace("| 20 | README 原文 | 我们的做法 | 原因 | 代价 |\n",
                                ""))
    facts, reason = self.verify()
    self.assertEqual(reason, "deviation-section-missing")

  def test_a_missing_evidence_table(self):
    self.rewrite_record(
      lambda text: text.replace(doc.EVIDENCE_TABLE_START, "")
                       .replace(doc.EVIDENCE_TABLE_END, ""))
    facts, reason = self.verify()
    self.assertEqual(reason, "evidence-table-missing")

  def test_an_evidence_path_that_does_not_exist(self):
    self.rewrite_record(
      lambda text: text.replace("logs/env/evidence_env.txt",
                                "logs/env/no-such-evidence.txt"))
    facts, reason = self.verify()
    self.assertEqual(reason, "evidence-path-missing")

  def test_an_evidence_marker_that_does_not_match(self):
    self.rewrite_record(
      lambda text: text.replace("| GPU_RTX_4090 |",
                                "| GPU_RTX_5090_NOT_IN_THE_FILE |"))
    facts, reason = self.verify()
    self.assertEqual(reason, "evidence-marker-missing")

  def test_a_tampered_digest(self):
    with open(os.path.join(self.root, "out", "g1_amber", "policy.onnx"), "a",
              encoding="utf-8") as handle:
      handle.write("tampered\n")
    facts, reason = self.verify()
    self.assertEqual(reason, "sha-mismatch")

  def test_a_wrong_eval_row_count(self):
    path = os.path.join(self.root, "runs", "eval", "eval_motion_1h.csv")
    with open(path, encoding="utf-8") as handle:
      lines = handle.read().splitlines()
    _write(path, "\n".join(lines[:-1]) + "\n")
    facts, reason = self.verify()
    self.assertEqual(reason, "eval-row-count-mismatch")

  def test_a_wrong_completion(self):
    path = os.path.join(self.root, "runs", "eval", "eval_motion_1h.csv")
    with open(path, encoding="utf-8") as handle:
      text = handle.read()
    _write(path, text.replace(",False,-1,", ",True,7,", 1))
    facts, reason = self.verify()
    self.assertEqual(reason, "completion-mismatch")

  def test_a_wrong_comparison_row_count(self):
    path = os.path.join(self.root, "runs", "official",
                        "compare_self_vs_official.csv")
    with open(path, encoding="utf-8") as handle:
      lines = handle.read().splitlines()
    _write(path, "\n".join(lines[:-1]) + "\n")
    facts, reason = self.verify()
    self.assertEqual(reason, "compare-row-count-mismatch")

  def test_a_delta_mean_that_is_not_quoted(self):
    self.rewrite_record(
      lambda text: text.replace("| joint_err_rms_rad | -0.100000 |",
                                "| joint_err_rms_rad | 0.000000 |"))
    facts, reason = self.verify()
    self.assertEqual(reason, "compare-delta-mismatch")

  def test_a_missing_curve(self):
    os.remove(os.path.join(self.root, "runs", "train_curves",
                           "g1_amber_1h_curves.csv"))
    facts, reason = self.verify()
    self.assertEqual(reason, "curve-missing")

  def test_a_curve_that_stops_early(self):
    path = os.path.join(self.root, "runs", "train_curves",
                        "g1_amber_1h_curves.csv")
    _write(path, "step,tag,value\n50,wm/state_loss,0.5\n")
    facts, reason = self.verify()
    self.assertEqual(reason, "curve-step-missing")

  def test_a_leaked_token(self):
    self.rewrite_record(
      lambda text: text + "\n令牌：hf_abcdefghij0123456789ABCDEF\n")
    facts, reason = self.verify()
    self.assertEqual(reason, "token-leaked")


class MirrorTest(FixtureCase):

  def test_an_identical_mirror(self):
    facts, reason = doc.verify_mirror(self.record, self.mirror)
    self.assertIsNone(reason)
    self.assertEqual(facts["mirror_match"], 1)

  def test_a_missing_mirror(self):
    os.remove(self.mirror)
    facts, reason = doc.verify_mirror(self.record, self.mirror)
    self.assertEqual(reason, "mirror-missing")

  def test_a_differing_mirror(self):
    with open(self.mirror, "a", encoding="utf-8") as handle:
      handle.write("\ndifferent\n")
    facts, reason = doc.verify_mirror(self.record, self.mirror)
    self.assertEqual(reason, "mirror-mismatch")

  def test_a_missing_record(self):
    os.remove(self.record)
    facts, reason = doc.verify_mirror(self.record, self.mirror)
    self.assertEqual(reason, "mirror-missing")


class FormatTest(unittest.TestCase):

  def test_the_mandatory_reason_set_is_present(self):
    mandatory = (
      "doc-missing", "doc-empty", "section-missing",
      "evidence-path-missing", "evidence-marker-missing", "sha-mismatch",
      "eval-row-count-mismatch", "compare-row-count-mismatch",
      "completion-mismatch", "curve-missing", "curve-step-missing",
      "token-leaked", "process-replication-missing",
      "unexecuted-section-missing", "deviation-section-missing",
      "mirror-missing", "mirror-mismatch")
    for reason in mandatory:
      self.assertIn(reason, doc.REASONS)

  def test_the_reason_set_has_no_duplicates(self):
    self.assertEqual(len(doc.REASONS), len(set(doc.REASONS)))

  def test_format_ok(self):
    self.assertEqual(doc.format_ok("DOC_VERIFY", sections=9),
                     "DOC_VERIFY_OK sections=9")

  def test_format_fail_carries_no_ok_marker(self):
    line = doc.format_fail("DOC_VERIFY", "doc-missing")
    self.assertEqual(line, "DOC_VERIFY_FAIL reason=doc-missing")
    self.assertNotIn("_OK", line)

  def test_an_unknown_reason_falls_back_into_the_fixed_set(self):
    line = doc.format_fail("DOC_VERIFY", "not-a-reason")
    self.assertIn("reason=", line)
    self.assertIn(line.split("reason=")[1], doc.REASONS)


class CliTest(FixtureCase):

  def _run(self, *args):
    return subprocess.run([sys.executable, DOC_PY] + list(args),
                          capture_output=True, text=True)

  def test_the_healthy_verify(self):
    result = self._run(
      "verify", "--doc", self.record, "--repo-root", self.root,
      "--eval-motion-csv", os.path.join(self.root, "runs", "eval",
                                        "eval_motion_1h.csv"),
      "--eval-human-csv", os.path.join(self.root, "runs", "eval",
                                       "eval_human_full_1h.csv"),
      "--compare-csv", os.path.join(self.root, "runs", "official",
                                    "compare_self_vs_official.csv"),
      "--curve-csv", os.path.join(self.root, "runs", "train_curves",
                                  "g1_amber_1h_curves.csv"),
      "--self-sha-dir", os.path.join(self.root, "out", "g1_amber"),
      "--official-sha-dir", os.path.join(self.root, "runs", "official",
                                         "morphmimic_policy"),
      "--expect-eval-rows", str(EVAL_ROWS),
      "--expect-compare-rows", str(COMPARE_ROWS),
      "--expect-curve-max-step", str(CURVE_MAX_STEP))
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertIn("DOC_VERIFY_OK", result.stdout)
    self.assertIn("sections=9", result.stdout)
    self.assertIn("sha_ok=1", result.stdout)

  def test_a_negative_verify(self):
    os.remove(self.record)
    result = self._run("verify", "--doc", self.record,
                        "--repo-root", self.root)
    self.assertEqual(result.returncode, 1)
    self.assertIn("DOC_VERIFY_FAIL reason=doc-missing", result.stdout)
    self.assertNotIn("DOC_VERIFY_OK", result.stdout)

  def test_the_mirror_cli(self):
    result = self._run("mirror", "--doc", self.record, "--mirror", self.mirror)
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertIn("DOC_MIRROR_OK mirror_match=1", result.stdout)

  def test_the_report_cli(self):
    result = self._run("report", "--doc", self.record,
                       "--repo-root", self.root,
                       "--expect-eval-rows", str(EVAL_ROWS),
                       "--expect-compare-rows", str(COMPARE_ROWS),
                       "--expect-curve-max-step", str(CURVE_MAX_STEP))
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertIn("DOC_REPORT_EVAL", result.stdout)
    self.assertNotIn("DOC_VERIFY_OK", result.stdout)


if __name__ == "__main__":
  unittest.main()
