#!/usr/bin/env bash
# repro/tests/test_deploy_assets.sh — the OFFLINE battery of the asset
# export orchestrator (repro/21_assets.sh).
#
# The battery drives the REAL orchestrator with a FAKE `uv` on the PATH: the
# stub stands in for
#
#     uv run --group export --frozen --offline python -c "import mjlab, mujoco"
#     uv run --group export --frozen --offline python -m deploy.sim2sim.export_assets ...
#
# so neither the container, nor a GPU, nor mjlab, nor the real exporter are
# needed.  Every scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# and every positive path asserts the landing spot, the published artefacts
# and the ABSENCE of any staging residue.
#
# usage: bash repro/tests/test_deploy_assets.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/repro/21_assets.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '     %s\n' "$2"
  return 0
}

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi
}
assert_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing=[$3] in=[$2]" ;;
  esac
}
assert_not_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) fail "$1" "unexpected=[$3] in=[$2]" ;;
    *) pass "$1" ;;
  esac
}
assert_rc_zero() { # <label> <rc>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "rc=$2"; fi
}
assert_rc_nonzero() { # <label> <rc>
  if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "rc=0"; fi
}
assert_file() { # <label> <path>
  if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing file: $2"; fi
}
assert_nonempty_file() { # <label> <path>
  if [ -f "$2" ] && [ -s "$2" ]; then pass "$1"; else fail "$1" "missing/empty file: $2"; fi
}
assert_absent() { # <label> <path>
  if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected path: $2"; fi
}
assert_file_count() { # <label> <dir> <glob> <expected>
  local n
  n="$(find "$2" -maxdepth 1 -type f -name "$3" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$1" "$4" "$n"
}
assert_line_count() { # <label> <file> <expected>
  local n
  n="$(wc -l <"$2" 2>/dev/null | tr -d ' ')"
  assert_eq "$1" "$3" "$n"
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# --- the fake `uv` ---------------------------------------------------------
# It understands the two commands the orchestrator issues:
#   uv ... python -c "<code>"           the import probe
#   uv ... python -m <module> <args...>  the upstream exporter
# The behaviour is steered by environment variables so one stub serves every
# scenario:
#   FAKE_UV_FAIL_IMPORT=1     the import probe fails
#   FAKE_UV_FAIL_EXPORT=1     the exporter fails (non-zero exit)
#   FAKE_UV_SHORT=1           the exporter writes only half of the clips
#   FAKE_UV_EMPTY_NPZ=1       the exporter writes one zero-byte clip
#   FAKE_UV_NO_XML=1          the exporter writes no scene xml
cat >"$BIN/uv" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args=("$@")
mode=""
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = "python" ]; then mode="${args[$((i + 1))]:-}"; break; fi
done
case "$mode" in
  -c)
    if [ "${FAKE_UV_FAIL_IMPORT:-0}" = "1" ]; then
      echo "fake uv: import of mjlab failed" >&2
      exit 1
    fi
    echo "fake uv: mjlab and mujoco imported"
    exit 0
    ;;
  -m) ;;
  *)
    echo "fake uv: unsupported command: $*" >&2
    exit 2
    ;;
esac

# the exporter: parse --robot / --subset-yaml / --clips / --out
robot="g1_amber"
out=""
clips=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --robot) robot="$2"; shift 2 ;;
    --subset-yaml) shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --clips)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in --*) break ;; esac
        clips+=("$1"); shift
      done
      ;;
    *) shift ;;
  esac
done

if [ "${FAKE_UV_FAIL_EXPORT:-0}" = "1" ]; then
  echo "fake uv: the exporter failed" >&2
  exit 3
fi

mkdir -p "$out/meshes/$robot"
printf 'fake mesh\n' >"$out/meshes/$robot/mesh_0.stl"
if [ "${FAKE_UV_NO_XML:-0}" != "1" ]; then
  printf '<mujoco model="fake">\n  <worldbody/>\n</mujoco>\n' >"$out/$robot.xml"
