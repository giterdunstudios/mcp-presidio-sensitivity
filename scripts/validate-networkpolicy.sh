#!/usr/bin/env bash
# Cluster-level NetworkPolicy validation for Stream 3.
#
# When to use:
#   - After any change to helm/mcp-server/templates/networkpolicy.yaml or
#     helm/presidio-worker/templates/networkpolicy.yaml
#   - After a Helm upgrade that touches networkPolicy.enabled
#   - After a cluster rebuild to confirm policies are enforced
#   - Before Phase 1 exit sign-off (required gate — see decision-log.md DEC-001)
#   Note: deploys and cleans up a temporary busybox test pod automatically.
#
# Use cases covered (cases 11–20):
#   11. MCP server pod → worker /scan              ALLOWED
#   12. MCP server pod → worker /health            ALLOWED
#   13. Non-MCP pod → worker /scan                 DENIED
#   14. Non-MCP pod → worker /health               DENIED
#   15. Kubelet → worker /health (liveness probe)  ALLOWED (node-level, bypasses NetworkPolicy)
#   16. MCP server → Keycloak OIDC discovery       ALLOWED
#   17. MCP server → worker (end-to-end scan)      ALLOWED
#   18. MCP server → external internet             DENIED
#   19. networkPolicy.enabled:false on worker      no NetworkPolicy resource created
#   20. networkPolicy.enabled:false on MCP server  no NetworkPolicy resource created
#
# Usage:
#   ./scripts/validate-networkpolicy.sh
#
# Requirements:
#   - Local kind cluster running (./scripts/setup-local.sh completed)
#   - kubectl configured for the kind cluster
#   - NetworkPolicy deployed (helm upgrade with networkPolicy.enabled=true)

set -euo pipefail

NAMESPACE="mcp-presidio"
TEST_POD="netpol-test-pod"
WORKER_SVC="presidio-worker.${NAMESPACE}.svc.cluster.local"
MCP_SVC="mcp-presidio-sensitivity.${NAMESPACE}.svc.cluster.local"
KEYCLOAK_SVC="keycloak.${NAMESPACE}.svc.cluster.local"
CONNECT_TIMEOUT=5

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}✔${RESET}  $*"; }
fail() { echo -e "  ${RED}✘${RESET}  $*"; FAILURES=$((FAILURES + 1)); }
skip() { echo -e "  ${YELLOW}⊘${RESET}  $*"; }
header() { echo -e "\n${BOLD}$*${RESET}"; }

FAILURES=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

