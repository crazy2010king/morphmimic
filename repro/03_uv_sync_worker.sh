#!/usr/bin/env bash
# repro/03_uv_sync_worker.sh — the BACKGROUND body of the uv environment sync.
#
# Why a separate worker: `uv sync --frozen` downloads GBs of wheels (torch
# 2.11.0+cu128 + the nvidia-* stack) through the proxy. A previous attempt ran
# it in the foreground of a single ssh call; when the session budget ran out,
# the whole call died with the log stuck at the `### RUN ... uv sync --frozen`
# banner (no EXIT line, no result). This worker is started detached
# (setsid/nohup, see uvsync_run_detached) and therefore survives the session
# that launched it; the caller only ever runs short, cheap commands
# (`03_uv_sync.sh start|status|wait|verify`) that read a status file.
#
# The worker's stdout/stderr are appended to logs/env/03_uv_sync.txt by the
# detached runner, so this script only PRINTS — it must never tee a second
# copy of the output into the same log.
#
# Terminal state is written to logs/env/03_uv_sync.status:
#   STATE=DONE|FAILED
#   RC=<exit code>
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it is
# never written to any system configuration.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
require_container
# shellcheck source=lib/uvsync.sh
source "$_SCRIPT_DIR/lib/uvsync.sh"

cd "$REPO_ROOT"

MAIN_LOG="$LOG_DIR/03_uv_sync.txt"
STATUS_FILE="$LOG_DIR/03_uv_sync.status"

# uv's own network knobs: the wheels are large and the proxy path is flaky,
# so a single stalled read must not abort the whole sync.
export UV_HTTP_TIMEOUT=600
export UV_HTTP_RETRIES=5

# --- output helpers --------------------------------------------------------
# Everything goes to stdout; the detached runner redirects stdout into
# MAIN_LOG. Using tee here would duplicate every line in the log.
wlog() { echo "$*"; }

# wrun <cmd...> — run a command with RUN/EXIT banners, like run_logged but
# without the second (tee'd) copy of the output.
wrun() {
  local rc=0
  echo "### RUN $(date -u +%Y-%m-%dT%H:%M:%SZ): $*"
  set +e
  "$@"
  rc=$?
  set -e
  echo "### EXIT $rc: $*"
  return $rc
}

