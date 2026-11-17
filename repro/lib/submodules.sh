#!/usr/bin/env bash
# repro/lib/submodules.sh — landing of the .gitmodules-pinned submodules.
#
# Split out of repro/02_submodules.sh so that the landing logic can be unit
# tested (repro/tests/test_submodules.sh) against a throwaway git remote,
# without touching the real worktree and without any network access.
#
# Why we do NOT use `git submodule update --init`:
#   * this worktree is a *linked* worktree whose .git file points at a
#     host-local path (/mnt/.../.git/worktrees/<name>) that does not exist
#     inside the ros_dev container -> plain `git` fails with
#     "fatal: not a git repository";
#   * `git submodule update --init` on such a worktree fails with
#     "git-submodule cannot be used without a working tree".
# So we reproduce the pinned state by cloning the exact .gitmodules SHA.
#
# The proxy is inlined into the sourcing process only (see repro/lib/common.sh).

# --- pinned submodules -----------------------------------------------------
# URLs come from .gitmodules; SHAs are the gitlinks recorded by the parent
# repository for those paths (verified against origin/main in the container).
GMR_PATH="third_party/GMR"
GMR_URL="https://github.com/YanjieZe/GMR.git"
GMR_SHA="25f56db79ac411258b377b6d4ccba0c8ff3372ac"

SDK_PATH="third_party/unitree_sdk2_wrapper"
SDK_URL="https://github.com/lzyang2000/unitree_sdk2_wrapper.git"
SDK_SHA="6264cc1efd9e72d3c7fffa38a360aea9e43838f3"

# land_submodule <path> <url> <sha> [<log-fn>]
#
# Materialises <path> at exactly <sha>:
#   git init -> remote add origin <url> -> fetch --depth 1 origin <sha>
#   -> checkout FETCH_HEAD
# Falls back to a full fetch + checkout <sha> when the server refuses to
# serve an arbitrary SHA (uploadpack.allowReachableSHA1InWant=false).
#
# Returns 0 only when HEAD == <sha>. Any failure (unreachable SHA, network
# error, checkout error) returns non-zero and leaves the caller in charge of
# the decision (GMR is blocking, the unitree SDK is best-effort).
land_submodule() {
  local path="$1" url="$2" sha="$3" logfn="${4:-echo}"
  "$logfn" "--- landing $path @ $sha ---"

  if [ -d "$path/.git" ]; then
    local head
    head="$(git_in "$path" rev-parse --verify HEAD 2>/dev/null || true)"
    if [ "$head" = "$sha" ]; then
      "$logfn" "    already at pinned SHA ($head) - nothing to do"
      return 0
    fi
    "$logfn" "    existing checkout at ${head:-<none>} differs from pinned SHA - re-landing"
    rm -rf "$path"
  else
    rmdir "$path" 2>/dev/null || true
  fi

  mkdir -p "$path"
  git_in "$path" init -q -b pinned
  git_in "$path" remote add origin "$url"
  if git_in "$path" fetch --depth 1 origin "$sha"; then
    "$logfn" "    fetched pinned SHA directly (depth 1)"
  else
    "$logfn" "    shallow fetch by SHA failed - falling back to full fetch"
    if ! git_in "$path" fetch --tags origin; then
      "$logfn" "    ERROR: fetch from $url failed (network/unreachable SHA)"
      return 1
    fi
  fi
  if ! git_in "$path" checkout -q "$sha" 2>/dev/null; then
    git_in "$path" checkout -q FETCH_HEAD 2>/dev/null || true
  fi

  local head
  head="$(git_in "$path" rev-parse --verify HEAD 2>/dev/null || echo '<none>')"
  if [ "$head" != "$sha" ]; then
    "$logfn" "    ERROR: HEAD is $head, expected $sha"
    return 1
  fi
  "$logfn" "    HEAD=$head OK"
  return 0
}

# verify_submodule <path> <sha> [<log-fn>]
#
# Asserts that <path> is a git checkout at exactly <sha> and that it is clean.
# Returns 0 when the check passes, 1 otherwise.
verify_submodule() {
  local path="$1" sha="$2" logfn="${3:-echo}"
  if [ ! -d "$path/.git" ]; then
    "$logfn" "    $path NOT LANDED"
    return 1
  fi
  local got dirty
  got="$(git_in "$path" rev-parse --verify HEAD 2>/dev/null || echo '<none>')"
  dirty="$(git_in "$path" status --porcelain=v1 --untracked-files=all 2>/dev/null | head -n 5)"
  "$logfn" "    $path HEAD=$got expected=$sha dirty=[${dirty:-clean}]"
  [ "$got" = "$sha" ] || return 1
  [ -z "$dirty" ] || return 1
  return 0
}
