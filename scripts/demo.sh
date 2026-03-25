#!/usr/bin/env bash
# Demo script for the mcp-presidio-sensitivity local stack.
#
# Usage:
#   ./scripts/demo.sh          # interactive menu
#   ./scripts/demo.sh <number> # run a specific demo directly
#   ./scripts/demo.sh a        # run all demos in sequence

set -euo pipefail

WORKER="http://localhost:8090"
MCP="http://localhost:8000"
KEYCLOAK="http://localhost:8080/realms/mcp-local"
CLIENT_ID="test-agent-client"
CLIENT_SECRET="test-agent-secret-change-in-prod"

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

header()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
label()   { echo -e "${DIM}$*${RESET}"; }
success() { echo -e "${GREEN}✔  $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠  $*${RESET}"; }
fail()    { echo -e "${RED}✘  $*${RESET}"; }

pretty_json() { python3 -m json.tool 2>/dev/null || cat; }

pause() { echo -e "\n${DIM}Press Enter to continue...${RESET}"; read -r; }

check_stack() {
  local ok=true
  curl -sf "$WORKER/health" &>/dev/null  || { fail "Worker not reachable at $WORKER — run ./scripts/setup-local.sh"; ok=false; }
  curl -sf "$MCP/health" &>/dev/null     || { fail "MCP server not reachable at $MCP — run ./scripts/setup-local.sh"; ok=false; }
  curl -sf "$KEYCLOAK/.well-known/openid-configuration" &>/dev/null \
    || { fail "Keycloak not reachable at $KEYCLOAK — run ./scripts/setup-local.sh"; ok=false; }
  [[ "$ok" == "true" ]] || exit 1
  echo -e "${GREEN}Stack is up — worker, MCP server, Keycloak all healthy${RESET}"
}

# Acquire a token for subsequent demos
get_token() {
  local scope="${1:-tools:classify.submit}"
  curl -sf -X POST "$KEYCLOAK/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&scope=$scope" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# Open an MCP session and return the session ID
open_mcp_session() {
  local token="$1"
  curl -sf -D - \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}},"id":1}' \
    "$MCP/mcp/mcp" 2>&1 | grep -i "mcp-session-id:" | tr -d '\r' | awk '{print $2}'
}

# Call classify_payload_sensitivity via MCP and print formatted result
mcp_classify() {
  local token="$1" session="$2" text="$3"
  local escaped
  escaped=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1]))" "$text" | sed 's/^"//;s/"$//')
  curl -s \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $session" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"classify_payload_sensitivity\",\"arguments\":{\"content\":\"$escaped\",\"content_type\":\"text/plain\"}},\"id\":2}" \
    "$MCP/mcp/mcp" | python3 -c "
import sys,json,re
raw=sys.stdin.read()
m=re.search(r'data: (.+)', raw)
if m:
  r=json.loads(m.group(1))['result']['structuredContent']
  d=r['decision']; s=r['max_severity_band']
  cats=r['matched_categories']; ents=r['entity_summary']
  colour='\033[0;31m' if d=='block' else '\033[0;33m' if d=='flag' else '\033[0;32m'
  reset='\033[0m'
  print(f'  Decision  : {colour}{d}{reset}')
  print(f'  Severity  : {s}')
  print(f'  Categories: {cats}')
  print(f'  Entities  : {ents}')
  print(f'  Scan ID   : {r[\"scan_id\"]}')
"
}

# ---------------------------------------------------------------------------
# Auth demos
# ---------------------------------------------------------------------------

