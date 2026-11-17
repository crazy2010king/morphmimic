#!/usr/bin/env bash
# repro/tests/test_store_guard.sh — offline fixture battery for the
# persistent-store contract (repro/lib/seed_store.sh + repro/30_store_guard.sh).
#
# WHY
#   Two heavy losses were caused by the same mechanism: GSD deletes a
#   milestone worktree that is not registered with git, and the recursive
#   deletion takes every untracked file with it.
#     * 2026-11-11  23.5 GB of g1.tar.gz + the metadata CSV
#     * 2026-11-11  the whole tool-chain probe output (logs/toolchain/**)
#
#   The second loss had a precise cause: the probe wrote into the worktree's
#   PLAIN logs/ directory, because the old seed_store_link() silently
#   accepted any existing path:
#       if [ -e "$REPO_ROOT/$name" ]; then return 0; fi
#   So a rebuilt worktree (plain directories instead of symlinks) kept the
#   "linked" state forever and every artefact went into a directory that the
#   next reconcile deleted.
#
#   This battery pins the FIXED contract:
#     1. a missing worktree path becomes a RELATIVE symlink into the store
#     2. a REAL DIRECTORY in the worktree is refused without --migrate
#        (nothing is lost, nothing is silently accepted)
#     3. with --migrate the content is MOVED into the store and the path
#        becomes the symlink again (the repair the old code could not do)
#     4. a symlink pointing outside the store is never touched
#     5. the guard fails closed on a diverged path
#     6. check() detects a missing payload with a fixed reason set
#     7. manifest() writes a cheap, greppable inventory
#     8. the three copies of the delivered record are compared byte by byte
#
# No network, no GPU, no payload: every fixture is synthetic and lives in a
# temp dir that is removed on exit.
#
# Run locally:   bash repro/tests/test_store_guard.sh
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
STORE_LIB="$LIB_DIR/seed_store.sh"
GUARD="$REPO_ROOT/repro/30_store_guard.sh"

PASS=0
FAIL=0
ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The fixtures reproduce the REAL export geometry, because the store is
# addressed by a RELATIVE symlink:
#   <export>/git_source/groot_nvidia/morphmimic/.gsd-worktrees/<wt>   (worktree)
#   <export>/git_source/groot_nvidia/morphmimic-seed-data/repo        (store)
EXPORT="$TMP/export"
WT="$EXPORT/git_source/groot_nvidia/morphmimic/.gsd-worktrees/W"
STORE="$EXPORT/git_source/groot_nvidia/morphmimic-seed-data/repo"

make_fixture() {
  rm -rf "$EXPORT"
  mkdir -p "$WT" "$STORE/logs/env" "$STORE/data/seed/_archives"
  mkdir -p "$STORE/out" "$STORE/assets" "$STORE/runs"
  printf 'seed\n' >"$STORE/data/seed/_archives/g1.tar.gz"
  printf 'meta\n' >"$STORE/data/seed/_archives/SHA256SUMS"
  mkdir -p "$STORE/data/seed_g1_npz50/subsets"
  printf 'clips: []\n' >"$STORE/data/seed_g1_npz50/manifest.csv"
  printf 'clips: []\n' >"$STORE/data/seed_g1_npz50/subsets/1h.yaml"
  printf 'log\n' >"$STORE/logs/env/marker.txt"
}

# Run a snippet with the store library loaded against the fixture.
in_fixture() {
  (
    set -uo pipefail
    export SEED_STORE_ROOT="$STORE"
    export REPO_ROOT="$WT"
    export SEED_PROTECTED="data logs out assets runs"
    # shellcheck source=../lib/seed_store.sh
    source "$STORE_LIB" >/dev/null 2>&1
    eval "$1"
  )
}

# ============================================================================
# 1. the library is sourceable and exposes the contract
# ============================================================================
for fn in seed_store_resolve_root seed_store_state seed_store_link_impl \
          seed_store_guard cmd_check cmd_manifest cmd_migrate cmd_sync_doc; do
  if in_fixture "declare -F $fn >/dev/null 2>&1"; then
    ok "seed_store.sh exposes $fn"
  else
    bad "seed_store.sh is missing $fn"
  fi
done

