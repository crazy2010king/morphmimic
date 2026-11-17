#!/usr/bin/env python3
"""repro/lib/deploy.py — the decision base of the deployment verification
(slice S08).

Standard library ONLY (argparse / csv / hashlib / io / json / math / os /
sys / zipfile).  The python3 on the PATH inside the ros_dev container has no
numpy and the project venv is not guaranteed to be alive, so every decision
used by the deployment orchestrators (assets export / sim2sim replay / eval /
official comparison / human replay) lives here, as a pure function that can be
driven offline by fixtures.

Why a pure-function library (project convention, see P001 / P002): the shell
used to parse the very same numbers in awk/grep while python parsed them
again -> two parsers drifted.  Here there is exactly ONE parser;
`repro/lib/deploy.sh` is a thin wrapper that only selects the interpreter and
forwards arguments.

Upstream artefacts this module reads:

  deploy.run --summary JSON   the per-run sim2sim summary
                               (deploy/sim2sim/sim_node.py:Tracker.summary)
                               robot, clip, frames, result,
                               joint_err_rms_rad, body_err_mean_m, end_drift_m
                               (+ end_drift_along_m / end_drift_across_m /
                               end_heading_err_deg), plus video / interface /
                               mode for the replay branches.
  morphmimic.scripts.eval CSV the per-clip table
                               (src/morphmimic/eval/benchmark.py:RESULT_COLUMNS)
                               name, frames, failed, fail_frame, norm_return,
                               steps + the drift columns.
  export_assets directory     <robot>.xml + clips/<robot>/<clip>.npz
  official v0.1 directory     SHA256SUMS + policy.onnx + <robot>.json
  make_gmr_session output     a PICO recording (npz): t_ns / body / buttons

Pure functions
  parse_sim_summary(path)        -> (facts|None, reason|None)
  check_video(path)              -> reason|None
  read_eval_csv(path)            -> (header, rows) | (None, reason)
  eval_completion(rows)          -> (clips, failures, completion)
  parse_failed_cell(value)       -> bool|None
  count_unparsable_failed(rows)  -> int
  parse_subset_yaml(path)        -> (info|None, reason|None)
  count_subset_clips(path)       -> int
  csv_row_count(path)            -> int
  build_compare_csv(self, off)   -> str
  format_ok(kind, **kv)          -> str   (DEPLOY_<KIND>_OK ...)
  format_fail(kind, reason)      -> str   (DEPLOY_<KIND>_FAIL reason=...)
  verify_sim_summaries(dir, n)   -> (facts|None, reason|None)
  verify_eval_csv(path, n)       -> (facts|None, reason|None)
  verify_assets_dir(dir, n)      -> (facts|None, reason|None)
  verify_official_dir(dir, require_covered=None) -> (facts|None, reason|None)
  read_sha256sums(dir)          -> (entries|None, reason|None)
  summaries_to_rows(dir)         -> (rows|None, reason|None)
  verify_session(path)           -> (facts|None, reason|None)
  verify_compare_csv(path, n=None) -> (facts|None, reason|None)
  verify_replay_summary(path)    -> (facts|None, reason|None)

Thin CLI (for the shell wrappers):
  deploy.py sim     --dir DIR --expect-count N
  deploy.py eval    --path CSV --expect-rows N
  deploy.py assets  --dir DIR --expect-clips N
  deploy.py official --dir DIR
  deploy.py session --path NPZ
  deploy.py compare --path CSV [--expect-rows N]
  deploy.py compare-build --self-csv CSV --official-csv CSV --out CSV
  deploy.py compare-build --self-dir DIR --official-dir DIR --out CSV

Exit code 0 == the decision is positive; 1 == the decision is negative (the
fixed reason set is printed on stdout as `reason=...`).
"""

from __future__ import annotations

import argparse
import ast
import csv
import hashlib
import io
import json
import math
import os
import struct
import sys
import zipfile

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------

#: The fixed failure-reason set.  Every negative path must use one of these.
REASONS = (
  # sim2sim summary
  "summary-missing",
  "summary-parse-failed",
  "summary-field-missing",
  "summary-value-empty",
  "summary-count-mismatch",
  "summary-clip-unknown",
  # video
  "video-missing",
  "video-empty",
  # eval csv
  "eval-csv-missing",
  "eval-csv-parse-failed",
  "eval-row-count-mismatch",
  # assets
  "assets-missing",
  "assets-xml-missing",
  "assets-xml-empty",
  "assets-clips-missing",
  "assets-clips-mismatch",
  "assets-clip-empty",
  "assets-meshes-missing",
  # clip list (the sampled replay list of the deployment verification)
  "clip-list-missing",
  "clip-list-empty",
  # official weights
  "official-dir-missing",
  "official-sha-missing",
  "official-sha-mismatch",
  "official-json-missing",
  "official-onnx-missing",
  # comparison table
  "compare-missing",
  "compare-parse-failed",
  "compare-row-mismatch",
  # human session / replay
  "session-missing",
  "session-format-invalid",
  "session-shape-invalid",
  "replay-summary-missing",
  "replay-summary-empty",
  # the human replay orchestrator (S08-T6)
  "deploy-dir-missing",
  "deploy-onnx-missing",
  "deploy-json-missing",
  "data-clip-missing",
  "mujoco-gl-unset",
  "session-make-failed",
  "replay-run-failed",
  "replay-timeout",
)

#: The summary fields every sim2sim run must carry (upstream
#: deploy/sim2sim/sim_node.py:Tracker.summary).
SUMMARY_FIELDS = (
  "robot",
  "clip",
  "frames",
  "result",
  "joint_err_rms_rad",
  "body_err_mean_m",
  "end_drift_m",
)

#: The summary fields that must hold a finite number (the "completion /
#: error / drift" trio of the slice goal).
SUMMARY_NUMERIC_FIELDS = (
  "frames",
  "joint_err_rms_rad",
  "body_err_mean_m",
  "end_drift_m",
)

#: The fields a TELEOP (human interface) replay summary must carry
#: (deploy/sim2sim/sim_node.py:run_teleop): it has no clip and no per-clip
#: error block, only the robot and the step count.
REPLAY_FIELDS = (
  "robot",
  "steps",
)

#: The fields a HUMAN-INTERFACE teleop replay summary must carry
#: (deploy/sim2sim/sim_node.py:run_teleop).  The motion branch's error
#: block is NOT part of it (under --interface human the policy node sends no
#: reference window to the sim, so joint_err_rms_rad is null upstream).
HUMAN_REPLAY_FIELDS = (
  "robot",
  "steps",
  "falls",
  "travel_along_m",
)

#: The columns the per-clip eval CSV must carry (upstream RESULT_COLUMNS).
EVAL_COLUMNS = (
  "name",
  "frames",
  "failed",
  "fail_frame",
  "norm_return",
  "steps",
)

#: The header of the self-vs-official comparison table.
COMPARE_COLUMNS = (
  "clip",
  "frames",
  "self_result",
  "self_joint_err_rms_rad",
  "self_body_err_mean_m",
  "self_end_drift_m",
  "official_result",
  "official_joint_err_rms_rad",
  "official_body_err_mean_m",
  "official_end_drift_m",
  "delta_joint_err_rms_rad",
  "delta_body_err_mean_m",
  "delta_end_drift_m",
)

#: The marker kinds (the DEPLOY_<KIND>_OK / _FAIL families).
KINDS = (
  "DEPLOY_ASSETS",
  "DEPLOY_SIM",
  "DEPLOY_EVAL",
  "DEPLOY_OFFICIAL",
  "DEPLOY_HUMAN",
  "DEPLOY_VERIFY",
)

#: The members a make_gmr_session recording must carry (PICO layout).
SESSION_MEMBERS = ("t_ns.npy", "body.npy", "buttons.npy")

#: The shape contract of a make_gmr_session recording: body [N, 24, 7] (PICO's
#: 24 joints, xyz + xyzw), buttons [N, 5] (A / B / X / Y / menu), t_ns [N].
SESSION_BODY_TAIL = (24, 7)
SESSION_BUTTONS_TAIL = (5,)


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def _is_number(value):
  """True when `value` is a finite number (bool is NOT a number)."""
  if isinstance(value, bool):
    return False
  if isinstance(value, int):
    return True
  if isinstance(value, float):
    return not (math.isnan(value) or math.isinf(value))
  return False


def _to_float(value):
  """Return a finite float, or None when the value is not a finite number."""
  if _is_number(value):
    return float(value)
  if isinstance(value, str):
    text = value.strip()
    if not text:
      return None
    try:
      number = float(text)
    except ValueError:
      return None
    if math.isnan(number) or math.isinf(number):
      return None
    return number
  return None


def _to_int(value):
  """Return an int, or None when the value is not an integer-like number."""
  number = _to_float(value)
  if number is None:
    return None
  if number != int(number):
    return None
  return int(number)


