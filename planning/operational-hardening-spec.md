# Engineering Spec: Operational Hardening

**Status:** `ready-for-implementation`
**Stream:** Phase 1 — Stream 3
**Depends on:** structured-logging-spec.md (service fields must be in place for consistent log output)
**Security sign-off required before Phase 1 exit:** NetworkPolicy is a security control, not just operational hardening. Phase 1 cannot be signed off without it.
**Last updated:** 2026-03-24

---

## Items

1. Scan timeout — rename error code, reduce default
2. NetworkPolicy — worker ingress restriction
3. NetworkPolicy — MCP server egress restriction
4. Rate limiting — per-caller token bucket

---

## 1. Scan Timeout

### Problem

`call_worker()` in `backend/worker_client.py` already uses `httpx.AsyncClient(timeout=config.WORKER_TIMEOUT_SECONDS)` with a default of 30 seconds. Two gaps:

1. The default is too generous — a 30-second hung scan blocks the MCP server coroutine and all requests behind it. 10 seconds is the right default for a synchronous embedded Presidio scan.
2. On `TimeoutException`, the error code is `SCAN_FAILED` — indistinguishable from an engine crash. Callers cannot implement different retry logic for timeouts vs. engine errors.

### Change

**`src/mcp_server/config.py`**
- Change `WORKER_TIMEOUT_SECONDS` default from `30.0` to `10.0`

**`src/mcp_server/backend/worker_client.py`**
- Change `TimeoutException` handler: raise `WorkerError("SCAN_TIMEOUT", ...)` instead of `WorkerError("SCAN_FAILED", ...)`

No other changes. The httpx client already uses `config.WORKER_TIMEOUT_SECONDS`; the Helm configmap already exposes this as an env var.

### Acceptance criteria

1. A worker call that takes longer than `WORKER_TIMEOUT_SECONDS` produces a `WorkerError` with `error_code="SCAN_TIMEOUT"`.
2. The MCP tool handler surfaces this as `RuntimeError("SCAN_TIMEOUT: ...")`.
3. Default timeout in local cluster is 10 seconds.
4. `WORKER_TIMEOUT_SECONDS` env var override works correctly.

---

## 2. NetworkPolicy — Worker Ingress Restriction

### Problem

The worker's `/scan` endpoint is currently reachable from any pod in the `mcp-presidio` namespace. The security model requires the worker to be reachable only from the MCP server. An MCP server that forwards the Authorization header (which it explicitly does not, by design) would not be caught by a misconfigured network layer. Defense-in-depth: NetworkPolicy enforces the topology.

### Design

Worker `NetworkPolicy`: deny all ingress by default; allow ingress on port 8080 from pods with the MCP server label only.

```yaml
# helm/presidio-worker/templates/networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "presidio-worker.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  podSelector:
    matchLabels:
      {{- include "presidio-worker.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-presidio-sensitivity
      ports:
        - protocol: TCP
          port: 8080
```

**`helm/presidio-worker/values.yaml`**
```yaml
networkPolicy:
  enabled: true
```

**`helm/presidio-worker/templates/networkpolicy.yaml`**
- Wrap the entire resource in `{{- if .Values.networkPolicy.enabled }}`.

**`helm/presidio-worker/values.local.yaml`**
- `networkPolicy.enabled: true` — enforce in local cluster, not just production.

### Acceptance criteria

1. `kubectl exec` into a pod that is not the MCP server → `curl http://presidio-worker:8080/health` times out or is refused.
2. MCP server → worker scan call succeeds normally.
3. NetworkPolicy is disabled when `networkPolicy.enabled: false`.

---

## 3. NetworkPolicy — MCP Server Egress Restriction

### Problem

The MCP server currently has unrestricted egress. It should only be able to reach:
- The Presidio worker service (for scan calls)
- The Keycloak service (for JWKS fetching via OIDC discovery)
- DNS (kube-dns, for service resolution)

Any other egress (external IPs, other namespace services) should be denied.

### Design

MCP server `NetworkPolicy`: deny all egress by default; allow egress to worker, Keycloak, and DNS.

```yaml
# helm/mcp-server/templates/networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "mcp-server.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  podSelector:
    matchLabels:
      {{- include "mcp-server.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Egress
  egress:
    # Worker
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: presidio-worker
      ports:
        - protocol: TCP
          port: 8080
    # Keycloak
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: keycloak
      ports:
        - protocol: TCP
          port: 8080
    # DNS (kube-dns)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

**`helm/mcp-server/values.yaml`**
```yaml
networkPolicy:
  enabled: true
