#!/usr/bin/env bash
# repro/27_train_curves.sh — the TRAINING CURVE EXTRACTOR of the g1_amber
# run (slice S09, task T1).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The milestone requirement R016 asks the reproduction record to carry the
# "training curve data" of the run.  On disk there was only the AUDIT
# conclusion of S06 (logs/env/18_train_report.txt: 52 tags / 0 non-whitelisted
# NaN / 9 ckpt / 26,413 iterations / 1.1112 it/s) -- no data a document
# could cite and no artefact a verifier could recompute.  A prose sentence
# is not a curve: the numbers of a curve must be re-derivable.
#
# So this script turns the tensorboard events of the formal run into TWO
# machine-checkable CSV artefacts:
#
#   runs/train_curves/g1_amber_1h_curves.csv          step,tag,value
#   runs/train_curves/g1_amber_1h_curves_summary.csv  tag,n,first,last,min,max,mean
#
# (plus a PNG overview when matplotlib is available -- a convenience, never a
# gate).
#
# ---------------------------------------------------------------------------
# THE TWO TRAPS
#
#   (a) ONE EVENTS FILE PER PROCESS START.  The formal run was restarted
#       nine times (the resume chain of S06), therefore the run directory
#       holds TEN events files.  Reading a single file under-reports the
#       curve and can hide a NaN of a later segment.  The extraction
#       therefore aggregates the WHOLE run directory with
#       `EventAccumulator(run_dir, size_guidance={"scalars": 0})`.
#
#   (b) THE NaN WHITELIST.  Under `--kp-student copy` the tags `kp/return`
#       and `kp/scale_return` are NaN BY DESIGN (upstream trainer.py:1935).
#       The verdict therefore comes from `train.nan_audit` with
#       `train.DEFAULT_WHITELIST` -- the ONE NaN source of truth of the
#       project (S06).  This script never re-implements a NaN rule.
#
# The DECISIONS live in repro/lib/train.py (stdlib only); this script only
# picks the interpreter, drives the tensorboard probe and formats the
# markers.  The probe needs tensorboard, which exists only in the project
# venv of the ros_dev container -- the system python3 of the container has
# no numpy and no tensorboard.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the environment facts (interpreter, run directory, events
#            files, output directory).  Success prints ONE line
#                TRAIN_CURVES_ENV_OK events_files=<n>
#   run      the extraction: aggregate the run directory, write the two CSV
#            artefacts (atomically), read them back and re-derive every
#            fact.  Success prints ONE line
#                TRAIN_CURVES_OK events_files=<n> tags=<n> rows=<n> \
#                          steps=<n> csv=<path relative to the repo root>
#            failure prints ONE line
#                TRAIN_CURVES_FAIL reason=<fixed reason set>
#            and exits non-zero.  A failing run NEVER prints an OK marker
#            (project convention P004: the OK marker is buffered and flushed
#            only when EVERY check passed).
#   verify   the READ-ONLY terminal gate: it re-derives the facts from the
#            CSV artefacts on disk (never from the extraction log) and
#            counts the events files of the run directory itself.  If the
#            artefacts do not exist yet, they are produced first (the
#            extraction is idempotent and atomic).  Same markers as `run`.
#   report   the numbers of the artefacts in the `TRAIN_CURVES_REPORT_*`
#            form (for the documentation back-fill of S09/T3).
#   selftest the offline battery: repro/tests/test_train_curves.py (no
#            container, no tensorboard, no run directory).
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SET (greppable)
#
#   run-dir-missing        the run directory does not exist
#   events-missing         no events file in the run directory
#   events-count-mismatch  the number of events files is not the expected one
#   tb-unavailable         no interpreter with tensorboard
#   extraction-failed      the probe or the payload could not be read
#   nan-nonwhitelist       a tag outside the whitelist carries a NaN/Inf
#   nonfinite-steps        a `*/nonfinite_steps` counter is > 0
#   tag-missing            a required tag is absent from the curve
#   tag-count-mismatch     the number of tags is not the expected one
#   curve-empty            the curve carries no row
#   curve-step-mismatch    the step coverage is not the expected one
#   curve-row-count-mismatch the number of rows is not the expected one
#   curve-csv-missing      the curve CSV does not exist
#   curve-csv-malformed    the curve CSV does not carry the expected header
#   curve-summary-mismatch the summary CSV does not match the curve CSV
#   analysis-failed        the decision base produced no result at all
#
# The set is the one of `train.CURVE_REASONS`.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without
# tensorboard and without the real run)
#
#   CURVES_ALLOW_LOCAL=1   allow running outside the ros_dev container
#   CURVES_RUN_DIR         the run directory (default logs/train/g1_amber_1h)
#   CURVES_OUT_DIR         the output directory (default runs/train_curves)
#   CURVES_NAME            the artefact name prefix (default g1_amber_1h)
#   CURVES_TORCH_PY        the interpreter with tensorboard (default: the
#                          project venv, else `uv run --frozen --no-sync
#                          python`)
#   CURVES_PY              the decision-base interpreter (default python3)
#   CURVES_TB_CMD          override the whole tensorboard probe command
#   CURVES_EXPECTED_EVENTS_FILES  expected number of events files (default 10)
#   CURVES_EXPECTED_TAGS          expected number of tags (default 52)
#   CURVES_EXPECTED_MAX_STEP      expected last step (default 26413)
#   CURVES_EXPECTED_MIN_STEP      expected first logged step (default 50)
#   CURVES_NO_PLOT=1       never draw the PNG overview
#
# NOTE on the step coverage: the upstream trainer logs every 50 iterations,
# therefore the first logged point of the run is iteration 50 and not 0.
# The coverage contract is "the CSV spans the whole run": the last step
# must be the last iteration of the run (26,413) and the first logged step
# must not be later than the first logging interval (50).  Iteration 0 was
# never logged by the trainer -- no data is missing, the trainer simply does
# not write a point for it.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/train.sh
source "$_SCRIPT_DIR/lib/train.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 16_seed_human_verify.sh convention).
set +e

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${CURVES_LOG_DIR:-$LOG_DIR}"
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/27_train_curves.txt"
RUN_DIR="${CURVES_RUN_DIR:-$REPO_ROOT/logs/train/g1_amber_1h}"
RUN_DIR="$(readlink -f "$RUN_DIR" 2>/dev/null || printf '%s' "$RUN_DIR")"
OUT_DIR="${CURVES_OUT_DIR:-$REPO_ROOT/runs/train_curves}"
NAME="${CURVES_NAME:-g1_amber_1h}"
CURVE_CSV="$OUT_DIR/${NAME}_curves.csv"
SUMMARY_CSV="$OUT_DIR/${NAME}_curves_summary.csv"
PNG_FILE="$OUT_DIR/${NAME}_curves.png"
EXPECTED_EVENTS="${CURVES_EXPECTED_EVENTS_FILES:-10}"
EXPECTED_TAGS="${CURVES_EXPECTED_TAGS:-52}"
EXPECTED_MAX_STEP="${CURVES_EXPECTED_MAX_STEP:-26413}"
EXPECTED_MIN_STEP="${CURVES_EXPECTED_MIN_STEP:-50}"
CURVES_PY_BIN="${CURVES_PY:-python3}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/27_train_curves.sh <env|run|verify|report|selftest>

  env       the environment facts (TRAIN_CURVES_ENV_OK / ..._FAIL)
  run       extract the curves and write the CSV artefacts
  verify    the read-only terminal gate (re-derives from the artefacts)
  report    the numbers of the artefacts (TRAIN_CURVES_REPORT_*)
  selftest  the offline unit battery

