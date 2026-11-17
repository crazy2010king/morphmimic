#!/usr/bin/env python3
"""repro/lib/seed_npz.py — pure decision functions for the G1 50 Hz npz
conversion (manifest statistics, error-rate gate, subset nesting, hours
consistency).

Standard library ONLY (csv / os / re / sys / collections): the python3 on the
PATH inside the ros_dev container is a conda 3.12 without numpy/pandas/pyyaml,
and the project .venv is not importable from every shell, so no third-party
import may be used here.  The functions below are pure: they only READ files,
they never write, never touch the network and never spawn a subprocess.

A thin command line interface is provided at the bottom of the file so that
the bash layer can reuse the exact same parsing instead of re-implementing it
in awk (the manifest is written by pandas, so a field may be quoted and a
naive `awk -F,` would mis-align the columns).

Upstream contracts this module encodes (see src/morphmimic/data/manifest.py):

  * manifest.csv columns:
      name, path, session, frames, seconds, name_reject, feas_reject,
      category, package
    `path` is relative to the npz root (the manifest's directory).
  * a subset yaml is {"root": <abs npz root>, "hours": h, "clips": [rel paths]}
    (upstream `build_subset` / `_write_subset`).
  * `filtered()` keeps a clip iff name_reject == "" AND feas_reject == "".

`rows` always means DATA rows (the CSV header is not a row).  Upstream
`convert_seed` writes exactly one row per converted clip, so for the real
dataset rows == 142220 while the file has 142221 physical lines.
"""

from __future__ import annotations

import csv
import os
import re
import sys
from collections import Counter

MANIFEST_COLUMNS = (
  "name",
  "path",
  "session",
  "frames",
  "seconds",
  "name_reject",
  "feas_reject",
  "category",
  "package",
)

#: A feasibility rejection caused by a hard error (not by a filter verdict).
ERROR_PREFIX = "error: "

#: Maximum accepted share of errored clips.
ERROR_RATE_LIMIT = 0.01

#: Canonical subset chain (upstream `SUBSET_HOURS`).
SUBSET_ORDER = ("tiny", "1h", "7h", "40h", "all")

#: Tolerance of the hours cross-check, in hours.
HOURS_TOLERANCE = 1e-6


# --------------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------------


def _read_manifest_rows(manifest_path):
  """Return the manifest rows as a list of dicts.

  Raises:
    ValueError: the file does not exist, has no header, or misses a column
      that the upstream contract guarantees.
  """
  if not os.path.isfile(manifest_path):
    raise ValueError("manifest not found: %s" % manifest_path)
  with open(manifest_path, "r", newline="", encoding="utf-8", errors="replace") as handle:
    reader = csv.DictReader(handle)
    fields = reader.fieldnames or []
    missing = [c for c in MANIFEST_COLUMNS if c not in fields]
    if missing:
      raise ValueError("manifest missing columns: %s" % ",".join(missing))
    rows = []
    for row in reader:
      rows.append({c: (row.get(c) or "") for c in MANIFEST_COLUMNS})
  return rows


def manifest_stats(manifest_path):
  """Summarise a conversion manifest.

  Returns a dict with:
    rows            number of data rows (header excluded)
    kept            clips with name_reject == "" AND feas_reject == ""
    errors          clips whose feas_reject starts with "error: "
    error_rate      errors / rows (0.0 when rows == 0)
    total_seconds   sum of `seconds` over all rows
    total_hours     total_seconds / 3600
    kept_seconds    sum of `seconds` over the kept clips
    kept_hours      kept_seconds / 3600
    name_rejects    {reason: count} of the non-empty name_reject values
    feas_rejects    {reason: count} of the non-empty feas_reject values
    named           rows with name_reject == "" (upstream "after name filter")
  """
  rows = _read_manifest_rows(manifest_path)

  total_rows = len(rows)
  kept = 0
  errors = 0
  named = 0
  total_seconds = 0.0
  kept_seconds = 0.0
  name_rejects = Counter()
  feas_rejects = Counter()

  for row in rows:
    name_reject = row["name_reject"]
    feas_reject = row["feas_reject"]
    if name_reject:
      name_rejects[name_reject] += 1
    else:
      named += 1
    if feas_reject:
      feas_rejects[feas_reject] += 1
    if feas_reject.startswith(ERROR_PREFIX):
      errors += 1
    try:
      seconds = float(row["seconds"] or 0.0)
    except ValueError:
      seconds = 0.0
    total_seconds += seconds
    if not name_reject and not feas_reject:
      kept += 1
      kept_seconds += seconds

  error_rate = (errors / total_rows) if total_rows else 0.0
  return {
    "rows": total_rows,
    "kept": kept,
    "errors": errors,
    "error_rate": error_rate,
    "total_seconds": total_seconds,
    "total_hours": total_seconds / 3600.0,
    "kept_seconds": kept_seconds,
    "kept_hours": kept_seconds / 3600.0,
    "named": named,
    "name_rejects": dict(name_rejects),
    "feas_rejects": dict(feas_rejects),
  }


