#!/usr/bin/env bash
# Full stack health and compliance check for mcp-presidio-sensitivity local dev.
#
# When to use:
#   - At the start of any development session to confirm the stack is healthy
#   - After ./scripts/rebuild.sh to verify the new pods came up cleanly
#   - After ./scripts/setup-local.sh to confirm full stack is ready
#   - Any time a service is unresponsive and you need a quick overview
#   - Before running demo.sh — catches problems before the live demo
#
# What it checks:
#   - Kind cluster exists
#   - All pods Running with 0 unexpected restarts
#   - Keycloak OIDC discovery endpoint reachable and returning valid JSON
#   - Worker and MCP server /health endpoints returning ok
#   - Token acquisition succeeds and TTL matches DEC-002 (≤ 60s)
#   - RFC 9728: 401 carries resource_metadata in WWW-Authenticate
#   - RFC 9728: /.well-known/oauth-protected-resource returns valid document
#
# Usage:
#   ./scripts/status.sh

set -uo pipefail

if ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

NAMESPACE="mcp-presidio"
CLUSTER_NAME="mcp-presidio"

pass() { printf '  \033[32mOK\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m--\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
header "Cluster"
if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
  pass "kind cluster '$CLUSTER_NAME' exists"
else
  fail "kind cluster '$CLUSTER_NAME' not found — run setup-local.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# Pods
# ---------------------------------------------------------------------------
header "Pods  ($NAMESPACE)"
kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | while read -r name ready status restarts age; do
  if [[ "$status" == "Running" ]]; then
    pass "$name  ($ready ready, $restarts restarts, age $age)"
  else
    fail "$name  status=$status ready=$ready restarts=$restarts"
  fi
done

# ---------------------------------------------------------------------------
# Service endpoints
# ---------------------------------------------------------------------------
header "Service endpoints"

# Keycloak OIDC discovery
KC_URL="http://localhost:8080/realms/mcp-local/.well-known/openid-configuration"
KC_RESPONSE=$(curl -sf --max-time 5 "$KC_URL" 2>/dev/null)
if echo "$KC_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'issuer' in d" 2>/dev/null; then
  ISSUER=$(echo "$KC_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
  pass "Keycloak OIDC discovery  ($ISSUER)"
else
  fail "Keycloak OIDC discovery  http://localhost:8080 — not ready or realm not imported"
fi

# Presidio worker
if curl -sf --max-time 5 http://localhost:8090/health | grep -q '"ok"' 2>/dev/null; then
  pass "Presidio worker          http://localhost:8090/health"
else
  fail "Presidio worker          http://localhost:8090/health"
fi

# MCP server
if curl -sf --max-time 5 http://localhost:8000/health | grep -q '"ok"' 2>/dev/null; then
  pass "MCP server               http://localhost:8000/health"
else
  fail "MCP server               http://localhost:8000/health"
fi

# ---------------------------------------------------------------------------
# Auth smoke test — token acquisition
# ---------------------------------------------------------------------------
header "Auth (token acquisition)"
TOKEN_RESPONSE=$(curl -sf --max-time 5 -X POST \
  http://localhost:8080/realms/mcp-local/protocol/openid-connect/token \
  -d "grant_type=client_credentials&client_id=test-agent-client&client_secret=test-agent-secret-change-in-prod&scope=tools:classify.submit" \
  2>/dev/null)

if echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'access_token' in d" 2>/dev/null; then
  EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in','?'))")
  pass "Token acquisition from Keycloak (expires_in: ${EXPIRES_IN}s)"
  # DEC-002: token TTL must be ≤ 60s
  if [[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] && [[ "$EXPIRES_IN" -gt 300 ]]; then
    fail "DEC-002 VIOLATION: token TTL ${EXPIRES_IN}s > 300s — run: ./scripts/keycloak-admin.sh set-ttl 60"
  elif [[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] && [[ "$EXPIRES_IN" -gt 60 ]]; then
    warn "DEC-002 advisory: token TTL ${EXPIRES_IN}s > 60s target — run: ./scripts/keycloak-admin.sh set-ttl 60"
  fi
else
  fail "Token acquisition from Keycloak — check client config or Keycloak realm"
fi

# ---------------------------------------------------------------------------
# RFC 9728 compliance check
# ---------------------------------------------------------------------------
header "RFC 9728 (Protected Resource Metadata)"

WWW_AUTH=$(curl -si --max-time 5 -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" -d '{}' 2>/dev/null \
  | grep -i "^www-authenticate:" | tr -d '\r')

if echo "$WWW_AUTH" | grep -q "resource_metadata"; then
  pass "401 WWW-Authenticate contains resource_metadata pointer"
else
  fail "401 WWW-Authenticate missing resource_metadata (RFC 9728 §5 non-compliant)"
fi

META=$(curl -sf --max-time 5 http://localhost:8000/.well-known/oauth-protected-resource 2>/dev/null)
if echo "$META" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'resource' in d and 'authorization_servers' in d" 2>/dev/null; then
  pass "/.well-known/oauth-protected-resource returns valid document"
else
  fail "/.well-known/oauth-protected-resource missing required fields"
fi

# ---------------------------------------------------------------------------
# Observability endpoints (Prometheus, Grafana)
# ---------------------------------------------------------------------------
header "Observability"

# MCP server /metrics
if curl -sf --max-time 5 http://localhost:8000/metrics 2>/dev/null | grep -q "mcp_build_info"; then
  pass "MCP server /metrics       http://localhost:8000/metrics"
else
  fail "MCP server /metrics       not serving (check prometheus-client dep)"
fi

# Worker /metrics
if curl -sf --max-time 5 http://localhost:8090/metrics 2>/dev/null | grep -q "worker_build_info"; then
  pass "Worker /metrics           http://localhost:8090/metrics"
else
  fail "Worker /metrics           not serving (check prometheus-client dep)"
fi

# ---------------------------------------------------------------------------
# Port mappings (informational)
# ---------------------------------------------------------------------------
header "Port mappings"
warn "Keycloak:         http://localhost:8080"
warn "Presidio worker:  http://localhost:8090"
warn "MCP server:       http://localhost:8000"
warn "Jaeger UI:        http://localhost:16686"
warn "Prometheus:       http://localhost:9090"
warn "Grafana:          http://localhost:3000"

printf '\n'
