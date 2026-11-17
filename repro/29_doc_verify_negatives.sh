#!/usr/bin/env bash
# repro/29_doc_verify_negatives.sh — the REAL negative transcripts of the
# reproduction-record verifier (slice S09, task T5).
#
# WHY
#   The offline battery (repro/tests/test_doc_verify.sh) drives the
#   verifier with synthetic fixtures.  That proves the DECISION LOGIC, but
#   it does not prove that the verifier works on the REAL record and the
#   REAL artefacts.  S08's lesson was "never trust an orchestrator's own
#   account"; the same applies here: the record verifier must prove that it
#   is NOT a machine that only ever prints OK.
#
# HOW
#   Nothing on a formal landing point is ever touched.  The real record and
#   the real artefacts are COPIED (the record byte for byte, the artefact
#   trees by symlink so that nothing large is duplicated) into a temporary
#   directory, and the breakage is applied to the COPY.  The verifier is
#   then pointed at the copy through DOC_REPO_ROOT, and its verdict is
#   asserted:
#
#     * the exit code is 1,
#     * the verdict line names the EXPECTED reason of the fixed set,
#     * stdout contains ZERO "DOC_VERIFY_OK" and ZERO "DOC_MIRROR_OK".
#
#   The three negatives (as required by the slice plan):
#
#     NEG-1  a number inside the evidence index table is changed so that
#            the key output string is no longer greppable in the evidence
#            file            -> reason=evidence-marker-missing
#     NEG-2  chapter 4 ("已分析未执行") is deleted from the copy
#                        -> reason=section-missing
#     NEG-3  a fake plaintext token ("hf_" + 28 alphanumerics) is injected
#            into the body of the copy -> reason=token-leaked
#
#   The transcripts (the raw stdout of every run plus its exit code) are
#   archived in logs/env/28_doc_verify_negatives.txt.
#
# The formal landing points are re-checked afterwards: their digests must be
# byte-identical before and after the battery, and no ".staging-*" residue
# may exist anywhere in the worktree.
#
# usage: bash repro/29_doc_verify_negatives.sh [run|both|check]
#
#   run    the three real negatives (writes logs/env/28_doc_verify_negatives.txt)
#   both   the host-side and the container-side terminal gate must agree
#          byte for byte (host only: it drives the container itself)
#   check  the close-out self-check only (read-only)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
set +e

RECORD_REL="docs/code_read/MorphMimic完整复现记录.md"
NEG_LOG="$LOG_DIR/28_doc_verify_negatives.txt"
DOC_VERIFY="$REPO_ROOT/repro/28_doc_verify.sh"
DOC_PY="${DOC_PY:-python3}"

FAILURES=0

