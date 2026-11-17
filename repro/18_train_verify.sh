#!/usr/bin/env bash
# repro/18_train_verify.sh — the READ-ONLY, INDEPENDENT terminal reviewer
# of the g1_amber formal training run (slice S06, task T3).
#
# ---------------------------------------------------------------------------
# WHY A SEPARATE, READ-ONLY REVIEWER
#
# The acceptance of the formal run is ">= 3 ckpt + a tensorboard curve
# without NaN + a resume that really happened + the whole run inside the
# resource budget".  If the TRAINING script judged its own output, the
# verdict would be a self-proof.  So this script never trusts what
# repro/17_train.sh / repro/17_train_worker.sh claim: it re-derives every
# fact from the artefacts on disk (the checkpoint files, the tensorboard
# event files, the training log, the resource sampler CSV and the status
# file).
#
# It is READ-ONLY: apart from its own log (logs/env/18_train_verify.txt) it
# never writes a single byte.  It never launches a training process.
#
# ---------------------------------------------------------------------------
# THE THREE TRAPS THIS REVIEWER MUST CLOSE (research §4.2 + the probe)
#
#   (a) TENSORBOARD — every process start writes a NEW events file into the
#       run directory (the probe measured 2 event files in one run
#       directory).  Reading only ONE event file under-reports and can miss
#       a NaN that appeared in a later segment.  The reviewer therefore
#       aggregates the WHOLE run directory with
#       `EventAccumulator(run_dir, size_guidance={"scalars": 0})`, which
#       loads every events file of that directory.
#
#   (b) THE NaN WHITELIST — under `--kp-student copy` the tags
#       `kp/return` and `kp/scale_return` are NaN BY DESIGN (upstream
#       trainer.py:1935 "NaN under copy"; the probe measured 52 tags of
#       which exactly these two are NaN).  A naive "every scalar must be
#       finite" check is therefore a false red.  The whitelist is the one
#       of repro/lib/train.py (`train.DEFAULT_WHITELIST`), and the audit
#       itself is `train.nan_audit` — one decision base, one implementation.
#
#   (c) THE RESOURCE PEAK — the peak VRAM must come from the nvidia-smi
#       PROCESS occupancy (`gpu_used_mb` of the sampler CSV), NOT from
#       torch's `max_memory_allocated` (the allocator view: the probe
#       measured 17.09 GB there while the process occupancy is larger).
#       The host gate asks for the former.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   verify   the terminal gate.  Prints ONE OK MARKER line
#              TRAIN_VERIFY_OK ckpts=<n> latest=1 tb_tags=<n> nan_whitelist=2 \
#                        resume_events=<n> gpu_peak_mb=<n> host_peak_gb=<x> \
#                        wall_s=<n> iterations=<n> lr_decay_iters=<n>
#            or, on failure, ONE FAIL MARKER line
#              TRAIN_VERIFY_FAIL reason=<fixed reason set>
#            and a non-zero exit code.  Besides the marker line the run also
#            prints a run header and the failure detail (both also appended
#            to $MAIN_LOG); the marker itself is always exactly ONE line.
#            A failing run NEVER prints an OK marker (the S03/MEM038
#            convention: the OK marker is buffered and flushed only when
#            every check passed).
#
#   report   the same numbers in the `TRAIN_REPORT_*` form, for the
#            documentation back-fill.
#
# THE FIXED REASON SET (greppable)
#
#   ckpt-count          fewer than 3 `ckpt_*.pt` files
#   ckpt-missing        no checkpoint at all / the smallest one vanished
#   ckpt-unloadable     `torch.load` failed on the smallest ckpt or latest.pt
#   latest-missing      no `latest.pt`
#   tb-no-events        no tensorboard event file / no scalar tag at all
#   tb-tag-missing      a required tag is absent
#   tb-nonfinite        a scalar outside the whitelist is NaN/Inf
#   tb-nonfinite-steps  a `*/nonfinite_steps` counter is > 0
#   resume-missing      no `resumed <path> at iteration N` in any log
#   resume-iteration    the resume iteration is 0, or no checkpoint is
#                       newer than the resume point
#   resource-csv-missing the resource sampler CSV is missing/unparsable
#   gpu-over-budget     peak VRAM >= 22 GiB
#   host-over-budget    peak host RAM >= 45 GiB
#   wall-over-budget    wall clock > the planned budget
#   iterations-mismatch --iterations != --lr-decay-iters
#   npz-verify-failed   the S04 npz gate (repro/14_seed_npz_verify.sh verify)
#                       no longer passes
#   human-verify-failed the S05 human50 gate (repro/16_seed_human_verify.sh
#                       verify) no longer passes
#   analysis-failed     the decision base (repro/lib/train.py) produced no
#                       result at all -- an internal error, never a verdict
#                       about the run
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one exists so the offline fixture battery
# can drive the reviewer without a GPU, without the payload and without
# the container)
#
#   TRAIN_ALLOW_LOCAL=1    allow running outside the ros_dev container
#   TRAIN_LOG_DIR          log directory      (default $LOG_DIR)
#   TRAIN_RUN_DIR          the run directory  (default logs/train/g1_amber_1h)
#   TRAIN_STATUS_FILE      status file        (default logs/env/17_train.status)
#   TRAIN_RESOURCES_CSV    resource sampler   (default logs/env/17_train_resources.csv)
#   TRAIN_WORKER_LOG       worker stdout      (default logs/env/17_train_worker.log)
#   TRAIN_PLAN_FILE        the plan file      (default logs/env/17_train_plan.env)
#   TRAIN_MIN_CKPTS        minimum ckpt count (default 3)
#   TRAIN_GPU_MAX_MB       VRAM limit in MiB  (default 22528 = 22 GiB)
#   TRAIN_HOST_MAX_GB      host RAM limit     (default 45)
#   TRAIN_WALL_MAX_S       wall budget (default: the plan file BUDGET_SECONDS)
#   TRAIN_NPZ_VERIFY_CMD   the S04 gate       (default: bash repro/14_seed_npz_verify.sh verify)
#   TRAIN_HUMAN_VERIFY_CMD the S05 gate       (default: bash repro/16_seed_human_verify.sh verify)
#   TRAIN_PY               the decision-base interpreter (default python3)
#   TRAIN_TORCH_PY         the torch/tensorboard interpreter (default: the
#                          project venv, else `uv run --frozen --no-sync python`)
#   TRAIN_TB_CMD           override the whole tensorboard aggregation command
#   TRAIN_CKPT_LOAD_CMD    override the whole `torch.load` probe command
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

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

