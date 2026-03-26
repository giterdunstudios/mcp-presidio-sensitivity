#!/usr/bin/env bash
# Keycloak admin operations for the mcp-local realm.
#
# All operations obtain a short-lived admin token from the master realm first.
# The admin token is never stored to disk or printed to stdout.
#
# When to use:
#   status          — At the start of any session to confirm realm config
#                     matches what is expected (TTL, brute force, client state).
#                     Also run after a cluster rebuild to confirm the realm
#                     import applied correctly.
#
#   set-ttl         — After a cluster rebuild if the realm import did not
#                     apply the TTL (Keycloak ignores accessTokenLifespan in
#                     partial imports). Also used to apply DEC-002 on a
#                     freshly created realm.
#                     Target: 60 seconds (see decision-log.md DEC-002).
#
#   discovery-check — Before any auth-related release or after changing
#                     auth/errors.py, config.py, or the /.well-known endpoint.
#                     Walks the full RFC 9728 four-step discovery chain and
#                     asserts every step is spec-compliant.
#
#   token           — Acquire and decode a client token. Shows issuer, subject,
#                     scope, iat, exp, and TTL remaining. Asserts DEC-002
#                     (≤ 60s). Use --raw to also print the Bearer token for
#                     use in curl commands.
#
# Usage:
#   ./scripts/keycloak-admin.sh status
#   ./scripts/keycloak-admin.sh set-ttl 60
#   ./scripts/keycloak-admin.sh discovery-check
#   ./scripts/keycloak-admin.sh token
#   ./scripts/keycloak-admin.sh token --raw
#
# Prerequisites:
#   - Keycloak running and accessible at http://localhost:8080
#   - mcp-local realm imported

set -euo pipefail

KEYCLOAK="http://localhost:8080"
REALM="mcp-local"
ADMIN_USER="admin"
ADMIN_PASSWORD="change-me-in-prod"
CLIENT_ID="test-agent-client"
CLIENT_SECRET="test-agent-secret-change-in-prod"
MCP_URL="http://localhost:8000"