fi

count=${#clips[@]}
if [ "${FAKE_UV_SHORT:-0}" = "1" ] && [ "$count" -gt 1 ]; then
  count=$((count / 2))
fi
i=0
while [ "$i" -lt "$count" ]; do
  clip="${clips[$i]}"
  mkdir -p "$out/clips/$robot"
  if [ "${FAKE_UV_EMPTY_NPZ:-0}" = "1" ] && [ "$i" -eq 0 ]; then
    : >"$out/clips/$robot/$clip.npz"
  else
    printf 'fake npz for %s\n' "$clip" >"$out/clips/$robot/$clip.npz"
  fi
  i=$((i + 1))
done
echo "[export] $robot: $count clips exported into $out"
exit 0
STUB
chmod +x "$BIN/uv"

# --- the fixture subset yaml ------------------------------------------------
# 20 clips: with the default stride of the battery (5) the sample is 4 clips
# (the indices 0, 5, 10, 15).
SUBSET="$TMP/subset.yaml"
{
  printf 'root: %s/does-not-exist\n' "$TMP"
  printf 'hours: 1.0\n'
  printf 'clips:\n'
  i=0
  while [ "$i" -lt 20 ]; do
    printf -- '- 2207%02d/clip_%03d__A%03d.npz\n' "$((i % 12 + 1))" "$i" "$i"
    i=$((i + 1))
  done
} >"$SUBSET"

EMPTY_SUBSET="$TMP/empty.yaml"
printf 'root: /nowhere\nhours: 1.0\nclips:\n' >"$EMPTY_SUBSET"

ASSETS="$TMP/assets"
LOGS="$TMP/logs"

# run <subcommand> [env assignments...] — runs the orchestrator and stores
# the output in $OUT and the exit code in $RC.
run() {
  local sub="$1"; shift
  OUT="$(env PATH="$BIN:$PATH" \
    ASSETS_ALLOW_LOCAL=1 \
    ASSETS_DIR="$ASSETS" \
    ASSETS_SUBSET_YAML="${SUBSET_OVERRIDE:-$SUBSET}" \
    ASSETS_SAMPLE_STRIDE="${STRIDE_OVERRIDE:-5}" \
    ASSETS_LOG_DIR="$LOGS" \
    "$@" \
    bash "$ORCH" "$sub" 2>&1)"
  RC=$?
}

staging_residue() {
  find "$ASSETS" -maxdepth 1 -name '.staging-*' 2>/dev/null | wc -l | tr -d ' '
}

echo "== 21_assets.sh: env gate =="

# the assets live in the seed store (they are binary artefacts and must not
# enter git), so the store must link them and git must ignore them.
assert_contains "the seed store links the assets directory" \
  "$(cat "$REPO_ROOT/repro/lib/seed_store.sh")" "for link in data logs out assets"
assert_contains "common.sh links the assets directory" \
  "$(cat "$REPO_ROOT/repro/lib/common.sh")" "seed_store_link assets"
assert_contains "the assets are git-ignored" \
  "$(cat "$REPO_ROOT/.gitignore")" "/assets/"

run env
assert_rc_zero "env gate exits 0" "$RC"
assert_contains "env gate prints DEPLOY_ASSETS_ENV_OK" "$OUT" "DEPLOY_ASSETS_ENV_OK"
assert_contains "env gate reports the subset clip count" "$OUT" "clips=20"
assert_contains "env gate reports the sampled clip count" "$OUT" "sampled=4"
assert_contains "env gate reports the robot" "$OUT" "robot=g1_amber"

SUBSET_OVERRIDE="$TMP/nope.yaml" run env
assert_rc_nonzero "env gate fails without a subset yaml" "$RC"
assert_contains "env gate reports subset-missing" "$OUT" "DEPLOY_ASSETS_ENV_FAIL reason=subset-missing"
assert_not_contains "env gate prints no OK marker on failure" "$OUT" "_OK"

SUBSET_OVERRIDE="$EMPTY_SUBSET" run env
assert_rc_nonzero "env gate fails on an empty subset" "$RC"
assert_contains "env gate reports subset-empty" "$OUT" "DEPLOY_ASSETS_ENV_FAIL reason=subset-empty"
assert_not_contains "env gate prints no OK marker on an empty subset" "$OUT" "_OK"

run env FAKE_UV_FAIL_IMPORT=1
assert_rc_nonzero "env gate fails when the import probe fails" "$RC"
assert_contains "env gate reports import-failed" "$OUT" "DEPLOY_ASSETS_ENV_FAIL reason=import-failed"
assert_not_contains "env gate prints no OK marker on an import failure" "$OUT" "_OK"

# a landing spot whose parent is a regular file can never be created
printf 'not a directory\n' >"$TMP/afile"
ASSETS="$TMP/afile/assets" run env
assert_rc_nonzero "env gate fails when the landing spot is not creatable" "$RC"
assert_contains "env gate reports assets-not-writable" "$OUT" "DEPLOY_ASSETS_ENV_FAIL reason=assets-not-writable"
assert_not_contains "env gate prints no OK marker on an unwritable landing spot" "$OUT" "_OK"
ASSETS="$TMP/assets"

echo "== 21_assets.sh: export =="

run export
assert_rc_zero "export exits 0" "$RC"
assert_contains "export prints DEPLOY_ASSETS_OK" "$OUT" "DEPLOY_ASSETS_OK"
assert_contains "export reports the sampled clip count" "$OUT" "DEPLOY_ASSETS_OK clips=4"
assert_nonempty_file "the scene xml is published" "$ASSETS/g1_amber.xml"
assert_file_count "the sampled clips are published" "$ASSETS/clips/g1_amber" '*.npz' 4
assert_nonempty_file "the clip list is published" "$ASSETS/clips_g1_amber.txt"
assert_line_count "the clip list holds one line per sampled clip" "$ASSETS/clips_g1_amber.txt" 4
assert_contains "the clip list holds relative paths" "$(cat "$ASSETS/clips_g1_amber.txt")" "clips/g1_amber/"
assert_eq "no staging residue survives a successful export" "0" "$(staging_residue)"
assert_nonempty_file "the meshes are published" "$ASSETS/meshes/g1_amber/mesh_0.stl"

# every published clip must be non-empty
zero_clips="$(find "$ASSETS/clips/g1_amber" -maxdepth 1 -type f -name '*.npz' -size 0 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no published clip is empty" "0" "$zero_clips"

# the export is idempotent: a second run replaces the landing spot
run export
assert_rc_zero "a second export exits 0" "$RC"
assert_file_count "a second export republishes the same clip count" "$ASSETS/clips/g1_amber" '*.npz' 4
assert_eq "a second export leaves no staging residue" "0" "$(staging_residue)"

echo "== 21_assets.sh: the failure paths =="

# the upstream exporter fails
run export FAKE_UV_FAIL_EXPORT=1
assert_rc_nonzero "export fails when the upstream exporter fails" "$RC"
assert_contains "export reports export-failed" "$OUT" "DEPLOY_ASSETS_FAIL reason=export-failed"
assert_not_contains "a failed export prints no DEPLOY_ASSETS_OK" "$OUT" "DEPLOY_ASSETS_OK"
assert_eq "a failed export leaves no staging residue" "0" "$(staging_residue)"
assert_nonempty_file "a failed export leaves the published assets untouched" "$ASSETS/g1_amber.xml"

# the exporter writes too few clips
run export FAKE_UV_SHORT=1
assert_rc_nonzero "export fails when the exporter writes too few clips" "$RC"
assert_contains "export reports staging-verify-failed" "$OUT" "DEPLOY_ASSETS_FAIL reason=staging-verify-failed"
assert_not_contains "a short export prints no DEPLOY_ASSETS_OK" "$OUT" "DEPLOY_ASSETS_OK"
assert_eq "a short export leaves no staging residue" "0" "$(staging_residue)"
assert_file_count "a short export does not publish the short clip set" "$ASSETS/clips/g1_amber" '*.npz' 4

# the exporter writes an empty clip
run export FAKE_UV_EMPTY_NPZ=1
assert_rc_nonzero "export fails when a published clip is empty" "$RC"
assert_contains "export reports staging-verify-failed for an empty clip" "$OUT" "DEPLOY_ASSETS_FAIL reason=staging-verify-failed"
assert_not_contains "an empty clip prints no DEPLOY_ASSETS_OK" "$OUT" "DEPLOY_ASSETS_OK"
assert_eq "an empty clip leaves no staging residue" "0" "$(staging_residue)"

# the exporter writes no scene xml
run export FAKE_UV_NO_XML=1
assert_rc_nonzero "export fails when the scene xml is missing" "$RC"
assert_contains "export reports staging-verify-failed for a missing xml" "$OUT" "DEPLOY_ASSETS_FAIL reason=staging-verify-failed"
assert_not_contains "a missing xml prints no DEPLOY_ASSETS_OK" "$OUT" "DEPLOY_ASSETS_OK"
assert_eq "a missing xml leaves no staging residue" "0" "$(staging_residue)"

# the environment gate fails -> the export never starts
SUBSET_OVERRIDE="$TMP/nope.yaml" run export
assert_rc_nonzero "export fails when the environment gate fails" "$RC"
assert_contains "export reports the environment gate reason" "$OUT" "DEPLOY_ASSETS_FAIL reason=subset-missing"
assert_not_contains "a failed environment gate prints no DEPLOY_ASSETS_OK" "$OUT" "DEPLOY_ASSETS_OK"

echo "== 21_assets.sh: the sampling rule =="

STRIDE_OVERRIDE=1 run env
assert_rc_zero "the env gate passes with stride 1" "$RC"
assert_contains "stride 1 samples every clip" "$OUT" "sampled=20"

STRIDE_OVERRIDE=10 run env
assert_rc_zero "the env gate passes with stride 10" "$RC"
assert_contains "stride 10 samples every 10th clip" "$OUT" "sampled=2"

STRIDE_OVERRIDE=1 run export
assert_rc_zero "the export with stride 1 exits 0" "$RC"
assert_contains "the export with stride 1 reports every clip" "$OUT" "DEPLOY_ASSETS_OK clips=20"
assert_line_count "the clip list of stride 1 holds every clip" "$ASSETS/clips_g1_amber.txt" 20
first_clip="$(sed -n '1p' "$ASSETS/clips_g1_amber.txt")"
assert_contains "the sample starts at the first clip of the subset" "$first_clip" "clip_000__A000.npz"
fifth_clip="$(sed -n '6p' "$ASSETS/clips_g1_amber.txt")"
assert_contains "the sample of stride 5 holds the 6th clip" "$fifth_clip" "clip_005__A005.npz"

echo "== 21_assets.sh: report =="

run report
assert_rc_zero "report exits 0" "$RC"
assert_contains "report names its side" "$OUT" "DEPLOY_REPORT_SIDE=assets"
assert_contains "report prints the xml size" "$OUT" "DEPLOY_REPORT_XML"
assert_contains "report prints the mesh count" "$OUT" "DEPLOY_REPORT_MESH count=1"
assert_contains "report prints the clip count" "$OUT" "DEPLOY_REPORT_CLIPS count=20"
assert_contains "report prints the clip list path" "$OUT" "DEPLOY_REPORT_CLIP_LIST"

STRIDE_OVERRIDE=7 run report
assert_rc_zero "report with an explicit stride exits 0" "$RC"
assert_contains "report prints the sampling rule" "$OUT" "DEPLOY_REPORT_SAMPLE stride=7"
assert_contains "report prints the sampled count of the rule" "$OUT" "sampled=3"
assert_contains "report prints the subset clip count" "$OUT" "subset_clips=20"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