note() { printf '%s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# landings_digest — one digest over the formal landing points.
#
# The formal landing points are: the in-repo mirror, the published copy in
# docs/code_doc/, the eval/comparison/curve artefacts and the checkpoint
# directory out/g1_amber.  Their digests must be IDENTICAL before and after
# the negative battery.
# --------------------------------------------------------------------------
landings_digest() {
  {
    sha256sum \
      "$REPO_ROOT/docs/code_read/"*.md \
      "$REPO_ROOT/docs/code_doc/MorphMimic完整复现记录.md" \
      "$REPO_ROOT/runs/eval/eval_motion_1h.csv" \
      "$REPO_ROOT/runs/eval/eval_human_full_1h.csv" \
      "$REPO_ROOT/runs/official/compare_self_vs_official.csv" \
      "$REPO_ROOT/runs/train_curves/"*.csv \
      "$REPO_ROOT/out/g1_amber/SHA256SUMS" 2>&1
    find "$REPO_ROOT/out/g1_amber" "$REPO_ROOT/runs" \
      -name '.staging-*' -print 2>/dev/null | sort
  } | sha256sum | cut -d' ' -f1
}

# staging_residue — every ".staging-*" left in the worktree.
staging_residue() {
  find "$REPO_ROOT" \
    -path "$REPO_ROOT/.git" -prune -o \
    -path "$REPO_ROOT/.gsd" -prune -o \
    -name '.staging-*' -print 2>/dev/null | sort
}

# --------------------------------------------------------------------------
# build_tmp_root — the throwaway root the verifier is pointed at.
#
#   <tmp>/docs/code_read/  a real COPY of the record (and of the sibling
#                          documents) — this is what gets broken
#   <tmp>/{logs,runs,out,assets}  symlinks to the real artefact trees
#   <tmp>/envlogs/        the log directory of the negative runs, so that
#                          the formal log logs/env/28_doc_verify.txt stays
#                          free of FAIL lines
# --------------------------------------------------------------------------
build_tmp_root() {
  TMP_ROOT="$(mktemp -d /tmp/doc_neg.XXXXXX)"
  mkdir -p "$TMP_ROOT/docs" "$TMP_ROOT/envlogs"
  cp -a "$REPO_ROOT/docs/code_read" "$TMP_ROOT/docs/code_read"
  ln -s "$REPO_ROOT/logs" "$TMP_ROOT/logs"
  ln -s "$REPO_ROOT/runs" "$TMP_ROOT/runs"
  ln -s "$REPO_ROOT/out" "$TMP_ROOT/out"
  ln -s "$REPO_ROOT/assets" "$TMP_ROOT/assets"
  PRISTINE="$TMP_ROOT/record.pristine.md"
  cp -a "$TMP_ROOT/docs/code_read/MorphMimic完整复现记录.md" "$PRISTINE"
  BROKEN="$TMP_ROOT/docs/code_read/MorphMimic完整复现记录.md"
}

# run_verify — runs the verifier against the temporary root.
#   stdout is captured in $OUT, the exit code in $RC.
run_verify() {
  OUT="$(DOC_REPO_ROOT="$TMP_ROOT" DOC_LOG_DIR="$TMP_ROOT/envlogs" \
        bash "$DOC_VERIFY" verify 2>&1)"
  RC=$?
}

# assert_negative <id> <expected reason> <description>
#
#   * the exit code is 1,
#   * the verdict names the expected reason,
#   * stdout holds ZERO OK markers.
assert_negative() {
  local id="$1" expected="$2" description="$3"
  local ok=1

  [ "$RC" -eq 1 ] || { fail "$id: exit code is $RC, expected 1"; ok=0; }
  printf '%s\n' "$OUT" | grep -q "DOC_VERIFY_FAIL reason=$expected\$" || {
    fail "$id: expected 'DOC_VERIFY_FAIL reason=$expected'"; ok=0; }
  if printf '%s\n' "$OUT" | grep -q 'DOC_VERIFY_OK'; then
    fail "$id: stdout contains a DOC_VERIFY_OK marker"; ok=0
  fi
  if printf '%s\n' "$OUT" | grep -q 'DOC_MIRROR_OK'; then
    fail "$id: stdout contains a DOC_MIRROR_OK marker"; ok=0
  fi

  {
    printf '\n--- %s: %s ---\n' "$id" "$description"
    printf 'command: DOC_REPO_ROOT=<tmp> DOC_LOG_DIR=<tmp>/envlogs bash repro/28_doc_verify.sh verify\n'
    printf '%s\n' "$OUT"
    printf '%s rc=%s\n' "$id" "$RC"
    printf 'assertions: rc==1 expected_reason=%s zero_ok_markers=1 -> %s\n' \
      "$expected" "$([ "$ok" -eq 1 ] && echo PASS || echo FAIL)"
  } >>"$NEG_LOG"

  [ "$ok" -eq 1 ] || return 1
  note "  $id: rc=$RC reason=$expected (no OK marker) -- PASS"
  return 0
}

# --------------------------------------------------------------------------
# NEG-1 — break a number inside the evidence index table.
#
# The key output of one evidence row is changed so that it is no longer
# greppable in its evidence file.  The row is chosen by the decision base's
# own rules (the string must be present before the change and absent after
# it), so the negative cannot degenerate into a different reason.
# --------------------------------------------------------------------------
neg1_break_marker() {
  "$DOC_PY" - "$BROKEN" "$PRISTINE" "$TMP_ROOT" <<'PYEOF'
import os, re, sys

broken_path, pristine_path, root = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(pristine_path, encoding="utf-8").read()

START = "<!-- DOC_EVIDENCE_TABLE_START -->"
END = "<!-- DOC_EVIDENCE_TABLE_END -->"
start = text.index(START)
end = text.index(END)
block = text[start:end]

lines = block.splitlines()
out_lines = []
changed = False
for line in lines:
    if not changed and line.strip().startswith("|"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 4 and cells[0] not in ("结论", "Conclusion"):
            path, output = cells[2], cells[3]
            target = os.path.join(root, path)
            if os.path.isfile(target):
                body = open(target, encoding="utf-8", errors="replace").read().lower()
                if output and output.lower() in body:
                    for m in re.finditer(r"\d", output):
                        digit = m.group(0)
                        mutated = output[:m.start()] + ("9" if digit != "9" else "8") + output[m.end():]
                        if mutated.lower() not in body:
                            cells[3] = mutated
                            line = "| " + " | ".join(cells) + " |"
                            changed = True
                            print("NEG-1 mutation: evidence row %r -> %r (file %s)"
                                  % (output, mutated, path))
                            break
    out_lines.append(line)

if not changed:
    print("NEG-1: no evidence row could be broken", file=sys.stderr)
    sys.exit(3)

# rebuild precisely: only the table block changed
new_block = "\n".join(out_lines)
result = text[:start] + new_block + text[end:]
open(broken_path, "w", encoding="utf-8").write(result)
PYEOF
  return $?
}

# --------------------------------------------------------------------------
# NEG-2 — delete chapter 4 ("已分析未执行") from the copy.
# --------------------------------------------------------------------------
neg2_delete_section4() {
  "$DOC_PY" - "$BROKEN" "$PRISTINE" <<'PYEOF'
import re, sys

broken_path, pristine_path = sys.argv[1], sys.argv[2]
text = open(pristine_path, encoding="utf-8").read()
pattern = re.compile(r"[ \t]*<!-- DOC_SECTION:4 -->.*?<!-- /DOC_SECTION:4 -->\n?",
                     re.DOTALL)
new_text, count = pattern.subn("", text)
if count != 1:
    print("NEG-2: chapter 4 block not found (%d)" % count, file=sys.stderr)
    sys.exit(3)
open(broken_path, "w", encoding="utf-8").write(new_text)
print("NEG-2 mutation: chapter 4 (DOC_SECTION:4) deleted (%d chars)" % (len(text) - len(new_text)))
PYEOF
  return $?
}

# --------------------------------------------------------------------------
# NEG-3 — inject a fake plaintext token into the body of the copy.
#
# The token is fake by construction: "hf_" plus 28 random-looking
# alphanumerics that exist nowhere else in the repository.  The two halves
# are kept apart so that this SOURCE FILE never holds a literal that
# matches the leak pattern itself (hf_ + 20 alphanumerics).
# --------------------------------------------------------------------------
neg3_inject_token() {
  "$DOC_PY" - "$BROKEN" "$PRISTINE" <<'PYEOF'
import sys

broken_path, pristine_path = sys.argv[1], sys.argv[2]
text = open(pristine_path, encoding="utf-8").read()
fake = "hf_" + "Qw7Zx2Lp9Rt4" + "Km6Nv1Bs8Dc3Fg5Hj"
marker = "<!-- DOC_SECTION:9 -->"
if marker not in text:
    print("NEG-3: chapter 9 marker not found", file=sys.stderr)
    sys.exit(3)
inject = ("\n> 撤销提醒示例（负例注入，非真实凭证）：`%s`\n" % fake)
new_text = text.replace(marker, marker + inject, 1)
open(broken_path, "w", encoding="utf-8").write(new_text)
print("NEG-3 mutation: fake plaintext token injected (%d chars)" % len(fake))
PYEOF
  return $?
}

# --------------------------------------------------------------------------
# cmd_run — the battery.
# --------------------------------------------------------------------------
cmd_run() {
  local before after residue
  before="$(landings_digest)"

  build_tmp_root
  note "temporary root: $TMP_ROOT (the formal landing points are untouched)"

  # the transcript is rewritten from scratch on every run (a partial run
  # must never be mistaken for a complete one)
  : >"$NEG_LOG"

  {
    printf '=== 29_doc_verify_negatives.sh — real negative transcripts of the record verifier ===\n'
    printf 'record:   %s\n' "$RECORD_REL"
    printf 'verifier: repro/28_doc_verify.sh verify\n'
    printf 'digests of the formal landing points BEFORE the battery: %s\n' "$before"
    printf '\n'
  } >>"$NEG_LOG"

  # --- NEG-1 ---------------------------------------------------------------
  cp -a "$PRISTINE" "$BROKEN"
  if neg1_break_marker; then
    run_verify
    assert_negative "NEG-1" "evidence-marker-missing" \
      "a number inside the evidence index table was changed (the key output is no longer greppable)"
  else
    fail "NEG-1: the mutation itself failed"
  fi

  # --- NEG-2 ---------------------------------------------------------------
  cp -a "$PRISTINE" "$BROKEN"
  if neg2_delete_section4; then
    run_verify
    assert_negative "NEG-2" "section-missing" \
      "chapter 4 (已分析未执行清单) was deleted from the copy"
  else
    fail "NEG-2: the mutation itself failed"
  fi

  # --- NEG-3 ---------------------------------------------------------------
  cp -a "$PRISTINE" "$BROKEN"
  if neg3_inject_token; then
    run_verify
    assert_negative "NEG-3" "token-leaked" \
      "a fake plaintext token (hf_ + 28 alphanumerics) was injected into the body"
  else
    fail "NEG-3: the mutation itself failed"
  fi

  # --- the formal landing points must be untouched -------------------------
  after="$(landings_digest)"
  if [ "$before" = "$after" ]; then
    note "  landing points: digest unchanged ($after)"
    printf 'digests of the formal landing points AFTER the battery:  %s (unchanged)\n' "$after" >>"$NEG_LOG"
  else
    fail "the formal landing points changed: $before -> $after"
    printf 'digests of the formal landing points AFTER the battery:  %s (CHANGED)\n' "$after" >>"$NEG_LOG"
  fi

  residue="$(staging_residue)"
  if [ -z "$residue" ]; then
    note "  staging residue: none"
    printf 'staging residue (.staging-*): none\n' >>"$NEG_LOG"
  else
    fail "staging residue found:"
    printf '%s\n' "$residue" >&2
    printf 'staging residue (.staging-*):\n%s\n' "$residue" >>"$NEG_LOG"
  fi

  rm -rf "$TMP_ROOT"
  note "temporary root removed: $TMP_ROOT"

  if [ "$FAILURES" -eq 0 ]; then
    note "DOC_NEGATIVES_OK negatives=3 reasons=evidence-marker-missing,section-missing,token-leaked"
    return 0
  fi
  note "DOC_NEGATIVES_FAIL failures=$FAILURES"
  return 1
}

# --------------------------------------------------------------------------
# cmd_both — the two-sided consistency of the terminal gate.
#
# The host side and the container side (the ros_dev container, reached
# through repro/lib/remote.sh) must reach the SAME conclusion, byte for
# byte.  The container side only checks the in-repo mirror, because the
# docs/code_doc symlink is broken inside the container (MEM023 / D009).
#
# This subcommand runs on the HOST only (it drives the container itself).
# --------------------------------------------------------------------------
cmd_both() {
  local host_out host_rc cont_out cont_rc host_marker cont_marker
  host_out="$(bash "$DOC_VERIFY" verify 2>&1)"; host_rc=$?
  cont_out="$(bash "$REPO_ROOT/repro/lib/remote.sh" 28_doc_verify.sh verify 2>&1)"; cont_rc=$?
  host_marker="$(printf '%s\n' "$host_out" | grep '^DOC_VERIFY_OK ' | head -n1)"
  cont_marker="$(printf '%s\n' "$cont_out" | grep '^DOC_VERIFY_OK ' | head -n1)"

  note "host     rc=$host_rc $host_marker"
  note "container rc=$cont_rc $cont_marker"

  if [ "$host_rc" -ne 0 ] || [ "$cont_rc" -ne 0 ]; then
    fail "the two-sided gate did not exit 0 (host=$host_rc container=$cont_rc)"
    return 1
  fi
  if [ -z "$host_marker" ] || [ -z "$cont_marker" ]; then
    fail "one of the two sides printed no DOC_VERIFY_OK marker"
    return 1
  fi
  if [ "$host_marker" != "$cont_marker" ]; then
    fail "the two sides disagree: '$host_marker' vs '$cont_marker'"
    return 1
  fi
  note "DOC_TWO_SIDES_OK markers_identical=1"
  return 0
}

# --------------------------------------------------------------------------
# cmd_check — the close-out self-check only (read-only).
# --------------------------------------------------------------------------
cmd_check() {
  local residue
  note "landings digest: $(landings_digest)"
  residue="$(staging_residue)"
  if [ -z "$residue" ]; then
    note "staging residue: none"
    return 0
  fi
  note "staging residue:"
  printf '%s\n' "$residue"
  return 1
}

case "${1:-run}" in
  run) cmd_run ;;
  both) cmd_both ;;
  check) cmd_check ;;
  -h|--help|help)
    printf 'usage: bash repro/29_doc_verify_negatives.sh [run|both|check]\n'
    ;;
  *)
    printf 'usage: bash repro/29_doc_verify_negatives.sh [run|both|check]\n' >&2
    exit 2
    ;;
esac
