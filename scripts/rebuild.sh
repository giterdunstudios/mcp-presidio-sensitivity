#!/usr/bin/env bash
# Rebuild one or both service images, push to the local k3d registry, and
# perform a rolling restart so pods pick up the new image immediately.
#
# When to use:
#   - After any Python source change to src/mcp_server/ or src/worker/
#   - After any Dockerfile change
#   - After any Helm chart change (values.yaml, templates/) — helm upgrade
#     runs automatically so config changes reach the cluster
#   - When a pod is running stale code (imageID in kubectl describe doesn't
#     match the locally built sha256)
#   - After merging a branch that changes application code or chart config
#   Always use this instead of manual docker build + docker push to registry +
#   rollout commands — it ensures --no-cache, correct image tags, helm config
#   sync, and waits for rollout completion before returning.
#
# Usage:
#   ./scripts/rebuild.sh              # rebuild both images (most common)
#   ./scripts/rebuild.sh mcp          # MCP server only — src/mcp_server/ changed
#   ./scripts/rebuild.sh worker       # worker only — src/worker/ changed
#   ./scripts/rebuild.sh mcp worker   # explicit both
#
# Prerequisites:
#   - k3d cluster and registry running (./scripts/setup-local.sh completed)
#   - Docker available

set -euo pipefail

# Prerequisites check
for cmd in docker k3d kubectl helm; do
  command -v "$cmd" &>/dev/null || { echo "[rebuild] ERROR: '$cmd' not found — run setup-local.sh first" >&2; exit 1; }
done

if ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="mcp-presidio"
NAMESPACE="mcp-presidio"
REGISTRY="k3d-mcp-registry:5000"
MCP_IMAGE="mcp-presidio-sensitivity:0.1.0"
WORKER_IMAGE="presidio-worker:0.1.0"
MCP_IMAGE_REMOTE="$REGISTRY/mcp-presidio-sensitivity:0.1.0"
WORKER_IMAGE_REMOTE="$REGISTRY/presidio-worker:0.1.0"

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

if ! k3d cluster list 2>/dev/null | grep -q "^$CLUSTER_NAME"; then
  fail "k3d cluster '$CLUSTER_NAME' not found — run ./scripts/setup-local.sh first"
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
# Push to registry (parallel where both are being pushed)
# ---------------------------------------------------------------------------

if $BUILD_MCP && $BUILD_WORKER; then
  log "Pushing both images to registry (parallel)..."
  docker tag "$MCP_IMAGE" "$MCP_IMAGE_REMOTE"
  docker tag "$WORKER_IMAGE" "$WORKER_IMAGE_REMOTE"
  docker push "$MCP_IMAGE_REMOTE" &
  docker push "$WORKER_IMAGE_REMOTE" &
  wait
  log "Both images pushed"
elif $BUILD_MCP; then
  log "Pushing $MCP_IMAGE to registry..."
  docker tag "$MCP_IMAGE" "$MCP_IMAGE_REMOTE"
  docker push "$MCP_IMAGE_REMOTE"
  log "$MCP_IMAGE pushed"
elif $BUILD_WORKER; then
  log "Pushing $WORKER_IMAGE to registry..."
  docker tag "$WORKER_IMAGE" "$WORKER_IMAGE_REMOTE"
  docker push "$WORKER_IMAGE_REMOTE"
  log "$WORKER_IMAGE pushed"
fi

# ---------------------------------------------------------------------------
# Helm upgrade — apply config changes (values.yaml, templates) alongside
# the new image. Runs before the rolling restart so the pod spec is current
# when the restart fires. The image tag is static (0.1.0) so helm upgrade
# alone does not trigger a rollout; kubectl rollout restart handles that.
# ---------------------------------------------------------------------------

if $BUILD_MCP; then
  log "Helm upgrade: mcp-presidio-sensitivity..."
  helm upgrade --install mcp-presidio-sensitivity "$PROJECT_ROOT/helm/mcp-server" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.yaml" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.local.yaml" \
    --namespace "$NAMESPACE" \
    --timeout 120s
fi

if $BUILD_WORKER; then
  log "Helm upgrade: presidio-worker..."
  helm upgrade --install presidio-worker "$PROJECT_ROOT/helm/presidio-worker" \
    -f "$PROJECT_ROOT/helm/presidio-worker/values.yaml" \
    -f "$PROJECT_ROOT/helm/presidio-worker/values.local.yaml" \
    --namespace "$NAMESPACE" \
    --timeout 180s
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