```

**`helm/mcp-server/values.local.yaml`**
- `networkPolicy.enabled: true`

### Implementation note on Keycloak label

The local Keycloak deployment is a plain K8s Deployment (not a Helm chart). Its pod label
must be verified — if it uses `app: keycloak` rather than `app.kubernetes.io/name: keycloak`,
the `podSelector` in the NetworkPolicy must match. Check `kubectl get pods -n mcp-presidio --show-labels` and adjust accordingly.

### Acceptance criteria

1. MCP server can successfully call the worker and Keycloak.
2. `kubectl exec` into the MCP server pod → `curl https://external-site.example.com` is refused/times out.
3. JWT validation (JWKS fetch from Keycloak) works through the NetworkPolicy.
4. NetworkPolicy is disabled when `networkPolicy.enabled: false`.

---

## 4. Rate Limiting

### Problem

Any authenticated caller with a valid `tools:classify.submit` token can submit an unlimited number of scan requests. Without rate limiting, a single misconfigured or malicious caller can saturate the MCP server and starve other callers.

### Design decisions

| Concern | Decision | Rationale |
|---|---|---|
| Library | SlowAPI | Pure Python; no Redis dependency; in-process token bucket via `limits` library. FastAPI-limiter requires Redis. |
| Key | `caller_subject` (JWT `sub` claim) | Per-caller limiting. A shared key (IP, service) would be too broad for a service-to-service API. |
| Storage | In-memory | Sufficient for Phase 1 single-replica deployment. Phase 2: swap for Redis-backed storage if multi-replica. |
| Default limit | 60 requests/minute per caller | Generous default — a well-behaved agent should not exceed this. Configurable via `values.yaml`. |
| Response on breach | HTTP 429 with `Retry-After` header | Standard rate-limit response; callers can back off correctly. |
| Exempt paths | `/health`, `/.well-known/oauth-protected-resource` | Health probes and metadata must not be rate-limited. |

### Implementation

**`src/mcp_server/requirements.txt`**
- Add `slowapi`

**`src/mcp_server/config.py`**
- Add `RATE_LIMIT_ENABLED: bool` — env var `RATE_LIMIT_ENABLED`, default `True`
- Add `RATE_LIMIT_PER_MINUTE: int` — env var `RATE_LIMIT_PER_MINUTE`, default `60`

**`src/mcp_server/main.py`**
- Add SlowAPI limiter instance: `limiter = Limiter(key_func=_get_caller_subject)`
- `_get_caller_subject(request)` reads `request.state.caller_subject` — set by JWT middleware before rate limiter fires
- Add `app.state.limiter = limiter` and `app.add_exception_handler(RateLimitExceeded, _rate_limit_handler)`
- Apply `@limiter.limit(f"{config.RATE_LIMIT_PER_MINUTE}/minute")` to the MCP mount

**Rate limit key function:**
```python
def _get_caller_subject(request: Request) -> str:
    # Falls back to remote addr if subject not yet set (pre-auth requests)
    return getattr(request.state, "caller_subject", request.client.host or "unknown")
```

**Rate limit error handler:**
```python
async def _rate_limit_handler(request: Request, exc: RateLimitExceeded) -> JSONResponse:
    return JSONResponse(
        status_code=429,
        headers={"Retry-After": "60"},
        content={"error_code": "RATE_LIMITED", "message": "Too many requests."},
    )
```

**`helm/mcp-server/values.yaml`**
```yaml
rateLimit:
  enabled: true
  requestsPerMinute: 60
```

**`helm/mcp-server/templates/deployment.yaml`**
```yaml
- name: RATE_LIMIT_ENABLED
  value: {{ .Values.rateLimit.enabled | quote }}
- name: RATE_LIMIT_PER_MINUTE
  value: {{ .Values.rateLimit.requestsPerMinute | quote }}
```

### Acceptance criteria

1. A caller that submits more than `RATE_LIMIT_PER_MINUTE` requests in 60 seconds receives HTTP 429 with `Retry-After: 60`.
2. Two different `caller_subject` values have independent counters — one caller's rate limit does not affect another.
3. `GET /health` is never rate-limited regardless of request volume.
4. Rate limiting is disabled when `RATE_LIMIT_ENABLED=false`.
5. HTTP 429 response body contains `error_code: RATE_LIMITED` and no payload content.
6. Log record is emitted at `WARNING` when a rate limit is breached, including `caller_subject` and `duration_ms`.

---

## Implementation Order Within Stream 3

1. Scan timeout (smallest change, highest safety value — unblocks security sign-off)
2. NetworkPolicy — worker ingress (security control)
3. NetworkPolicy — MCP server egress (security control)
4. Rate limiting (operational hardening — requires SlowAPI dependency)

NetworkPolicy items 2 and 3 can be implemented in parallel (different Helm charts).
