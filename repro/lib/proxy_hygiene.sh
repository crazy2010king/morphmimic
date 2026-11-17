#!/usr/bin/env bash
# repro/lib/proxy_hygiene.sh — reusable, side-effect-free proxy-trace detector.
#
# The rule set is shared by:
#   * repro/05_proxy_hygiene.sh  — scans the real system configuration files
#   * repro/tests/test_proxy_hygiene.sh — unit tests over inline fixtures
#
# A line is a POLLUTION finding when either
#   (A) it contains our proxy address (172.16.119.20) — anywhere, even inside a
#       comment: that address must never be mentioned in a system config file;
#   (B) it is an ACTIVE (non-comment) proxy setting, i.e. it matches
#       `(?i)(http|https|ftp|no|all)_proxy\s*[:=]` or a bare `proxy\s*[:=]`
#       or a bare `proxy` key (apt style `Acquire::http::Proxy`).
#
# A COMMENTED-OUT proxy setting (a line whose first non-blank character is `#`
# or `;`) is reported as COMMENT — it is inert.  Stock distribution files such
# as /etc/wgetrc ship exactly such examples; they are NOT our proxy and must
# not fail the hygiene gate.  Set PROXY_HYGIENE_STRICT=1 to also treat
# commented-out settings as pollution.
#
# The functions only read files; they never write anything.

PROXY_HYGIENE_ADDR="${PROXY_HYGIENE_ADDR:-172.16.119.20}"
PROXY_HYGIENE_STRICT="${PROXY_HYGIENE_STRICT:-0}"

# active proxy setting patterns
PROXY_HYGIENE_SETTING_RE='(http|https|ftp|no|all)_proxy[[:space:]]*[:=]|proxy[[:space:]]*[:=]|proxy[[:space:]]*::[[:space:]]*|proxy[[:space:]]+["'"'"']https?://|proxy[[:space:]]*$'
# the combined grep pattern (address is a fixed string, the rest is a regex)
PROXY_HYGIENE_ANY_RE="$PROXY_HYGIENE_SETTING_RE|$(printf '%s' "$PROXY_HYGIENE_ADDR" | sed 's/\./\\./g')"

# proxy_hygiene_scan_file <file>
# Prints the findings (ADDR / HIT / COMMENT), one per line.
# Return code: 0 = clean, 1 = polluted.
proxy_hygiene_scan_file() {
  local f="$1" rc=0 line n content stripped kind
  [ -f "$f" ] || return 0
  [ -r "$f" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%:*}"
    content="${line#*:}"
    # strip the leading blanks of the content to classify comment vs. active
    stripped="${content#"${content%%[![:space:]]*}"}"
    case "$stripped" in
      '#'*|';'*) kind="COMMENT" ;;
      *)         kind="HIT" ;;
    esac
    if printf '%s' "$content" | grep -qiF -- "$PROXY_HYGIENE_ADDR"; then
      printf 'ADDR %s:%s:%s\n' "$f" "$n" "$content"
      rc=1
      continue
    fi
    if printf '%s' "$content" | grep -qiE -- "$PROXY_HYGIENE_SETTING_RE"; then
      if [ "$kind" = "COMMENT" ] && [ "$PROXY_HYGIENE_STRICT" != "1" ]; then
        printf 'COMMENT %s:%s:%s\n' "$f" "$n" "$content"
      else
        printf 'HIT %s:%s:%s\n' "$f" "$n" "$content"
        rc=1
      fi
    fi
  done < <(grep -niE -- "$PROXY_HYGIENE_ANY_RE" "$f" 2>/dev/null || true)
  return $rc
}

# proxy_hygiene_scan_path <path>
# Scans a file, or every regular file directly inside a directory.
# Return code: 0 = clean, 1 = polluted.
proxy_hygiene_scan_path() {
  local p="$1" rc=0 f
  if [ -d "$p" ]; then
    for f in "$p"/*; do
      [ -f "$f" ] || continue
      proxy_hygiene_scan_file "$f" || rc=1
    done
    return $rc
  fi
  [ -f "$p" ] || return 0
  proxy_hygiene_scan_file "$p" || rc=1
  return $rc
}

# proxy_hygiene_targets — the system configuration files/directories that are
# inspected.  Missing paths are simply skipped (absent == clean).
# PROXY_HYGIENE_TARGETS_FILE (a file with one path per line) overrides the
# default list; it exists so that the failure path of the whole script can be
# exercised against a temporary fixture without touching any system file.
proxy_hygiene_targets() {
  if [ -n "${PROXY_HYGIENE_TARGETS_FILE:-}" ] && [ -f "$PROXY_HYGIENE_TARGETS_FILE" ]; then
    grep -v '^[[:space:]]*$' "$PROXY_HYGIENE_TARGETS_FILE" | grep -v '^[[:space:]]*#' || true
    return 0
  fi
  cat <<'EOF'
/etc/environment
/etc/environment.d
/etc/profile
/etc/profile.d
/etc/bash.bashrc
/etc/zsh/zshrc
/root/.bashrc
/root/.profile
/root/.zshrc
/root/.curlrc
/root/.wgetrc
/root/.config/uv/uv.toml
/root/.config/pip/pip.conf
/etc/pip.conf
/root/.gitconfig
/etc/gitconfig
/etc/apt/apt.conf.d
/etc/apt/apt.conf
/etc/wgetrc
EOF
}
