#!/usr/bin/env bash
# repro/05_proxy_hygiene.sh — proxy hygiene assertion (R004).
#
# Hard requirement of this project: the proxy exists ONLY as inline environment
# variables of the running process.  It must NEVER be written into a system
# configuration file (/etc/environment, /etc/profile*, ~/.bashrc, ~/.profile,
# uv.toml, pip.conf, gitconfig, apt.conf.d, wgetrc, ...).
#
# This script turns that promise into a machine assertion:
#   1. NEGATIVE SELF-TEST — the very same detector is fed a fixture that
#      contains proxy traces and must classify it as polluted.  A detector that
#      cannot detect anything would otherwise pass the "everything is clean"
#      check vacuously.  The self-test only touches a temporary directory.
#   2. SYSTEM SCAN — every system configuration file listed in
#      repro/lib/proxy_hygiene.sh is scanned; a hit prints
#      "<file>:<line>:<content>" and the script exits non-zero
#      (PROXY_HYGIENE_FAIL).
#   3. ENVIRONMENT SCAN — the proxy variables of the running process must be
#      exactly the ones inlined by repro/lib/common.sh (nothing else), a clean
#      `env -i` shell must not see any proxy variable, and the container's
#      own init environment (/proc/1/environ) must be proxy-free too.
#
# The log lands in logs/env/05_proxy_hygiene.txt and ends with
# PROXY_HYGIENE_OK; the self-test prints PROXY_HYGIENE_SELFTEST_OK.
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh).

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/proxy_hygiene.sh
source "$_SCRIPT_DIR/lib/proxy_hygiene.sh"
require_container

cd "$REPO_ROOT"

MAIN_LOG="${PROXY_HYGIENE_LOG:-$LOG_DIR/05_proxy_hygiene.txt}"

SELF_TEST_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST_ONLY=1; shift ;;
    --targets-file)
      # override the scan target list (used to exercise the FAILURE path of
      # this script against a temporary fixture, without touching any real
      # system configuration file)
      [ "$#" -ge 2 ] || { echo "--targets-file needs an argument" >&2; exit 2; }
      PROXY_HYGIENE_TARGETS_FILE="$2"; export PROXY_HYGIENE_TARGETS_FILE
      shift 2 ;;
    --log-file)
      [ "$#" -ge 2 ] || { echo "--log-file needs an argument" >&2; exit 2; }
      MAIN_LOG="$2"; shift 2 ;;
    *)
      echo "usage: bash repro/05_proxy_hygiene.sh [--self-test] [--targets-file FILE] [--log-file FILE]" >&2
      exit 2 ;;
  esac
done

log() { echo "$*" | tee -a "$MAIN_LOG"; }

# ancestor_proxy_vars — print every proxy variable found in the environment of
# this process' ancestors (ssh -> docker exec -> bash -> this script).  Empty
# output means none of them carries a proxy variable.
ancestor_proxy_vars() {
  local pid prev hits=""
  pid="$(proc_ppid $$)" || return 0
  local i=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 32 ]; do
    if [ -r "/proc/$pid/environ" ]; then
      hits="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -i proxy || true)"
      if [ -n "$hits" ]; then
        printf 'pid=%s %s\n' "$pid" "$hits"
      fi
    fi
    prev="$pid"
    pid="$(proc_ppid "$prev")" || break
    i=$((i + 1))
  done
}

echo "### RUN $(date -u +%Y-%m-%dT%H:%M:%SZ): 05_proxy_hygiene.sh $*" | tee -a "$MAIN_LOG"
log "=== 05_proxy_hygiene.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "REPO_ROOT=$REPO_ROOT"
log "PROXY_HYGIENE_ADDR=$PROXY_HYGIENE_ADDR"
log "PROXY_HYGIENE_STRICT=$PROXY_HYGIENE_STRICT"