if [ "${TRAIN_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${TRAIN_LOG_DIR:-$LOG_DIR}"
# CANONICALISE the log directory and the run directory: the milestone
# worktree (and its `logs/` symlink into the seed store) can be rebuilt while
# a long run is in flight (observed 2026-11-13).  The STORE paths never move,
# so the reviewer keeps finding the status file, the worker log, the sampler
# CSV and the checkpoints after a rebuild.
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/18_train_verify.txt"
TRAIN_LOG_ROOT="${TRAIN_LOG_ROOT:-$REPO_ROOT/logs/train}"
TRAIN_LOG_ROOT="$(readlink -f "$TRAIN_LOG_ROOT" 2>/dev/null || printf '%s' "$TRAIN_LOG_ROOT")"
RUN_DIR="${TRAIN_RUN_DIR:-$TRAIN_LOG_ROOT/g1_amber_1h}"
STATUS_FILE="${TRAIN_STATUS_FILE:-$LOG_DIR_REAL/17_train.status}"
RESOURCES_CSV="${TRAIN_RESOURCES_CSV:-$LOG_DIR_REAL/17_train_resources.csv}"
WORKER_LOG="${TRAIN_WORKER_LOG:-$LOG_DIR_REAL/17_train_worker.log}"
PLAN_FILE="${TRAIN_PLAN_FILE:-$LOG_DIR_REAL/17_train_plan.env}"
TRAIN_MIN_CKPTS="${TRAIN_MIN_CKPTS:-3}"
TRAIN_GPU_MAX_MB="${TRAIN_GPU_MAX_MB:-22528}"
TRAIN_HOST_MAX_GB="${TRAIN_HOST_MAX_GB:-45}"
TRAIN_NPZ_VERIFY_CMD="${TRAIN_NPZ_VERIFY_CMD:-bash $REPO_ROOT/repro/14_seed_npz_verify.sh verify}"
TRAIN_HUMAN_VERIFY_CMD="${TRAIN_HUMAN_VERIFY_CMD:-bash $REPO_ROOT/repro/16_seed_human_verify.sh verify}"
TRAIN_PY_BIN="${TRAIN_PY:-python3}"
TRAIN_LIB_DIR="$REPO_ROOT/repro/lib"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/18_train_verify.sh <verify|report>

  verify   the terminal gate (TRAIN_VERIFY_OK / TRAIN_VERIFY_FAIL reason=...)
  report   the same numbers as TRAIN_REPORT_* lines (documentation back-fill)

run dir:  $RUN_DIR
log:      $MAIN_LOG
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

# ---------------------------------------------------------------------------
# the two heavy probes (both overridable so the fixture battery can drive
# them offline)
# ---------------------------------------------------------------------------

# train_torch_cmd — the interpreter words used for torch / tensorboard.
train_torch_cmd() {
  local spec="${TRAIN_TORCH_PY:-}"
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

# TB_PY_CODE — the tensorboard aggregation.  It walks the WHOLE run
# directory: EventAccumulator takes a directory and loads every events file
# inside it, which is exactly what the "one events file per process start"
# trap requires.
read -r -d '' TB_PY_CODE <<'PYEOF' || true
import json, math, os, sys

run_dir = sys.argv[1] if len(sys.argv) > 1 else ""
out = {"tags": {}, "n_events_files": 0, "error": None}

try:
    from tensorboard.backend.event_processing import event_accumulator as ea
except Exception as exc:  # pragma: no cover - container without tensorboard
    out["error"] = "tensorboard-import-failed: %s" % (exc,)
    print(json.dumps(out))
    raise SystemExit(0)

if not run_dir or not os.path.isdir(run_dir):
    out["error"] = "run-dir-missing: %s" % (run_dir,)
    print(json.dumps(out))
    raise SystemExit(0)

try:
    out["n_events_files"] = len(
        [n for n in os.listdir(run_dir) if n.startswith("events.out.tfevents")])
except OSError:
    out["n_events_files"] = 0

try:
    # size_guidance={"scalars": 0} keeps EVERY scalar step of every event
    # file of the directory (0 == unlimited).
    acc = ea.EventAccumulator(run_dir, size_guidance={"scalars": 0})
    acc.Reload()
    for tag in list(acc.Tags().get("scalars", [])):
        values = []
        for event in acc.Scalars(tag):
            values.append(event.value)
        finite = True
        best = None
        for value in values:
            try:
                fvalue = float(value)
            except (TypeError, ValueError):
                finite = False
                break
            if not math.isfinite(fvalue):
                finite = False
                break
            if best is None or fvalue > best:
                best = fvalue
        out["tags"][tag] = {"n": len(values), "finite": finite, "max": best}
except Exception as exc:
    out["error"] = "accumulator-failed: %s" % (exc,)

print(json.dumps(out))
PYEOF

# tb_aggregate <run_dir> — the aggregated tensorboard summary (JSON).
tb_aggregate() {
  local run_dir="$1"
  if [ -n "${TRAIN_TB_CMD:-}" ]; then
    eval "$TRAIN_TB_CMD \"$run_dir\"" 2>/dev/null
    return $?
  fi
  local spec
  spec="$(train_torch_cmd)"
  if [ -z "$spec" ]; then
    printf '{"tags": {}, "n_events_files": 0, "error": "no-torch-interpreter"}\n'
    return 0
  fi
  local -a cmd
  read -r -a cmd <<<"$spec"
  "${cmd[@]}" -c "$TB_PY_CODE" "$run_dir" 2>/dev/null
  return $?
}

# ckpt_load_probe <path> — `torch.load` the checkpoint (map_location="cpu").
# ONLY the smallest ckpt and latest.pt are loaded: a full sweep over every
# checkpoint would load hundreds of MB per file and blow the host gate
# (the S03 lesson: a 68.7 GB sha256 re-check took 518 s).
ckpt_load_probe() {
  local path="$1"
  if [ -n "${TRAIN_CKPT_LOAD_CMD:-}" ]; then
    eval "$TRAIN_CKPT_LOAD_CMD \"$path\"" >/dev/null 2>&1
    return $?
  fi
  local spec
  spec="$(train_torch_cmd)"
  if [ -z "$spec" ]; then
    return 1
  fi
  local -a cmd
  read -r -a cmd <<<"$spec"
  "${cmd[@]}" -c 'import sys, torch; torch.load(sys.argv[1], map_location="cpu")' \
    "$path" >/dev/null 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# the analysis (stdlib only, on top of repro/lib/train.py)
# ---------------------------------------------------------------------------
read -r -d '' PY_ANALYSE <<'PYEOF' || true
import glob
import json
import os
import re
import sys

sys.path.insert(0, sys.argv[1])
import train


def env(name, default=None):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value


state = {"reason": None, "detail": ""}
metrics = {}


def fail(reason, detail=""):
    if state["reason"] is None:
        state["reason"] = reason
        state["detail"] = detail


run_dir = env("VER_RUN_DIR", "")
min_ckpts = int(env("VER_MIN_CKPTS", "3"))

# --- 1. checkpoints --------------------------------------------------------
ckpts = sorted(glob.glob(os.path.join(run_dir, "ckpt_*.pt")))
metrics["ckpts"] = len(ckpts)
if not ckpts:
    fail("ckpt-missing", "no ckpt_*.pt in %s" % (run_dir,))
elif len(ckpts) < min_ckpts:
    fail("ckpt-count",
         "ckpt_*.pt=%d < %d in %s" % (len(ckpts), min_ckpts, run_dir))

latest = os.path.join(run_dir, "latest.pt")
has_latest = os.path.isfile(latest)
metrics["latest"] = 1 if has_latest else 0
if not has_latest:
    fail("latest-missing", latest)


def ckpt_iter(path):
    match = re.search(r"ckpt_(\d+)\.pt$", os.path.basename(path))
    return int(match.group(1)) if match else -1


ckpt_iters = sorted(v for v in (ckpt_iter(p) for p in ckpts) if v >= 0)
max_ckpt_it = ckpt_iters[-1] if ckpt_iters else -1
metrics["max_ckpt_iter"] = max_ckpt_it

# the torch.load evidence was produced by the shell (the shell owns the
# interpreter choice); the verdict is decided here.
for key in ("VER_LOAD_SMALLEST", "VER_LOAD_LATEST"):
    verdict = env(key)
    # "ok"      the probe loaded the checkpoint
    # "skipped" the mode does not probe (the `report` mode)
    # "missing" the file does not exist (already reported as ckpt-count /
    #           latest-missing, which have a higher precedence)
    # "fail"    the probe failed -> the checkpoint is not loadable
    if verdict == "fail":
        fail("ckpt-unloadable", "%s=fail (%s)" % (key, env("VER_SMALLEST_CKPT", "")))

# --- 2. tensorboard --------------------------------------------------------
try:
    tb = json.loads(env("VER_TB_JSON", "{}") or "{}")
except Exception as exc:
    tb = {}
    tb["error"] = "tb-json-unparsable: %s" % (exc,)

tb_tags = tb.get("tags") or {}
metrics["tb_tags"] = len(tb_tags)
metrics["nonfinite_tags"] = 0

if tb.get("error") or not tb_tags:
    fail("tb-no-events",
         "error=%s tags=%d events_files=%s"
         % (tb.get("error"), len(tb_tags), tb.get("n_events_files")))
else:
    scalars = {}
    for tag, info in tb_tags.items():
        count = int((info or {}).get("n") or 0)
        if count <= 0:
            continue
        if not (info or {}).get("finite", True):
            scalars[tag] = [float("nan")]
        else:
            maximum = (info or {}).get("max")
            scalars[tag] = [float(maximum) if maximum is not None else 0.0]
    ok, bad_tags, missing, violations = train.nan_audit(scalars)
    metrics["nonfinite_tags"] = len(bad_tags)
    metrics["nan_whitelist"] = len(train.DEFAULT_WHITELIST)
    if missing:
        fail("tb-tag-missing", "missing=%s" % ",".join(missing))
    if bad_tags:
        fail("tb-nonfinite", "nonfinite_tags=%s" % ",".join(bad_tags))
    if violations:
        fail("tb-nonfinite-steps", ";".join(violations))

# --- 3. resume evidence ----------------------------------------------------
log_paths = []
worker_log = env("VER_WORKER_LOG", "")
if worker_log:
    log_paths.append(worker_log)
if os.path.isdir(run_dir):
    for name in sorted(os.listdir(run_dir)):
        if name.endswith(".log") or name.endswith(".txt"):
            log_paths.append(os.path.join(run_dir, name))

resume_events = []
max_it = 0
it_per_s = []
for path in log_paths:
    summary = train.parse_log_file(path)
    if summary is None:
        continue
    resume_events.extend(summary["resume_events"])
    max_it = max(max_it, summary["max_it"])
    it_per_s.extend(summary["it_per_s"])

metrics["resume_events"] = len(resume_events)
metrics["max_it"] = max_it
metrics["it_per_s"] = round(sum(it_per_s) / len(it_per_s), 4) if it_per_s else 0.0

if not resume_events:
    fail("resume-missing",
         "no 'resumed <path> at iteration N' in %s" % ",".join(log_paths))
else:
    best = max(it for (_path, it) in resume_events)
    metrics["resume_iter"] = best
    if best <= 0:
        fail("resume-iteration", "the resume iteration is %d (must be > 0)" % best)
    elif max_ckpt_it <= best:
        fail("resume-iteration",
             "no checkpoint is newer than the resume point %d (max ckpt iteration=%d)"
             % (best, max_ckpt_it))

# --- 4. resource budget ----------------------------------------------------
resources_csv = env("VER_RESOURCES_CSV", "")
summary = train.parse_resource_csv(resources_csv)
if summary is None:
    fail("resource-csv-missing", resources_csv)
    gpu_peak = None
    host_peak = None
else:
    gpu_peak = summary.get("gpu_used_mb_peak")
    host_peak = summary.get("host_used_gb_peak")

metrics["gpu_peak_mb"] = float(gpu_peak) if gpu_peak is not None else 0.0
metrics["host_peak_gb"] = round(float(host_peak), 2) if host_peak is not None else 0.0

status = train.read_status(env("VER_STATUS_FILE", ""))
wall_s = None
try:
    wall_s = float(status.get("ELAPSED"))
except (TypeError, ValueError):
    wall_s = None
metrics["wall_s"] = int(wall_s) if wall_s is not None else 0

limits = {}
if env("VER_GPU_MAX_MB") is not None:
    limits["gpu_max_mb"] = float(env("VER_GPU_MAX_MB"))
if env("VER_HOST_MAX_GB") is not None:
    limits["host_max_gb"] = float(env("VER_HOST_MAX_GB"))
if env("VER_WALL_MAX_S") is not None:
    limits["wall_max_s"] = float(env("VER_WALL_MAX_S"))

ok, reasons = train.budget_ok(gpu_peak, host_peak, wall_s, limits)
for reason in reasons:
    if "gpu-peak-over-budget" in reason:
        fail("gpu-over-budget", reason)
    elif "host-peak-over-budget" in reason:
        fail("host-over-budget", reason)
    elif "wall-over-budget" in reason:
        fail("wall-over-budget", reason)
    elif "gpu-peak-missing" in reason or "host-peak-missing" in reason:
        fail("resource-csv-missing", reason)
    elif "wall-clock-missing" in reason:
        fail("wall-over-budget", reason)

# --- 5. iterations vs --lr-decay-iters -------------------------------------
plan = {}
plan_file = env("VER_PLAN_FILE", "")
if plan_file and os.path.isfile(plan_file):
    with open(plan_file, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            plan[key.strip()] = value.strip()


def as_int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


iterations = None
for source in (plan.get("ITERATIONS"), status.get("ITER"), status.get("TARGET_ITER")):
    iterations = as_int(source)
    if iterations is not None:
        break
lr_decay = as_int(plan.get("LR_DECAY_ITERS"))

metrics["iterations"] = iterations if iterations is not None else 0
metrics["lr_decay_iters"] = lr_decay if lr_decay is not None else 0

if iterations is None or lr_decay is None:
    fail("iterations-mismatch",
         "no iteration evidence (plan=%s status ITER=%s)"
         % (plan.get("ITERATIONS"), status.get("ITER")))
elif iterations != lr_decay:
    fail("iterations-mismatch",
         "iterations=%d lr_decay_iters=%d" % (iterations, lr_decay))
else:
    plan_iterations = as_int(plan.get("ITERATIONS"))
    status_iter = as_int(status.get("ITER"))
    if plan_iterations is not None and status_iter is not None \
            and plan_iterations != status_iter:
        fail("iterations-mismatch",
             "plan ITERATIONS=%d status ITER=%d" % (plan_iterations, status_iter))

# --- output ----------------------------------------------------------------
order = ("ckpts", "latest", "tb_tags", "nan_whitelist", "resume_events",
         "gpu_peak_mb", "host_peak_gb", "wall_s", "iterations",
         "lr_decay_iters")
metrics.setdefault("nan_whitelist", len(train.DEFAULT_WHITELIST))
metrics.setdefault("latest", 0)
print("REASON=%s" % (state["reason"] or "-"))
print("DETAIL=%s" % (state["detail"] or "-"))
print("METRICS=%s" % " ".join("%s=%s" % (key, metrics.get(key, 0))
                              for key in order))
print("EXTRA=%s" % json.dumps({
    "nonfinite_tags": metrics.get("nonfinite_tags", 0),
    "it_per_s": metrics.get("it_per_s", 0.0),
    "max_ckpt_iter": metrics.get("max_ckpt_iter", -1),
    "resume_iter": metrics.get("resume_iter", 0),
    "max_it": metrics.get("max_it", 0),
}, sort_keys=True))
PYEOF

# plan_value <KEY> — the value of a KEY of the plan file.
plan_value() {
  [ -f "$PLAN_FILE" ] || return 0
  sed -n "s/^$1=//p" "$PLAN_FILE" | head -n1
}

# ---------------------------------------------------------------------------
# the shared analysis (used by `verify` and by `report`)
# ---------------------------------------------------------------------------
# analyse <mode: verify|report> — runs the probes, calls the decision base
# and prints the outcome on stdout:
#   line 1: "OK"            -> every check passed
#   line 1: "FAIL <reason>" -> the first failed check
#   line 2: "<detail>"
#   line 3: "<metrics k=v ...>"
analyse() {
  local mode="$1"
  local tb_json="" smallest="" load_smallest="skipped" load_latest="skipped"
  local ckpt_files=() f

  # (a) the checkpoint list (numeric order: ckpt_2000.pt < ckpt_10000.pt).
  while IFS= read -r f; do
    [ -n "$f" ] && ckpt_files+=("$f")
  done < <(find "$RUN_DIR" -maxdepth 1 -type f -name 'ckpt_*.pt' 2>/dev/null \
    | sort -t_ -k2 -n)

  if [ "${#ckpt_files[@]}" -gt 0 ]; then
    smallest="${ckpt_files[0]}"
  fi

  # (b) the tensorboard aggregation (the whole run directory).
  tb_json="$(tb_aggregate "$RUN_DIR")"

  # (c) the torch.load probes: the SMALLEST checkpoint and latest.pt only.
  if [ "$mode" = "verify" ]; then
    if [ -n "$smallest" ]; then
      if ckpt_load_probe "$smallest"; then load_smallest="ok"; else load_smallest="fail"; fi
    else
      load_smallest="missing"
    fi
    if [ -f "$RUN_DIR/latest.pt" ]; then
      if ckpt_load_probe "$RUN_DIR/latest.pt"; then load_latest="ok"; else load_latest="fail"; fi
    else
      load_latest="missing"
    fi
  fi

  # (d) the wall budget: the override wins, else the plan file.
  local wall_max="${TRAIN_WALL_MAX_S:-}"
  if [ -z "$wall_max" ]; then
    wall_max="$(plan_value BUDGET_SECONDS)"
  fi

  local out reason detail metrics extra
  out="$(VER_RUN_DIR="$RUN_DIR" \
    VER_MIN_CKPTS="$TRAIN_MIN_CKPTS" \
    VER_STATUS_FILE="$STATUS_FILE" \
    VER_RESOURCES_CSV="$RESOURCES_CSV" \
    VER_WORKER_LOG="$WORKER_LOG" \
    VER_PLAN_FILE="$PLAN_FILE" \
    VER_GPU_MAX_MB="$TRAIN_GPU_MAX_MB" \
    VER_HOST_MAX_GB="$TRAIN_HOST_MAX_GB" \
    VER_WALL_MAX_S="$wall_max" \
    VER_TB_JSON="$tb_json" \
    VER_LOAD_SMALLEST="$load_smallest" \
    VER_LOAD_LATEST="$load_latest" \
    VER_SMALLEST_CKPT="$smallest" \
    "$TRAIN_PY_BIN" -c "$PY_ANALYSE" "$TRAIN_LIB_DIR" 2>/dev/null)"

  reason="$(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -n1)"
  detail="$(printf '%s\n' "$out" | sed -n 's/^DETAIL=//p' | head -n1)"
  metrics="$(printf '%s\n' "$out" | sed -n 's/^METRICS=//p' | head -n1)"
  extra="$(printf '%s\n' "$out" | sed -n 's/^EXTRA=//p' | head -n1)"

  if [ -z "$reason" ] || [ -z "$metrics" ]; then
    printf 'FAIL analysis-failed\n'
    printf '%s\n' "${detail:-the decision base produced no result}"
    printf '\n'
    return 1
  fi
  if [ "$reason" != "-" ]; then
    printf 'FAIL %s\n' "$reason"
    printf '%s\n' "$detail"
    printf '%s\n' "$metrics"
    printf '%s\n' "$extra"
    return 1
  fi
  printf 'OK\n'
  printf '%s\n' "$detail"
  printf '%s\n' "$metrics"
  printf '%s\n' "$extra"
  return 0
}

# metric <metrics> <key> — the value of one metric.
metric() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1
}

# ---------------------------------------------------------------------------
# cmd_verify
# ---------------------------------------------------------------------------
cmd_verify() {
  elog "=== 18_train_verify.sh verify $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "run dir: $RUN_DIR"

  local result reason detail metrics extra
  result="$(analyse verify)"
  reason="$(printf '%s\n' "$result" | sed -n '1p')"
  detail="$(printf '%s\n' "$result" | sed -n '2p')"
  metrics="$(printf '%s\n' "$result" | sed -n '3p')"
  extra="$(printf '%s\n' "$result" | sed -n '4p')"

  if [ "$reason" != "OK" ]; then
    local r="${reason#FAIL }"
    [ -n "$detail" ] && [ "$detail" != "-" ] && elog "  $detail"
    elog "TRAIN_VERIFY_FAIL reason=$r"
    return 1
  fi

  # (5) the data gates of the upstream slices: the S04 npz library and the
  # S05 human50 sidecars must still be intact.
  if ! eval "$TRAIN_NPZ_VERIFY_CMD" >/dev/null 2>&1; then
    elog "  the npz gate failed: $TRAIN_NPZ_VERIFY_CMD"
    elog "TRAIN_VERIFY_FAIL reason=npz-verify-failed"
    return 1
  fi
  if ! eval "$TRAIN_HUMAN_VERIFY_CMD" >/dev/null 2>&1; then
    elog "  the human50 gate failed: $TRAIN_HUMAN_VERIFY_CMD"
    elog "TRAIN_VERIFY_FAIL reason=human-verify-failed"
    return 1
  fi

  elog_ok "TRAIN_VERIFY_OK $metrics"
  flush_ok_markers
  return 0
}

# ---------------------------------------------------------------------------
# cmd_report
# ---------------------------------------------------------------------------
cmd_report() {
  elog "=== 18_train_verify.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  local result reason detail metrics extra
  result="$(analyse report)"
  reason="$(printf '%s\n' "$result" | sed -n '1p')"
  detail="$(printf '%s\n' "$result" | sed -n '2p')"
  metrics="$(printf '%s\n' "$result" | sed -n '3p')"
  extra="$(printf '%s\n' "$result" | sed -n '4p')"

  local it_per_s nonfinite_tags
  it_per_s="$(printf '%s\n' "$extra" | sed -n 's/.*"it_per_s": \([0-9.eE+-]*\).*/\1/p' | head -n1)"
  nonfinite_tags="$(printf '%s\n' "$extra" | sed -n 's/.*"nonfinite_tags": \([0-9]*\).*/\1/p' | head -n1)"

  elog "TRAIN_REPORT_CKPTS=$(metric "$metrics" ckpts)"
  elog "TRAIN_REPORT_ITERATIONS=$(metric "$metrics" iterations)"
  elog "TRAIN_REPORT_IT_PER_S=${it_per_s:-0}"
  elog "TRAIN_REPORT_GPU_PEAK_MB=$(metric "$metrics" gpu_peak_mb)"
  elog "TRAIN_REPORT_HOST_PEAK_GB=$(metric "$metrics" host_peak_gb)"
  elog "TRAIN_REPORT_WALL_S=$(metric "$metrics" wall_s)"
  elog "TRAIN_REPORT_TB_TAGS=$(metric "$metrics" tb_tags)"
  elog "TRAIN_REPORT_NONFINITE_TAGS=${nonfinite_tags:-0}"
  elog "TRAIN_REPORT_RESUME_EVENTS=$(metric "$metrics" resume_events)"
  if [ "$reason" = "OK" ]; then
    elog "TRAIN_REPORT_OK=1"
    return 0
  fi
  elog "TRAIN_REPORT_OK=0"
  elog "TRAIN_REPORT_REASON=${reason#FAIL }"
  return 1
}

case "${1:-}" in
  verify) shift || true; cmd_verify "$@" ;;
  report) shift || true; cmd_report "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/18_train_verify.sh <verify|report>" >&2
    usage >&2
    exit 2
    ;;
esac