def _fmt_number(value):
  """Format a number for the CSV / marker output ("" when None)."""
  number = _to_float(value)
  if number is None:
    return ""
  if number == int(number) and abs(number) < 1e15:
    return str(int(number))
  return repr(number)


def _read_text(path):
  """Read a text file; None when it cannot be read."""
  try:
    with open(str(path), "r", encoding="utf-8", errors="replace") as handle:
      return handle.read()
  except OSError:
    return None


def _sha256_file(path):
  """The hex sha256 digest of a file; None when it cannot be read."""
  digest = hashlib.sha256()
  try:
    with open(str(path), "rb") as handle:
      for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
  except OSError:
    return None
  return digest.hexdigest()


# --------------------------------------------------------------------------
# parsing: the sim2sim summary
# --------------------------------------------------------------------------


def parse_sim_summary(path, required=None):
  """Read a `deploy.run --summary` JSON file.

  Returns (facts, reason)

    facts  None when the summary is unusable, otherwise a dict with
           robot / clip / frames / result / joint_err_rms_rad /
           body_err_mean_m / end_drift_m (+ the raw path and the optional
           video path).
    reason None when the summary is usable, otherwise one of REASONS.

  A value counts as "non-empty" when the key exists and holds a finite
  number (or, for the string fields, a non-blank string).  A missing key is
  "summary-field-missing"; a present but empty/NaN/None value is
  "summary-value-empty".

  `required` overrides the field contract (the teleop replay summary has a
  different one, see REPLAY_FIELDS).
  """
  if not path or not os.path.isfile(str(path)):
    return None, "summary-missing"
  text = _read_text(path)
  if text is None:
    return None, "summary-missing"
  try:
    raw = json.loads(text)
  except (ValueError, TypeError):
    return None, "summary-parse-failed"
  if not isinstance(raw, dict):
    return None, "summary-parse-failed"

  fields = tuple(required) if required is not None else SUMMARY_FIELDS
  for field in fields:
    if field not in raw:
      return None, "summary-field-missing"

  facts = {"path": str(path)}

  for field in ("robot", "clip", "result"):
    if field not in fields:
      continue
    value = raw.get(field)
    if not isinstance(value, str) or not value.strip():
      return None, "summary-value-empty"
    facts[field] = value.strip()

  for field in SUMMARY_NUMERIC_FIELDS:
    if field not in fields:
      continue
    value = raw.get(field)
    if value is None:
      return None, "summary-value-empty"
    number = _to_float(value)
    if number is None:
      return None, "summary-value-empty"
    facts[field] = number

  if "frames" in fields:
    facts["frames"] = _to_int(raw.get("frames"))
    if facts["frames"] is None:
      return None, "summary-value-empty"

  if "steps" in fields:
    steps = _to_int(raw.get("steps"))
    if steps is None:
      return None, "summary-value-empty"
    facts["steps"] = steps

  video = raw.get("video")
  facts["video"] = video if isinstance(video, str) and video.strip() else None
  facts["interface"] = raw.get("interface")
  facts["mode"] = raw.get("mode")
  return facts, None


def check_video(path):
  """The reason a video file is unusable, or None when it is fine.

  A video must exist and have more than zero bytes ("video-missing" /
  "video-empty").
  """
  if not path:
    return "video-missing"
  if not os.path.isfile(str(path)):
    return "video-missing"
  try:
    size = os.path.getsize(str(path))
  except OSError:
    return "video-missing"
  if size <= 0:
    return "video-empty"
  return None


# --------------------------------------------------------------------------
# parsing: the per-clip eval CSV
# --------------------------------------------------------------------------


def read_eval_csv(path):
  """Read the per-clip eval CSV written by morphmimic.scripts.eval.

  Returns (header, rows) on success, (None, reason) on failure.

    header  the column names (as written)
    rows    a list of dicts, one per data row

  reason  "eval-csv-missing"      the file does not exist / cannot be read
          "eval-csv-parse-failed"  not readable as CSV, or the header does
                                   not carry the required columns
  """
  if not path or not os.path.isfile(str(path)):
    return None, "eval-csv-missing"
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.reader(handle)
      records = [row for row in reader]
  except (OSError, csv.Error, UnicodeError):
    return None, "eval-csv-parse-failed"
  if not records:
    return None, "eval-csv-parse-failed"
  header = [name.strip() for name in records[0]]
  for column in EVAL_COLUMNS:
    if column not in header:
      return None, "eval-csv-parse-failed"
  rows = []
  for record in records[1:]:
    if not record or all(not cell.strip() for cell in record):
      continue  # a blank line is not a clip
    row = {}
    for index, name in enumerate(header):
      row[name] = record[index] if index < len(record) else ""
    rows.append(row)
  return (header, rows), None


def eval_completion(rows):
  """The (clips, failures, completion) triple of a per-clip eval table.

  The "failed" column is parsed as "True" / "False", case-insensitively and
  after stripping whitespace.  An unparsable value counts as a failure
  (fail closed).  completion = 1 - failures / clips (0.0 for an empty table).
  """
  clips = 0
  failures = 0
  for row in rows or []:
    clips += 1
    raw = row.get("failed") if isinstance(row, dict) else None
    if raw is None:
      failures += 1
      continue
    if isinstance(raw, bool):
      failed = raw
    else:
      text = str(raw).strip().lower()
      if text == "true":
        failed = True
      elif text == "false":
        failed = False
      else:
        failed = True  # fail closed
    if failed:
      failures += 1
  completion = 0.0 if clips <= 0 else 1.0 - (float(failures) / float(clips))
  return clips, failures, completion


def parse_failed_cell(value):
  """The boolean of a "failed" cell, or None when it cannot be parsed.

  "True" / "False" (case-insensitive, whitespace stripped) and real booleans
  are parsed; everything else is unparsable.
  """
  if isinstance(value, bool):
    return value
  if value is None:
    return None
  text = str(value).strip().lower()
  if text == "true":
    return True
  if text == "false":
    return False
  return None


def count_unparsable_failed(rows):
  """The number of rows whose "failed" cell cannot be parsed.

  The count is 0 for an empty table.  A row without a "failed" key counts as
  unparsable (the column is mandatory).
  """
  count = 0
  for row in rows or []:
    if not isinstance(row, dict):
      count += 1
      continue
    if parse_failed_cell(row.get("failed")) is None:
      count += 1
  return count


# --------------------------------------------------------------------------
# parsing: the subset yaml
# --------------------------------------------------------------------------


def parse_subset_yaml(path):
  """Read a subset yaml (upstream morphmimic/data/subset.py) with the
  standard library only.

  A subset yaml holds a `root:` (the clip root), an optional `hours:` and
  the `clips:` list (one relative npz path per line).  Only that shape is
  understood; anything else is refused (fail closed) instead of guessed.

  Returns (info, reason)

    info  None on failure, otherwise a dict with
          "root"  the clip root (str, "" when the key is absent)
          "hours" the duration as written (str, "" when the key is absent)
          "clips" the list of the clip paths (list of str)

    reason None on success, otherwise "subset-missing" (the file does not
           exist / cannot be read) or "subset-parse-failed" (the shape is
           not understood, or the clip list is empty).
  """
  if not path or not os.path.isfile(str(path)):
    return None, "subset-missing"
  try:
    with open(str(path), "r", encoding="utf-8", errors="replace") as handle:
      lines = handle.read().splitlines()
  except OSError:
    return None, "subset-missing"

  info = {"root": "", "hours": "", "clips": []}
  key = None
  for raw in lines:
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
      continue
    if stripped.startswith("- "):
      if key != "clips":
        return None, "subset-parse-failed"
      info["clips"].append(stripped[2:].strip())
      continue
    if stripped == "-":
      continue
    if ":" not in stripped:
      return None, "subset-parse-failed"
    name, _, value = stripped.partition(":")
    name = name.strip()
    value = value.strip()
    if name == "clips":
      key = "clips"
      continue
    if name in ("root", "hours"):
      key = name
      info[name] = value
      continue
    key = None
  if not info["clips"]:
    return None, "subset-parse-failed"
  return info, None


def count_subset_clips(path):
  """The number of clips of a subset yaml (0 when it cannot be read)."""
  info, reason = parse_subset_yaml(path)
  if reason is not None or not info:
    return 0
  return len(info["clips"])


def csv_row_count(path):
  """The number of DATA rows of a CSV file (the header does not count).

  A missing / unreadable file has 0 rows (the caller checks the existence
  separately).
  """
  if not path or not os.path.isfile(str(path)):
    return 0
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.reader(handle)
      count = 0
      for index, row in enumerate(reader):
        if index == 0:
          continue
        if not row or all(not cell.strip() for cell in row):
          continue
        count += 1
    return count
  except (OSError, csv.Error, UnicodeError):
    return 0


# --------------------------------------------------------------------------
# the comparison table (self vs official)
# --------------------------------------------------------------------------


