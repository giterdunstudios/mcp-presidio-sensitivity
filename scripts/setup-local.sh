#!/usr/bin/env bash
# Bootstrap the local mcp-presidio development stack.
#
# When to use:
#   - First-time setup on a new machine or after --teardown
#   - After a WSL2 restart that wiped the k3d cluster
#   - When you need a completely clean environment (teardown + re-run)
#   Do NOT use this for routine code changes — use ./scripts/rebuild.sh instead.
#
# What this does:
#   1. Creates the k3d local registry (k3d-mcp-registry:5000) if not present
#   2. Creates the k3d cluster with host port mappings
#   3. Creates the mcp-presidio namespace
#   4. Deploys Keycloak via kubectl apply (infrastructure/keycloak-local.yaml)
#   5. Pushes the presidio-worker image to the registry and deploys it via Helm
#   6. Pushes the mcp-presidio-sensitivity image and deploys it via Helm (if built)
#   7. Waits for all pods to be ready
#   8. Runs a smoke test against each endpoint
#
# After setup, always run:
#   ./scripts/keycloak-admin.sh set-ttl 60   (enforce DEC-002 token TTL)
#   ./scripts/status.sh                       (confirm full stack is healthy)
#
# Prerequisites:
#   - k3d, kubectl, helm, docker (with docker group access)
#   - presidio-worker image built: docker build -t presidio-worker:0.1.0 src/worker/
#
# Usage:
#   ./scripts/setup-local.sh               # full setup
#   ./scripts/setup-local.sh --skip-build  # skip image build (use existing image)
#   ./scripts/setup-local.sh --teardown    # delete the cluster and registry, then exit

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisites check — fail fast with actionable messages
# ---------------------------------------------------------------------------

check_prereq() {
  local cmd="$1"
  local install_hint="$2"
  if ! command -v "$cmd" &>/dev/null; then
    echo "[setup] ERROR: '$cmd' not found. $install_hint" >&2
    exit 1
  fi
}

check_prereq docker  "Install Docker: https://docs.docker.com/engine/install/"
check_prereq k3d     "Install k3d: https://k3d.io/stable/#installation  (brew install k3d)"
check_prereq kubectl "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
check_prereq helm    "Install helm: https://helm.sh/docs/intro/install/  (brew install helm)"
check_prereq curl    "Install curl: apt-get install curl"

# ---------------------------------------------------------------------------
# Container detection — skip sg docker re-exec when running inside devtools.
# Inside the devtools container the Docker socket is mounted directly and sg
# is not available. On the host (WSL2) sg is needed to apply the docker group
# to non-interactive subshells.
# ---------------------------------------------------------------------------
IN_CONTAINER=false
[ -f /.dockerenv ] && IN_CONTAINER=true

# Re-exec with docker group applied if not already in it (host only).
if ! $IN_CONTAINER && ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

