#!/usr/bin/env bash
# repro/04_smoke.sh — the 32-env simulation smoke test.
#
# The highest-risk step of S01: it proves that the simulation stack really runs
# on this machine (the MJCF assets ship with the wheel, the warp/mujoco-warp
# kernels compile on the GPU, the GPU simulation steps and the reward is a
# finite number).
#
# The registered task ids cannot be used yet: `MultiMotionCommand.__init__`
# raises ValueError when `subset_yaml` is empty, and the real npz clips only
# arrive in S03/S04. So the smoke test ships its own synthetic standing clip
# (repro/lib/make_smoke_clip.py) and runs the env over it
# (repro/lib/smoke_env.py).
#
# Everything is logged to logs/env/04_smoke.txt; the log ends with SMOKE_OK.
#
# The proxy is inlined into THIS process only (see repro/lib/common.sh); it is
# never written to any system configuration.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
require_container

cd "$REPO_ROOT"

MAIN_LOG="$LOG_DIR/04_smoke.txt"
DATA_ROOT="$REPO_ROOT/data/smoke/seed_g1_npz50"
SUBSET_YAML="$DATA_ROOT/subsets/smoke.yaml"

# The log is APPENDED to, so the evidence of a cold run (the warp kernel JIT)
# survives the warm runs that follow it. repro/00_env.sh appends the whole run
# to logs/env/00_env.txt on top of this.
echo "### RUN $(date -u +%Y-%m-%dT%H:%M:%SZ): 04_smoke.sh" | tee -a "$MAIN_LOG"
echo "=== 04_smoke.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$MAIN_LOG"
echo "REPO_ROOT=$REPO_ROOT" | tee -a "$MAIN_LOG"
echo "proxy(inline, process-scoped)=$PROXY" | tee -a "$MAIN_LOG"
echo "warp cache: ~/.cache/warp (the first run JITs the kernels, the later ones" | tee -a "$MAIN_LOG"
echo "hit the cache; a container restart loses it)" | tee -a "$MAIN_LOG"

t_start=$(date +%s)

# --- step 1: the synthetic standing clip ------------------------------------
echo "" | tee -a "$MAIN_LOG"
if ! run_logged "$MAIN_LOG" \
      uv run --frozen --no-sync python repro/lib/make_smoke_clip.py \
      --out-root "$DATA_ROOT"; then
  echo "ERROR: the smoke clip could not be built" >&2
  exit 1
fi

if [ ! -f "$DATA_ROOT/smoke_stand/stand.npz" ]; then
  echo "ERROR: $DATA_ROOT/smoke_stand/stand.npz was not written" >&2
  exit 1
fi
if [ ! -f "$SUBSET_YAML" ]; then
  echo "ERROR: $SUBSET_YAML was not written" >&2
  exit 1
fi
echo "### STEP smoke_clip DONE" | tee -a "$MAIN_LOG"

# --- step 2: the 32-env simulation ------------------------------------------
echo "" | tee -a "$MAIN_LOG"
if ! run_logged "$MAIN_LOG" \
      uv run --frozen --no-sync python repro/lib/smoke_env.py \
      --subset-yaml "$SUBSET_YAML" --num-envs 32 --steps 50; then
  echo "ERROR: the 32-env simulation smoke test failed" >&2
  exit 1
fi
echo "### STEP smoke_env DONE" | tee -a "$MAIN_LOG"

t_end=$(date +%s)
echo "" | tee -a "$MAIN_LOG"
echo "SMOKE_ELAPSED_SECONDS_$((t_end - t_start))" | tee -a "$MAIN_LOG"

# The warp kernel JIT cost (for S09): the first run compiles the mujoco-warp
# kernels into ~/.cache/warp (the "Module ... (compiled)" lines above), every
# later run loads them from that cache. A container restart loses the cache and
# the next run pays the JIT again.
warp_cache="${WARP_CACHE_DIR:-/root/.cache/warp}"
echo "WARP_CACHE_DIR_$warp_cache" | tee -a "$MAIN_LOG"
echo "WARP_CACHE_SIZE_$(du -sh "$warp_cache" 2>/dev/null | cut -f1 || echo unknown)" | tee -a "$MAIN_LOG"
echo "WARP_JIT_NOTE the first run JITs the mujoco-warp kernels into \$WARP_CACHE_DIR (the 'Module ... (compiled)' lines); later runs load them from the cache; a container restart loses it" | tee -a "$MAIN_LOG"

# --- marker assertions ------------------------------------------------------
missing=0
for marker in "SMOKE_CLIP_OK" "NUM_ENVS_32" "REWARD_MEAN_FINITE" "SMOKE_ENV_OK"; do
  if ! grep -aqF -- "$marker" "$MAIN_LOG"; then
    echo "ERROR: missing marker in $MAIN_LOG: $marker" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "ERROR: the smoke test did not produce the expected markers" >&2
  exit 1
fi

# The reward must be a real number, not NaN.
reward_line="$(grep -aE '^REWARD_MEAN_-?[0-9]+\.[0-9]+' "$MAIN_LOG" | tail -n1)"
if ! printf '%s' "$reward_line" | grep -aqE '^REWARD_MEAN_-?[0-9]+\.[0-9]+'; then
  echo "ERROR: the reward mean is not a finite number: ${reward_line:-<none>}" >&2
  exit 1
fi

echo "SMOKE_OK" | tee -a "$MAIN_LOG"
