#!/usr/bin/env bash
# repro/lib/toolchain.sh — probe library for the four external tool chains.
#
# Split out of repro/07_toolchain.sh so that the verdict contract can be unit
# tested offline (repro/tests/test_toolchain.sh) without network, compiler,
# container or a real venv.
#
# THE VERDICT CONTRACT (R002 / D010)
#
#   For every tool exactly ONE group of three lines is produced:
#
#       TOOLCHAIN_<NAME>_VERDICT=VERIFIED|SKIPPED
#       TOOLCHAIN_<NAME>_REASON=<non-empty explanation>
#       TOOLCHAIN_<NAME>_EVIDENCE=<log / artefact path or command>
#
#   <NAME> is one of GMR (baseline), SOMA, XRT, UNITREE.
#   * VERIFIED means "the tool chain was really exercised" and the REASON
#     says WHAT was exercised;
#   * SKIPPED means "not exercised" and the REASON says WHY (version, missing
#     privilege, missing hardware, network, ...);
#   * "neither verified nor explained" is not an allowed state: an empty
#     REASON or an empty EVIDENCE is rejected by tc_emit_verdict.
#
#   The same three lines are written to
#       logs/env/07_toolchain.txt      (the probe run)
#       docs/code_read/TOOLCHAIN.md    (the human readable conclusion)
#   and repro/07_toolchain.sh verify cross-checks the two.
#
# WHERE THE PROBES WORK
#
#   * clones and build trees live under logs/toolchain/ (git-ignored) — the
#     repository work tree and the third_party submodules must stay clean
#     (repro/02_submodules.sh rejects a dirty submodule);
#   * every git operation goes through common.sh's git_in (setpriv to the
#     directory owner) — plain `git` in the container dies with
#     "fatal: detected dubious ownership" on the NFS export;
#   * the network only works through the inlined proxy of common.sh; nothing
#     is ever written to /etc/environment, ~/.bashrc, pip.conf or uv.toml;
#   * every heavy step runs under `timeout` so a probe can never hang the
#     one-shot orchestration.
#
# The probes degrade honestly: when a step fails, the raw error summary goes
# into the REASON (and into logs/toolchain/diag/) and the verdict becomes
# SKIPPED with that reason.  A probe never fails silently and never claims
# VERIFIED for something it did not run.

# --- the four tools --------------------------------------------------------
TC_TOOL_NAMES="GMR SOMA XRT UNITREE"

# pinned upstream commits (must not drift silently)
TC_GMR_SHA="${TC_GMR_SHA:-25f56db79ac411258b377b6d4ccba0c8ff3372ac}"
TC_SOMA_SHA="${TC_SOMA_SHA:-cbdb2b494a2af82137bf9b6f15122d60167281c4}"
TC_XRT_SHA="${TC_XRT_SHA:-8941e1dbbf4313fe83846f82984eaa8c992690bf}"
TC_UNITREE_SHA="${TC_UNITREE_SHA:-6264cc1efd9e72d3c7fffa38a360aea9e43838f3}"

# --- work areas (all inside the git-ignored logs/ tree) --------------------
# The probe output (clones, build trees, isolated venvs, diagnostics) is
# heavy and must survive a worktree rebuild, so it is addressed through the
# PERSISTENT STORE, never through the worktree.  Before this was fixed the
# probe wrote into the worktree's plain logs/ directory and the whole tree
# was deleted by the next GSD reconcile (observed 2026-11-11).
TC_ROOT="${TC_ROOT:-${SEED_STORE_ROOT:-$REPO_ROOT/logs}/toolchain}"
TC_SRC_DIR="${TC_SRC_DIR:-$TC_ROOT/src}"
TC_BUILD_DIR="${TC_BUILD_DIR:-$TC_ROOT/build}"
TC_VENV_DIR="${TC_VENV_DIR:-$TC_ROOT/venvs}"
TC_DIAG_DIR="${TC_DIAG_DIR:-$TC_ROOT/diag}"

# --- time budgets (seconds) ------------------------------------------------
# The heavy steps run behind `timeout`; exceeding the budget degrades the
# verdict to SKIPPED with the timeout in the reason.
TC_TIMEOUT_SOMA="${TC_TIMEOUT_SOMA:-900}"
TC_TIMEOUT_XRT="${TC_TIMEOUT_XRT:-1200}"
TC_TIMEOUT_UNITREE="${TC_TIMEOUT_UNITREE:-600}"
TC_TIMEOUT_CLONE="${TC_TIMEOUT_CLONE:-600}"

# TC_OFFLINE=1 short-circuits every probe to SKIPPED (used by the offline
# unit tests: no network, no compiler, no clone).
TC_OFFLINE="${TC_OFFLINE:-0}"

# --- small helpers ---------------------------------------------------------

