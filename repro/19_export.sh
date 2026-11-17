#!/usr/bin/env bash
# repro/19_export.sh — the ONNX EXPORT ORCHESTRATOR of the g1_amber export
# (slice S07, task T3).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# The upstream exporter `python -m deploy.export_onnx` writes in this order:
#
#   1. _export_onnx()  -> writes policy.onnx into out_dir
#   2. the parity probe -> raises ValueError when |ONNX - PyTorch| > 1e-4
#
# So a parity failure LEAVES A HALF-FINISHED policy.onnx behind in out_dir,
# while the milestone contract (R012) demands "a rejected export produces NO
# file".  The upstream does not implement that contract, so this script does:
#
#   export into a STAGING directory -> verify the staging directory with the
#   decision base -> publish atomically (rename) into the formal landing spot
#   out/g1_amber.  Every failure path deletes the staging directory and
#   leaves the formal landing spot UNTOUCHED.
#
# The export is also chained behind the S06 follow-up: `18_train_verify.sh
# verify` runs as an AUTOMATIC PRECONDITION GATE before the export, so a
# broken training artefact can never be exported.
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   env      the fail-closed ENVIRONMENT GATE (seconds, no GPU, no network):
#            the venv imports torch / onnx / onnxruntime, the source
#            checkpoint exists AND torch.load()s, the landing directory is
#            writable.  Success prints ONE line
#                EXPORT_ENV_OK python=<v> torch=<v> onnx=<v> \
#                       onnxruntime=<v> onnxscript=<v> ckpt=<path>
#            failure prints ONE line
#                EXPORT_ENV_FAIL reason=<fixed reason set>
#            and exits non-zero.  The OK marker is BUFFERED and flushed only
#            when EVERY check passed (project convention P004).
#
#   export   the pipeline:
#              1. the precondition gate (18_train_verify.sh verify) MUST pass
#                 -- otherwise nothing is exported at all,
#              2. the upstream exporter writes into the staging directory,
#              3. the decision base (repro/lib/export.py) verifies the staging
#                 directory (4 artefacts, parity <= atol, digests recomputed),
#              4. only then the staging directory is renamed into the formal
#                 landing spot out/g1_amber.
#            Success prints ONE line
#                EXPORT_EXPORT_OK out=<dir> files=4 parity_max=<v>
#            failure prints ONE line
#                EXPORT_EXPORT_FAIL reason=<fixed reason set>
#            plus the negative-event marker EXPORT_NEG_FAIL reason=<r>
#            (every export failure IS a negative event and is marked as one).
#            Extra arguments are forwarded to the upstream exporter, e.g.
#                bash repro/19_export.sh export --goal-anchor robot
#            (which must fail: the checkpoint was trained with reference).
#
#   report   the EXPORT-SIDE self report (the INDEPENDENT reviewer is
#            repro/20_export_verify.sh report -- its EXPORT_REPORT_* lines
#            are the ones the documentation quotes).  This side is labelled
#            EXPORT_REPORT_SIDE=export so the two can never be confused.
#
#   selftest the offline battery: repro/tests/test_export_orchestrator.sh.
#
# ---------------------------------------------------------------------------
# THE FIXED REASON SETS (greppable)
#
#   env gate:      interpreter-missing  import-failed  ckpt-missing
#                  ckpt-unloadable      out-not-writable
#   export gate:   ckpt-verify-failed   export-failed
#                  staging-verify-failed publish-failed
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES (every one of them exists so the offline fixture
# battery can drive the orchestrator without the container, without torch and
# without the real export)
#
#   EXPORT_ALLOW_LOCAL=1   allow running outside the ros_dev container
#   EXPORT_CKPT            source checkpoint
#                           (default logs/train/g1_amber_1h/ckpt_26413.pt)
#   EXPORT_OUT_DIR         formal landing spot (default out/g1_amber)
#   EXPORT_STAGING_DIR     staging directory (default out/.staging-<pid>/<robot>)
#   EXPORT_CKPT_VERIFY_CMD the precondition gate
#                           (default bash repro/18_train_verify.sh verify)
#   EXPORT_EXPORT_CMD      the upstream command (default:
#                           uv run --frozen --no-sync --group export python
#                           -m deploy.export_onnx <ckpt>)
#   EXPORT_ENV_IMPORT_CMD  the import probe (default "<venv python> -")
#   EXPORT_ENV_CKPT_CMD    the checkpoint probe (default "<venv python> -")
#   EXPORT_VENV_PY         the venv interpreter (default .venv/bin/python)
#   EXPORT_UV_BIN          uv binary (default uv)
#   EXPORT_UV_ARGS         uv arguments (default run --frozen --no-sync
#                          --group export)
#   EXPORT_ROBOT           robot name (default g1_amber)
#   EXPORT_ATOL            parity tolerance (default 1e-4)
#   EXPORT_LOG_DIR         log directory (default $LOG_DIR)
#   EXPORT_PY              the decision-base interpreter (default python3)
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it
# is never written to any system configuration.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/export.sh
source "$_SCRIPT_DIR/lib/export.sh"

# common.sh turns on `set -e`.  Every failure path below is handled
# explicitly (each gate prints its own fail marker and returns 1), so
# errexit is disabled here (the 17_train.sh / 20_export_verify.sh convention).
set +e

if [ "${EXPORT_ALLOW_LOCAL:-0}" != "1" ]; then
  require_container
fi

# --- configuration ---------------------------------------------------------
LOG_DIR_REAL="${EXPORT_LOG_DIR:-$LOG_DIR}"
LOG_DIR_REAL="$(readlink -f "$LOG_DIR_REAL" 2>/dev/null || printf '%s' "$LOG_DIR_REAL")"
MAIN_LOG="$LOG_DIR_REAL/19_export.txt"

ROBOT="${EXPORT_ROBOT:-g1_amber}"
ATOL="${EXPORT_ATOL:-1e-4}"
CKPT="${EXPORT_CKPT:-$REPO_ROOT/logs/train/g1_amber_1h/ckpt_26413.pt}"
# The probes read the checkpoint from the environment, so the override and
# the probe can never disagree.
export EXPORT_CKPT="$CKPT"
OUT_DIR="${EXPORT_OUT_DIR:-$REPO_ROOT/out/$ROBOT}"
STAGING_DIR="${EXPORT_STAGING_DIR:-$REPO_ROOT/out/.staging-$$/$ROBOT}"
# Only a staging directory that WE created may have its parent removed.
STAGING_OWNED=0
[ -n "${EXPORT_STAGING_DIR:-}" ] || STAGING_OWNED=1

UV_BIN="${EXPORT_UV_BIN:-uv}"
UV_ARGS="${EXPORT_UV_ARGS:-run --frozen --no-sync --group export}"
CKPT_VERIFY_CMD="${EXPORT_CKPT_VERIFY_CMD:-bash $REPO_ROOT/repro/18_train_verify.sh verify}"
SELFTEST_CMD="${EXPORT_SELFTEST_CMD:-bash $REPO_ROOT/repro/tests/test_export_orchestrator.sh}"

# The upstream command.  The staging directory is appended at call time.
EXPORT_CMD="${EXPORT_EXPORT_CMD:-$UV_BIN $UV_ARGS python -m deploy.export_onnx $(printf '%q' "$CKPT")}"

mkdir -p "$LOG_DIR_REAL" 2>/dev/null || true

usage() {
  cat <<EOF
usage: bash repro/19_export.sh <subcommand>

  env       the fail-closed environment gate (EXPORT_ENV_OK / EXPORT_ENV_FAIL)
  export    precondition gate -> staging export -> verify -> atomic publish
            (EXPORT_EXPORT_OK / EXPORT_EXPORT_FAIL reason=...)
  report    the export-side self report (EXPORT_REPORT_SIDE=export)
  selftest  the offline battery (repro/tests/test_export_orchestrator.sh)

ckpt:      $CKPT
out dir:   $OUT_DIR
staging:   $STAGING_DIR
log:       $MAIN_LOG
EOF
}

# --- output ----------------------------------------------------------------
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

# neg_fail <reason> — every export failure is a negative event and is marked
# as one, so the log of a failed run can be grepped for EXPORT_NEG_FAIL.
neg_fail() { elog "EXPORT_NEG_FAIL reason=$1"; return 0; }

# --- the probes ------------------------------------------------------------
# The probe source is piped into the probe command on STDIN (python reads a
# program from stdin), so no inline `-c` program has to survive the quoting.
IMPORT_PROBE_SRC=$(cat <<'PY'
import sys
import torch
import onnx
import onnxruntime
print("PY_VERSION=" + sys.version.split()[0])
print("TORCH_VERSION=" + str(torch.__version__))
print("ONNX_VERSION=" + str(getattr(onnx, "__version__", "unknown")))
print("ONNXRUNTIME_VERSION=" + str(getattr(onnxruntime, "__version__", "unknown")))
print("ONNXSCRIPT_VERSION=" + str(getattr(__import__("onnxscript"), "__version__", "unknown")))
PY
)

CKPT_PROBE_SRC=$(cat <<'PY'
import os
import torch
path = os.environ["EXPORT_CKPT"]
obj = torch.load(path, map_location="cpu", weights_only=False)
data = obj if isinstance(obj, dict) else getattr(obj, "__dict__", {})
it = data.get("iteration", "") if hasattr(data, "get") else ""
print("CKPT_ITERATION=" + str(it))
print("CKPT_LOADED=1")
PY
)

# venv_python — the interpreter that owns torch / onnx / onnxruntime.
venv_python() {
  if [ -n "${EXPORT_VENV_PY:-}" ]; then printf '%s' "$EXPORT_VENV_PY"; return 0; fi
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then printf '%s' "$REPO_ROOT/.venv/bin/python"; return 0; fi
  printf '%s' "$UV_BIN $UV_ARGS python"
}

# import_probe_cmd / ckpt_probe_cmd — the command that runs a probe.
import_probe_cmd() {
  if [ -n "${EXPORT_ENV_IMPORT_CMD:-}" ]; then printf '%s' "$EXPORT_ENV_IMPORT_CMD"; return 0; fi
  printf '%s -' "$(venv_python)"
}

ckpt_probe_cmd() {
  if [ -n "${EXPORT_ENV_CKPT_CMD:-}" ]; then printf '%s' "$EXPORT_ENV_CKPT_CMD"; return 0; fi
  printf '%s -' "$(venv_python)"
}

# run_probe <cmd> <source> — feeds the probe source into the command and
# echoes its output.  The exit code is the command's exit code.
run_probe() {
  local cmd="$1" src="$2" out rc
  out="$(printf '%s\n' "$src" | eval "$cmd" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return $rc
}

# --- env gate --------------------------------------------------------------
# env_fail <reason> [detail...] — the ONLY failure exit of the gate: it
# prints the fail marker (and the details) and returns 1.  It NEVER prints an
# OK marker.
env_fail() {
  local reason="$1"; shift || true
  local detail
  for detail in "$@"; do
    [ -n "$detail" ] && elog "  $detail"
  done
  elog "EXPORT_ENV_FAIL reason=$reason"
  return 1
}

env_gate() {
  local interp first
  interp="$(venv_python)"
  first="${interp%% *}"
  # The interpreter check applies to the DEFAULT probe and to an explicitly
  # requested interpreter; a fixture that brings its own probe command owns
  # its own interpreter.
  if [ -n "${EXPORT_VENV_PY:-}" ] || [ -z "${EXPORT_ENV_IMPORT_CMD:-}" ]; then
    if ! command -v "$first" >/dev/null 2>&1 && [ ! -x "$first" ]; then
      env_fail "interpreter-missing" \
        "interpreter=$interp" \
        "fix: uv sync --frozen --offline --group export" || return 1
      return 1
    fi
  fi

  # (1) torch / onnx / onnxruntime / onnxscript must import.
  local probe_out probe_rc
  probe_out="$(run_probe "$(import_probe_cmd)" "$IMPORT_PROBE_SRC")"
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    env_fail "import-failed" \
      "interpreter=$interp" \
      "probe: $(printf '%s\n' "$probe_out" | tail -n 3 | tr '\n' ' ')" || return 1
    return 1
  fi

  # (2) the source checkpoint must exist.
  if [ ! -f "$CKPT" ]; then
    env_fail "ckpt-missing" "PATH=$CKPT" || return 1
    return 1
  fi

  # (3) ... and it must torch.load().
  local ckpt_out ckpt_rc
  ckpt_out="$(run_probe "$(ckpt_probe_cmd)" "$CKPT_PROBE_SRC")"
  ckpt_rc=$?
  if [ "$ckpt_rc" -ne 0 ]; then
    env_fail "ckpt-unloadable" \
      "PATH=$CKPT" \
      "probe: $(printf '%s\n' "$ckpt_out" | tail -n 3 | tr '\n' ' ')" || return 1
    return 1
  fi

  # (4) the landing spot must be writable (its parent must be creatable).
  local parent
  parent="$(dirname "$OUT_DIR")"
  if ! mkdir -p "$parent" 2>/dev/null; then
    env_fail "out-not-writable" \
      "PATH=$parent" \
      "fix: SEED_WORKTREE=<worktree> bash repro/lib/seed_store.sh link" || return 1
    return 1
  fi
  if [ ! -w "$parent" ]; then
    env_fail "out-not-writable" \
      "PATH=$parent" \
      "fix: SEED_WORKTREE=<worktree> bash repro/lib/seed_store.sh link" || return 1
    return 1
  fi

  local python_version="" torch_version="" onnx_version="" ort_version="" script_version=""
  python_version="$(printf '%s\n' "$probe_out" | sed -n 's/^PY_VERSION=//p' | head -n1)"
  torch_version="$(printf '%s\n' "$probe_out" | sed -n 's/^TORCH_VERSION=//p' | head -n1)"
  onnx_version="$(printf '%s\n' "$probe_out" | sed -n 's/^ONNX_VERSION=//p' | head -n1)"
  ort_version="$(printf '%s\n' "$probe_out" | sed -n 's/^ONNXRUNTIME_VERSION=//p' | head -n1)"
  script_version="$(printf '%s\n' "$probe_out" | sed -n 's/^ONNXSCRIPT_VERSION=//p' | head -n1)"

  elog_ok "EXPORT_ENV_OK python=$python_version torch=$torch_version onnx=$onnx_version onnxruntime=$ort_version onnxscript=$script_version ckpt=$CKPT"
  flush_ok_markers
  return 0
}

cmd_env() {
  elog "=== 19_export.sh env $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "ckpt:     $CKPT"
  elog "out dir:  $OUT_DIR"
  local rc=0
  env_gate || rc=1
  return "$rc"
}

# --- export ----------------------------------------------------------------
# cleanup_staging — remove the staging directory (and, when we created it,
# its now empty parent).  The formal landing spot is NEVER touched here.
cleanup_staging() {
  rm -rf "$STAGING_DIR" 2>/dev/null || true
  if [ "$STAGING_OWNED" = "1" ]; then
    rmdir "$(dirname "$STAGING_DIR")" 2>/dev/null || true
  fi
}

# staging_check — verify the staging directory with the decision base
# (repro/lib/export.py).  The decision base prints its own OK marker; the
# orchestrator NEVER forwards it (one gate, one marker: this script's gate
# marker is EXPORT_EXPORT_OK).  Returns 0 on success and sets
# STAGING_FILES / STAGING_PARITY_MAX.
STAGING_FILES=""
STAGING_PARITY_MAX=""
STAGING_OUT=""

staging_check() {
  local dir="$1" rc okline
  STAGING_OUT="$(export_run verify --out-dir "$dir" --robot "$ROBOT" --atol "$ATOL" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  okline="$(printf '%s\n' "$STAGING_OUT" | grep '^EXPORT_VERIFY_OK ' | head -n1)"
  if [ -z "$okline" ]; then
    return 1
  fi
  STAGING_FILES="$(printf '%s\n' "$okline" | sed -n 's/^EXPORT_VERIFY_OK files=\([0-9]*\).*/\1/p')"
  STAGING_PARITY_MAX="$(printf '%s\n' "$okline" | sed -n 's/.* parity_max=\([^ ]*\).*/\1/p')"
  return 0
}

cmd_export() {
  elog "=== 19_export.sh export $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "ckpt:      $CKPT"
  elog "out dir:   $OUT_DIR"
  elog "staging:   $STAGING_DIR"

  # (0) the PRECONDITION GATE: the training artefacts must still verify.
  local gate_tmp gate_rc
  gate_tmp="$(mktemp)"
  eval "$CKPT_VERIFY_CMD" >"$gate_tmp" 2>&1
  gate_rc=$?
  {
    printf -- '--- precondition gate: %s (rc=%s) ---\n' "$CKPT_VERIFY_CMD" "$gate_rc"
    cat "$gate_tmp"
  } >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$gate_rc" -ne 0 ]; then
    rm -f "$gate_tmp"
    elog "  the precondition gate failed: $CKPT_VERIFY_CMD"
    elog "EXPORT_EXPORT_FAIL reason=ckpt-verify-failed"
    neg_fail "ckpt-verify-failed"
    return 1
  fi
  rm -f "$gate_tmp"
  elog "  precondition gate: PASS ($CKPT_VERIFY_CMD)"

  # (1) the staging directory.
  if ! mkdir -p "$(dirname "$STAGING_DIR")" 2>/dev/null; then
    elog "EXPORT_EXPORT_FAIL reason=publish-failed"
    elog "  staging root is not creatable: $(dirname "$STAGING_DIR")"
    neg_fail "publish-failed"
    return 1
  fi
  rm -rf "$STAGING_DIR" 2>/dev/null || true
  if ! mkdir -p "$STAGING_DIR" 2>/dev/null; then
    elog "EXPORT_EXPORT_FAIL reason=publish-failed"
    elog "  staging directory is not creatable: $STAGING_DIR"
    neg_fail "publish-failed"
    return 1
  fi

  # (2) the upstream export.
  local cmd out rc
  cmd="$EXPORT_CMD $(printf '%q' "$STAGING_DIR")"
  local a
  for a in "$@"; do cmd="$cmd $(printf '%q' "$a")"; done
  elog "  upstream command: $cmd"
  out="$(eval "$cmd" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >>"$MAIN_LOG" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    elog "  the upstream exporter failed (rc=$rc)"
    cleanup_staging
    elog "EXPORT_EXPORT_FAIL reason=export-failed"
    neg_fail "export-failed"
    return 1
  fi

  # (3) the staging directory must pass EVERY gate before it is published.
  local reason
  staging_check "$STAGING_DIR"
  if [ "$?" -ne 0 ]; then
    reason="$(printf '%s\n' "$STAGING_OUT" | sed -n 's/^EXPORT_VERIFY_FAIL reason=\([a-z-]*\).*$/\1/p' | head -n1)"
    elog "  the staging directory was rejected: reason=${reason:-unknown}"
    printf '%s\n' "$STAGING_OUT" >>"$MAIN_LOG" 2>/dev/null || true
    cleanup_staging
    elog "EXPORT_EXPORT_FAIL reason=staging-verify-failed"
    neg_fail "staging-verify-failed"
    return 1
  fi
  elog "  staging verified: files=$STAGING_FILES parity_max=$STAGING_PARITY_MAX"

  # (4) the ATOMIC PUBLISH: the landing spot is replaced by a rename.
  # The parent of the landing spot must exist (the export never creates the
  # landing spot itself -- only its parent).
  if ! mkdir -p "$(dirname "$OUT_DIR")" 2>/dev/null; then
    cleanup_staging
    elog "EXPORT_EXPORT_FAIL reason=publish-failed"
    elog "  the landing spot parent is not creatable: $(dirname "$OUT_DIR")"
    neg_fail "publish-failed"
    return 1
  fi
  local trash=""
  if [ -e "$OUT_DIR" ] || [ -L "$OUT_DIR" ]; then
    trash="$OUT_DIR.trash.$$"
    if ! mv "$OUT_DIR" "$trash" 2>/dev/null; then
      cleanup_staging
      elog "EXPORT_EXPORT_FAIL reason=publish-failed"
      elog "  the previous landing spot could not be moved aside: $OUT_DIR"
      neg_fail "publish-failed"
      return 1
    fi
  fi
  if ! mv "$STAGING_DIR" "$OUT_DIR" 2>/dev/null; then
    if [ -n "$trash" ]; then mv "$trash" "$OUT_DIR" 2>/dev/null || true; fi
    cleanup_staging
    elog "EXPORT_EXPORT_FAIL reason=publish-failed"
    elog "  the staging directory could not be published: $STAGING_DIR -> $OUT_DIR"
    neg_fail "publish-failed"
    return 1
  fi
  [ -n "$trash" ] && rm -rf "$trash" 2>/dev/null || true
  if [ "$STAGING_OWNED" = "1" ]; then
    rmdir "$(dirname "$STAGING_DIR")" 2>/dev/null || true
  fi

  # (5) the published landing spot must still pass the gate.
  if ! staging_check "$OUT_DIR" >/dev/null 2>&1; then
    elog "EXPORT_EXPORT_FAIL reason=publish-failed"
    elog "  the published landing spot does not verify: $OUT_DIR"
    neg_fail "publish-failed"
    return 1
  fi

  elog_ok "EXPORT_EXPORT_OK out=$OUT_DIR files=$STAGING_FILES parity_max=$STAGING_PARITY_MAX"
  flush_ok_markers
  return 0
}

# --- report (the export-side self report) ----------------------------------
cmd_report() {
  elog "=== 19_export.sh report $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  elog "EXPORT_REPORT_SIDE=export"
  elog "EXPORT_REPORT_OUT dir=$OUT_DIR"
  elog "EXPORT_REPORT_CKPT path=$CKPT"
  elog "EXPORT_REPORT_COMMAND cmd=$EXPORT_CMD"
  elog "EXPORT_REPORT_STAGING dir=$STAGING_DIR"
  local count=0 f bytes
  for f in policy.onnx "$ROBOT.json" MANIFEST.txt SHA256SUMS; do
    if [ -f "$OUT_DIR/$f" ]; then
      bytes="$(wc -c <"$OUT_DIR/$f" 2>/dev/null | tr -d ' ')"
      elog "EXPORT_REPORT_FILE file=$f bytes=$bytes"
      count=$((count + 1))
    fi
  done
  elog "EXPORT_REPORT_FILES count=$count"
  if [ -d "$OUT_DIR" ]; then
    elog "EXPORT_REPORT_PUBLISHED=1"
  else
    elog "EXPORT_REPORT_PUBLISHED=0"
  fi
  elog "EXPORT_REPORT_OK=1"
  return 0
}

# --- selftest --------------------------------------------------------------
cmd_selftest() {
  elog "=== 19_export.sh selftest $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  eval "$SELFTEST_CMD"
  return $?
}

case "${1:-}" in
  env)      shift || true; cmd_env "$@" ;;
  export)   shift || true; cmd_export "$@" ;;
  report)   shift || true; cmd_report "$@" ;;
  selftest) shift || true; cmd_selftest "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "usage: bash repro/19_export.sh <env|export|report|selftest>" >&2
    usage >&2
    exit 2
    ;;
esac
