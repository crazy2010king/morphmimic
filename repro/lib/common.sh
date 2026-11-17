#!/usr/bin/env bash
# repro/lib/common.sh — shared helpers for every repro/* script.
#
# These scripts are executed INSIDE the remote `ros_dev` container, where the
# worktree lives on the same NFS export as the local checkout:
#   local  : /mnt/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz
#   remote : /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz
#
# CONVENTION (hard rule, enforced again by repro/05_proxy_hygiene.sh):
# the proxy is inlined into THIS process' environment only. It is never written
# to /etc/environment, /etc/profile, /root/.bashrc, uv.toml, pip.conf, ... .
# When the script exits, the proxy variables are gone again.

set -euo pipefail

# --- repository root -------------------------------------------------------
# Derived from this file's own location: <repo>/repro/lib/common.sh -> <repo>
# (independent of which script sources it, and identical on host & container).
_COMMON_SH="${BASH_SOURCE[0]}"
REPO_ROOT="$(cd "$(dirname "$_COMMON_SH")/../.." && pwd)"
export REPO_ROOT

# --- proxy: inline, process-scoped only -------------------------------------
PROXY="${PROXY:-http://172.16.119.20:40381}"

# COMMON_PROXY_INLINE=0 (set BEFORE sourcing this file) opts out of exporting
# the proxy variables.  It exists for repro/00_env.sh, the orchestrator: it
# must NOT carry proxy variables itself, because repro/05_proxy_hygiene.sh
# asserts that no ANCESTOR process of it exposes a proxy variable (the
# orchestrator would be such an ancestor).  Every step script sources
# common.sh itself and therefore gets the proxy in its own process, which is
# exactly the "inline, process-scoped only" convention this project requires.
if [ "${COMMON_PROXY_INLINE:-1}" != "0" ]; then
  export http_proxy="$PROXY"
  export https_proxy="$PROXY"
  export HTTP_PROXY="$PROXY"
  export HTTPS_PROXY="$PROXY"
  export no_proxy="localhost,127.0.0.1"
  export NO_PROXY="localhost,127.0.0.1"
fi

# --- logging ---------------------------------------------------------------
# logs/ is git-ignored, so every artefact lands under logs/env/.
#
# The BONES-SEED payload (archives, metadata, logs) lives OUTSIDE any git
# worktree — see repro/lib/seed_store.sh.  The worktree links data/ and
# logs/ into that store.  GSD deletes "stale" milestone worktrees, and with
# them those links: a worker that resolves LOG_DIR through the worktree then
# loses its status file (observed 2026-11-11 15:04 — the finalize worker
# reported STATE=ABSENT while the download was at 66%, because the worktree
# had been rebuilt and logs/ had become a plain directory).
#
# So the store is resolved here and the worktree links are (re)created when
# they are missing.  When logs/ is NOT a symlink into the store, the log
# directory is taken from the store directly: the chain then survives any
# further worktree rebuild.
SEED_STORE_LIB="$REPO_ROOT/repro/lib/seed_store.sh"
if [ -f "$SEED_STORE_LIB" ]; then
  # shellcheck source=lib/seed_store.sh
  source "$SEED_STORE_LIB" >/dev/null 2>&1 || true
fi

# seed_store_link <name> — point <repo>/<name> at the store copy.
#
# The single implementation lives in repro/lib/seed_store.sh.  It is NOT a
# no-op when the worktree path exists as a REAL DIRECTORY: a rebuilt worktree
# has plain directories instead of symlinks, and the previous implementation
# silently accepted that — so the artefacts were written into a directory
# that the next GSD reconcile deleted (that is how the whole tool-chain probe
# output, logs/toolchain/**, was lost on 2026-11-11).  Now the content is
# moved into the store and the path becomes the symlink again.
seed_store_link() {
  [ -n "${SEED_STORE_ROOT:-}" ] || return 1
  if ! declare -F seed_store_link_impl >/dev/null 2>&1; then
    # the store library could not be sourced: keep the old, SAFE behaviour
    # (never create a link over a real directory) and report the failure.
    echo "WARNING: repro/lib/seed_store.sh is unavailable; store links not verified" >&2
    return 1
  fi
  seed_store_link_impl "$@"
}

