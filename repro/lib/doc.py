#!/usr/bin/env python3
"""repro/lib/doc.py — the decision base of the reproduction record verifier
(slice S09, task T2: FIRST PROOF).

Standard library ONLY (argparse / csv / hashlib / json / math / os / re /
sys).  NO numpy, NO pandas, NO torch, NO yaml: the container's system
python3 has none of them, and the verifier must run on the host AND inside
the ros_dev container with the very same interpreter.

WHY A SEPARATE DECISION BASE
  "Every conclusion of the reproduction record is traceable to a concrete
  command and its output" is, until now, a promise in prose.  This module
  turns it into a decidable contract, so that the record (written in T3) is
  written AGAINST a machine check instead of being checked after the fact.
  Exactly ONE parser decides; `repro/lib/doc.sh` is a thin wrapper that only
  selects the interpreter and forwards the arguments (project convention
  P001).

THE DOCUMENT CONTRACT (what a compliant record must carry)
  1. Nine chapters, each delimited by the section markers
         <!-- DOC_SECTION:<n> --> ... <!-- /DOC_SECTION:<n> -->
     with n = 1..9 and these titles:
        1 环境事实表          2 每阶段命令原文与关键输出
        3 对 README 的偏离清单 4 已分析未执行清单
        5 产物路径与 SHA-256   6 训练曲线数据
        7 eval 对照表         8 踩坑记录
        9 明文 token 撤销提醒
  2. A front-matter declaration (BEFORE the first section marker) that
     contains "流程复现" and "非数值等价复现": the record reproduces the
     PROCESS, not a numerical equivalence.
  3. Chapter 3 holds the deviation list (at least `--min-deviations`
     markdown table rows, default 20).
  4. Chapter 4 names the three "analysed but not executed" items: the PICO
     headset on-body wear, the real G1 hardware coupling, and the official
     x2-t2 comparison.
  5. An evidence index table, delimited by
         <!-- DOC_EVIDENCE_TABLE_START --> ... <!-- DOC_EVIDENCE_TABLE_END -->
     with exactly four columns:
         结论 | 复现命令 | 证据文件（相对仓库根） | 关键输出（须能在证据文件中 grep 到）
     Every data row must:
       * carry a non-empty conclusion and a non-empty command,
       * name an evidence file that EXISTS relative to the repository root
         (the logs//runs//out//assets/ seed-store symlinks are followed),
       * carry a key output string that IS PRESENT in that evidence file
         (case-insensitive substring).
  6. No plaintext token: the regex `hf_[A-Za-z0-9]{20,}` must not match.

WHAT IS RECOMPUTED (never taken from the document's own prose)
  * the SHA-256 digests of out/g1_amber/SHA256SUMS and
    runs/official/morphmimic_policy/SHA256SUMS (the digests are recomputed
    from the bytes on disk),
  * the row count of BOTH eval CSVs (490 each),
  * the completion of both eval tables (recomputed from the `failed`
    column -- the document's self-report is never trusted),
  * the row count of the self-vs-official comparison table (49) and the
    MEANS of its three delta columns (the record must quote them),
  * the step coverage of the training curve CSV.

Pure functions
  parse_sections(text)            -> {id: body}
  extract_evidence_table(text)    -> (rows, reason)
  check_evidence_rows(root, rows) -> reason
  read_sha256sums(directory)      -> (entries, reason)
  verify_sha256sums(directory)    -> (facts, reason)
  read_eval_csv(path)             -> (rows, reason)
  eval_completion(rows)           -> (clips, failures, completion)
  read_compare_csv(path)          -> (rows, reason)
  compare_delta_means(rows)       -> {metric: mean}
  read_curve_csv(path)            -> (rows, reason)
  curve_step_coverage(rows)       -> {min_step, max_step, n_rows}
  scan_tokens(text)               -> [match, ...]
  verify_document(...)            -> (facts, reason)
  verify_mirror(doc, mirror)      -> (facts, reason)
  format_ok(kind, **kv)           -> str
  format_fail(kind, reason)       -> str

Thin CLI (for the shell wrappers):
  doc.py verify --doc FILE --repo-root DIR [...]   -> DOC_VERIFY_OK / _FAIL
  doc.py mirror --doc FILE --mirror FILE          -> DOC_MIRROR_OK / _FAIL
  doc.py report --doc FILE --repo-root DIR [...]   -> DOC_REPORT_* lines

Exit code 0 == the decision is positive; 1 == the decision is negative (the
reason is printed on stdout as `reason=...`).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import os
import re
import sys

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------

#: The fixed failure-reason set.  Every negative path uses one of these.
REASONS = (
  # the document itself
  "doc-missing",
  "doc-empty",
  "section-missing",
  "process-replication-missing",
  "unexecuted-section-missing",
  "deviation-section-missing",
  # the evidence index table
  "evidence-table-missing",
  "evidence-table-malformed",
  "evidence-row-invalid",
  "evidence-path-missing",
  "evidence-marker-missing",
  # the recomputed artefacts
  "sha-missing",
  "sha-mismatch",
  "eval-csv-missing",
  "eval-row-count-mismatch",
  "completion-mismatch",
  "compare-missing",
  "compare-parse-failed",
  "compare-row-count-mismatch",
  "compare-delta-mismatch",
  "curve-missing",
  "curve-parse-failed",
  "curve-step-missing",
  "token-leaked",
  # the mirror (docs/code_doc <-> docs/code_read)
  "mirror-missing",
  "mirror-mismatch",
)

#: The nine chapters of the reproduction record, in order.
SECTION_TITLES = (
  (1, "环境事实表"),
  (2, "每阶段命令原文与关键输出"),
  (3, "对 README 的偏离清单"),
  (4, "已分析未执行清单"),
  (5, "产物路径与 SHA-256"),
  (6, "训练曲线数据"),
  (7, "eval 对照表"),
  (8, "踩坑记录"),
  (9, "明文 token 撤销提醒"),
)

#: The tokens chapter 4 ("已分析未执行清单") must name.
UNEXECUTED_TOKENS = ("PICO", "真机", "x2", "t2")

#: The front-matter declaration of the record.
PROCESS_TOKENS = ("流程复现", "非数值等价复现")

#: The plaintext-token pattern (the record must never contain one).
TOKEN_PATTERN = r"hf_[A-Za-z0-9]{20,}"
_TOKEN_RE = re.compile(TOKEN_PATTERN)

#: The markers of the evidence index table.
EVIDENCE_TABLE_START = "<!-- DOC_EVIDENCE_TABLE_START -->"
EVIDENCE_TABLE_END = "<!-- DOC_EVIDENCE_TABLE_END -->"

#: The markers of a chapter.
_SECTION_START_RE = re.compile(r"<!--\s*DOC_SECTION:(\d+)\s*-->")
_SECTION_END_RE = re.compile(r"<!--\s*/DOC_SECTION:(\d+)\s*-->")

#: The default expected numbers (overridable on the command line).
DEFAULT_EXPECT_SECTIONS = 9
DEFAULT_EXPECT_EVAL_ROWS = 490
DEFAULT_EXPECT_COMPARE_ROWS = 49
DEFAULT_EXPECT_CURVE_MAX_STEP = 26413
DEFAULT_EXPECT_CURVE_MIN_STEP = 50
DEFAULT_EXPECT_COMPLETION = 1.0
DEFAULT_MIN_DEVIATIONS = 20

#: The delta columns of the self-vs-official comparison table.
DELTA_METRICS = (
  "joint_err_rms_rad",
  "body_err_mean_m",
  "end_drift_m",
)

#: The marker kinds.
KINDS = (
  "DOC_VERIFY",
  "DOC_MIRROR",
)


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def _read_text(path):
  """The text of a file, or None when it cannot be read."""
  try:
    with open(str(path), "r", encoding="utf-8", errors="replace") as handle:
      return handle.read()
  except (OSError, UnicodeError):
    return None


def sha256_file(path):
  """The SHA-256 hex digest of a file, or None when it cannot be read."""
  try:
    digest = hashlib.sha256()
    with open(str(path), "rb") as handle:
      while True:
        chunk = handle.read(1024 * 1024)
        if not chunk:
          break
        digest.update(chunk)
    return digest.hexdigest()
  except OSError:
    return None


def _is_number(value):
  if isinstance(value, bool):
    return False
  if isinstance(value, (int, float)):
    return math.isfinite(float(value))
  return False


def _to_float(value):
  try:
    number = float(value)
  except (TypeError, ValueError):
    return None
  if not math.isfinite(number):
    return None
  return number


def _fmt_number(value):
  """The canonical 6-decimal rendering of a number (stable in the record)."""
  if value is None:
    return ""
  return "%.6f" % float(value)


def number_renderings(value):
  """The accepted renderings of a number inside the record.

  The record is written by hand, so a recomputed mean may be quoted with
  3, 4, 5 or 6 decimals (or in the scientific form).  Every accepted
  rendering is listed here -- the check is "the record quotes THIS number",
  not "the record uses exactly this format".
  """
  if value is None:
    return []
  number = float(value)
  renderings = ["%.6f" % number, "%.5f" % number, "%.4f" % number,
                "%.3f" % number, "%.2f" % number]
  try:
    renderings.append(repr(number))
  except (TypeError, ValueError):
    pass
  unique = []
  for item in renderings:
    if item not in unique:
      unique.append(item)
  return unique


def _split_row(line):
  """The cells of a markdown table row (the outer pipes are dropped)."""
  text = line.strip()
  if text.startswith("|"):
    text = text[1:]
  if text.endswith("|"):
    text = text[:-1]
  return [cell.strip() for cell in text.split("|")]


def _is_separator_row(cells):
  if not cells:
    return False
  for cell in cells:
    if not cell or not re.fullmatch(r":?-{1,}:?", cell):
      return False
  return True


# --------------------------------------------------------------------------
# parsing the document
# --------------------------------------------------------------------------


def parse_sections(text):
  """The chapters of a record: {id: body}.

  A chapter starts at `<!-- DOC_SECTION:n -->` and ends at
  `<!-- /DOC_SECTION:n -->`; an unterminated chapter ends at the next
  chapter marker (or at the end of the document).  The front matter (the
  text BEFORE the first chapter marker) is returned under the key 0.
  """
  sections = {}
  text = text or ""
  starts = list(_SECTION_START_RE.finditer(text))
  if not starts:
    sections[0] = text
    return sections
  sections[0] = text[:starts[0].start()]
  for index, match in enumerate(starts):
    ident = int(match.group(1))
    body_start = match.end()
    limit = starts[index + 1].start() if index + 1 < len(starts) else len(text)
    end_match = _SECTION_END_RE.search(text, body_start, limit)
    body_end = end_match.start() if end_match else limit
    sections[ident] = text[body_start:body_end]
  return sections


def extract_evidence_table(text):
  """The data rows of the evidence index table.

  Returns (rows, reason): `rows` is a list of dicts with the keys
  "conclusion", "command", "path" and "output"; `reason` is None on
  success.

    "evidence-table-missing"    the markers are not there
    "evidence-table-malformed"  the block is not a four-column table
  """
  text = text or ""
  start = text.find(EVIDENCE_TABLE_START)
  end = text.find(EVIDENCE_TABLE_END)
  if start < 0 or end < 0 or end < start:
    return None, "evidence-table-missing"
  block = text[start + len(EVIDENCE_TABLE_START):end]
  table_rows = [line for line in block.splitlines() if line.strip().startswith("|")]
  if not table_rows:
    return None, "evidence-table-malformed"
  rows = []
  for line in table_rows:
    cells = _split_row(line)
    if _is_separator_row(cells):
      continue
    if len(cells) != 4:
      return None, "evidence-table-malformed"
    rows.append({
      "conclusion": cells[0],
      "command": cells[1],
      "path": cells[2],
      "output": cells[3],
    })
  # the first row is the header ("结论 | 复现命令 | ...")
  if len(rows) >= 1 and rows[0]["conclusion"] in ("结论", "Conclusion"):
    rows = rows[1:]
  if not rows:
    return None, "evidence-table-malformed"
  return rows, None


def check_evidence_rows(repo_root, rows):
  """Assert every evidence row against the repository.

  Checks, per row:
    * the conclusion and the command are non-empty  -> "evidence-row-invalid"
    * the evidence file exists (relative to the repository root; the
      seed-store symlinks logs//runs//out//assets/ are followed)
                                                -> "evidence-path-missing"
    * the key output IS PRESENT in the evidence file (case-insensitive
      substring)                                 -> "evidence-marker-missing"

  Returns (facts, reason); facts["bad"] names the offending row.
  """
  facts = {"rows": len(rows or []), "bad": None}
  root = str(repo_root or ".")
  for index, row in enumerate(rows or []):
    conclusion = str(row.get("conclusion") or "").strip()
    command = str(row.get("command") or "").strip()
    if not conclusion or not command:
      facts["bad"] = index
      return facts, "evidence-row-invalid"
    relative = str(row.get("path") or "").strip()
    if not relative:
      facts["bad"] = index
      return facts, "evidence-row-invalid"
    target = os.path.join(root, relative)
    if not os.path.isfile(target):
      facts["bad"] = index
      facts["path"] = relative
      return facts, "evidence-path-missing"
    key_output = str(row.get("output") or "").strip()
    if not key_output:
      facts["bad"] = index
      return facts, "evidence-row-invalid"
    text = _read_text(target)
    if text is None:
      facts["bad"] = index
      facts["path"] = relative
      return facts, "evidence-path-missing"
    if key_output.lower() not in text.lower():
      facts["bad"] = index
      facts["path"] = relative
      facts["output"] = key_output
      return facts, "evidence-marker-missing"
    facts.setdefault("checked", []).append(relative)
  return facts, None


def scan_tokens(text):
  """Every plaintext token in the text (an empty list when clean)."""
  return [match.group(0) for match in _TOKEN_RE.finditer(text or "")]


def count_deviation_rows(body):
  """The number of deviation entries of chapter 3.

  A deviation entry is a DATA row of a markdown table of the chapter.  A
  table block is a header row followed by a separator row; the header and
  the separator never count.  A table without a separator row counts its
  rows as data.
  """
  lines = (body or "").splitlines()
  count = 0
  index = 0
  while index < len(lines):
    stripped = lines[index].strip()
    if not stripped.startswith("|"):
      index += 1
      continue
    header_cells = _split_row(stripped)
    index += 1
    separator = None
    if index < len(lines):
      candidate = lines[index].strip()
      if candidate.startswith("|"):
        cells = _split_row(candidate)
        if _is_separator_row(cells):
          separator = cells
          index += 1
    if separator is None:
      # a table without a separator row: the row itself is data
      if any(header_cells):
        count += 1
      continue
    while index < len(lines):
      data = lines[index].strip()
      if not data.startswith("|"):
        break
      cells = _split_row(data)
      if not _is_separator_row(cells) and any(cells):
        count += 1
      index += 1
  return count


# --------------------------------------------------------------------------
# the recomputed artefacts
# --------------------------------------------------------------------------


def read_sha256sums(directory):
  """The SHA256SUMS entries of a directory: {name: digest}.

  Returns (entries, reason); "sha-missing" when the file is missing /
  unreadable / holds no parsable entry.
  """
  if not directory or not os.path.isdir(str(directory)):
    return None, "sha-missing"
  sums_path = os.path.join(str(directory), "SHA256SUMS")
  if not os.path.isfile(sums_path):
    return None, "sha-missing"
  text = _read_text(sums_path)
  if text is None:
    return None, "sha-missing"
  entries = {}
  for raw in text.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
      continue
    parts = line.split(None, 1)
    if len(parts) != 2:
      continue
    digest, name = parts[0].strip().lower(), parts[1].strip().lstrip("*")
    if len(digest) != 64:
      continue
    entries[name] = digest
  if not entries:
    return None, "sha-missing"
  return entries, None


def verify_sha256sums(directory):
  """Recompute every digest listed in the SHA256SUMS of a directory.

  Returns (facts, reason):
    "sha-missing"   the directory / the SHA256SUMS / a listed file is gone
    "sha-mismatch"  a recomputed digest differs from the recorded one
  """
  facts = {"dir": str(directory or ""), "checked": [], "sha": {}}
  entries, reason = read_sha256sums(directory)
  if reason is not None:
    return None, reason
  root = str(directory)
  for name in sorted(entries):
    target = os.path.join(root, name)
    if not os.path.isfile(target):
      facts["missing"] = name
      return facts, "sha-missing"
    digest = sha256_file(target)
    if digest is None:
      facts["missing"] = name
      return facts, "sha-missing"
    if digest != entries[name]:
      facts["mismatch"] = name
      facts["expected"] = entries[name]
      facts["actual"] = digest
      return facts, "sha-mismatch"
    facts["checked"].append(name)
    facts["sha"][name] = digest
  return facts, None


def read_eval_csv(path):
  """The rows of a per-clip eval CSV.

  Returns (rows, reason):
    "eval-csv-missing"      the file does not exist / cannot be read
    "eval-csv-parse-failed" not readable as CSV, or no `failed` column
  """
  if not path or not os.path.isfile(str(path)):
    return None, "eval-csv-missing"
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      records = list(csv.reader(handle))
  except (OSError, csv.Error, UnicodeError):
    return None, "eval-csv-parse-failed"
  if not records:
    return None, "eval-csv-parse-failed"
  header = [name.strip() for name in records[0]]
  if "failed" not in header:
    return None, "eval-csv-parse-failed"
  rows = []
  for record in records[1:]:
    if not record or all(not cell.strip() for cell in record):
      continue
    row = {}
    for index, name in enumerate(header):
      row[name] = record[index] if index < len(record) else ""
    rows.append(row)
  return rows, None


def eval_completion(rows):
  """The (clips, failures, completion) triple of an eval table.

  The `failed` column is parsed as "True" / "False" (case-insensitive,
  whitespace stripped); an unparsable value counts as a failure (fail
  closed).  completion = 1 - failures / clips (0.0 for an empty table).
  """
  clips = 0
  failures = 0
  for row in rows or []:
    clips += 1
    raw = row.get("failed")
    text = "" if raw is None else str(raw).strip().lower()
    if text not in ("true", "false"):
      failures += 1
      continue
    if text == "true":
      failures += 1
  completion = 0.0 if clips <= 0 else 1.0 - (float(failures) / float(clips))
  return clips, failures, completion


def read_compare_csv(path):
  """The rows of the self-vs-official comparison table.

  Returns (rows, reason):
    "compare-missing"       the file does not exist / cannot be read
    "compare-parse-failed"  not readable as CSV, or a delta column is gone
  """
  if not path or not os.path.isfile(str(path)):
    return None, "compare-missing"
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      records = list(csv.reader(handle))
  except (OSError, csv.Error, UnicodeError):
    return None, "compare-parse-failed"
  if not records:
    return None, "compare-parse-failed"
  header = [name.strip() for name in records[0]]
  for metric in DELTA_METRICS:
    if ("delta_" + metric) not in header:
      return None, "compare-parse-failed"
  rows = []
  for record in records[1:]:
    if not record or all(not cell.strip() for cell in record):
      continue
    row = {}
    for index, name in enumerate(header):
      row[name] = record[index] if index < len(record) else ""
    rows.append(row)
  return rows, None


def _mean(values):
  numbers = [value for value in values if _is_number(value)]
  if not numbers:
    return None
  return sum(numbers) / float(len(numbers))


def compare_delta_means(rows):
  """The mean of the three delta columns of a comparison table."""
  means = {}
  for metric in DELTA_METRICS:
    means[metric] = _mean([_to_float(row.get("delta_" + metric))
                            for row in rows or []])
  return means


def read_curve_csv(path):
  """The rows (step, tag, value) of the training curve CSV.

  Returns (rows, reason):
    "curve-missing"      the file does not exist / cannot be read
    "curve-parse-failed" not readable as CSV, or the header is wrong
  """
  if not path or not os.path.isfile(str(path)):
    return None, "curve-missing"
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      records = list(csv.reader(handle))
  except (OSError, csv.Error, UnicodeError):
    return None, "curve-parse-failed"
  if not records:
    return None, "curve-parse-failed"
  header = [name.strip() for name in records[0]]
  if header[:3] != ["step", "tag", "value"]:
    return None, "curve-parse-failed"
  rows = []
  for record in records[1:]:
    if len(record) < 3:
      continue
    try:
      step = int(record[0])
    except (TypeError, ValueError):
      continue
    rows.append((step, record[1], record[2]))
  return rows, None


def curve_step_coverage(rows):
  """The step range covered by the curve rows."""
  steps = []
  for row in rows or []:
    steps.append(row[0])
  return {
    "min_step": min(steps) if steps else None,
    "max_step": max(steps) if steps else None,
    "n_steps": len(set(steps)),
    "n_rows": len(steps),
  }


# --------------------------------------------------------------------------
# output line formats (single source of truth for the shell wrappers)
# --------------------------------------------------------------------------


def format_ok(kind, **kv):
  """The one-line DOC_<KIND>_OK marker."""
  parts = ["%s_OK" % kind]
  for key in kv:
    parts.append("%s=%s" % (key, kv[key]))
  return " ".join(parts)


def format_fail(kind, reason):
  """The one-line DOC_<KIND>_FAIL marker (never contains an OK marker)."""
  if reason not in REASONS:
    reason = "evidence-table-missing"
  return "%s_FAIL reason=%s" % (kind, reason)


# --------------------------------------------------------------------------
# the decision entry points
# --------------------------------------------------------------------------


def verify_document(doc_path, repo_root, eval_motion_csv=None,
                    eval_human_csv=None, compare_csv=None, curve_csv=None,
                    self_sha_dir=None, official_sha_dir=None,
                    expect_sections=DEFAULT_EXPECT_SECTIONS,
                    expect_eval_rows=DEFAULT_EXPECT_EVAL_ROWS,
                    expect_compare_rows=DEFAULT_EXPECT_COMPARE_ROWS,
                    expect_curve_min_step=DEFAULT_EXPECT_CURVE_MIN_STEP,
                    expect_curve_max_step=DEFAULT_EXPECT_CURVE_MAX_STEP,
                    expect_completion=DEFAULT_EXPECT_COMPLETION,
                    min_deviations=DEFAULT_MIN_DEVIATIONS):
  """Verify the reproduction record against the artefacts on disk.

  Checks, in order (the first failure decides the reason):
    1. the document exists                       -> "doc-missing"
    2. the document is not empty                 -> "doc-empty"
    3. no plaintext token                        -> "token-leaked"
    4. the nine chapters are present             -> "section-missing"
    5. the front-matter declaration             -> "process-replication-missing"
    6. chapter 3 holds the deviation list       -> "deviation-section-missing"
    7. chapter 4 names the three unexecuted items
                                                  -> "unexecuted-section-missing"
    8. the evidence index table exists and every row holds
                                                  -> "evidence-table-missing"
                                                  / "evidence-table-malformed"
                                                  / "evidence-row-invalid"
    9. every evidence file exists               -> "evidence-path-missing"
   10. every key output is greppable            -> "evidence-marker-missing"
   11. the SHA-256 digests recompute            -> "sha-missing" / "sha-mismatch"
   12. both eval CSVs hold the expected rows    -> "eval-row-count-mismatch"
   13. both completions recompute to the expected value
                                                  -> "completion-mismatch"
   14. the comparison table holds the expected rows
                                                  -> "compare-row-count-mismatch"
   15. the record quotes the recomputed delta means
                                                  -> "compare-delta-mismatch"
   16. the curve CSV covers the whole run       -> "curve-missing"
                                                  / "curve-step-missing"

  Returns (facts, reason).  Fail-closed: no exception ever escapes.
  """
  facts = {
    "doc": str(doc_path or ""),
    "sections": 0,
    "evidence_rows": 0,
    "sha_ok": 0,
    "eval_rows": 0,
    "compare_rows": 0,
    "curve_rows": 0,
  }

  if not doc_path or not os.path.isfile(str(doc_path)):
    return None, "doc-missing"
  text = _read_text(doc_path)
  if text is None:
    return None, "doc-missing"
  if not text.strip():
    return None, "doc-empty"

  # (3) no plaintext token
  leaked = scan_tokens(text)
  if leaked:
    facts["token_count"] = len(leaked)
    return None, "token-leaked"

  # (4) the nine chapters
  sections = parse_sections(text)
  present = [ident for ident, _title in SECTION_TITLES if ident in sections]
  facts["sections"] = len(present)
  if len(present) != int(expect_sections):
    facts["missing_sections"] = [
      ident for ident, _title in SECTION_TITLES if ident not in sections]
    return None, "section-missing"

  # (5) the front-matter declaration (the cover page, or chapter 1)
  front = (sections.get(0, "") or "") + "\n" + (sections.get(1, "") or "")
  for token in PROCESS_TOKENS:
    if token not in front:
      facts["missing_token"] = token
      return None, "process-replication-missing"

  # (6) the deviation list
  deviations = count_deviation_rows(sections.get(3, ""))
  facts["deviations"] = deviations
  if deviations < int(min_deviations):
    return None, "deviation-section-missing"

  # (7) the three unexecuted items
  unexecuted = sections.get(4, "")
  for token in UNEXECUTED_TOKENS:
    if token not in unexecuted:
      facts["missing_token"] = token
      return None, "unexecuted-section-missing"

  # (8..10) the evidence index table
  rows, reason = extract_evidence_table(text)
  if reason is not None:
    return None, reason
  facts["evidence_rows"] = len(rows)
  evidence_facts, reason = check_evidence_rows(repo_root, rows)
  if reason is not None:
    facts.update(evidence_facts or {})
    return None, reason

  # (11) the SHA-256 digests, recomputed
  for directory in (self_sha_dir, official_sha_dir):
    if not directory:
      continue
    sha_facts, reason = verify_sha256sums(directory)
    if reason is not None:
      facts.update(sha_facts or {})
      return None, reason
    facts["sha_ok"] = 1
    facts.setdefault("sha_dirs", []).append(sha_facts["dir"])

  # (12) the eval row counts
  for csv_path in (eval_motion_csv, eval_human_csv):
    if not csv_path:
      continue
    eval_rows, reason = read_eval_csv(csv_path)
    if reason is not None:
      return None, reason
    facts["eval_rows"] = len(eval_rows)
    if len(eval_rows) != int(expect_eval_rows):
      facts["eval_expected"] = int(expect_eval_rows)
      return None, "eval-row-count-mismatch"

  # (13) the completions, recomputed from the `failed` column
  for csv_path in (eval_motion_csv, eval_human_csv):
    if not csv_path:
      continue
    eval_rows, reason = read_eval_csv(csv_path)
    if reason is not None:
      return None, reason
    clips, failures, completion = eval_completion(eval_rows)
    facts["completion"] = completion
    if abs(completion - float(expect_completion)) > 1e-9:
      facts["completion_expected"] = float(expect_completion)
      facts["failures"] = failures
      return None, "completion-mismatch"

  # (14) the comparison table
  means = {}
  if compare_csv:
    compare_rows, reason = read_compare_csv(compare_csv)
    if reason is not None:
      return None, reason
    facts["compare_rows"] = len(compare_rows)
    if len(compare_rows) != int(expect_compare_rows):
      facts["compare_expected"] = int(expect_compare_rows)
      return None, "compare-row-count-mismatch"
    means = compare_delta_means(compare_rows)

  # (15) the record quotes the recomputed delta means (one metric per line:
  # the metric name AND its value must appear on the SAME line, so that a
  # wrong number can be attributed to a single metric)
  if means:
    lines = text.splitlines()
    for metric in DELTA_METRICS:
      value = means.get(metric)
      if value is None:
        continue
      accepted = number_renderings(value)
      quoted = False
      for line in lines:
        if metric not in line:
          continue
        if any(item in line for item in accepted):
          quoted = True
          break
      if not quoted:
        facts["missing_delta"] = "%s=%s" % (metric, _fmt_number(value))
        return None, "compare-delta-mismatch"
      facts.setdefault("delta_means", {})[metric] = _fmt_number(value)

  # (16) the training curve
  if curve_csv:
    curve_rows, reason = read_curve_csv(curve_csv)
    if reason is not None:
      return None, reason
    coverage = curve_step_coverage(curve_rows)
    facts["curve_rows"] = coverage["n_rows"]
    facts["curve_min_step"] = coverage["min_step"]
    facts["curve_max_step"] = coverage["max_step"]
    if coverage["n_rows"] <= 0:
      return None, "curve-missing"
    if coverage["max_step"] != int(expect_curve_max_step):
      facts["curve_max_expected"] = int(expect_curve_max_step)
      return None, "curve-step-missing"
    if coverage["min_step"] > int(expect_curve_min_step):
      facts["curve_min_expected"] = int(expect_curve_min_step)
      return None, "curve-step-missing"

  return facts, None


def verify_mirror(doc_path, mirror_path):
  """Verify that the published mirror is byte-identical to the record.

  Returns (facts, reason):
    "mirror-missing"   one of the two files is missing
    "mirror-mismatch"  the two digests differ
  """
  facts = {"doc": str(doc_path or ""), "mirror": str(mirror_path or "")}
  if not doc_path or not os.path.isfile(str(doc_path)):
    return None, "mirror-missing"
  if not mirror_path or not os.path.isfile(str(mirror_path)):
    return None, "mirror-missing"
  left = sha256_file(doc_path)
  right = sha256_file(mirror_path)
  if left is None or right is None:
    return None, "mirror-missing"
  facts["doc_sha256"] = left
  facts["mirror_sha256"] = right
  if left != right:
    return None, "mirror-mismatch"
  facts["mirror_match"] = 1
  return facts, None


def format_verify_ok(facts):
  """The single DOC_VERIFY_OK line of the terminal reviewer."""
  facts = facts or {}
  return format_ok("DOC_VERIFY",
                   sections=facts.get("sections", 0),
                   evidence_rows=facts.get("evidence_rows", 0),
                   sha_ok=facts.get("sha_ok", 0),
                   eval_rows=facts.get("eval_rows", 0),
                   compare_rows=facts.get("compare_rows", 0),
                   curve_rows=facts.get("curve_rows", 0))


def format_report_lines(facts):
  """The DOC_REPORT_* lines (the facts the record has to quote)."""
  facts = facts or {}
  lines = []
  lines.append("DOC_REPORT_SECTIONS sections=%s" % facts.get("sections", 0))
  lines.append("DOC_REPORT_EVIDENCE_ROWS evidence_rows=%s"
               % facts.get("evidence_rows", 0))
  lines.append("DOC_REPORT_EVAL eval_rows=%s completion=%s"
               % (facts.get("eval_rows", 0),
                  _fmt_number(facts.get("completion"))))
  lines.append("DOC_REPORT_COMPARE compare_rows=%s" % facts.get("compare_rows", 0))
  for metric in DELTA_METRICS:
    value = (facts.get("delta_means") or {}).get(metric)
    lines.append("DOC_REPORT_DELTA delta_%s=%s" % (metric, _fmt_number(value)))
  lines.append("DOC_REPORT_CURVE curve_rows=%s min_step=%s max_step=%s"
               % (facts.get("curve_rows", 0),
                  facts.get("curve_min_step"), facts.get("curve_max_step")))
  for name in (facts.get("sha_dirs") or []):
    lines.append("DOC_REPORT_SHA dir=%s" % name)
  return lines


# --------------------------------------------------------------------------
# thin CLI
# --------------------------------------------------------------------------


def _add_common(parser):
  parser.add_argument("--doc", default=None, help="the reproduction record")
  parser.add_argument("--repo-root", default=".", help="the repository root")
  parser.add_argument("--eval-motion-csv", default=None)
  parser.add_argument("--eval-human-csv", default=None)
  parser.add_argument("--compare-csv", default=None)
  parser.add_argument("--curve-csv", default=None)
  parser.add_argument("--self-sha-dir", default=None)
  parser.add_argument("--official-sha-dir", default=None)
  parser.add_argument("--expect-sections", type=int, default=DEFAULT_EXPECT_SECTIONS)
  parser.add_argument("--expect-eval-rows", type=int, default=DEFAULT_EXPECT_EVAL_ROWS)
  parser.add_argument("--expect-compare-rows", type=int, default=DEFAULT_EXPECT_COMPARE_ROWS)
  parser.add_argument("--expect-curve-min-step", type=int,
                      default=DEFAULT_EXPECT_CURVE_MIN_STEP)
  parser.add_argument("--expect-curve-max-step", type=int,
                      default=DEFAULT_EXPECT_CURVE_MAX_STEP)
  parser.add_argument("--expect-completion", type=float, default=DEFAULT_EXPECT_COMPLETION)
  parser.add_argument("--min-deviations", type=int, default=DEFAULT_MIN_DEVIATIONS)


def _cmd_verify(args):
  facts, reason = verify_document(
    args.doc, args.repo_root,
    eval_motion_csv=args.eval_motion_csv,
    eval_human_csv=args.eval_human_csv,
    compare_csv=args.compare_csv,
    curve_csv=args.curve_csv,
    self_sha_dir=args.self_sha_dir,
    official_sha_dir=args.official_sha_dir,
    expect_sections=args.expect_sections,
    expect_eval_rows=args.expect_eval_rows,
    expect_compare_rows=args.expect_compare_rows,
    expect_curve_min_step=args.expect_curve_min_step,
    expect_curve_max_step=args.expect_curve_max_step,
    expect_completion=args.expect_completion,
    min_deviations=args.min_deviations)
  if reason is not None:
    print(format_fail("DOC_VERIFY", reason))
    return 1
  print(format_verify_ok(facts))
  return 0


def _cmd_mirror(args):
  facts, reason = verify_mirror(args.doc, args.mirror)
  if reason is not None:
    print(format_fail("DOC_MIRROR", reason))
    return 1
  print(format_ok("DOC_MIRROR", mirror_match=1))
  return 0


def _cmd_report(args):
  facts, reason = verify_document(
    args.doc, args.repo_root,
    eval_motion_csv=args.eval_motion_csv,
    eval_human_csv=args.eval_human_csv,
    compare_csv=args.compare_csv,
    curve_csv=args.curve_csv,
    self_sha_dir=args.self_sha_dir,
    official_sha_dir=args.official_sha_dir,
    expect_sections=args.expect_sections,
    expect_eval_rows=args.expect_eval_rows,
    expect_compare_rows=args.expect_compare_rows,
    expect_curve_min_step=args.expect_curve_min_step,
    expect_curve_max_step=args.expect_curve_max_step,
    expect_completion=args.expect_completion,
    min_deviations=args.min_deviations)
  if reason is not None:
    print(format_fail("DOC_VERIFY", reason))
    return 1
  for line in format_report_lines(facts):
    print(line)
  return 0


def build_parser():
  parser = argparse.ArgumentParser(
    prog="doc.py", description="the reproduction record decision base")
  sub = parser.add_subparsers(dest="command")

  verify = sub.add_parser("verify", help="verify the reproduction record")
  _add_common(verify)
  verify.set_defaults(func=_cmd_verify)

  mirror = sub.add_parser("mirror", help="verify the published mirror")
  mirror.add_argument("--doc", default=None)
  mirror.add_argument("--mirror", default=None)
  mirror.set_defaults(func=_cmd_mirror)

  report = sub.add_parser("report", help="the facts the record has to quote")
  _add_common(report)
  report.set_defaults(func=_cmd_report)

  return parser


def main(argv=None):
  parser = build_parser()
  args = parser.parse_args(argv)
  if not getattr(args, "func", None):
    parser.print_help()
    return 2
  try:
    return args.func(args)
  except Exception as exc:  # fail closed: never leak a traceback as a verdict
    print(format_fail("DOC_VERIFY", "evidence-table-missing"))
    sys.stderr.write("doc.py: %s\n" % exc)
    return 1


if __name__ == "__main__":
  sys.exit(main())