def _compare_key(row):
  """The clip name of a comparison row (accepts "clip" or "name")."""
  if not isinstance(row, dict):
    return ""
  for key in ("clip", "name"):
    value = row.get(key)
    if isinstance(value, str) and value.strip():
      return value.strip()
  return ""


def _compare_value(row, key):
  """One metric of a comparison row, as a float (None when absent)."""
  if not isinstance(row, dict):
    return None
  return _to_float(row.get(key))


def build_compare_csv(self_rows, official_rows):
  """The self-vs-official comparison table as CSV text.

  Both sides are aligned by clip name; only the clips present on BOTH sides
  are kept, sorted by clip name.  The deltas are self - official (an empty
  cell when one of the two sides has no value).

  `self_rows` / `official_rows` are lists of dicts carrying the clip name
  ("clip" or "name"), the optional "frames" / "result" and the three
  metrics joint_err_rms_rad / body_err_mean_m / end_drift_m.
  """
  self_index = {}
  for row in self_rows or []:
    key = _compare_key(row)
    if key:
      self_index[key] = row
  official_index = {}
  for row in official_rows or []:
    key = _compare_key(row)
    if key:
      official_index[key] = row

  buffer = io.StringIO()
  writer = csv.writer(buffer, lineterminator="\n")
  writer.writerow(COMPARE_COLUMNS)
  for key in sorted(set(self_index) & set(official_index)):
    mine = self_index[key]
    theirs = official_index[key]
    frames = _to_int(mine.get("frames")) if isinstance(mine, dict) else None
    if frames is None and isinstance(theirs, dict):
      frames = _to_int(theirs.get("frames"))
    row = [
      key,
      "" if frames is None else str(frames),
      str(mine.get("result") or "") if isinstance(mine, dict) else "",
      _fmt_number(_compare_value(mine, "joint_err_rms_rad")),
      _fmt_number(_compare_value(mine, "body_err_mean_m")),
      _fmt_number(_compare_value(mine, "end_drift_m")),
      str(theirs.get("result") or "") if isinstance(theirs, dict) else "",
      _fmt_number(_compare_value(theirs, "joint_err_rms_rad")),
      _fmt_number(_compare_value(theirs, "body_err_mean_m")),
      _fmt_number(_compare_value(theirs, "end_drift_m")),
    ]
    deltas = []
    for metric in ("joint_err_rms_rad", "body_err_mean_m", "end_drift_m"):
      left = _compare_value(mine, metric)
      right = _compare_value(theirs, metric)
      deltas.append("" if left is None or right is None else _fmt_number(left - right))
    writer.writerow(row + deltas)
  return buffer.getvalue()


def _read_compare_csv(path):
  """Read a comparison CSV; (header, rows) or (None, reason)."""
  if not path or not os.path.isfile(str(path)):
    return None, "compare-missing"
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.reader(handle)
      records = [row for row in reader]
  except (OSError, csv.Error, UnicodeError):
    return None, "compare-parse-failed"
  if not records:
    return None, "compare-parse-failed"
  header = [name.strip() for name in records[0]]
  for column in COMPARE_COLUMNS:
    if column not in header:
      return None, "compare-parse-failed"
  rows = []
  for record in records[1:]:
    if not record or all(not cell.strip() for cell in record):
      continue
    row = {}
    for index, name in enumerate(header):
      row[name] = record[index] if index < len(record) else ""
    rows.append(row)
  return (header, rows), None


# --------------------------------------------------------------------------
# output line formats (single source of truth for the shell wrappers)
# --------------------------------------------------------------------------


def format_ok(kind, **kv):
  """The one-line DEPLOY_<KIND>_OK marker."""
  parts = ["%s_OK" % kind]
  for key in kv:
    parts.append("%s=%s" % (key, kv[key]))
  return " ".join(parts)


def format_fail(kind, reason):
  """The one-line DEPLOY_<KIND>_FAIL marker (never contains an OK marker)."""
  if reason not in REASONS:
    reason = "summary-parse-failed"
  return "%s_FAIL reason=%s" % (kind, reason)


# --------------------------------------------------------------------------
# the single decision entry points
# --------------------------------------------------------------------------


def verify_sim_summaries(directory, expect_count=None):
  """Verify the per-clip sim2sim summaries of a replay directory.

  Checks (in order):
    1. the directory exists and holds at least one *.json  -> "summary-missing"
    2. every summary parses and carries the required fields
                                                      -> "summary-parse-failed"
                                                      / "summary-field-missing"
                                                      / "summary-value-empty"
    3. every summary whose "video" key is set points at a readable, non-empty
       video                                             -> "video-missing"
                                                      / "video-empty"
    4. the number of summaries equals `expect_count`    -> "summary-count-mismatch"

  Returns (facts, reason).  Fail-closed: no exception ever escapes.
  """
  facts = {"dir": str(directory or ""), "summaries": [], "count": 0}
  if not directory or not os.path.isdir(str(directory)):
    return None, "summary-missing"
  names = sorted(name for name in os.listdir(str(directory))
                 if name.endswith(".json"))
  if not names:
    return None, "summary-missing"

  for name in names:
    path = os.path.join(str(directory), name)
    summary, reason = parse_sim_summary(path)
    if reason is not None:
      return None, reason
    video = summary.get("video")
    if video:
      candidates = [video]
      if not os.path.isabs(video):
        candidates.append(os.path.join(str(directory), video))
        candidates.append(os.path.join(os.path.dirname(str(directory)), video))
      found = None
      for candidate in candidates:
        if os.path.isfile(candidate):
          found = candidate
          break
      if found is None:
        return None, "video-missing"
      video_reason = check_video(found)
      if video_reason is not None:
        return None, video_reason
    facts["summaries"].append(summary)

  facts["count"] = len(facts["summaries"])
  if expect_count is not None and facts["count"] != int(expect_count):
    facts["expected_count"] = int(expect_count)
    return None, "summary-count-mismatch"
  return facts, None


def verify_eval_csv(path, expect_rows=None, require_parseable_failed=False):
  """Verify the per-clip eval CSV.

  Checks (in order):
    1. the file exists and is readable          -> "eval-csv-missing"
    2. it parses as CSV with the required header -> "eval-csv-parse-failed"
    3. the number of data rows equals `expect_rows`
                                                -> "eval-row-count-mismatch"
    4. every "failed" cell is parsable (only when `require_parseable_failed`
       is set)                                -> "eval-csv-parse-failed"

  Returns (facts, reason); facts carries the header, the rows, the clip
  count, the failures and the completion.
  """
  facts = {"path": str(path or "")}
  parsed, reason = read_eval_csv(path)
  if reason is not None:
    return None, reason
  header, rows = parsed
  facts["header"] = list(header)
  facts["rows"] = rows
  clips, failures, completion = eval_completion(rows)
  facts["clips"] = clips
  facts["failures"] = failures
  facts["completion"] = completion
  if expect_rows is not None and clips != int(expect_rows):
    facts["expected_rows"] = int(expect_rows)
    return None, "eval-row-count-mismatch"
  unparsable = count_unparsable_failed(rows)
  facts["unparsable_failed"] = unparsable
  if require_parseable_failed and unparsable > 0:
    facts["unparsable_failed_count"] = unparsable
    return None, "eval-csv-parse-failed"
  return facts, None


def verify_assets_dir(directory, expect_clips=None):
  """Verify an export_assets directory.

  Checks (in order):
    1. the directory exists                     -> "assets-missing"
    2. it holds a robot scene (*.xml)           -> "assets-xml-missing"
    3. it holds the clips (clips/<robot>/*.npz) -> "assets-clips-missing"
    4. the number of clips equals `expect_clips`-> "assets-clips-mismatch"

  Returns (facts, reason).
  """
  facts = {"dir": str(directory or ""), "clips": [], "count": 0}
  if not directory or not os.path.isdir(str(directory)):
    return None, "assets-missing"
  root = str(directory)
  xmls = sorted(name for name in os.listdir(root) if name.endswith(".xml"))
  if not xmls:
    return None, "assets-xml-missing"
  facts["xml"] = os.path.join(root, xmls[0])
  facts["xmls"] = xmls

  clips = []
  clips_root = os.path.join(root, "clips")
  if os.path.isdir(clips_root):
    for dirpath, _dirnames, filenames in os.walk(clips_root):
      for name in sorted(filenames):
        if name.endswith(".npz"):
          clips.append(os.path.join(dirpath, name))
  if not clips:
    return None, "assets-clips-missing"
  clips.sort()
  facts["clips"] = clips
  facts["count"] = len(clips)
  if expect_clips is not None and facts["count"] != int(expect_clips):
    facts["expected_clips"] = int(expect_clips)
    return None, "assets-clips-mismatch"
  return facts, None