def error_rate_ok(rows, errors, limit=ERROR_RATE_LIMIT):
  """True when `errors` / `rows` stays within `limit`.

  Boundary behaviour: exactly `limit` PASSES (the limit is inclusive), one
  error more FAILS.  The comparison is done on the counts
  (`errors <= limit * rows`) so that a rate of exactly 1% is not rejected by
  a binary rounding artefact.

  An empty manifest (`rows <= 0`) is NOT ok: "no data" must never pass a
  gate — fail closed.
  """
  if rows is None or errors is None:
    return False
  rows = int(rows)
  errors = int(errors)
  if rows <= 0:
    return False
  if errors < 0:
    return False
  return errors <= limit * rows + 1e-9


def sample_paths(manifest_path, n):
  """Return n evenly spaced `path` values of the manifest.

  The sampling is deterministic (no RNG): sample i of n picks the row at
  index round(i * (rows - 1) / (n - 1)), so the sample spans the WHOLE
  manifest instead of clustering in its head.  Rows with an empty `path` are
  skipped.  When the manifest holds fewer rows than requested, every row is
  returned.

  This is the canonical implementation; repro/lib/seed_npz.sh mirrors it and
  repro/tests/test_seed_npz.sh asserts the two agree.
  """
  rows = _read_manifest_rows(manifest_path)
  paths = [row["path"] for row in rows if row["path"]]
  if n is None:
    n = 0
  n = int(n)
  if n <= 0 or not paths:
    return []
  count = len(paths)
  take = n if n < count else count
  if take == 1:
    return [paths[0]]
  chosen = []
  for i in range(1, take + 1):
    index = int((i - 1) * (count - 1) / (take - 1) + 0.5)
    chosen.append(paths[index])
  return chosen


# --------------------------------------------------------------------------
# subset yamls
# --------------------------------------------------------------------------


def _parse_scalar(text):
  """Parse one YAML scalar (plain, single- or double-quoted)."""
  text = text.strip()
  if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
    body = text[1:-1]
    if text[0] == '"':
      body = body.replace('\\"', '"').replace("\\\\", "\\")
    else:
      body = body.replace("''", "'")
    return body
  return text


def _parse_flow_list(text):
  """Parse a YAML flow sequence: [a, b, 'c d']."""
  body = text.strip()[1:-1].strip()
  if not body:
    return []
  items = []
  current = ""
  quote = ""
  for char in body:
    if quote:
      current += char
      if char == quote:
        quote = ""
      continue
    if char in ("'", '"'):
      quote = char
      current += char
      continue
    if char == ",":
      items.append(current)
      current = ""
      continue
    current += char
  if current.strip():
    items.append(current)
  return [_parse_scalar(item) for item in items]