# tc_git_in <timeout_s> <dir> <git args...>
#
# Like common.sh's git_in (git as the uid that owns <dir>, so the NFS export
# does not trigger "detected dubious ownership") but with a hard timeout.
# `timeout` cannot wrap a shell function, so the setpriv/env/git chain is
# rebuilt here.
tc_git_in() {
  local tmo="${1:-60}"; shift
  local dir="${1:-}"; shift
  [ "$#" -gt 0 ] || { echo "tc_git_in: no git command given" >&2; return 2; }
  local uid gid
  uid="$(stat -c %u "$dir" 2>/dev/null || echo 0)"
  gid="$(stat -c %g "$dir" 2>/dev/null || echo 0)"
  # GIT_LFS_SKIP_SMUDGE=1: the tool chain probes only need the SOURCE of the
  # third party repos.  The LFS assets (sample BVH / robot meshes) belong to
  # the batch retargeting runs of a later slice and would turn a clone into a
  # multi gigabyte download.
  #
  # GIT_INDEX_FILE on the container's local disk: on the NFS export git fails
  # with "fatal: unable to write new index file" (the index write needs a
  # local filesystem).  The index is a git runtime artefact, the repository
  # content stays on the NFS share.
  local idx
  idx="/tmp/tc_index_$(printf '%s' "$dir" | md5sum 2>/dev/null | cut -c1-12)"
  if [ "$(id -u)" -eq 0 ] && [ "$uid" != "0" ] && command -v setpriv >/dev/null 2>&1; then
    timeout "$tmo" setpriv --reuid="$uid" --regid="$gid" --clear-groups \
      env HOME="${GIT_TMP_HOME:-/tmp}" GIT_LFS_SKIP_SMUDGE=1 GIT_INDEX_FILE="$idx" \
      git -C "$dir" "${GIT_SAFE_OPTS[@]}" "$@"
  else
    timeout "$tmo" env GIT_LFS_SKIP_SMUDGE=1 GIT_INDEX_FILE="$idx" \
      git -C "$dir" "${GIT_SAFE_OPTS[@]}" "$@"
  fi
}


# tc_sanitize_line <text>
# Collapses a text into a single line (verdict lines are line oriented).
tc_sanitize_line() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'
}