def read_sha256sums(directory):
  """The SHA256SUMS entries of a directory: {name: digest}.

  Returns (entries, reason); reason is "official-sha-missing" when the file
  is missing / unreadable / holds no parsable entry.
  """
  if not directory or not os.path.isdir(str(directory)):
    return None, "official-sha-missing"
  sums_path = os.path.join(str(directory), "SHA256SUMS")
  if not os.path.isfile(sums_path):
    return None, "official-sha-missing"
  text = _read_text(sums_path)
  if text is None:
    return None, "official-sha-missing"

  entries = {}
  for raw in text.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
      continue
    parts = line.split(None, 1)
    if len(parts) != 2:
      continue
    digest, name = parts[0].strip(), parts[1].strip().lstrip("*")
    if len(digest) != 64:
      continue
    entries[name] = digest.lower()
  if not entries:
    return None, "official-sha-missing"
  return entries, None


def verify_official_dir(directory, require_covered=None):
  """Verify an unpacked official v0.1 policy directory.

  Checks (in order):
    1. the directory exists                     -> "official-dir-missing"
    2. SHA256SUMS exists and is non-empty       -> "official-sha-missing"
    3. every listed file exists                 -> "official-sha-missing"
    4. policy.onnx exists                       -> "official-onnx-missing"
    5. at least one <robot>.json exists         -> "official-json-missing"
    6. every name of `require_covered` is listed in SHA256SUMS
                                                -> "official-sha-missing"
    7. every recomputed digest matches SHA256SUMS -> "official-sha-mismatch"

  `require_covered` names the files the caller needs the digests of (the
  official v0.1 SHA256SUMS covers FOUR files: policy.onnx, g1_amber.json,
  t2.json and x2.json; the caller requires only the ones it uses, and the
  extra coverage is NOT a failure).

  Returns (facts, reason).
  """
  facts = {"dir": str(directory or ""), "sha": {}}
  if not directory or not os.path.isdir(str(directory)):
    return None, "official-dir-missing"
  root = str(directory)

  entries, reason = read_sha256sums(root)
  if reason is not None:
    return None, reason
  facts["sha"] = dict(entries)
  facts["covered"] = sorted(entries)

  for name in entries:
    if not os.path.isfile(os.path.join(root, name)):
      facts["missing"] = name
      return None, "official-sha-missing"

  if not os.path.isfile(os.path.join(root, "policy.onnx")):
    return None, "official-onnx-missing"

  jsons = sorted(name for name in os.listdir(root) if name.endswith(".json"))
  if not jsons:
    return None, "official-json-missing"
  facts["jsons"] = jsons

  # the caller may require that specific files are covered by SHA256SUMS
  # (the coverage of the files it does NOT use is not a failure).
  for name in (require_covered or ()):
    if name not in entries:
      facts["not_covered"] = name
      return None, "official-sha-missing"

  files = sorted(name for name in os.listdir(root)
                 if os.path.isfile(os.path.join(root, name)))
  facts["files"] = files

  for name in sorted(entries):
    digest = _sha256_file(os.path.join(root, name))
    if digest is None:
      facts["unreadable"] = name
      return None, "official-sha-mismatch"
    if digest != entries[name]:
      facts["mismatch"] = name
      facts["expected"] = entries[name]
      facts["actual"] = digest
      return None, "official-sha-mismatch"
    facts.setdefault("checked", []).append(name)
  return facts, None


def summaries_to_rows(directory):
  """The per-clip metric rows of a directory of sim2sim summaries.

  Every *.json of the directory is read with parse_sim_summary (the ONE
  parser of the slice), so the comparison table can never disagree with the
  replay judgement.

  Returns (rows, reason); reason is "summary-missing" when the directory
  does not exist / holds no summary, and the parse reason otherwise.
  """
  if not directory or not os.path.isdir(str(directory)):
    return None, "summary-missing"
  names = sorted(name for name in os.listdir(str(directory))
                 if name.endswith(".json"))
  if not names:
    return None, "summary-missing"
  rows = []
  for name in names:
    facts, reason = parse_sim_summary(os.path.join(str(directory), name))
    if reason is not None:
      return None, reason
    rows.append({
      "clip": facts["clip"],
      "frames": facts["frames"],
      "result": facts["result"],
      "joint_err_rms_rad": facts["joint_err_rms_rad"],
      "body_err_mean_m": facts["body_err_mean_m"],
      "end_drift_m": facts["end_drift_m"],
    })
  return rows, None


def read_npy_shape(data):
  """The shape of a .npy payload (bytes), read from its header alone.

  The .npy format stores the shape as a python literal in the header, so
  the standard library is enough (no numpy): the header is parsed with
  ast.literal_eval.  Returns the shape as a tuple of ints, or None when the
  payload is not a readable .npy.
  """
  if not data or len(data) < 10 or not data.startswith(b"\x93NUMPY"):
    return None
  major = data[6]
  try:
    if major == 1:
      header_len = struct.unpack("<H", data[8:10])[0]
      start = 10
    else:
      header_len = struct.unpack("<I", data[8:12])[0]
      start = 12
  except struct.error:
    return None
  header = data[start:start + header_len]
  try:
    doc = ast.literal_eval(header.decode("latin-1").strip())
  except (ValueError, SyntaxError, UnicodeDecodeError):
    return None
  if not isinstance(doc, dict):
    return None
  shape = doc.get("shape")
  if isinstance(shape, int):
    shape = (shape,)
  if not isinstance(shape, tuple):
    return None
  try:
    return tuple(int(value) for value in shape)
  except (TypeError, ValueError):
    return None


def session_array_shapes(path):
  """The shapes of the three arrays of a PICO recording (npz).

  Returns (shapes, reason); shapes maps the member name ("t_ns" / "body" /
  "buttons") to its shape tuple.  reason is "session-missing" or
  "session-format-invalid" (the same reasons verify_session uses), so the
  caller sees ONE vocabulary.
  """
  if not path or not os.path.isfile(str(path)):
    return None, "session-missing"
  try:
    with zipfile.ZipFile(str(path)) as archive:
      names = archive.namelist()
      shapes = {}
      for member in SESSION_MEMBERS:
        if member not in names:
          return None, "session-format-invalid"
        shape = read_npy_shape(archive.read(member))
        if shape is None:
          return None, "session-format-invalid"
        shapes[member[:-4]] = shape
  except (OSError, KeyError, zipfile.BadZipFile):
    return None, "session-format-invalid"
  return shapes, None


def verify_session_arrays(path):
  """Verify the ARRAY CONTRACT of a make_gmr_session recording.

  Checks (in order):
    1. the file exists and is a readable npz      -> "session-missing"
                                                    / "session-format-invalid"
    2. body is [N, 24, 7] (PICO's 24 joints, xyz + xyzw)
                                                -> "session-shape-invalid"
    3. buttons is [N, 5] (A / B / X / Y / menu) -> "session-shape-invalid"
    4. t_ns is [N]                               -> "session-shape-invalid"
    5. N is greater than zero                    -> "session-shape-invalid"

  Returns (facts, reason); facts carries the three shapes and the sample
  count N.
  """
  facts = {"path": str(path or "")}
  shapes, reason = session_array_shapes(path)
  if reason is not None:
    return None, reason
  facts["shapes"] = dict(shapes)

  body = shapes["body"]
  buttons = shapes["buttons"]
  t_ns = shapes["t_ns"]
  facts["samples"] = body[0] if body else 0

  if len(body) != 3 or tuple(body[1:]) != SESSION_BODY_TAIL:
    facts["bad_member"] = "body"
    facts["shape"] = list(body)
    return None, "session-shape-invalid"
  if len(buttons) != 2 or tuple(buttons[1:]) != SESSION_BUTTONS_TAIL:
    facts["bad_member"] = "buttons"
    facts["shape"] = list(buttons)
    return None, "session-shape-invalid"
  if len(t_ns) != 1:
    facts["bad_member"] = "t_ns"
    facts["shape"] = list(t_ns)
    return None, "session-shape-invalid"
  if body[0] <= 0:
    facts["bad_member"] = "body"
    facts["shape"] = list(body)
    return None, "session-shape-invalid"
  if buttons[0] != body[0] or t_ns[0] != body[0]:
    facts["bad_member"] = "buttons"
    facts["shape"] = list(buttons)
    return None, "session-shape-invalid"
  return facts, None


def verify_session(path):
  """Verify a make_gmr_session recording (a PICO npz).

  Checks (in order):
    1. the file exists                       -> "session-missing"
    2. it is a zip (npz) holding the PICO members
                                              -> "session-format-invalid"

  Returns (facts, reason); facts carries the members and the body shape.
  """
  facts = {"path": str(path or "")}
  if not path or not os.path.isfile(str(path)):
    return None, "session-missing"
  try:
    with zipfile.ZipFile(str(path)) as archive:
      names = archive.namelist()
  except (OSError, zipfile.BadZipFile):
    return None, "session-format-invalid"
  facts["members"] = list(names)
  for member in SESSION_MEMBERS:
    if member not in names:
      facts["missing_member"] = member
      return None, "session-format-invalid"
  try:
    with zipfile.ZipFile(str(path)) as archive:
      facts["body_bytes"] = archive.getinfo("body.npy").file_size
  except (OSError, KeyError, zipfile.BadZipFile):
    return None, "session-format-invalid"
  return facts, None


