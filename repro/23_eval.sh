#!/usr/bin/env bash
# repro/23_eval.sh — the EVALUATION ORCHESTRATOR of the deployment
# verification (slice S08, task T4).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The milestone requirement R014 asks for the "policy quality" side of the
# deployment verification: the self-trained checkpoint of S06 must be
# benchmarked with the UPSTREAM evaluator (morphmimic.scripts.eval) on the
# 1h subset (490 clips), once through the motion goal interface and once
# through the human skeleton goal interface, and BOTH per-clip tables must
# have exactly one row per clip of the subset.
#
# This is a DIFFERENT measurement surface than the sim2sim replay of T3:
#
#     T3 (sim2sim)  : the exported ONNX policy drives MuJoCo on ONE clip at
#                     a time; it measures the deployment pipeline (rendering,
#                     the ZMQ protocol, the exported assets).
#     T4 (eval)     : the PyTorch checkpoint is benchmarked by the upstream
#                     evaluator over the WHOLE subset; it measures the policy
#                     quality (completion, norm. return, drift).
#
# The two surfaces must NEVER be mixed: the completion of the eval CSV and
# the "result" of a sim2sim summary are different numbers.
#
# The upstream evaluator exists (`uv run python -m morphmimic.scripts.eval
# --ckpt ... --subset-yaml ... --interface motion|human`), but it is a
# single-shot tool: it writes a CSV and prints a summary, and it does NOT
# verify anything about its own output.  The orchestration contract of this
# slice needs more:
#
#     * the env gate must pass BEFORE the benchmark runs (fail closed),
#     * the expected row count is READ FROM THE SUBSET YAML (never a
#       hard-coded 490),
#     * the CSV must carry the mandatory header, hold exactly one row per
#       clip, and every "failed" cell must be parsable,
#     * the completion is RECOMPUTED from the "failed" column by the
#       decision base (repro/lib/deploy.py) — the evaluator's own printout
#       is never trusted,
#     * a failure must be visible: non-zero exit, NO OK marker, a fixed
#       reason.
#
# So this script is the orchestrator and repro/lib/deploy.py is the decision
# base: the CSV is parsed by ONE parser (deploy.read_eval_csv /
# deploy.verify_eval_csv / deploy.eval_completion), so the shell and the
# python can never drift apart.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the fail-closed ENVIRONMENT GATE (seconds, no GPU): the
#            training group imports (torch + mjlab), the checkpoint exists,
#            the subset yaml exists and holds clips, the human sidecar
#            directory exists.  Success prints ONE line
#                DEPLOY_EVAL_ENV_OK ckpt=<path> clips=<n>
#            failure prints ONE line
#                DEPLOY_EVAL_ENV_FAIL reason=<fixed reason set>
#            and exits non-zero.  The OK marker is BUFFERED and flushed only
#            when EVERY check passed (project convention P004).
#
#   motion   the motion-interface benchmark:
#              1. the environment gate MUST pass -- otherwise nothing runs,
#              2. the evaluator is run with
#                    uv run --frozen --offline python -m morphmimic.scripts.eval
#                    --ckpt <ckpt> --subset-yaml <yaml> --interface motion
#                    --out runs/eval/eval_motion_1h.csv --num-envs <n>
#              3. the CSV is verified by the decision base (header, row
#                 count == the clip count of the subset, parsable "failed"
#                 column),
#              4. the completion is recomputed from the "failed" column.
#            Success prints ONE line
#                DEPLOY_EVAL_OK interface=motion rows=<n> completion=<v>
#            failure prints ONE line
#                DEPLOY_EVAL_FAIL reason=<fixed reason set>
#
#   human   the human-interface benchmark (the same, with
#            `--interface human --human-points full --human-root <root>`);
#            the success line is
#                DEPLOY_EVAL_OK interface=human rows=<n> completion=<v>
#
#   report  the evaluation-side self report (DEPLOY_REPORT_*): the row
#            count, the recomputed completion and the measured wall clock
#            of every interface.
#
#   selftest the offline battery: repro/tests/test_deploy_eval.sh.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SETS (greppable)
#
#   env gate:  import-failed  ckpt-missing  subset-missing
#              subset-parse-failed  human-root-missing
#   run gate:  eval-failed  eval-timeout  eval-csv-missing
#              eval-csv-parse-failed  eval-row-count-mismatch
#
# The CSV reasons are the ones repro/lib/deploy.py produces (deploy.REASONS),
# so the orchestrator and the decision base share ONE vocabulary.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without a GPU
# and without the real benchmark)
#
#   EVAL_ALLOW_LOCAL=1   allow running outside the ros_dev container
#   EVAL_CKPT            the checkpoint (default
#                        logs/train/g1_amber_1h/ckpt_26413.pt)
#   EVAL_SUBSET_YAML     the subset (default
#                        data/seed_g1_npz50/subsets/1h.yaml)
#   EVAL_HUMAN_ROOT      the human sidecar root (default: the clip root of
#                        the subset yaml + /human50)
#   EVAL_OUT_DIR         the landing spot (default runs/eval)
#   EVAL_MOTION_OUT      the motion CSV (default
#                        runs/eval/eval_motion_1h.csv)
#   EVAL_HUMAN_OUT       the human CSV (default
#                        runs/eval/eval_human_full_1h.csv)
#   EVAL_NUM_ENVS        the parallel envs (default 490 = the clip count of
#                        the 1h subset)
#   EVAL_UV_BIN          the uv binary (default uv)
#   EVAL_UV_ARGS         the uv arguments (default run --frozen --offline)
#   EVAL_IMPORT_CMD      the import probe (default
#                        "<uv> <uv args> python -c 'import torch, mjlab'")
#   EVAL_RUN_TEMPLATE    the benchmark command template (default
#                        "<uv> <uv args> python -m morphmimic.scripts.eval
#                         --ckpt {ckpt} --subset-yaml {subset}
#                         --interface {interface} --out {out}
#                         --num-envs {num_envs}{extra}")
#   EVAL_TIMEOUT         the wall-clock timeout of one benchmark in seconds
#                        (default 21600 = 6 h; 0 disables it)
#   EVAL_PY              the decision-base interpreter (default python3)
#   EVAL_LOG_DIR         the log directory (default $LOG_DIR)
#   EVAL_SELFTEST_CMD    the offline battery command
#
# CLI OPTIONS of `motion` / `human`:
#   --subset-yaml FILE   evaluate another subset (the smoke run uses
#                        subsets/tiny.yaml)
#   --out FILE           write the CSV somewhere else
#   --num-envs N         the parallel envs
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 22_sim2sim.sh / 21_assets.sh convention).
set +e

