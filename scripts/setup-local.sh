#!/usr/bin/env bash
# Bootstrap the local mcp-presidio development stack.
#
# When to use:
#   - First-time setup on a new machine or after --teardown
#   - After a WSL2 restart that wiped the kind cluster
#   - When you need a completely clean environment (teardown + re-run)
#   Do NOT use this for routine code changes — use ./scripts/rebuild.sh instead.
#
# What this does:
#   1. Creates the kind cluster with host port mappings
#   2. Creates the mcp-presidio namespace
#   3. Deploys Keycloak via kubectl apply (infrastructure/keycloak-local.yaml)
#   4. Loads the presidio-worker image and deploys it via Helm
#   5. Loads the mcp-presidio-sensitivity image and deploys it via Helm (if built)
#   6. Waits for all pods to be ready
#   7. Runs a smoke test against each endpoint
#
# After setup, always run:
#   ./scripts/keycloak-admin.sh set-ttl 60   (enforce DEC-002 token TTL)
#   ./scripts/status.sh                       (confirm full stack is healthy)
#
# Prerequisites:
#   - kind, kubectl, helm, docker (with docker group access)
#   - presidio-worker image built: docker build -t presidio-worker:0.1.0 src/worker/
#
# Usage:
#   ./scripts/setup-local.sh               # full setup
#   ./scripts/setup-local.sh --skip-build  # skip image build (use existing image)
#   ./scripts/setup-local.sh --teardown    # delete the cluster and exit

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
MCP_SERVER_IMAGE="mcp-presidio-sensitivity:0.1.0"

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
# 0. Helm repositories
# ---------------------------------------------------------------------------
# bitnami is registered for potential future use (e.g. if Keycloak moves back
# to a Helm-managed deploy). Not currently used — Keycloak is deployed via
# kubectl apply (infrastructure/keycloak-local.yaml).
log "Registering Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update 2>/dev/null || true
helm repo update bitnami 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Build images (unless skipped)
# ---------------------------------------------------------------------------

if $SKIP_BUILD; then
  log "Skipping image builds (--skip-build passed)"
else
  log "Building $WORKER_IMAGE..."
  sg docker -c "docker build -t '$WORKER_IMAGE' '$PROJECT_ROOT/src/worker/'"

  if [[ -d "$PROJECT_ROOT/src/mcp_server" ]]; then
    log "Building $MCP_SERVER_IMAGE..."
    sg docker -c "docker build -t '$MCP_SERVER_IMAGE' '$PROJECT_ROOT/src/mcp_server/'"
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
# 4. Deploy Keycloak
# ---------------------------------------------------------------------------

log "Creating Keycloak realm ConfigMap..."
kubectl create configmap keycloak-realm-import \
  --from-file="$PROJECT_ROOT/keycloak/realm-import/mcp-local-realm.json" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Deploying Keycloak..."
kubectl apply -f "$PROJECT_ROOT/infrastructure/keycloak-local.yaml"
kubectl rollout status deployment/keycloak -n "$NAMESPACE" --timeout=300s

# ---------------------------------------------------------------------------
# 5. Deploy observability infrastructure (Jaeger, Prometheus, Grafana)
# ---------------------------------------------------------------------------

log "Deploying Jaeger..."
kubectl apply -f "$PROJECT_ROOT/infrastructure/jaeger.yaml"
kubectl rollout status deployment/jaeger -n "$NAMESPACE" --timeout=60s

log "Deploying Prometheus..."
kubectl apply -f "$PROJECT_ROOT/infrastructure/prometheus.yaml"
kubectl rollout status deployment/prometheus -n "$NAMESPACE" --timeout=60s

log "Deploying Grafana..."
kubectl apply -f "$PROJECT_ROOT/infrastructure/grafana.yaml"
kubectl rollout status deployment/grafana -n "$NAMESPACE" --timeout=60s

# ---------------------------------------------------------------------------
# 6. Load and deploy presidio-worker
# ---------------------------------------------------------------------------

log "Loading $WORKER_IMAGE into kind cluster..."
sg docker -c "kind load docker-image '$WORKER_IMAGE' --name '$CLUSTER_NAME'"

log "Deploying presidio-worker..."
helm upgrade --install presidio-worker "$PROJECT_ROOT/helm/presidio-worker" \
  -f "$PROJECT_ROOT/helm/presidio-worker/values.yaml" \
  -f "$PROJECT_ROOT/helm/presidio-worker/values.local.yaml" \
  --namespace "$NAMESPACE" \
  --wait --timeout 180s
kubectl rollout restart deployment/presidio-worker -n "$NAMESPACE"
kubectl rollout status deployment/presidio-worker -n "$NAMESPACE" --timeout=120s

# ---------------------------------------------------------------------------
# 7. Load and deploy mcp-presidio-sensitivity (if built)
# ---------------------------------------------------------------------------

if sg docker -c "docker image inspect '$MCP_SERVER_IMAGE'" &>/dev/null; then
  log "Loading $MCP_SERVER_IMAGE into kind cluster..."
  sg docker -c "kind load docker-image '$MCP_SERVER_IMAGE' --name '$CLUSTER_NAME'"

  log "Deploying mcp-presidio-sensitivity..."
  helm upgrade --install mcp-presidio-sensitivity "$PROJECT_ROOT/helm/mcp-server" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.yaml" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.local.yaml" \
    --namespace "$NAMESPACE" \
    --wait --timeout 120s
  kubectl rollout restart deployment/mcp-presidio-sensitivity -n "$NAMESPACE"
  kubectl rollout status deployment/mcp-presidio-sensitivity -n "$NAMESPACE" --timeout=120s
else
  log "Skipping mcp-presidio-sensitivity deploy — image not built (Lane D pending)"
fi

# ---------------------------------------------------------------------------
# 8. Smoke tests
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

check "Keycloak OIDC discovery" \
  "http://localhost:8080/realms/mcp-local/.well-known/openid-configuration" \
  "issuer"

check "Worker health" "http://localhost:8090/health" '"ok"'

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
log "  Keycloak:         http://localhost:8080"
log "  Presidio worker:  http://localhost:8090"
log "  MCP server:       $MCP_STATUS"
log "  Jaeger UI:        http://localhost:16686"
log "  Prometheus:       http://localhost:9090"
log "  Grafana:          http://localhost:3000"
log ""
log "Tear down with:  ./scripts/setup-local.sh --teardown"
