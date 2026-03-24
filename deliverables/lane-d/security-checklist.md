# Security Checklist — MCP Server (Lane D)

**Phase:** 0
**Date:** 2026-03-24
**Author:** Lane D agent (Claude Sonnet 4.6)
**Review required:** Security/Privacy Lead

---

## Instructions

This checklist is completed by Lane D and reviewed by the Security/Privacy Lead
before Phase 0 exit criteria are signed off.  Every item must be checked or
have a documented exception.

---

## A. Authentication controls

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| A1 | No anonymous access to protected endpoints | PASS | JWT middleware rejects requests without valid Bearer token with 401 before route handler fires |
| A2 | Token validation runs before request body is read | PASS | `JWTAuthMiddleware.dispatch()` calls `verify_token()` before `call_next(request)` — Starlette middleware fires before route handler |
| A3 | RS256 algorithm pinned — `alg: none` and symmetric algorithms rejected | PASS | `jwt.decode(..., algorithms=["RS256"])` in `auth/token_verifier.py` |
| A4 | `iss` claim validated against configured issuer | PASS | `issuer=config.ISSUER_URL` passed to `jwt.decode()` |
| A5 | `aud` claim validated — must contain `mcp-presidio-server` | PASS | `audience=config.AUDIENCE` passed to `jwt.decode()` |
| A6 | `exp` validated — expired tokens rejected | PASS | `"verify_exp": True` in decode options |
| A7 | `nbf` validated if present — future tokens rejected | PASS | `"verify_nbf": True` in decode options |
| A8 | JWKS fetched from issuer URI — no hardcoded public keys | PASS | `_fetch_jwks()` in `auth/token_verifier.py` fetches from `config.JWKS_URI` |
| A9 | JWKS cache TTL is configurable | PASS | `config.JWKS_CACHE_TTL_SECONDS` — default 300s, overridable via env var |
| A10 | JWKS fetch failure returns 401, not 5xx | PASS | `_fetch_jwks()` raises `TokenInvalidError` on failure; middleware converts to 401 |

---

## B. Authorization controls

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| B1 | `tools:classify.submit` scope required for classify tool | PASS | `TOOL_SCOPE_MAP` in `authorization/policy.py`; checked in middleware for `/mcp*` paths |
| B2 | Wrong scope returns 403 (not 401) | PASS | `build_403_response()` in `auth/errors.py`; `insufficient_scope` error code |
| B3 | 403 response includes `WWW-Authenticate` header with `scope` parameter | PASS | `build_403_response()` sets `WWW-Authenticate: Bearer ..., scope="tools:classify.submit"` |
| B4 | `/health` exempt from auth (K8s probes) | PASS | `EXEMPT_PATHS` in middleware; decision #22 |
| B5 | `/.well-known/oauth-protected-resource` exempt from auth | PASS | `EXEMPT_PATHS` in middleware |

---

## C. Token passthrough controls

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| C1 | Caller's `Authorization` header is NOT forwarded to the worker | PASS | `headers` dict in `backend/worker_client.py` is constructed from scratch: `{"Content-Type": ..., "X-Correlation-ID": ...}`. No caller header is copied. |
| C2 | No caller credential material appears in any outbound request to the worker | PASS | `call_worker()` takes explicit parameters — it has no access to the original `Request` object |
| C3 | Worker is only passed: content, correlation_id, source_system label | PASS | `WorkerScanRequest` in `backend/models.py` contains only scan parameters |

---

## D. Payload non-leakage controls

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| D1 | `content` field never appears in log statements | PASS | `observability/logging.py::log_request()` has no `content` parameter; all log calls in middleware use only metadata fields |
| D2 | `content` never included in error responses | PASS | All error responses use `build_401_response()`, `build_403_response()`, or fixed-string `WorkerError.message` |
| D3 | Exception messages never derived from payload content | PASS | All exception handlers catch `Exception` and re-raise with fixed-string messages; exception detail not forwarded to callers |
| D4 | Worker error responses do not re-surface payload content | PASS | `WorkerError` carries only `error_code` (fixed) and `message` (fixed string in `worker_client.py`) |
| D5 | Failure paths (timeout, 5xx, parse error) do not leak payload | PASS | See design notes §5 — all failure paths produce sanitised error codes |