LOG_DIR="$REPO_ROOT/logs/env"
if [ ! -L "$REPO_ROOT/logs" ] && [ -n "${SEED_STORE_ROOT:-}" ] && [ -d "$SEED_STORE_ROOT/logs" ]; then
  LOG_DIR="$SEED_STORE_ROOT/logs/env"
fi
export LOG_DIR
mkdir -p "$LOG_DIR" 2>/dev/null || true
# --migrate is deliberately NOT used here: importing common.sh must not
# move directories or rewrite symlinks as a side effect (35+ scripts source
# this file, including read-only ones, and `assets`/`runs` are git-tracked
# symlinks).  Repairing a diverged worktree path is an explicit action:
#     bash repro/30_store_guard.sh migrate
# A missing path is still healed here (creating a relative symlink is
# idempotent and cannot lose anything).
seed_store_link data || true
seed_store_link logs || true
# `out` holds the ONNX export artefacts (policy.onnx is ~65 MB); they are as
# heavy as the seed payload, so they live in the store as well and the
# worktree only carries the symlink.
seed_store_link out || true
# `assets` holds the exported MuJoCo assets of the deployment verification
# (slice S08): the scene XML, the meshes and one npz per clip.  They are
# binary artefacts, so they live in the store; the worktree only carries the
# symlink.
seed_store_link assets || true
# `runs` holds the sim2sim replay artefacts (slice S08): one summary json
# and one mp4 per clip.  Binary artefacts as well -> the store.
seed_store_link runs || true

# store_guard <name>... — fail closed when a worktree path is not
# store-backed.  Every script that writes a heavy artefact (archives, npz,
# checkpoints, ONNX, replay videos, the delivered record) MUST call this
# BEFORE writing it: a worktree that is not linked into the store loses
# everything it holds on the next GSD reconcile.
store_guard() {
  if ! declare -F seed_store_guard >/dev/null 2>&1; then
    echo "STORE_GUARD_FAIL reason=store-library-unavailable" >&2
    return 1
  fi
  seed_store_guard "$@"
}

# Git in this container runs as root over NFS files owned by another uid, so
# "dubious ownership" has to be dealt with for every invocation.
#
# Measured facts (container ros_dev):
#   * git version 2.34.1 -> `safe.directory=*` (wildcard) is NOT supported and
#     `-c safe.directory=<path>` on the command line is NOT honoured either
#     (only the global config file is read). The only safe, config-free way to
#     operate on these NFS repositories is to run git AS the uid that owns the
#     files (uid 1000 here) via setpriv.
#   * the NFS export is root-squashed: directories created by root show up as
#     uid 1000, which is exactly why root's git refuses to touch them.
GIT_SAFE_OPTS=(-c "protocol.file.allow=always")
GIT_TMP_HOME="${GIT_TMP_HOME:-/tmp}"

# git_in <dir> <git args...>
# Run git with <dir> as working directory, as the uid that owns <dir>, so
# git's ownership check passes without writing any global/system configuration.
git_in() {
  local dir="$1"; shift
  local uid gid
  uid="$(stat -c %u "$dir" 2>/dev/null || echo 0)"
  gid="$(stat -c %g "$dir" 2>/dev/null || echo 0)"
  if [ "$(id -u)" -eq 0 ] && [ "$uid" != "0" ] && command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid="$uid" --regid="$gid" --clear-groups \
      env HOME="$GIT_TMP_HOME" git -C "$dir" "${GIT_SAFE_OPTS[@]}" "$@"
  else
    git -C "$dir" "${GIT_SAFE_OPTS[@]}" "$@"
  fi
}

# Mount prefixes used to remap the worktree's gitdir pointer (see below).
LOCAL_REPO_MOUNT_PREFIX="${LOCAL_REPO_MOUNT_PREFIX:-/mnt/test_cc_dev}"
REMOTE_REPO_MOUNT_PREFIX="${REMOTE_REPO_MOUNT_PREFIX:-/home/ubuntu/work_dev/wqq/nfs/test_cc_dev}"

