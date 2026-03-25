#!/usr/bin/env bash
# Rebuild one or both service images, load into the kind cluster, and
# perform a rolling restart so pods pick up the new image immediately.
#
# Usage:
#   ./scripts/rebuild.sh              # rebuild both images
#   ./scripts/rebuild.sh mcp          # rebuild MCP server only
#   ./scripts/rebuild.sh worker       # rebuild worker only
#   ./scripts/rebuild.sh mcp worker   # explicit both

set -euo pipefail

if ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="mcp-presidio"
NAMESPACE="mcp-presidio"
MCP_IMAGE="mcp-presidio-sensitivity:0.1.0"
WORKER_IMAGE="presidio-worker:0.1.0"

log()  { echo "[rebuild] $*"; }
fail() { echo "[rebuild] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Determine which targets to build
# ---------------------------------------------------------------------------

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("mcp" "worker")
fi

BUILD_MCP=false
BUILD_WORKER=false
for t in "${TARGETS[@]}"; do
  case "$t" in
    mcp)    BUILD_MCP=true ;;
    worker) BUILD_WORKER=true ;;
    *) fail "Unknown target '$t'. Valid targets: mcp, worker" ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight: cluster must exist
# ---------------------------------------------------------------------------

if ! kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
  fail "Kind cluster '$CLUSTER_NAME' not found — run ./scripts/setup-local.sh first"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if $BUILD_MCP; then
  log "Building $MCP_IMAGE (--no-cache)..."
  docker build --no-cache \
    -t "$MCP_IMAGE" \
    -f "$PROJECT_ROOT/src/mcp_server/Dockerfile" \
    "$PROJECT_ROOT/src/mcp_server/"
  log "$MCP_IMAGE built OK"
fi

if $BUILD_WORKER; then
  log "Building $WORKER_IMAGE (--no-cache)..."
  docker build --no-cache \
    -t "$WORKER_IMAGE" \
    -f "$PROJECT_ROOT/src/worker/Dockerfile" \
    "$PROJECT_ROOT/src/worker/"
  log "$WORKER_IMAGE built OK"
fi

# ---------------------------------------------------------------------------
# Load into kind (parallel where both are being loaded)
# ---------------------------------------------------------------------------

if $BUILD_MCP && $BUILD_WORKER; then
  log "Loading both images into kind cluster (parallel)..."
  kind load docker-image "$MCP_IMAGE"    --name "$CLUSTER_NAME" &
  kind load docker-image "$WORKER_IMAGE" --name "$CLUSTER_NAME" &
  wait
  log "Both images loaded"
elif $BUILD_MCP; then
  log "Loading $MCP_IMAGE into kind cluster..."
  kind load docker-image "$MCP_IMAGE" --name "$CLUSTER_NAME"
  log "$MCP_IMAGE loaded"
elif $BUILD_WORKER; then
  log "Loading $WORKER_IMAGE into kind cluster..."
  kind load docker-image "$WORKER_IMAGE" --name "$CLUSTER_NAME"
  log "$WORKER_IMAGE loaded"
fi

# ---------------------------------------------------------------------------
# Rolling restart and wait
# ---------------------------------------------------------------------------

if $BUILD_MCP; then
  log "Rolling restart: mcp-presidio-sensitivity..."
  kubectl rollout restart deployment/mcp-presidio-sensitivity -n "$NAMESPACE"
fi

if $BUILD_WORKER; then
  log "Rolling restart: presidio-worker..."
  kubectl rollout restart deployment/presidio-worker -n "$NAMESPACE"
fi

if $BUILD_MCP; then
  kubectl rollout status deployment/mcp-presidio-sensitivity -n "$NAMESPACE" --timeout=120s
  log "mcp-presidio-sensitivity rollout complete"
fi

if $BUILD_WORKER; then
  kubectl rollout status deployment/presidio-worker -n "$NAMESPACE" --timeout=120s
  log "presidio-worker rollout complete"
fi

# ---------------------------------------------------------------------------
# Quick health check
# ---------------------------------------------------------------------------

log "Verifying health endpoints..."
sleep 2

if $BUILD_MCP; then
  if curl -sf --max-time 5 http://localhost:8000/health | grep -q '"ok"'; then
    log "  OK  MCP server health"
  else
    fail "MCP server /health did not return ok after rollout"
  fi
fi

if $BUILD_WORKER; then
  if curl -sf --max-time 5 http://localhost:8090/health | grep -q '"ok"'; then
    log "  OK  Worker health"
  else
    fail "Worker /health did not return ok after rollout"
  fi
fi

log ""
log "Rebuild complete. Run ./scripts/status.sh to verify the full stack."
