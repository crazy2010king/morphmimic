#!/usr/bin/env bash
# repro/lib/seed_store.sh — the PERSISTENT location of every heavy artefact.
#
# --------------------------------------------------------------------------
# WHY THIS EXISTS
#
# GSD's reconcile step removes a milestone worktree that is "not registered
# with git" (observed 2026-11-11:
#   "Removing stale worktree directory (not registered with git):
#    /mnt/.../morphmimic/.gsd-worktrees/M001-ttwecz")
# and a recursive removal takes every UNTRACKED file with it.  That is how
# 23.5 GB of g1.tar.gz and the finished metadata CSV were lost on 2026-11-11,
# and how the whole tool-chain probe output (logs/toolchain/**, i.e. the
# cloned third-party repos, the isolated venvs and the pybind11 build) was
# lost on 2026-11-11 as well — that probe had run BEFORE this store existed,
# so it wrote into the worktree's plain `logs/` directory.
#
# Everything heavy therefore lives OUTSIDE any git worktree:
#
#   LOCAL : /mnt/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo
#   REMOTE: /home/ubuntu/work_dev/wqq/nfs/test_cc_dev/git_source/groot_nvidia/morphmimic-seed-data/repo
#
# Inside the worktree, data/ logs/ out/ assets/ runs/ docs/ are SYMLINKS into
# that store, so every repro script keeps working with its documented paths
# while the bytes survive any worktree rebuild.
#
# THE BUG THIS FILE NOW FIXES
#
# The previous `seed_store_link` was a no-op whenever the worktree path
# existed as a REAL DIRECTORY:
#
#     if [ -e "$REPO_ROOT/$name" ]; then return 0; fi     # <-- silent
#
# A rebuilt worktree has plain directories instead of symlinks, so the link
# was never re-created and every subsequent artefact was written into a
# directory that the next reconcile would delete.  The link is now asserted
# (`seed_store_link --migrate` moves the contents into the store and replaces
# the directory by the link), and `seed_store_guard` fails closed so that no
# script can quietly write heavy output into the worktree again.
#
# USAGE
#
#   bash repro/lib/seed_store.sh paths      # print the resolved paths
#   bash repro/lib/seed_store.sh link       # (re)create the worktree symlinks
#   bash repro/lib/seed_store.sh migrate    # link + move stray content into the store
#   bash repro/lib/seed_store.sh check      # health check (fail closed)
#   bash repro/lib/seed_store.sh manifest   # write <store>/MANIFEST.txt
#   bash repro/lib/seed_store.sh doctor     # check + manifest

# NOTE: this file is a LIBRARY as well as a program.  It must NOT change the
# shell options of the process that sources it: 28_doc_verify.sh deliberately
# runs with `set -uo pipefail` (no -e) so that it can inspect the exit code of
# the decision base, and a sourced `set -e` aborted it before it could print
# a verdict.  Strict mode is therefore enabled only in the dispatch block at
# the bottom, where this file runs as a program.

SEED_STORE_REL="${SEED_STORE_REL:-git_source/groot_nvidia/morphmimic-seed-data/repo}"
SEED_STORE_PREFIXES="${SEED_STORE_PREFIXES:-/mnt/test_cc_dev /home/ubuntu/work_dev/wqq/nfs/test_cc_dev}"

# The single source of truth: which worktree paths are store-backed.  Every
# heavy artefact must live under one of these names.
#
# NOTE: `docs` is deliberately NOT here: docs/ holds TRACKED repository
# content (docs/code_read/*.md) and must never be replaced by a symlink.
# The delivered record is protected separately — it exists in three copies
# (the git-tracked mirror in docs/code_read/, the durable copy in the store
# at <store>/docs/code_doc/, and the delivery copy in the user's doc repo),
# and repro/28_doc_verify.sh compares all three byte by byte.
SEED_PROTECTED="${SEED_PROTECTED:-data logs out assets runs}"