# ---------------------------------------------------------------------------
# 1. detector self-test (negative test) — temp dir only, no system file is
#    touched by this step.
# ---------------------------------------------------------------------------
selftest_dir=""
cleanup() {
  if [ -n "$selftest_dir" ] && [ -d "$selftest_dir" ]; then
    rm -rf "$selftest_dir"
  fi
}
trap cleanup EXIT

run_self_test() {
  local failures=0
  selftest_dir="$(mktemp -d "${TMPDIR:-/tmp}/proxy_hygiene_selftest.XXXXXX")"

  printf 'PATH=/usr/bin\n' > "$selftest_dir/clean.env"
  printf 'http_proxy=http://172.16.119.20:40381\n' > "$selftest_dir/active_ours.env"
  printf 'NO_PROXY = example.com\n' > "$selftest_dir/active_generic.env"
  printf '#http_proxy = http://proxy.example.invalid:3128/\n' > "$selftest_dir/commented.env"
  printf '# once used 172.16.119.20:40381\n' > "$selftest_dir/address_in_comment.env"

  local out rc=0

  # scan_fixture <file> <expected-rc> <expected-finding-prefix> <description>
  # The helper keeps the "did the detector classify the fixture as expected?"
  # question in one place; a mismatch is a self-test failure.
  scan_fixture() {
    local file="$1" want_rc="$2" want_prefix="$3" desc="$4"
    local o r
    r=0
    o="$(proxy_hygiene_scan_file "$file")" || r=$?
    if [ "$r" -ne "$want_rc" ]; then
      log "SELFTEST FAIL: $desc — expected rc=$want_rc, got rc=$r (${o:-<no findings>})"
      failures=$((failures + 1))
      return 0
    fi
    if [ -n "$want_prefix" ] && ! printf '%s' "$o" | grep -q "^$want_prefix "; then
      log "SELFTEST FAIL: $desc — expected a $want_prefix finding, got: ${o:-<none>}"
      failures=$((failures + 1))
      return 0
    fi
    if [ -z "$want_prefix" ] && [ -n "$o" ]; then
      log "SELFTEST FAIL: $desc — expected no finding, got: $o"
      failures=$((failures + 1))
      return 0
    fi
    log "SELFTEST ok: $desc -> ${o:-<clean>}"
    return 0
  }

  # 1a. a clean file must stay clean
  scan_fixture "$selftest_dir/clean.env" 0 "" "a clean fixture stays clean"

  # 1b. an active setting that uses our proxy address -> polluted
  scan_fixture "$selftest_dir/active_ours.env" 1 "ADDR" "an active proxy fixture is detected"

  # 1c. an active generic proxy setting -> polluted
  scan_fixture "$selftest_dir/active_generic.env" 1 "HIT" "a generic proxy fixture is detected"

  # 1d. a commented-out setting is inert -> clean (but reported)
  scan_fixture "$selftest_dir/commented.env" 0 "COMMENT" "a commented-out setting is inert"

  # 1e. our proxy address inside a comment is still pollution
  scan_fixture "$selftest_dir/address_in_comment.env" 1 "ADDR" "our proxy address in a comment is detected"

  cleanup
  selftest_dir=""

  if [ "$failures" -ne 0 ]; then
    log "PROXY_HYGIENE_SELFTEST_FAIL ($failures failing case(s))"
    return 1
  fi
  log "PROXY_HYGIENE_SELFTEST_OK"
  return 0
}

log ""
log "--- step 1: detector self-test (negative test, temp dir only) ---"
if ! run_self_test; then
  echo "ERROR: the proxy-hygiene detector failed its own self-test" >&2
  exit 1
fi

if [ "$SELF_TEST_ONLY" -eq 1 ]; then
  log "PROXY_HYGIENE_SELFTEST_ONLY"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. system configuration scan
# ---------------------------------------------------------------------------
log ""
log "--- step 2: system configuration scan ---"