finish() {
  local state="$1" rc="$2"
  printf 'STATE=%s\nRC=%s\nFINISHED_AT=%s\n' \
    "$state" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATUS_FILE.tmp" \
    && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

fail() {
  wlog "ERROR: $*"
  finish FAILED 1
  exit 1
}

wlog "=== 03_uv_sync_worker.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
wlog "REPO_ROOT=$REPO_ROOT"
wlog "proxy(inline, process-scoped)=$PROXY"
wlog "uv_version=$(uv --version 2>&1)"
wlog "UV_HTTP_TIMEOUT=$UV_HTTP_TIMEOUT UV_HTTP_RETRIES=$UV_HTTP_RETRIES"
wlog ""

# ---------------------------------------------------------------------------
# 1) Python 3.11: probe the uv-managed interpreter first, download only when
#    it is genuinely absent (pyproject pins requires-python = "==3.11.*").
# ---------------------------------------------------------------------------
wlog "--- step 1: managed CPython 3.11 ---"
if managed_path="$(uvsync_managed_python_path 3.11)"; then
  wlog "    managed cpython-3.11 already present: $managed_path"
  wlog "    managed_python: $managed_path"
  wlog "    PYTHON_DOWNLOAD_SKIPPED"
else
  wlog "    no uv-managed cpython-3.11 found -> downloading"
  t0=$(date +%s)
  if ! wrun uv python install 3.11; then
    fail "'uv python install 3.11' failed"
  fi
  t1=$(date +%s)
  wlog "    download took $((t1 - t0))s"
  if ! managed_path="$(uvsync_managed_python_path 3.11)"; then
    fail "no uv-managed cpython-3.11 available after install"
  fi
  wlog "    managed_python: $managed_path"
  wlog "    PYTHON_DOWNLOAD_DONE"
fi
wlog "### STEP managed_python DONE"
wlog ""

# ---------------------------------------------------------------------------
# 2) uv sync --frozen (default dependency groups).
#    --no-progress keeps the progress bar out of the NFS log; the wheel
#    downloads still show up as uv's own log lines.
# ---------------------------------------------------------------------------
wlog "--- step 2: uv sync --frozen ---"
t0=$(date +%s)
if ! wrun env UV_HTTP_TIMEOUT=600 UV_HTTP_RETRIES=5 uv sync --frozen --no-progress; then
  fail "'uv sync --frozen' failed (see the uv output above)"
fi
t1=$(date +%s)
wlog "    uv sync --frozen took $((t1 - t0))s"
wlog "### STEP uv_sync_frozen DONE"
wlog ""

# ---------------------------------------------------------------------------
# 3) uv sync --frozen --group export --group teleop
#    The teleop group pulls general-motion-retargeting (workspace member
#    third_party/GMR) -> only works after 02_submodules.sh landed it.
# ---------------------------------------------------------------------------
wlog "--- step 3: uv sync --frozen --group export --group teleop ---"
t0=$(date +%s)
if ! wrun env UV_HTTP_TIMEOUT=600 UV_HTTP_RETRIES=5 \
        uv sync --frozen --group export --group teleop --no-progress; then
  fail "'uv sync --frozen --group export --group teleop' failed (see the uv output above)"
fi
t1=$(date +%s)
wlog "    grouped uv sync took $((t1 - t0))s"
wlog "### STEP uv_sync_groups DONE"
wlog ""

# ---------------------------------------------------------------------------
# 4) venv location assertion: <repo>/.venv must exist and be inside the root
#    (deploy/install_pico.sh calls `.venv/bin/python` by that exact path).
# ---------------------------------------------------------------------------
wlog "--- step 4: venv location assertion ---"
if ! uvsync_check_venv "$REPO_ROOT"; then
  fail "venv assertion failed (expected $REPO_ROOT/.venv/bin/python)"
fi
wlog "    venv is inside the worktree root"
wlog "### STEP venv_location DONE"
wlog ""

# ---------------------------------------------------------------------------
# 5) Import + CUDA self-check.
#    Importing morphmimic registers its mjlab tasks -> proves the package
#    itself is importable, not just its dependencies.
#    --no-sync: the environment was just synced; re-resolving would be a
#    second, pointless network round trip.
# ---------------------------------------------------------------------------
wlog "--- step 5: import + CUDA self-check ---"
SELFCHECK='
import torch, mjlab, warp, morphmimic
print("TORCH_VERSION_" + torch.__version__)
print("TORCH_CUDA_" + str(torch.version.cuda))
# torch.cuda.is_available() returns a Python bool -> "True"/"False".
# The marker contract (plan + verify command) demands the uppercase form
# "CUDA_AVAILABLE_TRUE", so normalise it here.
print("CUDA_AVAILABLE_" + str(torch.cuda.is_available()).upper())
if torch.cuda.is_available():
    print("CUDA_DEVICE_" + torch.cuda.get_device_name(0))
# mjlab does not expose __version__; the installed distribution metadata does
# (mjlab 1.6.0), so ask importlib first and fall back to the attribute.
try:
    from importlib.metadata import version as _dist_version
    _mjlab_version = _dist_version("mjlab")
except Exception:
    _mjlab_version = getattr(mjlab, "__version__", "unknown")
print("MJLAB_VERSION_" + str(_mjlab_version))
print("WARP_VERSION_" + str(warp.__version__))
'
if ! selfcheck_out="$(uv run --frozen --no-sync python -c "$SELFCHECK" 2>&1)"; then
  echo "$selfcheck_out"
  fail "import/CUDA self-check failed"
fi
echo "$selfcheck_out"
echo "### EXIT 0: uv run --frozen --no-sync python -c <selfcheck>"

# Assert on the CAPTURED output (the in-memory truth), not on the log file.
missing=0
for m in "TORCH_VERSION_2.11.0+cu128" "CUDA_AVAILABLE_TRUE" "CUDA_DEVICE_NVIDIA GeForce RTX 4090"; do
  if ! printf '%s\n' "$selfcheck_out" | grep -qF -- "$m"; then
    wlog "ERROR: self-check output is missing: $m"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  fail "import/CUDA self-check did not report the expected facts"
fi
wlog "    self-check reported torch 2.11.0+cu128 on an RTX 4090"
wlog "### STEP import_cuda_selfcheck DONE"
wlog ""

# ---------------------------------------------------------------------------
# 6) GPU cross-check via nvidia-smi (independent of torch).
# ---------------------------------------------------------------------------
wlog "--- step 6: nvidia-smi cross-check ---"
if ! wrun nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv; then
  fail "nvidia-smi cross-check failed"
fi
wlog "### STEP nvidia_smi DONE"
wlog ""

# ---------------------------------------------------------------------------
# 7) Marker assertions over the log file that the caller will grep, plus the
#    uv cache facts T6/S09 need.
# ---------------------------------------------------------------------------
wlog "--- step 7: marker assertions ---"
if ! uvsync_require_log_markers "$MAIN_LOG" \
      "TORCH_VERSION_2.11.0+cu128" \
      "CUDA_AVAILABLE_TRUE" \
      "CUDA_DEVICE_NVIDIA GeForce RTX 4090"; then
  fail "expected markers missing from $MAIN_LOG"
fi
wlog "    all expected markers present"

cache_dir="$(uv cache dir 2>&1 || echo '<unknown>')"
cache_size="$(du -sh "$cache_dir" 2>/dev/null | cut -f1 || echo '<unknown>')"
wlog "UV_CACHE_DIR=$cache_dir"
wlog "UV_CACHE_SIZE=$cache_size"
wlog "### STEP marker_assertions DONE"
wlog ""

wlog "UV_SYNC_OK"
finish DONE 0
exit 0