run dir: $RUN_DIR
out dir: $OUT_DIR
log:     $MAIN_LOG
EOF
}

# --- output -----------------------------------------------------------------
# Every marker is written to stdout AND appended to the log file, so the log
# file is greppable after the fact.
elog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed ONLY when every check passed.
OK_MARKERS=()
elog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do elog "$m"; done
  OK_MARKERS=()
}

# rel_path <absolute path> — the path relative to the repository root (the
# marker must stay stable between the host and the container).
rel_path() {
  local path="$1"
  case "$path" in
    "$REPO_ROOT"/*) printf '%s' "${path#"$REPO_ROOT"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

# metric <metrics> <key> — the value of one metric of the METRICS= line.
metric() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1
}

# ---------------------------------------------------------------------------
# the tensorboard probe (the only part that needs tensorboard)
# ---------------------------------------------------------------------------

# curves_torch_cmd — the interpreter words used for tensorboard.
curves_torch_cmd() {
  local spec="${CURVES_TORCH_PY:-}"
  if [ -z "$spec" ]; then
    if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
      spec="$REPO_ROOT/.venv/bin/python"
    elif command -v uv >/dev/null 2>&1; then
      spec="uv run --frozen --no-sync python"
    else
      spec=""
    fi
  fi
  printf '%s' "$spec"
}

# TB_PY_CODE — the aggregation.  It walks the WHOLE run directory:
# EventAccumulator takes a directory and loads every events file inside it,
# which is exactly what the "one events file per process start" trap
# requires.  The non-finite values are encoded as strings ("nan" / "inf" /
# "-inf") so that the payload stays strict JSON.
read -r -d '' TB_PY_CODE <<'PYEOF' || true
import json, math, os, sys

run_dir = sys.argv[1] if len(sys.argv) > 1 else ""
png_path = sys.argv[2] if len(sys.argv) > 2 else ""

out = {"error": None, "events_files": 0, "scalars": {}}

try:
    from tensorboard.backend.event_processing import event_accumulator as ea
except Exception as exc:
    out["error"] = "tensorboard-import-failed: %s" % (exc,)
    print(json.dumps(out))
    raise SystemExit(0)

if not run_dir or not os.path.isdir(run_dir):
    out["error"] = "run-dir-missing: %s" % (run_dir,)
    print(json.dumps(out))
    raise SystemExit(0)

try:
    out["events_files"] = len(
        [n for n in os.listdir(run_dir) if n.startswith("events.out.tfevents")])
except OSError:
    out["events_files"] = 0

if out["events_files"] <= 0:
    out["error"] = "events-missing: %s" % (run_dir,)
    print(json.dumps(out))
    raise SystemExit(0)

try:
    acc = ea.EventAccumulator(run_dir, size_guidance={"scalars": 0})
    acc.Reload()
    for tag in list(acc.Tags().get("scalars", [])):
        values = []
        for event in acc.Scalars(tag):
            value = float(event.value)
            if math.isnan(value):
                values.append([int(event.step), "nan"])
            elif math.isinf(value):
                values.append([int(event.step), "inf" if value > 0 else "-inf"])
            else:
                values.append([int(event.step), value])
        out["scalars"][tag] = values
except Exception as exc:
    out["error"] = "accumulator-failed: %s" % (exc,)

# The PNG overview is a convenience, never a gate: a missing matplotlib is
# NOT a failure of the extraction.  Its state travels inside the payload,
# so that stdout stays pure JSON.
if png_path and out["error"] is None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        plot_tags = ["wm/state_loss", "policy/objective", "critic/loss",
                     "collect/mean_norm_return", "perf/it_per_s"]
        figure, axes = plt.subplots(len(plot_tags), 1, figsize=(9, 12))
        for axis, tag in zip(axes, plot_tags):
            points = [(step, value) for step, value
                      in out["scalars"].get(tag, []) if isinstance(value, float)]
            if points:
                axis.plot([p[0] for p in points], [p[1] for p in points],
                          linewidth=0.8)
            axis.set_title(tag, fontsize=8)
            axis.grid(True, linewidth=0.3, alpha=0.5)
        figure.tight_layout()
        figure.savefig(png_path, dpi=110)
        plt.close(figure)
        out["png"] = png_path
    except Exception as exc:
        out["png"] = "skipped:matplotlib-unavailable (%s)" % (exc,)

print(json.dumps(out))
PYEOF

# tb_probe <run_dir> [png_path] — the aggregated payload (JSON on stdout).
tb_probe() {
  local run_dir="$1" png_path="${2:-}"
  if [ -n "${CURVES_TB_CMD:-}" ]; then
    eval "$CURVES_TB_CMD \"$run_dir\"" 2>/dev/null
    return $?
  fi
  local spec
  spec="$(curves_torch_cmd)"
  if [ -z "$spec" ]; then
    printf '{"error": "no-torch-interpreter", "events_files": 0, "scalars": {}}\n'
    return 0
  fi
  local -a cmd
  read -r -a cmd <<<"$spec"
  "${cmd[@]}" -c "$TB_PY_CODE" "$run_dir" "$png_path" 2>/dev/null
  return $?
}

# count_events_files <run_dir> — the number of events files (read-only).
count_events_files() {
  local run_dir="$1"
  if [ ! -d "$run_dir" ]; then
    printf '0'
    return 0
  fi
  find "$run_dir" -maxdepth 1 -type f -name 'events.out.tfevents*' 2>/dev/null \
    | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# the extraction (shared by `run` and `verify`)
# ---------------------------------------------------------------------------
# curves_extract — aggregates the run directory and writes the artefacts.
# It prints the decision lines of the decision base on stdout and returns
# 0 when every check passed:
#   line 1: "REASON=<reason|->"
#   line 2: "DETAIL=<detail>"
#   line 3: "METRICS=<k=v ...>"
#   line 4: "CURVE_CSV=<path>"
#   line 5: "SUMMARY_CSV=<path>"
# It NEVER prints an OK marker (the caller owns the marker).
curves_extract() {
  local payload
  payload="$(mktemp)"
  mkdir -p "$OUT_DIR" 2>/dev/null || true
  local probe png_arg=""
  if [ "${CURVES_NO_PLOT:-0}" != "1" ]; then
    png_arg="$PNG_FILE"
  fi
  probe="$(tb_probe "$RUN_DIR" "$png_arg")"
  printf '%s\n' "$probe" >"$payload"

  if [ -z "$probe" ]; then
    printf 'REASON=extraction-failed\n'
    printf 'DETAIL=the tensorboard probe produced no output\n'
    printf 'METRICS=\n'
    rm -f "$payload"
    return 1
  fi

  mkdir -p "$OUT_DIR" 2>/dev/null || true

  local out
  out="$("$CURVES_PY_BIN" "$REPO_ROOT/repro/lib/train.py" curves \
    --scalars-json "$payload" \
    --out-dir "$OUT_DIR" \
    --name "$NAME" \
    --expected-tags "$EXPECTED_TAGS" \
    --expected-max-step "$EXPECTED_MAX_STEP" \
    --expected-min-step "$EXPECTED_MIN_STEP" \
    --expected-events-files "$EXPECTED_EVENTS" 2>/dev/null)"
  rm -f "$payload"

  # The decision base exits non-zero on a NEGATIVE verdict -- that is a
  # verdict, not a crash.  Only a missing REASON= line means that the
  # decision base produced no result at all.
  if ! printf '%s\n' "$out" | grep -q '^REASON='; then
    printf 'REASON=analysis-failed\n'
    printf 'DETAIL=the decision base produced no result\n'
    printf 'METRICS=\n'
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}

# ---------------------------------------------------------------------------
# cmd_env
# ---------------------------------------------------------------------------
cmd_env() {
  elog "=== 27_train_curves.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  if [ "${CURVES_ALLOW_LOCAL:-0}" != "1" ] && ! in_container; then
    elog "TRAIN_CURVES_ENV_FAIL reason=run-dir-missing"
    elog "  the extraction must run inside the ros_dev container"
    return 1
  fi
  if [ ! -d "$RUN_DIR" ]; then
    elog "TRAIN_CURVES_ENV_FAIL reason=run-dir-missing"
    elog "  $RUN_DIR does not exist"
    return 1
  fi

  local events spec
  events="$(count_events_files "$RUN_DIR")"
  spec="$(curves_torch_cmd)"

  elog "run dir:   $RUN_DIR"
  elog "out dir:   $OUT_DIR"
  elog "events:    $events"
  elog "torch py:  ${spec:-<none>}"
  elog "decision:  $(command -v "$CURVES_PY_BIN" || printf '%s' "$CURVES_PY_BIN")"

  if [ "$events" -le 0 ]; then
    elog "TRAIN_CURVES_ENV_FAIL reason=events-missing"
    return 1
  fi
  if [ -z "$spec" ] && [ -z "${CURVES_TB_CMD:-}" ]; then
    elog "TRAIN_CURVES_ENV_FAIL reason=tb-unavailable"
    return 1
  fi

  elog_ok "TRAIN_CURVES_ENV_OK events_files=$events"
  flush_ok_markers
  return 0
}

# ---------------------------------------------------------------------------
# cmd_run
# ---------------------------------------------------------------------------
cmd_run() {
  elog "=== 27_train_curves.sh run $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  if [ "${CURVES_ALLOW_LOCAL:-0}" != "1" ] && ! in_container; then
    elog "  the extraction must run inside the ros_dev container"
    elog "TRAIN_CURVES_FAIL reason=run-dir-missing"
    return 1
  fi
  if [ ! -d "$RUN_DIR" ]; then
    elog "  the run directory $RUN_DIR does not exist"
    elog "TRAIN_CURVES_FAIL reason=run-dir-missing"
    return 1
  fi

  local events
  events="$(count_events_files "$RUN_DIR")"
  if [ "$events" -le 0 ]; then
    elog "  no events file in $RUN_DIR"
    elog "TRAIN_CURVES_FAIL reason=events-missing"
    return 1
  fi
  if [ "$events" != "$EXPECTED_EVENTS" ]; then
    elog "  events files=$events != expected $EXPECTED_EVENTS"
    elog "TRAIN_CURVES_FAIL reason=events-count-mismatch"
    return 1
  fi

  local out reason detail metrics
  out="$(curves_extract)"
  reason="$(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -n1)"
  detail="$(printf '%s\n' "$out" | sed -n 's/^DETAIL=//p' | head -n1)"
  metrics="$(printf '%s\n' "$out" | sed -n 's/^METRICS=//p' | head -n1)"

  if [ -z "$reason" ]; then
    elog "  the decision base produced no reason (reason=analysis-failed)"
    elog "TRAIN_CURVES_FAIL reason=analysis-failed"
    return 1
  fi
  if [ "$reason" != "-" ]; then
    if [ -n "$detail" ] && [ "$detail" != "-" ]; then
      elog "  $detail"
    fi
    elog "TRAIN_CURVES_FAIL reason=$reason"
    return 1
  fi

  local events rows tags steps
  events="$(count_events_files "$RUN_DIR")"
  rows="$(metric "$metrics" rows)"
  tags="$(metric "$metrics" tags)"
  steps="$(metric "$metrics" max_step)"
  if [ -n "$detail" ] && [ "$detail" != "-" ]; then
    elog "  $detail"
  fi
  elog_ok "TRAIN_CURVES_OK events_files=$events tags=$tags rows=$rows steps=$steps csv=$(rel_path "$CURVE_CSV")"
  flush_ok_markers
  return 0
}

# ---------------------------------------------------------------------------
# cmd_verify
# ---------------------------------------------------------------------------
cmd_verify() {
  elog "=== 27_train_curves.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  if [ "${CURVES_ALLOW_LOCAL:-0}" != "1" ] && ! in_container; then
    elog "  the verification must run inside the ros_dev container"
    elog "TRAIN_CURVES_FAIL reason=run-dir-missing"
    return 1
  fi
  if [ ! -d "$RUN_DIR" ]; then
    elog "  the run directory $RUN_DIR does not exist"
    elog "TRAIN_CURVES_FAIL reason=run-dir-missing"
    return 1
  fi

  local events
  events="$(count_events_files "$RUN_DIR")"
  if [ "$events" -le 0 ]; then
    elog "  no events file in $RUN_DIR"
    elog "TRAIN_CURVES_FAIL reason=events-missing"
    return 1
  fi
  if [ "$events" != "$EXPECTED_EVENTS" ]; then
    elog "  events files=$events != expected $EXPECTED_EVENTS"
    elog "TRAIN_CURVES_FAIL reason=events-count-mismatch"
    return 1
  fi

  # The artefacts must exist; when they do not, they are produced first
  # (the extraction is idempotent and atomic).
  if [ ! -f "$CURVE_CSV" ] || [ ! -f "$SUMMARY_CSV" ]; then
    elog "  the curve artefacts are missing -- extracting them first"
    local extract_out extract_reason
    extract_out="$(curves_extract)"
    extract_reason="$(printf '%s\n' "$extract_out" | sed -n 's/^REASON=//p' | head -n1)"
    if [ -z "$extract_reason" ]; then
      elog "  the extraction produced no reason (reason=analysis-failed)"
      elog "TRAIN_CURVES_FAIL reason=analysis-failed"
      return 1
    fi
    if [ "$extract_reason" != "-" ]; then
      elog "  the extraction failed (reason=$extract_reason)"
      elog "TRAIN_CURVES_FAIL reason=$extract_reason"
      return 1
    fi
  fi

  # The verdict is re-derived from the artefacts on disk -- the extraction
  # log is never trusted (the S08 lesson).
  local out reason detail metrics
  out="$("$CURVES_PY_BIN" "$REPO_ROOT/repro/lib/train.py" curves-verify \
    --csv "$CURVE_CSV" \
    --summary "$SUMMARY_CSV" \
    --expected-tags "$EXPECTED_TAGS" \
    --expected-max-step "$EXPECTED_MAX_STEP" \
    --expected-min-step "$EXPECTED_MIN_STEP" 2>/dev/null)"
  reason="$(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -n1)"
  detail="$(printf '%s\n' "$out" | sed -n 's/^DETAIL=//p' | head -n1)"
  metrics="$(printf '%s\n' "$out" | sed -n 's/^METRICS=//p' | head -n1)"

  if [ -z "$reason" ]; then
    elog "  the decision base produced no result (reason=analysis-failed)"
    elog "TRAIN_CURVES_FAIL reason=analysis-failed"
    return 1
  fi
  if [ "$reason" != "-" ]; then
    [ -n "$detail" ] && elog "  $detail"
    elog "TRAIN_CURVES_FAIL reason=$reason"
    return 1
  fi

  local rows tags steps
  rows="$(metric "$metrics" rows)"
  tags="$(metric "$metrics" tags)"
  steps="$(metric "$metrics" max_step)"
  [ -n "$detail" ] && elog "  $detail"
  elog_ok "TRAIN_CURVES_OK events_files=$events tags=$tags rows=$rows steps=$steps csv=$(rel_path "$CURVE_CSV")"
  flush_ok_markers
  return 0
}

# ---------------------------------------------------------------------------
# cmd_report
# ---------------------------------------------------------------------------
cmd_report() {
  elog "=== 27_train_curves.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  if [ ! -f "$CURVE_CSV" ]; then
    elog "TRAIN_CURVES_REPORT_OK=0"
    elog "TRAIN_CURVES_REPORT_REASON=curve-csv-missing"
    return 1
  fi

  local out reason metrics
  out="$("$CURVES_PY_BIN" "$REPO_ROOT/repro/lib/train.py" curves-verify \
    --csv "$CURVE_CSV" \
    --summary "$SUMMARY_CSV" 2>/dev/null)"
  reason="$(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -n1)"
  metrics="$(printf '%s\n' "$out" | sed -n 's/^METRICS=//p' | head -n1)"

  elog "TRAIN_CURVES_REPORT_EVENTS_FILES=$(count_events_files "$RUN_DIR")"
  elog "TRAIN_CURVES_REPORT_ROWS=$(metric "$metrics" rows)"
  elog "TRAIN_CURVES_REPORT_TAGS=$(metric "$metrics" tags)"
  elog "TRAIN_CURVES_REPORT_FIRST_STEP=$(metric "$metrics" min_step)"
  elog "TRAIN_CURVES_REPORT_LAST_STEP=$(metric "$metrics" max_step)"
  elog "TRAIN_CURVES_REPORT_NAN_TAGS=$(metric "$metrics" nan_tags)"
  elog "TRAIN_CURVES_REPORT_SUMMARY_OK=$(metric "$metrics" summary_ok)"
  elog "TRAIN_CURVES_REPORT_CSV=$(rel_path "$CURVE_CSV")"
  elog "TRAIN_CURVES_REPORT_SUMMARY_CSV=$(rel_path "$SUMMARY_CSV")"
  if [ "$reason" = "-" ]; then
    elog "TRAIN_CURVES_REPORT_OK=1"
    return 0
  fi
  elog "TRAIN_CURVES_REPORT_OK=0"
  elog "TRAIN_CURVES_REPORT_REASON=${reason}"
  return 1
}

# ---------------------------------------------------------------------------
# cmd_selftest
# ---------------------------------------------------------------------------
cmd_selftest() {
  local test_file="$REPO_ROOT/repro/tests/test_train_curves.py"
  if [ ! -f "$test_file" ]; then
    elog "TRAIN_CURVES_SELFTEST_FAIL reason=test-missing"
    return 1
  fi
  "$CURVES_PY_BIN" "$test_file"
  local rc=$?
  if [ $rc -ne 0 ]; then
    elog "TRAIN_CURVES_SELFTEST_FAIL reason=selftest-failed"
    return 1
  fi
  elog "TRAIN_CURVES_SELFTEST_OK cases=1"
  return 0
}

case "${1:-}" in
  env) shift || true; cmd_env "$@" ;;
  run) shift || true; cmd_run "$@" ;;
  verify) shift || true; cmd_verify "$@" ;;
  report) shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/27_train_curves.sh <env|run|verify|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
