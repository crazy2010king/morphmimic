#!/usr/bin/env bash
# repro/tests/test_export_orchestrator.sh — offline NEGATIVE fixture battery
# for the export orchestrator repro/19_export.sh (slice S07, task T3).
#
# The orchestrator is the thing that publishes the ONNX artefacts, so the
# battery proves the two contracts that matter:
#
#   1. the FAIL-CLOSED contract: every broken precondition (import failure,
#      missing checkpoint, unloadable checkpoint, unwritable landing spot,
#      failing training precondition gate, failing upstream export, rejected
#      staging directory) ends in a NON-ZERO exit, a reason from the FIXED
#      reason set and ZERO EXPORT_EXPORT_OK markers;
#   2. the ATOMIC-PUBLISH contract: a failed run leaves the formal landing
#      spot out/g1_amber UNTOUCHED (no half-finished policy.onnx), and a
#      successful run publishes exactly the four artefacts.
#
# No network, no container, no torch, no GPU: the upstream exporter is
# replaced by a fake command that writes a synthetic export directory, and
# the probes are replaced by tiny fake scripts.  The orchestrator itself is
# the REAL script, driven with EXPORT_ALLOW_LOCAL=1 and with every path /
# command overridden.
#
# Run locally:   bash repro/tests/test_export_orchestrator.sh
# Run remotely:  bash repro/lib/remote.sh tests/test_export_orchestrator.sh
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
ORCH="$REPO_ROOT/repro/19_export.sh"

PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/stdout.txt"
LOGD="$TMP/logs"
CKPT="$TMP/ckpt_26413.pt"
LANDING="$TMP/out/g1_amber"
STAGING="$TMP/staging/g1_amber"
MARKER="$TMP/export_ran.marker"
ARGSFILE="$TMP/export_args.txt"

ENV_REASONS="interpreter-missing import-failed ckpt-missing ckpt-unloadable out-not-writable"
EXPORT_REASONS="ckpt-verify-failed export-failed staging-verify-failed publish-failed"

# --- fixtures ---------------------------------------------------------------

# the fake upstream exporter: writes a synthetic export directory into the
# staging directory it is given as its first argument.
cat >"$TMP/fake_export.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
staging="${1:-}"
shift || true
mode="${EXPORT_FAKE_MODE:-ok}"
[ -n "${EXPORT_FAKE_ARGS_FILE:-}" ] && printf '%s\n' "$*" >"$EXPORT_FAKE_ARGS_FILE"
[ -n "${EXPORT_FAKE_MARKER:-}" ] && : >"$EXPORT_FAKE_MARKER"
if [ "$mode" = "fail" ]; then
  echo "fake upstream failure: ValueError: ONNX does not match PyTorch" >&2
  exit 1
fi
mkdir -p "$staging"
printf 'fake policy graph\n' >"$staging/policy.onnx"
printf '{"fake": "robot json"}\n' >"$staging/g1_amber.json"
motion="6.2e-06"
human="5.2e-06"
[ "$mode" = "parity-over" ] && motion="2.0e-04"
{
  printf 'MorphMimic export manifest\n\n'
  printf 'Parity with PyTorch (each robot own checkpoint, 64 random inputs):\n\n'
  printf '  g1_amber max |ONNX - PyTorch|  motion %s  human %s\n\n' "$motion" "$human"
  printf 'Files (check with: sha256sum -c SHA256SUMS)\n\n'
  ( cd "$staging" && sha256sum policy.onnx g1_amber.json ) | sed 's/^/  /'
  printf '\nSource checkpoints\n\n'
  printf '  g1_amber logs/train/g1_amber_1h/ckpt_26413.pt\n'
} >"$staging/MANIFEST.txt"
( cd "$staging" && sha256sum policy.onnx g1_amber.json >SHA256SUMS )
case "$mode" in
  missing-file) rm -f "$staging/policy.onnx" ;;
  sha-mismatch)
    sed -i 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
      "$staging/SHA256SUMS" ;;
esac
exit 0
FAKE

# the fake import probe: prints the version lines the env gate parses.
cat >"$TMP/fake_import.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
cat >/dev/null
if [ "${EXPORT_FAKE_IMPORT_RC:-0}" != "0" ]; then
  echo "ModuleNotFoundError: No module named 'onnxscript'" >&2
  exit 1
