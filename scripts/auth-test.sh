#!/usr/bin/env bash
# Auth enforcement test matrix for mcp-presidio-sensitivity.
#
# Tests that Envoy/Istio enforces auth boundaries across five scenarios.
# As of Phase 2 (DEC-003), JWT validation and scope enforcement are handled
# by the Envoy sidecar via RequestAuthentication + AuthorizationPolicy CRDs —
# not by application middleware. Test cases are identical from the client's
# perspective; enforcement point has moved to the mesh layer.
#
# When to use:
#   After any change to infrastructure/istio/*.yaml or request-authentication.yaml.
#   After an Istio control-plane upgrade.
#   Before any Phase 2+ sign-off.
#   Any time auth boundary behaviour is in doubt.
#
# Cases tested:
#   1  No token        → 401 + RFC 9728 WWW-Authenticate header
#   2  Malformed token → 401
#   3  Valid token, wrong scope  → 403
#   4  Valid token, correct scope → 200
#   5  Expired token   → 401
#      (sets realm TTL to 2s, acquires token, restores TTL to 60s, waits 4s)
#
# Usage:
#   ./scripts/auth-test.sh
#
# Prerequisites:
#   - Stack healthy (run ./scripts/status.sh first)
#   - Keycloak accessible at http://localhost:8080
#   - mcp-local realm imported with test-agent-client configured

set -euo pipefail

KEYCLOAK="http://localhost:8080"
REALM="mcp-local"
ADMIN_USER="admin"
ADMIN_PASSWORD="change-me-in-prod"
CLIENT_ID="test-agent-client"
CLIENT_SECRET="test-agent-secret-change-in-prod"
MCP="http://localhost:8000"

