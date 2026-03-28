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

IN_CONTAINER=false
[ -f /.dockerenv ] && IN_CONTAINER=true

if ! $IN_CONTAINER && ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="mcp-presidio"
NAMESPACE="mcp-presidio"
REGISTRY_PUSH="localhost:5000"         # host-reachable push address; cluster pulls via k3d-mcp-registry:5000

# IMAGE_TAG defaults to the short git SHA of HEAD so branch builds get unique
# tags and don't overwrite each other in the registry. Override with:
#   IMAGE_TAG=my-tag ./scripts/rebuild.sh
# The tag is passed to Helm via --set image.tag so values.local.yaml does not
# need to be modified per branch.
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "dev")}"

MCP_IMAGE="mcp-presidio-sensitivity:${IMAGE_TAG}"
WORKER_IMAGE="presidio-worker:${IMAGE_TAG}"
MCP_IMAGE_REMOTE="$REGISTRY_PUSH/mcp-presidio-sensitivity:${IMAGE_TAG}"
WORKER_IMAGE_REMOTE="$REGISTRY_PUSH/presidio-worker:${IMAGE_TAG}"

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

# Credential scan (non-blocking — warn only)
"$SCRIPT_DIR/check-credentials.sh"

# ---------------------------------------------------------------------------
# Lock file sync check — fail fast if requirements.lock.txt is stale
# ---------------------------------------------------------------------------

check_lockfile_sync() {
  local svc="$1" workdir="$2"
  log "Checking $svc requirements.lock.txt sync..."
  # pip-compile --check is not available in pip-tools 7.x; generate to temp and diff instead.
  # When running inside a devtools container, volume mounts must use the HOST path (Docker socket
  # pass-through — the host Docker daemon resolves paths on the host, not inside this container).
  local host_workdir="${HOST_PROJECT_ROOT:+${HOST_PROJECT_ROOT}/src/${svc}}"
  host_workdir="${host_workdir:-$workdir}"
  if ! docker run --rm -v "$host_workdir:/work" python:3.11.15-slim \
       sh -c 'pip install -q pip-tools >/dev/null 2>&1 &&
              pip-compile --no-header --strip-extras -o /tmp/lock.check.txt /work/requirements.txt >/dev/null 2>&1 &&
              diff -q /tmp/lock.check.txt /work/requirements.lock.txt >/dev/null 2>&1'; then
    fail "$svc requirements.lock.txt is out of sync with requirements.txt.
Regenerate with:
  docker run --rm -v \$(pwd)/src/${svc}:/work python:3.11.15-slim \\
    sh -c 'pip install -q pip-tools >/dev/null 2>&1 && pip-compile --no-header \\
           --strip-extras -o /tmp/fresh.lock.txt /work/requirements.txt >/dev/null 2>&1 && \\
           cp /tmp/fresh.lock.txt /work/requirements.lock.txt'"
  fi
  log "Lock file in sync: $svc"
}

if $BUILD_MCP; then
  check_lockfile_sync "mcp_server" "$PROJECT_ROOT/src/mcp_server"
fi
if $BUILD_WORKER; then
  check_lockfile_sync "worker" "$PROJECT_ROOT/src/worker"
fi

# ---------------------------------------------------------------------------
# Build — output redirected to a temp log to avoid flooding the terminal.
# On success: one summary line. On failure: last 40 lines of build log.
# ---------------------------------------------------------------------------

docker_build() {
  local image="$1" dockerfile="$2" context="$3"
  local buildlog
  buildlog=$(mktemp)
  log "Building $image (--no-cache) → log: $buildlog"
  if docker build --no-cache -t "$image" -f "$dockerfile" "$context" \
       >"$buildlog" 2>&1; then
    log "$image built OK"
  else
    log "ERROR: $image build failed — last 40 lines:"
    tail -40 "$buildlog" >&2
    rm -f "$buildlog"
    exit 1
  fi
  rm -f "$buildlog"
}