fi
printf 'PY_VERSION=3.11.9\n'
printf 'TORCH_VERSION=2.11.0+cu128\n'
printf 'ONNX_VERSION=1.23.2\n'
printf 'ONNXRUNTIME_VERSION=1.31.0\n'
printf 'ONNXSCRIPT_VERSION=0.7.2\n'
exit 0
FAKE

# the fake checkpoint probe.
cat >"$TMP/fake_ckpt_probe.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
cat >/dev/null
if [ "${EXPORT_FAKE_CKPT_RC:-0}" != "0" ]; then
  echo "RuntimeError: PytorchStreamReader failed reading zip archive" >&2
  exit 1
fi
printf 'CKPT_ITERATION=26413\n'
printf 'CKPT_LOADED=1\n'
exit 0
FAKE

# the fake training precondition gate (18_train_verify.sh verify).
cat >"$TMP/fake_verify.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
if [ "${EXPORT_FAKE_VERIFY_RC:-0}" != "0" ]; then
  echo "TRAIN_VERIFY_FAIL reason=checkpoint-missing" >&2
  exit 1
fi
printf 'TRAIN_VERIFY_OK ckpt=logs/train/g1_amber_1h/ckpt_26413.pt iteration=26413\n'
exit 0
FAKE

# the fake selftest command.
cat >"$TMP/fake_selftest.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
: >"${EXPORT_FAKE_SELFTEST_MARKER:-/dev/null}"
printf 'PASS=1 FAIL=0\n'
exit 0
FAKE

chmod +x "$TMP/fake_export.sh" "$TMP/fake_import.sh" "$TMP/fake_ckpt_probe.sh" \
  "$TMP/fake_verify.sh" "$TMP/fake_selftest.sh"
printf 'fake checkpoint payload\n' >"$CKPT"

# --- runner -----------------------------------------------------------------

# run_orch <subcommand> [env assignments...] — the orchestrator with the
# fixture environment.  Sets $RC and $OUT.
run_orch() {
  local sub="$1"; shift
  env EXPORT_ALLOW_LOCAL=1 \
      EXPORT_CKPT="$CKPT" \
      EXPORT_OUT_DIR="$LANDING" \
      EXPORT_STAGING_DIR="$STAGING" \
      EXPORT_LOG_DIR="$LOGD" \
      EXPORT_EXPORT_CMD="bash $TMP/fake_export.sh" \
      EXPORT_ENV_IMPORT_CMD="bash $TMP/fake_import.sh" \
      EXPORT_ENV_CKPT_CMD="bash $TMP/fake_ckpt_probe.sh" \
      EXPORT_CKPT_VERIFY_CMD="bash $TMP/fake_verify.sh" \
      EXPORT_SELFTEST_CMD="bash $TMP/fake_selftest.sh" \
      EXPORT_FAKE_ARGS_FILE="$ARGSFILE" \
      EXPORT_FAKE_MARKER="$MARKER" \
      EXPORT_FAKE_SELFTEST_MARKER="$TMP/selftest_ran.marker" \
      "$@" \
      bash "$ORCH" "$sub" >"$OUT" 2>&1
  RC=$?
}

has_export_ok() { grep -q 'EXPORT_EXPORT_OK' "$OUT"; }
has_env_ok()    { grep -q 'EXPORT_ENV_OK' "$OUT"; }
has_verify_ok() { grep -q 'EXPORT_VERIFY_OK' "$OUT"; }

reason_in_set() {
  local set="$1" reason
  reason="$(sed -n 's/^EXPORT_\(ENV\|EXPORT\)_FAIL reason=\([a-z-]*\).*/\2/p' "$OUT" | head -1)"
  [ -n "$reason" ] || return 1
  case " $set " in
    *" $reason "*) return 0 ;;
  esac
  return 1
}

# assert_env_failure <label> <expected reason>
assert_env_failure() {
  local label="$1" expected="$2"
  if [ "$RC" -eq 0 ]; then
    bad "$label: env exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
  else
    ok "$label: env exits non-zero ($RC)"
  fi
  if has_env_ok; then
    bad "$label: EXPORT_ENV_OK must NOT be printed on a failure"
    sed 's/^/      | /' "$OUT"; FAIL=$((FAIL + 1))
  else
    ok "$label: no EXPORT_ENV_OK marker"; PASS=$((PASS + 1))
  fi
  if reason_in_set "$ENV_REASONS"; then
    ok "$label: reason belongs to the fixed set"
  else
    bad "$label: reason outside the fixed set"; sed 's/^/      | /' "$OUT"
  fi
  if grep -q "reason=$expected" "$OUT"; then
    ok "$label: reason=$expected"
  else
    bad "$label: expected reason=$expected"; sed 's/^/      | /' "$OUT"
  fi
}

