#!/usr/bin/env bash
# repro/lib/remote.sh — LOCAL-side entry point.
#
# Every repro step must run inside the remote `ros_dev` container: the local
# dev box has no GPU, no `uv`, and no outbound network. This script ships the
# requested script to that container over ssh and transparently propagates the
# remote exit code.
#
#   usage: bash repro/lib/remote.sh <script> [args...]
#   e.g.   bash repro/lib/remote.sh 01_snapshot.sh
#          bash repro/lib/remote.sh repro/03_uv_sync.sh
#
# Environment overrides:
#   REMOTE_HOST (default 172.16.119.199)
#   REMOTE_PORT (default 2242)
#   REMOTE_USER (default ubuntu — the only key-authorised user; `nvidia` is rejected)
#   REMOTE_CONTAINER (default ros_dev)
#   REMOTE_REPO_ROOT (default the container-visible path of this worktree)

set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-172.16.119.199}"
REMOTE_PORT="${REMOTE_PORT:-2242}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_CONTAINER="${REMOTE_CONTAINER:-ros_dev}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic/.gsd-worktrees/M001-ttwecz}"

if [ "$#" -lt 1 ]; then
  echo "usage: bash repro/lib/remote.sh <script> [args...]" >&2
  exit 2
fi

SCRIPT="$1"; shift

# Accept "01_snapshot.sh", "repro/01_snapshot.sh" and "tests/test_lib.sh".
# A bare name means a script under repro/; a path that already resolves
# against the repository root is used as-is.
case "$SCRIPT" in
  repro/*)  SCRIPT_PATH="$SCRIPT" ;;
  */repro/*) SCRIPT_PATH="$SCRIPT" ;;
  *)
    local_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [ -f "$local_root/$SCRIPT" ]; then
      SCRIPT_PATH="$SCRIPT"
    else
      SCRIPT_PATH="repro/$SCRIPT"
    fi
    ;;
esac

# Build the remote command. `docker exec` (no -it: there is no TTY) runs the
# script with bash -lc so the container's login PATH (uv, nvidia-smi, ...) is
# picked up. Arguments are quoted so they survive the two-level expansion.
REMOTE_CMD="cd $(printf '%q' "$REMOTE_REPO_ROOT") && bash $(printf '%q' "$SCRIPT_PATH")"
for a in "$@"; do
  REMOTE_CMD="$REMOTE_CMD $(printf '%q' "$a")"
done

ssh -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    -p "$REMOTE_PORT" \
    "$REMOTE_USER@$REMOTE_HOST" \
    "docker exec $REMOTE_CONTAINER bash -lc $(printf '%q' "$REMOTE_CMD")"