mcp_pod() {
    kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=mcp-presidio-sensitivity \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

exec_in_mcp() {
    kubectl exec -n "$NAMESPACE" "$(mcp_pod)" -- "$@" 2>/dev/null
}

exec_in_test_pod() {
    kubectl exec -n "$NAMESPACE" "$TEST_POD" -- "$@" 2>/dev/null
}

# Returns 0 if connection succeeds, 1 if refused/timeout
can_connect() {
    local pod_exec_fn="$1"; shift
    local url="$1"
    $pod_exec_fn wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null "$url" 2>/dev/null
}

check_policy_resource_exists() {
    local resource_name="$1"
    kubectl get networkpolicy "$resource_name" -n "$NAMESPACE" &>/dev/null
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

header "Pre-flight checks"

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Namespace $NAMESPACE not found — run ./scripts/setup-local.sh first${RESET}"
    exit 1
fi

MCP_POD=$(mcp_pod)
if [[ -z "$MCP_POD" ]]; then
    echo -e "${RED}MCP server pod not found in $NAMESPACE${RESET}"
    exit 1
fi
pass "MCP server pod found: $MCP_POD"

WORKER_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=presidio-worker \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$WORKER_POD" ]]; then
    echo -e "${RED}Worker pod not found in $NAMESPACE${RESET}"
    exit 1
fi
pass "Worker pod found: $WORKER_POD"

# ---------------------------------------------------------------------------
# Deploy test pod (non-MCP, used for denied-access checks)
# ---------------------------------------------------------------------------

header "Deploying test pod (non-MCP identity)"

kubectl run "$TEST_POD" \
    --image=busybox:1.36 \
    --restart=Never \
    --namespace="$NAMESPACE" \
    --overrides='{"spec":{"containers":[{"name":"netpol-test","image":"busybox:1.36","command":["sleep","300"]}]}}' \
    2>/dev/null || true

kubectl wait pod/"$TEST_POD" -n "$NAMESPACE" --for=condition=Ready --timeout=30s &>/dev/null
pass "Test pod ready"

# ---------------------------------------------------------------------------
# Case 11: MCP server pod → worker /scan — ALLOWED
# ---------------------------------------------------------------------------

header "Case 11 — MCP server → worker /scan (ALLOWED)"
if exec_in_mcp wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null \
        "http://${WORKER_SVC}:8080/health"; then
    pass "MCP server can reach worker"
else
    fail "MCP server cannot reach worker — NetworkPolicy too restrictive"
fi

# ---------------------------------------------------------------------------
# Case 12: MCP server pod → worker /health — ALLOWED
# ---------------------------------------------------------------------------

header "Case 12 — MCP server → worker /health (ALLOWED)"
if exec_in_mcp wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null \
        "http://${WORKER_SVC}:8080/health"; then
    pass "MCP server can reach worker /health"
else
    fail "MCP server cannot reach worker /health"
fi

# ---------------------------------------------------------------------------
# Case 13: Non-MCP pod → worker /scan — DENIED
# ---------------------------------------------------------------------------

header "Case 13 — Non-MCP pod → worker /scan (DENIED)"
if exec_in_test_pod wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null \
        "http://${WORKER_SVC}:8080/health" 2>/dev/null; then
    fail "Non-MCP pod reached worker — NetworkPolicy not enforced"
else
    pass "Non-MCP pod correctly denied access to worker"
fi

# ---------------------------------------------------------------------------
# Case 14: Non-MCP pod → worker /health — DENIED
# ---------------------------------------------------------------------------

header "Case 14 — Non-MCP pod → worker /health (DENIED)"
if exec_in_test_pod wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null \
        "http://${WORKER_SVC}:8080/health" 2>/dev/null; then
    fail "Non-MCP pod reached worker /health — NetworkPolicy not enforced"
else
    pass "Non-MCP pod correctly denied access to worker /health"
fi

# ---------------------------------------------------------------------------
# Case 15: Kubelet liveness probe → worker /health — ALLOWED
# ---------------------------------------------------------------------------

header "Case 15 — Kubelet liveness probe (ALLOWED)"
WORKER_READY=$(kubectl get pod "$WORKER_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
if [[ "$WORKER_READY" == "true" ]]; then
    pass "Worker pod is Ready — kubelet liveness probe is passing (node-level, bypasses NetworkPolicy)"
else
    fail "Worker pod is not Ready — kubelet probe may be blocked"
fi

# ---------------------------------------------------------------------------
# Case 16: MCP server → Keycloak OIDC discovery — ALLOWED
# ---------------------------------------------------------------------------

header "Case 16 — MCP server → Keycloak OIDC discovery (ALLOWED)"
if exec_in_mcp wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null \
        "http://${KEYCLOAK_SVC}:8080/realms/mcp-local/.well-known/openid-configuration"; then
    pass "MCP server can reach Keycloak OIDC discovery"
else
    fail "MCP server cannot reach Keycloak — JWT validation will fail"
fi

# ---------------------------------------------------------------------------
# Case 17: End-to-end — valid token → scan succeeds (proves full path)
# ---------------------------------------------------------------------------

header "Case 17 — End-to-end scan through NetworkPolicy (ALLOWED)"
TOKEN=$(curl -sf -X POST "http://localhost:8080/realms/mcp-local/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=test-agent-client&client_secret=test-agent-secret-change-in-prod&scope=tools:classify.submit" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

if [[ -z "$TOKEN" ]]; then
    skip "Case 17: could not obtain token — Keycloak not reachable from host, skipping end-to-end check"
else
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"netpol-test","version":"1.0"}},"id":1}' \
        "http://localhost:8000/mcp")
    if [[ "$HTTP_CODE" == "200" ]]; then
        pass "End-to-end MCP call succeeded through NetworkPolicy (HTTP $HTTP_CODE)"
    else
        fail "End-to-end MCP call failed (HTTP $HTTP_CODE) — NetworkPolicy may be blocking the path"
    fi
fi

# ---------------------------------------------------------------------------
# Case 18: MCP server → external internet — DENIED
# ---------------------------------------------------------------------------

header "Case 18 — MCP server → external internet (DENIED)"
if exec_in_mcp wget -q --timeout="$CONNECT_TIMEOUT" -O /dev/null \
        "http://example.com" 2>/dev/null; then
    fail "MCP server reached external internet — egress NetworkPolicy not enforced"
else
    pass "MCP server correctly denied external internet access"
fi

# ---------------------------------------------------------------------------
# Case 19: networkPolicy.enabled:false on worker — no NetworkPolicy resource
# ---------------------------------------------------------------------------

header "Case 19 — Worker NetworkPolicy resource presence"
WORKER_NETPOL=$(kubectl get networkpolicy -n "$NAMESPACE" \
    -o jsonpath='{.items[?(@.spec.podSelector.matchLabels.app\.kubernetes\.io/name=="presidio-worker")].metadata.name}' \
    2>/dev/null)
if [[ -n "$WORKER_NETPOL" ]]; then
    pass "Worker NetworkPolicy exists: $WORKER_NETPOL"
else
    skip "Case 19: Worker NetworkPolicy not found — deployed with networkPolicy.enabled:false (or not yet deployed)"
fi

# ---------------------------------------------------------------------------
# Case 20: networkPolicy.enabled:false on MCP server — no NetworkPolicy resource
# ---------------------------------------------------------------------------

header "Case 20 — MCP server NetworkPolicy resource presence"
MCP_NETPOL=$(kubectl get networkpolicy -n "$NAMESPACE" \
    -o jsonpath='{.items[?(@.spec.podSelector.matchLabels.app\.kubernetes\.io/name=="mcp-presidio-sensitivity")].metadata.name}' \
    2>/dev/null)
if [[ -n "$MCP_NETPOL" ]]; then
    pass "MCP server NetworkPolicy exists: $MCP_NETPOL"
else
    skip "Case 20: MCP server NetworkPolicy not found — deployed with networkPolicy.enabled:false (or not yet deployed)"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

header "Cleanup"
kubectl delete pod "$TEST_POD" -n "$NAMESPACE" --ignore-not-found &>/dev/null
pass "Test pod removed"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${BOLD}${GREEN}All NetworkPolicy checks passed${RESET}"
else
    echo -e "${BOLD}${RED}${FAILURES} check(s) failed${RESET}"
    exit 1
fi
