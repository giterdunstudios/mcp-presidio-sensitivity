#!/usr/bin/env bash
# Demo script for the mcp-presidio local stack.
# Shows what the stack can currently do with live API calls.
#
# Usage:
#   ./scripts/demo.sh          # interactive menu
#   ./scripts/demo.sh <number> # run a specific demo directly

set -euo pipefail

# Re-exec with docker group if needed (required on WSL2)
if ! groups | grep -qw docker; then
  exec sg docker -c "bash $0 $*"
fi

WORKER="http://localhost:8080"
HYDRA_PUBLIC="http://localhost:4444"
HYDRA_ADMIN="http://localhost:4445"

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
error()   { echo -e "${RED}✘  $*${RESET}"; }

pretty_json() { python3 -m json.tool 2>/dev/null || cat; }

show_request() {
  echo -e "${DIM}Request:${RESET}"
  echo -e "${DIM}  $*${RESET}"
  echo ""
}

pause() { echo -e "\n${DIM}Press Enter to continue...${RESET}"; read -r; }

check_stack() {
  if ! curl -sf "$WORKER/health" &>/dev/null; then
    error "Presidio worker is not reachable at $WORKER"
    echo "Run ./scripts/setup-local.sh to start the stack."
    exit 1
  fi
  if ! curl -sf "$HYDRA_ADMIN/health/ready" &>/dev/null; then
    error "Hydra is not reachable at $HYDRA_ADMIN"
    echo "Run ./scripts/setup-local.sh to start the stack."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Demo functions
# ---------------------------------------------------------------------------

demo_1() {
  header "Demo 1 — Credit card detected and blocked"
  label "A payment message containing a Luhn-valid test card number."
  label "Expected: financial_identifier detected, severity high, decision block."
  echo ""

  PAYLOAD='{"content": "Please process payment for card 4111111111111111 expiry 12/28", "content_type": "text/plain"}'
  show_request "POST $WORKER/scan"
  echo "$PAYLOAD" | pretty_json
  echo ""
  label "Response:"
  curl -sf -X POST "$WORKER/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | pretty_json
}

demo_2() {
  header "Demo 2 — Name, email and phone flagged together"
  label "A contact record containing a person name, email and phone number."
  label "Expected: direct_identifier + contact_data, severity high, decision block."
  echo ""

  PAYLOAD='{"content": "Call Jane Testperson on 555-867-5309 or email jane@example.com", "content_type": "text/plain"}'
  show_request "POST $WORKER/scan"
  echo "$PAYLOAD" | pretty_json
  echo ""
  label "Response:"
  curl -sf -X POST "$WORKER/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | pretty_json
}

demo_3() {
  header "Demo 3 — US SSN detected"
  label "A message containing an IRS-reserved (invalid) SSN."
  label "Expected: government_identifier detected, severity high, decision block."
  echo ""

  PAYLOAD='{"content": "Employee records updated. SSN on file: 999-99-9999.", "content_type": "text/plain"}'
  show_request "POST $WORKER/scan"
  echo "$PAYLOAD" | pretty_json
  echo ""
  label "Response:"
  curl -sf -X POST "$WORKER/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | pretty_json
}

demo_4() {
  header "Demo 4 — Clean text returns allow"
  label "A generic business memo with no personal data, dates, or names."
  label "Expected: sensitivity_detected false, no categories, decision allow."
  label "Note: DATE_TIME is classified as direct_identifier (high severity)."
  label "Even innocent date references like 'next month' will trigger a block."
  label "This is a known false positive — severity mapping is a Phase 1 calibration task."
  echo ""

  PAYLOAD='{"content": "The revenue target was exceeded by 14%. The operations team has confirmed capacity is sufficient.", "content_type": "text/plain"}'
  show_request "POST $WORKER/scan"
  echo "$PAYLOAD" | pretty_json
  echo ""
  label "Response:"
  curl -sf -X POST "$WORKER/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | pretty_json
}

demo_5() {
  header "Demo 5 — Rich payload with 4+ entity types"
  label "A paragraph containing a name, SSN, credit card, and email."
  label "Expected: multiple categories, severity high, decision block."
  echo ""

  PAYLOAD='{"content": "Dear John Synthetic, your account review is complete. SSN 999-12-3456, card 4111111111111111, contact john@test.example.", "content_type": "text/plain"}'
  show_request "POST $WORKER/scan"
  echo "$PAYLOAD" | pretty_json
  echo ""
  label "Response:"
  curl -sf -X POST "$WORKER/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | pretty_json
}

demo_6() {
  header "Demo 6 — Oversized payload rejected"
  label "A payload just over the 1MB limit."
  label "Expected: HTTP 413 PAYLOAD_TOO_LARGE, no scan performed."
  echo ""

  show_request "POST $WORKER/scan  (payload: 1MB + 1 byte)"
  RESULT=$(python3 -c "
import json, urllib.request, urllib.error
payload = json.dumps({'content': 'x' * 1_048_577, 'content_type': 'text/plain'}).encode()
req = urllib.request.Request('$WORKER/scan', data=payload, headers={'Content-Type': 'application/json'}, method='POST')
try:
    urllib.request.urlopen(req)
except urllib.error.HTTPError as e:
    print('HTTP', e.code)
    print(e.read().decode())
")
  echo "$RESULT" | head -1
  echo "$RESULT" | tail -n +2 | pretty_json
}

demo_7() {
  header "Demo 7 — Unsupported content type rejected"
  label "Sending XML instead of text/plain or application/json."
  label "Expected: HTTP 415 UNSUPPORTED_CONTENT_TYPE, no scan performed."
  echo ""

  show_request "POST $WORKER/scan  (Content-Type: application/xml)"
  curl -sf -X POST "$WORKER/scan" \
    -H "Content-Type: application/xml" \
    -d "<data>test</data>" | pretty_json || \
  curl -s -X POST "$WORKER/scan" \
    -H "Content-Type: application/xml" \
    -d "<data>test</data>" | pretty_json
}

demo_8() {
  header "Demo 8 — OAuth token issuance"
  label "An agent requests a signed JWT using client credentials."
  label "Expected: RS256 JWT with correct iss, aud, scope, and exp claims."
  echo ""

  show_request "POST $HYDRA_PUBLIC/oauth2/token  (client_credentials grant)"
  RESPONSE=$(curl -sf -X POST "$HYDRA_PUBLIC/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=test-agent-client&client_secret=test-agent-secret-change-in-prod&scope=tools:classify.submit&audience=mcp-presidio-server")

  TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

  label "Token metadata:"
  echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps({k: v for k, v in d.items() if k != 'access_token'}, indent=2))
"
  echo ""
  label "Decoded claims:"
  echo "$TOKEN" | python3 -c "
import sys, base64, json
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps(claims, indent=2))
"
}

