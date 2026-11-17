#!/usr/bin/env bash
# repro/lib/uvsync.sh — helpers for repro/03_uv_sync.sh.
#
# Split out of the script itself so that the decision logic can be unit
# tested (repro/tests/test_uv_sync.sh) without network, GPU or a real venv.
#
# Measured container facts this file relies on:
#   * the container's system python is 3.10/3.12, but pyproject.toml pins
#     requires-python = "==3.11.*";
#   * uv 0.12.6 already manages cpython-3.11.16 under
#     /root/.local/share/uv/python/, so `uv python install 3.11` is a no-op
#     (no download) as long as we detect it first;
#   * the venv MUST live at <repo>/.venv because deploy/install_pico.sh calls
#     `.venv/bin/python` by that exact relative path.

# --- managed python detection ----------------------------------------------
#
# uvsync_managed_python_path <version>
#
# Prints the path of a *uv-managed* CPython <version> and returns 0.
# Returns 1 when no such interpreter is available.
#
# "Managed" means it lives under a uv python root
# (<...>/share/uv/python/... or <...>/uv/python/...); a system interpreter
# (e.g. /usr/bin/python3) does NOT count, because the plan requires the
# managed cpython-3.11 to be used rather than downloading a second copy.
#
# Search-root override (test seam, see MEM021):
#   UV_PYTHON_SEARCH_ROOTS  colon-separated list of uv python install roots.
#                           When it is set (non-empty) it REPLACES the default
#                           roots for the glob fallback only. When it is unset
#                           the behaviour is byte-for-byte the S01 behaviour:
#                             ${UV_PYTHON_INSTALL_DIR:-$HOME/.local/share/uv/python}
#                             $HOME/.local/share/uv/python
#                             /root/.local/share/uv/python
#                           (the second entry is only present when
#                           UV_PYTHON_INSTALL_DIR overrides the first one —
#                           the historical order is preserved exactly).
# The override exists so the unit tests can prove "a system interpreter does
# not count as managed" on a machine that really does have a managed
# interpreter installed (e.g. the ros_dev container), without changing any
# production default.
uvsync_python_search_roots() {
  local roots="${UV_PYTHON_SEARCH_ROOTS:-}"
  if [ -n "$roots" ]; then
    local rest="$roots" part
    while [ -n "$rest" ]; do
      part="${rest%%:*}"
      if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
      [ -n "$part" ] && printf '%s\n' "$part"
    done
    return 0
  fi
  if [ -n "${UV_PYTHON_INSTALL_DIR:-}" ]; then
    printf '%s\n' "$UV_PYTHON_INSTALL_DIR"
    printf '%s\n' "$HOME/.local/share/uv/python"
  else
    printf '%s\n' "$HOME/.local/share/uv/python"
  fi
  printf '%s\n' "/root/.local/share/uv/python"
}