seed_store_resolve_root() {
  if [ -n "${SEED_STORE_ROOT:-}" ]; then
    printf '%s' "$SEED_STORE_ROOT"
    return 0
  fi
  local p
  for p in $SEED_STORE_PREFIXES; do
    if [ -d "$p/$SEED_STORE_REL" ]; then
      printf '%s' "$p/$SEED_STORE_REL"
      return 0
    fi
  done
  # Fall back to the store-relative location of THIS script
  # (<store>/repro/lib/seed_store.sh -> <store>), which is correct when the
  # script runs from the store copy itself.
  local self="${BASH_SOURCE[0]}"
  printf '%s' "$(cd "$(dirname "$self")/../.." && pwd)"
}

SEED_STORE_ROOT="$(seed_store_resolve_root)"
export SEED_STORE_ROOT

# The git worktree that links into the store (may be absent).
SEED_WORKTREE="${SEED_WORKTREE:-}"

# The repository root: <repo>/repro/lib/seed_store.sh -> <repo>.  When this
# file is sourced by repro/lib/common.sh the value is already set there.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export REPO_ROOT

# --- helpers ----------------------------------------------------------------

# The relative symlink target, so the SAME link resolves on both mount
# prefixes: from <repo>/.gsd-worktrees/<name> the store is two levels up in
# the export and one level out of the repository directory.
seed_store_relative_target() {
  local name="$1"
  local store_name store_parent
  store_name="$(basename "$SEED_STORE_ROOT")"
  store_parent="$(basename "$(dirname "$SEED_STORE_ROOT")")"
  printf '../../../%s/%s/%s' "$store_parent" "$store_name" "$name"
}

# seed_store_state <name> — one of:
#   linked      the worktree path is a symlink into the store   (good)
#   diverged    the worktree path is a REAL directory           (dangerous)
#   foreign     the worktree path is a symlink somewhere else   (needs a human)
#   missing     the worktree path does not exist               (fixable)
seed_store_state() {
  local name="$1" path="$2"
  if [ -L "$path" ]; then
    if [ "$(readlink -f "$path" 2>/dev/null || true)" = "$(readlink -f "$SEED_STORE_ROOT/$name" 2>/dev/null || true)" ]; then
      printf 'linked'
    else
      printf 'foreign'
    fi
    return 0
  fi
  if [ -d "$path" ]; then printf 'diverged'; return 0; fi
  if [ -e "$path" ]; then printf 'foreign'; return 0; fi
  printf 'missing'
}

seed_store_ensure_dirs() {
  mkdir -p "$SEED_STORE_ROOT/data/seed/_archives" \
           "$SEED_STORE_ROOT/data/seed_g1_npz50/subsets" \
           "$SEED_STORE_ROOT/logs/env" \
           "$SEED_STORE_ROOT/logs/train" \
           "$SEED_STORE_ROOT/logs/toolchain" \
           "$SEED_STORE_ROOT/out" \
           "$SEED_STORE_ROOT/assets" \
           "$SEED_STORE_ROOT/runs" \
           "$SEED_STORE_ROOT/docs/code_doc" 2>/dev/null || true
}

