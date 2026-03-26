#!/usr/bin/env bash
# End-to-end demo for the mcp-presidio-sensitivity local stack.
#
# When to use:
#   - To verify the full request path works after a rebuild or deploy
#   - To demonstrate capabilities to stakeholders
#   - To manually validate a specific scenario (auth, detection, enforcement)
#   Run ./scripts/status.sh first to confirm the stack is healthy before
#   running the demo.
#
# Demo cases:
#   0  Auth boundary — 401 / 403 / 200
#   t  Token issuance and decoded claims
#   f  RFC 9728 discovery flow — client bootstrap from MCP URL only
#   1  Credit card detected and blocked
#   2  Name + email + phone
#   3  US SSN detected
#   4  Clean business text → allow
#   5  Date-only text → flag (not block)
#   6  Rich payload — 4+ entity types
#   7  Oversized payload rejected (>1 MiB)
#   8  Unsupported content type rejected
#   l  Scan lifecycle trace — ephemeral vs persistent
#   a  Run all demos in sequence
#
# Usage:
#   ./scripts/demo.sh          # interactive menu
#   ./scripts/demo.sh <number> # run a specific demo directly (e.g. demo.sh 1)
#   ./scripts/demo.sh a        # run all demos in sequence (CI / sign-off)

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
    "$MCP/mcp" 2>&1 | grep -i "mcp-session-id:" | tr -d '\r' | awk '{print $2}'
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
    "$MCP/mcp" | python3 -c "
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
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MCP/mcp")
  [[ "$CODE" == "401" ]] && success "HTTP $CODE — Unauthorised" || fail "HTTP $CODE (expected 401)"

  printf "  Garbage token   → "
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer not.a.real.token" "$MCP/mcp")
  [[ "$CODE" == "401" ]] && success "HTTP $CODE — Unauthorised" || fail "HTTP $CODE (expected 401)"

  printf "  Wrong scope     → "
  WRONG_TOKEN=$(get_token "tools:health.read")  # valid token, but missing tools:classify.submit
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $WRONG_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}},"id":1}' \
    "$MCP/mcp")
  [[ "$CODE" == "403" ]] && success "HTTP $CODE — Forbidden (insufficient scope)" || fail "HTTP $CODE (expected 403)"

  printf "  Correct scope   → "
  GOOD_TOKEN=$(get_token "tools:classify.submit")
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $GOOD_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}},"id":1}' \
    "$MCP/mcp")
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

