#!/usr/bin/env bash
# repro/tests/test_seed_download_e2e.sh — offline end-to-end test of the
# BONES-SEED downloader (repro/08_seed_download_worker.sh) against a LOCAL
# fixture HTTP server.
#
# No proxy, no HuggingFace, no internet: a stdlib http.server fixture serves
# the bytes and implements the two behaviours the real CDN has:
#   * HTTP Range requests (curl -C - needs "206 + Content-Range")
#   * a truncated response (the connection dies mid-body) -> the client sees a
#     broken transfer and has to resume
#
# Covered:
#   1. RESUME      a cut transfer is retried, the second attempt resumes at
#                  the byte offset of the first one and the final file is
#                  byte-identical to the fixture (SEED_DL_FILE_OK)
#   2. AUTH       a request without the token gets 401 -> SEED_DL_AUTH_FAIL
#                  and a non-zero exit, and no OK marker is printed
#   3. SIZE       a fixture whose byte count differs from the plan ->
#                  SEED_DL_SIZE_MISMATCH and a non-zero exit
#   4. SHA256     a fixture whose hash differs from the plan ->
#                  SEED_DL_SHA256_MISMATCH and a non-zero exit
#   5. STATUS     the status file is readable WHILE the transfer runs and
#                  carries STATE / BYTES / TOTAL / PCT
#   6. SECRECY    the token never appears in any log
#
# Run locally:  bash repro/tests/test_seed_download_e2e.sh
# Run remotely: bash repro/lib/remote.sh tests/test_seed_download_e2e.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
WORKER="$REPO_ROOT/repro/08_seed_download_worker.sh"

PASS=0
FAIL=0
ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
SERVER_PIDS=()
cleanup() {
  local p
  for p in "${SERVER_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ ! -f "$WORKER" ]; then
  echo "ERROR: worker not found: $WORKER" >&2
  exit 1
fi

SECRET="fixture-secret-token"

# ---------------------------------------------------------------------------
# The fixture server (stdlib only).
# ---------------------------------------------------------------------------
cat >"$TMP/server.py" <<'PYEOF'
#!/usr/bin/env python3
"""Local fixture HTTP server for the BONES-SEED downloader e2e test.

  * every request must carry `Authorization: Bearer <secret>` (401 otherwise)
  * HTTP Range requests are supported (206 + Content-Range)
  * --cut-first: the first plain GET of a file is truncated after half of
    its body and the connection is closed (a broken transfer)
  * --throttle N: serve at most N bytes per second
  * the bound port is written to --portfile
"""
import argparse
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.root = ""
        self.secret = ""
        self.cut_first = False
        self.throttle = 0
        self.lock = threading.Lock()
        self.cut = set()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[fixture] " + (fmt % args) + "\n")

    def _authorized(self):
        want = "Bearer " + self.server.secret if self.server.secret else None
        if want is None:
            return True
        return self.headers.get("Authorization", "").strip() == want

    def _resolve(self):
        rel = self.path.split("?")[0].lstrip("/")
        if not rel:
            return None
        full = os.path.join(self.server.root, rel)
        if not os.path.isfile(full):
            return None
        return full

    def do_HEAD(self):
        if not self._authorized():
            self.send_error(401, "unauthorized")
            return
        full = self._resolve()
        if full is None:
            self.send_error(404, "not found")
            return
        size = os.path.getsize(full)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(size))
        self.end_headers()

    def do_GET(self):
        if not self._authorized():
            self.send_error(401, "unauthorized")
            return
        full = self._resolve()
        if full is None:
            self.send_error(404, "not found")
            return
        size = os.path.getsize(full)
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        partial = False
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
            if m:
                partial = True
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = int(m.group(2))
                else:
                    end = size - 1
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if end >= size:
                    end = size - 1
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Content-Length", str(length))
        self.end_headers()

        cut = False
        if not partial and self.server.cut_first:
            with self.server.lock:
                if full not in self.server.cut:
                    self.server.cut.add(full)
                    cut = True
        remaining = length // 2 if cut else length
        throttle = self.server.throttle
        with open(full, "rb") as fh:
            fh.seek(start)
            while remaining > 0:
                data = fh.read(min(65536, remaining))
                if not data:
                    break
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(data)
                if throttle:
                    time.sleep(len(data) / float(throttle))
        if cut:
            # The declared Content-Length is bigger than what was sent: the
            # client must detect the short read and resume later.
            self.close_connection = True
            try:
                self.connection.close()
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--portfile", required=True)
    ap.add_argument("--secret", default="")
    ap.add_argument("--cut-first", action="store_true")
    ap.add_argument("--throttle", type=int, default=0)
    args = ap.parse_args()

    srv = Server(("127.0.0.1", 0), Handler)
    srv.root = os.path.abspath(args.root)
    srv.secret = args.secret
    srv.cut_first = args.cut_first
    srv.throttle = args.throttle
    with open(args.portfile, "w") as fh:
        fh.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