# assert_export_failure <label> <expected reason>
assert_export_failure() {
  local label="$1" expected="$2"
  if [ "$RC" -eq 0 ]; then
    bad "$label: export exited 0 (expected non-zero)"; sed 's/^/      | /' "$OUT"
  else
    ok "$label: export exits non-zero ($RC)"
  fi
  if has_export_ok; then
    bad "$label: EXPORT_EXPORT_OK must NOT be printed on a failure"
    sed 's/^/      | /' "$OUT"; FAIL=$((FAIL + 1))
  else
    ok "$label: no EXPORT_EXPORT_OK marker"; PASS=$((PASS + 1))
  fi
  if has_verify_ok; then
    bad "$label: the orchestrator must not print the reviewer's marker"
    sed 's/^/      | /' "$OUT"; FAIL=$((FAIL + 1))
  else
    ok "$label: no EXPORT_VERIFY_OK marker (one gate, one marker)"; PASS=$((PASS + 1))
  fi
  if reason_in_set "$EXPORT_REASONS"; then
    ok "$label: reason belongs to the fixed set"
  else
    bad "$label: reason outside the fixed set"; sed 's/^/      | /' "$OUT"
  fi
  if grep -q "reason=$expected" "$OUT"; then
    ok "$label: reason=$expected"
  else
    bad "$label: expected reason=$expected"; sed 's/^/      | /' "$OUT"
  fi
  if [ -e "$LANDING" ]; then
    bad "$label: the formal landing spot must stay untouched"
    ls -l "$LANDING" 2>&1 | sed 's/^/      | /'
  else
    ok "$label: the formal landing spot holds no file"
  fi
}

reset_state() {
  rm -rf "$LANDING" "$TMP/out" "$STAGING" "$TMP/staging" "$MARKER" "$ARGSFILE" \
         "$TMP/selftest_ran.marker"
  mkdir -p "$LOGD"
}

# ============================================================================
# 1. the env gate on a healthy environment
# ============================================================================
reset_state
run_orch env
if [ "$RC" -eq 0 ]; then
  ok "env: exits 0 on a healthy environment"
else
  bad "env: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if grep -q 'EXPORT_ENV_OK python=3.11.9 torch=2.11.0+cu128 onnx=1.23.2 onnxruntime=1.31.0' "$OUT"; then
  ok "env: the OK marker carries the probed versions"
else
  bad "env: unexpected OK marker content"; sed 's/^/      | /' "$OUT"
fi
if grep -q "ckpt=$CKPT" "$OUT"; then
  ok "env: the OK marker carries the source checkpoint"
else
  bad "env: the OK marker does not carry the checkpoint"; sed 's/^/      | /' "$OUT"
fi
if [ "$(grep -c 'EXPORT_ENV_OK' "$OUT")" -eq 1 ]; then
  ok "env: exactly ONE OK marker line"
else
  bad "env: more than one OK marker line"
fi

# ============================================================================
# 2. the env gate: the import probe fails
# ============================================================================
reset_state
run_orch env EXPORT_FAKE_IMPORT_RC=1
assert_env_failure "import failure" "import-failed"

# ============================================================================
# 3. the env gate: the source checkpoint does not exist
# ============================================================================
reset_state
run_orch env EXPORT_CKPT="$TMP/no-such-ckpt.pt"
assert_env_failure "missing checkpoint" "ckpt-missing"

# ============================================================================
# 4. the env gate: the checkpoint cannot be loaded
# ============================================================================
reset_state
run_orch env EXPORT_FAKE_CKPT_RC=1
assert_env_failure "unloadable checkpoint" "ckpt-unloadable"

# ============================================================================
# 5. the env gate: the interpreter does not exist
# ============================================================================
reset_state
run_orch env EXPORT_VENV_PY="$TMP/no-such-python"
assert_env_failure "missing interpreter" "interpreter-missing"

# ============================================================================
# 6. the env gate: the landing spot is not writable
# ============================================================================
reset_state
printf 'not a directory\n' >"$TMP/blocked"
run_orch env EXPORT_OUT_DIR="$TMP/blocked/g1_amber"
assert_env_failure "unwritable landing spot" "out-not-writable"

