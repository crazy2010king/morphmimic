#!/usr/bin/env bash
# repro/01_snapshot.sh — capture the machine facts of the remote ros_dev
# container into logs/env/snapshot.txt.
#
# This is the baseline every later step is measured against (R006), and it
# records the *current* state of the system proxy configuration so that
# repro/05_proxy_hygiene.sh can prove it stayed clean (R004).
#
# Run locally:  bash repro/lib/remote.sh 01_snapshot.sh

set -euo pipefail

# shellcheck source=repro/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# This script records the CONTAINER's machine facts. logs/ lives on the shared
# NFS export, so running it locally would overwrite the container's
# authoritative snapshot with local-machine facts (no GPU, no uv).
require_container

SNAPSHOT="$LOG_DIR/snapshot.txt"
mkdir -p "$LOG_DIR"

# Fresh snapshot each run (this file is the live baseline, not evidence).
: > "$SNAPSHOT"

say() { printf '%s\n' "$*" >> "$SNAPSHOT"; }

say "=== morphmimic remote environment snapshot ==="
say "generated_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "repo_root: $REPO_ROOT"
say "hostname: $(hostname)"
say "container: ros_dev"
say ""

# --- git -------------------------------------------------------------------
say "--- git ---"
resolve_git_context
if [ -n "$GIT_DIR_RESOLVED" ]; then
  say "gitdir_resolved: $GIT_DIR_RESOLVED"
else
  say "gitdir_resolved: (default discovery)"
fi
say "git_head: $(git_repo rev-parse HEAD 2>&1 || echo UNKNOWN)"
say "git_branch: $(git_repo branch --show-current 2>&1 || echo UNKNOWN)"
say "git_describe: $(git_repo log -1 --pretty='%h %s' 2>&1 || echo UNKNOWN)"
say "git_status_porcelain_count: $(git_repo status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
say ""

# --- uv.lock ---------------------------------------------------------------
say "--- uv.lock ---"
if [ -f "$REPO_ROOT/uv.lock" ]; then
  say "uv_lock_sha256: $(sha256sum "$REPO_ROOT/uv.lock" | awk '{print $1}')"
  say "uv_lock_bytes: $(wc -c < "$REPO_ROOT/uv.lock" | tr -d ' ')"
  say ""
  # The per-wheel sha256 of the packages that matter for a rebuild.  The lock
  # file is the source of truth for them, so a third party can verify the
  # wheels they fetch against these digests (R006: "关键 wheel 哈希").
  say "wheel_hashes:"
  python3 - "$REPO_ROOT/uv.lock" >> "$SNAPSHOT" <<'PY'
import sys, tomllib

want = {
    "torch", "mjlab", "warp-lang", "mujoco-warp",
    "general-motion-retargeting", "mujoco", "protobuf", "onnx",
    "onnxruntime", "onnxscript", "numpy", "scipy",
}

with open(sys.argv[1], "rb") as fh:
    lock = tomllib.load(fh)

for pkg in lock.get("package", []):
    name = pkg.get("name")
    if name not in want:
        continue
    version = pkg.get("version", "?")
    for wheel in pkg.get("wheels", []):
        digest = wheel.get("hash", "")
        filename = wheel.get("url", "").rsplit("/", 1)[-1]
        if not digest:
            continue
        print(f"  {name}=={version} {filename} {digest}")
PY
  say ""
  say "uv_lock_packages:"
  python3 - "$REPO_ROOT/uv.lock" >> "$SNAPSHOT" <<'PY'
import sys, tomllib

want = {
    "torch", "mjlab", "warp-lang", "mujoco-warp",
    "general-motion-retargeting", "mujoco",
    "protobuf", "onnx", "onnxruntime", "onnxscript", "numpy", "scipy",
}

with open(sys.argv[1], "rb") as fh:
    lock = tomllib.load(fh)

for pkg in lock.get("package", []):
    name = pkg.get("name")
    if name not in want:
        continue
    version = pkg.get("version", "?")
    source = pkg.get("source", {})
    if isinstance(source, dict) and "registry" in source:
        src = "registry:" + source["registry"]
    elif isinstance(source, dict) and "editable" in source:
        src = "editable:" + source["editable"]
    elif isinstance(source, dict) and "git" in source:
        src = "git:" + source["git"]
    else:
        src = str(source)
    print(f"  - {name} {version} [{src}]")
    for wheel in pkg.get("wheels", []) or []:
        print(f"      wheel: {wheel.get('url', '?')}")
        print(f"      hash:  {wheel.get('hash', '?')}")
    sdist = pkg.get("sdist")
    if sdist:
        print(f"      sdist: {sdist.get('url', '?')}")
        print(f"      hash:  {sdist.get('hash', '?')}")
PY
else
  say "uv_lock: MISSING"
fi
say ""

# --- installed package versions -------------------------------------------
# The lock file says what SHOULD be installed; this says what IS installed
# in the project venv.  The difference between the two is the first thing a
# reviewer needs when a rebuild does not behave like the original run.
say "--- venv package versions (installed) ---"
if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
  "$REPO_ROOT/.venv/bin/python" - >> "$SNAPSHOT" <<'PY' 2>&1 || say "  (probe failed)"
import importlib.metadata as md

for name in ("torch", "mjlab", "warp-lang", "mujoco", "mujoco-warp",
             "protobuf", "onnx", "onnxruntime", "onnxscript",
             "numpy", "scipy", "general-motion-retargeting"):
    try:
        print(f"  {name}=={md.version(name)}")
    except Exception:
        print(f"  {name}==NOT_INSTALLED")
PY
else
  say "  (no project venv)"
fi
say ""