# start_server <name> [extra args...] -> echoes the port
start_server() {
  local name="$1"; shift
  local portfile="$TMP/$name.port"
  rm -f "$portfile"
  python3 "$TMP/server.py" --root "$TMP/www" --portfile "$portfile" \
          --secret "$SECRET" "$@" >"$TMP/$name.server.log" 2>&1 &
  SERVER_PIDS+=("$!")
  local i=0
  while [ ! -s "$portfile" ]; do
    sleep 0.2
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      echo "ERROR: fixture server '$name' did not start" >&2
      return 1
    fi
  done
  cat "$portfile"
}

# --- fixtures ---------------------------------------------------------------
mkdir -p "$TMP/www" "$TMP/root"
python3 - "$TMP/www/fixture.bin" <<'PYEOF'
import sys
# deterministic, incompressible enough content
data = bytes((i * 37 + (i >> 8) * 11) % 256 for i in range(262144))
open(sys.argv[1], "wb").write(data)
PYEOF
FIXTURE_SIZE=$(stat -c %s "$TMP/www/fixture.bin")
FIXTURE_SHA=$(sha256sum "$TMP/www/fixture.bin" | awk '{print $1}')

write_table() {
  local file="$1" size="$2" sha="$3" url="$4" dest="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' "fixture.bin" "$size" "$sha" "$url" "$dest" >"$file"
}

# run_worker <table> <outlog> [extra env assignments...]
run_worker() {
  local table="$1" outlog="$2"; shift 2
  env SEED_FILE_TABLE="$table" \
      SEED_DEST_ROOT="$TMP/root" \
      SEED_STATUS_FILE="$TMP/status" \
      SEED_MAIN_LOG="$TMP/main.log" \
      SEED_SHA256SUMS="$TMP/SHA256SUMS" \
      SEED_BACKOFF_SCALE=0 \
      SEED_PROGRESS_INTERVAL=1 \
      SEED_MAX_ATTEMPTS=5 \
      SEED_TOKEN="$SECRET" \
      "$@" \
      bash "$WORKER" >"$outlog" 2>&1
  echo $?
}

# ===========================================================================
# 1) resume after a cut transfer
# ===========================================================================
PORT="$(start_server cut --cut-first)"
if [ -z "$PORT" ]; then
  bad "could not start the fixture server"
else
  URL="http://127.0.0.1:$PORT/fixture.bin"
  TABLE="$TMP/table_ok.tsv"
  write_table "$TABLE" "$FIXTURE_SIZE" "$FIXTURE_SHA" "$URL" "blobs/fixture.bin"
  rm -f "$TMP/root/blobs/fixture.bin" "$TMP/root/blobs/fixture.bin.part"
  RC="$(run_worker "$TABLE" "$TMP/out_resume.log")"
  OUT="$(cat "$TMP/out_resume.log")"

  if [ "$RC" = "0" ]; then
    ok "the worker completed the (cut) transfer and exited 0"
  else
    bad "the worker exited $RC (expected 0)"
    printf '%s\n' "$OUT" | tail -20
  fi

  if printf '%s' "$OUT" | grep -qF "SEED_DL_FILE_OK"; then
    ok "the resumed transfer printed SEED_DL_FILE_OK"
  else
    bad "SEED_DL_FILE_OK is missing from the worker output"
    printf '%s\n' "$OUT" | tail -20
  fi

  RESUME_OFFSET="$(printf '%s' "$OUT" | sed -n 's/.*SEED_DL_RESUME file=fixture.bin offset=\([0-9]*\).*/\1/p' | head -n1)"
  if [ -n "$RESUME_OFFSET" ] && [ "$RESUME_OFFSET" -gt 0 ]; then
    ok "the second attempt resumed at offset=$RESUME_OFFSET (> 0)"
  else
    bad "no SEED_DL_RESUME marker with a positive offset (got '$RESUME_OFFSET')"
    printf '%s\n' "$OUT" | tail -20
  fi

  if printf '%s' "$OUT" | grep -qF "SEED_DL_TRANSFER_FAIL"; then
    ok "the cut transfer was reported as a failed attempt and retried"
  else
    bad "the cut transfer was not reported as a failure"
  fi

  if [ -f "$TMP/root/blobs/fixture.bin" ]; then
    GOT_SIZE=$(stat -c %s "$TMP/root/blobs/fixture.bin")
    GOT_SHA=$(sha256sum "$TMP/root/blobs/fixture.bin" | awk '{print $1}')
    if [ "$GOT_SIZE" = "$FIXTURE_SIZE" ] && [ "$GOT_SHA" = "$FIXTURE_SHA" ]; then
      ok "the resumed file is byte-identical to the fixture (size+sha256)"
    else
      bad "the resumed file differs from the fixture (size=$GOT_SIZE sha=$GOT_SHA)"
    fi
  else
    bad "the resumed file was not published"
  fi

  if [ ! -f "$TMP/root/blobs/fixture.bin.part" ]; then
    ok "the .part file was renamed into place (no leftover .part)"
  else
    bad "the .part file is still there after a successful transfer"
  fi

  if [ -f "$TMP/root/blobs/fixture.bin.sha256" ]; then
    ok "the sha256 sidecar was written"
  else
    bad "the sha256 sidecar is missing"
  fi

  if [ -f "$TMP/SHA256SUMS" ]; then
    ok "SHA256SUMS was written"
  else
    bad "SHA256SUMS is missing"
  fi
