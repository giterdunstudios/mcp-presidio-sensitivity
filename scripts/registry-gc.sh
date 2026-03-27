#!/usr/bin/env bash
# Run garbage collection on the local k3d registry to reclaim disk space
# occupied by unreferenced (dangling) image layers.
#
# When to use:
#   - When `docker exec k3d-mcp-registry du -sh /var/lib/registry` reports > ~5GB
#   - After 10 or more rebuild.sh runs on an active branch (each run pushes a
#     new SHA-tagged image; old layers accumulate until GC runs)
#   - Before a WSL2 session where disk headroom is tight
#   NOT automated — GC is a manual developer responsibility to avoid interrupting
#   concurrent builds (see safety note below).
#
# Usage:
#   ./scripts/registry-gc.sh               # live GC (removes dangling layers)
#   ./scripts/registry-gc.sh --dry-run     # show what would be removed; safe, no changes
#   ./scripts/registry-gc.sh --prune-old-tags  # also remove untagged manifests (old SHAs)
#
# Safety note:
#   Default GC (no flags) is safe when no concurrent `docker push` is in progress.
#   The GC sweep phase can delete blobs that an in-flight push has written but not yet
#   referenced by a manifest. Ensure no `rebuild.sh` is running before executing GC.
#   --prune-old-tags is DESTRUCTIVE — see the warning below before using it.
#
# Prerequisites:
#   - k3d cluster and registry running (./scripts/setup-local.sh completed)
#   - Docker available

set -euo pipefail

REGISTRY_CONTAINER="k3d-mcp-registry"
REGISTRY_HOST="localhost:5000"
REGISTRY_CONFIG="/etc/docker/registry/config.yml"
REGISTRY_DATA="/var/lib/registry"

log()  { echo "[registry-gc] $*"; }
warn() { printf '[registry-gc] \033[33mWARNING\033[0m: %s\n' "$*"; }
fail() { echo "[registry-gc] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

DRY_RUN=false
PRUNE_OLD_TAGS=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --prune-old-tags) PRUNE_OLD_TAGS=true ;;
    *) fail "Unknown flag '$arg'. Valid flags: --dry-run, --prune-old-tags" ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight: registry container must be running
# ---------------------------------------------------------------------------

if ! docker ps --filter "name=^${REGISTRY_CONTAINER}$" --format '{{.Names}}' 2>/dev/null \
    | grep -q "^${REGISTRY_CONTAINER}$"; then
  warn "Registry container '${REGISTRY_CONTAINER}' is not running."
  warn "Start it with: ./scripts/setup-local.sh"
  fail "Registry not running — cannot proceed"
fi

log "Registry container '${REGISTRY_CONTAINER}' is running."

# ---------------------------------------------------------------------------
# --prune-old-tags safety gate
# ---------------------------------------------------------------------------

if $PRUNE_OLD_TAGS; then
  printf '\n'
  printf '\033[1;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
  printf '\033[1;31m  WARNING: --prune-old-tags deletes manifests for ALL       \033[0m\n'
  printf '\033[1;31m  untagged (old SHA) images in the registry.                \033[0m\n'
  printf '\033[1;31m                                                             \033[0m\n'
  printf '\033[1;31m  Any pod still running an older SHA image will fail to     \033[0m\n'
  printf '\033[1;31m  pull if it is restarted after GC runs.                    \033[0m\n'
  printf '\033[1;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
  printf '\n'
  warn "Before continuing, confirm:"
  warn "  1. All running pods reference the CURRENT git SHA image tag."
  warn "     Check with: kubectl get pods -n mcp-presidio -o wide"
  warn "  2. No other branch has pods running against older SHA tags in this cluster."
  printf '\n'
  read -r -p "[registry-gc] Type 'yes' to confirm all pods use the current SHA and proceed: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted by operator."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Show disk usage and tag counts BEFORE GC
# ---------------------------------------------------------------------------

printf '\n'
log "=== BEFORE GC ==="

log "Disk usage (${REGISTRY_DATA}):"
docker exec "${REGISTRY_CONTAINER}" du -sh "${REGISTRY_DATA}" 2>/dev/null \
  | sed 's/^/  [registry-gc]   /'