def verify_replay_summary(path):
  """Verify the summary of a human-interface replay.

  Checks (in order):
    1. the summary file exists                -> "replay-summary-missing"
    2. it is not empty                       -> "replay-summary-empty"
    3. it parses and carries the replay fields (REPLAY_FIELDS: the teleop
       summary has no clip and no per-clip error block)
                                                 -> "replay-summary-empty"
    4. the video it names exists and is non-empty
                                                 -> "video-missing"
                                                 / "video-empty"

  Returns (facts, reason).
  """
  if not path or not os.path.isfile(str(path)):
    return None, "replay-summary-missing"
  try:
    size = os.path.getsize(str(path))
  except OSError:
    return None, "replay-summary-missing"
  if size <= 0:
    return None, "replay-summary-empty"
  facts, reason = parse_sim_summary(path, required=REPLAY_FIELDS)
  if reason is not None:
    return None, "replay-summary-empty"
  video = facts.get("video")
  if video:
    video_reason = check_video(video)
    if video_reason is not None:
      return None, video_reason
  return facts, None


def verify_human_replay_summary(path, video_fallback=None):
  """Verify the summary of a HUMAN-INTERFACE teleop replay.

  The teleop branch of deploy/sim2sim/sim_node.py:run_teleop writes a
  different summary than the motion branch: no clip, no per-clip error
  block, but the step count, the falls, the travel and the turn.

  Checks (in order):
    1. the summary file exists                -> "replay-summary-missing"
    2. it is not empty                       -> "replay-summary-empty"
    3. it parses as a JSON object            -> "replay-summary-empty"
    4. it carries the human replay fields
       (robot / steps / falls / travel_along_m)
                                                -> "summary-field-missing"
    5. those fields hold non-empty numbers
       (steps > 0, falls >= 0, travel_along_m finite)
                                                -> "summary-value-empty"
    6. the video it names exists and is non-empty
                                                -> "video-missing"
                                                / "video-empty"

  NOTE on joint_err_rms_rad: under --interface human the policy node sends
  NO reference window to the sim (deploy/sim2sim/policy_node.py: "The sim
  draws robot reference windows only, so a human window is not sent"), so
  the upstream teleop summary carries joint_err_rms_rad = null.  The error
  block is therefore NOT part of the human replay contract; the measured
  facts are the steps, the falls and the travel.

  Returns (facts, reason).
  """
  if not path or not os.path.isfile(str(path)):
    return None, "replay-summary-missing"
  try:
    size = os.path.getsize(str(path))
  except OSError:
    return None, "replay-summary-missing"
  if size <= 0:
    return None, "replay-summary-empty"
  text = _read_text(path)
  if text is None:
    return None, "replay-summary-empty"
  try:
    raw = json.loads(text)
  except (ValueError, TypeError):
    return None, "replay-summary-empty"
  if not isinstance(raw, dict):
    return None, "replay-summary-empty"

  facts = {"path": str(path)}
  for field in HUMAN_REPLAY_FIELDS:
    if field not in raw:
      facts["missing_field"] = field
      return None, "summary-field-missing"

  robot = raw.get("robot")
  if not isinstance(robot, str) or not robot.strip():
    facts["empty_field"] = "robot"
    return None, "summary-value-empty"
  facts["robot"] = robot.strip()

  steps = _to_int(raw.get("steps"))
  if steps is None or steps <= 0:
    facts["empty_field"] = "steps"
    return None, "summary-value-empty"
  facts["steps"] = steps

  falls = _to_int(raw.get("falls"))
  if falls is None or falls < 0:
    facts["empty_field"] = "falls"
    return None, "summary-value-empty"
  facts["falls"] = falls

  travel = _to_float(raw.get("travel_along_m"))
  if travel is None:
    facts["empty_field"] = "travel_along_m"
    return None, "summary-value-empty"
  facts["travel_along_m"] = travel

  # the error block is informational only under the human interface (it is
  # null upstream); it is reported when it holds a number.
  error = _to_float(raw.get("joint_err_rms_rad"))
  facts["joint_err_rms_rad"] = error
  facts["interface"] = raw.get("interface")
  facts["mode"] = raw.get("mode")

  video = raw.get("video")
  facts["video"] = video if isinstance(video, str) and video.strip() else None
  if video:
    # The absolute path stored in the summary is the CONTAINER path
    # (/home/ubuntu/...); the reviewer resolves the artefact by name
    # (video_fallback) so that the host side of the NFS mount reaches the
    # same verdict.
    candidates = [video]
    if video_fallback:
      candidates.append(str(video_fallback))
    found = None
    for candidate in candidates:
      if os.path.isfile(candidate):
        found = candidate
        break
    if found is None:
      return None, "video-missing"
    video_reason = check_video(found)
    if video_reason is not None:
      return None, video_reason
    facts["video_resolved"] = found
  return facts, None


def verify_compare_csv(path, expect_rows=None):
  """Verify the self-vs-official comparison table.

  Checks (in order):
    1. the file exists                        -> "compare-missing"
    2. it parses with the required header     -> "compare-parse-failed"
    3. every row is complete and its deltas are self - official
                                              -> "compare-row-mismatch"
    4. the number of rows equals `expect_rows`-> "compare-row-mismatch"

  Returns (facts, reason).
  """
  facts = {"path": str(path or "")}
  parsed, reason = _read_compare_csv(path)
  if reason is not None:
    return None, reason
  header, rows = parsed
  facts["header"] = list(header)
  facts["rows"] = len(rows)
  facts["data"] = list(rows)
  facts["clips"] = []
  for row in rows:
    clip = (row.get("clip") or "").strip()
    if not clip:
      return None, "compare-row-mismatch"
    facts["clips"].append(clip)
    for side in ("self_", "official_"):
      if not str(row.get(side + "result") or "").strip():
        facts["empty_result"] = side + "result"
        return None, "compare-row-mismatch"
    for metric in ("joint_err_rms_rad", "body_err_mean_m", "end_drift_m"):
      mine = _to_float(row.get("self_" + metric))
      theirs = _to_float(row.get("official_" + metric))
      delta = _to_float(row.get("delta_" + metric))
      if mine is None or theirs is None or delta is None:
        return None, "compare-row-mismatch"
      if abs((mine - theirs) - delta) > 1e-6 * max(1.0, abs(mine - theirs)):
        facts["mismatch_clip"] = clip
        facts["mismatch_metric"] = metric
        return None, "compare-row-mismatch"
  if expect_rows is not None and len(rows) != int(expect_rows):
    facts["expected_rows"] = int(expect_rows)
    return None, "compare-row-mismatch"
  return facts, None


# --------------------------------------------------------------------------
# the terminal reviewer: the cross-artefact verification of slice S08
# --------------------------------------------------------------------------
#
# The orchestrators (repro/21..25) judge their own step; the reviewer below
# re-derives EVERY fact from the artefacts on disk (assets/, runs/), never
# from the self-report of an orchestrator.  It is the only place where the
# question "is the deployment verified?" is answered.


def read_clip_list(path):
  """Read a clip list (one relative clip path per line).

  Returns (entries, reason); entries is the list of the relative clip
  paths (blank lines and comments are skipped), reason is
  "clip-list-missing" (absent / unreadable) or "clip-list-empty".
  """
  if not path or not os.path.isfile(str(path)):
    return None, "clip-list-missing"
  text = _read_text(path)
  if text is None:
    return None, "clip-list-missing"
  entries = []
  for raw in text.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
      continue
    entries.append(line)
  if not entries:
    return None, "clip-list-empty"
  return entries, None


def clip_stem(entry):
  """The clip name of a list entry ("clips/g1_amber/foo.npz" -> "foo")."""
  base = os.path.basename(str(entry))
  if base.endswith(".npz"):
    base = base[:-4]
  return base


def _file_size(path):
  """The size of a file in bytes, or None when it cannot be measured."""
  try:
    return os.path.getsize(str(path))
  except OSError:
    return None


def _mean(values):
  """The mean of the finite numbers of `values`, or None."""
  numbers = [value for value in (values or []) if _to_float(value) is not None]
  if not numbers:
    return None
  return sum(_to_float(value) for value in numbers) / float(len(numbers))