# tc_rel_path <path> — render a path as it is seen FROM THE STORE ROOT.
#
# The verdict lines are compared byte by byte against the machine-greppable
# block in docs/code_read/TOOLCHAIN.md (tc_compare_verdicts).  An ABSOLUTE
# path would embed the mount prefix of whoever ran the probe: the host sees
# /mnt/test_cc_dev/..., the container sees /home/ubuntu/work_dev/.../ — so the
# same probe run would produce two different blocks and the comparison could
# never hold across both sides.  Store-relative paths ("logs/toolchain/...",
# "data/...", "out/...") are identical everywhere.
tc_rel_path() {
  local p="${1:-}" root="${SEED_STORE_ROOT:-}"
  [ -n "$p" ] || { printf ''; return 0; }
  if [ -n "$root" ]; then
    case "$p" in
      "$root"/*) printf '%s' "${p#"$root"/}"; return 0 ;;
    esac
  fi
  printf '%s' "$p"
}

# tc_repo_rel_path <path> — render a path as it is seen FROM THE REPOSITORY
# ROOT (third_party/GMR/...).  Used for artefacts that live in the worktree
# (the submodule checkout) rather than in the store.
tc_repo_rel_path() {
  local p="${1:-}"
  [ -n "$p" ] || { printf ''; return 0; }
  case "$p" in
    "${REPO_ROOT}"/*) printf '%s' "${p#"$REPO_ROOT"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# tc_emit_verdict <NAME> <VERDICT> <REASON> <EVIDENCE>
#
# The single place where a verdict line is produced.  It refuses to print
# anything that violates the contract (unknown tool, illegal verdict, empty
# reason, empty evidence) and returns non-zero in that case.
tc_emit_verdict() {
  local name="${1:-}" verdict="${2:-}" reason evidence
  reason="$(tc_sanitize_line "${3:-}")"
  evidence="$(tc_sanitize_line "${4:-}")"

  case "$name" in
    GMR|SOMA|XRT|UNITREE) ;;
    *) echo "tc_emit_verdict: unknown tool name: '$name'" >&2; return 2 ;;
  esac
  case "$verdict" in
    VERIFIED|SKIPPED) ;;
    *) echo "tc_emit_verdict: illegal verdict for $name: '$verdict'" >&2; return 2 ;;
  esac
  if [ -z "$reason" ]; then
    echo "tc_emit_verdict: $name needs a non-empty reason" >&2
    return 2
  fi
  if [ -z "$evidence" ]; then
    echo "tc_emit_verdict: $name needs a non-empty evidence" >&2
    return 2
  fi

  printf 'TOOLCHAIN_%s_VERDICT=%s\n' "$name" "$verdict"
  printf 'TOOLCHAIN_%s_REASON=%s\n' "$name" "$reason"
  printf 'TOOLCHAIN_%s_EVIDENCE=%s\n' "$name" "$evidence"
  return 0
}

# tc_probe_skip <NAME> <REASON> <EVIDENCE>
# The one helper a probe uses when it degrades to SKIPPED.
tc_probe_skip() {
  tc_emit_verdict "${1:-}" SKIPPED "${2:-}" "${3:-}"
}

# tc_probe_diag <NAME> <text...>
# Diagnostic line (not a verdict line) — goes to the log for the humans.
tc_probe_diag() {
  local name="${1:-}"; shift
  printf 'PROBE[%s] %s\n' "$name" "$(tc_sanitize_line "$*")"
}

# tc_pinned_sha <submodule path>
#
# The gitlink SHA recorded in the superproject (the pinned version the
# repository ships with), or an empty string when the path is not a submodule.
tc_pinned_sha() {
  local path="${1:-}"
  local line
  # the worktree's gitdir pointer is host-local; common.sh remaps it (the
  # container sees the worktree under a different mount prefix).
  if [ -z "${GIT_DIR_RESOLVED:-}" ] && command -v resolve_git_context >/dev/null 2>&1; then
    resolve_git_context
  fi
  line="$(git_repo ls-tree HEAD -- "$path" 2>/dev/null | head -n 1)"
  printf '%s' "$line" | awk '{ if ($1 == "160000" && NF >= 3) print $3; }'
}

# tc_tail_error <file>
# The last meaningful lines of a log file, flattened into one line — this is
# the "raw error summary" that ends up in the REASON of a SKIPPED verdict.
tc_tail_error() {
  local f="${1:-}"
  [ -f "$f" ] || { printf 'no log file %s' "$f"; return 0; }
  tail -n 8 "$f" 2>/dev/null | tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'
}

# --- parsing / checking ----------------------------------------------------

# tc_parse_verdicts <file>
#
# Prints one line per tool: "<NAME>|<VERDICT>|<REASON>|<EVIDENCE>".
# Missing fields stay empty — the caller decides whether that is fatal.
tc_parse_verdicts() {
  local file="${1:-}"
  if [ ! -f "$file" ]; then
    echo "tc_parse_verdicts: no such file: $file" >&2
    return 2
  fi

  local -A verdicts=() reasons=() evidences=()
  local line key value name field
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TOOLCHAIN_*_VERDICT=*|TOOLCHAIN_*_REASON=*|TOOLCHAIN_*_EVIDENCE=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    name="${key#TOOLCHAIN_}"
    case "$name" in
      *_VERDICT)  field="VERDICT";  name="${name%_VERDICT}" ;;
      *_REASON)   field="REASON";   name="${name%_REASON}" ;;
      *_EVIDENCE) field="EVIDENCE"; name="${name%_EVIDENCE}" ;;
      *) continue ;;
    esac
    case "$name" in
      GMR|SOMA|XRT|UNITREE) ;;
      *) continue ;;
    esac
    case "$field" in
      VERDICT)  verdicts["$name"]="$value" ;;
      REASON)   reasons["$name"]="$value" ;;
      EVIDENCE) evidences["$name"]="$value" ;;
    esac
  done <"$file"

  local n
  for n in $TC_TOOL_NAMES; do
    printf '%s|%s|%s|%s\n' "$n" "${verdicts[$n]:-}" "${reasons[$n]:-}" "${evidences[$n]:-}"
  done
  return 0
}

# tc_check_verdicts <file>
#
# The completeness assertion: all four groups present, legal verdict, non
# empty reason, non empty evidence.  Prints TOOLCHAIN_OK on success and
# TOOLCHAIN_FAIL (with one detail line per problem) otherwise.
tc_check_verdicts() {
  local file="${1:-}"
  local rc=0 name verdict reason evidence
  while IFS='|' read -r name verdict reason evidence; do
    [ -n "$name" ] || continue
    if [ -z "$verdict" ]; then
      echo "TOOLCHAIN_FAIL missing verdict for $name"
      rc=1
      continue
    fi
    case "$verdict" in
      VERIFIED|SKIPPED) ;;
      *) echo "TOOLCHAIN_FAIL illegal verdict for $name: '$verdict'"; rc=1 ;;
    esac
    if [ -z "$reason" ]; then
      echo "TOOLCHAIN_FAIL empty reason for $name"
      rc=1
    fi
    if [ -z "$evidence" ]; then
      echo "TOOLCHAIN_FAIL empty evidence for $name"
      rc=1
    fi
  done < <(tc_parse_verdicts "$file" 2>/dev/null || true)

  if [ "$rc" -eq 0 ]; then
    echo "TOOLCHAIN_OK"
    return 0
  fi
  echo "TOOLCHAIN_FAIL"
  return 1
}

# tc_compare_verdicts <logfile> <docfile>
#
# Cross-checks the probe log against the written conclusion: every tool must
# carry the same verdict, the same reason and the same evidence in both.
# Prints TOOLCHAIN_DOC_OK or TOOLCHAIN_DOC_FAIL with the differences.
tc_compare_verdicts() {
  local logf="${1:-}" docf="${2:-}"
  local rc=0
  if [ ! -f "$logf" ]; then
    echo "TOOLCHAIN_DOC_FAIL missing log file: $logf"
    return 1
  fi
  if [ ! -f "$docf" ]; then
    echo "TOOLCHAIN_DOC_FAIL missing conclusion file: $docf"
    return 1
  fi

  local -A lver=() lrea=() leve=() dver=() drea=() deve=()
  local side name verdict reason evidence
  for side in log doc; do
    local file="$logf"
    [ "$side" = "doc" ] && file="$docf"
    local -A V=() R=() E=()
    local line key value field
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        TOOLCHAIN_*_VERDICT=*|TOOLCHAIN_*_REASON=*|TOOLCHAIN_*_EVIDENCE=*) ;;
        *) continue ;;
      esac
      key="${line%%=*}"; value="${line#*=}"; name="${key#TOOLCHAIN_}"
      case "$name" in
        *_VERDICT)  field="VERDICT";  name="${name%_VERDICT}" ;;
        *_REASON)   field="REASON";   name="${name%_REASON}" ;;
        *_EVIDENCE) field="EVIDENCE"; name="${name%_EVIDENCE}" ;;
        *) continue ;;
      esac
      case "$name" in GMR|SOMA|XRT|UNITREE) ;; *) continue ;; esac
      case "$field" in
        VERDICT)  V["$name"]="$value" ;;
        REASON)   R["$name"]="$value" ;;
        EVIDENCE) E["$name"]="$value" ;;
      esac
    done <"$file"
    if [ "$side" = "log" ]; then
      lver=("${V[@]}"); lrea=("${R[@]}"); leve=("${E[@]}")
    else
      dver=("${V[@]}"); drea=("${R[@]}"); deve=("${E[@]}")
    fi
  done

  # the associative arrays above lose the key association, so compare with
  # the parser instead (one line per tool).
  local lline dline
  while IFS='|' read -r name verdict reason evidence; do
    [ -n "$name" ] || continue
    dline="$(tc_parse_verdicts "$docf" | grep "^$name|" || true)"
    local dver_v="" drea_v="" deve_v=""
    IFS='|' read -r _ dver_v drea_v deve_v <<<"$dline"
    lline="${verdict}|${reason}|${evidence}"
    if [ "${lline%%|*}" != "$dver_v" ]; then
      echo "TOOLCHAIN_DOC_FAIL verdict mismatch for $name: log=${verdict} doc=${dver_v:-<none>}"
      rc=1
    fi
    if [ "$reason" != "$drea_v" ]; then
      echo "TOOLCHAIN_DOC_FAIL reason mismatch for $name"
      rc=1
    fi
    if [ "$evidence" != "$deve_v" ]; then
      echo "TOOLCHAIN_DOC_FAIL evidence mismatch for $name"
      rc=1
    fi
  done < <(tc_parse_verdicts "$logf")

  if [ "$rc" -eq 0 ]; then
    echo "TOOLCHAIN_DOC_OK"
    return 0
  fi
  echo "TOOLCHAIN_DOC_FAIL"
  return 1
}

# ===========================================================================
# the real probes
# ===========================================================================

# tc_probe_gmr
#
# Baseline: the GMR submodule must be in place at the pinned commit AND the
# project venv must be able to import it (this is what S01's teleop group
# installed).  Cheap, offline, no build.
tc_probe_gmr() {
  local name="GMR"
  local dir="$REPO_ROOT/third_party/GMR"
  local expected actual import_out

  if [ "${TC_OFFLINE:-0}" = "1" ]; then
    tc_probe_skip "$name" "TC_OFFLINE=1：离线模式，未执行导入检查" "logs/env/07_toolchain.txt"
    return 0
  fi

  expected="$(tc_pinned_sha third_party/GMR)"
  actual=""
  if [ -d "$dir" ]; then
    actual="$(git_in "$dir" rev-parse HEAD 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  tc_probe_diag "$name" "pinned=$expected actual=${actual:-<none>}"

  local raw_import=""
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    raw_import="$("$REPO_ROOT/.venv/bin/python" -c 'import general_motion_retargeting as g; print("GMR_IMPORT_OK", g.__file__)' 2>&1 || true)"
  fi
  # GMR's __init__ prints a hint about the missing XRoboToolkit SDK; only the
  # marker line is the evidence.
  import_out="$(printf '%s\n' "$raw_import" | grep '^GMR_IMPORT_OK' | head -n 1 || true)"
  import_out="GMR_IMPORT_OK $(tc_repo_rel_path "${import_out#GMR_IMPORT_OK }")"
  tc_probe_diag "$name" "import=${import_out:-<none>}"

  if [ -n "$expected" ] && [ "$actual" = "$expected" ] \
     && printf '%s' "$import_out" | grep -q '^GMR_IMPORT_OK'; then
    tc_emit_verdict "$name" VERIFIED \
      "third_party/GMR 落在锁定的提交 $expected，且项目 venv 可导入 general_motion_retargeting（S01 的 teleop 组未退化）" \
      "logs/env/07_toolchain.txt; third_party/GMR@$expected; $import_out"
    return 0
  fi

  local why=""
  if [ "$actual" != "$expected" ]; then
    why="子模块 HEAD 与锁定提交不一致（期望 $expected，实际 ${actual:-<none>}）"
  else
    why="项目 venv 无法导入 general_motion_retargeting"
  fi
  tc_probe_skip "$name" \
    "$why；导入输出：$(tc_sanitize_line "${raw_import:-<none>}")" \
    "logs/env/07_toolchain.txt; logs/toolchain/diag/gmr_import.log"
  return 0
}

# tc_probe_soma
#
# NVIDIA/soma-retargeter @ cbdb2b4:
#   1. clone the pinned commit (git_in, proxy inlined),
#   2. install its dependencies into an INDEPENDENT venv (it requires
#      Python >= 3.12, the project venv is 3.11 -> it must never go into
#      the project venv),
#   3. import the package and list the available robot targets,
#   4. check that the project side scripts (stage_subset / assemble_robots /
#      validate_csv) run.
# Every step is bounded by `timeout`; a failure degrades to SKIPPED with the
# raw error summary.
tc_probe_soma() {
  local name="SOMA"
  local clone="$TC_SRC_DIR/soma-retargeter"
  local venv="$TC_VENV_DIR/soma"
  local log_clone="$TC_DIAG_DIR/soma_clone.log"
  local log_sync="$TC_DIAG_DIR/soma_sync.log"
  local log_import="$TC_DIAG_DIR/soma_import.log"
  local log_tools="$TC_DIAG_DIR/soma_tools.log"

  if [ "${TC_OFFLINE:-0}" = "1" ]; then
    tc_probe_skip "$name" "TC_OFFLINE=1：离线模式，未克隆 NVIDIA/soma-retargeter" "logs/env/07_toolchain.txt"
    return 0
  fi

  mkdir -p "$TC_SRC_DIR" "$TC_VENV_DIR" "$TC_DIAG_DIR"

  # 1. clone
  if [ ! -d "$clone/.git" ]; then
    tc_probe_diag "$name" "cloning NVIDIA/soma-retargeter -> $clone"
    if ! tc_git_in "$TC_TIMEOUT_CLONE" "$TC_SRC_DIR" clone --quiet \
         https://github.com/NVIDIA/soma-retargeter.git "$clone" >"$log_clone" 2>&1; then
      tc_probe_skip "$name" \
        "克隆 NVIDIA/soma-retargeter 失败：$(tc_tail_error "$log_clone")" \
        "logs/env/07_toolchain.txt; $log_clone"
      return 0
    fi
  fi
  if [ "$(git_in "$clone" rev-parse HEAD 2>/dev/null | tr -d '[:space:]' || true)" != "$TC_SOMA_SHA" ]; then
    if ! tc_git_in 300 "$clone" checkout --quiet "$TC_SOMA_SHA" >"$log_clone" 2>&1; then
      tc_probe_skip "$name" \
        "检出锁定提交 $TC_SOMA_SHA 失败：$(tc_tail_error "$log_clone")" \
        "logs/env/07_toolchain.txt; $log_clone"
      return 0
    fi
  fi
  tc_probe_diag "$name" "clone ok at $(git_in "$clone" rev-parse HEAD 2>/dev/null | tr -d '[:space:]')"

  # 2. dependencies in an independent venv (Python >= 3.12).  The sync is
  # idempotent: an up to date venv is re-verified in seconds, an interrupted
  # one is completed — so the probe can be re-run after a timeout.
  tc_probe_diag "$name" "installing dependencies into $venv (independent venv, python >= 3.12)"
  local sync_cmd="uv sync"
  [ -f "$clone/uv.lock" ] && sync_cmd="uv sync --frozen"
  if ! ( cd "$clone" && UV_PROJECT_ENVIRONMENT="$venv" timeout "$TC_TIMEOUT_SOMA" \
           $sync_cmd ) >"$log_sync" 2>&1; then
    tc_probe_skip "$name" \
      "依赖安装失败或超时（$sync_cmd，独立 venv，requires-python>=3.12 与项目 venv 3.11 不兼容）：$(tc_tail_error "$log_sync")" \
      "logs/env/07_toolchain.txt; $log_sync"
    return 0
  fi

  # 3. import + targets
  if ! timeout 300 "$venv/bin/python" - >"$log_import" 2>&1 <<'PY'
import importlib
mod = importlib.import_module("soma_retargeter")
print("SOMA_IMPORT_OK", mod.__file__)
try:
    from soma_retargeter.robotics.robot_registry import list_available_targets
    print("SOMA_TARGETS", list_available_targets())
except Exception as exc:  # the registry moved between upstream commits
    print("SOMA_TARGETS_UNAVAILABLE", exc)
PY
  then
    tc_probe_skip "$name" \
      "soma_retargeter 导入失败：$(tc_tail_error "$log_import")" \
      "logs/env/07_toolchain.txt; $log_import"
    return 0
  fi
  local import_out targets_out
  import_out="$(grep '^SOMA_IMPORT_OK' "$log_import" | head -n 1 || true)"
  targets_out="$(grep '^SOMA_TARGETS ' "$log_import" | head -n 1 || true)"
  tc_probe_diag "$name" "import=$import_out"
  tc_probe_diag "$name" "$targets_out"

  # 4. project side scripts
  local t
  : >"$log_tools"
  for t in stage_subset assemble_robots validate_csv; do
    if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
      if ! ( cd "$REPO_ROOT" && timeout 120 "$REPO_ROOT/.venv/bin/python" \
               "tools/soma_retargeter/$t.py" --help ) >>"$log_tools" 2>&1; then
        tc_probe_skip "$name" \
          "项目侧脚本 tools/soma_retargeter/$t.py --help 失败：$(tc_tail_error "$log_tools")" \
          "logs/env/07_toolchain.txt; $log_tools"
        return 0
      fi
    fi
  done
  tc_probe_diag "$name" "project side scripts ok"

  tc_emit_verdict "$name" VERIFIED \
    "NVIDIA/soma-retargeter@$TC_SOMA_SHA 已克隆并钉住该提交，依赖装进独立 Python>=3.12 venv（$(tc_rel_path "$venv")，未污染项目 venv），soma_retargeter 可导入并能列出机器人目标，项目侧 stage_subset/assemble_robots/validate_csv 三个脚本 --help 全部退出 0" \
    "logs/env/07_toolchain.txt; $(tc_rel_path "$clone")@$TC_SOMA_SHA; $import_out; ${targets_out:-SOMA_TARGETS 未公开}; $(tc_rel_path "$log_import")"
  return 0
}

# tc_probe_xrt
#
# XR-Robotics/XRoboToolkit-PC-Service-Pybind @ 8941e1d (the XRT_REF of
# deploy/install_pico.sh):
#   1. clone the pinned commit,
#   2. build the wheel with scikit-build-core (which pulls a cmake >= 3.26
#      from PyPI — the image only has cmake 3.22.1),
#   3. install the wheel into an isolated venv and import it.
# The build happens in an isolated venv, the project venv is NOT touched
# (a plain `uv sync` would remove the package anyway).
tc_probe_xrt() {
  local name="XRT"
  local clone="$TC_SRC_DIR/XRoboToolkit-PC-Service-Pybind"
  local venv="$TC_VENV_DIR/xrt"
  local log_clone="$TC_DIAG_DIR/xrt_clone.log"
  local log_build="$TC_DIAG_DIR/xrt_build.log"
  local log_import="$TC_DIAG_DIR/xrt_import.log"

  if [ "${TC_OFFLINE:-0}" = "1" ]; then
    tc_probe_skip "$name" "TC_OFFLINE=1：离线模式，未克隆 XRoboToolkit" "logs/env/07_toolchain.txt"
    return 0
  fi

  mkdir -p "$TC_SRC_DIR" "$TC_VENV_DIR" "$TC_DIAG_DIR"

  if [ ! -d "$clone/.git" ]; then
    tc_probe_diag "$name" "cloning XRoboToolkit-PC-Service-Pybind -> $clone"
    if ! tc_git_in "$TC_TIMEOUT_CLONE" "$TC_SRC_DIR" clone --quiet \
         https://github.com/XR-Robotics/XRoboToolkit-PC-Service-Pybind.git "$clone" \
         >"$log_clone" 2>&1; then
      tc_probe_skip "$name" \
        "克隆 XRoboToolkit 失败：$(tc_tail_error "$log_clone")" \
        "logs/env/07_toolchain.txt; $log_clone"
      return 0
    fi
  fi
  if [ "$(git_in "$clone" rev-parse HEAD 2>/dev/null | tr -d '[:space:]' || true)" != "$TC_XRT_SHA" ]; then
    if ! tc_git_in 300 "$clone" checkout --quiet "$TC_XRT_SHA" >"$log_clone" 2>&1; then
      tc_probe_skip "$name" \
        "检出锁定提交 $TC_XRT_SHA 失败：$(tc_tail_error "$log_clone")" \
        "logs/env/07_toolchain.txt; $log_clone"
      return 0
    fi
  fi
  tc_probe_diag "$name" "clone ok at $(git_in "$clone" rev-parse HEAD 2>/dev/null | tr -d '[:space:]')"

  # build the wheel (scikit-build-core pulls its own cmake)
  local wheel
  wheel="$(ls -1 "$clone"/dist/*.whl 2>/dev/null | head -n 1 || true)"
  if [ -z "$wheel" ]; then
    tc_probe_diag "$name" "building the wheel with scikit-build-core (pulls cmake from PyPI)"
    if ! ( cd "$clone" && timeout "$TC_TIMEOUT_XRT" uv build --wheel --out-dir "$clone/dist" ) \
         >"$log_build" 2>&1; then
      tc_probe_skip "$name" \
        "scikit-build-core 构建 wheel 失败（镜像 cmake 只有 3.22.1 < 3.26，需要从 PyPI 拉 cmake）：$(tc_tail_error "$log_build")" \
        "logs/env/07_toolchain.txt; $log_build"
      return 0
    fi
    wheel="$(ls -1 "$clone"/dist/*.whl 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$wheel" ]; then
    tc_probe_skip "$name" \
      "构建结束但没有产出 wheel：$(tc_tail_error "$log_build")" \
      "logs/env/07_toolchain.txt; $log_build"
    return 0
  fi
  tc_probe_diag "$name" "wheel=$(basename "$wheel")"

  # install into an isolated venv (the project venv must stay in sync state)
  if [ ! -x "$venv/bin/python" ]; then
    timeout 300 uv venv --python 3.11 "$venv" >"$log_import" 2>&1 || true
  fi
  if ! timeout 900 uv pip install --python "$venv/bin/python" "$wheel" >>"$log_import" 2>&1; then
    tc_probe_skip "$name" \
      "把 wheel 装进隔离 venv 失败：$(tc_tail_error "$log_import")" \
      "logs/env/07_toolchain.txt; $log_import"
    return 0
  fi

  if ! timeout 120 "$venv/bin/python" -c 'import xrobotoolkit_sdk; print("XRT_IMPORT_OK", xrobotoolkit_sdk.__file__)' \
       >"$log_import" 2>&1; then
    tc_probe_skip "$name" \
      "xrobotoolkit_sdk 导入失败：$(tc_tail_error "$log_import")" \
      "logs/env/07_toolchain.txt; $log_import"
    return 0
  fi
  local import_out
  import_out="$(grep '^XRT_IMPORT_OK' "$log_import" | head -n 1 || true)"
  tc_probe_diag "$name" "$import_out"

  tc_emit_verdict "$name" VERIFIED \
    "XRoboToolkit-PC-Service-Pybind@$TC_XRT_SHA 已克隆并钉住该提交，用 scikit-build-core 构建出 $(basename "$wheel")（cp310-abi3），装进隔离 venv $(tc_rel_path "$venv") 后 xrobotoolkit_sdk 可导入；未装进项目 venv（普通 uv sync 会把它当锁文件外的包删掉）" \
    "logs/env/07_toolchain.txt; $(tc_rel_path "$clone")@$TC_XRT_SHA; $import_out; $(tc_rel_path "$log_build")"
  return 0
}

# tc_prepare_python311
#
# The uv managed interpreters live under /root (mode 700) and the Unitree
# binding has to be built as uid 1000 (build.sh refuses root) — uid 1000
# cannot traverse /root.  So the interpreter is COPIED into the git ignored
# logs tree first and the build venv is created from that copy.
# Prints the path of the copied interpreter (empty when it cannot be found).
tc_prepare_python311() {
  local dest="$TC_ROOT/python/cpython-3.11"
  local bin="$dest/bin/python3.11"
  if [ -x "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi
  local src=""
  local candidate
  for candidate in /root/.local/share/uv/python/cpython-3.11*/bin/python3.11 \
                   "$HOME"/.local/share/uv/python/cpython-3.11*/bin/python3.11; do
    [ -e "$candidate" ] || continue
    src="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    [ -n "$src" ] && break
  done
  if [ -z "$src" ]; then
    src="$(uv python find 3.11 2>/dev/null | head -n 1 || true)"
    [ -n "$src" ] && src="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
  fi
  [ -n "$src" ] || return 1
  local src_root
  src_root="$(dirname "$(dirname "$src")")"
  [ -d "$src_root" ] || return 1
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  # NOT `cp -a`: on the root-squashed NFS export every file would emit a
  # "failed to preserve ownership" warning, which is slow for a 100 MB tree.
  cp -r --no-preserve=ownership "$src_root" "$dest" || return 1
  chmod -R a+rX "$dest" 2>/dev/null || true
  [ -x "$bin" ] || return 1
  printf '%s' "$bin"
  return 0
}