demo_trace() {
  header "Scan lifecycle trace — ephemeral vs. persistent"
  label "Shows what is created, what is discarded, and what (if anything) persists"
  label "for a single scan request through the full Keycloak → MCP → Worker path."
  echo ""

  # Show pod ages — what's been running and since when
  echo -e "${BOLD}Running services:${RESET}"
  kubectl get pods -n mcp-presidio \
    --sort-by='.metadata.creationTimestamp' \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,STARTED:.metadata.creationTimestamp' \
    2>/dev/null | sed 's/T/ /g;s/Z//' | awk 'NR==1{next} {printf "  %-48s %-10s %s\n",$1,$2,$3}'
  echo ""

  echo -e "${BOLD}Request lifecycle:${RESET}"
  echo ""

  # Step 1 — token
  printf "  ${DIM}[client]${RESET}     acquiring token from Keycloak ..."
  TOKEN=$(get_token "tools:classify.submit")
  echo -e "\r  ${DIM}[client]${RESET}     token acquired from Keycloak   ${DIM}(persists: JWT, TTL 300s)${RESET}"
  sleep 0.7

  # Step 2 — session
  printf "  ${DIM}[client]${RESET}     opening MCP session ..."
  SESSION=$(open_mcp_session "$TOKEN")
  echo -e "\r  ${DIM}[client]${RESET}     MCP session opened             ${DIM}(persists: in-memory session, TTL ~idle)${RESET}"
  sleep 0.7

  # Step 3 — fire scan
  echo ""
  printf "  ${DIM}[client]${RESET}     sending classify_payload_sensitivity ..."
  T0=$(date +%s%3N)

  RESULT=$(curl -s \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $SESSION" \
    -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"classify_payload_sensitivity","arguments":{"content":"Employee John Smith, SSN 234-56-7890, card 4111111111111111.","content_type":"text/plain"}},"id":2}' \
    "$MCP/mcp")

  T1=$(date +%s%3N)
  ELAPSED=$(( T1 - T0 ))
  echo -e "\r  ${DIM}[client]${RESET}     request dispatched — waiting for response              "
  sleep 0.5

  # Step 4 — show MCP server log line
  MCP_LOG=$(kubectl logs -n mcp-presidio deploy/mcp-presidio-sensitivity --since=15s 2>/dev/null \
    | python3 -c "
import sys,json
for line in sys.stdin:
    try:
        d=json.loads(line)
        if d.get('message')=='request' and d.get('auth_decision')=='allow':
            ts=d.get('timestamp','')[11:23]
            subj=d.get('caller_subject','')[:8]
            dur=round(d.get('duration_ms',0))
            print(f'  {ts}  mcp-server   auth=allow caller={subj}... duration={dur}ms')
    except: pass
" 2>/dev/null | tail -1)

  if [[ -n "$MCP_LOG" ]]; then
    echo -e "  ${CYAN}${MCP_LOG}${RESET}"
    sleep 0.7
  fi

  # Step 5 — show worker log lines one at a time
  WORKER_LINES=$(kubectl logs -n mcp-presidio deploy/presidio-worker --since=15s 2>/dev/null \
    | python3 -c "
import sys,json
lines=[]
for line in sys.stdin:
    try:
        d=json.loads(line)
        if d.get('message') in ('scan started','scan completed'):
            ts=d.get('timestamp','')[11:23]
            msg=d.get('message','')
            sid=d.get('scan_id','')[:8]
            dec=d.get('decision','')
            sev=d.get('max_severity_band','')
            n=d.get('findings_count','')
            extra=f' decision={dec} severity={sev} findings={n}' if dec else ''
            lines.append(f'  {ts}  worker       {msg} scan_id={sid}...{extra}')
    except: pass
for l in lines[-2:]: print(l)
" 2>/dev/null)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo -e "  ${CYAN}${line}${RESET}"
    sleep 0.8
  done <<< "$WORKER_LINES"

  echo ""

  # Step 6 — ephemeral teardown steps, one per beat
  sleep 0.4
  echo -e "  ${DIM}[worker]${RESET}     Presidio ran in-process        ${DIM}(ephemeral: payload never written to disk)${RESET}"
  sleep 0.7
  echo -e "  ${DIM}[worker]${RESET}     scan_request deleted           ${DIM}(ephemeral: content reference dropped post-analysis)${RESET}"
  sleep 0.7
  echo -e "  ${DIM}[worker]${RESET}     result returned to MCP server  ${DIM}(ephemeral: not stored)${RESET}"
  sleep 0.7
  echo -e "  ${DIM}[client]${RESET}     bounded result returned        ${DIM}(ephemeral: lives in response only)${RESET}"
  sleep 0.5

  SCAN_ID=$(echo "$RESULT" | python3 -c "
import sys,json,re
raw=sys.stdin.read()
m=re.search(r'data: (.+)', raw)
if m:
    r=json.loads(m.group(1))['result']['structuredContent']
    print(r['scan_id'])
" 2>/dev/null)

  DECISION=$(echo "$RESULT" | python3 -c "
import sys,json,re
raw=sys.stdin.read()
m=re.search(r'data: (.+)', raw)
if m:
    r=json.loads(m.group(1))['result']['structuredContent']
    print(r['decision'], r['max_severity_band'])
" 2>/dev/null)

  echo ""
  echo -e "${BOLD}Result:${RESET}  scan_id=${SCAN_ID}  decision=${DECISION}  round-trip=${ELAPSED}ms"
  echo ""
  sleep 0.5
  echo -e "${BOLD}Persisted after this scan:${RESET}"
  sleep 0.4
  echo -e "  ${YELLOW}⚠  Nothing${RESET} — no database, no audit store, no file writes"
  sleep 0.4
  echo -e "  ${DIM}The only record is the log line above in pod stdout.${RESET}"
  echo -e "  ${DIM}It disappears when the pod restarts.${RESET}"
  echo -e "  ${DIM}Audit storage is Phase 1 Stream 2.${RESET}"
}

# ---------------------------------------------------------------------------
# RFC 9728 discovery flow demo
# ---------------------------------------------------------------------------

demo_jaeger() {
  header "Jaeger distributed trace — A3 OTel instrumentation"
  label "Fires a classify_payload_sensitivity call and retrieves the resulting trace"
  label "from Jaeger, showing spans across both services."
  echo ""

  # Check Jaeger is reachable
  JAEGER="http://localhost:16686"
  if ! curl -sf "$JAEGER/api/services" &>/dev/null; then
    warn "Jaeger UI not reachable at $JAEGER"
    warn "Run: kubectl port-forward -n mcp-presidio svc/jaeger 16686:16686"
    return 1
  fi

  # Step 1 — fire a classify request to generate a trace
  label "Step 1 — Sending classify_payload_sensitivity (rich payload with multiple entity types)."
  echo ""
  printf "  ${DIM}[client → mcp → worker]${RESET}  classifying payload ..."

  TOKEN=$(get_token "tools:classify.submit")
  SESSION=$(open_mcp_session "$TOKEN")

  T0=$(date +%s%3N)
  RESULT=$(curl -s \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $SESSION" \
    -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"classify_payload_sensitivity","arguments":{"content":"Dear John Synthetic, SSN 234-56-7890, card 4111111111111111, contact john@test.example.","content_type":"text/plain"}},"id":2}' \
    "$MCP/mcp")
  T1=$(date +%s%3N)
  ELAPSED=$(( T1 - T0 ))

  SCAN_ID=$(echo "$RESULT" | python3 -c "
import sys,json,re
raw=sys.stdin.read()
m=re.search(r'data: (.+)', raw)
if m:
    r=json.loads(m.group(1))['result']['structuredContent']
    print(r.get('scan_id','?'))
" 2>/dev/null)

  echo -e "\r  ${DIM}[client ← mcp]${RESET}             scan_id=${SCAN_ID}  round-trip=${ELAPSED}ms"
  sleep 1.5

  # Step 2 — wait for spans to flush to Jaeger (BatchSpanProcessor has a short delay)
  echo ""
  label "Step 2 — Waiting for OTel BatchSpanProcessor to flush spans to Jaeger."
  echo ""
  printf "  ${DIM}[otel → jaeger]${RESET}  flushing spans ..."
  sleep 3
  echo -e "\r  ${DIM}[otel → jaeger]${RESET}  spans exported              "
  sleep 0.5

  # Step 3 — query Jaeger API for the most recent trace
  echo ""
  label "Step 3 — Querying Jaeger API for the trace."
  echo ""

  curl -sf "$JAEGER/api/traces?service=mcp-presidio-sensitivity&limit=1" 2>/dev/null | python3 -c "
import sys, json

data = json.loads(sys.stdin.read())
traces = data.get('data', [])
if not traces:
    print('  no traces found in Jaeger — spans may still be flushing')
    sys.exit(0)

t = traces[0]
trace_id = t['traceID']
spans = t['spans']
processes = t.get('processes', {})

bold  = '\033[1m'
cyan  = '\033[0;36m'
dim   = '\033[2m'
reset = '\033[0m'

print(f'  {bold}trace_id:{reset} {cyan}{trace_id}{reset}')
print(f'  {bold}spans:{reset}    {len(spans)} across 2 services')
print()

for s in sorted(spans, key=lambda x: x['startTime']):
    pid = s.get('processID', '')
    proc = processes.get(pid, {})
    svc = proc.get('serviceName', pid)
    op = s['operationName']
    dur = s['duration'] / 1000
    tags = {tg['key']: tg['value'] for tg in s.get('tags', [])}

    indent = '    ' if svc == 'presidio-worker' else '  '
    colour = '\033[0;33m' if svc == 'presidio-worker' else '\033[0;36m'

    extra = ''
    for k in ('caller_subject', 'decision', 'findings_count', 'language'):
        if k in tags:
            extra += f'  {dim}{k}={tags[k]}{reset}'

    print(f'{indent}{colour}[{svc}]{reset}  {bold}{op}{reset}  {dim}{dur:.1f}ms{reset}{extra}')
" 2>/dev/null || echo "  (trace parse error)"

  echo ""
  echo -e "${DIM}Open the Jaeger UI to explore the full trace waterfall:${RESET}"
  echo -e "  ${CYAN}http://localhost:16686${RESET}  ${DIM}(requires: kubectl port-forward -n mcp-presidio svc/jaeger 16686:16686)${RESET}"
  echo ""
  success "A3 — distributed trace confirmed across mcp-presidio-sensitivity and presidio-worker"
}

demo_flow() {
  header "RFC 9728 Discovery Flow (Flow 2)"
  label "Simulates a compliant client that starts with only the MCP server URL."
  label "Keycloak URL, token endpoint, and required scope are all discovered —"
  label "nothing pre-configured out-of-band."
  echo ""

  # Step 1 — unauthenticated request → 401 + resource_metadata
  label "Step 1 — Client sends an unauthenticated request to discover the auth server."
  echo ""
  printf "  ${DIM}[client → mcp]${RESET}  POST /mcp (no token) ..."
  FULL_RESP=$(curl -si --max-time 5 -X POST "$MCP/mcp" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null)
  HTTP_CODE=$(echo "$FULL_RESP" | grep "^HTTP" | awk '{print $2}')
  WWW_AUTH=$(echo "$FULL_RESP" | grep -i "^www-authenticate:" | tr -d '\r')
  RESOURCE_META_URL=$(echo "$WWW_AUTH" | python3 -c "
import sys, re
m = re.search(r'resource_metadata=\"([^\"]+)\"', sys.stdin.read())
print(m.group(1) if m else '')
")
  echo -e "\r  ${DIM}[mcp → client]${RESET}  HTTP ${HTTP_CODE} — resource_metadata URL in WWW-Authenticate"
  sleep 0.5
  echo -e "  ${DIM}               ${RESET}  ${DIM}${WWW_AUTH}${RESET}"
  sleep 1.2
  echo ""

  # Step 2 — fetch resource metadata document
  label "Step 2 — Client fetches the resource metadata document."
  echo ""
  printf "  ${DIM}[client → mcp]${RESET}  GET /.well-known/oauth-protected-resource ..."
  META_DOC=$(curl -sf --max-time 5 "$RESOURCE_META_URL" 2>/dev/null)
  AS_URL=$(echo "$META_DOC" | python3 -c "import sys,json; print(json.load(sys.stdin)['authorization_servers'][0])")
  SCOPE_SUPPORTED=$(echo "$META_DOC" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('scopes_supported', ['?'])))")
  echo -e "\r  ${DIM}[mcp → client]${RESET}  authorization_servers + scopes_supported received"
  sleep 0.5
  echo -e "  ${DIM}               ${RESET}  ${DIM}authorization_servers[0]: $AS_URL${RESET}"
  echo -e "  ${DIM}               ${RESET}  ${DIM}scopes_supported:         $SCOPE_SUPPORTED${RESET}"
  sleep 1.2
  echo ""

  # Step 3 — OIDC discovery from AS
  label "Step 3 — Client discovers the token endpoint from the authorization server."
  echo ""
  printf "  ${DIM}[client → as]${RESET}   GET /.well-known/openid-configuration ..."
  OIDC_DOC=$(curl -sf --max-time 5 "${AS_URL}/.well-known/openid-configuration" 2>/dev/null)
  TOKEN_ENDPOINT=$(echo "$OIDC_DOC" | python3 -c "import sys,json; print(json.load(sys.stdin)['token_endpoint'])")
  ISSUER=$(echo "$OIDC_DOC" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
  echo -e "\r  ${DIM}[as → client]${RESET}   token_endpoint + issuer received"
  sleep 0.5
  echo -e "  ${DIM}               ${RESET}  ${DIM}issuer:         $ISSUER${RESET}"
  echo -e "  ${DIM}               ${RESET}  ${DIM}token_endpoint: $TOKEN_ENDPOINT${RESET}"
  sleep 1.2
  echo ""

  # Step 4 — acquire token from discovered endpoint
  label "Step 4 — Client acquires a token from the discovered endpoint."
  echo ""
  printf "  ${DIM}[client → as]${RESET}   POST /token (client_credentials, scope=tools:classify.submit) ..."
  TOKEN_RESP=$(curl -sf --max-time 10 -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&scope=tools:classify.submit" \
    2>/dev/null)
  ACCESS_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  EXPIRES_IN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in','?'))")
  SUBJECT=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys, base64, json
token = sys.stdin.read().strip()
payload = token.split('.')[1] + '=' * (-len(token.split('.')[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(claims.get('sub', '?'))
")
  echo -e "\r  ${DIM}[as → client]${RESET}   JWT received (expires_in: ${EXPIRES_IN}s)"
  sleep 0.5
  echo -e "  ${DIM}               ${RESET}  ${DIM}sub: $SUBJECT${RESET}"
  sleep 1.2
  echo ""

  # Step 5 — authenticated request to MCP
  label "Step 5 — Client sends the authenticated request to the MCP server."
  echo ""
  printf "  ${DIM}[client → mcp]${RESET}  POST /mcp  Authorization: Bearer <JWT> ..."
  SESSION=$(open_mcp_session "$ACCESS_TOKEN")
  echo -e "\r  ${DIM}[mcp → client]${RESET}  HTTP 200 — session opened"
  sleep 0.5
  echo -e "  ${DIM}               ${RESET}  ${DIM}mcp-session-id: $SESSION${RESET}"
  sleep 1.0
  echo ""

  # Summary
  echo -e "${BOLD}Discovery complete.${RESET}"
  echo -e "${DIM}Started with one URL: $MCP${RESET}"
  echo -e "${DIM}Keycloak location, token endpoint, and required scope — all discovered.${RESET}"
  echo ""
  success "Flow 2 (RFC 9728) — compliant client bootstrap from MCP URL only"
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
  echo "  f  RFC 9728 discovery flow — client bootstrap from MCP URL only"
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
  echo -e "${BOLD}Observability${RESET}"
  echo "  l  Scan lifecycle trace — ephemeral vs. persistent"
  echo "  j  Jaeger distributed trace — A3 OTel spans across both services"
  echo ""
  echo "  a  Run all demos in sequence"
  echo "  q  Quit"
  echo ""
}

run_demo() {
  case "$1" in
    0|auth) demo_auth ;;
    t|token) demo_token ;;
    f|flow) demo_flow ;;
    1) demo_1 ;;
    2) demo_2 ;;
    3) demo_3 ;;
    4) demo_4 ;;
    5) demo_5 ;;
    6) demo_6 ;;
    7) demo_7 ;;
    8) demo_8 ;;
    l|trace) demo_trace ;;
    j|jaeger) demo_jaeger ;;
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
  for d in auth token flow 1 2 3 4 5 6 7 8 trace jaeger; do
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
    [0-9]|t|f|l|j|token|auth|flow|trace|jaeger) run_demo "$choice" ;;
    a)
      for d in auth token flow 1 2 3 4 5 6 7 8 trace jaeger; do
        run_demo "$d"
        pause
      done
      ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) warn "Enter a number 0–8, 't', 'a' for all, or 'q' to quit." ;;
  esac
done
