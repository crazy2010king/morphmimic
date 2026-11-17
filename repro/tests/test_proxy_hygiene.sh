#!/usr/bin/env bash
# repro/tests/test_proxy_hygiene.sh — unit tests for the proxy-trace detector.
#
# Pure local, no network, no GPU, no container: the detector
# (repro/lib/proxy_hygiene.sh) is fed inline fixtures in a temporary directory.
# Prints TESTS_OK when every assertion passes.

set -euo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/proxy_hygiene.sh
source "$_TEST_DIR/../lib/proxy_hygiene.sh"

failures=0
checks=0

check() {  # check <description> <condition-result> [detail]
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 ${3:-}"
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_proxy_hygiene.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- fixtures ---------------------------------------------------------------
cat > "$WORK/clean.env" <<'EOF'
PATH=/usr/local/bin:/usr/bin:/bin
LANG=C.UTF-8
EOF

cat > "$WORK/active_ours.env" <<'EOF'
http_proxy=http://172.16.119.20:40381
EOF

cat > "$WORK/active_generic.env" <<'EOF'
NO_PROXY = example.com
EOF

cat > "$WORK/active_lowercase.env" <<'EOF'
no_proxy=localhost
EOF

cat > "$WORK/active_colon.env" <<'EOF'
export https_proxy:http://proxy.example.invalid:3128
EOF

cat > "$WORK/apt_style.env" <<'EOF'
Acquire::http::Proxy "http://proxy.example.invalid:3128";
EOF

cat > "$WORK/commented.env" <<'EOF'
#http_proxy = http://proxy.example.invalid:3128/
EOF

cat > "$WORK/semicolon_comment.env" <<'EOF'
; ftp_proxy = http://proxy.example.invalid:3128/
EOF

cat > "$WORK/address_in_comment.env" <<'EOF'
# once used 172.16.119.20:40381
EOF

cat > "$WORK/indented_comment.env" <<'EOF'
   # https_proxy = http://proxy.example.invalid:3128/
EOF

mkdir -p "$WORK/dir"
cp "$WORK/clean.env" "$WORK/dir/ok.conf"
cp "$WORK/active_ours.env" "$WORK/dir/bad.conf"

# --- assertions -------------------------------------------------------------
rc=0; out="$(proxy_hygiene_scan_file "$WORK/clean.env")" || rc=$?
check "a clean file is classified clean" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc out=$out"
check "a clean file produces no findings" "$([ -z "$out" ] && echo 0 || echo 1)" "out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/active_ours.env")" || rc=$?
check "an active setting with our proxy address is polluted" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"
check "the address finding is reported as ADDR" "$(printf '%s' "$out" | grep -q '^ADDR ' && echo 0 || echo 1)" "out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/active_generic.env")" || rc=$?
check "an active NO_PROXY setting is polluted" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"
check "the generic finding is reported as HIT" "$(printf '%s' "$out" | grep -q '^HIT ' && echo 0 || echo 1)" "out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/active_lowercase.env")" || rc=$?
check "a lowercase no_proxy setting is polluted" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/active_colon.env")" || rc=$?
check "a colon-separated setting is polluted" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/apt_style.env")" || rc=$?
check "an apt-style Proxy key is polluted" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/commented.env")" || rc=$?
check "a commented-out setting is inert" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc out=$out"
check "a commented-out setting is still reported" "$(printf '%s' "$out" | grep -q '^COMMENT ' && echo 0 || echo 1)" "out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/semicolon_comment.env")" || rc=$?
check "a semicolon-comment is inert" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/indented_comment.env")" || rc=$?
check "an indented comment is inert" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/address_in_comment.env")" || rc=$?
check "our proxy address inside a comment is polluted" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"
check "the address-in-comment finding is reported as ADDR" "$(printf '%s' "$out" | grep -q '^ADDR ' && echo 0 || echo 1)" "out=$out"

rc=0; out="$(proxy_hygiene_scan_file "$WORK/does_not_exist.env")" || rc=$?
check "a missing file is clean" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc"

rc=0; out="$(proxy_hygiene_scan_path "$WORK/dir")" || rc=$?
check "a directory scan reports the polluted member" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"
check "the directory scan names the offending file" "$(printf '%s' "$out" | grep -q 'bad.conf' && echo 0 || echo 1)" "out=$out"

# strict mode: commented-out settings count as pollution
PROXY_HYGIENE_STRICT=1
rc=0; out="$(proxy_hygiene_scan_file "$WORK/commented.env")" || rc=$?
check "strict mode treats a commented-out setting as pollution" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "rc=$rc out=$out"
PROXY_HYGIENE_STRICT=0

# the target list must not be empty and must contain the core files
targets="$(proxy_hygiene_targets)"
check "the target list is not empty" "$([ -n "$targets" ] && echo 0 || echo 1)"
check "the target list contains /etc/environment" "$(printf '%s' "$targets" | grep -qx '/etc/environment' && echo 0 || echo 1)"
check "the target list contains /etc/profile.d" "$(printf '%s' "$targets" | grep -qx '/etc/profile.d' && echo 0 || echo 1)"
check "the target list contains the uv config" "$(printf '%s' "$targets" | grep -qx '/root/.config/uv/uv.toml' && echo 0 || echo 1)"

echo "checks=$checks failures=$failures"
if [ "$failures" -ne 0 ]; then
  echo "TESTS_FAILED"
  exit 1
fi
echo "TESTS_OK"