def verify_assets_for_review(directory, list_path=None, robot=None):
  """Verify the exported assets against the sampled clip list.

  Checks (in order):
    1. the assets directory exists          -> "assets-missing"
    2. it holds a robot scene xml          -> "assets-xml-missing"
    3. the xml is not empty                -> "assets-xml-empty"
    4. it holds the clips                  -> "assets-clips-missing"
    5. the clip list is readable           -> "clip-list-missing"
                                               / "clip-list-empty"
    6. the number of clips equals the list -> "assets-clips-mismatch"
    7. every clip of the list exists       -> "assets-clips-missing"
    8. every clip of the list is non-empty -> "assets-clip-empty"
    9. it holds the meshes                 -> "assets-meshes-missing"

  Returns (facts, reason); facts carries the clip list, the stems, the xml
  path / size and the mesh file count.
  """
  facts = {"dir": str(directory or ""), "clips": [], "count": 0}
  if not directory or not os.path.isdir(str(directory)):
    return None, "assets-missing"
  root = str(directory)

  xmls = sorted(name for name in os.listdir(root) if name.endswith(".xml"))
  if not xmls:
    return None, "assets-xml-missing"
  facts["xml"] = os.path.join(root, xmls[0])
  facts["xmls"] = xmls
  xml_bytes = _file_size(facts["xml"])
  facts["xml_bytes"] = xml_bytes
  if xml_bytes is None or xml_bytes <= 0:
    return None, "assets-xml-empty"

  clips = []
  clips_root = os.path.join(root, "clips")
  if os.path.isdir(clips_root):
    for dirpath, _dirnames, filenames in os.walk(clips_root):
      for name in sorted(filenames):
        if name.endswith(".npz"):
          clips.append(os.path.join(dirpath, name))
  if not clips:
    return None, "assets-clips-missing"
  clips.sort()
  facts["clips"] = clips
  facts["count"] = len(clips)

  entries = None
  if list_path is not None:
    entries, reason = read_clip_list(list_path)
    if reason is not None:
      return None, reason
    facts["list"] = str(list_path)
    facts["entries"] = list(entries)
    facts["stems"] = [clip_stem(entry) for entry in entries]
    if len(clips) != len(entries):
      facts["expected_clips"] = len(entries)
      return None, "assets-clips-mismatch"

  for entry in (entries or []):
    path = os.path.join(root, entry)
    if not os.path.isfile(path):
      facts["missing_clip"] = entry
      return None, "assets-clips-missing"
    size = _file_size(path)
    if size is None or size <= 0:
      facts["empty_clip"] = entry
      return None, "assets-clip-empty"

  meshes_root = os.path.join(root, "meshes")
  meshes = []
  if os.path.isdir(meshes_root):
    for dirpath, _dirnames, filenames in os.walk(meshes_root):
      for name in sorted(filenames):
        meshes.append(os.path.join(dirpath, name))
  if not meshes:
    return None, "assets-meshes-missing"
  facts["meshes"] = len(meshes)
  if robot:
    facts["robot"] = robot
  return facts, None


def verify_sim_replay(summary_dir, video_dir=None, expect_stems=None):
  """Verify the per-clip sim2sim summaries AND their videos.

  Checks (in order):
    1. the summary directory exists and holds summaries -> "summary-missing"
    2. every summary parses and carries the contract   -> "summary-parse-failed"
                                                          / "summary-field-missing"
                                                          / "summary-value-empty"
    3. every clip has a video                         -> "video-missing"
    4. every video is non-empty                       -> "video-empty"
    5. every expected clip has a summary              -> "summary-clip-unknown"
    6. the number of summaries equals the expectation -> "summary-count-mismatch"

  The video is looked up by clip name inside `video_dir` FIRST: the
  absolute path stored in the summary is the CONTAINER path
  (/home/ubuntu/...), which does not resolve on the host side of the NFS
  mount.  The reviewer therefore resolves the artefact by name and stays
  side-agnostic.

  Returns (facts, reason).
  """
  facts = {"dir": str(summary_dir or ""), "summaries": [], "count": 0}
  if not summary_dir or not os.path.isdir(str(summary_dir)):
    return None, "summary-missing"
  names = sorted(name for name in os.listdir(str(summary_dir))
                 if name.endswith(".json"))
  if not names:
    return None, "summary-missing"

  for name in names:
    path = os.path.join(str(summary_dir), name)
    summary, reason = parse_sim_summary(path)
    if reason is not None:
      return None, reason
    clip = summary.get("clip") or ""
    candidates = []
    if video_dir:
      candidates.append(os.path.join(str(video_dir), clip + ".mp4"))
    raw_video = summary.get("video")
    if raw_video:
      candidates.append(raw_video)
    found = None
    for candidate in candidates:
      if os.path.isfile(candidate):
        found = candidate
        break
    if found is None:
      facts["missing_video_clip"] = clip
      return None, "video-missing"
    video_reason = check_video(found)
    if video_reason is not None:
      facts["bad_video_clip"] = clip
      return None, video_reason
    facts["summaries"].append(summary)

  facts["count"] = len(facts["summaries"])
  facts["completed"] = 0
  facts["failed"] = 0
  for summary in facts["summaries"]:
    result = str(summary.get("result") or "")
    if result.startswith("completed"):
      facts["completed"] += 1
    else:
      facts["failed"] += 1
  facts["mean_joint_err_rms_rad"] = _mean(
    [summary.get("joint_err_rms_rad") for summary in facts["summaries"]])
  facts["mean_body_err_mean_m"] = _mean(
    [summary.get("body_err_mean_m") for summary in facts["summaries"]])
  facts["mean_end_drift_m"] = _mean(
    [summary.get("end_drift_m") for summary in facts["summaries"]])

  if expect_stems is not None:
    have = set(summary.get("clip") for summary in facts["summaries"])
    missing = [stem for stem in expect_stems if stem not in have]
    if missing:
      facts["missing_clips"] = missing
      return None, "summary-clip-unknown"
    if facts["count"] != len(expect_stems):
      facts["expected_count"] = len(expect_stems)
      return None, "summary-count-mismatch"
  return facts, None


def verify_eval_pair(motion_path, human_path, expect_rows=None):
  """Verify the two per-clip eval CSVs (motion + human).

  Both CSVs must exist, carry the contract header and hold exactly
  `expect_rows` data rows; the completion is recomputed from the "failed"
  column.  A CSV whose "failed" cells cannot be parsed is a failure, too.

  Returns (facts, reason); facts carries the per-interface rows, failures
  and completion.
  """
  facts = {}
  for interface, path in (("motion", motion_path), ("human", human_path)):
    parsed, reason = verify_eval_csv(path, expect_rows,
                                     require_parseable_failed=True)
    if reason is not None:
      return None, reason
    facts[interface] = {
      "path": str(path),
      "rows": parsed["clips"],
      "failures": parsed["failures"],
      "completion": parsed["completion"],
    }
  return facts, None


def verify_human_artifacts(session_path, summary_path, video_path=None):
  """Verify the human-interface artefacts (session + replay summary + video).

  Checks (in order):
    1. the session exists and is a readable npz -> "session-missing"
                                                 / "session-format-invalid"
    2. the session arrays carry the PICO shape-> "session-shape-invalid"
    3. the replay summary exists               -> "replay-summary-missing"
    4. the replay summary is not empty         -> "replay-summary-empty"
    5. the replay summary carries the fields   -> "summary-field-missing"
    6. those fields hold non-empty numbers     -> "summary-value-empty"
    7. the replay video exists and is non-empty-> "video-missing" / "video-empty"

  Returns (facts, reason).
  """
  facts = {"session": str(session_path or ""),
           "summary": str(summary_path or ""),
           "video": str(video_path or "")}
  session, reason = verify_session(session_path)
  if reason is not None:
    return None, reason
  facts["members"] = len(session.get("members") or [])
  arrays, reason = verify_session_arrays(session_path)
  if reason is not None:
    return None, reason
  facts["samples"] = arrays["samples"]
  facts["shapes"] = {name: list(shape) for name, shape in arrays["shapes"].items()}
  facts["session_bytes"] = _file_size(session_path)

  replay, reason = verify_human_replay_summary(summary_path,
                                                video_fallback=video_path)
  if reason is not None:
    return None, reason
  facts["steps"] = replay.get("steps")
  facts["falls"] = replay.get("falls")
  facts["travel_along_m"] = replay.get("travel_along_m")
  facts["joint_err_rms_rad"] = replay.get("joint_err_rms_rad")
  facts["interface"] = replay.get("interface")
  facts["mode"] = replay.get("mode")
  facts["summary_bytes"] = _file_size(summary_path)

  if video_path:
    video_reason = check_video(video_path)
    if video_reason is not None:
      return None, video_reason
    facts["video_bytes"] = _file_size(video_path)
  return facts, None


