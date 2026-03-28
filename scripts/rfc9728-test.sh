#!/usr/bin/env bash
# RFC 9728 discovery chain integration test for mcp-presidio-sensitivity.
#
# Walks the full "client needs only MCP server URL" discovery chain (Flow 2
# in planning/auth-flows-diagram.md) with labelled pass/fail output per step.
# Starts from MCP_URL only — no pre-obtained token, no pre-configured
# Keycloak URL.
#
# When to use:
#   After any change to the RFC 9728 discovery endpoint
#   (src/mcp_server/main.py /.well-known/oauth-protected-resource route).
#   After any change to auth error responses (auth/errors.py).
#   After an Istio deployment or upgrade that could affect WWW-Authenticate
#   header injection.
#   As a standalone compliance check that the discovery chain is intact.
#
# Steps tested:
#   1  Unauthenticated POST /mcp → 401 or 403 + WWW-Authenticate header
#   2  Parse resource_metadata URL from WWW-Authenticate header
#   3  GET resource_metadata URL → 200 + authorization_servers array
#   4  GET <AS_URL>/.well-known/openid-configuration → 200 + token_endpoint
#   5  POST token_endpoint (client credentials) → 200 + access_token
#   6  POST /mcp with discovered token → 200
#
# NOTE — Steps 1 and 2 require Istio to be deployed (Phase 2).
# Without Istio, the MCP server returns 200 for unauthenticated requests and
# the WWW-Authenticate challenge is not issued. Steps 1-2 will FAIL until
# Phase 2 Istio deployment is complete (BP-029). This is expected behaviour
# in the current environment — do not skip or suppress the failures.
#
# Usage:
#   ./scripts/rfc9728-test.sh
#
# Prerequisites:
#   - Stack healthy (run ./scripts/status.sh first)
#   - MCP server accessible at http://localhost:8000
#   - Keycloak accessible at http://localhost:8080 (discovered, not pre-configured)

set -euo pipefail

MCP_URL="http://localhost:8000"

# Client credentials — same as scripts/auth-test.sh and keycloak/realm-import/mcp-local-realm.json.
# Hardcoded for local dev; do not use in production.
CLIENT_ID="test-agent-client"
CLIENT_SECRET="test-agent-secret-change-in-prod"
SCOPE="tools:classify.submit"