fi

# ===========================================================================
# 2) authentication failure (no token -> 401)
# ===========================================================================
PORT2="$(start_server auth)"
if [ -z "$PORT2" ]; then
  bad "could not start the fixture server (auth case)"
else
  URL2="http://127.0.0.1:$PORT2/fixture.bin"
  TABLE2="$TMP/table_auth.tsv"
  write_table "$TABLE2" "$FIXTURE_SIZE" "$FIXTURE_SHA" "$URL2" "blobs/auth.bin"
  RC="$(run_worker "$TABLE2" "$TMP/out_auth.log" HF_TOKEN= HF_TOKEN_PATH="$TMP/no_such_token" SEED_TOKEN=)"
  OUT="$(cat "$TMP/out_auth.log")"

  if [ "$RC" != "0" ]; then
    ok "an unauthenticated request exits non-zero (rc=$RC)"
  else
    bad "an unauthenticated request exited 0"
  fi
  if printf '%s' "$OUT" | grep -qF "SEED_DL_AUTH_FAIL"; then
    ok "the 401 produced the SEED_DL_AUTH_FAIL marker"
  else
    bad "SEED_DL_AUTH_FAIL is missing"
    printf '%s\n' "$OUT" | tail -20
  fi
  if printf '%s' "$OUT" | grep -qE "SEED_DL_FILE_OK|SEED_DOWNLOAD_OK"; then
    bad "the failing path printed an OK marker"
  else
    ok "the failing path printed no OK marker"
  fi
fi

# ===========================================================================
# 3) size mismatch
# ===========================================================================
PORT3="$(start_server size)"
if [ -z "$PORT3" ]; then
  bad "could not start the fixture server (size case)"
else
  URL3="http://127.0.0.1:$PORT3/fixture.bin"
  TABLE3="$TMP/table_size.tsv"
  write_table "$TABLE3" "$((FIXTURE_SIZE + 1))" "$FIXTURE_SHA" "$URL3" "blobs/size.bin"
  RC="$(run_worker "$TABLE3" "$TMP/out_size.log")"
  OUT="$(cat "$TMP/out_size.log")"

  if [ "$RC" != "0" ]; then
    ok "a byte count that differs from the plan exits non-zero (rc=$RC)"
  else
    bad "a byte count mismatch exited 0"
  fi
  if printf '%s' "$OUT" | grep -qF "SEED_DL_SIZE_MISMATCH"; then
    ok "the size mismatch produced the SEED_DL_SIZE_MISMATCH marker"
  else
    bad "SEED_DL_SIZE_MISMATCH is missing"
    printf '%s\n' "$OUT" | tail -20
  fi
  if printf '%s' "$OUT" | grep -qE "SEED_DL_FILE_OK|SEED_DOWNLOAD_OK"; then
    bad "the size-mismatch path printed an OK marker"
  else
    ok "the size-mismatch path printed no OK marker"
  fi