log "Tag counts (Registry v2 API at http://${REGISTRY_HOST}):"
CATALOG=$(curl -sf --max-time 5 "http://${REGISTRY_HOST}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
REPOS=$(echo "$CATALOG" | python3 -c "import sys,json; repos=json.load(sys.stdin).get('repositories',[]); print('\n'.join(repos))" 2>/dev/null || true)

if [[ -z "$REPOS" ]]; then
  log "  (registry is empty — no repositories found)"
  TOTAL_TAGS_BEFORE=0
else
  TOTAL_TAGS_BEFORE=0
  while IFS= read -r repo; do
    TAGS_JSON=$(curl -sf --max-time 5 "http://${REGISTRY_HOST}/v2/${repo}/tags/list" 2>/dev/null || echo '{"tags":null}')
    TAG_COUNT=$(echo "$TAGS_JSON" | python3 -c "import sys,json; tags=json.load(sys.stdin).get('tags') or []; print(len(tags))" 2>/dev/null || echo 0)
    log "  ${repo}: ${TAG_COUNT} tag(s)"
    TOTAL_TAGS_BEFORE=$(( TOTAL_TAGS_BEFORE + TAG_COUNT ))
  done <<< "$REPOS"
  log "  Total: ${TOTAL_TAGS_BEFORE} tag(s) across all repositories"
fi

# ---------------------------------------------------------------------------
# Build garbage-collect command args
# ---------------------------------------------------------------------------

GC_ARGS=""
if $DRY_RUN; then
  GC_ARGS="--dry-run"
fi
if $PRUNE_OLD_TAGS; then
  GC_ARGS="${GC_ARGS} --delete-untagged"
fi

# ---------------------------------------------------------------------------
# Run garbage collection
# ---------------------------------------------------------------------------

printf '\n'
if $DRY_RUN; then
  log "=== DRY RUN (no changes will be made) ==="
else
  log "=== RUNNING GC ==="
fi

# shellcheck disable=SC2086
docker exec "${REGISTRY_CONTAINER}" registry garbage-collect \
  ${GC_ARGS} "${REGISTRY_CONFIG}"

# ---------------------------------------------------------------------------
# Show disk usage and tag counts AFTER GC
# ---------------------------------------------------------------------------

printf '\n'
log "=== AFTER GC ==="

log "Disk usage (${REGISTRY_DATA}):"
docker exec "${REGISTRY_CONTAINER}" du -sh "${REGISTRY_DATA}" 2>/dev/null \
  | sed 's/^/  [registry-gc]   /'

if [[ -n "$REPOS" ]]; then
  log "Tag counts:"
  TOTAL_TAGS_AFTER=0
  while IFS= read -r repo; do
    TAGS_JSON=$(curl -sf --max-time 5 "http://${REGISTRY_HOST}/v2/${repo}/tags/list" 2>/dev/null || echo '{"tags":null}')
    TAG_COUNT=$(echo "$TAGS_JSON" | python3 -c "import sys,json; tags=json.load(sys.stdin).get('tags') or []; print(len(tags))" 2>/dev/null || echo 0)
    log "  ${repo}: ${TAG_COUNT} tag(s)"
    TOTAL_TAGS_AFTER=$(( TOTAL_TAGS_AFTER + TAG_COUNT ))
  done <<< "$REPOS"
  log "  Total: ${TOTAL_TAGS_AFTER} tag(s) across all repositories"
fi

printf '\n'
if $DRY_RUN; then
  log "Dry run complete — registry unchanged."
  log "Re-run without --dry-run to apply GC."
else
  log "GC complete."
  if $PRUNE_OLD_TAGS; then
    warn "Old SHA manifests have been removed. Pods restarting from an older image tag will fail to pull."
    warn "Run ./scripts/rebuild.sh to push the current SHA image and ./scripts/status.sh to verify."
  else
    log "To reclaim space from old SHA-tagged images, re-run with --prune-old-tags"
    log "(requires confirming all running pods reference the current SHA)."
  fi
fi