# seed_store_merge_tree <src dir> <dst dir>
# Moves every entry of <src> into <dst>, recursing into directories.
#
# NOTHING is ever deleted unless the two copies are PROVEN identical: a file
# whose target already exists is compared by size and (for files below
# MERGE_HASH_MAX bytes) by sha256; only then is the worktree copy dropped.
# Everything else is reported as CONFLICT and left in place for a human.
seed_store_merge_tree() {
  local src="$1" dst="$2" entry base ss ds
  local max="${MERGE_HASH_MAX:-104857600}"
  mkdir -p "$dst"
  for entry in "$src"/* "$src"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      if [ -d "$dst/$base" ] && [ ! -L "$dst/$base" ]; then
        seed_store_merge_tree "$entry" "$dst/$base"
        # the source directory is now empty: drop it, so the caller can
        # replace the worktree path by the symlink
        rmdir "$entry" 2>/dev/null || true
      elif [ -e "$dst/$base" ]; then
        echo "CONFLICT $dst/$base exists and is not a directory; left in place" >&2
      else
        mv -f "$entry" "$dst/$base"
        echo "MOVED $entry -> $dst/$base"
      fi
      continue
    fi
    if [ -e "$dst/$base" ]; then
      ss="$(stat -c %s "$entry" 2>/dev/null || echo -1)"
      ds="$(stat -c %s "$dst/$base" 2>/dev/null || echo -2)"
      if [ "$ss" = "$ds" ] && [ "$ss" -le "$max" ] 2>/dev/null; then
        local hs hd
        hs="$(sha256sum "$entry" 2>/dev/null | cut -d' ' -f1)"
        hd="$(sha256sum "$dst/$base" 2>/dev/null | cut -d' ' -f1)"
        if [ -n "$hs" ] && [ "$hs" = "$hd" ]; then
          rm -f "$entry"
          echo "DEDUPED $entry (identical to $dst/$base)"
          continue
        fi
      fi
      echo "CONFLICT $dst/$base differs from $entry (size $ds vs $ss); left in place" >&2
      continue
    fi
    mv -f "$entry" "$dst/$base"
    echo "MOVED $entry -> $dst/$base"
  done
}

# seed_store_link_impl <name> [--migrate]
#   linked    -> no-op
#   missing  -> create the relative symlink
#   diverged -> without --migrate: refuse (return 1).  With --migrate: move
#               the content into the store and replace it by the symlink.
#   foreign  -> never touched (return 1): a human has to decide.
#
# The name carries the "_impl" suffix because repro/lib/common.sh wraps it
# with a `seed_store_link` that adds the repository-local context.
seed_store_link_impl() {
  local name="$1"; shift
  local migrate=0
  [ "${1:-}" = "--migrate" ] && migrate=1

  [ -n "${SEED_STORE_ROOT:-}" ] || return 1
  local path="$REPO_ROOT/$name"
  local state; state="$(seed_store_state "$name" "$path")"

  case "$state" in
    linked)
      return 0
      ;;
    missing)
      seed_store_ensure_dirs
      mkdir -p "$SEED_STORE_ROOT/$name" 2>/dev/null || true
      ln -sfn "$(seed_store_relative_target "$name")" "$path"
      echo "LINKED $path -> $(seed_store_relative_target "$name")"
      return 0
      ;;
    foreign)
      echo "ERROR: $path is a symlink to $(readlink "$path"), not into the store" >&2
      echo "       refusing to touch it; decide manually" >&2
      return 1
      ;;
    diverged)
      if [ "$migrate" -ne 1 ]; then
        echo "ERROR: $path is a REAL DIRECTORY, not a symlink into the store" >&2
        echo "       artefacts written there die with the next worktree rebuild" >&2
        echo "       fix: bash repro/lib/seed_store.sh migrate" >&2
        return 1
      fi
      seed_store_ensure_dirs
      mkdir -p "$SEED_STORE_ROOT/$name" 2>/dev/null || true
      # Merge recursively: a diverged worktree directory usually holds the
      # SAME subtrees as the store (both were produced by an earlier run),
      # so a flat "move" would report a conflict for every directory.
      seed_store_merge_tree "$path" "$SEED_STORE_ROOT/$name"
      local conflicts=0 entry
      for entry in "$path"/* "$path"/.[!.]*; do
        [ -e "$entry" ] || continue
        echo "ERROR: $entry could not be moved into the store; left in place" >&2
        conflicts=$((conflicts + 1))
      done
      if [ "$conflicts" -ne 0 ]; then
        echo "ERROR: $path still holds $conflicts entries; not replaced by a link" >&2
        return 1
      fi
      rmdir "$path" 2>/dev/null || true
      if [ -d "$path" ]; then
        echo "ERROR: $path could not be replaced by a link" >&2
        return 1
      fi
      ln -sfn "$(seed_store_relative_target "$name")" "$path"
      echo "LINKED $path -> $(seed_store_relative_target "$name")"
      return 0
      ;;
  esac
  return 0
}

# Public alias (used when this file is executed directly).
seed_store_link() {
  seed_store_link_impl "$@"
}

# Public aliases for the subcommands, so other scripts can call them without
# dispatching through the "$0" guard below.
seed_store_check_impl()    { cmd_check "$@"; }
seed_store_migrate_impl()  { cmd_migrate "$@"; }
seed_store_manifest_impl() { cmd_manifest "$@"; }
seed_store_doctor_impl()   { cmd_doctor "$@"; }
seed_store_sync_doc_impl() { cmd_sync_doc "$@"; }
seed_store_check_doc_impl(){ cmd_check_doc "$@"; }

# seed_store_guard <name>... — fail closed when a worktree path is not
# store-backed.  Call this BEFORE writing anything heavy.
seed_store_guard() {
  local name path state bad=0
  for name in "$@"; do
    path="$REPO_ROOT/$name"
    state="$(seed_store_state "$name" "$path")"
    if [ "$state" != "linked" ]; then
      echo "STORE_GUARD_FAIL name=$name state=$state path=$path" >&2
      echo "  the store is $SEED_STORE_ROOT" >&2
      echo "  fix: bash repro/lib/seed_store.sh migrate" >&2
      bad=1
    else
      echo "STORE_GUARD_OK name=$name -> $(readlink "$path")"
    fi
  done
  return "$bad"
}

# --- subcommands ------------------------------------------------------------

cmd_paths() {
  echo "SEED_STORE_ROOT=$SEED_STORE_ROOT"
  echo "SEED_STORE_ARCHIVES=$SEED_STORE_ROOT/data/seed/_archives"
  echo "SEED_STORE_LOGS=$SEED_STORE_ROOT/logs/env"
  echo "SEED_PROTECTED=$SEED_PROTECTED"
}

cmd_link() {
  local name
  seed_store_ensure_dirs
  for name in $SEED_PROTECTED; do
    seed_store_link "$name" || return 1
  done
  echo "SEED_STORE_LINK_OK root=$SEED_STORE_ROOT"
}

cmd_migrate() {
  local name
  seed_store_ensure_dirs
  for name in $SEED_PROTECTED; do
    seed_store_link "$name" --migrate || return 1
  done
  echo "SEED_STORE_MIGRATE_OK root=$SEED_STORE_ROOT"
}

# The payload-critical invariants: if one of these is gone, a re-run would
# need hours of downloading/converting again.  Everything else is advisory.
_seed_store_required() {
  echo "$SEED_STORE_ROOT/data/seed/_archives"
  echo "$SEED_STORE_ROOT/data/seed_g1_npz50/manifest.csv"
  echo "$SEED_STORE_ROOT/data/seed_g1_npz50/subsets/1h.yaml"
  echo "$SEED_STORE_ROOT/logs/env"
}

_seed_store_advisory() {
  echo "$SEED_STORE_ROOT/data/seed_g1_npz50/human50"
  echo "$SEED_STORE_ROOT/logs/train/g1_amber_1h"
  echo "$SEED_STORE_ROOT/logs/toolchain"
  echo "$SEED_STORE_ROOT/out/g1_amber/policy.onnx"
  echo "$SEED_STORE_ROOT/out/g1_amber/g1_amber.json"
  echo "$SEED_STORE_ROOT/assets"
  echo "$SEED_STORE_ROOT/runs/eval"
  echo "$SEED_STORE_ROOT/runs/official"
  echo "$SEED_STORE_ROOT/docs/code_doc"
}

cmd_check() {
  local ok=0 path state name
  echo "SEED_STORE_ROOT=$SEED_STORE_ROOT"

  # 0. the store must not live inside a git worktree
  if [ -d "$SEED_STORE_ROOT/.git" ]; then
    echo "FAIL: the store lives inside a git repository: $SEED_STORE_ROOT"
    ok=1
  fi

  # 1. the store itself must be reachable and writable
  if [ ! -d "$SEED_STORE_ROOT" ]; then
    echo "FAIL: store root missing: $SEED_STORE_ROOT"
    echo "SEED_STORE_FAIL reason=store-root-missing"
    return 1
  fi
  if [ ! -w "$SEED_STORE_ROOT" ]; then
    echo "FAIL: store root is not writable: $SEED_STORE_ROOT"
    ok=1
  fi

  # 2. every protected name must exist in the store AND be linked from the
  #    worktree (a real directory there means "the next rebuild deletes it")
  for name in $SEED_PROTECTED; do
    if [ ! -d "$SEED_STORE_ROOT/$name" ]; then
      echo "FAIL: store dir missing: $SEED_STORE_ROOT/$name"
      ok=1
      continue
    fi
    if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ]; then
      state="$(seed_store_state "$name" "$REPO_ROOT/$name")"
      case "$state" in
        linked)  echo "OK   store/$name linked from the worktree" ;;
        diverged) echo "FAIL: $REPO_ROOT/$name is a REAL DIRECTORY (artefacts there will be deleted)"
                  echo "      fix: bash repro/lib/seed_store.sh migrate"
                  ok=1 ;;
        foreign) echo "FAIL: $REPO_ROOT/$name points outside the store"
                  ok=1 ;;
        missing) echo "WARN: $REPO_ROOT/$name is not linked yet"
                  echo "      fix: bash repro/lib/seed_store.sh link" ;;
      esac
    fi
  done

  # 3. payload-critical invariants
  local p
  for p in $(_seed_store_required); do
    if [ -e "$p" ]; then
      echo "OK   required $p"
    else
      echo "FAIL: required payload missing: $p"
      ok=1
    fi
  done

  # 4. advisory artefacts (present = good, missing = warn)
  for p in $(_seed_store_advisory); do
    if [ -e "$p" ]; then echo "OK   optional $p"; else echo "WARN: optional artefact missing: $p"; fi
  done

  # 4b. the tool-chain probe output is the artefact that the 2026-11-11
  #     worktree rebuild destroyed.  It is advisory (the verdicts live in
  #     docs/code_read/TOOLCHAIN.md), but its absence must be GREPPABLE so
  #     that "it was deleted again" is noticed instead of being silent.
  if [ ! -d "$SEED_STORE_ROOT/logs/toolchain" ] || [ ! -f "$SEED_STORE_ROOT/logs/env/07_toolchain.txt" ]; then
    echo "WARN: toolchain-probe-output missing (not regenerated after the 2026-11-11 worktree rebuild); verdicts survive in docs/code_read/TOOLCHAIN.md"
    echo "STORE_GUARD_WARN name=toolchain-probe-output reason=not-generated"
  fi

  if [ "$ok" -eq 0 ]; then
    echo "SEED_STORE_OK"
  else
    echo "SEED_STORE_FAIL reason=store-incomplete"
  fi
  return "$ok"
}

cmd_manifest() {
  # The manifest is the inventory used to NOTICE an accidental deletion, so
  # it must be cheap enough to run on every session start: the store holds
  # ~484 GB in ~300k files, so a full `du` or a hash of the 23.5 GB / 45 GB
  # archives is not acceptable here (it exceeded a 300 s budget).
  #
  # Therefore: sizes come from `stat` on named artefacts, digests are
  # computed only for files below MANIFEST_HASH_MAX bytes, and the big
  # archives are described by their size plus the checksum that
  # 09_seed_verify.sh already recorded in the archived SHA256SUMS.
  local out="$SEED_STORE_ROOT/MANIFEST.txt"
  local max="${MANIFEST_HASH_MAX:-104857600}"
  local name dir entries
  {
    echo "# morphmimic persistent store manifest"
    echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# store root: $SEED_STORE_ROOT"
    echo "# this file is the inventory used to DETECT an accidental deletion:"
    echo "#   bash repro/30_store_guard.sh check   # structural invariants"
    echo "# digests are computed for files <= ${max} B; the two seed archives are"
    echo "# described by size and by the checksums in data/seed/_archives/SHA256SUMS"
    echo
    echo "## directories (top level entry count)"
    for name in $SEED_PROTECTED docs; do
      dir="$SEED_STORE_ROOT/$name"
      if [ -d "$dir" ]; then
        entries="$(ls -1A "$dir" 2>/dev/null | wc -l)"
        printf '%-8s entries=%-8s %s\n' "$name" "$entries" "$dir"
      else
        printf '%-8s MISSING  %s\n' "$name" "$dir"
      fi
    done
    echo
    echo "## key artefacts"
    local f size
    for f in \
      "$SEED_STORE_ROOT/data/seed/_archives/g1.tar.gz" \
      "$SEED_STORE_ROOT/data/seed/_archives/soma_uniform.tar.gz" \
      "$SEED_STORE_ROOT/data/seed/_archives/SHA256SUMS" \
      "$SEED_STORE_ROOT/data/seed_g1_npz50/manifest.csv" \
      "$SEED_STORE_ROOT/data/seed_g1_npz50/subsets/1h.yaml" \
      "$SEED_STORE_ROOT/logs/env/07_toolchain.txt" \
      "$SEED_STORE_ROOT/logs/env/30_store_guard.txt" \
      "$SEED_STORE_ROOT/logs/env/snapshot.txt" \
      "$SEED_STORE_ROOT/out/g1_amber/policy.onnx" \
      "$SEED_STORE_ROOT/out/g1_amber/g1_amber.json" \
      "$SEED_STORE_ROOT/runs/official/compare_self_vs_official.csv" \
      "$SEED_STORE_ROOT/docs/code_doc/MorphMimic完整复现记录.md"
    do
      if [ ! -f "$f" ]; then
        printf '%-12s %-16s MISSING  %s\n' "-" "-" "$f"
        continue
      fi
      size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
      if [ "$size" -le "$max" ]; then
        printf '%-12s %-16s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$size" "$f"
      else
        printf '%-12s %-16s %s\n' "(too big)" "$size" "$f"
      fi
    done
    echo
    echo "## seed archive checksums (as recorded by 09_seed_verify.sh)"
    if [ -f "$SEED_STORE_ROOT/data/seed/_archives/SHA256SUMS" ]; then
      sed 's/^/  /' "$SEED_STORE_ROOT/data/seed/_archives/SHA256SUMS"
    else
      echo "  (missing: data/seed/_archives/SHA256SUMS)"
    fi
    echo
    echo "## inventory of the training run"
    if [ -d "$SEED_STORE_ROOT/logs/train/g1_amber_1h" ]; then
      ls -1 "$SEED_STORE_ROOT/logs/train/g1_amber_1h" 2>/dev/null | sed 's/^/  /'
    else
      echo "  (missing: logs/train/g1_amber_1h)"
    fi
  } > "$out"
  echo "SEED_STORE_MANIFEST_OK path=$out"
}

cmd_doctor() {
  cmd_check || true
  cmd_manifest
}

# --- the delivered record: three copies, one contract ----------------------
#
#   1. git  : docs/code_read/MorphMimic完整复现记录.md   (tracked, survives
#             any worktree rebuild by definition)
#   2. store: <store>/docs/code_doc/MorphMimic完整复现记录.md  (durable copy
#             inside the persistent store)
#   3. delivery: the user's doc repository, reached through the absolute
#             symlink docs/code_doc (that is where the record is DELIVERED)
#
# cmd_sync_doc copies the delivery copy into the store and asserts that all
# three are byte identical; cmd_check_doc reports the state.
DOC_NAME="MorphMimic完整复现记录.md"

_seed_store_delivery_dir() {
  printf '%s' "${SEED_DOC_DELIVERY_DIR:-$(readlink -f "$REPO_ROOT/docs/code_doc" 2>/dev/null || true)}"
}

cmd_sync_doc() {
  local delivery store_dir repo_mirror rc=0
  delivery="$(_seed_store_delivery_dir)"
  store_dir="$SEED_STORE_ROOT/docs/code_doc"
  repo_mirror="$REPO_ROOT/docs/code_read/$DOC_NAME"

  if [ -z "$delivery" ] || [ ! -d "$delivery" ]; then
    echo "WARN: no delivery directory found (docs/code_doc does not resolve)"
    return 0
  fi

  # the store copy must be a REAL directory, never a symlink into a
  # machine-specific path: the store has to stand on its own.
  if [ -L "$store_dir" ]; then
    rm -f "$store_dir"
  fi
  mkdir -p "$store_dir"
  local f
  for f in "$delivery"/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$store_dir/$(basename "$f")"
  done

  # three-way byte comparison
  local a b c
  a="$repo_mirror"; b="$store_dir/$DOC_NAME"; c="$delivery/$DOC_NAME"
  if [ -f "$a" ] && [ -f "$b" ] && [ -f "$c" ]; then
    local sa sb sc
    sa="$(sha256sum "$a" | cut -d' ' -f1)"
    sb="$(sha256sum "$b" | cut -d' ' -f1)"
    sc="$(sha256sum "$c" | cut -d' ' -f1)"
    if [ "$sa" = "$sb" ] && [ "$sb" = "$sc" ]; then
      echo "SEED_STORE_DOC_OK copies=3 sha256=$sa"
      return 0
    fi
    echo "SEED_STORE_DOC_FAIL reason=copies-differ repo=$sa store=$sb delivery=$sc" >&2
    return 1
  fi
  for f in "$a" "$b" "$c"; do
    [ -f "$f" ] || echo "WARN: document copy missing: $f"
  done
  echo "SEED_STORE_DOC_FAIL reason=copy-missing" >&2
  rc=1
  return "$rc"
}

cmd_check_doc() {
  local delivery store_dir repo_mirror
  delivery="$(_seed_store_delivery_dir)"
  store_dir="$SEED_STORE_ROOT/docs/code_doc"
  repo_mirror="$REPO_ROOT/docs/code_read/$DOC_NAME"
  local missing=0
  [ -f "$repo_mirror" ] || { echo "WARN: git mirror missing: $repo_mirror"; missing=1; }
  [ -f "$store_dir/$DOC_NAME" ] || { echo "WARN: store copy missing: $store_dir/$DOC_NAME"; missing=1; }
  [ -f "$delivery/$DOC_NAME" ] || { echo "WARN: delivery copy missing: $delivery/$DOC_NAME"; missing=1; }
  if [ "$missing" -eq 0 ]; then
    local sa sb sc
    sa="$(sha256sum "$repo_mirror" | cut -d' ' -f1)"
    sb="$(sha256sum "$store_dir/$DOC_NAME" | cut -d' ' -f1)"
    sc="$(sha256sum "$delivery/$DOC_NAME" | cut -d' ' -f1)"
    if [ "$sa" = "$sb" ] && [ "$sb" = "$sc" ]; then
      echo "SEED_STORE_DOC_OK copies=3 sha256=$sa"
      return 0
    fi
    echo "SEED_STORE_DOC_FAIL reason=copies-differ repo=$sa store=$sb delivery=$sc" >&2
    return 1
  fi
  echo "SEED_STORE_DOC_FAIL reason=copy-missing" >&2
  return 1
}

# Only dispatch when EXECUTED.  When SOURCED (repro/lib/common.sh sources this
# file to resolve SEED_STORE_ROOT) the store root and the helper functions
# must be defined but no subcommand may run.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-paths}" in
    paths)   cmd_paths ;;
    link)    cmd_link ;;
    migrate) cmd_migrate ;;
    check)   cmd_check ;;
    manifest) cmd_manifest ;;
    doctor)  cmd_doctor ;;
    *) echo "usage: $0 [paths|link|migrate|check|manifest|doctor]" >&2; exit 2 ;;
  esac
fi