pass()   { printf '  \033[32m✔\033[0m  %s\n' "$*"; }
fail()   { printf '  \033[31m✘\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
info()   { printf '  \033[2m--\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }
FAILURES=0

# ---------------------------------------------------------------------------
# Step 1 — Unauthenticated POST /mcp → 401 or 403 + WWW-Authenticate header
# ---------------------------------------------------------------------------

header "Step 1 — Unauthenticated request triggers auth challenge (401/403)"
info "POST $MCP_URL/mcp (no Authorization header)"

STEP1_RESP=$(curl -si --max-time 10 -X POST "$MCP_URL/mcp" \
  -H "Content-Type: application/json" \
  -d '{}' 2>/dev/null || true)
STEP1_CODE=$(echo "$STEP1_RESP" | grep "^HTTP" | awk '{print $2}')
WWW_AUTH=$(echo "$STEP1_RESP" | grep -i "^www-authenticate:" | tr -d '\r')

if [[ "$STEP1_CODE" == "401" || "$STEP1_CODE" == "403" ]]; then
  pass "HTTP $STEP1_CODE — auth challenge issued"
else
  fail "HTTP ${STEP1_CODE:-(no response)} (expected 401 or 403) — Istio not deployed? Steps 1-2 fail until Phase 2"
fi

if echo "$WWW_AUTH" | grep -q "resource_metadata"; then
  pass "WWW-Authenticate header present with resource_metadata"
  info "$WWW_AUTH"
else
  fail "WWW-Authenticate header missing or no resource_metadata (RFC 9728 §5) — Istio not deployed?"
  info "${WWW_AUTH:-(no header)}"
fi

# ---------------------------------------------------------------------------
# Step 2 — Extract resource_metadata URL from WWW-Authenticate
# ---------------------------------------------------------------------------

header "Step 2 — Parse resource_metadata URL from WWW-Authenticate"

METADATA_URL=$(echo "$WWW_AUTH" | grep -oP 'resource_metadata="\K[^"]+' || true)

if [[ -n "$METADATA_URL" && "$METADATA_URL" == http* ]]; then
  pass "resource_metadata URL extracted: $METADATA_URL"
else
  fail "resource_metadata URL not found or invalid (got: '${METADATA_URL:-empty}') — cannot proceed with discovery chain"
  info "Steps 3-6 will use fallback URL for continued testing"
  # Use well-known fallback path so remaining steps can still run
  METADATA_URL="${MCP_URL}/.well-known/oauth-protected-resource"
  info "Fallback URL: $METADATA_URL"
fi

# ---------------------------------------------------------------------------
# Step 3 — GET resource metadata document
# ---------------------------------------------------------------------------

header "Step 3 — Fetch OAuth Protected Resource document"
info "GET $METADATA_URL"

STEP3_CODE=$(curl -s -o /tmp/rfc9728_meta_body -w "%{http_code}" --max-time 10 \
  "$METADATA_URL" 2>/dev/null || echo "000")
META_BODY=$(cat /tmp/rfc9728_meta_body 2>/dev/null || echo "")

if [[ "$STEP3_CODE" == "200" ]]; then
  pass "HTTP 200 — resource metadata document returned"
else
  fail "HTTP ${STEP3_CODE} (expected 200)"
fi

AS_URL=$(echo "$META_BODY" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['authorization_servers'][0])" \
  2>/dev/null || true)

if [[ -n "$AS_URL" ]]; then
  pass "authorization_servers[0] present: $AS_URL"
else
  fail "authorization_servers array missing or empty in resource metadata document"
fi

SCOPES_OK=$(echo "$META_BODY" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('ok' if 'tools:classify.submit' in d.get('scopes_supported',[]) else 'missing')" \
  2>/dev/null || echo "missing")

if [[ "$SCOPES_OK" == "ok" ]]; then
  pass "scopes_supported contains tools:classify.submit"
else
  fail "scopes_supported missing tools:classify.submit"
fi

# ---------------------------------------------------------------------------
# Step 4 — GET OpenID Connect discovery document
# ---------------------------------------------------------------------------

header "Step 4 — Fetch OpenID Connect discovery document"

if [[ -z "$AS_URL" ]]; then
  fail "Step 4 skipped — AS_URL not available (step 3 failed)"
  FAILURES=$((FAILURES+1))
else
  OIDC_URL="${AS_URL}/.well-known/openid-configuration"
  info "GET $OIDC_URL"

  STEP4_CODE=$(curl -s -o /tmp/rfc9728_oidc_body -w "%{http_code}" --max-time 10 \
    "$OIDC_URL" 2>/dev/null || echo "000")
  OIDC_BODY=$(cat /tmp/rfc9728_oidc_body 2>/dev/null || echo "")

  if [[ "$STEP4_CODE" == "200" ]]; then
    pass "HTTP 200 — OIDC configuration document returned"
  else
    fail "HTTP ${STEP4_CODE} (expected 200)"
  fi

  TOKEN_ENDPOINT=$(echo "$OIDC_BODY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['token_endpoint'])" \
    2>/dev/null || true)
  ISSUER=$(echo "$OIDC_BODY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['issuer'])" \
    2>/dev/null || true)

  if [[ -n "$TOKEN_ENDPOINT" ]]; then
    pass "token_endpoint discovered: $TOKEN_ENDPOINT"
  else
    fail "token_endpoint field missing in OIDC configuration document"
  fi

  if [[ -n "$ISSUER" ]]; then
    pass "issuer present: $ISSUER"
  else
    fail "issuer field missing in OIDC configuration document"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Acquire token via client credentials at discovered token_endpoint
# ---------------------------------------------------------------------------

header "Step 5 — Acquire token via discovered token_endpoint"

if [[ -z "${TOKEN_ENDPOINT:-}" ]]; then
  fail "Step 5 skipped — token_endpoint not available (step 4 failed)"
  ACCESS_TOKEN=""
else
  info "POST $TOKEN_ENDPOINT"
  info "grant_type=client_credentials  client_id=$CLIENT_ID  scope=$SCOPE"

  STEP5_CODE=$(curl -s -o /tmp/rfc9728_token_body -w "%{http_code}" --max-time 10 \
    -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=${SCOPE}" \
    2>/dev/null || echo "000")
  TOKEN_BODY=$(cat /tmp/rfc9728_token_body 2>/dev/null || echo "")

  if [[ "$STEP5_CODE" == "200" ]]; then
    pass "HTTP 200 — token endpoint responded"
  else
    fail "HTTP ${STEP5_CODE} (expected 200)"
  fi

  ACCESS_TOKEN=$(echo "$TOKEN_BODY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['access_token'])" \
    2>/dev/null || true)

  if [[ -n "$ACCESS_TOKEN" ]]; then
    pass "access_token present in response"
  else
    fail "access_token missing from token response"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6 — POST /mcp with discovered token → 200
# ---------------------------------------------------------------------------

header "Step 6 — Authenticated request succeeds using discovered token"

if [[ -z "${ACCESS_TOKEN:-}" ]]; then
  fail "Step 6 skipped — access_token not available (step 5 failed)"
else
  info "POST $MCP_URL/mcp  Authorization: Bearer <token>"

  STEP6_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"rfc9728-test","version":"1.0"}},"id":1}' \
    "$MCP_URL/mcp" 2>/dev/null || echo "000")

  if [[ "$STEP6_CODE" == "200" ]]; then
    pass "HTTP 200 — authenticated request accepted, MCP session opened"
  else
    fail "HTTP ${STEP6_CODE} (expected 200)"
  fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo ""
if [[ $FAILURES -eq 0 ]]; then
  printf '\033[32m\033[1mAll 6 RFC 9728 discovery chain steps passed\033[0m\n'
else
  printf '\033[31m\033[1m%d step(s) failed\033[0m\n' "$FAILURES"
  if [[ $FAILURES -le 2 ]]; then
    printf '\033[2m(Steps 1-2 are expected to fail until Phase 2 Istio deployment — BP-029)\033[0m\n'
  fi
  exit 1
fi