pass()   { printf '  \033[32m✔\033[0m  %s\n' "$*"; }
fail()   { printf '  \033[31m✘\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
info()   { printf '  \033[2m--\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }
FAILURES=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Returns the admin access_token string (not full JSON)
admin_token() {
  local response
  response=$(curl -sf --max-time 10 -X POST \
    "$KEYCLOAK/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=${ADMIN_USER}&password=${ADMIN_PASSWORD}" \
    2>/dev/null) || { echo "ERROR: could not reach Keycloak at $KEYCLOAK" >&2; exit 1; }
  echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# Returns full token JSON response; callers extract access_token or expires_in.
# Accepts an optional scope argument (default: tools:classify.submit).
client_token() {
  local scope="${1:-tools:classify.submit}"
  curl -sf --max-time 10 -X POST \
    "$KEYCLOAK/realms/$REALM/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=${scope}" \
    2>/dev/null || { echo "ERROR: could not obtain client token from Keycloak" >&2; exit 1; }
}

# Sets the realm accessTokenLifespan. Called in case 5 and the EXIT trap.
set_realm_ttl() {
  local seconds="$1"
  local tok
  tok=$(admin_token)
  curl -sf --max-time 10 -o /dev/null \
    -X PUT "$KEYCLOAK/admin/realms/$REALM" \
    -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" \
    -d "{\"accessTokenLifespan\": $seconds}" 2>/dev/null || true
}

# Sends an MCP initialize request and returns only the HTTP status code.
mcp_init_code() {
  local token="$1"
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"auth-test","version":"1.0"}},"id":1}' \
    "$MCP/mcp"
}

# Ensure realm TTL is restored to DEC-002 value if the script exits early.
trap 'set_realm_ttl 60 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Case 1 — No token → 401 + RFC 9728 WWW-Authenticate
# ---------------------------------------------------------------------------

header "Case 1 — No token → auth challenge (401/403) + RFC 9728 WWW-Authenticate"
# Phase 2 note: Istio's AuthorizationPolicy always returns 403 for denied requests.
# When no JWT is present, RequestAuthentication passes the request (allow_missing),
# then AuthorizationPolicy denies it (403). True 401 for missing tokens requires
# a gateway-level policy not yet implemented. Both 401 and 403 are accepted here
# provided the WWW-Authenticate header is present (RFC 9728 §5 compliance).

RESP=$(curl -si --max-time 10 -X POST "$MCP/mcp" \
  -H "Content-Type: application/json" -d '{}' 2>/dev/null)
CODE=$(echo "$RESP" | grep "^HTTP" | awk '{print $2}')
WWW_AUTH=$(echo "$RESP" | grep -i "^www-authenticate:" | tr -d '\r')

if [[ "$CODE" == "401" || "$CODE" == "403" ]]; then
  pass "HTTP $CODE — auth challenge issued (Istio returns 403 for missing JWT)"
else
  fail "HTTP $CODE (expected 401 or 403)"
fi

if echo "$WWW_AUTH" | grep -q "resource_metadata"; then
  pass "WWW-Authenticate contains resource_metadata (RFC 9728 §5)"
  info "$WWW_AUTH"
else
  fail "WWW-Authenticate missing resource_metadata (RFC 9728 §5)"
  info "${WWW_AUTH:-(no header)}"
fi

# ---------------------------------------------------------------------------
# Case 2 — Malformed token → 401
# ---------------------------------------------------------------------------

header "Case 2 — Malformed token → 401"

CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer not.a.real.token" \
  -H "Content-Type: application/json" -d '{}' \
  "$MCP/mcp")

if [[ "$CODE" == "401" ]]; then
  pass "HTTP 401 — malformed token rejected"
else
  fail "HTTP $CODE (expected 401)"
fi

# ---------------------------------------------------------------------------
# Case 3 — Valid token, wrong scope → 403
# ---------------------------------------------------------------------------

header "Case 3 — Valid token, wrong scope → 403"

WRONG_TOK=$(client_token "tools:health.read" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
CODE=$(mcp_init_code "$WRONG_TOK")

if [[ "$CODE" == "403" ]]; then
  pass "HTTP 403 — valid token with insufficient scope rejected"
else
  fail "HTTP $CODE (expected 403)"
fi

# ---------------------------------------------------------------------------
# Case 4 — Valid token, correct scope → 200
# ---------------------------------------------------------------------------

header "Case 4 — Valid token, correct scope → 200"

GOOD_TOK=$(client_token "tools:classify.submit" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
CODE=$(mcp_init_code "$GOOD_TOK")

if [[ "$CODE" == "200" ]]; then
  pass "HTTP 200 — valid token accepted, MCP session opened"
else
  fail "HTTP $CODE (expected 200)"
fi

# ---------------------------------------------------------------------------
# Case 5 — Expired token → 401
# Temporarily lowers realm TTL to 2s to keep wait time short.
# Restores to 60s (DEC-002) before sleeping — the EXIT trap also ensures this.
# ---------------------------------------------------------------------------

header "Case 5 — Expired token → 401"
# Phase 2 note: Istio's JWT authn filter has a default 60-second clock skew
# tolerance. A token expired less than 60s ago is still considered valid.
# This test sets TTL=2s and waits 65s to exceed the clock skew window.
# The wait is intentional — do not reduce it.

info "Setting realm TTL to 2s ..."
set_realm_ttl 2

EXP_TOK=$(client_token "tools:classify.submit" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
info "Token acquired (TTL 2s)"

info "Restoring realm TTL to 60s (DEC-002) ..."
set_realm_ttl 60

WAIT=65
printf "  \033[2m--\033[0m  Waiting ${WAIT}s for token to expire beyond Istio clock skew window (60s) ...\n"
for i in $(seq "$WAIT" -1 1); do
  printf "\r  \033[2m--\033[0m  %2ds remaining ... " "$i"
  sleep 1
done
printf "\r  \033[2m--\033[0m  Wait complete.                          \n"

CODE=$(mcp_init_code "$EXP_TOK")

if [[ "$CODE" == "401" ]]; then
  pass "HTTP 401 — expired token rejected"
else
  fail "HTTP $CODE (expected 401)"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo ""
if [[ $FAILURES -eq 0 ]]; then
  printf '\033[32m\033[1mAll 5 auth enforcement cases passed\033[0m\n'
else
  printf '\033[31m\033[1m%d case(s) failed\033[0m\n' "$FAILURES"
  exit 1
fi