# docker_exec: run a docker subcommand, using sg when on host outside docker group.
docker_exec() {
  if $IN_CONTAINER; then
    docker "$@"
  else
    sg docker -c "docker $*"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="mcp-presidio"
NAMESPACE="mcp-presidio"
REGISTRY_NAME="mcp-registry"          # k3d prepends 'k3d-' → k3d-mcp-registry
REGISTRY_PUSH="localhost:5000"         # host-reachable push address
WORKER_IMAGE="presidio-worker:0.1.0"
MCP_SERVER_IMAGE="mcp-presidio-sensitivity:0.1.0"
WORKER_IMAGE_REMOTE="$REGISTRY_PUSH/presidio-worker:0.1.0"
MCP_SERVER_IMAGE_REMOTE="$REGISTRY_PUSH/mcp-presidio-sensitivity:0.1.0"

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
# k3d version check — must meet minimum floor before any k3d commands
# ---------------------------------------------------------------------------

REQUIRED_K3D_VERSION="5.7.4"
INSTALLED_K3D_VERSION=$(k3d version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

[ -z "$INSTALLED_K3D_VERSION" ] && fail "could not parse k3d version output. Run 'k3d version' manually."

LOWER_K3D=$(printf '%s\n%s\n' "$REQUIRED_K3D_VERSION" "$INSTALLED_K3D_VERSION" | sort -V | head -1)

if [ "$LOWER_K3D" = "$INSTALLED_K3D_VERSION" ] && [ "$INSTALLED_K3D_VERSION" != "$REQUIRED_K3D_VERSION" ]; then
  fail "k3d $INSTALLED_K3D_VERSION is below required minimum $REQUIRED_K3D_VERSION. Upgrade: https://k3d.io/stable/#installation"
elif [ "$INSTALLED_K3D_VERSION" != "$REQUIRED_K3D_VERSION" ]; then
  echo "[setup] WARNING: k3d $INSTALLED_K3D_VERSION is newer than pinned $REQUIRED_K3D_VERSION — may work, but untested. Run ./scripts/validate-networkpolicy.sh after setup to confirm enforcement is intact." >&2
fi

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

if $TEARDOWN; then
  log "Tearing down cluster $CLUSTER_NAME..."
  k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true
  log "Deleting registry $REGISTRY_NAME..."
  k3d registry delete "$REGISTRY_NAME" 2>/dev/null || true
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
  docker_exec build -t "$WORKER_IMAGE" "$PROJECT_ROOT/src/worker/"

  if [[ -d "$PROJECT_ROOT/src/mcp_server" ]]; then
    log "Building $MCP_SERVER_IMAGE..."
    docker_exec build -t "$MCP_SERVER_IMAGE" "$PROJECT_ROOT/src/mcp_server/"
  else
    log "Skipping $MCP_SERVER_IMAGE build — src/mcp_server/ not yet present"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Create registry
# ---------------------------------------------------------------------------

if k3d registry list 2>/dev/null | grep -q "k3d-$REGISTRY_NAME"; then
  log "Registry k3d-$REGISTRY_NAME already exists — skipping creation"
else
  log "Creating k3d registry k3d-$REGISTRY_NAME on port 5000..."
  k3d registry create "$REGISTRY_NAME" --port 5000
fi

# ---------------------------------------------------------------------------
# 3. Create k3d cluster
# ---------------------------------------------------------------------------

if k3d cluster list 2>/dev/null | grep -q "^$CLUSTER_NAME"; then
  log "Cluster $CLUSTER_NAME already exists — skipping creation"
else
  log "Creating k3d cluster $CLUSTER_NAME..."
  k3d cluster create --config "$PROJECT_ROOT/infrastructure/k3d-config.yaml"
fi

kubectl config use-context "k3d-$CLUSTER_NAME"

# ---------------------------------------------------------------------------
# 4. Namespace
# ---------------------------------------------------------------------------

kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
log "Namespace $NAMESPACE ready"

# ---------------------------------------------------------------------------
# 5. Deploy Keycloak
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
# 6. Deploy observability infrastructure (Jaeger, Prometheus, Grafana)
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
# 7. Push and deploy presidio-worker
# ---------------------------------------------------------------------------

log "Pushing $WORKER_IMAGE to registry..."
docker_exec tag "$WORKER_IMAGE" "$WORKER_IMAGE_REMOTE"
docker_exec push "$WORKER_IMAGE_REMOTE"

log "Deploying presidio-worker..."
helm upgrade --install presidio-worker "$PROJECT_ROOT/helm/presidio-worker" \
  -f "$PROJECT_ROOT/helm/presidio-worker/values.yaml" \
  -f "$PROJECT_ROOT/helm/presidio-worker/values.local.yaml" \
  --namespace "$NAMESPACE" \
  --wait --timeout 180s
kubectl rollout restart deployment/presidio-worker -n "$NAMESPACE"
kubectl rollout status deployment/presidio-worker -n "$NAMESPACE" --timeout=120s

# ---------------------------------------------------------------------------
# 8. Push and deploy mcp-presidio-sensitivity (if built)
# ---------------------------------------------------------------------------

if docker_exec image inspect "$MCP_SERVER_IMAGE" &>/dev/null; then
  log "Pushing $MCP_SERVER_IMAGE to registry..."
  docker_exec tag "$MCP_SERVER_IMAGE" "$MCP_SERVER_IMAGE_REMOTE"
  docker_exec push "$MCP_SERVER_IMAGE_REMOTE"

  log "Deploying mcp-presidio-sensitivity..."
  helm upgrade --install mcp-presidio-sensitivity "$PROJECT_ROOT/helm/mcp-server" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.yaml" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.local.yaml" \
    --namespace "$NAMESPACE" \
    --wait --timeout 120s
  kubectl rollout restart deployment/mcp-presidio-sensitivity -n "$NAMESPACE"
  kubectl rollout status deployment/mcp-presidio-sensitivity -n "$NAMESPACE" --timeout=120s
else
  log "Skipping mcp-presidio-sensitivity deploy — image not built"
fi

# ---------------------------------------------------------------------------
# 9. Smoke tests
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
  log "  --  MCP server not deployed yet"
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