if [ "${EVAL_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${EVAL_LOG_DIR:-$LOG_DIR}"
mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true
MAIN_LOG="$LOG_DIR_REAL/23_eval.txt"

CKPT="${EVAL_CKPT:-$REPO_ROOT/logs/train/g1_amber_1h/ckpt_26413.pt}"
SUBSET_YAML="${EVAL_SUBSET_YAML:-$REPO_ROOT/data/seed_g1_npz50/subsets/1h.yaml}"
OUT_DIR_REAL="${EVAL_OUT_DIR:-$REPO_ROOT/runs/eval}"
MOTION_OUT="${EVAL_MOTION_OUT:-$OUT_DIR_REAL/eval_motion_1h.csv}"
HUMAN_OUT="${EVAL_HUMAN_OUT:-$OUT_DIR_REAL/eval_human_full_1h.csv}"
HUMAN_ROOT="${EVAL_HUMAN_ROOT:-}"
NUM_ENVS="${EVAL_NUM_ENVS:-490}"
TIMEOUT="${EVAL_TIMEOUT:-21600}"
PY="${EVAL_PY:-python3}"
UV_BIN="${EVAL_UV_BIN:-uv}"
UV_ARGS="${EVAL_UV_ARGS:-run --frozen --offline}"
IMPORT_CMD="${EVAL_IMPORT_CMD:-$UV_BIN $UV_ARGS python -c 'import torch, mjlab'}"
# NOTE: the default of the benchmark template holds `}` characters, so it can
# NOT be written as ${EVAL_RUN_TEMPLATE:-...}: the closing brace would end
# the parameter expansion early.  Hence the explicit if.
if [ -n "${EVAL_RUN_TEMPLATE:-}" ]; then
  RUN_TEMPLATE="$EVAL_RUN_TEMPLATE"
else
  RUN_TEMPLATE="$UV_BIN $UV_ARGS python -m morphmimic.scripts.eval --ckpt {ckpt} --subset-yaml {subset} --interface {interface} --out {out} --num-envs {num_envs} {extra}"
fi
SELFTEST_CMD="${EVAL_SELFTEST_CMD:-bash $REPO_ROOT/repro/tests/test_deploy_eval.sh}"
DEPLOY_LIB="$REPO_ROOT/repro/lib/deploy.py"
TIMINGS_FILE="$OUT_DIR_REAL/timings.tsv"

usage() {
  cat <<EOF
usage: bash repro/23_eval.sh <subcommand> [options]

  env       the fail-closed environment gate (DEPLOY_EVAL_ENV_OK / _FAIL)
  motion    the motion-interface benchmark (DEPLOY_EVAL_OK interface=motion)
  human     the human-interface benchmark (DEPLOY_EVAL_OK interface=human)
            options: --subset-yaml FILE  --out FILE  --num-envs N
  report    the evaluation-side self report (DEPLOY_REPORT_*)
  selftest  the offline battery (repro/tests/test_deploy_eval.sh)

ckpt:      $CKPT
subset:    $SUBSET_YAML
out dir:   $OUT_DIR_REAL
motion:    $MOTION_OUT
human:     $HUMAN_OUT
log:       $MAIN_LOG
EOF
}

# --- output ----------------------------------------------------------------
elog() {
  printf '%s\n' "$*"
  mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true
  printf '%s\n' "$*" >>"$MAIN_LOG" 2>/dev/null || true
}

# The OK markers are buffered and flushed ONLY when every check passed
# (project convention P004): a failure path must print NO OK marker.
OK_MARKERS=()
elog_ok() { OK_MARKERS+=("$*"); }
flush_ok_markers() {
  local m
  for m in ${OK_MARKERS[@]+"${OK_MARKERS[@]}"}; do elog "$m"; done
  OK_MARKERS=()
}

# --- helpers ---------------------------------------------------------------
# rel_to_repo <path> — the path relative to the repository root when it is
# inside it (the markers quote repo-relative paths), the path itself
# otherwise.
rel_to_repo() {
  local p="$1"
  case "$p" in
    "$REPO_ROOT"/*) printf '%s' "${p#"$REPO_ROOT"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# subset_info <subset.yaml>
# The decision is made by repro/lib/deploy.py (parse_subset_yaml): the clip
# root and the clip count of the subset are READ, never assumed.
# Prints
#   ok root=<root> clips=<n>
# on success and
#   reason=<reason>
# on failure (exit code 1).
subset_info() {
  "$PY" - "$1" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

subset_path, lib_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

info, reason = module.parse_subset_yaml(subset_path)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print("ok root=%s clips=%d" % (info["root"], len(info["clips"])))
PY
}

# eval_csv_check <csv> <expected rows>
# The decision is made by repro/lib/deploy.py (verify_eval_csv): the header,
# the row count and the parsability of the "failed" column.  The completion
# is RECOMPUTED here from the "failed" column.  Prints
#   ok clips=<n> failures=<n> completion=<v>
# on success and
#   reason=<reason>
# on failure (exit code 1).
eval_csv_check() {
  "$PY" - "$1" "$2" "$DEPLOY_LIB" <<'PY'
import importlib.util
import sys

csv_path, expect_rows, lib_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location("deploy_decision_base", lib_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

facts, reason = module.verify_eval_csv(csv_path, expect_rows=expect_rows,
                                       require_parseable_failed=True)
if reason is not None:
  print("reason=%s" % reason)
  sys.exit(1)
print("ok clips=%d failures=%d completion=%.6f" % (
  facts["clips"], facts["failures"], facts["completion"]))
PY
}

# expand_template <template> — replaces the placeholders {ckpt} {subset}
# {interface} {out} {num_envs} {extra} with shell-quoted values.
expand_template() {
  local template="$1" interface="$2" out_path="$3" extra="$4"
  local out="$template"
  out="${out//\{ckpt\}/$(printf '%q' "$CKPT")}"
  out="${out//\{subset\}/$(printf '%q' "$SUBSET_YAML")}"
  out="${out//\{interface\}/$(printf '%q' "$interface")}"
  out="${out//\{out\}/$(printf '%q' "$out_path")}"
  out="${out//\{num_envs\}/$(printf '%q' "$NUM_ENVS")}"
  out="${out//\{extra\}/$extra}"
  printf '%s' "$out"
}

# --- env gate --------------------------------------------------------------
# env_fail <reason> [detail...] — the ONLY failure exit of the gate: it
# prints the fail marker (and the details) and returns 1.  It NEVER prints
# an OK marker.
env_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_EVAL_ENV_FAIL reason=$reason"
  return 1
}

env_gate() {
  # (1) the training group must import (torch + mjlab).
  local probe_out probe_rc
  probe_out="$(eval "$IMPORT_CMD" 2>&1)"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    env_fail "import-failed" \
      "command: $IMPORT_CMD" \
      "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    return 1
  fi

  # (2) the checkpoint must exist (and be a non-empty file).
  if [ ! -f "$CKPT" ] || [ ! -s "$CKPT" ]; then
    env_fail "ckpt-missing" "PATH=$CKPT" || return 1
    return 1
  fi

  # (3) the subset yaml must exist and hold clips.
  if [ ! -f "$SUBSET_YAML" ]; then
    env_fail "subset-missing" "PATH=$SUBSET_YAML" || return 1
    return 1
  fi
  local info clips
  info="$(subset_info "$SUBSET_YAML")"
  if [ $? -ne 0 ]; then
    local reason
    reason="$(printf '%s\n' "$info" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    env_fail "${reason:-subset-parse-failed}" "PATH=$SUBSET_YAML" || return 1
    return 1
  fi
  clips="$(printf '%s\n' "$info" | sed -n 's/^ok .*clips=\([0-9]*\).*$/\1/p' | head -n1)"
  if [ "${clips:-0}" -le 0 ]; then
    env_fail "subset-parse-failed" "PATH=$SUBSET_YAML" || return 1
    return 1
  fi

  # (4) the human sidecar directory must exist (the human interface reads
  #     the sidecars from there).
  local human_root
  human_root="$(human_root_of "$info")"
  if [ ! -d "$human_root" ]; then
    env_fail "human-root-missing" "PATH=$human_root" || return 1
    return 1
  fi

  elog_ok "DEPLOY_EVAL_ENV_OK ckpt=$(rel_to_repo "$CKPT") clips=$clips"
  flush_ok_markers
  return 0
}

# human_root_of <subset info line> — the human sidecar root: the explicit
# EVAL_HUMAN_ROOT when it is set, otherwise the clip root of the subset yaml
# + /human50 (the layout of S05).
human_root_of() {
  if [ -n "$HUMAN_ROOT" ]; then
    printf '%s' "$HUMAN_ROOT"
    return 0
  fi
  local root
  root="$(printf '%s\n' "$1" | sed -n 's/^ok root=\([^ ]*\) .*$/\1/p' | head -n1)"
  if [ -z "$root" ]; then
    root="$(dirname "$SUBSET_YAML")"
  fi
  printf '%s' "$root/human50"
}

cmd_env() {
  elog "=== 23_eval.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "ckpt:      $CKPT"
  elog "subset:    $SUBSET_YAML"
  elog "out dir:   $OUT_DIR_REAL"
  local rc=0
  env_gate || rc=1
  return "$rc"
}

# --- the benchmark ---------------------------------------------------------
# eval_fail <reason> [detail...]
eval_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "DEPLOY_EVAL_FAIL reason=$reason"
  return 1
}

# cmd_benchmark <interface> <out csv>
cmd_benchmark() {
  local interface="$1" out_path="$2"

  elog "=== 23_eval.sh $interface $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "ckpt:      $CKPT"
  elog "subset:    $SUBSET_YAML"
  elog "out:       $out_path"
  elog "num envs:  $NUM_ENVS"

  # (0) the ENVIRONMENT GATE must pass -- otherwise nothing is benchmarked.
  local gate_tmp gate_rc reason
  gate_tmp="$(mktemp)"
  env_gate >"$gate_tmp" 2>&1
  gate_rc=$?
  {
    printf -- '--- environment gate (rc=%s) ---\n' "$gate_rc"
    cat "$gate_tmp"
  } >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$gate_rc" -ne 0 ]; then
    reason="$(sed -n 's/^DEPLOY_EVAL_ENV_FAIL reason=\([a-z-]*\)$/\1/p' "$gate_tmp" | head -n1)"
    rm -f "$gate_tmp"
    elog "  the environment gate failed: reason=${reason:-unknown}"
    elog "DEPLOY_EVAL_FAIL reason=${reason:-import-failed}"
    return 1
  fi
  rm -f "$gate_tmp"
  elog "  environment gate: PASS"

  # (1) the expected row count is read from the subset yaml.
  local info clips
  info="$(subset_info "$SUBSET_YAML")"
  if [ $? -ne 0 ]; then
    reason="$(printf '%s\n' "$info" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    eval_fail "${reason:-subset-parse-failed}" "PATH=$SUBSET_YAML"
    return 1
  fi
  clips="$(printf '%s\n' "$info" | sed -n 's/^ok .*clips=\([0-9]*\).*$/\1/p' | head -n1)"
  if [ "${clips:-0}" -le 0 ]; then
    eval_fail "subset-parse-failed" "PATH=$SUBSET_YAML"
    return 1
  fi
  elog "  clips in the subset: $clips"

  # (2) the landing spot.
  mkdir -p "$(dirname "$out_path")" 2>/dev/null || true
  if [ ! -d "$(dirname "$out_path")" ]; then
    eval_fail "eval-csv-missing" "PATH=$out_path"
    return 1
  fi
  rm -f "$out_path" 2>/dev/null || true

  # (3) the benchmark itself.
  local extra="" cmd rc out started ended elapsed
  if [ "$interface" = "human" ]; then
    local human_root
    human_root="$(human_root_of "$info")"
    extra="--human-points full --human-root $(printf '%q' "$human_root")"
  fi
  cmd="$(expand_template "$RUN_TEMPLATE" "$interface" "$out_path" "$extra")"
  # A hung benchmark (a GPU stall, a stuck env) must not stall the whole
  # orchestration: the wall clock is bounded and a timeout is reported with
  # its own fixed reason.
  if [ "${TIMEOUT:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    cmd="timeout $TIMEOUT $cmd"
  fi
  started="$(date +%s)"
  elog "  --- the $interface benchmark (timeout=${TIMEOUT:-0}s)"
  out="$(cd "$REPO_ROOT" && eval "$cmd" 2>&1)"
  rc=$?
  ended="$(date +%s)"
  elapsed=$((ended - started))
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    elog "  the benchmark timed out after ${elapsed}s"
    eval_fail "eval-timeout" "command: $cmd"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    elog "  the benchmark command failed (rc=$rc)"
    elog "  $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
    eval_fail "eval-failed" "command: $cmd"
    return 1
  fi
  elog "  the benchmark finished in ${elapsed}s"

  # (4) the CSV is verified by the decision base, and the completion is
  #     recomputed from the "failed" column.
  local check_out
  check_out="$(eval_csv_check "$out_path" "$clips")"
  if [ $? -ne 0 ]; then
    reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
    eval_fail "${reason:-eval-csv-parse-failed}" "csv: $out_path ($check_out)"
    return 1
  fi
  elog "  $check_out"
  local rows failures completion
  rows="$(printf '%s\n' "$check_out" | sed -n 's/^ok clips=\([0-9]*\).*$/\1/p' | head -n1)"
  failures="$(printf '%s\n' "$check_out" | sed -n 's/^ok .*failures=\([0-9]*\).*$/\1/p' | head -n1)"
  completion="$(printf '%s\n' "$check_out" | sed -n 's/^ok .*completion=\([0-9.]*\).*$/\1/p' | head -n1)"

  # (5) the wall clock is kept for the report.
  mkdir -p "$(dirname "$TIMINGS_FILE")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$interface" "$elapsed" "$rows" "$failures" "$completion" \
    >>"$TIMINGS_FILE" 2>/dev/null || true

  elog_ok "DEPLOY_EVAL_OK interface=$interface rows=$rows completion=$completion"
  flush_ok_markers
  return 0
}

# --- report ----------------------------------------------------------------
cmd_report() {
  elog "=== 23_eval.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "DEPLOY_REPORT_SIDE=eval"
  elog "DEPLOY_REPORT_DIR dir=$OUT_DIR_REAL"

  local interface
  for interface in motion human; do
    local csv_path
    if [ "$interface" = "motion" ]; then
      csv_path="$MOTION_OUT"
    else
      csv_path="$HUMAN_OUT"
    fi
    if [ ! -f "$csv_path" ]; then
      elog "DEPLOY_REPORT_EVAL interface=$interface csv=missing"
      continue
    fi
    local info clips check_out rows failures completion
    info="$(subset_info "$SUBSET_YAML")"
    clips="$(printf '%s\n' "$info" | sed -n 's/^ok .*clips=\([0-9]*\).*$/\1/p' | head -n1)"
    check_out="$(eval_csv_check "$csv_path" "${clips:-0}")"
    if [ $? -ne 0 ]; then
      local reason
      reason="$(printf '%s\n' "$check_out" | sed -n 's/^reason=\([a-z-]*\)$/\1/p' | head -n1)"
      elog "DEPLOY_REPORT_EVAL interface=$interface csv=$(rel_to_repo "$csv_path") reason=${reason:-unknown}"
      continue
    fi
    rows="$(printf '%s\n' "$check_out" | sed -n 's/^ok clips=\([0-9]*\).*$/\1/p' | head -n1)"
    failures="$(printf '%s\n' "$check_out" | sed -n 's/^ok .*failures=\([0-9]*\).*$/\1/p' | head -n1)"
    completion="$(printf '%s\n' "$check_out" | sed -n 's/^ok .*completion=\([0-9.]*\).*$/\1/p' | head -n1)"
    elog "DEPLOY_REPORT_EVAL interface=$interface csv=$(rel_to_repo "$csv_path") rows=$rows failures=$failures completion=$completion"
  done

  if [ -f "$TIMINGS_FILE" ]; then
    local interface_s elapsed_s rows_s failures_s completion_s
    while IFS=$'\t' read -r interface_s elapsed_s rows_s failures_s completion_s; do
      [ -n "${interface_s:-}" ] || continue
      elog "DEPLOY_REPORT_WALLCLOCK interface=$interface_s seconds=$elapsed_s rows=$rows_s failures=$failures_s completion=$completion_s"
    done <"$TIMINGS_FILE"
  else
    elog "DEPLOY_REPORT_WALLCLOCK interface=none seconds=0 rows=0 failures=0 completion=0"
  fi
  elog "DEPLOY_REPORT_OK=1"
  return 0
}

# --- selftest --------------------------------------------------------------
cmd_selftest() {
  elog "=== 23_eval.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  eval "$SELFTEST_CMD"
  return $?
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  motion|human)
            sub="$1"; shift || true
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --subset-yaml) SUBSET_YAML="${2:-}"; shift 2 ;;
                --subset-yaml=*) SUBSET_YAML="${1#*=}"; shift ;;
                --out) if [ "$sub" = "motion" ]; then MOTION_OUT="${2:-}"; else HUMAN_OUT="${2:-}"; fi; shift 2 ;;
                --out=*) if [ "$sub" = "motion" ]; then MOTION_OUT="${1#*=}"; else HUMAN_OUT="${1#*=}"; fi; shift ;;
                --num-envs) NUM_ENVS="${2:-0}"; shift 2 ;;
                --num-envs=*) NUM_ENVS="${1#*=}"; shift ;;
                *) echo "23_eval.sh: unknown option: $1" >&2; exit 2 ;;
              esac
            done
            if [ "$sub" = "motion" ]; then
              cmd_benchmark motion "$MOTION_OUT"
            else
              cmd_benchmark human "$HUMAN_OUT"
            fi
            ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/23_eval.sh <env|motion|human|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
