#!/usr/bin/env bash
# Run any command inside the devtools container.
#
# Provides k3d, kubectl, helm, and docker CLI without requiring host installation.
# All tools are pinned — no dependency on the host environment beyond Docker itself.
#
# Usage:
#   ./scripts/devtools-run.sh ./scripts/setup-local.sh
#   ./scripts/devtools-run.sh ./scripts/setup-local.sh --teardown
#   ./scripts/devtools-run.sh kubectl get pods -n mcp-presidio
#   ./scripts/devtools-run.sh helm list -n mcp-presidio
#   ./scripts/devtools-run.sh k3d cluster list
#
# Rebuild the devtools image:
#   docker rmi mcp-presidio-devtools:latest
#   ./scripts/devtools-run.sh <any command>  # will rebuild automatically

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVTOOLS_IMAGE="mcp-presidio-devtools:latest"
DOCKERFILE="$PROJECT_ROOT/infrastructure/devtools.Dockerfile"

# Build devtools image if not already present
if ! docker image inspect "$DEVTOOLS_IMAGE" &>/dev/null; then
  echo "[devtools] Building $DEVTOOLS_IMAGE (first run)..."
  docker build -f "$DOCKERFILE" -t "$DEVTOOLS_IMAGE" "$PROJECT_ROOT"
fi

# Ensure kubeconfig dir exists on host (shared into container)
KUBE_DIR="${HOME}/.kube"
mkdir -p "$KUBE_DIR"

# Run the container. Kubeconfig is written as root inside the container;
# fix ownership on exit so host tools (kubectl, demo.sh) can read it.
docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$KUBE_DIR:/root/.kube" \
  -v "$PROJECT_ROOT:/workspace" \
  --network host \
  --workdir /workspace \
  "$DEVTOOLS_IMAGE" \
  "$@"
EXIT_CODE=$?

# Repair kubeconfig ownership if root took it over inside the container
if [ -f "$KUBE_DIR/config" ] && [ "$(stat -c '%U' "$KUBE_DIR/config" 2>/dev/null)" = "root" ]; then
  docker run --rm \
    -v "$KUBE_DIR:/kube" \
    alpine:3.20 \
    sh -c "chown -R $(id -u):$(id -g) /kube" 2>/dev/null || true
fi

exit $EXIT_CODE
