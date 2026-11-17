#!/usr/bin/env python3
"""repro/lib/train.py — the decision base of the g1_amber training run
(slice S06).

Standard library ONLY (argparse / csv / datetime / json / math / os / re /
sys).  The python3 on the PATH inside the ros_dev container has NO numpy and
the project venv is not guaranteed to be alive, so every decision used by the
training orchestrator (`repro/17_train.sh`) and by the read-only verifier
(`repro/18_train_verify.sh`) lives here, as a pure function that can be
driven offline by fixtures.

Why a pure-function library (project convention, see MEM059):
  the shell used to parse the very same numbers in awk/grep while python
  parsed them again -> two parsers drifted.  Here there is exactly ONE
  parser; `repro/lib/train.sh` is a thin wrapper that only selects the
  interpreter and forwards arguments.

Pure functions
  parse_log_line(line)        -> dict | None
  parse_log_file(path)        -> dict | None
  plan_iterations(b, it/s, f) -> int
  plan_ckpt_every(it, min)    -> int
  plan_lr_decay_iters(it)    -> int
  budget_ok(gpu, host, wall)  -> (bool, [reason, ...])
  parse_resource_csv(path)   -> dict | None
  nan_audit(scalars, white)   -> (ok, bad_tags, missing, violations)
  curve_rows_from_scalars(s)  -> [(step, tag, value), ...]
  curve_summary_rows(rows)    -> [{tag, n, first_step, last_step, min, max, mean}]
  curve_step_coverage(rows)   -> {min_step, max_step, n_steps, n_rows}
  write_curve_csv(path, rows) -> None   (atomic)
  write_curve_summary_csv(p, r) -> None  (atomic)
  check_curve_artifacts(...)  -> (ok, reasons, metrics)
  write_status(path, ...)     -> None   (atomic)
  read_status(path)           -> dict

Thin CLI (for the shell wrappers):
  train.py log-summary <log-file>
  train.py plan --budget-seconds N --it-per-s X [--factor F] [--min-ckpts N]
  train.py budget --gpu-peak-mb N --host-peak-gb X --wall-s N
                [--gpu-max-mb N] [--host-max-gb X] [--wall-max-s N]
  train.py curves --scalars-json FILE|- --out-dir DIR [--name N] [...]
  train.py curves-verify --csv FILE --summary FILE [...]

Exit code 0 == the requested decision is satisfied; 1 == the decision is
negative (the reason is printed on stdout as `reason=...`).
"""

import argparse
import csv
import datetime
import json
import math
import os
import re
import sys

# --------------------------------------------------------------------------
# constants (all budgets come from the M001 decisions / R011)
# --------------------------------------------------------------------------

#: GPU peak limit in MiB.  R011 says "peak VRAM < 22 GB"; the decision base
#: works in MiB because that is what nvidia-smi reports.
GPU_LIMIT_MB = 22 * 1024

#: Host RAM peak limit in GiB (R011: "peak host RAM < 45 GB").
HOST_LIMIT_GB = 45.0

#: Default safety factor of the iteration plan (budget x it/s x 0.85).
DEFAULT_FACTOR = 0.85

#: Minimum number of `ckpt_*.pt` files the formal run must leave behind.
DEFAULT_MIN_CKPTS = 3

#: `ckpt_every` is always a multiple of this (and never below it).
CKPT_GRID = 1000

#: The tensorboard tags that are required to exist in a healthy run.
REQUIRED_TAGS = (
  "wm/state_loss",
  "wm/nonfinite_steps",
  "policy/objective",
  "policy/nonfinite_steps",
  "critic/loss",
  "critic/nonfinite_steps",
  "kp/nonfinite_steps",
  "perf/it_per_s",
  "perf/gpu_mem_gb",
)

#: The `*/nonfinite_steps` counters that must stay exactly 0.
NONFINITE_STEP_TAGS = (
  "wm/nonfinite_steps",
  "policy/nonfinite_steps",
  "critic/nonfinite_steps",
  "kp/nonfinite_steps",
  "critic_kp/nonfinite_steps",
)

#: Tags that are NaN BY DESIGN under `--kp-student copy`
#: (upstream trainer.py:1935 / 2002).  They are allowed to be non-finite.
DEFAULT_WHITELIST = ("kp/return", "kp/scale_return")

#: Header of the resource sampler CSV written by repro/17_train_worker.sh.
RESOURCE_COLUMNS = (
  "ts",
  "iter",
  "gpu_used_mb",
  "gpu_total_mb",
  "host_used_gb",
  "host_avail_gb",
  "proc_rss_gb",
)

#: Fixed field order of the status files (S03/S04 convention).
STATUS_FIELDS = ("STATE", "RC", "STARTED_AT")
STATUS_FIELDS_TAIL = ("FINISHED_AT",)

# --------------------------------------------------------------------------
# log parsing
# --------------------------------------------------------------------------

