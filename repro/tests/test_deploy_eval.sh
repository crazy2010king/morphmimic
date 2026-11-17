#!/usr/bin/env bash
# repro/tests/test_deploy_eval.sh — the OFFLINE battery of the evaluation
# orchestrator (repro/23_eval.sh).
#
# The battery drives the REAL orchestrator with a FAKE benchmark command (the
# EVAL_RUN_TEMPLATE override): the stub stands in for
#
#     uv run --frozen --offline python -m morphmimic.scripts.eval
#         --ckpt ... --subset-yaml ... --interface motion|human --out ...
#         --num-envs ... [--human-points full --human-root ...]
#
# so neither the container, nor a GPU, nor the real evaluator are needed.
# The stub writes the per-clip CSV the upstream would write, and can be
# steered into every failure mode.
#
# Every negative scenario asserts the triple the project convention demands
# of a negative path:
#
#     non-zero exit code + NO OK marker + the expected fixed reason
#
# The decision itself is NOT stubbed: the CSV is parsed by the real decision
# base (repro/lib/deploy.py: verify_eval_csv / eval_completion) with the
# host's plain python3 (stdlib only).
#
# usage: bash repro/tests/test_deploy_eval.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/repro/23_eval.sh"

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
assert_absent() { # <label> <path>
  if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected path: $2"; fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the fake benchmark command ---------------------------------------------
# It understands the upstream's arguments and writes the per-clip CSV:
#   --out <csv>              the CSV the upstream writes
# The behaviour is steered by FAKE_EVAL_MODE:
#   ok                 the happy path (FAKE_EVAL_ROWS rows)
#   short              too few rows (the orchestrator must refuse it)
#   missing-failed     the header has no `failed` column
#   bad-failed         the `failed` cells cannot be parsed
#   no-csv             the CSV is not written at all
#   nonzero            the command itself fails
# The behaviour is steered by STUB_HANG=1 as well: the stub then hangs
# forever, so the wall-clock timeout of the orchestrator can be tested.
# Every invocation is recorded in $STUB_CALLS (one line per benchmark).
STUB="$TMP/stub_eval.sh"
STUB_CALLS="$TMP/stub_calls.txt"
cat >"$STUB" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
out=""
interface=""
extra=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --interface) interface="$2"; shift 2 ;;
    --human-points|--human-root) extra="$extra $1=$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\n' "$interface" "$out" "$extra" >>"${STUB_CALLS:?}"

mode="${FAKE_EVAL_MODE:-ok}"
if [ "${STUB_HANG:-0}" = "1" ]; then
  sleep 30
  exit 0
fi
if [ "$mode" = "nonzero" ]; then
  echo "fake eval: the benchmark failed" >&2
  exit 7
fi

rows="${FAKE_EVAL_ROWS:-4}"
case "$mode" in
  no-csv)
    rm -f "$out"
    exit 0
    ;;
  missing-failed)
    header="name,frames,fail_frame,norm_return,steps"
    ;;
  *)
    header="name,frames,failed,fail_frame,norm_return,steps"
    ;;
esac

{
  printf '%s\n' "$header"
  i=0
  while [ "$i" -lt "$rows" ]; do
    case "$mode" in
      bad-failed) failed="maybe" ;;
      *) if [ "$i" -eq 0 ]; then failed="True"; else failed="False"; fi ;;
    esac
    if [ "$header" = "name,frames,fail_frame,norm_return,steps" ]; then
      printf 'clip_%03d,300,-1,0.5,300\n' "$i"
    else
      printf 'clip_%03d,300,%s,-1,0.5,300\n' "$i" "$failed"
    fi
    i=$((i + 1))
  done
} >"$out"
exit 0
STUB
chmod +x "$STUB"

# --- the fixtures -----------------------------------------------------------
FAKE_ROOT="$TMP/seed/seed_g1_npz50"
mkdir -p "$FAKE_ROOT/human50" "$TMP/logs" "$TMP/out"
CKPT="$TMP/ckpt_26413.pt"
printf 'fake checkpoint\n' >"$CKPT"

SUBSET="$TMP/subsets/1h.yaml"
mkdir -p "$TMP/subsets"
{
  printf 'root: %s\n' "$FAKE_ROOT"
  printf 'hours: 1.0014\n'
  printf 'clips:\n'
  printf -- '- a/clip_000.npz\n'
  printf -- '- a/clip_001.npz\n'
  printf -- '- a/clip_002.npz\n'
  printf -- '- a/clip_003.npz\n'
} >"$SUBSET"

MOTION_CSV="$TMP/out/eval_motion_1h.csv"
HUMAN_CSV="$TMP/out/eval_human_full_1h.csv"

RUN_TEMPLATE="$STUB --ckpt {ckpt} --subset-yaml {subset} --interface {interface} --out {out} --num-envs {num_envs} {extra}"

