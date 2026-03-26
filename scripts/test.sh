#!/usr/bin/env bash
# Run the mcp_server unit test suite inside a Docker container.
#
# When to use:
#   - After any source change to src/mcp_server/ to verify nothing is broken
#   - Before opening a PR or committing a substantial change
#   - In CI (replace this script with a direct docker run if needed)
#
# Why Docker:
#   The host Python is PEP 668 managed (Ubuntu) — pip installs are blocked
#   system-wide and no venv is configured. Running tests in a container gives
#   a clean, reproducible environment that matches what the Dockerfile builds.
#
# Usage:
#   ./scripts/test.sh              # run all tests
#   ./scripts/test.sh -k auth      # pass any pytest args through
#   ./scripts/test.sh -v -x        # verbose, stop on first failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_SRC="$PROJECT_ROOT/src/mcp_server"

PYTEST_ARGS=("${@:--v}")

# Packages required to run the test suite — mirrors requirements.lock.txt
# but only the subset needed by tests (no uvicorn runtime, no grpc exporter build deps).
# If you add a new direct dependency to requirements.txt, add it here too.
PACKAGES=(
  "opentelemetry-api==1.40.0"
  "opentelemetry-sdk==1.40.0"
  "opentelemetry-exporter-otlp-proto-grpc==1.40.0"
  "fastapi==0.135.2"
  "mcp==1.26.0"
  "PyJWT[crypto]==2.12.1"
  "pydantic==2.12.5"
  "uvicorn==0.42.0"
  "httpx==0.28.1"
  "prometheus-client==0.24.1"
  "pytest==9.0.2"
  "pytest-asyncio==1.3.0"
  "anyio==4.13.0"
)

echo "[test] Running mcp_server test suite in Docker (python:3.11.15-slim)..."
echo "[test] pytest args: ${PYTEST_ARGS[*]}"
echo ""

docker run --rm \
  -v "$MCP_SRC:/app" \
  -w /app \
  python:3.11.15-slim \
  bash -c "
    pip install --quiet ${PACKAGES[*]} 2>&1 | grep -v '^Collecting\|^  Downloading\|^  Using\|^Installing' || true
    echo '[test] Dependencies ready.'
    python3 -m pytest tests/ ${PYTEST_ARGS[*]}
  "
