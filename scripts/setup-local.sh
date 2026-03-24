#!/usr/bin/env bash
# Bootstrap the local mcp-presidio development stack.
#
# What this does:
#   1. Creates the kind cluster with host port mappings
#   2. Creates the mcp-presidio namespace
#   3. Deploys Hydra via Helm and patches its NodePort services
#   4. Loads the presidio-worker image and deploys it via Helm
#   5. Waits for all pods to be ready
#   6. Registers the test OAuth client in Hydra
#   7. Runs a smoke test against each endpoint
#
# Prerequisites:
#   - kind, kubectl, helm, docker (with docker group access)
#   - ory/hydra Helm repo added:  helm repo add ory https://k8s.ory.sh/helm/charts
#   - presidio-worker image built: docker build -t presidio-worker:0.1.0 src/worker/
#
# Usage:
#   ./scripts/setup-local.sh            # full setup
#   ./scripts/setup-local.sh --skip-build  # skip image build (use existing image)
#   ./scripts/setup-local.sh --teardown # delete the cluster and exit

set -euo pipefail

# Re-exec with docker group applied if not already in it.
# Required on WSL2 where 'newgrp docker' only applies to interactive shells.
if ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="mcp-presidio"
NAMESPACE="mcp-presidio"
WORKER_IMAGE="presidio-worker:0.1.0"
MCP_SERVER_IMAGE="mcp-server:0.1.0"

SKIP_BUILD=false
TEARDOWN=false

for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
    --teardown)   TEARDOWN=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[setup] $*"; }
fail() { echo "[setup] ERROR: $*" >&2; exit 1; }

wait_for_pods() {
  local label="$1"
  local timeout="${2:-120s}"
  log "Waiting for pods ($label) to be ready (timeout: $timeout)..."
  kubectl rollout status deployment -l "$label" -n "$NAMESPACE" --timeout="$timeout"
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

if $TEARDOWN; then
  log "Tearing down cluster $CLUSTER_NAME..."
  kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  log "Done."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Build images (unless skipped)
# ---------------------------------------------------------------------------

if $SKIP_BUILD; then
  log "Skipping image builds (--skip-build passed)"
else
  log "Building $WORKER_IMAGE..."
  docker build -t "$WORKER_IMAGE" "$PROJECT_ROOT/src/worker/"

  if [[ -d "$PROJECT_ROOT/src/mcp_server" ]]; then
    log "Building $MCP_SERVER_IMAGE..."
    docker build -t "$MCP_SERVER_IMAGE" "$PROJECT_ROOT/src/mcp_server/"
  else
    log "Skipping $MCP_SERVER_IMAGE build — src/mcp_server/ not yet present (Lane D pending)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Create kind cluster
# ---------------------------------------------------------------------------

if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
  log "Cluster $CLUSTER_NAME already exists — skipping creation"
else
  log "Creating kind cluster $CLUSTER_NAME..."
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$PROJECT_ROOT/infrastructure/kind-config.yaml"
fi

kubectl config use-context "kind-$CLUSTER_NAME"

# ---------------------------------------------------------------------------
# 3. Namespace
# ---------------------------------------------------------------------------

kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
log "Namespace $NAMESPACE ready"

# ---------------------------------------------------------------------------
# 4. Deploy Hydra
# ---------------------------------------------------------------------------

log "Deploying Hydra..."
helm upgrade --install hydra ory/hydra \
  -f "$PROJECT_ROOT/helm/hydra-values.local.yaml" \
  --namespace "$NAMESPACE" \
  --wait --timeout 120s

log "Patching Hydra NodePort services..."
kubectl patch svc hydra-public -n "$NAMESPACE" \
  -p '{"spec":{"ports":[{"port":4444,"targetPort":4444,"nodePort":30444}]}}'
kubectl patch svc hydra-admin -n "$NAMESPACE" \
  -p '{"spec":{"ports":[{"port":4445,"targetPort":4445,"nodePort":30445}]}}'

# ---------------------------------------------------------------------------
# 5. Load and deploy presidio-worker
# ---------------------------------------------------------------------------

log "Loading $WORKER_IMAGE into kind cluster..."
kind load docker-image "$WORKER_IMAGE" --name "$CLUSTER_NAME"

log "Deploying presidio-worker..."
helm upgrade --install presidio-worker "$PROJECT_ROOT/helm/presidio-worker" \
  -f "$PROJECT_ROOT/helm/presidio-worker/values.yaml" \
  -f "$PROJECT_ROOT/helm/presidio-worker/values.local.yaml" \
  --namespace "$NAMESPACE" \
  --wait --timeout 180s

# ---------------------------------------------------------------------------
# 6. Load and deploy mcp-server (if built)
# ---------------------------------------------------------------------------

if docker image inspect "$MCP_SERVER_IMAGE" &>/dev/null; then
  log "Loading $MCP_SERVER_IMAGE into kind cluster..."
  kind load docker-image "$MCP_SERVER_IMAGE" --name "$CLUSTER_NAME"

  log "Deploying mcp-server..."
  helm upgrade --install mcp-server "$PROJECT_ROOT/helm/mcp-server" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.yaml" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.local.yaml" \
    --namespace "$NAMESPACE" \
    --wait --timeout 120s

  log "Patching mcp-server NodePort service..."
  kubectl patch svc mcp-server -n "$NAMESPACE" \
    -p '{"spec":{"ports":[{"port":8000,"targetPort":8000,"nodePort":30800}]}}' 2>/dev/null || true
else
  log "Skipping mcp-server deploy — image not built (Lane D pending)"
fi

# ---------------------------------------------------------------------------
# 7. Register OAuth test client
# ---------------------------------------------------------------------------

log "Registering test OAuth client..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:4445/admin/clients \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "test-agent-client",
    "client_secret": "test-agent-secret-change-in-prod",
    "grant_types": ["client_credentials"],
    "scope": "tools:classify.submit tools:health.read",
    "audience": ["mcp-presidio-server"],
    "token_endpoint_auth_method": "client_secret_post"
  }')

if [[ "$RESPONSE" == "201" ]]; then
  log "OAuth client registered"
elif [[ "$RESPONSE" == "409" ]]; then
  log "OAuth client already exists — skipping"
else
  fail "Unexpected response registering OAuth client: HTTP $RESPONSE"
fi

# ---------------------------------------------------------------------------
# 7. Smoke tests
# ---------------------------------------------------------------------------

log "Running smoke tests..."

check() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local result
  result=$(curl -sf "$url" 2>/dev/null) || fail "Smoke test failed: $name — could not reach $url"
  echo "$result" | grep -q "$expected" || fail "Smoke test failed: $name — expected '$expected' in response"
  log "  OK  $name"
}

check "Hydra public health"  "http://localhost:4444/.well-known/jwks.json" "keys"
check "Hydra admin health"   "http://localhost:4445/health/ready"           '"ok"'
check "Worker health"        "http://localhost:8080/health"                 '"ok"'

if curl -sf "http://localhost:8000/health" &>/dev/null; then
  check "MCP server health" "http://localhost:8000/health" '"ok"'
  MCP_STATUS="http://localhost:8000"
else
  log "  --  MCP server not deployed yet (Lane D pending)"
  MCP_STATUS="not deployed"
fi

log ""
log "Stack is ready."
log ""
log "  Hydra public:     http://localhost:4444"
log "  Hydra admin:      http://localhost:4445"
log "  Presidio worker:  http://localhost:8080"
log "  MCP server:       $MCP_STATUS"
log ""
log "Tear down with:  ./scripts/setup-local.sh --teardown"