demo_auth() {
  header "Auth boundary — 401 / 403 / 200"
  label "Shows the three auth outcomes the MCP server enforces."
  echo ""

  printf "  No token        → "
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MCP/mcp/mcp")
  [[ "$CODE" == "401" ]] && success "HTTP $CODE — Unauthorised" || fail "HTTP $CODE (expected 401)"

  printf "  Garbage token   → "
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer not.a.real.token" "$MCP/mcp/mcp")
  [[ "$CODE" == "401" ]] && success "HTTP $CODE — Unauthorised" || fail "HTTP $CODE (expected 401)"

  printf "  Wrong scope     → "
  WRONG_TOKEN=$(get_token "tools:health.read")  # valid token, but missing tools:classify.submit
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $WRONG_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}},"id":1}' \
    "$MCP/mcp/mcp")
  [[ "$CODE" == "403" ]] && success "HTTP $CODE — Forbidden (insufficient scope)" || fail "HTTP $CODE (expected 403)"

  printf "  Correct scope   → "
  GOOD_TOKEN=$(get_token "tools:classify.submit")
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $GOOD_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}},"id":1}' \
    "$MCP/mcp/mcp")
  [[ "$CODE" == "200" ]] && success "HTTP $CODE — session opened" || fail "HTTP $CODE (expected 200)"

  printf "  /health no auth → "
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MCP/health")
  [[ "$CODE" == "200" ]] && success "HTTP $CODE — liveness probe works unauthenticated" || fail "HTTP $CODE (expected 200)"
}

# ---------------------------------------------------------------------------
# Token demo
# ---------------------------------------------------------------------------

demo_token() {
  header "Keycloak token issuance"
  label "Agent requests a signed JWT using the client credentials grant."
  label "The token includes aud:mcp-presidio-server and scope:tools:classify.submit."
  echo ""

  RESPONSE=$(curl -sf -X POST "$KEYCLOAK/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&scope=tools:classify.submit")

  label "Token metadata:"
  echo "$RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps({k:v for k,v in d.items() if k!='access_token'}, indent=2))
"
  echo ""
  label "Decoded claims:"
  echo "$RESPONSE" | python3 -c "
import sys,base64,json
token=json.load(sys.stdin)['access_token']
payload=token.split('.')[1]
payload+='='*(4-len(payload)%4)
claims=json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps(claims, indent=2))
"
}

# ---------------------------------------------------------------------------
# Detection demos (via MCP tool — full end-to-end path)
# ---------------------------------------------------------------------------

_acquire() {
  TOKEN=$(get_token "tools:classify.submit")
  SESSION=$(open_mcp_session "$TOKEN")
}

demo_1() {
  header "Demo 1 — Credit card detected and blocked"
  label "Payment message containing a Luhn-valid test card number."
  label "Expected: financial_identifier, severity high, decision block."
  echo ""
  _acquire
  mcp_classify "$TOKEN" "$SESSION" "Please process payment for card 4111111111111111 expiry 12/28"
}

demo_2() {
  header "Demo 2 — Name, email and phone"
  label "Contact record with person name, email address and phone number."
  label "Expected: direct_identifier + contact_data, severity high, decision block."
  echo ""
  _acquire
  mcp_classify "$TOKEN" "$SESSION" "Call Jane Testperson on 555-867-5309 or email jane@example.com"
}

demo_3() {
  header "Demo 3 — US SSN detected"
  label "Message containing a syntactically valid SSN."
  label "Expected: government_identifier, severity high, decision block."
  echo ""
  _acquire
  mcp_classify "$TOKEN" "$SESSION" "Employee records updated. SSN on file: 234-56-7890."
}

demo_4() {
  header "Demo 4 — Clean business text"
  label "Generic business memo with no personal data."
  label "Expected: sensitivity_detected false, decision allow."
  echo ""
  _acquire
  mcp_classify "$TOKEN" "$SESSION" "The revenue target was exceeded by 14%. The operations team has confirmed capacity is sufficient."
}

demo_5() {
  header "Demo 5 — Date-only text (Phase 1 calibration)"
  label "Text with dates but no personal identifiers."
  label "Expected: flag/medium — dates are contextually ambiguous, not a block."
  label "Previously this incorrectly returned block/high (fixed in Phase 1)."
  echo ""
  _acquire
  mcp_classify "$TOKEN" "$SESSION" "The meeting is next Tuesday, March 31st. Quarterly review is due in April."
}

demo_6() {
  header "Demo 6 — Rich payload (4+ entity types)"
  label "A paragraph containing a name, SSN, credit card, and email."
  label "Expected: multiple categories, severity high, decision block."
  echo ""
  _acquire
  mcp_classify "$TOKEN" "$SESSION" "Dear John Synthetic, your account review is complete. SSN 234-56-7890, card 4111111111111111, contact john@test.example."
}