# run <subcommand> [VAR=value ...] [args...]
# The VAR=value arguments become environment overrides of the orchestrator
# (they are applied AFTER the defaults, so they win); every other argument
# is passed to the orchestrator as an argument.
run() {
  local sub="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  OUT="$(env \
    EVAL_ALLOW_LOCAL=1 \
    STUB_CALLS="$STUB_CALLS" \
    FAKE_EVAL_MODE="ok" \
    FAKE_EVAL_ROWS="4" \
    EVAL_CKPT="$CKPT" \
    EVAL_SUBSET_YAML="$SUBSET" \
    EVAL_OUT_DIR="$TMP/out" \
    EVAL_MOTION_OUT="$MOTION_CSV" \
    EVAL_HUMAN_OUT="$HUMAN_CSV" \
    EVAL_IMPORT_CMD="true" \
    EVAL_RUN_TEMPLATE="$RUN_TEMPLATE" \
    EVAL_LOG_DIR="$TMP/logs" \
    "${envs[@]+"${envs[@]}"}" \
    bash "$ORCH" "$sub" "$@" 2>&1)"
  RC=$?
}

stub_calls() { wc -l <"$STUB_CALLS" 2>/dev/null | tr -d ' '; }

echo "== 23_eval.sh: the environment gate =="

run env
assert_rc_zero "the env gate exits 0" "$RC"
assert_contains "the env gate prints DEPLOY_EVAL_ENV_OK" "$OUT" "DEPLOY_EVAL_ENV_OK"
assert_contains "the env gate reports the checkpoint" "$OUT" "ckpt="
assert_contains "the env gate reports the clip count" "$OUT" "clips=4"

run env EVAL_IMPORT_CMD=false
assert_rc_nonzero "the env gate fails when the import probe fails" "$RC"
assert_contains "the env gate reports import-failed" "$OUT" "DEPLOY_EVAL_ENV_FAIL reason=import-failed"
assert_not_contains "the env gate prints no OK marker on an import failure" "$OUT" "_OK"

run env EVAL_CKPT="$TMP/nothing.pt"
assert_rc_nonzero "the env gate fails without the checkpoint" "$RC"
assert_contains "the env gate reports ckpt-missing" "$OUT" "DEPLOY_EVAL_ENV_FAIL reason=ckpt-missing"
assert_not_contains "the env gate prints no OK marker without the checkpoint" "$OUT" "_OK"

run env EVAL_SUBSET_YAML="$TMP/nothing.yaml"
assert_rc_nonzero "the env gate fails without the subset yaml" "$RC"
assert_contains "the env gate reports subset-missing" "$OUT" "DEPLOY_EVAL_ENV_FAIL reason=subset-missing"
assert_not_contains "the env gate prints no OK marker without the subset" "$OUT" "_OK"

printf 'root: %s\nclips:\n' "$FAKE_ROOT" >"$TMP/empty_subset.yaml"
run env EVAL_SUBSET_YAML="$TMP/empty_subset.yaml"
assert_rc_nonzero "the env gate fails on a subset without clips" "$RC"
assert_contains "the env gate reports subset-parse-failed" "$OUT" "DEPLOY_EVAL_ENV_FAIL reason=subset-parse-failed"
assert_not_contains "the env gate prints no OK marker on an empty subset" "$OUT" "_OK"

run env EVAL_HUMAN_ROOT="$TMP/no_such_human50"
assert_rc_nonzero "the env gate fails without the human sidecars" "$RC"
assert_contains "the env gate reports human-root-missing" "$OUT" "DEPLOY_EVAL_ENV_FAIL reason=human-root-missing"
assert_not_contains "the env gate prints no OK marker without the sidecars" "$OUT" "_OK"

echo "== 23_eval.sh: the motion benchmark =="

: >"$STUB_CALLS"
run motion
assert_rc_zero "the motion benchmark exits 0" "$RC"
assert_contains "the motion benchmark prints DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK interface=motion"
assert_contains "the motion benchmark reports the row count" "$OUT" "rows=4"
assert_contains "the motion benchmark reports the recomputed completion" "$OUT" "completion=0.750000"
assert_eq "the benchmark command was run once" "1" "$(stub_calls)"
assert_contains "the benchmark was asked for the motion interface" "$(cat "$STUB_CALLS")" "motion"
assert_file "the motion CSV was written" "$MOTION_CSV"
assert_contains "the motion CSV carries the header" "$(head -n1 "$MOTION_CSV")" "name,frames,failed,fail_frame,norm_return,steps"
assert_eq "the motion CSV holds one row per clip" "5" "$(wc -l <"$MOTION_CSV" | tr -d ' ')"
assert_contains "the wall clock was recorded" "$(cat "$TMP/out/timings.tsv")" "motion"