def verify_deploy_artifacts(config):
  """Verify EVERY artefact of the deployment verification, from disk.

  `config` is a dict with the keys

    assets_dir, clip_list, sim_summary_dir, sim_video_dir,
    eval_motion_csv, eval_human_csv, eval_expect_rows,
    official_dir, compare_csv, compare_expect_rows,
    session, replay_summary, human_video

  The checks run in the order of the slice goal (assets -> sim2sim ->
  eval -> official -> compare -> human) and the FIRST failure wins, so the
  reported reason is always the first broken link of the chain.

  Returns (facts, reason); facts carries every count the OK marker needs.
  """
  config = dict(config or {})
  facts = {}

  assets, reason = verify_assets_for_review(config.get("assets_dir"),
                                             config.get("clip_list"),
                                             config.get("robot"))
  if reason is not None:
    return None, reason
  facts["assets"] = assets
  facts["assets_clips"] = assets["count"]
  stems = assets.get("stems") or []

  sim, reason = verify_sim_replay(config.get("sim_summary_dir"),
                                   config.get("sim_video_dir"),
                                   expect_stems=stems or None)
  if reason is not None:
    return None, reason
  facts["sim"] = sim
  facts["sim_clips"] = sim["count"]

  evaluation, reason = verify_eval_pair(config.get("eval_motion_csv"),
                                         config.get("eval_human_csv"),
                                         config.get("eval_expect_rows"))
  if reason is not None:
    return None, reason
  facts["eval"] = evaluation
  facts["eval_motion_rows"] = evaluation["motion"]["rows"]
  facts["eval_human_rows"] = evaluation["human"]["rows"]
  facts["eval_motion_completion"] = evaluation["motion"]["completion"]
  facts["eval_human_completion"] = evaluation["human"]["completion"]

  official, reason = verify_official_dir(config.get("official_dir"),
                                         require_covered=("policy.onnx", "g1_amber.json"))
  if reason is not None:
    return None, reason
  facts["official"] = official
  facts["official_sha_files"] = len(official.get("checked") or [])

  compare_expect = config.get("compare_expect_rows")
  if compare_expect is None:
    compare_expect = len(stems) or None
  compare, reason = verify_compare_csv(config.get("compare_csv"), compare_expect)
  if reason is not None:
    return None, reason
  facts["compare"] = compare
  facts["compare_rows"] = compare["rows"]
  facts["compare_deltas"] = _compare_delta_means(compare.get("data") or [])

  human, reason = verify_human_artifacts(config.get("session"),
                                          config.get("replay_summary"),
                                          config.get("human_video"))
  if reason is not None:
    return None, reason
  facts["human"] = human
  facts["human_steps"] = human.get("steps")
  return facts, None


def _compare_delta_means(rows):
  """The mean of the three delta columns of a comparison table."""
  means = {}
  for metric in ("joint_err_rms_rad", "body_err_mean_m", "end_drift_m"):
    means[metric] = _mean([row.get("delta_" + metric) for row in rows or []])
  return means


def format_verify_ok(facts):
  """The single DEPLOY_VERIFY_OK line of the terminal reviewer."""
  facts = facts or {}
  return format_ok("DEPLOY_VERIFY",
                   assets_clips=facts.get("assets_clips", 0),
                   sim_clips=facts.get("sim_clips", 0),
                   eval_motion_rows=facts.get("eval_motion_rows", 0),
                   eval_human_rows=facts.get("eval_human_rows", 0),
                   official_sha_files=facts.get("official_sha_files", 0),
                   compare_rows=facts.get("compare_rows", 0),
                   human_steps=facts.get("human_steps", 0))


def format_report_lines(facts):
  """The DEPLOY_REPORT_* lines of the terminal reviewer (documentation)."""
  facts = facts or {}
  lines = []
  assets = facts.get("assets") or {}
  lines.append("DEPLOY_REPORT_ASSETS clips=%s xml=%s xml_bytes=%s meshes=%s list=%s" % (
    facts.get("assets_clips", 0), assets.get("xml", ""),
    assets.get("xml_bytes", 0), assets.get("meshes", 0), assets.get("list", "")))

  sim = facts.get("sim") or {}
  lines.append("DEPLOY_REPORT_SIM clips=%s completed=%s failed=%s mean_joint_err_rms_rad=%s"
               " mean_body_err_mean_m=%s mean_end_drift_m=%s" % (
                 facts.get("sim_clips", 0), sim.get("completed", 0),
                 sim.get("failed", 0),
                 _fmt_number(sim.get("mean_joint_err_rms_rad")),
                 _fmt_number(sim.get("mean_body_err_mean_m")),
                 _fmt_number(sim.get("mean_end_drift_m"))))

  evaluation = facts.get("eval") or {}
  motion = evaluation.get("motion") or {}
  human_eval = evaluation.get("human") or {}
  lines.append("DEPLOY_REPORT_EVAL motion_rows=%s motion_failures=%s motion_completion=%s"
               " human_rows=%s human_failures=%s human_completion=%s" % (
                 motion.get("rows", 0), motion.get("failures", 0),
                 "%.4f" % motion.get("completion", 0.0),
                 human_eval.get("rows", 0), human_eval.get("failures", 0),
                 "%.4f" % human_eval.get("completion", 0.0)))

  official = facts.get("official") or {}
  sha = official.get("sha") or {}
  lines.append("DEPLOY_REPORT_OFFICIAL dir=%s files=%s sha_files=%s policy_onnx_sha=%s"
               " g1_amber_json_sha=%s" % (
                 official.get("dir", ""), len(official.get("files") or []),
                 len(official.get("checked") or []),
                 str(sha.get("policy.onnx", ""))[:16],
                 str(sha.get("g1_amber.json", ""))[:16]))

  deltas = facts.get("compare_deltas") or {}
  lines.append("DEPLOY_REPORT_COMPARE rows=%s mean_delta_joint_err_rms_rad=%s"
               " mean_delta_body_err_mean_m=%s mean_delta_end_drift_m=%s" % (
                 facts.get("compare_rows", 0),
                 _fmt_number(deltas.get("joint_err_rms_rad")),
                 _fmt_number(deltas.get("body_err_mean_m")),
                 _fmt_number(deltas.get("end_drift_m"))))

  human = facts.get("human") or {}
  lines.append("DEPLOY_REPORT_HUMAN steps=%s falls=%s travel_along_m=%s session_bytes=%s"
               " video_bytes=%s interface=%s" % (
                 human.get("steps", 0), human.get("falls", 0),
                 _fmt_number(human.get("travel_along_m")),
                 human.get("session_bytes", 0), human.get("video_bytes", 0),
                 human.get("interface", "")))
  return lines


# --------------------------------------------------------------------------
# thin CLI
# --------------------------------------------------------------------------


def _cmd_sim(args):
  facts, reason = verify_sim_summaries(args.dir, args.expect_count)
  if reason is not None:
    print(format_fail("DEPLOY_SIM", reason))
    return 1
  print(format_ok("DEPLOY_SIM", files=len(facts["summaries"]),
                   expected=args.expect_count if args.expect_count is not None else ""))
  return 0


def _cmd_eval(args):
  facts, reason = verify_eval_csv(args.path, args.expect_rows,
                                  require_parseable_failed=args.require_parseable_failed)
  if reason is not None:
    print(format_fail("DEPLOY_EVAL", reason))
    return 1
  print(format_ok("DEPLOY_EVAL", clips=facts["clips"], failures=facts["failures"],
                   completion="%.4f" % facts["completion"],
                   unparsable=facts.get("unparsable_failed", 0)))
  return 0


def _cmd_subset(args):
  info, reason = parse_subset_yaml(args.path)
  if reason is not None:
    print(format_fail("DEPLOY_EVAL", "eval-csv-missing"))
    sys.stderr.write("reason=%s\n" % reason)
    return 1
  print("root=%s clips=%d" % (info["root"], len(info["clips"])))
  return 0


def _cmd_assets(args):
  facts, reason = verify_assets_dir(args.dir, args.expect_clips)
  if reason is not None:
    print(format_fail("DEPLOY_ASSETS", reason))
    return 1
  print(format_ok("DEPLOY_ASSETS", clips=facts["count"], xml=facts["xml"]))
  return 0


def _cmd_official(args):
  facts, reason = verify_official_dir(args.dir, require_covered=args.require or None)
  if reason is not None:
    print(format_fail("DEPLOY_OFFICIAL", reason))
    return 1
  print(format_ok("DEPLOY_OFFICIAL", files=len(facts.get("files") or []),
                   sha_files=len(facts.get("checked") or []),
                   jsons=len(facts.get("jsons") or [])))
  return 0


def _cmd_session(args):
  facts, reason = verify_session(args.path)
  if reason is not None:
    print(format_fail("DEPLOY_HUMAN", reason))
    return 1
  if getattr(args, "require_shape", False):
    arrays, reason = verify_session_arrays(args.path)
    if reason is not None:
      print(format_fail("DEPLOY_HUMAN", reason))
      return 1
    facts["samples"] = arrays["samples"]
  print(format_ok("DEPLOY_HUMAN", members=len(facts.get("members") or []),
                   samples=facts.get("samples", "")))
  return 0


def _cmd_replay(args):
  facts, reason = verify_human_replay_summary(args.path)
  if reason is not None:
    print(format_fail("DEPLOY_HUMAN", reason))
    return 1
  print(format_ok("DEPLOY_HUMAN", steps=facts.get("steps"),
                  falls=facts.get("falls"),
                  travel_along_m=facts.get("travel_along_m")))
  return 0