demo_7() {
  header "Demo 7 — Oversized payload rejected"
  label "Payload just over the 1MB limit sent directly to the worker."
  label "Expected: HTTP 413 PAYLOAD_TOO_LARGE, no scan performed."
  echo ""
  python3 -c "
import json, urllib.request, urllib.error
payload = json.dumps({'content': 'x' * 1_048_577, 'content_type': 'text/plain', 'language': 'en', 'request_metadata': {'workflow_id': 'test', 'source_system': 'demo'}}).encode()
req = urllib.request.Request('$WORKER/scan', data=payload, headers={'Content-Type': 'application/json'}, method='POST')
try:
    urllib.request.urlopen(req)
except urllib.error.HTTPError as e:
    import json as j
    print('  HTTP', e.code)
    body = j.loads(e.read())
    print('  error_code:', body.get('error_code'))
    print('  message   :', body.get('message'))
"
}

demo_8() {
  header "Demo 8 — Unsupported content type rejected"
  label "Sending XML instead of text/plain or application/json to the worker."
  label "Expected: HTTP 415 UNSUPPORTED_CONTENT_TYPE, no scan performed."
  echo ""
  python3 -c "
import urllib.request, urllib.error, json
req = urllib.request.Request('$WORKER/scan', data=b'<data>test</data>', headers={'Content-Type': 'application/xml'}, method='POST')
try:
    urllib.request.urlopen(req)
except urllib.error.HTTPError as e:
    body = json.loads(e.read())
    print('  HTTP', e.code)
    print('  error_code:', body.get('error_code'))
    print('  message   :', body.get('message'))
"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

show_menu() {
  echo -e "${BOLD}mcp-presidio-sensitivity demo${RESET}"
  echo -e "${DIM}worker: $WORKER  |  mcp: $MCP  |  keycloak: $KEYCLOAK${RESET}"
  echo ""
  echo -e "${BOLD}Auth${RESET}"
  echo "  0  Auth boundary — 401 / 403 / 200"
  echo "  t  Token issuance and decoded claims"
  echo ""
  echo -e "${BOLD}Detection (full MCP path — Keycloak → MCP → worker)${RESET}"
  echo "  1  Credit card detected and blocked"
  echo "  2  Name + email + phone"
  echo "  3  US SSN detected"
  echo "  4  Clean business text → allow"
  echo "  5  Date-only text → flag (not block — Phase 1 fix)"
  echo "  6  Rich payload — 4+ entity types"
  echo ""
  echo -e "${BOLD}Enforcement (direct to worker)${RESET}"
  echo "  7  Oversized payload rejected (>1MB)"
  echo "  8  Unsupported content type rejected"
  echo ""
  echo "  a  Run all demos in sequence"
  echo "  q  Quit"
  echo ""
}

run_demo() {
  case "$1" in
    0|auth) demo_auth ;;
    t|token) demo_token ;;
    1) demo_1 ;;
    2) demo_2 ;;
    3) demo_3 ;;
    4) demo_4 ;;
    5) demo_5 ;;
    6) demo_6 ;;
    7) demo_7 ;;
    8) demo_8 ;;
    *) warn "Unknown demo: $1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

check_stack

if [[ $# -gt 0 && "$1" != "a" ]]; then
  run_demo "$1"
  exit 0
fi

if [[ $# -gt 0 && "$1" == "a" ]]; then
  for d in auth token 1 2 3 4 5 6 7 8; do
    run_demo "$d"
    pause
  done
  exit 0
fi

while true; do
  echo ""
  show_menu
  printf "Choose: "
  read -r choice
  case "$choice" in
    [0-9]|t|token|auth) run_demo "$choice" ;;
    a)
      for d in auth token 1 2 3 4 5 6 7 8; do
        run_demo "$d"
        pause
      done
      ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) warn "Enter a number 0–8, 't', 'a' for all, or 'q' to quit." ;;
  esac
done
