#!/usr/bin/env bash
# Classify a text payload through the full MCP path.
#
# Performs the RFC 9728 discovery chain starting from the MCP URL only —
# no Keycloak URL required. Acquires a token, opens an MCP session, calls
# classify_payload_sensitivity, and prints the full structured result.
#
# Modes:
#   Default   — service health map, inline step progress, full result
#   --learn   — adds request/response detail and lifecycle notes per step
#
# When to use:
#   Any time you want to send a payload and see the full classification
#   response. Follows the same path a compliant agent client would take.
#
# Usage:
#   ./scripts/classify.sh "text to classify"
#   ./scripts/classify.sh path/to/file.txt
#   ./scripts/classify.sh /absolute/path/to/file.txt
#   ./scripts/classify.sh --learn "text to classify"
#   echo "some text" | ./scripts/classify.sh [--learn]
#
# Prerequisites:
#   - Stack healthy (run ./scripts/status.sh first)

set -euo pipefail

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

LEARN=false
if [[ "${1:-}" == "--learn" ]]; then
  LEARN=true
  shift
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

MCP="http://localhost:8000"
WORKER="http://localhost:8090"
KEYCLOAK_BASE="http://localhost:8080"
REALM="mcp-local"
CLIENT_ID="test-agent-client"
CLIENT_SECRET="test-agent-secret-change-in-prod"

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

