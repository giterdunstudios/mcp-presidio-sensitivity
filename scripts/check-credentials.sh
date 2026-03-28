#!/usr/bin/env bash
# scripts/check-credentials.sh
#
# Scans local config files for known default/hardcoded credentials.
#
# When to use:
#   - Automatically called by rebuild.sh before every build (non-blocking)
#   - Run manually with --strict before opening a PR that touches Helm values
#   - Run with --strict in CI pipelines that validate production values files
#
# Usage:
#   ./scripts/check-credentials.sh           # warn only, exit 0
#   ./scripts/check-credentials.sh --strict  # exit 1 if any findings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STRICT=false
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=true
fi

# ---------------------------------------------------------------------------
# Files to scan — local config files that may contain default dev credentials.
# Production values.yaml files are intentionally excluded (no credentials there).
# ---------------------------------------------------------------------------

SCAN_TARGETS=(
  "$PROJECT_ROOT/helm/mcp-server/values.local.yaml"
  "$PROJECT_ROOT/helm/presidio-worker/values.local.yaml"
  "$PROJECT_ROOT/keycloak"
  "$PROJECT_ROOT/infrastructure/keycloak-local.yaml"
)

# Optional — present in this project but may not exist in all checkouts
if [[ -f "$PROJECT_ROOT/helm/keycloak-values.local.yaml" ]]; then
  SCAN_TARGETS+=("$PROJECT_ROOT/helm/keycloak-values.local.yaml")
fi

# ---------------------------------------------------------------------------
# Patterns — known default/placeholder credential values used in local dev.
# These must not appear in production config.
# ---------------------------------------------------------------------------

PATTERNS=(
  "change-in-prod"
  "change-me-in-prod"
  "test-agent-secret"
)

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

FINDINGS=0

for target in "${SCAN_TARGETS[@]}"; do
  if [[ ! -e "$target" ]]; then
    continue
  fi

  for pattern in "${PATTERNS[@]}"; do
    # grep -rn: recursive, with line numbers; -H: always print filename
    matches=$(grep -rn --include="*.yaml" --include="*.yml" --include="*.json" \
      -H "$pattern" "$target" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      echo "[check-credentials] WARNING: found default credential pattern '$pattern':"
      while IFS= read -r line; do
        echo "  $line"
      done <<< "$matches"
      FINDINGS=$((FINDINGS + 1))
    fi
  done

  # Separate scan for Keycloak admin password set to literal 'admin'
  # Match password fields (password:, adminPassword:, KC_BOOTSTRAP_ADMIN_PASSWORD:)
  # followed by the value 'admin' — word-boundary aware to avoid false positives
  admin_matches=$(grep -rn --include="*.yaml" --include="*.yml" --include="*.json" \
    -H -E '(password|adminPassword|ADMIN_PASSWORD)[[:space:]]*:[[:space:]]*admin[[:space:]]*$' \
    "$target" 2>/dev/null || true)
  if [[ -n "$admin_matches" ]]; then
    echo "[check-credentials] WARNING: found default admin password pattern:"
    while IFS= read -r line; do
      echo "  $line"
    done <<< "$admin_matches"
    FINDINGS=$((FINDINGS + 1))
  fi
done

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [[ $FINDINGS -eq 0 ]]; then
  echo "[check-credentials] No default credentials found in local config files."
else
  echo "[check-credentials] $FINDINGS finding(s) above are expected in local dev config and are safe to ignore."
  echo "[check-credentials] These values must not appear in production config files."
  if $STRICT; then
    echo "[check-credentials] --strict mode: exiting 1" >&2
    exit 1
  fi
fi

exit 0