# ---------------------------------------------------------------------------
# Vulnerability scanning — runs after docker build, before docker push.
# Requires Trivy to be installed on the host (optional — warn if absent).
# Severity policy:
#   CRITICAL → exit 1 (blocks push + deploy — do not ship critical CVEs to cluster)
#   HIGH     → exit 0 (warn only — printed visibly but build continues)
#   MEDIUM/LOW → not scanned (reduce noise)
# Escape hatch (offline/airgap): set TRIVY_SKIP_DB_UPDATE=1 to pass
# --skip-db-update to trivy and avoid the network call.
# Install Trivy: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
# ---------------------------------------------------------------------------

trivy_scan() {
  local image="$1"
  if ! command -v trivy &>/dev/null; then
    log "WARNING: trivy not installed — skipping vulnerability scan for $image"
    log "         Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
    return 0
  fi
  local trivy_extra_args=()
  if [ "${TRIVY_SKIP_DB_UPDATE:-0}" = "1" ]; then
    trivy_extra_args+=("--skip-db-update")
  fi
  log "Scanning $image for vulnerabilities (CRITICAL=block, HIGH=warn)..."
  # CRITICAL check — block the build
  if ! trivy image --severity CRITICAL --exit-code 1 --quiet "${trivy_extra_args[@]}" "$image"; then
    fail "CRITICAL vulnerabilities found in $image — fix before deploying. Run: trivy image $image"
  fi
  # HIGH check — warn only
  local high_count
  high_count=$(trivy image --severity HIGH --exit-code 0 --quiet --format table "${trivy_extra_args[@]}" "$image" 2>/dev/null | grep -c HIGH || true)
  if [ "$high_count" -gt 0 ]; then
    log "WARNING: $high_count HIGH severity finding(s) in $image — review with: trivy image --severity HIGH $image"
  else
    log "$image scan clean (no CRITICAL or HIGH)"
  fi
}

if $BUILD_MCP; then
  docker_build "$MCP_IMAGE" \
    "$PROJECT_ROOT/src/mcp_server/Dockerfile" \
    "$PROJECT_ROOT/src/mcp_server/"
  trivy_scan "$MCP_IMAGE"
fi

if $BUILD_WORKER; then
  docker_build "$WORKER_IMAGE" \
    "$PROJECT_ROOT/src/worker/Dockerfile" \
    "$PROJECT_ROOT/src/worker/"
  trivy_scan "$WORKER_IMAGE"
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
# the new image. --set image.tag overrides the tag in values.local.yaml so
# each branch deploys its own SHA-tagged image without modifying any file.
# When the tag changes, Helm detects the pod spec diff and the rollout
# restart below picks it up. When only config changes (same SHA), the
# rollout restart alone moves pods onto the new config.
# ---------------------------------------------------------------------------

if $BUILD_MCP; then
  log "Helm upgrade: mcp-presidio-sensitivity (image.tag=${IMAGE_TAG})..."
  helm upgrade --install mcp-presidio-sensitivity "$PROJECT_ROOT/helm/mcp-server" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.yaml" \
    -f "$PROJECT_ROOT/helm/mcp-server/values.local.yaml" \
    --set image.tag="${IMAGE_TAG}" \
    --namespace "$NAMESPACE" \
    --timeout 120s
fi

if $BUILD_WORKER; then
  log "Helm upgrade: presidio-worker (image.tag=${IMAGE_TAG})..."
  helm upgrade --install presidio-worker "$PROJECT_ROOT/helm/presidio-worker" \
    -f "$PROJECT_ROOT/helm/presidio-worker/values.yaml" \
    -f "$PROJECT_ROOT/helm/presidio-worker/values.local.yaml" \
    --set image.tag="${IMAGE_TAG}" \
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
  # Worker is NetworkPolicy-restricted — not reachable via localhost:8090.
  # kubectl rollout status (above) already confirmed the deployment is Ready,
  # which means the kubelet liveness/readiness probes passed. No external check needed.
  log "  OK  Worker health (confirmed via rollout status — external port is NetworkPolicy-restricted)"
fi

log ""
log "Rebuild complete. Run ./scripts/status.sh to verify the full stack."