# --- GPU -------------------------------------------------------------------
say "--- GPU ---"
say "nvidia_smi_query:"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv >> "$SNAPSHOT" 2>&1 || say "  (nvidia-smi query failed)"
say ""
say "nvidia_smi_header:"
nvidia-smi 2>&1 | head -n 12 >> "$SNAPSHOT" || say "  (nvidia-smi failed)"
say ""

# --- OS / CPU / memory / disk ---------------------------------------------
say "--- os / cpu / memory ---"
say "os_release:"
if [ -f /etc/os-release ]; then
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release | sed 's/^/  /' >> "$SNAPSHOT"
else
  say "  (missing)"
fi
say "kernel: $(uname -srm)"
say "nproc: $(nproc)"
say "free_g:"
free -g | sed 's/^/  /' >> "$SNAPSHOT"
say ""

say "--- disk (worktree NFS mount) ---"
df -h "$REPO_ROOT" | sed 's/^/  /' >> "$SNAPSHOT" 2>&1 || say "  (df failed)"
say "mount:"
findmnt -T "$REPO_ROOT" -o TARGET,SOURCE,FSTYPE 2>/dev/null | sed 's/^/  /' >> "$SNAPSHOT" || say "  (findmnt unavailable)"
say ""

# --- toolchain -------------------------------------------------------------
say "--- toolchain ---"
say "uv_version: $(uv --version 2>&1 || echo MISSING)"
say "uv_path: $(command -v uv || echo MISSING)"
say "system_python: $(python3 --version 2>&1 || echo MISSING)"
say "system_python_path: $(command -v python3 || echo MISSING)"
say "uv_python_list:"
uv python list 2>&1 | sed 's/^/  /' >> "$SNAPSHOT" || say "  (uv python list failed)"
say "managed_cpython_3_11: $(uv python list 2>/dev/null | awk '/cpython-3\.11/ {print $2; exit}' || echo NONE)"
say ""

# --- proxy configuration baseline (for T5's hygiene assertions) ------------
say "--- proxy configuration baseline ---"
say "note: the proxy variables below come from repro/lib/common.sh and are"
say "      inlined into THIS process only (they vanish when the script exits)."
say "      They are NOT persisted in any system configuration file."
say "current_process_proxy_vars:"
( env | grep -iE '^(http|https|ftp|no)_proxy=' | sort | sed 's/^/  /' ) >> "$SNAPSHOT" || true
if ! env | grep -qiE '^(http|https|ftp|no)_proxy='; then
  say "  (none)"
fi
say ""
say "system_default_env_proxy_vars (clean env, i.e. what the system itself provides):"
( env -i bash -c 'env | grep -iE "^(http|https|ftp|no)_proxy="' | sort | sed 's/^/  /' ) >> "$SNAPSHOT" || true
if ! env -i bash -c 'env | grep -qiE "^(http|https|ftp|no)_proxy="'; then
  say "  (none)"
fi
say ""
say "system_config_proxy_scan:"
say "  (raw = any textual match; active = match on a NON-commented line;"
say "   an 'active' hit, or any hit naming our proxy 172.16.119.20, is real contamination."
say "   Stock commented-out defaults such as /etc/wgetrc's yoyodyne example are"
say "   'raw'-only and must not be treated as contamination.)"
PROXY_RE='172\.16\.119\.20|(http|https|ftp|no)_proxy[[:space:]]*[:=]'
for f in /etc/environment /etc/profile /etc/bash.bashrc /root/.bashrc /root/.profile \
         /root/.config/uv/uv.toml /root/.config/pip/pip.conf /etc/pip.conf \
         /root/.gitconfig /etc/gitconfig /etc/apt/apt.conf /etc/wgetrc; do
  if [ -f "$f" ]; then
    raw="$(grep -inE "$PROXY_RE" "$f" || true)"
    active="$(grep -inE "$PROXY_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    ours="$(grep -inE '172\.16\.119\.20' "$f" || true)"
    if [ -n "$raw" ]; then
      say "  $f: raw_match=yes active_match=$([ -n "$active" ] && echo yes || echo no) our_proxy_address=$([ -n "$ours" ] && echo yes || echo no)"
      printf '%s\n' "$raw" | sed 's/^/      raw: /' >> "$SNAPSHOT"
    else
      say "  $f: clean"
    fi
  else
    say "  $f: absent"
  fi
done
for d in /etc/environment.d /etc/profile.d /etc/apt/apt.conf.d; do
  if [ -d "$d" ]; then
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      raw="$(grep -inE "$PROXY_RE" "$f" || true)"
      active="$(grep -inE "$PROXY_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
      ours="$(grep -inE '172\.16\.119\.20' "$f" || true)"
      if [ -n "$raw" ]; then
        say "  $f: raw_match=yes active_match=$([ -n "$active" ] && echo yes || echo no) our_proxy_address=$([ -n "$ours" ] && echo yes || echo no)"
        printf '%s\n' "$raw" | sed 's/^/      raw: /' >> "$SNAPSHOT"
      else
        say "  $f: clean"
      fi
    done
  else
    say "  $d/: absent"
  fi
done
say ""

say "=== end of snapshot ==="
# The digest of the snapshot body: everything written up to this point.  It
# makes the snapshot RE-CHECKABLE (R006): a later session can recompute it
# and compare, instead of trusting a free-text file.
SNAPSHOT_BODY_SHA="$(sha256sum "$SNAPSHOT" | awk '{print $1}')"
say "snapshot_body_sha256: $SNAPSHOT_BODY_SHA"
echo "SNAPSHOT_OK"
echo "SNAPSHOT_OK" >> "$SNAPSHOT"
echo "snapshot written to: $SNAPSHOT"