def parse_simple_yaml(text):
  """Parse the YAML subset that upstream `yaml.safe_dump` produces for a
  subset spec: top-level `key: value` scalars plus one block list.

  Supported (and only this):
    root: /abs/path
    hours: 1.234
    clips:
    - a.npz
    - 'b c.npz'
    clips: []            (flow style, empty or short)

  Raises:
    ValueError: a line is not parsable with this subset.
  """
  result = {}
  list_key = None
  for raw in text.splitlines():
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
      continue
    if stripped.startswith("- ") or stripped == "-":
      item = _parse_scalar(stripped[1:].strip()) if stripped != "-" else ""
      if list_key is None:
        raise ValueError("yaml list item outside of a list key: %r" % raw)
      result.setdefault(list_key, [])
      if not isinstance(result[list_key], list):
        raise ValueError("yaml key %r is not a list" % list_key)
      result[list_key].append(item)
      continue
    match = re.match(r"^([^:]+):\s*(.*)$", stripped)
    if not match:
      raise ValueError("unparsable yaml line: %r" % raw)
    key = match.group(1).strip()
    value = match.group(2).strip()
    if value == "":
      result[key] = []
      list_key = key
      continue
    list_key = None
    if value.startswith("[") and value.endswith("]"):
      result[key] = _parse_flow_list(value)
    else:
      result[key] = _parse_scalar(value)
  return result


def subset_spec(yaml_path):
  """Read a subset yaml written by upstream `build_subset`.

  Returns {"root": str, "hours": float, "clips": [str, ...]}.

  Raises:
    ValueError: the file is missing, unparsable, or misses a key.
  """
  if not os.path.isfile(yaml_path):
    raise ValueError("subset yaml not found: %s" % yaml_path)
  with open(yaml_path, "r", encoding="utf-8", errors="replace") as handle:
    raw = parse_simple_yaml(handle.read())
  for key in ("root", "hours", "clips"):
    if key not in raw:
      raise ValueError("subset yaml %s misses key %r" % (yaml_path, key))
  clips = raw["clips"]
  if not isinstance(clips, list):
    raise ValueError("subset yaml %s: clips is not a list" % yaml_path)
  try:
    hours = float(raw["hours"])
  except (TypeError, ValueError):
    raise ValueError("subset yaml %s: hours is not a number" % yaml_path)
  return {
    "root": str(raw["root"]),
    "hours": hours,
    "clips": [str(c) for c in clips],
    "path": str(yaml_path),
  }


def subsets_nested(specs, required=SUBSET_ORDER):
  """True when the subset chain is nested: tiny ⊆ 1h ⊆ 7h ⊆ 40h ⊆ all.

  `specs` maps a subset name onto a spec dict (as returned by
  `subset_spec`) or onto a plain list of clip paths.  `required` is the
  chain that must be present AND nested; it defaults to the full canonical
  chain and may be shortened for fixtures.  A missing subset makes the
  check fail (fail closed).
  """
  if not isinstance(specs, dict):
    return False
  if not required:
    return False
  unknown = [name for name in required if name not in SUBSET_ORDER]
  if unknown:
    raise ValueError("unknown subset names: %s" % ",".join(unknown))
  # the required chain must follow the canonical order
  positions = [SUBSET_ORDER.index(name) for name in required]
  if positions != sorted(positions):
    return False

  def clips_of(name):
    spec = specs.get(name)
    if spec is None:
      return None
    if isinstance(spec, dict):
      clips = spec.get("clips")
    else:
      clips = spec
    if not isinstance(clips, list):
      return None
    return set(str(c) for c in clips)

  previous = None
  for name in required:
    current = clips_of(name)
    if current is None:
      return False
    if previous is not None and not previous.issubset(current):
      return False
    previous = current
  return True


def subset_hours_consistent(spec, seconds_by_path):
  """True when the clips' summed duration matches the yaml `hours`.

  `spec` is a subset spec (as returned by `subset_spec`); `seconds_by_path`
  maps a clip path onto its duration in seconds.  Tolerance: 1e-6 h.

  A clip that is missing from `seconds_by_path` makes the check fail: a
  subset that cannot be re-costed is not consistent.
  """
  if not isinstance(spec, dict):
    return False
  clips = spec.get("clips")
  hours = spec.get("hours")
  if not isinstance(clips, list) or hours is None:
    return False
  try:
    hours = float(hours)
  except (TypeError, ValueError):
    return False
  total = 0.0
  for clip in clips:
    if clip not in seconds_by_path:
      return False
    try:
      total += float(seconds_by_path[clip])
    except (TypeError, ValueError):
      return False
  return abs(total / 3600.0 - hours) <= HOURS_TOLERANCE