: >"$STUB_CALLS"
run human
assert_rc_zero "the human benchmark exits 0" "$RC"
assert_contains "the human benchmark prints DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK interface=human"
assert_contains "the human benchmark reports the row count" "$OUT" "rows=4"
assert_eq "the benchmark command was run once" "1" "$(stub_calls)"
assert_contains "the benchmark was asked for the human interface" "$(cat "$STUB_CALLS")" "human"
assert_contains "the benchmark was given the human sidecar root" "$(cat "$STUB_CALLS")" "--human-root=$FAKE_ROOT/human50"
assert_contains "the benchmark was given the full human point set" "$(cat "$STUB_CALLS")" "--human-points=full"

echo "== 23_eval.sh: the negative paths =="

run motion FAKE_EVAL_ROWS=2
assert_rc_nonzero "the benchmark fails when the CSV holds too few rows" "$RC"
assert_contains "the benchmark reports eval-row-count-mismatch" "$OUT" "DEPLOY_EVAL_FAIL reason=eval-row-count-mismatch"
assert_not_contains "a short CSV prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"
assert_not_contains "a short CSV prints no DEPLOY_EVAL_ENV_OK" "$OUT" "DEPLOY_EVAL_ENV_OK"

run motion FAKE_EVAL_MODE=missing-failed
assert_rc_nonzero "the benchmark fails when the failed column is missing" "$RC"
assert_contains "the benchmark reports eval-csv-parse-failed" "$OUT" "DEPLOY_EVAL_FAIL reason=eval-csv-parse-failed"
assert_not_contains "a missing failed column prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"

run motion FAKE_EVAL_MODE=bad-failed
assert_rc_nonzero "the benchmark fails when the failed values cannot be parsed" "$RC"
assert_contains "the benchmark reports eval-csv-parse-failed" "$OUT" "DEPLOY_EVAL_FAIL reason=eval-csv-parse-failed"
assert_not_contains "an unparsable failed column prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"

run motion FAKE_EVAL_MODE=no-csv
assert_rc_nonzero "the benchmark fails when the CSV is missing" "$RC"
assert_contains "the benchmark reports eval-csv-missing" "$OUT" "DEPLOY_EVAL_FAIL reason=eval-csv-missing"
assert_not_contains "a missing CSV prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"

run motion FAKE_EVAL_MODE=nonzero
assert_rc_nonzero "the benchmark fails when the evaluator exits non-zero" "$RC"
assert_contains "the benchmark reports eval-failed" "$OUT" "DEPLOY_EVAL_FAIL reason=eval-failed"
assert_not_contains "a failing evaluator prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"

run motion EVAL_TIMEOUT=1 STUB_HANG=1
assert_rc_nonzero "the benchmark fails when the evaluator times out" "$RC"
assert_contains "the benchmark reports eval-timeout" "$OUT" "DEPLOY_EVAL_FAIL reason=eval-timeout"
assert_not_contains "a timed-out benchmark prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"

: >"$STUB_CALLS"
run motion EVAL_IMPORT_CMD=false
assert_rc_nonzero "the benchmark fails when the environment gate fails" "$RC"
assert_contains "the benchmark reports the environment gate reason" "$OUT" "DEPLOY_EVAL_FAIL reason=import-failed"
assert_not_contains "a failed environment gate prints no DEPLOY_EVAL_OK" "$OUT" "DEPLOY_EVAL_OK"
assert_eq "a failed environment gate runs no benchmark" "0" "$(stub_calls)"

echo "== 23_eval.sh: the options =="

run motion --subset-yaml "$TMP/empty_subset.yaml"
assert_rc_nonzero "the benchmark refuses a subset without clips" "$RC"
assert_contains "the benchmark reports subset-parse-failed" "$OUT" "DEPLOY_EVAL_FAIL reason=subset-parse-failed"

run motion --out "$TMP/out/other.csv"
assert_rc_zero "the benchmark accepts another output path" "$RC"
assert_file "the benchmark wrote the requested CSV" "$TMP/out/other.csv"

echo "== 23_eval.sh: the report =="

run report
assert_rc_zero "the report exits 0" "$RC"
assert_contains "report names its side" "$OUT" "DEPLOY_REPORT_SIDE=eval"
assert_contains "report prints the motion completion" "$OUT" "DEPLOY_REPORT_EVAL interface=motion"
assert_contains "report prints the human completion" "$OUT" "DEPLOY_REPORT_EVAL interface=human"
assert_contains "report prints the wall clock" "$OUT" "DEPLOY_REPORT_WALLCLOCK"

echo "== 23_eval.sh: the repository wiring =="

assert_contains "the orchestrator uses the shared decision base" \
  "$(cat "$ORCH")" "repro/lib/deploy.py"
assert_contains "the orchestrator benchmarks the upstream evaluator" \
  "$(cat "$ORCH")" "morphmimic.scripts.eval"
assert_contains "the orchestrator reads the expected row count from the subset" \
  "$(cat "$ORCH")" "parse_subset_yaml"
assert_contains "the orchestrator recomputes the completion" \
  "$(cat "$ORCH")" "verify_eval_csv"
assert_eq "the orchestrator never imports yaml itself" "0" \
  "$(grep -c 'import yaml' "$ORCH" | tr -d ' ')"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