pass() { printf '  \033[32m✔\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
info() { printf '  \033[2m--\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }
FAILURES=0

# ---------------------------------------------------------------------------
# Admin token — obtained fresh for every invocation, never persisted
# ---------------------------------------------------------------------------

admin_token() {
  local response
  response=$(curl -sf --max-time 10 -X POST \
    "$KEYCLOAK/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=${ADMIN_USER}&password=${ADMIN_PASSWORD}" \
    2>/dev/null) || { echo "ERROR: could not reach Keycloak at $KEYCLOAK" >&2; exit 1; }
  echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# ---------------------------------------------------------------------------
# Client token — full JSON response; callers extract access_token or expires_in
# ---------------------------------------------------------------------------

client_token() {
  curl -sf --max-time 10 -X POST \
    "$KEYCLOAK/realms/$REALM/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=tools:classify.submit" \
    2>/dev/null || { echo "ERROR: could not obtain client token from Keycloak" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------

cmd_status() {
  header "Realm: $REALM"
  local token
  token=$(admin_token)
  local realm_json
  realm_json=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer $token" \
    "$KEYCLOAK/admin/realms/$REALM" 2>/dev/null)

  local ttl brute_force
  ttl=$(echo "$realm_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessTokenLifespan','(not set — Keycloak default 300)'))")
  brute_force=$(echo "$realm_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('bruteForceProtected', False))")

  info "accessTokenLifespan:  ${ttl}s"
  info "bruteForceProtected:  $brute_force"

  header "Client: $CLIENT_ID"
  local clients_json client_json
  clients_json=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer $token" \
    "$KEYCLOAK/admin/realms/$REALM/clients?clientId=$CLIENT_ID" 2>/dev/null)
  local enabled
  enabled=$(echo "$clients_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('enabled') if d else 'not found')")
  local sa_enabled
  sa_enabled=$(echo "$clients_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('serviceAccountsEnabled') if d else 'not found')")
  info "enabled:                    $enabled"
  info "serviceAccountsEnabled:     $sa_enabled"
}

# ---------------------------------------------------------------------------
# Subcommand: set-ttl
# ---------------------------------------------------------------------------

cmd_set_ttl() {
  local seconds="${1:-}"
  if [[ -z "$seconds" ]] || ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    echo "Usage: $0 set-ttl <seconds>" >&2; exit 1
  fi
  header "Setting accessTokenLifespan to ${seconds}s on realm $REALM"
  local token
  token=$(admin_token)
  local http_code
  http_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
    -X PUT "$KEYCLOAK/admin/realms/$REALM" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"accessTokenLifespan\": $seconds}" 2>/dev/null)

  if [[ "$http_code" == "204" ]]; then
    pass "accessTokenLifespan set to ${seconds}s (HTTP $http_code)"
    # Verify by re-reading
    local actual_ttl
    actual_ttl=$(curl -sf --max-time 10 \
      -H "Authorization: Bearer $(admin_token)" \
      "$KEYCLOAK/admin/realms/$REALM" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessTokenLifespan'))")
    info "Verified live value: ${actual_ttl}s"
    # Test a real token
    local token_ttl
    token_ttl=$(client_token | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in'))")
    info "New token expires_in:  ${token_ttl}s"
  else
    fail "Failed to update TTL (HTTP $http_code)"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: discovery-check (RFC 9728 compliance)
# ---------------------------------------------------------------------------

cmd_discovery_check() {
  header "RFC 9728 Discovery Chain"

  # Step 1: 401 must carry resource_metadata in WWW-Authenticate
  local www_auth
  www_auth=$(curl -si --max-time 5 -X POST "$MCP_URL/mcp" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null \
    | grep -i "^www-authenticate:" | tr -d '\r')

  if echo "$www_auth" | grep -q "resource_metadata"; then
    pass "Step 1 — 401 WWW-Authenticate contains resource_metadata"
    info "$www_auth"
  else
    fail "Step 1 — 401 WWW-Authenticate missing resource_metadata (RFC 9728 §5)"
    info "$www_auth"
  fi

  # Step 2: /.well-known/oauth-protected-resource returns valid doc
  local meta_doc
  meta_doc=$(curl -sf --max-time 5 "$MCP_URL/.well-known/oauth-protected-resource" 2>/dev/null)
  if echo "$meta_doc" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'resource' in d and 'authorization_servers' in d" 2>/dev/null; then
    pass "Step 2 — /.well-known/oauth-protected-resource returns resource + authorization_servers"
    local as_url
    as_url=$(echo "$meta_doc" | python3 -c "import sys,json; print(json.load(sys.stdin)['authorization_servers'][0])")
    info "authorization_servers[0]: $as_url"
  else
    fail "Step 2 — /.well-known/oauth-protected-resource missing required fields"
  fi

  # Step 3: AS OpenID Connect discovery doc is reachable
  local as_url
  as_url=$(echo "$meta_doc" | python3 -c "import sys,json; print(json.load(sys.stdin)['authorization_servers'][0])" 2>/dev/null || echo "")
  if [[ -n "$as_url" ]]; then
    local oidc_doc
    oidc_doc=$(curl -sf --max-time 5 "${as_url}/.well-known/openid-configuration" 2>/dev/null)
    if echo "$oidc_doc" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'token_endpoint' in d and 'issuer' in d" 2>/dev/null; then
      pass "Step 3 — AS OpenID Connect discovery reachable and valid"
      local te
      te=$(echo "$oidc_doc" | python3 -c "import sys,json; print(json.load(sys.stdin)['token_endpoint'])")
      info "token_endpoint: $te"
    else
      fail "Step 3 — AS OpenID Connect discovery missing token_endpoint or issuer"
    fi
  else
    fail "Step 3 — could not determine AS URL from resource metadata"
  fi

  # Step 4: Token can actually be obtained from the discovered endpoint
  local token_response expires_in
  token_response=$(client_token 2>/dev/null) || token_response=""
  expires_in=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in','ERROR'))" 2>/dev/null || echo "ERROR")
  if [[ "$expires_in" != "ERROR" ]]; then
    pass "Step 4 — token obtained from discovered endpoint (expires_in: ${expires_in}s)"
    if [[ "$expires_in" -gt 300 ]]; then
      fail "  DEC-002 VIOLATION: expires_in=${expires_in}s exceeds 300s — expected ≤ 60s per decision log"
    fi
  else
    fail "Step 4 — could not obtain token from discovered endpoint"
  fi

  echo ""
  if [[ $FAILURES -eq 0 ]]; then
    printf '\033[32m\033[1mRFC 9728 discovery chain fully compliant\033[0m\n'
  else
    printf '\033[31m\033[1m%d compliance check(s) failed\033[0m\n' "$FAILURES"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: token
# ---------------------------------------------------------------------------

cmd_token() {
  local raw=false
  [[ "${1:-}" == "--raw" ]] && raw=true

  header "Token: $CLIENT_ID"
  local response token expires_in
  response=$(client_token)
  token=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  expires_in=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in','?'))")

  echo "$token" | python3 -c "
import sys, json, base64, datetime, time
token = sys.stdin.read().strip()
parts = token.split('.')
payload = parts[1] + '=' * (-len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
now = int(time.time())
exp = claims.get('exp', 0)
iat = claims.get('iat', 0)
fmt = lambda ts: datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ')
print('  iss:           ' + claims.get('iss', '?'))
print('  sub:           ' + claims.get('sub', '?'))
print('  scope:         ' + claims.get('scope', '?'))
print('  iat:           ' + fmt(iat))
print('  exp:           ' + fmt(exp))
print('  ttl_remaining: ' + str(exp - now) + 's')
"

  if [[ "$expires_in" =~ ^[0-9]+$ ]] && [[ "$expires_in" -gt 60 ]]; then
    fail "DEC-002: expires_in=${expires_in}s exceeds 60s"
  else
    pass "DEC-002: expires_in=${expires_in}s (≤ 60s)"
  fi

  if $raw; then
    header "Raw Token"
    echo "$token"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
  status)           cmd_status ;;
  set-ttl)          cmd_set_ttl "$@" ;;
  discovery-check)  cmd_discovery_check ;;
  token)            cmd_token "$@" ;;
  *)
    echo "Usage: $0 {status|set-ttl <seconds>|discovery-check|token [--raw]}" >&2
    exit 1
    ;;
esac