# ============================================================================
# 2. a missing worktree path becomes a RELATIVE symlink into the store
# ============================================================================
make_fixture
out="$(in_fixture 'seed_store_link_impl data' 2>&1)"
if [ -L "$WT/data" ]; then
  ok "a missing path becomes a symlink"
  target="$(readlink "$WT/data")"
  case "$target" in
    /*) bad "the symlink must be relative, got $target" ;;
    *)  ok "the symlink is relative ($target)" ;;
  esac
  if [ "$(readlink -f "$WT/data")" = "$(readlink -f "$STORE/data")" ]; then
    ok "the symlink resolves to the store"
  else
    bad "the symlink does not resolve to the store"
  fi
else
  bad "a missing path did not become a symlink: $out"
fi

# ============================================================================
# 3. a REAL DIRECTORY is refused without --migrate (the silent-failure bug)
# ============================================================================
make_fixture
rm -f "$WT/data"
mkdir -p "$WT/data/seed_g1_npz50"
printf 'stray\n' >"$WT/data/stray.txt"
out="$(in_fixture 'seed_store_link_impl data' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a real directory is refused without --migrate (rc=$rc)"
else
  bad "a real directory was accepted silently — this is the 2026-11-11 bug"
fi
if printf '%s' "$out" | grep -q 'REAL DIRECTORY'; then
  ok "the refusal names the cause (REAL DIRECTORY)"
else
  bad "the refusal does not name the cause: $out"
fi
if [ -f "$WT/data/stray.txt" ]; then
  ok "the refusal did NOT touch the content"
else
  bad "the refusal destroyed the content"
fi

# ============================================================================
# 4. with --migrate the content is MOVED into the store and re-linked
# ============================================================================
out="$(in_fixture 'seed_store_link_impl data --migrate' 2>&1)"
if [ -L "$WT/data" ]; then
  ok "--migrate re-links the path"
else
  bad "--migrate did not create the symlink: $out"
fi
if [ -f "$STORE/data/stray.txt" ]; then
  ok "--migrate moved the content into the store"
else
  bad "--migrate lost the content: $out"
fi
if [ ! -d "$WT/data" ] || [ -L "$WT/data" ]; then
  ok "the worktree path is a symlink, not a directory any more"
else
  bad "the worktree path is still a real directory"
fi
if [ "$(cat "$WT/data/stray.txt" 2>/dev/null)" = "stray" ]; then
  ok "the stray content is reachable through the link (it lives in the store)"
else
  bad "the stray content is not reachable through the link"
fi

# ============================================================================
# 5. a symlink pointing outside the store is never touched
# ============================================================================
make_fixture
rm -f "$WT/logs"
ln -s /tmp "$WT/logs"
out="$(in_fixture 'seed_store_link_impl logs --migrate' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ -L "$WT/logs" ] && [ "$(readlink "$WT/logs")" = "/tmp" ]; then
  ok "a foreign symlink is refused and left untouched"
else
  bad "a foreign symlink was modified: $out"
fi

# ============================================================================
# 6. the guard fails closed on a diverged path
# ============================================================================
make_fixture
rm -f "$WT/runs"
mkdir -p "$WT/runs"
out="$(in_fixture 'seed_store_guard runs' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'STORE_GUARD_FAIL'; then
  ok "the guard fails closed on a diverged path"
else
  bad "the guard did not fail closed: $out"
fi
if printf '%s' "$out" | grep -q 'seed_store.sh migrate'; then
  ok "the guard prints the repair command"
else
  bad "the guard does not print the repair command: $out"
fi

# the guard passes when the path is linked
make_fixture
out="$(in_fixture 'seed_store_link_impl data >/dev/null; seed_store_guard data' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'STORE_GUARD_OK'; then
  ok "the guard passes on a linked path"
else
  bad "the guard failed on a linked path: $out"
fi

# ============================================================================
# 7. check() detects a missing payload with a fixed reason set
# ============================================================================
make_fixture
out="$(in_fixture 'cmd_check' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SEED_STORE_OK'; then
  ok "check() passes on an intact fixture"
else
  bad "check() failed on an intact fixture: $out"
fi

rm -f "$STORE/data/seed_g1_npz50/manifest.csv"
out="$(in_fixture 'cmd_check' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'SEED_STORE_FAIL reason=store-incomplete'; then
  ok "check() fails closed when a required payload is missing"
else
  bad "check() did not notice the missing payload: $out"
fi

# ============================================================================
# 8. manifest() writes a cheap, greppable inventory
# ============================================================================
make_fixture
out="$(in_fixture 'cmd_manifest' 2>&1)"
if [ -f "$STORE/MANIFEST.txt" ] && grep -q 'key artefacts' "$STORE/MANIFEST.txt"; then
  ok "manifest() writes the inventory"
else
  bad "manifest() did not write the inventory: $out"
fi
if grep -q 'data/seed/_archives/g1.tar.gz' "$STORE/MANIFEST.txt"; then
  ok "the inventory lists the seed archive"
else
  bad "the inventory does not list the seed archive"
fi

# ============================================================================
# 9. the three copies of the delivered record are compared byte by byte
# ============================================================================
make_fixture
DELIV="$TMP/delivery"
mkdir -p "$DELIV" "$STORE/docs/code_doc" "$WT/docs/code_read"
printf 'record body\n' >"$DELIV/MorphMimic完整复现记录.md"
printf 'record body\n' >"$WT/docs/code_read/MorphMimic完整复现记录.md"
out="$(in_fixture "SEED_DOC_DELIVERY_DIR='$DELIV' cmd_sync_doc" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SEED_STORE_DOC_OK copies=3'; then
  ok "the three copies of the record are byte identical"
else
  bad "the record copies were not verified: $out"
fi

printf 'different\n' >"$WT/docs/code_read/MorphMimic完整复现记录.md"
out="$(in_fixture "SEED_DOC_DELIVERY_DIR='$DELIV' cmd_check_doc" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'SEED_STORE_DOC_FAIL'; then
  ok "a diverging record copy is detected"
else
  bad "a diverging record copy was not detected: $out"
fi

# ============================================================================
# 10. the guard script exists, is syntactically valid and fails closed
# ============================================================================
if bash -n "$GUARD" 2>/dev/null; then
  ok "30_store_guard.sh parses"
else
  bad "30_store_guard.sh does not parse"
fi
if grep -q 'STORE_GUARD_OK' "$GUARD" && grep -q 'STORE_GUARD_FAIL' "$GUARD"; then
  ok "30_store_guard.sh carries the marker contract"
else
  bad "30_store_guard.sh lacks the marker contract"
fi

# ============================================================================
# summary
# ============================================================================
printf '\n== test_store_guard.sh: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