# --- where am I running? ---------------------------------------------------
# The local checkout lives under /mnt/test_cc_dev/..., the container view of the
# same NFS export under /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/....
# Because logs/ is on that shared export, a script that writes logs must ONLY
# run in the container: running it locally would overwrite the container's
# authoritative artefacts with local-machine facts (no GPU, no uv).
in_container() {
  case "$REPO_ROOT" in
    "$REMOTE_REPO_MOUNT_PREFIX"/*) return 0 ;;
    *) return 1 ;;
  esac
}

require_container() {
  if ! in_container; then
    echo "ERROR: this script must run inside the ros_dev container." >&2
    echo "       REPO_ROOT=$REPO_ROOT does not live under $REMOTE_REPO_MOUNT_PREFIX" >&2
    echo "       Use: bash repro/lib/remote.sh <script>" >&2
    exit 3
  fi
}

# --- git context resolution ------------------------------------------------
# The worktree's .git file points at a HOST-local path
# (/mnt/test_cc_dev/.../.git/worktrees/<name>) that does not exist inside the
# container, so plain `git` there fails with "not a git repository".
# resolve_git_context() finds the real gitdir (remapped or by walking up) and
# git_repo() then runs git against it explicitly.
GIT_DIR_RESOLVED=""

resolve_git_context() {
  GIT_DIR_RESOLVED=""
  local dotgit="$REPO_ROOT/.git"
  [ -f "$dotgit" ] || return 0   # plain (non-linked) checkout: nothing to do

  local gitdir
  gitdir="$(sed -n 's/^gitdir: //p' "$dotgit" | head -n 1)"
  [ -n "$gitdir" ] || return 0
  if [ -d "$gitdir" ]; then
    GIT_DIR_RESOLVED="$gitdir"
    return 0
  fi

  # remap the host-local mount prefix onto the container-visible one
  local mapped="${gitdir/$LOCAL_REPO_MOUNT_PREFIX/$REMOTE_REPO_MOUNT_PREFIX}"
  if [ -d "$mapped" ]; then
    GIT_DIR_RESOLVED="$mapped"
    return 0
  fi

  # fallback: <ancestor>/.git/worktrees/<worktree-name>
  local name p
  name="$(basename "$REPO_ROOT")"
  p="$REPO_ROOT"
  local i
  for i in 1 2 3 4 5; do
    p="$(dirname "$p")"
    if [ -d "$p/.git/worktrees/$name" ]; then
      GIT_DIR_RESOLVED="$p/.git/worktrees/$name"
      return 0
    fi
  done
  return 0
}

# Run git inside the repository, honouring the resolved gitdir when needed.
# git_in runs git as the uid that owns the worktree (NFS + root-squash), so
# git 2.34's ownership check passes without touching any global config.
git_repo() {
  if [ -n "$GIT_DIR_RESOLVED" ]; then
    GIT_DIR="$GIT_DIR_RESOLVED" GIT_WORK_TREE="$REPO_ROOT" git_in "$REPO_ROOT" "$@"
  else
    git_in "$REPO_ROOT" "$@"
  fi
}

# --- logging helper --------------------------------------------------------
# run_logged <logfile> <cmd...>
# Runs the command, appends stdout+stderr (plus a RUN/EXIT banner) to
# <logfile>, echoes the output to the caller's stdout, and propagates the
# command's exit code.
run_logged() {
  local logfile="$1"; shift
  [ "$#" -gt 0 ] || { echo "run_logged: no command given" >&2; return 2; }
  mkdir -p "$(dirname "$logfile")"
  local tmp rc
  tmp="$(mktemp)"
  echo "### RUN $(date -u +%Y-%m-%dT%H:%M:%SZ): $*" | tee -a "$logfile"
  set +e
  "$@" >"$tmp" 2>&1
  rc=$?
  set -e
  cat "$tmp" | tee -a "$logfile"
  echo "### EXIT $rc: $*" | tee -a "$logfile"
  rm -f "$tmp"
  return $rc
}
