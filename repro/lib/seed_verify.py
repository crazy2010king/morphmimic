#!/usr/bin/env python3
"""repro/lib/seed_verify.py — reconcile the BONES-SEED metadata against the
extracted clip trees.

Stdlib only (csv / os / argparse / sys): the python3 on the PATH inside the
ros_dev container is a conda 3.12 without huggingface_hub and the project
.venv does not have it either, so no third-party import may be used here.

Inputs
  --metadata <csv>   seed_metadata_v004.csv (columns: filename,
                     move_g1_path, move_soma_uniform_path)
  --g1-csv <dir>     extracted G1 CSV tree (data/seed/g1/csv)
  --soma-bvh <dir>   extracted BVH tree (data/seed/soma_uniform/bvh)
  --sessions <dir>   optional root that must contain every session directory
  --mode files|clips reconciliation unit (default: files)
                     files  every extracted FILE is matched against the
                            metadata (matched = #files present in both trees)
                     clips  every metadata ROW is a clip: a clip counts as
                            matched only when BOTH its CSV and its BVH are on
                            disk (matched = #clips, i.e. 142220 for the real
                            dataset). "extra" stays a FILE counter.

The metadata rule (measured on all 142,220 rows): basename(move_g1_path) ==
filename + ".csv" and basename(move_soma_uniform_path) == filename + ".bvh".

Exit code 0 == every check passed.
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

REQUIRED_COLUMNS = ("filename", "move_g1_path", "move_soma_uniform_path")


def fail(message):
    """Print a failure marker and leave with a non-zero exit code."""
    sys.stdout.write("SEED_META_FAIL %s\n" % message)
    sys.exit(2)


def read_metadata(path):
    """Return a list of (filename, g1_path, soma_path) triples."""
    if not os.path.isfile(path):
        fail("metadata not found: %s" % path)
    rows = []
    with open(path, "r", newline="", encoding="utf-8-sig", errors="replace") as handle:
        reader = csv.DictReader(handle)
        fields = reader.fieldnames or []
        missing = [c for c in REQUIRED_COLUMNS if c not in fields]
        if missing:
            fail("metadata missing columns: %s" % ",".join(missing))
        for row in reader:
            filename = (row.get("filename") or "").strip()
            g1 = (row.get("move_g1_path") or "").strip()
            soma = (row.get("move_soma_uniform_path") or "").strip()
            rows.append((filename, g1, soma))
    return rows


def expected_clips(rows):
    """Return (clips, broken) for the clip-level reconciliation.

    clips maps a metadata `filename` (the clip id) onto
    (session_g1, base_g1, session_soma, base_soma).  `broken` counts the
    rows that violate the basename rule (basename(path) == filename+suffix).
    """
    clips = {}
    broken = 0
    for row in rows:
        filename, g1, soma = row
        if not filename or not g1 or not soma:
            broken += 1
            continue
        base_g1 = os.path.basename(g1)
        base_soma = os.path.basename(soma)
        if base_g1 != filename + ".csv" or base_soma != filename + ".bvh":
            broken += 1
            continue
        session_g1 = os.path.basename(os.path.dirname(g1))
        session_soma = os.path.basename(os.path.dirname(soma))
        if not session_g1 or not session_soma:
            broken += 1
            continue
        clips[filename] = (session_g1, base_g1, session_soma, base_soma)
    return clips, broken


def expected_pairs(rows, path_index, suffix):
    """Map (session, basename) -> expected, and count basename rule breaks."""
    expected = {}
    broken = 0
    for row in rows:
        filename, g1, soma = row
        path = (g1, soma)[path_index]
        if not filename or not path:
            broken += 1
            continue
        base = os.path.basename(path)
        if base != filename + suffix:
            broken += 1
            continue
        session = os.path.basename(os.path.dirname(path))
        if not session:
            broken += 1
            continue
        expected[(session, base)] = True
    return expected, broken


def scan_tree(root, suffix):
    """Return ({(session, basename)}, {session: count}, zero_byte_count)."""
    files = {}
    per_session = defaultdict(int)
    zero_byte = 0
    if not os.path.isdir(root):
        return files, per_session, zero_byte
    for dirpath, _dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        session = "" if rel_dir == "." else rel_dir.replace(os.sep, "/")
        for name in filenames:
            if not name.endswith(suffix):
                continue
            full = os.path.join(dirpath, name)
            files[(session, name)] = True
            per_session[session] += 1
            try:
                if os.path.getsize(full) == 0:
                    zero_byte += 1
            except OSError:
                zero_byte += 1
    return files, per_session, zero_byte


def check_samples(root, suffix, kind, per_session):
    """Sample one file per session and validate its first line."""
    problems = []
    checked = 0
    for session in sorted(per_session):
        candidates = []
        session_dir = os.path.join(root, session)
        if not os.path.isdir(session_dir):
            problems.append("%s session directory missing: %s" % (kind, session))
            continue
        for name in sorted(os.listdir(session_dir)):
            if name.endswith(suffix):
                candidates.append(os.path.join(session_dir, name))
        if not candidates:
            problems.append("%s no %s file in session %s" % (kind, suffix, session))
            continue
        path = candidates[0]
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                first = handle.readline().rstrip("\n")
        except OSError as exc:
            problems.append("%s unreadable %s: %s" % (kind, path, exc))
            continue
        if kind == "csv":
            columns = first.count(",") + 1
            if "," not in first or columns <= 10:
                problems.append("csv first line malformed (%d columns): %s" % (columns, path))
                continue
        else:
            if not first.startswith("HIERARCHY"):
                problems.append("bvh first line is not HIERARCHY: %s" % path)
                continue
        checked += 1
        sys.stdout.write(
            "SEED_META_SAMPLE kind=%s session=%s file=%s ok=1\n" % (kind, session, os.path.basename(path))
        )
    return checked, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description="BONES-SEED metadata reconciliation")
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--g1-csv", required=True)
    parser.add_argument("--soma-bvh", required=True)
    parser.add_argument("--sessions", default=None)
    parser.add_argument("--mode", choices=("files", "clips"), default="files")
    args = parser.parse_args(argv)

    rows = read_metadata(args.metadata)
    exp_g1, broken_g1 = expected_pairs(rows, 0, ".csv")
    exp_soma, broken_soma = expected_pairs(rows, 1, ".bvh")

    act_g1, per_g1, zero_g1 = scan_tree(args.g1_csv, ".csv")
    act_soma, per_soma, zero_soma = scan_tree(args.soma_bvh, ".bvh")

    missing_g1 = set(exp_g1) - set(act_g1)
    extra_g1 = set(act_g1) - set(exp_g1)
    missing_soma = set(exp_soma) - set(act_soma)
    extra_soma = set(act_soma) - set(exp_soma)

    zero_byte = zero_g1 + zero_soma

    exp_per_session_soma = defaultdict(int)

    if args.mode == "clips":
        clips, broken = expected_clips(rows)
        broken_g1 = broken
        broken_soma = 0
        exp_g1_set = set((s, b) for s, b, _ss, _sb in clips.values())
        exp_soma_set = set((s, b) for _s, _bg, s, b in clips.values())
        extra_g1 = set(act_g1) - exp_g1_set
        extra_soma = set(act_soma) - exp_soma_set
        extra = len(extra_g1) + len(extra_soma)

        matched = 0
        missing = 0
        exp_per_session = defaultdict(int)
        act_per_session = defaultdict(int)
        # the session directories live under the g1 tree
        exp_per_session_soma = defaultdict(int)
        for _filename, (s_g1, b_g1, s_soma, b_soma) in clips.items():
            exp_per_session[s_g1] += 1
            if (s_g1, b_g1) in act_g1 and (s_soma, b_soma) in act_soma:
                matched += 1
                act_per_session[s_g1] += 1
            else:
                missing += 1
        sessions = set(exp_per_session) | set(act_per_session)
        session_mismatch = 0
    else:
        matched = (len(exp_g1) - len(missing_g1)) + (len(exp_soma) - len(missing_soma))
        missing = len(missing_g1) + len(missing_soma)
        extra = len(extra_g1) + len(extra_soma)

        # per session counters
        exp_per_session = defaultdict(int)
        for session, _name in exp_g1:
            exp_per_session[session] += 1
        for session, _name in exp_soma:
            exp_per_session_soma[session] += 1
        sessions = set(exp_per_session) | set(exp_per_session_soma) | set(per_g1) | set(per_soma)
        session_mismatch = 0

    sys.stdout.write(
        "SEED_META_MATCH matched=%d missing=%d extra=%d\n" % (matched, missing, extra)
    )
    sys.stdout.write("SEED_EXTRACT_ZERO_BYTE count=%d\n" % zero_byte)

    for session in sorted(sessions):
        if args.mode == "clips":
            expected = exp_per_session[session]
            actual = act_per_session[session]
        else:
            expected = max(exp_per_session[session], exp_per_session_soma[session])
            actual = max(per_g1.get(session, 0), per_soma.get(session, 0))
        sys.stdout.write(
            "SEED_META_SESSION session=%s expected=%d actual=%d\n" % (session, expected, actual)
        )
        if expected != actual:
            session_mismatch += 1

    # session directories must exist under --sessions when given
    missing_session_dirs = 0
    if args.sessions:
        for session in sorted(set(exp_per_session) | set(exp_per_session_soma)):
            if not os.path.isdir(os.path.join(args.sessions, session)):
                missing_session_dirs += 1
                sys.stdout.write("SEED_META_SESSION_DIR_MISSING session=%s\n" % session)

    checked_csv, problems_csv = check_samples(args.g1_csv, ".csv", "csv", per_g1)
    checked_bvh, problems_bvh = check_samples(args.soma_bvh, ".bvh", "bvh", per_soma)

    for problem in problems_csv + problems_bvh:
        sys.stdout.write("SEED_META_SAMPLE_FAIL %s\n" % problem)

    ok = True
    if broken_g1 or broken_soma:
        sys.stdout.write(
            "SEED_META_BASENAME_MISMATCH g1=%d soma=%d\n" % (broken_g1, broken_soma)
        )
        ok = False
    if missing:
        ok = False
    if extra:
        ok = False
    if zero_byte:
        ok = False
    if session_mismatch:
        sys.stdout.write("SEED_META_SESSION_MISMATCH sessions=%d\n" % session_mismatch)
        ok = False
    if missing_session_dirs:
        ok = False
    if problems_csv or problems_bvh:
        ok = False

    if not ok:
        sys.stdout.write(
            "SEED_META_FAIL matched=%d missing=%d extra=%d zero_byte=%d\n"
            % (matched, missing, extra, zero_byte)
        )
        return 1

    sys.stdout.write(
        "SEED_META_OK matched=%d missing=%d extra=%d samples=%d\n"
        % (matched, missing, extra, checked_csv + checked_bvh)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