# ============================================================================
# 7. the export: the training precondition gate fails -> NOTHING is exported
# ============================================================================
reset_state
run_orch export EXPORT_FAKE_VERIFY_RC=1
assert_export_failure "failing precondition gate" "ckpt-verify-failed"
if [ -e "$MARKER" ]; then
  bad "failing precondition gate: the upstream exporter must NOT run"
else
  ok "failing precondition gate: the upstream exporter never ran"
fi
if grep -q 'TRAIN_VERIFY' "$LOGD/19_export.txt" 2>/dev/null; then
  ok "failing precondition gate: the gate output is recorded in the log"
else
  bad "failing precondition gate: the gate output is missing from the log"
fi

# ============================================================================
# 8. the export: the upstream exporter fails
# ============================================================================
reset_state
run_orch export EXPORT_FAKE_MODE=fail
assert_export_failure "failing upstream export" "export-failed"
if [ -e "$STAGING" ]; then
  bad "failing upstream export: the staging directory must be removed"
else
  ok "failing upstream export: the staging directory was removed"
fi

# ============================================================================
# 9. the export: the staging directory violates the parity tolerance
# ============================================================================
reset_state
run_orch export EXPORT_FAKE_MODE=parity-over
assert_export_failure "parity over tolerance" "staging-verify-failed"
if [ -e "$STAGING" ]; then
  bad "parity over tolerance: the staging directory must be removed"
else
  ok "parity over tolerance: the staging directory was removed"
fi

# ============================================================================
# 10. the export: the staging directory misses an artefact
# ============================================================================
reset_state
run_orch export EXPORT_FAKE_MODE=missing-file
assert_export_failure "incomplete staging directory" "staging-verify-failed"

# ============================================================================
# 11. the export: the digests in SHA256SUMS do not match the files
# ============================================================================
reset_state
run_orch export EXPORT_FAKE_MODE=sha-mismatch
assert_export_failure "tampered digest" "staging-verify-failed"

# ============================================================================
# 12. the export: the happy path publishes exactly four artefacts
# ============================================================================
reset_state
run_orch export
if [ "$RC" -eq 0 ]; then
  ok "happy path: export exits 0"
else
  bad "happy path: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if grep -q "EXPORT_EXPORT_OK out=$LANDING files=4 parity_max=6.2e-06" "$OUT"; then
  ok "happy path: the OK marker carries the landing spot and the parity"
else
  bad "happy path: unexpected OK marker content"; sed 's/^/      | /' "$OUT"
fi
if [ "$(grep -c 'EXPORT_EXPORT_OK' "$OUT")" -eq 1 ]; then
  ok "happy path: exactly ONE OK marker line"
else
  bad "happy path: more than one OK marker line"
fi
if [ -d "$LANDING" ]; then
  ok "happy path: the landing spot exists"
else
  bad "happy path: the landing spot was not created"
fi
if [ "$(find "$LANDING" -type f 2>/dev/null | wc -l)" -eq 4 ]; then
  ok "happy path: the landing spot holds exactly 4 files"
else
  bad "happy path: unexpected file count in the landing spot"
  find "$LANDING" -type f 2>/dev/null | sed 's/^/      | /'
fi
for f in policy.onnx g1_amber.json MANIFEST.txt SHA256SUMS; do
  if [ -s "$LANDING/$f" ]; then
    ok "happy path: $f is published and non-empty"
  else
    bad "happy path: $f is missing or empty"
  fi
done
if [ -e "$STAGING" ]; then
  bad "happy path: the staging directory must be gone after the publish"
else
  ok "happy path: the staging directory is gone after the publish"
fi
if has_verify_ok; then
  bad "happy path: the orchestrator must not print the reviewer's marker"
  sed 's/^/      | /' "$OUT"
else
  ok "happy path: no EXPORT_VERIFY_OK marker (one gate, one marker)"
fi

# ============================================================================
# 13. the export: re-exporting replaces the previous landing spot
# ============================================================================
reset_state
run_orch export
printf 'stale artefact\n' >"$LANDING/STALE.txt"
run_orch export
if [ "$RC" -eq 0 ]; then
  ok "re-export: exits 0"
else
  bad "re-export: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if [ -e "$LANDING/STALE.txt" ]; then
  bad "re-export: the previous landing spot must be replaced, not merged"
else
  ok "re-export: the previous landing spot was replaced"
fi
if [ "$(find "$LANDING" -type f 2>/dev/null | wc -l)" -eq 4 ]; then
  ok "re-export: the landing spot holds exactly 4 files again"