_RE_IT = re.compile(r"\[morphmimic\]\s+it\s+(\d+)\b")
_RE_ITPS = re.compile(r"\|\s*([0-9]+(?:\.[0-9]+)?)\s*it/s")
_RE_MEM = re.compile(r"\|\s*mem\s+([0-9]+(?:\.[0-9]+)?)\s*GB")
_RE_WMLOSS = re.compile(r"\bwm loss\s+([-+0-9.eE]+)")
_RE_POLICY = re.compile(r"\|\s*J\s+([-+0-9.eE]+)")
_RE_CRITIC = re.compile(r"\bcritic\s+([-+0-9.eE]+)")
_RE_NONFINITE = re.compile(
  r"nonfinite wm/pol/critic\s+(\d+)\s*/\s*(\d+)\s*/\s*(\d+)")
_RE_KP_J = re.compile(r"\bkp J\s+(nan|[-+0-9.eE]+)")
_RE_RESUME = re.compile(r"resumed\s+(?P<path>.*?)\s+at iteration\s+(?P<it>\d+)")


def _to_float(text):
  """Return a finite float, or None when the text is not a finite number."""
  try:
    value = float(text)
  except (TypeError, ValueError):
    return None
  if not math.isfinite(value):
    return None
  return value


def parse_log_line(line):
  """Parse one upstream training log line.

  Returns a dict with the keys

    it              int   iteration number
    it_per_s        float iterations per second
    mem_gb          float torch peak GPU memory in GB (None when absent)
    wm_loss         float world-model loss (None when absent)
    policy_objective float
    critic_loss     float
    nonfinite_wm    int
    nonfinite_pol   int
    nonfinite_critic int
    kp_j_nan        bool  the `kp J nan` marker (design NaN under copy)

  or None when the line is not an iteration line (never raises).
  """
  if not line or not isinstance(line, str):
    return None
  match = _RE_IT.search(line)
  if not match:
    return None
  itps_match = _RE_ITPS.search(line)
  if not itps_match:
    return None

  it = int(match.group(1))
  it_per_s = float(itps_match.group(1))

  mem_gb = None
  mem_match = _RE_MEM.search(line)
  if mem_match:
    mem_gb = float(mem_match.group(1))

  wm_loss = None
  wm_match = _RE_WMLOSS.search(line)
  if wm_match:
    wm_loss = _to_float(wm_match.group(1))

  policy_objective = None
  policy_match = _RE_POLICY.search(line)
  if policy_match:
    policy_objective = _to_float(policy_match.group(1))

  critic_loss = None
  critic_match = _RE_CRITIC.search(line)
  if critic_match:
    critic_loss = _to_float(critic_match.group(1))

  nonfinite = (0, 0, 0)
  nf_match = _RE_NONFINITE.search(line)
  if nf_match:
    nonfinite = (
      int(nf_match.group(1)),
      int(nf_match.group(2)),
      int(nf_match.group(3)),
    )

  kp_j_nan = False
  kp_match = _RE_KP_J.search(line)
  if kp_match:
    kp_j_nan = kp_match.group(1).lower() == "nan"

  return {
    "it": it,
    "it_per_s": it_per_s,
    "mem_gb": mem_gb,
    "wm_loss": wm_loss,
    "policy_objective": policy_objective,
    "critic_loss": critic_loss,
    "nonfinite_wm": nonfinite[0],
    "nonfinite_pol": nonfinite[1],
    "nonfinite_critic": nonfinite[2],
    "kp_j_nan": kp_j_nan,
  }


def parse_log_file(path):
  """Summarise a whole upstream training log.

  Returns a dict

    max_it          int    highest iteration seen (0 when no iteration line)
    it_per_s        list   every parsed it/s value, in file order
    mem_gb_peak     float  peak `mem ... GB` value (None when never seen)
    nonfinite       dict   {"wm": n, "pol": n, "critic": n} summed over lines
    resume_events   list   [(checkpoint path, iteration), ...]
    lines           int    number of lines read
    parsed_lines    int    number of iteration lines parsed

  or None when the file does not exist (fail-closed).
  """
  if not path or not os.path.isfile(path):
    return None
  summary = {
    "max_it": 0,
    "it_per_s": [],
    "mem_gb_peak": None,
    "nonfinite": {"wm": 0, "pol": 0, "critic": 0},
    "resume_events": [],
    "lines": 0,
    "parsed_lines": 0,
  }
  with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for raw in handle:
      summary["lines"] += 1
      line = raw.rstrip("\n")
      resume = _RE_RESUME.search(line)
      if resume:
        summary["resume_events"].append(
          (resume.group("path"), int(resume.group("it"))))
      parsed = parse_log_line(line)
      if parsed is None:
        continue
      summary["parsed_lines"] += 1
      summary["it_per_s"].append(parsed["it_per_s"])
      if parsed["it"] > summary["max_it"]:
        summary["max_it"] = parsed["it"]
      if parsed["mem_gb"] is not None:
        peak = summary["mem_gb_peak"]
        if peak is None or parsed["mem_gb"] > peak:
          summary["mem_gb_peak"] = parsed["mem_gb"]
      summary["nonfinite"]["wm"] += parsed["nonfinite_wm"]
      summary["nonfinite"]["pol"] += parsed["nonfinite_pol"]
      summary["nonfinite"]["critic"] += parsed["nonfinite_critic"]
  return summary


# --------------------------------------------------------------------------
# planning
# --------------------------------------------------------------------------