abort() { printf "${RED}error:${RESET} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Payload — file path, inline argument, or stdin
# ---------------------------------------------------------------------------

SOURCE_LABEL=""
if [[ $# -eq 1 && -f "$1" ]]; then
  FILE_PATH=$(realpath "$1")
  PAYLOAD=$(< "$FILE_PATH") || abort "Could not read file: $1"
  SOURCE_LABEL="  Source:    $FILE_PATH"
elif [[ $# -gt 0 ]]; then
  PAYLOAD="$*"
else
  if [[ -t 0 ]]; then
    abort 'No payload. Usage: ./scripts/classify.sh [--learn] "text to classify"'
  fi
  PAYLOAD=$(cat)
fi
[[ -z "$PAYLOAD" ]] && abort "Payload is empty."
CHAR_COUNT=${#PAYLOAD}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

echo ""
if $LEARN; then
  echo -e "${BOLD}classify_payload_sensitivity${RESET}  (${CHAR_COUNT} chars)  ${DIM}[learn mode]${RESET}"
else
  echo -e "${BOLD}classify_payload_sensitivity${RESET}  (${CHAR_COUNT} chars)"
fi
[[ -n "$SOURCE_LABEL" ]] && echo -e "${DIM}${SOURCE_LABEL}${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Service health map
# ---------------------------------------------------------------------------

MCP_UP=false; KEYCLOAK_UP=false; WORKER_UP=false
curl -sf --max-time 3 "$MCP/health"                                                       &>/dev/null && MCP_UP=true      || true
curl -sf --max-time 3 "${KEYCLOAK_BASE}/realms/${REALM}/.well-known/openid-configuration" &>/dev/null && KEYCLOAK_UP=true || true
curl -sf --max-time 3 "$WORKER/health"                                                    &>/dev/null && WORKER_UP=true   || true

dot() {
  if "$1"; then printf "${GREEN}●${RESET}"; else printf "${RED}○${RESET}"; fi
}

printf "  Services:  "
dot "$MCP_UP";      printf "  MCP Server       "
dot "$KEYCLOAK_UP"; printf "  Keycloak         "
dot "$WORKER_UP";   printf "  Presidio Worker\n"
echo ""

"$MCP_UP"      || abort "MCP Server is not reachable. Run ./scripts/status.sh."
"$KEYCLOAK_UP" || abort "Keycloak is not reachable. Run ./scripts/status.sh."
# Worker is NetworkPolicy-restricted (DEC-001): not reachable from host by design.
# classify.sh communicates with the MCP server only; the MCP server routes to the worker
# internally. Worker status shown above is informational; absence does not block classification.

# ---------------------------------------------------------------------------
# Step helpers
# ---------------------------------------------------------------------------
#
# Default mode: one line per step, overwrites "..." with ✔ on completion.
# Learn mode:   step header block, then request → response → lifecycle note.

STEP=0
_SVC=""
_LBL=""

step_begin() {
  STEP=$(( STEP + 1 ))
  _SVC="$1"
  _LBL="$2"
  if ! $LEARN; then
    printf "  ${DIM}Step %d${RESET}  %-16s  %s ..." "$STEP" "$_SVC" "$_LBL"
  else
    local title="${3:-$_LBL}"
    printf "\n  ${BOLD}Step %d · %s${RESET}  ${DIM}[%s]${RESET}\n" "$STEP" "$title" "$_SVC"
    printf "  %s\n" "--------------------------------------------------------"
  fi
}

step_req() {
  if $LEARN; then printf "     ${DIM}→ %s${RESET}\n" "$*"; fi
}

step_res() {
  if $LEARN; then printf "     ${DIM}← %s${RESET}\n" "$*"; fi
}

step_note() {
  if $LEARN; then printf "     ${DIM}Lifecycle: %s${RESET}\n" "$*"; fi
}

step_done() {
  if ! $LEARN; then
    printf "\r  ${DIM}Step %d${RESET}  %-16s  %-36s ${GREEN}✔${RESET}  ${DIM}%s${RESET}\n" \
      "$STEP" "$_SVC" "$_LBL" "$1"
  else
    printf "  ${GREEN}✔${RESET}  ${DIM}%s${RESET}\n" "$1"
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — Discover resource_metadata URL from 401 WWW-Authenticate
# ---------------------------------------------------------------------------

step_begin "MCP Server" "Discovering auth chain" "Discovery"
step_req   "POST $MCP/mcp (no token)"

FULL_RESP=$(curl -si --max-time 10 -X POST "$MCP/mcp" \
  -H "Content-Type: application/json" -d '{}' 2>/dev/null)
WWW_AUTH=$(echo "$FULL_RESP" | grep -i "^www-authenticate:" | tr -d '\r')
RESOURCE_META_RAW=$(echo "$WWW_AUTH" | python3 -c "
import sys, re
m = re.search(r'resource_metadata=\"([^\"]+)\"', sys.stdin.read())
print(m.group(1) if m else '')
" 2>/dev/null)

[[ -z "$RESOURCE_META_RAW" ]] && \
  abort "MCP server did not return resource_metadata in WWW-Authenticate."

# The server advertises its internal cluster DNS name. Rebase the path onto
# the known localhost MCP URL so the script can reach it from outside the cluster.
META_PATH=$(python3 -c \
  "import sys; from urllib.parse import urlparse; print(urlparse(sys.argv[1]).path)" \
  "$RESOURCE_META_RAW")
RESOURCE_META_URL="${MCP}${META_PATH}"

step_res  "401  $(echo "$WWW_AUTH" | sed 's/^[Ww][Ww][Ww]-[Aa]uthenticate: //')"
step_note "response header only — no state created"
step_note "(dev: resource_metadata URL rebased from cluster-internal address to $MCP)"
step_done "ephemeral — no state created"

# ---------------------------------------------------------------------------
# Step 2 — Fetch resource metadata → authorization server URL
# ---------------------------------------------------------------------------

step_begin "MCP Server" "Fetching resource metadata" "Resource Metadata"
step_req   "GET $RESOURCE_META_URL"

META_DOC=$(curl -sf --max-time 10 "$RESOURCE_META_URL" 2>/dev/null) || \
  abort "Could not fetch resource metadata from $RESOURCE_META_URL"

AS_URL=$(echo "$META_DOC" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['authorization_servers'][0])")
SCOPES=$(echo "$META_DOC" | python3 -c \
  "import sys,json; print(', '.join(json.load(sys.stdin).get('scopes_supported', ['?'])))")

step_res  "authorization_servers[0]: $AS_URL"
step_res  "scopes_supported: $SCOPES"
step_note "static config document — no state created"
step_done "ephemeral — no state created"

# ---------------------------------------------------------------------------
# Step 3 — OIDC discovery → token endpoint
# ---------------------------------------------------------------------------

step_begin "Keycloak" "Fetching OIDC config" "OIDC Discovery"
step_req   "GET ${AS_URL}/.well-known/openid-configuration"

OIDC_DOC=$(curl -sf --max-time 10 "${AS_URL}/.well-known/openid-configuration" 2>/dev/null) || \
  abort "Could not reach authorization server at $AS_URL"

TOKEN_ENDPOINT=$(echo "$OIDC_DOC" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['token_endpoint'])")
ISSUER=$(echo "$OIDC_DOC" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['issuer'])")

step_res  "issuer: $ISSUER"
step_res  "token_endpoint: $TOKEN_ENDPOINT"
step_note "static config document — no state created"
step_done "ephemeral — no state created"

# ---------------------------------------------------------------------------
# Step 4 — Acquire token
# ---------------------------------------------------------------------------

step_begin "Keycloak" "Acquiring token" "Token Acquisition"
step_req   "POST $TOKEN_ENDPOINT"
step_req   "grant_type=client_credentials  scope=tools:classify.submit"

TOKEN_RESP=$(curl -sf --max-time 10 -X POST "$TOKEN_ENDPOINT" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=tools:classify.submit" \
  2>/dev/null) || abort "Could not acquire token from $TOKEN_ENDPOINT"

ACCESS_TOKEN=$(echo "$TOKEN_RESP" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['access_token'])")
EXPIRES_IN=$(echo "$TOKEN_RESP" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('expires_in','?'))")
SUBJECT=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys, base64, json
token = sys.stdin.read().strip()
payload = token.split('.')[1] + '=' * (-len(token.split('.')[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(claims.get('sub', '?'))
")

step_res  "JWT  expires_in=${EXPIRES_IN}s  sub=$SUBJECT"
step_note "ephemeral — ${EXPIRES_IN}s TTL (DEC-002), no server-side session, no revocation endpoint"
step_done "ephemeral — ${EXPIRES_IN}s TTL"

# ---------------------------------------------------------------------------
# Step 5 — Open MCP session
# ---------------------------------------------------------------------------

step_begin "MCP Server" "Opening MCP session" "MCP Session"
step_req   "POST $MCP/mcp  method=initialize  protocolVersion=2024-11-05"

SESSION=$(curl -sf -D - --max-time 10 \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"classify","version":"1.0"}},"id":1}' \
  "$MCP/mcp" 2>/dev/null \
  | grep -i "mcp-session-id:" | tr -d '\r' | awk '{print $2}')

[[ -z "$SESSION" ]] && abort "Could not open MCP session — check server logs."

step_res  "mcp-session-id: $SESSION"
step_note "ephemeral — in-memory only, lost on pod restart"
step_done "ephemeral — in-memory session"

# ---------------------------------------------------------------------------
# Step 6 — Call classify_payload_sensitivity
# ---------------------------------------------------------------------------

step_begin "MCP → Worker" "Classifying payload" "Classification"
step_req   "POST $MCP/mcp  tools/call  classify_payload_sensitivity"
step_req   "Worker: POST /scan (internal, NetworkPolicy enforced, no token)"

ESCAPED=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1]))" "$PAYLOAD" \
  | sed 's/^"//;s/"$//')

RESULT=$(curl -s --max-time 30 \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-session-id: $SESSION" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"classify_payload_sensitivity\",\"arguments\":{\"content\":\"${ESCAPED}\",\"content_type\":\"text/plain\"}},\"id\":2}" \
  "$MCP/mcp" 2>/dev/null)

SCAN_DECISION=$(echo "$RESULT" | python3 -c "
import sys, json, re
m = re.search(r'data: (.+)', sys.stdin.read())
if m:
    r = json.loads(m.group(1))['result']['structuredContent']
    print(r.get('decision','?'), r.get('scan_id','?'))
" 2>/dev/null || echo "? ?")

step_res  "bounded result — decision: $(echo "$SCAN_DECISION" | awk '{print $1}')  scan_id: $(echo "$SCAN_DECISION" | awk '{print $2}')"
step_note "ephemeral — payload never written to disk, no audit store yet (Phase 1 Stream 2)"
step_done "ephemeral — no persistence"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Result${RESET}"

echo "$RESULT" | python3 -c "
import sys, json, re

raw = sys.stdin.read()
m = re.search(r'data: (.+)', raw)
if not m:
    print('error: no result in MCP response', file=sys.stderr)
    print('raw:', raw, file=sys.stderr)
    sys.exit(1)

r = json.loads(m.group(1))['result']['structuredContent']

decision  = r.get('decision', '?')
severity  = r.get('max_severity_band', '?')
detected  = r.get('sensitivity_detected', False)
categories = r.get('matched_categories', [])
entities  = r.get('entity_summary', {})
findings  = r.get('findings_count', 0)
scan_id   = r.get('scan_id', '?')

colour = '\033[0;31m' if decision == 'block' else '\033[0;33m' if decision == 'flag' else '\033[0;32m'
bold  = '\033[1m'
dim   = '\033[2m'
reset = '\033[0m'

print(f'  Decision:   {colour}{bold}{decision.upper()}{reset}')
print(f'  Severity:   {severity}')
print(f'  Detected:   {detected}')
print(f'  Findings:   {findings}')
print(f'  Categories: {categories}')
print(f'  Entities:   {json.dumps(entities)}')
print(f'  Scan ID:    {scan_id}')
print()
print(f'{dim}Full structured content:{reset}')
print(json.dumps(r, indent=2))
"