---

## E. Backend trust model

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| E1 | Worker URL is a Kubernetes-internal ClusterIP address | PASS | `config.WORKER_URL` defaults to `http://presidio-worker.mcp-presidio.svc.cluster.local:8080` — unreachable externally |
| E2 | MCP server does not trust the worker's response without parsing | PASS | `WorkerScanResponse.model_validate()` in `worker_client.py` — unknown fields are ignored by Pydantic by default |
| E3 | Correlation ID forwarded to worker for traceability | PASS | `request_metadata.workflow_id = correlation_id` in `call_worker()` |

---

## F. Container and deployment security

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| F1 | Non-root user in container (uid 1001) | PASS | `useradd --uid 1001` in Dockerfile; `runAsUser: 1001` in values.yaml |
| F2 | uid 1001 distinct from worker uid 1000 | PASS | Worker uses uid 1000; MCP server uses uid 1001 |
| F3 | No secrets baked into image | PASS | All config via env vars (ConfigMap); no credentials in Dockerfile or requirements.txt |
| F4 | Read-only root filesystem enabled | PASS | `readOnlyRootFilesystem: true` in values.yaml; `/tmp` provided as memory-backed emptyDir |
| F5 | `allowPrivilegeEscalation: false` | PASS | Set in `containerSecurityContext` in values.yaml |
| F6 | All Linux capabilities dropped | PASS | `capabilities.drop: [ALL]` in values.yaml |
| F7 | No service account token auto-mount | PASS | `automountServiceAccountToken: false` in deployment.yaml |
| F8 | Memory and CPU limits enforced | PASS | `resources.limits.memory: 256Mi`, `resources.limits.cpu: 500m` in values.yaml |
| F9 | `/tmp` is memory-backed emptyDir — no node disk writes | PASS | `emptyDir.medium: Memory` in deployment.yaml |

---

## G. Protected Resource Metadata

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| G1 | PRM endpoint returns correct authorization server URL | PASS | Returns `config.ISSUER_URL` in `authorization_servers` |
| G2 | PRM endpoint returns correct scopes | PASS | Lists `tools:classify.submit` and `tools:health.read` |
| G3 | PRM endpoint exempt from auth (must be publicly discoverable) | PASS | In `EXEMPT_PATHS` |

---

## H. Structured logging

| # | Control | Status | Evidence / Notes |
|---|---------|--------|-----------------|
| H1 | Every request emits a log record with required fields | PASS | `log_request()` emits `correlation_id`, `caller_subject`, `tool`, `auth_decision`, `worker_status`, `duration_ms`, `timestamp` |
| H2 | Log records include correlation_id | PASS | Always present |
| H3 | Log records include caller_subject (from JWT `sub`) | PASS | Extracted from claims in middleware |
| H4 | Log records never include payload content | PASS | `log_request()` has no content parameter by design |
| H5 | Auth denial (401/403) is logged before response is returned | PASS | `log_request()` called before `return build_401_response()` in middleware |

---

## I. Open items / accepted deviations

| # | Item | Accepted | Reason |
|---|------|----------|--------|
| I1 | `/health` requires no auth | Yes — decision #22 | K8s probes cannot carry tokens |
| I2 | Blanket scope check on `/mcp*` path | Yes — Phase 0 accepted | Tool name is inside MCP protocol envelope; HTTP path is only `tools:classify.submit` context in Phase 0 |
| I3 | JWKS cache uses simple dict (not TTLCache) | Yes — Phase 0 | Single-replica deployment; Phase 1 item to upgrade |
| I4 | No rate limiting | Deferred to Phase 2 | Not required for Phase 0 |
| I5 | No audit storage | Deferred to Phase 1 | Not required for Phase 0 |
| I6 | No network policy for MCP server egress | Phase 1 item | Worker network policy also deferred |

---

## Sign-off

| Role | Status | Date |
|------|--------|------|
| Lane D (author) | Complete — ready for review | 2026-03-24 |
| Security/Privacy Lead | Pending | — |
