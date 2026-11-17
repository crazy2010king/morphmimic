#!/usr/bin/env bash
# repro/tests/test_smoke.sh — the negative/edge-case tests of the smoke clip
# builder (repro/lib/make_smoke_clip.py) and of the reader it must satisfy.
#
# The tests need a CPU only (MuJoCo forward kinematics): no GPU, no network and
# no simulation. They run inside the ros_dev container, where the project venv
# lives:
#
#   Run remotely: bash repro/lib/remote.sh tests/test_smoke.sh
#   Run locally:  bash repro/tests/test_smoke.sh   (needs a usable .venv)
#
# Exit code 0 == all tests passed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# The interpreter: uv inside the container (the project's own runner), the
# project venv when it is usable directly.
if command -v uv >/dev/null 2>&1; then
  PY=(uv run --frozen --no-sync python)
elif [ -x "$REPO_ROOT/.venv/bin/python" ]; then
  PY=("$REPO_ROOT/.venv/bin/python")
else
  echo "no usable interpreter: uv is missing and $REPO_ROOT/.venv/bin/python does not run here" >&2
  echo "run this test in the container: bash repro/lib/remote.sh tests/test_smoke.sh" >&2
  exit 3
fi

cd "$REPO_ROOT"
"${PY[@]}" repro/tests/test_smoke.py
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL  the smoke tests failed (rc=$rc)" >&2
  exit "$rc"
fi
echo "TESTS_OK"