else
  bad "re-export: unexpected file count in the landing spot"
fi

# ============================================================================
# 14. the export: extra arguments are forwarded to the upstream exporter
# ============================================================================
reset_state
env EXPORT_ALLOW_LOCAL=1 \
    EXPORT_CKPT="$CKPT" \
    EXPORT_OUT_DIR="$LANDING" \
    EXPORT_STAGING_DIR="$STAGING" \
    EXPORT_LOG_DIR="$LOGD" \
    EXPORT_EXPORT_CMD="bash $TMP/fake_export.sh" \
    EXPORT_ENV_IMPORT_CMD="bash $TMP/fake_import.sh" \
    EXPORT_ENV_CKPT_CMD="bash $TMP/fake_ckpt_probe.sh" \
    EXPORT_CKPT_VERIFY_CMD="bash $TMP/fake_verify.sh" \
    EXPORT_FAKE_ARGS_FILE="$ARGSFILE" \
    EXPORT_FAKE_MARKER="$MARKER" \
    bash "$ORCH" export --goal-anchor robot >"$OUT" 2>&1
RC=$?
if [ -s "$ARGSFILE" ]; then
  ok "extra arguments: the upstream exporter received them"
  if grep -q -- '--goal-anchor robot' "$ARGSFILE"; then
    ok "extra arguments: '--goal-anchor robot' reached the upstream exporter"
  else
    bad "extra arguments: the forwarded arguments are wrong"
    sed 's/^/      | /' "$ARGSFILE"
  fi
else
  bad "extra arguments: the upstream exporter was not called"
fi

# ============================================================================
# 15. the report: the export side describes itself
# ============================================================================
reset_state
run_orch export
run_orch report
if [ "$RC" -eq 0 ]; then
  ok "report: exits 0"
else
  bad "report: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
for needle in "EXPORT_REPORT_SIDE=export" \
              "EXPORT_REPORT_OUT dir=$LANDING" \
              "EXPORT_REPORT_CKPT path=$CKPT" \
              "EXPORT_REPORT_FILE file=policy.onnx bytes=" \
              "EXPORT_REPORT_FILES count=4" \
              "EXPORT_REPORT_PUBLISHED=1"; do
  if grep -qF "$needle" "$OUT"; then
    ok "report: prints '$needle'"
  else
    bad "report: missing '$needle'"; sed 's/^/      | /' "$OUT"
  fi
done

# ============================================================================
# 16. the selftest: it runs the offline battery
# ============================================================================
reset_state
run_orch selftest
if [ "$RC" -eq 0 ]; then
  ok "selftest: exits 0"
else
  bad "selftest: exited $RC (expected 0)"; sed 's/^/      | /' "$OUT"
fi
if [ -e "$TMP/selftest_ran.marker" ]; then
  ok "selftest: the offline battery was executed"
else
  bad "selftest: the offline battery was not executed"
fi

# ============================================================================
# 17. the orchestrator writes its own log
# ============================================================================
reset_state
run_orch export
if [ -s "$LOGD/19_export.txt" ]; then
  ok "log: the orchestrator wrote logs/env/19_export.txt"
else
  bad "log: no log file written"; ls -l "$LOGD" 2>&1 | sed 's/^/      | /'
fi
if grep -q 'EXPORT_EXPORT_OK' "$LOGD/19_export.txt" 2>/dev/null; then
  ok "log: the OK marker is greppable in the log file"
else
  bad "log: the OK marker is missing from the log file"
fi

# ============================================================================
# 18. the orchestrator holds no decision logic of its own
# ============================================================================
if grep -q 'export_run verify' "$ORCH"; then
  ok "the orchestrator delegates the verdict to the decision base"
else
  bad "the orchestrator must delegate the verdict to repro/lib/export.py"
fi
if grep -Eq 'sha256sum|sha256_file|parse_manifest_parity' "$ORCH"; then
  bad "the orchestrator must not re-implement the decision"
  grep -nE 'sha256sum|sha256_file|parse_manifest_parity' "$ORCH" | sed 's/^/      | /'
else
  ok "the orchestrator implements no digest/parity parsing of its own"
fi
if grep -q 'EXPORT_EXPORT_OK' "$ORCH"; then
  ok "the orchestrator owns the EXPORT_EXPORT_OK marker"
else
  bad "the orchestrator must own the EXPORT_EXPORT_OK marker"
fi

# ============================================================================
# summary
# ============================================================================
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