def manifest_seconds_by_path(manifest_path):
  """Map every manifest row's `path` onto its `seconds`."""
  result = {}
  for row in _read_manifest_rows(manifest_path):
    try:
      seconds = float(row["seconds"] or 0.0)
    except ValueError:
      seconds = 0.0
    result[row["path"]] = seconds
  return result


# --------------------------------------------------------------------------
# command line interface
# --------------------------------------------------------------------------
#
# The CLI is a THIN shell over the functions above: it exists so that the
# bash layer (repro/lib/seed_npz.sh and the scripts of slice S04) can reuse
# the exact same parsing and sampling logic instead of re-implementing it in
# awk.  The manifest is written by pandas, so a field may be quoted; only the
# csv module parses that correctly.

_CLI_USAGE = """usage: seed_npz.py <command> [args]

commands:
  stats <manifest>                 manifest statistics as key=value lines
  sample-paths <manifest> <n>      print n evenly spaced manifest paths
  subset-spec <subset.yaml>        print the subset spec as key=value lines
  nested <name=subset.yaml> ...    check the subset chain is nested
"""


def _cli_stats(manifest_path):
  stats = manifest_stats(manifest_path)
  print("rows=%d" % stats["rows"])
  print("kept=%d" % stats["kept"])
  print("errors=%d" % stats["errors"])
  print("error_rate=%.10f" % stats["error_rate"])
  print("total_seconds=%.3f" % stats["total_seconds"])
  print("total_hours=%.6f" % stats["total_hours"])
  print("kept_seconds=%.3f" % stats["kept_seconds"])
  print("kept_hours=%.6f" % stats["kept_hours"])
  print("named=%d" % stats["named"])
  print("error_rate_ok=%d" % int(error_rate_ok(stats["rows"], stats["errors"])))
  for reason, count in sorted(stats["name_rejects"].items()):
    print("name_reject=%s x%d" % (reason, count))
  for reason, count in sorted(stats["feas_rejects"].items()):
    print("feas_reject=%s x%d" % (reason, count))


def _cli_nested(entries):
  """`nested name=subset.yaml ...` -> prints `nested=1` and exits 0 when the
  chain is nested, prints `nested=0` and exits 1 otherwise.

  The names are sorted into the canonical chain order (tiny -> 1h -> 7h ->
  40h -> all) so that the caller does not have to pass them in order.
  """
  specs = {}
  names = []
  for entry in entries:
    if "=" not in entry:
      raise ValueError("expected name=path, got %r" % entry)
    name, path = entry.split("=", 1)
    specs[name] = subset_spec(path)
    names.append(name)
  unknown = [name for name in names if name not in SUBSET_ORDER]
  if unknown:
    raise ValueError("unknown subset names: %s" % ",".join(unknown))
  names.sort(key=SUBSET_ORDER.index)
  ok = subsets_nested(specs, required=tuple(names))
  print("nested=%d" % int(ok))
  return 0 if ok else 1


def main(argv=None):
  """Entry point of the CLI. Returns the process exit code."""
  argv = list(sys.argv[1:] if argv is None else argv)
  if not argv:
    sys.stderr.write(_CLI_USAGE)
    return 2
  command = argv[0]
  try:
    if command == "stats" and len(argv) == 2:
      _cli_stats(argv[1])
      return 0
    if command == "sample-paths" and len(argv) == 3:
      for path in sample_paths(argv[1], int(argv[2])):
        print(path)
      return 0
    if command == "subset-spec" and len(argv) == 2:
      spec = subset_spec(argv[1])
      print("root=%s" % spec["root"])
      print("hours=%.10f" % spec["hours"])
      print("clips=%d" % len(spec["clips"]))
      return 0
    if command == "nested" and len(argv) >= 2:
      return _cli_nested(argv[1:])
  except ValueError as error:
    sys.stderr.write("seed_npz: %s\n" % error)
    return 1
  sys.stderr.write(_CLI_USAGE)
  return 2


if __name__ == "__main__":
  sys.exit(main())