def plan_iterations(budget_seconds, it_per_s, factor=DEFAULT_FACTOR):
  """Return floor(budget_seconds * it_per_s * factor).

  Fail-closed: a non-positive / non-finite budget, throughput or factor
  yields 0 -- never a negative number and never NaN.
  """
  values = (budget_seconds, it_per_s, factor)
  for value in values:
    if value is None:
      return 0
    try:
      if not math.isfinite(float(value)):
        return 0
    except (TypeError, ValueError):
      return 0
  budget = float(budget_seconds)
  speed = float(it_per_s)
  ratio = float(factor)
  if budget <= 0.0 or speed <= 0.0 or ratio <= 0.0:
    return 0
  return int(math.floor(budget * speed * ratio))


def ckpt_count(iterations, ckpt_every):
  """Number of `ckpt_*.pt` files a run of `iterations` leaves behind.

  The upstream trainer writes a checkpoint every `ckpt_every` iterations and
  a final `latest.pt` at the end of the run, therefore the count is
  ceil(iterations / ckpt_every) (the last, possibly partial, segment still
  produces one checkpoint).
  """
  if iterations is None or ckpt_every is None:
    return 0
  iterations = int(iterations)
  ckpt_every = int(ckpt_every)
  if iterations <= 0 or ckpt_every <= 0:
    return 0
  return int(math.ceil(iterations / float(ckpt_every)))


def plan_ckpt_every(iterations, min_ckpts=DEFAULT_MIN_CKPTS):
  """Return the smallest `ckpt_every` (multiple of 1000, at least 1000) that
  still leaves >= `min_ckpts` checkpoints behind.

  Fail-closed: a non-positive iteration count or min_ckpts yields 1000 (the
  smallest legal value) instead of a nonsensical 0.

  NOTE: when `iterations` is too small for `min_ckpts` checkpoints to exist
  at all (iterations < min_ckpts * 1000), the smallest legal value 1000 is
  returned -- the guarantee cannot be met inside the "ckpt_every is a
  multiple of 1000 and at least 1000" rule.
  """
  if iterations is None or min_ckpts is None:
    return CKPT_GRID
  iterations = int(iterations)
  min_ckpts = int(min_ckpts)
  if iterations <= 0 or min_ckpts <= 0:
    return CKPT_GRID
  raw = iterations / float(min_ckpts)
  every = int(math.ceil(raw / CKPT_GRID)) * CKPT_GRID
  if every < CKPT_GRID:
    every = CKPT_GRID
  # Rounding UP to the grid may push the count below min_ckpts; step back
  # until the guarantee holds (never below 1000).
  while every > CKPT_GRID and ckpt_count(iterations, every) < min_ckpts:
    every -= CKPT_GRID
  return every


def plan_lr_decay_iters(iterations):
  """Return the `--lr-decay-iters` value for a run of `iterations`.

  MEM005 (M001 decision): the LR schedule must cover the WHOLE formal run,
  therefore `--lr-decay-iters == --iterations` (the upstream README default
  of 250,000 would never decay inside a short run).
  """
  if iterations is None:
    return 0
  try:
    iterations = int(iterations)
  except (TypeError, ValueError):
    return 0
  if iterations <= 0:
    return 0
  return iterations


def budget_ok(gpu_peak_mb, host_peak_gb, wall_s, limits=None):
  """Check the observed resource peaks against the budget.

  `limits` is a dict with the optional keys

    gpu_max_mb   (default GPU_LIMIT_MB = 22 * 1024 MiB, strict `<`)
    host_max_gb  (default HOST_LIMIT_GB = 45.0, strict `<`)
    wall_max_s   (default None: the wall clock is then not checked)

  Returns (ok, reasons).  `reasons` lists every violated limit with the
  observed value; an empty list means "everything inside the budget".
  """
  limits = limits or {}
  gpu_max = float(limits.get("gpu_max_mb", GPU_LIMIT_MB))
  host_max = float(limits.get("host_max_gb", HOST_LIMIT_GB))
  wall_max = limits.get("wall_max_s", None)

  reasons = []

  gpu = _to_float(gpu_peak_mb)
  if gpu is None:
    reasons.append("gpu peak missing (reason=gpu-peak-missing 显存峰值缺失)")
  elif gpu >= gpu_max:
    reasons.append(
      "gpu peak %.0f MiB >= limit %.0f MiB "
      "(reason=gpu-peak-over-budget 显存峰值超预算)" % (gpu, gpu_max))

  host = _to_float(host_peak_gb)
  if host is None:
    reasons.append(
      "host memory peak missing (reason=host-peak-missing 主机内存峰值缺失)")
  elif host >= host_max:
    reasons.append(
      "host peak %.2f GiB >= limit %.2f GiB "
      "(reason=host-peak-over-budget 主机内存超预算)" % (host, host_max))

  wall = _to_float(wall_s)
  if wall_max is not None:
    wall_limit = float(wall_max)
    if wall is None:
      reasons.append("wall clock missing (reason=wall-clock-missing 墙钟缺失)")
    elif wall > wall_limit:
      reasons.append(
        "wall clock %.0f s > budget %.0f s "
        "(reason=wall-over-budget 墙钟超预算)" % (wall, wall_limit))

  return (not reasons), reasons


# --------------------------------------------------------------------------
# resource CSV
# --------------------------------------------------------------------------