fi

# ===========================================================================
# 4) sha256 mismatch
# ===========================================================================
PORT4="$(start_server sha)"
if [ -z "$PORT4" ]; then
  bad "could not start the fixture server (sha case)"
else
  URL4="http://127.0.0.1:$PORT4/fixture.bin"
  TABLE4="$TMP/table_sha.tsv"
  write_table "$TABLE4" "$FIXTURE_SIZE" \
      "0000000000000000000000000000000000000000000000000000000000000000" \
      "$URL4" "blobs/sha.bin"
  RC="$(run_worker "$TABLE4" "$TMP/out_sha.log")"
  OUT="$(cat "$TMP/out_sha.log")"

  if [ "$RC" != "0" ]; then
    ok "a hash that differs from the plan exits non-zero (rc=$RC)"
  else
    bad "a sha256 mismatch exited 0"
  fi
  if printf '%s' "$OUT" | grep -qF "SEED_DL_SHA256_MISMATCH"; then
    ok "the hash mismatch produced the SEED_DL_SHA256_MISMATCH marker"
  else
    bad "SEED_DL_SHA256_MISMATCH is missing"
    printf '%s\n' "$OUT" | tail -20
  fi
  if printf '%s' "$OUT" | grep -qE "SEED_DL_FILE_OK|SEED_DOWNLOAD_OK"; then
    bad "the sha-mismatch path printed an OK marker"
  else
    ok "the sha-mismatch path printed no OK marker"
  fi
  if [ -f "$TMP/root/blobs/sha.bin.part" ]; then
    ok "the .part file was kept after the hash mismatch (never deleted)"
  else
    bad "the .part file was deleted after the hash mismatch"
  fi
fi

# ===========================================================================
# 5) the status file is readable while the transfer runs
# ===========================================================================
PORT5="$(start_server slow --throttle 40000)"
if [ -z "$PORT5" ]; then
  bad "could not start the fixture server (status case)"
else
  URL5="http://127.0.0.1:$PORT5/fixture.bin"
  TABLE5="$TMP/table_status.tsv"
  write_table "$TABLE5" "$FIXTURE_SIZE" "$FIXTURE_SHA" "$URL5" "blobs/status.bin"
  rm -f "$TMP/status"
  run_worker "$TABLE5" "$TMP/out_status.log" >/dev/null 2>&1 &
  WPID=$!
  SEEN=""
  i=0
  while [ "$i" -lt 200 ]; do
    if [ -f "$TMP/status" ]; then
      SEEN="$(cat "$TMP/status")"
      SBYTES="$(printf '%s' "$SEEN" | sed -n 's/^BYTES=//p' | head -n1)"
      case "$SBYTES" in
        ''|*[!0-9]*) : ;;
        *) [ "$SBYTES" -gt 0 ] && break ;;
      esac
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$WPID" 2>/dev/null

  if printf '%s' "$SEEN" | grep -q "^STATE=" \
     && printf '%s' "$SEEN" | grep -q "^BYTES=" \
     && printf '%s' "$SEEN" | grep -q "^TOTAL=" \
     && printf '%s' "$SEEN" | grep -q "^PCT="; then
    ok "the status file exposes STATE / BYTES / TOTAL / PCT during the transfer"
  else
    bad "the status file did not expose the expected keys"
    printf '%s\n' "$SEEN"
  fi
  SBYTES="$(printf '%s' "$SEEN" | sed -n 's/^BYTES=//p' | head -n1)"
  if [ -n "$SBYTES" ] && [ "$SBYTES" -gt 0 ]; then
    ok "the status file reported progress ($SBYTES bytes)"
  else
    bad "the status file reported no progress (BYTES=$SBYTES)"
  fi
  if grep -qF "SEED_DL_PROGRESS" "$TMP/main.log" 2>/dev/null; then
    ok "the SEED_DL_PROGRESS marker was written to the log"
  else
    bad "the SEED_DL_PROGRESS marker is missing from the log"
  fi
fi

# ===========================================================================
# 6) the token never reaches a log
# ===========================================================================
if grep -qF "$SECRET" "$TMP/main.log" "$TMP"/out_*.log 2>/dev/null; then
  bad "the token leaked into a log file"
else
  ok "the token never appears in any log file"
fi

# --- summary ----------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "SEED_DOWNLOAD_E2E_FAILED"
  exit 1
fi
echo "SEED_DOWNLOAD_E2E_OK"
exit 0