uvsync_managed_python_path() {
  local version="$1"
  local found=""
  found="$(uv python find "$version" 2>/dev/null || true)"
  if [ -n "$found" ] && [ -x "$found" ]; then
    case "$found" in
      */share/uv/python/*|*/uv/python/*)
        printf '%s\n' "$found"; return 0 ;;
    esac
    # `uv python find` may hand back a *shim* from ~/.local/bin (that is what
    # `uv python install` creates). The shim is not the interpreter itself and
    # does not live under a uv python root -> fall through to the fallbacks.
  fi

  # Fallback 1: ask uv for the installed interpreters and pick the managed one.
  # `uv` may be missing entirely or may fail; in both cases this must yield an
  # EMPTY result instead of aborting the caller under `set -e`.
  local installed=""
  if command -v uv >/dev/null 2>&1; then
    installed="$(uv python list --only-installed 2>/dev/null || true)"
  fi
  local line p
  while IFS= read -r line; do
    for p in $line; do
      case "$p" in
        */share/uv/python/*|*/uv/python/*)
          case "$p" in
            *cpython-$version*) printf '%s\n' "$p"; return 0 ;;
          esac
          ;;
      esac
    done
  done <<<"$installed"

  # Fallback 2: glob the uv python install roots directly.
  local base cand
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    for cand in "$base"/cpython-$version*/bin/python3.11 "$base"/cpython-$version*/bin/python3; do
      if [ -x "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
    done
  done < <(uvsync_python_search_roots)
  return 1
}

# uvsync_requires_managed_python <version>
#
# 0 when a managed interpreter for <version> must be DOWNLOADED
# (i.e. none is present yet), 1 when it already exists and the download
# can be skipped.
uvsync_requires_managed_python() {
  local version="$1"
  if uvsync_managed_python_path "$version" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# --- venv location assertion ----------------------------------------------
#
# uvsync_check_venv <repo_root>
#
# Asserts that <repo_root>/.venv/bin/python exists, is executable and
# resolves inside <repo_root>. Prints
#   VENV_PYTHON_<absolute path>
#   VENV_PYTHON_VERSION_<version>
# Returns non-zero (and prints the reason to stderr) when the assertion
# fails — e.g. when UV_PROJECT_ENVIRONMENT pointed the venv somewhere else.
uvsync_check_venv() {
  local root="$1"
  local py="$root/.venv/bin/python"

  if [ ! -e "$py" ]; then
    echo "ERROR: $py does not exist" >&2
    return 1
  fi
  if [ ! -x "$py" ]; then
    echo "ERROR: $py is not executable" >&2
    return 1
  fi

  # Resolve the *venv directory* (not the python symlink chain): a real venv
  # has .venv/bin/python -> python3.11 -> the base interpreter in
  # ~/.local/share/uv/python/..., i.e. the python symlink legitimately points
  # outside the worktree. What must stay inside the worktree is the venv
  # itself, because deploy/install_pico.sh calls <repo>/.venv/bin/python.
  local real_root real_venv
  real_root="$(cd "$root" && pwd -P)"
  real_venv="$(readlink -f "$root/.venv" 2>/dev/null || true)"
  [ -n "$real_venv" ] || real_venv="$(cd "$root/.venv" && pwd -P)"

  case "$real_venv" in
    "$real_root"/*) : ;;
    *)
      echo "ERROR: venv directory $real_venv is NOT inside the worktree root $real_root" >&2
      return 1
      ;;
  esac

  local ver
  ver="$("$py" --version 2>&1 || echo '<unknown>')"
  echo "VENV_PYTHON_$py"
  echo "VENV_PYTHON_VERSION_$ver"
  return 0
}

# --- detached background execution -----------------------------------------
#
# The heavy step of this task is `uv sync --frozen`: it downloads GBs of
# wheels (torch 2.11.0+cu128 plus the nvidia-* stack) through the proxy.
# Running that in the foreground over ssh means one long-running tool call —
# exactly what killed a previous attempt when the session budget ran out
# (the log stopped at the `### RUN ... uv sync --frozen` banner, no EXIT
# line, no result).
#
# The helpers below split that work into
#   * a worker that is fully detached from the ssh session (setsid/nohup), so
#     it keeps running even when the session that started it dies, and
#   * short, cheap polling commands that only read a status file.
#
# uvsync_run_detached <statusfile> <logfile> <cmd...>
#   Starts <cmd> detached. stdout+stderr are appended to <logfile> (no
#   intermediate buffering, so `tail` shows live progress). The terminal
#   state is written to <statusfile> as
#       STATE=DONE|FAILED
#       RC=<exit code>
#   Returns immediately with WORKER_PID=/STATUS_FILE=/LOG_FILE=.
uvsync_run_detached() {
  local statusfile="$1" logfile="$2"; shift 2
  [ "$#" -gt 0 ] || { echo "uvsync_run_detached: no command given" >&2; return 2; }
  mkdir -p "$(dirname "$statusfile")" "$(dirname "$logfile")"

  local cmd_q="" a
  for a in "$@"; do cmd_q+=" $(printf '%q' "$a")"; done

  local runner
  runner="$(mktemp)"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'LOGF=%q\n' "$logfile"
    printf 'STATF=%q\n' "$statusfile"
    printf 'cmd=%q\n' "$cmd_q"
    cat <<'INNER'
# Publish our own PID so the poller can detect a worker that died hard.
printf 'STATE=RUNNING\nPID=%s\nSTARTED_AT=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATF.runner.tmp" && mv "$STATF.runner.tmp" "$STATF"
echo "### DETACHED START $(date -u +%Y-%m-%dT%H:%M:%SZ): $cmd" >>"$LOGF"
eval "$cmd" >>"$LOGF" 2>&1
rc=$?
echo "### DETACHED EXIT $rc: $cmd" >>"$LOGF"
# The worker normally writes its own terminal state. Only derive one when it
# died before doing so (e.g. killed by the OOM killer).
if ! grep -qE '^STATE=(DONE|FAILED)' "$STATF" 2>/dev/null; then
  if [ "$rc" -eq 0 ]; then
    printf 'STATE=DONE\nRC=0\n' >"$STATF.runner.tmp" && mv "$STATF.runner.tmp" "$STATF"
  else
    printf 'STATE=FAILED\nRC=%s\n' "$rc" >"$STATF.runner.tmp" && mv "$STATF.runner.tmp" "$STATF"
  fi
fi
INNER
  } >"$runner"
  chmod +x "$runner"

  # The placeholder is written BEFORE the runner is launched, and never
  # rewritten afterwards: the runner publishes its own PID (and the worker's
  # terminal state) as soon as it starts. A post-launch write from this side
  # would race with a fast worker and could clobber a terminal DONE/FAILED.
  printf 'STATE=RUNNING\nPID=0\nSTARTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$statusfile"

  local pid
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$runner" </dev/null >/dev/null 2>&1 &
  else
    nohup "$runner" </dev/null >/dev/null 2>&1 &
  fi
  pid=$!
  echo "WORKER_PID=$pid"
  echo "STATUS_FILE=$statusfile"
  echo "LOG_FILE=$logfile"
  return 0
}

# uvsync_status <statusfile>
#   Prints STATE=RUNNING|DONE|FAILED|ABSENT (plus PID/RC when known).
#   A worker that vanished without writing a terminal state is reported as
#   FAILED, because "RUNNING forever" is the failure mode this task exists
#   to eliminate.
uvsync_status() {
  local statusfile="$1"
  if [ ! -f "$statusfile" ]; then
    echo "STATE=ABSENT"
    return 3
  fi
  local state pid rc
  state="$(sed -n 's/^STATE=//p' "$statusfile" | head -n1)"
  pid="$(sed -n 's/^PID=//p' "$statusfile" | head -n1)"
  rc="$(sed -n 's/^RC=//p' "$statusfile" | head -n1)"
  case "${state:-}" in
    DONE)
      echo "STATE=DONE"; [ -n "$rc" ] && echo "RC=$rc"; return 0 ;;
    FAILED)
      echo "STATE=FAILED"; echo "RC=${rc:-unknown}"; return 0 ;;
  esac
  if [ -n "$pid" ] && [ "$pid" != "0" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "STATE=FAILED"
    echo "RC=unknown"
    echo "REASON=worker pid $pid is gone but no terminal state was written"
    return 0
  fi
  echo "STATE=RUNNING"
  [ -n "$pid" ] && echo "PID=$pid"
  return 0
}

# uvsync_wait_bounded <statusfile> <timeout_s> [poll_s]
#   Bounded polling. 0 = DONE, 1 = FAILED, 2 = timeout.
uvsync_wait_bounded() {
  local statusfile="$1"
  local timeout_s="${2:-600}"
  local poll_s="${3:-5}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local out
  while :; do
    out="$(uvsync_status "$statusfile" || true)"
    case "$out" in
      STATE=DONE*)   printf '%s\n' "$out"; return 0 ;;
      STATE=FAILED*) printf '%s\n' "$out"; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s\n' "$out"
      echo "TIMEOUT after ${timeout_s}s"
      return 2
    fi
    sleep "$poll_s"
  done
}

# uvsync_tail <logfile> [n]
#   Prints the last n lines of the log (default 30).
uvsync_tail() {
  local logfile="$1" n="${2:-30}"
  if [ ! -f "$logfile" ]; then
    echo "(no log file: $logfile)"
    return 1
  fi
  tail -n "$n" "$logfile"
}

# --- log marker helpers ----------------------------------------------------
#
# uvsync_log_has <logfile> <marker>
#   0 when the marker line is present in the log, 1 otherwise.
uvsync_log_has() {
  local logfile="$1" marker="$2"
  [ -f "$logfile" ] || return 1
  grep -qF -- "$marker" "$logfile"
}

# uvsync_require_log_markers <logfile> <marker...>
#   0 when every marker is present; otherwise prints the missing ones and
#   returns 1.
uvsync_require_log_markers() {
  local logfile="$1"; shift
  local missing=0 m
  for m in "$@"; do
    if ! uvsync_log_has "$logfile" "$m"; then
      echo "ERROR: missing marker in $logfile: $m" >&2
      missing=1
    fi
  done
  return "$missing"
}