def _cmd_compare(args):
  facts, reason = verify_compare_csv(args.path, args.expect_rows)
  if reason is not None:
    print(format_fail("DEPLOY_VERIFY", reason))
    return 1
  print(format_ok("DEPLOY_VERIFY", rows=facts["rows"]))
  return 0


def _read_metric_csv(path):
  """Read a per-side metric CSV (clip/frames/result/three metrics).

  The header must carry a clip name column ("clip" or "name"); the metric
  columns are optional (a missing metric leaves the delta cell empty).
  """
  if not path or not os.path.isfile(str(path)):
    raise SystemExit("deploy.py: cannot read %s" % path)
  try:
    with open(str(path), "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.reader(handle)
      records = [row for row in reader]
  except (OSError, csv.Error, UnicodeError) as error:
    raise SystemExit("deploy.py: cannot read %s (%s)" % (path, error))
  if not records:
    raise SystemExit("deploy.py: %s is empty" % path)
  header = [name.strip() for name in records[0]]
  if "clip" not in header and "name" not in header:
    raise SystemExit("deploy.py: %s has no clip column" % path)
  rows = []
  for record in records[1:]:
    if not record or all(not cell.strip() for cell in record):
      continue
    row = {}
    for index, name in enumerate(header):
      row[name] = record[index] if index < len(record) else ""
    rows.append(row)
  return rows


def _cmd_compare_build(args):
  if args.self_dir or args.official_dir:
    if not (args.self_dir and args.official_dir):
      print(format_fail("DEPLOY_VERIFY", "compare-missing"))
      sys.stderr.write("deploy.py: compare-build needs BOTH summary dirs\n")
      return 1
    self_rows, reason = summaries_to_rows(args.self_dir)
    if reason is not None:
      print(format_fail("DEPLOY_VERIFY", reason))
      return 1
    official_rows, reason = summaries_to_rows(args.official_dir)
    if reason is not None:
      print(format_fail("DEPLOY_VERIFY", reason))
      return 1
  else:
    try:
      self_rows = _read_metric_csv(args.self_csv)
      official_rows = _read_metric_csv(args.official_csv)
    except SystemExit as error:
      print(format_fail("DEPLOY_VERIFY", "compare-missing"))
      sys.stderr.write("%s\n" % error)
      return 1
  text = build_compare_csv(self_rows, official_rows)
  if args.out:
    with open(str(args.out), "w", encoding="utf-8", newline="") as handle:
      handle.write(text)
  else:
    sys.stdout.write(text)
  return 0


def _review_config(args):
  """The configuration of the terminal reviewer (from the CLI arguments)."""
  return {
    "assets_dir": args.assets_dir,
    "clip_list": args.clip_list,
    "sim_summary_dir": args.sim_summary_dir,
    "sim_video_dir": args.sim_video_dir,
    "eval_motion_csv": args.eval_motion_csv,
    "eval_human_csv": args.eval_human_csv,
    "eval_expect_rows": args.eval_expect_rows,
    "official_dir": args.official_dir,
    "compare_csv": args.compare_csv,
    "compare_expect_rows": args.compare_expect_rows,
    "session": args.session,
    "replay_summary": args.replay_summary,
    "human_video": args.human_video,
    "robot": args.robot,
  }


def _cmd_verify_all(args):
  facts, reason = verify_deploy_artifacts(_review_config(args))
  if reason is not None:
    print(format_fail("DEPLOY_VERIFY", reason))
    return 1
  print(format_verify_ok(facts))
  return 0


def _cmd_report_all(args):
  facts, reason = verify_deploy_artifacts(_review_config(args))
  if reason is not None:
    print(format_fail("DEPLOY_VERIFY", reason))
    return 1
  for line in format_report_lines(facts):
    print(line)
  return 0


def build_parser():
  parser = argparse.ArgumentParser(
    prog="deploy.py",
    description="Decision base of the deployment verification (stdlib only).")
  sub = parser.add_subparsers(dest="command")

  sim = sub.add_parser("sim", help="verify the sim2sim summaries of a directory")
  sim.add_argument("--dir", required=True)
  sim.add_argument("--expect-count", type=int, default=None)
  sim.set_defaults(func=_cmd_sim)

  evaluate = sub.add_parser("eval", help="verify a per-clip eval CSV")
  evaluate.add_argument("--path", required=True)
  evaluate.add_argument("--expect-rows", type=int, default=None)
  evaluate.add_argument("--require-parseable-failed", action="store_true",
                        help="refuse a CSV whose `failed` cells cannot be parsed")
  evaluate.set_defaults(func=_cmd_eval)

  subset = sub.add_parser("subset", help="read a subset yaml (root + clip count)")
  subset.add_argument("--path", required=True)
  subset.set_defaults(func=_cmd_subset)

  assets = sub.add_parser("assets", help="verify an export_assets directory")
  assets.add_argument("--dir", required=True)
  assets.add_argument("--expect-clips", type=int, default=None)
  assets.set_defaults(func=_cmd_assets)

  official = sub.add_parser("official", help="verify an unpacked official policy dir")
  official.add_argument("--dir", required=True)
  official.add_argument("--require", action="append", default=[],
                        help="a file that SHA256SUMS must cover (repeatable)")
  official.set_defaults(func=_cmd_official)

  session = sub.add_parser("session", help="verify a make_gmr_session recording")
  session.add_argument("--path", required=True)
  session.add_argument("--require-shape", action="store_true",
                        help="also check the array shapes (body [N,24,7])")
  session.set_defaults(func=_cmd_session)

  replay = sub.add_parser("replay", help="verify a human-interface replay summary")
  replay.add_argument("--path", required=True)
  replay.set_defaults(func=_cmd_replay)

  compare = sub.add_parser("compare", help="verify a self-vs-official table")
  compare.add_argument("--path", required=True)
  compare.add_argument("--expect-rows", type=int, default=None)
  compare.set_defaults(func=_cmd_compare)

  build = sub.add_parser("compare-build", help="build a self-vs-official table")
  build.add_argument("--self-csv", default=None)
  build.add_argument("--official-csv", default=None)
  build.add_argument("--self-dir", default=None,
                     help="a directory of deploy.run summary json files")
  build.add_argument("--official-dir", default=None,
                     help="a directory of deploy.run summary json files")
  build.add_argument("--out", default=None)
  build.set_defaults(func=_cmd_compare_build)

  review = sub.add_parser("verify-all",
                          help="verify EVERY deployment artefact from disk")
  review.add_argument("--assets-dir", default="assets")
  review.add_argument("--clip-list", default="assets/clips_g1_amber.txt")
  review.add_argument("--sim-summary-dir", default="runs/sim2sim/summary")
  review.add_argument("--sim-video-dir", default="runs/sim2sim/video")
  review.add_argument("--eval-motion-csv", default="runs/eval/eval_motion_1h.csv")
  review.add_argument("--eval-human-csv", default="runs/eval/eval_human_full_1h.csv")
  review.add_argument("--eval-expect-rows", type=int, default=None)
  review.add_argument("--official-dir", default="runs/official/morphmimic_policy")
  review.add_argument("--compare-csv", default="runs/official/compare_self_vs_official.csv")
  review.add_argument("--compare-expect-rows", type=int, default=None)
  review.add_argument("--session", default="runs/human/session.npz")
  review.add_argument("--replay-summary", default="runs/human/replay_summary.json")
  review.add_argument("--human-video", default="runs/human/replay.mp4")
  review.add_argument("--robot", default="g1_amber")
  review.set_defaults(func=_cmd_verify_all)

  report = sub.add_parser("report-all",
                           help="the DEPLOY_REPORT_* facts of the terminal reviewer")
  report.add_argument("--assets-dir", default="assets")
  report.add_argument("--clip-list", default="assets/clips_g1_amber.txt")
  report.add_argument("--sim-summary-dir", default="runs/sim2sim/summary")
  report.add_argument("--sim-video-dir", default="runs/sim2sim/video")
  report.add_argument("--eval-motion-csv", default="runs/eval/eval_motion_1h.csv")
  report.add_argument("--eval-human-csv", default="runs/eval/eval_human_full_1h.csv")
  report.add_argument("--eval-expect-rows", type=int, default=None)
  report.add_argument("--official-dir", default="runs/official/morphmimic_policy")
  report.add_argument("--compare-csv", default="runs/official/compare_self_vs_official.csv")
  report.add_argument("--compare-expect-rows", type=int, default=None)
  report.add_argument("--session", default="runs/human/session.npz")
  report.add_argument("--replay-summary", default="runs/human/replay_summary.json")
  report.add_argument("--human-video", default="runs/human/replay.mp4")
  report.add_argument("--robot", default="g1_amber")
  report.set_defaults(func=_cmd_report_all)

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