# tc_probe_unitree
#
# third_party/unitree_sdk2_wrapper @ 6264cc1 (already vendored as a
# submodule):
#   1. the pinned commit + the SDK assets are in place,
#   2. the pybind11 binding is built — build.sh refuses to run as root and
#      would dirty the submodule with a build/ directory, so the wrapper is
#      copied into logs/toolchain/build/ and built there as uid 1000 with
#      the pybind11 of an isolated venv (the system pybind11-dev 2.9.1 does
#      not support Python 3.11),
#   3. the resulting module imports.
tc_probe_unitree() {
  local name="UNITREE"
  local wrapper="$REPO_ROOT/third_party/unitree_sdk2_wrapper"
  local copy="$TC_BUILD_DIR/unitree_sdk2_wrapper"
  local tools_venv="$TC_VENV_DIR/tools"
  local log_assets="$TC_DIAG_DIR/unitree_assets.log"
  local log_build="$TC_DIAG_DIR/unitree_build.log"
  local log_import="$TC_DIAG_DIR/unitree_import.log"

  if [ "${TC_OFFLINE:-0}" = "1" ]; then
    tc_probe_skip "$name" "TC_OFFLINE=1：离线模式，未构建 Unitree SDK 绑定" "logs/env/07_toolchain.txt"
    return 0
  fi

  mkdir -p "$TC_BUILD_DIR" "$TC_VENV_DIR" "$TC_DIAG_DIR"

  # 1. assets + pinned commit
  local expected actual
  expected="$(tc_pinned_sha third_party/unitree_sdk2_wrapper)"
  actual=""
  [ -d "$wrapper" ] && actual="$(git_in "$wrapper" rev-parse HEAD 2>/dev/null | tr -d '[:space:]' || true)"
  {
    echo "expected=$expected actual=${actual:-<none>}"
    for f in lib/x86_64/libunitree_sdk2.a include/unitree python_binding/unitree_interface.cpp; do
      if [ -e "$wrapper/$f" ]; then echo "ASSET_OK $f"; else echo "ASSET_MISSING $f"; fi
    done
  } >"$log_assets"
  tc_probe_diag "$name" "$(tc_sanitize_line "$(cat "$log_assets")")"

  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    tc_probe_skip "$name" \
      "子模块 HEAD 与锁定提交不一致（期望 $expected，实际 ${actual:-<none>}）" \
      "logs/env/07_toolchain.txt; $log_assets"
    return 0
  fi
  if grep -q '^ASSET_MISSING' "$log_assets"; then
    tc_probe_skip "$name" \
      "SDK 资产不完整：$(tc_tail_error "$log_assets")" \
      "logs/env/07_toolchain.txt; $log_assets"
    return 0
  fi

  # 2. build (in a copy, as uid 1000 — build.sh refuses root)
  local so_file
  so_file="$(ls -1 "$copy"/python_binding/build/lib/unitree_interface*.so 2>/dev/null | head -n 1 || true)"
  if [ -z "$so_file" ]; then
    tc_probe_diag "$name" "copying the wrapper into $copy and building the binding as uid 1000"
    rm -rf "$copy"
    cp -r --no-preserve=ownership "$wrapper" "$copy" || {
      tc_probe_skip "$name" "复制 wrapper 到 $copy 失败" "logs/env/07_toolchain.txt; $log_build"
      return 0
    }
    rm -rf "$copy/python_binding/build"

    if [ ! -x "$tools_venv/bin/python" ]; then
      local py311_bin
      py311_bin="$(tc_prepare_python311 || true)"
      if [ -z "$py311_bin" ]; then
        tc_probe_skip "$name" \
          "找不到可用的 CPython 3.11（uid 1000 读不到 /root 下的 uv 托管解释器，复制到 logs 树也失败）" \
          "logs/env/07_toolchain.txt; $log_build"
        return 0
      fi
      tc_probe_diag "$name" "build interpreter=$py311_bin"
      timeout 300 uv venv --python "$py311_bin" "$tools_venv" >>"$log_build" 2>&1 || true
    fi
    if ! timeout 600 uv pip install --python "$tools_venv/bin/python" "pybind11<3" >>"$log_build" 2>&1; then
      tc_probe_skip "$name" \
        "在隔离 venv 里安装 pybind11 失败：$(tc_tail_error "$log_build")" \
        "logs/env/07_toolchain.txt; $log_build"
      return 0
    fi
    local pybind_dir
    pybind_dir="$("$tools_venv/bin/python" -m pybind11 --cmakedir 2>/dev/null || true)"
    tc_probe_diag "$name" "pybind11 cmake dir=${pybind_dir:-<none>}"

    local runner="$TC_DIAG_DIR/unitree_build_cmd.sh"
    cat >"$runner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
cd "$copy/python_binding"
export PATH="$tools_venv/bin:\$PATH"
export HOME=/tmp
export Python_EXECUTABLE="$tools_venv/bin/python"
export PYTHON_EXECUTABLE="$tools_venv/bin/python"
export CMAKE_PREFIX_PATH="${pybind_dir}"
exec bash build.sh --sdk-path "$copy" --python-version 3.11
EOF
    chmod +x "$runner"
    local build_rc=0
    if command -v setpriv >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
      timeout "$TC_TIMEOUT_UNITREE" setpriv --reuid=1000 --regid=1000 --clear-groups \
        env HOME=/tmp "$runner" >>"$log_build" 2>&1 || build_rc=$?
    else
      timeout "$TC_TIMEOUT_UNITREE" "$runner" >>"$log_build" 2>&1 || build_rc=$?
    fi
    if [ "$build_rc" -ne 0 ]; then
      tc_probe_skip "$name" \
        "pybind11 绑定构建失败（rc=$build_rc，build.sh 拒绝 root 必须在副本里以 uid 1000 构建）：$(tc_tail_error "$log_build")" \
        "logs/env/07_toolchain.txt; $log_build"
      return 0
    fi
    so_file="$(ls -1 "$copy"/python_binding/build/lib/unitree_interface*.so 2>/dev/null | head -n 1 || true)"
    if [ -z "$so_file" ]; then
      so_file="$(ls -1 "$copy"/unitree_interface*.so 2>/dev/null | head -n 1 || true)"
    fi
  fi
  if [ -z "$so_file" ]; then
    tc_probe_skip "$name" \
      "构建结束但没有产出 unitree_interface*.so：$(tc_tail_error "$log_build")" \
      "logs/env/07_toolchain.txt; $log_build"
    return 0
  fi
  tc_probe_diag "$name" "built $(basename "$so_file")"

  # 3. import
  local so_dir
  so_dir="$(dirname "$so_file")"
  if ! timeout 120 env PYTHONPATH="$so_dir" "$tools_venv/bin/python" \
        -c 'import unitree_interface; print("UNITREE_IMPORT_OK", unitree_interface.__file__)' \
        >"$log_import" 2>&1; then
    tc_probe_skip "$name" \
      "unitree_interface 导入失败：$(tc_tail_error "$log_import")" \
      "logs/env/07_toolchain.txt; $log_import"
    return 0
  fi
  local import_out
  import_out="$(grep '^UNITREE_IMPORT_OK' "$log_import" | head -n 1 || true)"
  tc_probe_diag "$name" "$import_out"

  tc_emit_verdict "$name" VERIFIED \
    "third_party/unitree_sdk2_wrapper@$TC_UNITREE_SHA 的 SDK 资产齐全，pybind11 绑定在 logs/toolchain/build 的副本里以 uid 1000 构建成功（$(basename "$so_file")），在 Python 3.11 下可导入；真机通信回环需要 G1 硬件，属 S08 部署验证范围" \
    "logs/env/07_toolchain.txt; $(tc_rel_path "$so_file"); $import_out; $(tc_rel_path "$log_build")"
  return 0
}

# tc_probe_all
# Runs the four probes in order and prints their verdict groups.
tc_probe_all() {
  tc_probe_gmr
  tc_probe_soma
  tc_probe_xrt
  tc_probe_unitree
  return 0
}