polluted=0
scanned=0
while IFS= read -r target; do
  [ -n "$target" ] || continue
  if [ -d "$target" ]; then
    n_files="$(find "$target" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    log "SCAN DIR  $target ($n_files file(s))"
  elif [ -f "$target" ]; then
    log "SCAN FILE $target"
  else
    log "SKIP      $target (absent == clean)"
    continue
  fi
  scanned=$((scanned + 1))
  findings="$(proxy_hygiene_scan_path "$target" || true)"
  if [ -n "$findings" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      log "$f"
    done <<< "$findings"
    if printf '%s' "$findings" | grep -qE '^(ADDR|HIT) '; then
      polluted=$((polluted + 1))
    fi
  fi
done < <(proxy_hygiene_targets)

log "SCANNED_TARGETS_$scanned"
log "POLLUTED_TARGETS_$polluted"

if [ "$polluted" -ne 0 ]; then
  log "PROXY_HYGIENE_FAIL"
  echo "ERROR: proxy traces found in $polluted system configuration target(s)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. environment scan — the proxy must live in this process only
# ---------------------------------------------------------------------------
log ""
log "--- step 3: environment scan ---"

expected_no_proxy="localhost,127.0.0.1"
env_fail=0
for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
  val="${!var:-}"
  if [ "$val" != "$PROXY" ]; then
    log "ENV FAIL $var is not the inlined proxy value (got '${val:-<unset>}')"
    env_fail=1
  else
    log "ENV OK   $var is the inlined proxy value (process-scoped)"
  fi
done
for var in no_proxy NO_PROXY; do
  val="${!var:-}"
  if [ "$val" != "$expected_no_proxy" ]; then
    log "ENV FAIL $var is not the inlined no-proxy value (got '${val:-<unset>}')"
    env_fail=1
  else
    log "ENV OK   $var is the inlined no-proxy value (process-scoped)"
  fi
done

# The inline variables are the ONLY proxy variables of this process: unsetting
# them leaves nothing behind (they are not inherited from any system config).
leftover="$( ( unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; env | grep -i proxy ) || true)"
if [ -n "$leftover" ]; then
  log "ENV FAIL proxy variables survive the un-set: $leftover"
  env_fail=1
else
  log "INLINE_PROXY_ONLY_OK (no proxy variable remains once the inline ones are removed)"
fi

# A completely clean environment must not contain any proxy variable.
clean_env="$(env -i PATH=/usr/local/bin:/usr/bin:/bin bash -c 'env | grep -i proxy' || true)"
if [ -n "$clean_env" ]; then
  log "ENV FAIL a clean env still exposes proxy variables: $clean_env"
  env_fail=1
else
  log "CLEAN_ENV_NO_PROXY_OK (env -i bash -c 'env | grep -i proxy' is empty)"
fi

# The container's own init environment must be proxy-free as well.
init_env="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -i proxy || true)"
if [ -n "$init_env" ]; then
  log "ENV FAIL the container init environment exposes proxy variables: $init_env"
  env_fail=1
else
  log "CONTAINER_INIT_NO_PROXY_OK (/proc/1/environ has no proxy variable)"
fi

# ... and so must the environment of every process this script descends from
# (the ssh -> docker exec -> bash chain).  $PPID is 0 under `docker exec`, so
# the ancestor chain is resolved through /proc/<pid>/stat instead.
proc_ppid() {
  # the ppid is the 2nd whitespace-separated field after the ")" of comm
  local line rest
  line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  rest="${line#*) }"
  printf '%s' "$rest" | awk '{print $2}'
}

ancestor_env="$(ancestor_proxy_vars)" || ancestor_env=""
if [ -n "$ancestor_env" ]; then
  log "ENV FAIL an ancestor process environment exposes proxy variables: $ancestor_env"
  env_fail=1
else
  log "ANCESTOR_ENV_NO_PROXY_OK (no proxy variable in the ssh/docker-exec/bash ancestor chain)"
fi

if [ "$env_fail" -ne 0 ]; then
  log "PROXY_HYGIENE_FAIL"
  echo "ERROR: the proxy is not confined to this process" >&2
  exit 1
fi

log ""
log "PROXY_HYGIENE_OK"