demo_9() {
  header "Demo 9 — Wrong scope rejected by Hydra"
  label "An agent requests a token with a scope it is not authorised for."
  label "Expected: error response from Hydra — scope not permitted."
  echo ""

  show_request "POST $HYDRA_PUBLIC/oauth2/token  (scope: tools:admin)"
  curl -s -X POST "$HYDRA_PUBLIC/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=test-agent-client&client_secret=test-agent-secret-change-in-prod&scope=tools:admin" | pretty_json
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

show_menu() {
  echo -e "${BOLD}mcp-presidio demo${RESET}  —  local stack at $WORKER"
  echo ""
  echo -e "${BOLD}Detection demos${RESET}"
  echo "  1  Credit card detected and blocked"
  echo "  2  Name + email + phone detected together"
  echo "  3  US SSN detected"
  echo "  4  Clean text returns allow"
  echo "  5  Rich payload — 4+ entity types"
  echo ""
  echo -e "${BOLD}Enforcement demos${RESET}"
  echo "  6  Oversized payload rejected (>1MB)"
  echo "  7  Unsupported content type rejected"
  echo ""
  echo -e "${BOLD}Auth demos${RESET}"
  echo "  8  OAuth token issuance (client credentials)"
  echo "  9  Wrong scope rejected by Hydra"
  echo ""
  echo "  a  Run all demos in sequence"
  echo "  q  Quit"
  echo ""
}

run_demo() {
  case "$1" in
    1) demo_1 ;;
    2) demo_2 ;;
    3) demo_3 ;;
    4) demo_4 ;;
    5) demo_5 ;;
    6) demo_6 ;;
    7) demo_7 ;;
    8) demo_8 ;;
    9) demo_9 ;;
    *) warn "Unknown demo: $1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

check_stack

# Non-interactive: run a specific demo and exit
if [[ $# -gt 0 && "$1" != "a" ]]; then
  run_demo "$1"
  exit 0
fi

# Run all
if [[ $# -gt 0 && "$1" == "a" ]]; then
  for i in 1 2 3 4 5 6 7 8 9; do
    run_demo "$i"
    pause
  done
  exit 0
fi

# Interactive menu
while true; do
  echo ""
  show_menu
  echo -n "Choose: "
  read -r choice

  case "$choice" in
    [1-9]) run_demo "$choice" ;;
    a)
      for i in 1 2 3 4 5 6 7 8 9; do
        run_demo "$i"
        pause
      done
      ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) warn "Enter a number 1–9, 'a' for all, or 'q' to quit." ;;
  esac
done