def parse_resource_csv(path):
  """Parse the resource sampler CSV.

  Expected header: `ts,iter,gpu_used_mb,gpu_total_mb,host_used_gb,`
  `host_avail_gb,proc_rss_gb`.

  Returns a dict

    gpu_used_mb_peak   float
    gpu_total_mb       float  (max observed total, for cross-checking)
    host_used_gb_peak  float
    host_avail_gb_min  float
    samples            int

  or None when the file is missing / empty / misses a column (fail-closed).
  """
  if not path or not os.path.isfile(path):
    return None
  try:
    with open(path, "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.DictReader(handle)
      fields = reader.fieldnames or []
      missing = [c for c in RESOURCE_COLUMNS if c not in fields]
      if missing:
        return None
      rows = list(reader)
  except OSError:
    return None
  if not rows:
    return None

  gpu_peak = None
  gpu_total = None
  host_peak = None
  host_avail_min = None
  samples = 0
  for row in rows:
    samples += 1
    used = _to_float((row.get("gpu_used_mb") or "").strip())
    if used is not None and (gpu_peak is None or used > gpu_peak):
      gpu_peak = used
    total = _to_float((row.get("gpu_total_mb") or "").strip())
    if total is not None and (gpu_total is None or total > gpu_total):
      gpu_total = total
    host = _to_float((row.get("host_used_gb") or "").strip())
    if host is not None and (host_peak is None or host > host_peak):
      host_peak = host
    avail = _to_float((row.get("host_avail_gb") or "").strip())
    if avail is not None and (host_avail_min is None or avail < host_avail_min):
      host_avail_min = avail

  return {
    "gpu_used_mb_peak": gpu_peak,
    "gpu_total_mb": gpu_total,
    "host_used_gb_peak": host_peak,
    "host_avail_gb_min": host_avail_min,
    "samples": samples,
  }


# --------------------------------------------------------------------------
# tensorboard NaN audit
# --------------------------------------------------------------------------


def _is_finite_number(value):
  """True when `value` is a finite number (NaN / Inf / non-numbers fail)."""
  if isinstance(value, bool):
    return True
  if isinstance(value, int):
    return True
  if isinstance(value, float):
    return math.isfinite(value)
  return False


def nan_audit(scalars_by_tag, whitelist=None):
  """Audit the aggregated tensorboard scalars of a run.

  `scalars_by_tag` maps a tag onto the list of its scalar values.
  `whitelist` defaults to DEFAULT_WHITELIST (tags allowed to be non-finite
  by design).

  Returns (ok, bad_tags, missing_required_tags, nonfinite_steps_violations)

    bad_tags                  tags outside the whitelist with a non-finite value
    missing_required_tags     required tags absent (or empty)
    nonfinite_steps_violations "<tag>=<max>" strings for every counter > 0
  """
  if scalars_by_tag is None:
    scalars_by_tag = {}
  white = set(whitelist) if whitelist is not None else set(DEFAULT_WHITELIST)

  bad_tags = []
  for tag, values in sorted(scalars_by_tag.items()):
    if tag in white:
      continue
    if not values:
      continue
    for value in values:
      if not _is_finite_number(value):
        bad_tags.append(tag)
        break

  missing = []
  for tag in REQUIRED_TAGS:
    values = scalars_by_tag.get(tag)
    if not values:
      missing.append(tag)

  violations = []
  for tag in NONFINITE_STEP_TAGS:
    values = scalars_by_tag.get(tag)
    if not values:
      continue
    worst = None
    for value in values:
      if not _is_finite_number(value):
        worst = float("inf")
        break
      if worst is None or value > worst:
        worst = value
    if worst is not None and worst > 0:
      violations.append("%s=%s" % (tag, worst))

  ok = not bad_tags and not missing and not violations
  return ok, bad_tags, missing, violations


# --------------------------------------------------------------------------
# training curve extraction (slice S09, task T1)
# --------------------------------------------------------------------------
#
# The g1_amber run writes ONE tensorboard events file per process start
# (10 files for the formal run).  Reading a single file under-reports, so the
# extraction aggregates the WHOLE run directory.  The aggregation itself
# needs tensorboard (container venv only) and therefore lives in the shell
# probe; everything that DECIDES something lives here, stdlib only, so the
# same rules run on the host and inside the container.

#: Column order of the curve CSV (step, tag, value).
CURVE_COLUMNS = ("step", "tag", "value")

#: Column order of the per-tag summary CSV.
CURVE_SUMMARY_COLUMNS = (
  "tag", "n", "first_step", "last_step", "min", "max", "mean")

#: The fixed reason set of the curve gate (shared with repro/27_train_curves.sh).
CURVE_REASONS = (
  "run-dir-missing",
  "events-missing",
  "events-count-mismatch",
  "tb-unavailable",
  "extraction-failed",
  "nan-nonwhitelist",
  "nonfinite-steps",
  "tag-missing",
  "tag-count-mismatch",
  "curve-empty",
  "curve-step-mismatch",
  "curve-row-count-mismatch",
  "curve-csv-missing",
  "curve-csv-malformed",
  "curve-summary-mismatch",
  "analysis-failed",
)


def _curve_value(raw):
  """Coerce one scalar of the extractor into a float.

  NaN / +-Inf are preserved (they are DATA, not errors: `kp/return` and
  `kp/scale_return` are NaN by design under `--kp-student copy`).  Anything
  that is not a number at all yields None (the row is dropped).
  """
  if isinstance(raw, bool):
    return None
  if isinstance(raw, (int, float)):
    return float(raw)
  if isinstance(raw, str):
    text = raw.strip().lower()
    if text in ("nan", "+nan", "-nan"):
      return float("nan")
    if text in ("inf", "+inf", "infinity", "+infinity"):
      return float("inf")
    if text in ("-inf", "-infinity"):
      return float("-inf")
    try:
      return float(text)
    except ValueError:
      return None
  return None


def _fmt_curve_value(value):
  """Format a scalar for the CSV (round-trip exact for finite floats)."""
  if value is None:
    return ""
  value = float(value)
  if math.isnan(value):
    return "nan"
  if math.isinf(value):
    return "inf" if value > 0 else "-inf"
  return repr(value)


def curve_rows_from_scalars(scalars_by_tag):
  """Turn the aggregated scalars into the flat curve rows.

  `scalars_by_tag` maps a tag onto a list of `(step, value)` pairs (the
  value may be a float, a NaN/Inf float or the string form thereof).

  Returns the rows `[(step, tag, value), ...]` sorted by (step, tag).
  Unparsable entries are dropped (never raise).
  """
  rows = []
  for tag in sorted(scalars_by_tag or {}):
    entries = scalars_by_tag[tag] or []
    for entry in entries:
      try:
        step = int(entry[0])
        raw = entry[1]
      except (TypeError, ValueError, IndexError, KeyError):
        continue
      value = _curve_value(raw)
      if value is None:
        continue
      rows.append((step, tag, value))
  rows.sort(key=lambda row: (row[0], row[1]))
  return rows


def curve_summary_rows(rows):
  """Aggregate the curve rows into one summary row per tag.

  Returns a list of dicts

    tag          str
    n            int    number of points of that tag
    first_step   int
    last_step    int
    min          float  over the FINITE values only (None when none)
    max          float  over the FINITE values only (None when none)
    mean         float  over the FINITE values only (None when none)

  sorted by tag.  The non-finite values (the whitelisted design NaNs) are
  counted in `n` but excluded from min / max / mean -- otherwise a single
  NaN would poison the whole summary.
  """
  buckets = {}
  for step, tag, value in rows:
    bucket = buckets.get(tag)
    if bucket is None:
      bucket = {"n": 0, "first_step": None, "last_step": None, "finite": []}
      buckets[tag] = bucket
    bucket["n"] += 1
    if bucket["first_step"] is None or step < bucket["first_step"]:
      bucket["first_step"] = step
    if bucket["last_step"] is None or step > bucket["last_step"]:
      bucket["last_step"] = step
    if math.isfinite(value):
      bucket["finite"].append(value)

  summary = []
  for tag in sorted(buckets):
    bucket = buckets[tag]
    finite = bucket["finite"]
    summary.append({
      "tag": tag,
      "n": bucket["n"],
      "first_step": bucket["first_step"],
      "last_step": bucket["last_step"],
      "min": min(finite) if finite else None,
      "max": max(finite) if finite else None,
      "mean": (sum(finite) / len(finite)) if finite else None,
    })
  return summary


def curve_step_coverage(rows):
  """Describe the step range covered by the curve rows.

  Returns a dict

    min_step   int  (None when there is no row)
    max_step   int  (None when there is no row)
    n_steps    int  number of distinct steps
    n_rows     int  number of rows
  """
  steps = set()
  min_step = None
  max_step = None
  count = 0
  for row in rows:
    step = row[0]
    count += 1
    steps.add(step)
    if min_step is None or step < min_step:
      min_step = step
    if max_step is None or step > max_step:
      max_step = step
  return {
    "min_step": min_step,
    "max_step": max_step,
    "n_steps": len(steps),
    "n_rows": count,
  }


def _write_csv_atomic(path, header, rows):
  """Write a CSV atomically (`path.tmp` first, then `os.replace`)."""
  directory = os.path.dirname(os.path.abspath(path))
  if directory:
    os.makedirs(directory, exist_ok=True)
  tmp = path + ".tmp"
  with open(tmp, "w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(list(header))
    for row in rows:
      writer.writerow(list(row))
    handle.flush()
    os.fsync(handle.fileno())
  os.replace(tmp, path)
  return path


def write_curve_csv(path, rows):
  """Write the curve CSV (columns: step, tag, value) atomically."""
  body = [(step, tag, _fmt_curve_value(value))
          for step, tag, value in rows]
  return _write_csv_atomic(path, CURVE_COLUMNS, body)


def write_curve_summary_csv(path, summary_rows):
  """Write the per-tag summary CSV atomically."""
  body = []
  for row in summary_rows:
    body.append((
      row.get("tag", ""),
      row.get("n", 0),
      "" if row.get("first_step") is None else row.get("first_step"),
      "" if row.get("last_step") is None else row.get("last_step"),
      "" if row.get("min") is None else _fmt_curve_value(row.get("min")),
      "" if row.get("max") is None else _fmt_curve_value(row.get("max")),
      "" if row.get("mean") is None else _fmt_curve_value(row.get("mean")),
    ))
  return _write_csv_atomic(path, CURVE_SUMMARY_COLUMNS, body)


def read_curve_csv(path):
  """Read the curve CSV back into `[(step, tag, value), ...]`.

  Returns None when the file is missing or does not carry the expected
  header (fail-closed: a malformed artefact is never silently accepted).
  """
  if not path or not os.path.isfile(path):
    return None
  rows = []
  try:
    with open(path, "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.reader(handle)
      header = next(reader, None)
      if header is None:
        return None
      header = [field.strip() for field in header]
      if header != list(CURVE_COLUMNS):
        return None
      for raw in reader:
        if len(raw) < 3:
          continue
        try:
          step = int(raw[0])
        except ValueError:
          continue
        value = _curve_value(raw[2])
        if value is None:
          continue
        rows.append((step, raw[1].strip(), value))
  except OSError:
    return None
  return rows


def read_curve_summary_csv(path):
  """Read the summary CSV back into a list of dicts (None when malformed)."""
  if not path or not os.path.isfile(path):
    return None
  out = []
  try:
    with open(path, "r", newline="", encoding="utf-8", errors="replace") as handle:
      reader = csv.DictReader(handle)
      fields = reader.fieldnames or []
      if [field.strip() for field in fields] != list(CURVE_SUMMARY_COLUMNS):
        return None
      for raw in reader:
        out.append({
          "tag": (raw.get("tag") or "").strip(),
          "n": int(raw.get("n") or 0),
          "first_step": int(raw["first_step"]) if (raw.get("first_step") or "") else None,
          "last_step": int(raw["last_step"]) if (raw.get("last_step") or "") else None,
          "min": _curve_value(raw.get("min") or ""),
          "max": _curve_value(raw.get("max") or ""),
          "mean": _curve_value(raw.get("mean") or ""),
        })
  except (OSError, ValueError):
    return None
  return out


def _same_float(left, right):
  if left is None or right is None:
    return left is None and right is None
  if math.isnan(left) and math.isnan(right):
    return True
  return abs(left - right) <= 1e-9 * max(1.0, abs(left), abs(right))


def _summary_equal(derived, parsed):
  """Compare the derived summary with the summary CSV on disk."""
  if len(derived) != len(parsed):
    return False
  by_tag = {row.get("tag"): row for row in parsed}
  for row in derived:
    other = by_tag.get(row.get("tag"))
    if other is None:
      return False
    if int(other.get("n") or 0) != int(row.get("n") or 0):
      return False
    if other.get("first_step") != row.get("first_step"):
      return False
    if other.get("last_step") != row.get("last_step"):
      return False
    for key in ("min", "max", "mean"):
      if not _same_float(other.get(key), row.get(key)):
        return False
  return True


def check_curve_artifacts(csv_path, summary_path=None, whitelist=None,
                          expected_events_files=None, expected_tags=None,
                          expected_rows=None, expected_max_step=None,
                          expected_min_step=None):
  """Re-derive every curve fact from the artefacts on disk.

  This NEVER trusts the extraction log: the CSV is read back, the rows are
  re-aggregated and the NaN verdict is taken from `nan_audit` (the single
  NaN source of truth, with DEFAULT_WHITELIST).

  Returns (ok, reasons, metrics) with

    metrics["rows"]        number of curve rows
    metrics["tags"]        number of distinct tags
    metrics["min_step"]    first logged step (None when empty)
    metrics["max_step"]    last logged step (None when empty)
    metrics["nan_tags"]    number of non-whitelisted tags with a NaN
    metrics["summary_ok"]  1 when the summary CSV matches the curve CSV
  """
  metrics = {
    "rows": 0,
    "tags": 0,
    "min_step": None,
    "max_step": None,
    "nan_tags": 0,
    "summary_ok": 0,
  }
  reasons = []

  rows = read_curve_csv(csv_path)
  if rows is None:
    if csv_path and os.path.isfile(csv_path):
      reasons.append("curve-csv-malformed")
    else:
      reasons.append("curve-csv-missing")
    return False, reasons, metrics

  metrics["rows"] = len(rows)
  coverage = curve_step_coverage(rows)
  metrics["min_step"] = coverage["min_step"]
  metrics["max_step"] = coverage["max_step"]

  tags = sorted(set(tag for (_step, tag, _value) in rows))
  metrics["tags"] = len(tags)
  if not rows:
    reasons.append("curve-empty")

  # The NaN verdict comes from nan_audit + DEFAULT_WHITELIST only.
  scalars = {}
  for _step, tag, value in rows:
    scalars.setdefault(tag, []).append(value)
  _ok, bad_tags, missing, violations = nan_audit(scalars, whitelist)
  metrics["nan_tags"] = len(bad_tags)
  if bad_tags:
    reasons.append("nan-nonwhitelist")
  if violations:
    reasons.append("nonfinite-steps")
  if missing:
    reasons.append("tag-missing")

  if expected_tags is not None and len(tags) != int(expected_tags):
    reasons.append("tag-count-mismatch")
  if expected_rows is not None and len(rows) != int(expected_rows):
    reasons.append("curve-row-count-mismatch")
  if expected_max_step is not None:
    if coverage["max_step"] != int(expected_max_step):
      reasons.append("curve-step-mismatch")
  if expected_min_step is not None:
    min_step = coverage["min_step"]
    if min_step is None or min_step > int(expected_min_step):
      reasons.append("curve-step-mismatch")

  if summary_path:
    parsed = read_curve_summary_csv(summary_path)
    if parsed is None or not _summary_equal(curve_summary_rows(rows), parsed):
      reasons.append("curve-summary-mismatch")
    else:
      metrics["summary_ok"] = 1

  if expected_events_files is not None:
    metrics["events_files"] = int(expected_events_files)

  return (not reasons), reasons, metrics


def _load_scalars_payload(path):
  """Load the extraction payload (JSON) produced by the tensorboard probe."""
  try:
    if path == "-":
      text = sys.stdin.read()
    else:
      with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    payload = json.loads(text)
  except (OSError, ValueError) as exc:
    return None, "extraction-failed: %s" % (exc,)
  if not isinstance(payload, dict):
    return None, "extraction-failed: the payload is not a JSON object"
  return payload, None


def _extraction_reason(error):
  """Map the error string of the probe onto the fixed reason set."""
  text = str(error or "")
  if "tensorboard-import-failed" in text or "no-torch-interpreter" in text:
    return "tb-unavailable"
  if "run-dir-missing" in text:
    return "run-dir-missing"
  if "events-missing" in text:
    return "events-missing"
  return "extraction-failed"


def _cmd_curves(args):
  """Extract the curves, write the artefacts and check them back."""
  payload, error = _load_scalars_payload(args.scalars_json)
  if error:
    print("REASON=extraction-failed")
    print("DETAIL=%s" % error)
    print("METRICS=")
    return 1

  probe_error = payload.get("error")
  if probe_error:
    reason = _extraction_reason(probe_error)
    print("REASON=%s" % reason)
    print("DETAIL=%s" % probe_error)
    print("METRICS=events_files=%s" % (payload.get("events_files") or 0))
    return 1

  scalars = payload.get("scalars") or {}
  rows = curve_rows_from_scalars(scalars)
  events_files = int(payload.get("events_files") or 0)
  if events_files <= 0:
    print("REASON=events-missing")
    print("DETAIL=no events file in the run directory")
    print("METRICS=")
    return 1

  csv_path = os.path.join(args.out_dir, "%s_curves.csv" % args.name)
  summary_path = os.path.join(args.out_dir, "%s_curves_summary.csv" % args.name)
  if rows:
    write_curve_csv(csv_path, rows)
    write_curve_summary_csv(summary_path, curve_summary_rows(rows))

  ok, reasons, metrics = check_curve_artifacts(
    csv_path,
    summary_path,
    expected_tags=args.expected_tags,
    expected_rows=args.expected_rows,
    expected_max_step=args.expected_max_step,
    expected_min_step=args.expected_min_step,
  )
  if events_files is not None and args.expected_events_files is not None \
          and events_files != int(args.expected_events_files):
    ok = False
    reasons = list(reasons) + ["events-count-mismatch"]

  metrics["events_files"] = events_files
  detail = "rows=%d tags=%d steps=%s..%s" % (
    metrics["rows"], metrics["tags"],
    metrics["min_step"], metrics["max_step"])
  print("REASON=%s" % ("-" if ok else reasons[0]))
  print("DETAIL=%s" % detail)
  print("METRICS=%s" % " ".join(
    "%s=%s" % (key, metrics.get(key)) for key in
    ("rows", "tags", "min_step", "max_step", "events_files", "nan_tags",
     "summary_ok")))
  print("CURVE_CSV=%s" % csv_path)
  print("SUMMARY_CSV=%s" % summary_path)
  return 0 if ok else 1


def _cmd_curves_verify(args):
  """Check the curve artefacts on disk (read-only)."""
  ok, reasons, metrics = check_curve_artifacts(
    args.csv,
    args.summary,
    expected_tags=args.expected_tags,
    expected_rows=args.expected_rows,
    expected_max_step=args.expected_max_step,
    expected_min_step=args.expected_min_step,
  )
  detail = "rows=%d tags=%d steps=%s..%s" % (
    metrics["rows"], metrics["tags"],
    metrics["min_step"], metrics["max_step"])
  print("REASON=%s" % ("-" if ok else reasons[0]))
  print("DETAIL=%s" % detail)
  print("METRICS=%s" % " ".join(
    "%s=%s" % (key, metrics.get(key)) for key in
    ("rows", "tags", "min_step", "max_step", "events_files", "nan_tags",
     "summary_ok")))
  print("CURVE_CSV=%s" % args.csv)
  print("SUMMARY_CSV=%s" % (args.summary or ""))
  return 0 if ok else 1


# --------------------------------------------------------------------------
# status files
# --------------------------------------------------------------------------


def _now_iso():
  return datetime.datetime.now(datetime.timezone.utc).strftime(
    "%Y-%m-%dT%H:%M:%SZ")


def write_status(path, state, rc, extra=None):
  """Atomically write a status file (write `path.tmp` then `os.replace`).

  The field order is fixed: STATE / RC / STARTED_AT / <extra keys> /
  FINISHED_AT.  `extra` is a dict of extra key -> value pairs; STARTED_AT and
  FINISHED_AT may be given through it.
  """
  extra = dict(extra or {})
  values = {"STATE": state, "RC": rc}
  values["STARTED_AT"] = extra.pop("STARTED_AT", None) or _now_iso()
  # FINISHED_AT is popped BEFORE the extra keys are copied: a caller-supplied
  # FINISHED_AT must not be written twice (once among the extra keys, once
  # in the tail).
  values["FINISHED_AT"] = extra.pop("FINISHED_AT", None) or _now_iso()
  for key in extra:
    values[key] = extra[key]

  lines = []
  for key in STATUS_FIELDS:
    lines.append("%s=%s" % (key, values.get(key, "")))
  for key in sorted(k for k in values if k not in STATUS_FIELDS):
    lines.append("%s=%s" % (key, values[key]))
  for key in STATUS_FIELDS_TAIL:
    lines.append("%s=%s" % (key, values.get(key, "")))

  directory = os.path.dirname(os.path.abspath(path))
  if directory:
    os.makedirs(directory, exist_ok=True)
  tmp = path + ".tmp"
  with open(tmp, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
  os.replace(tmp, path)


def read_status(path):
  """Read a status file into a dict; a missing file yields `{}`."""
  if not path or not os.path.isfile(path):
    return {}
  result = {}
  with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for raw in handle:
      line = raw.strip()
      if not line or line.startswith("#"):
        continue
      if "=" not in line:
        continue
      key, _, value = line.partition("=")
      result[key.strip()] = value.strip()
  return result


# --------------------------------------------------------------------------
# thin CLI
# --------------------------------------------------------------------------


def _cmd_log_summary(args):
  summary = parse_log_file(args.log_file)
  if summary is None:
    print("reason=log-missing")
    return 1
  print(json.dumps(summary, sort_keys=True))
  return 0


def _cmd_plan(args):
  iterations = plan_iterations(args.budget_seconds, args.it_per_s, args.factor)
  ckpt_every = plan_ckpt_every(iterations, args.min_ckpts)
  lr_decay = plan_lr_decay_iters(iterations)
  print("iterations=%d" % iterations)
  print("lr_decay_iters=%d" % lr_decay)
  print("ckpt_every=%d" % ckpt_every)
  print("ckpt_count=%d" % ckpt_count(iterations, ckpt_every))
  return 0 if iterations > 0 else 1


def _cmd_budget(args):
  limits = {}
  if args.gpu_max_mb is not None:
    limits["gpu_max_mb"] = args.gpu_max_mb
  if args.host_max_gb is not None:
    limits["host_max_gb"] = args.host_max_gb
  if args.wall_max_s is not None:
    limits["wall_max_s"] = args.wall_max_s
  ok, reasons = budget_ok(args.gpu_peak_mb, args.host_peak_gb, args.wall_s,
                          limits)
  print("budget_ok=%s" % ("true" if ok else "false"))
  for reason in reasons:
    print("reason=%s" % reason)
  return 0 if ok else 1


def build_parser():
  parser = argparse.ArgumentParser(
    prog="train.py",
    description="Decision base of the g1_amber training run (stdlib only).")
  sub = parser.add_subparsers(dest="command")

  log = sub.add_parser("log-summary", help="summarise a training log")
  log.add_argument("log_file")
  log.set_defaults(func=_cmd_log_summary)

  plan = sub.add_parser("plan", help="derive the training plan")
  plan.add_argument("--budget-seconds", type=float, required=True)
  plan.add_argument("--it-per-s", type=float, required=True)
  plan.add_argument("--factor", type=float, default=DEFAULT_FACTOR)
  plan.add_argument("--min-ckpts", type=int, default=DEFAULT_MIN_CKPTS)
  plan.set_defaults(func=_cmd_plan)

  budget = sub.add_parser("budget", help="check the resource budget")
  budget.add_argument("--gpu-peak-mb", type=float, required=True)
  budget.add_argument("--host-peak-gb", type=float, required=True)
  budget.add_argument("--wall-s", type=float, required=True)
  budget.add_argument("--gpu-max-mb", type=float, default=None)
  budget.add_argument("--host-max-gb", type=float, default=None)
  budget.add_argument("--wall-max-s", type=float, default=None)
  budget.set_defaults(func=_cmd_budget)

  def add_expectations(parser_):
    parser_.add_argument("--expected-tags", type=int, default=None)
    parser_.add_argument("--expected-rows", type=int, default=None)
    parser_.add_argument("--expected-max-step", type=int, default=None)
    parser_.add_argument("--expected-min-step", type=int, default=None)
    parser_.add_argument("--expected-events-files", type=int, default=None)

  curves = sub.add_parser(
    "curves", help="extract the training curves and write the CSV artefacts")
  curves.add_argument("--scalars-json", required=True,
                      help="the JSON payload of the tensorboard probe ('-' = stdin)")
  curves.add_argument("--out-dir", required=True)
  curves.add_argument("--name", default="g1_amber_1h")
  add_expectations(curves)
  curves.set_defaults(func=_cmd_curves)

  curves_verify = sub.add_parser(
    "curves-verify", help="check the curve CSV artefacts on disk")
  curves_verify.add_argument("--csv", required=True)
  curves_verify.add_argument("--summary", default=None)
  add_expectations(curves_verify)
  curves_verify.set_defaults(func=_cmd_curves_verify)

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
