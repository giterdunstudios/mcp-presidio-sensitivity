# MCP Server Design Notes — Lane D

**Phase:** 0
**Date:** 2026-03-24
**Author:** Lane D agent (Claude Sonnet 4.6)

---

## 1. Architecture overview

The MCP server is the trust boundary between callers (agents and services) and
the Presidio worker.  Its core responsibilities are:

1. Validate Bearer JWTs on every protected request
2. Enforce scope-based authorization
3. Forward scan requests to the worker (without token passthrough)
4. Return bounded results to the caller
5. Emit structured audit logs (no payload content)

```
[Caller — agent or service]
    |
    | HTTP POST with Bearer JWT
    v
[FastAPI + JWTAuthMiddleware]
    - verify_token() — RS256 signature, iss, aud, exp, nbf
    - is_authorized() — scope check
    - reject 401 / 403 before body is read
    |
    | request.state.claims injected
    v
[FastMCP — MCP protocol handling]
    - classify_payload_sensitivity tool handler
    |
    | call_worker() — internal HTTP, no Authorization header
    v
[Presidio Worker — ClusterIP, unreachable externally]
    http://presidio-worker.mcp-presidio.svc.cluster.local:8080
```

---

## 2. Framework choices

### FastAPI + Starlette middleware

The MCP SDK (`mcp`, FastMCP interface) provides a Starlette-compatible ASGI app
that can be mounted on a FastAPI router.  JWT validation is implemented as a
Starlette `BaseHTTPMiddleware` rather than a FastAPI dependency for one
critical reason:

**Middleware fires before the route handler reads the request body.**

FastAPI dependencies and route handlers cannot guarantee this ordering because
the dependency injection system may consume the body before auth checks fire.
By using middleware, the "401 before any business logic" requirement (briefing
security constraint table) is structurally enforced by Starlette's dispatch order.

### MCP SDK mount

The FastMCP app is mounted at `/mcp` on the parent FastAPI app.  The JWT
middleware intercepts all requests to `/mcp*` before the MCP SDK sees them.
This means:
- The MCP SDK never sees an unauthenticated request
- Tool handler code does not need to re-validate tokens
- Protocol-level MCP errors (malformed tool call, missing args) can still
  surface from the SDK without exposing auth internals

### Streamable HTTP transport

The MCP SDK is configured for Streamable HTTP transport (not SSE).  This is the
correct choice for agent callers that make point-in-time invocations and do not
maintain persistent connections.

---

## 3. JWT validation design

### JWKS caching

Public keys are fetched from Hydra's JWKS URI:
```
http://hydra.mcp-presidio.svc.cluster.local:4444/.well-known/jwks.json
```

Keys are cached in memory with a configurable TTL (default: 300 seconds,
matching `jwksCacheTtlSeconds` in values.yaml).  The cache is a module-level
dictionary in `auth/token_verifier.py`.  Cache misses and TTL expiry trigger
a fresh JWKS fetch.

This is a simple in-process cache.  A Phase 1 improvement would use a
thread-safe TTL cache (e.g. `cachetools.TTLCache`) to handle concurrent
expiry correctly.  For Phase 0 single-replica deployment this is acceptable.

### Algorithm pinning

The `jwt.decode()` call passes `algorithms=["RS256"]` explicitly.  This
prevents `alg: none` attacks and symmetric algorithm substitution attacks.
The `python-jose[cryptography]` library raises `JWTError` if the token header
specifies any algorithm not in the allowed list.

### Issuer and audience validation

Both are validated by `python-jose` via the `issuer=` and `audience=` arguments.
These match the confirmed values from the token validation report:
- Issuer: `http://hydra.mcp-presidio.svc.cluster.local:4444`
- Audience: `mcp-presidio-server`

### Scope claim extraction

Hydra uses `scp` (array) not `scope` (string).  The `auth/claims.py` module
extracts from `scp` first, falling back to `scope` for compatibility.
See token-validation-report.md Step 3 for the confirmed claim structure.

---

## 4. Token passthrough guarantee

**The caller's Authorization header is never forwarded to the worker.**

This is enforced structurally in `backend/worker_client.py`:

```python
headers = {
    "Content-Type": "application/json",
    "X-Correlation-ID": correlation_id,
}
```

The `headers` dict is constructed from scratch.  There is no code path that
copies or passes through the inbound `Authorization` header.  The `httpx.AsyncClient`
call uses only this explicit headers dict — there is no default header
inheritance from the incoming request.

For Security/Privacy Lead review: search `worker_client.py` for "Authorization"
— it appears only in the docstring's "never forward" comment, not in any
header assignment.

---

## 5. Payload non-leakage analysis

### Log statements

The structured logger (`observability/logging.py`) has no `content` parameter.
The `log_request()` helper function has a documented "Security note" that it
must never be given a content parameter.

The middleware log calls (`JWTAuthMiddleware.dispatch`) log only:
`correlation_id`, `caller_subject`, `tool` (path), `auth_decision`,
`worker_status`, `duration_ms`.

The tool handler (`tools/classify.py`) does not emit any log statements.
Worker errors are re-raised as `RuntimeError` with a sanitised message
from `WorkerError.message` (which itself only carries `error_code` and `message`
— see `backend/worker_client.py`).

### Error responses

All 401/403 responses (`auth/errors.py`) contain only:
- `error` (OAuth error code)
- `error_description` (fixed string)

No payload, no token fragment, no exception detail.

`WorkerError` responses carry only `error_code` and `message`.
These are set to fixed strings in `worker_client.py` — not derived from
exception messages or response body content.

### Failure paths

| Failure | What is logged | What is returned |
|---------|----------------|-----------------|
| Worker timeout | `correlation_id`, `worker_status` | 503 + `SCAN_FAILED` |
| Worker 4xx | `correlation_id`, `status_code` | mapped error code + message |
| Worker parse error | `correlation_id`, exception type name | 503 + `SCAN_FAILED` |
| JWKS fetch failure | exception type name only | 401 + `invalid_token` |
| JWT validation failure | exception type name only | 401 + `invalid_token` |

In all cases: no payload content, no matched substrings, no raw exception
messages derived from input data.

---

## 6. Correlation ID flow

Every request receives a UUID correlation ID generated by the middleware before
any other processing:

```python
correlation_id = str(uuid.uuid4())
```

This ID is:
1. Stored in `request.state.correlation_id`
2. Set in `_current_correlation_id` context variable for MCP tool handler access
3. Forwarded to the worker as `request_metadata.workflow_id`
4. Included in all log records for this request

If the caller supplies a `workflow_id` in their tool request, that value is
used as the workflow anchor but the MCP server's correlation_id remains the
primary tracing key.

---

## 7. Health endpoint — auth exemption

`GET /health` is exempt from JWT authentication.  This is a deliberate
deviation from the auth spec's `tools:health.read` scope requirement.

**Reason:** Kubernetes liveness and readiness probes cannot present Bearer tokens.
If the health endpoint required auth, the probes would fail and the pod would
be killed.

**Decision log entry #22** records this acceptance.

**Risk:** An unauthenticated caller can confirm the server is alive.  This is
acceptable for a liveness probe endpoint.  The endpoint returns only
`{"status": "ok"}` — no sensitive information is exposed.

---

## 8. Protected Resource Metadata

`GET /.well-known/oauth-protected-resource` is also exempt from auth.
This endpoint returns the PRM document required by auth spec §4, FR-3.

It discloses:
- The Authorization Server URL (already public)
- The supported scopes (already public by design)
- The server resource URL (deployment-internal hostname)

The server resource URL is a cluster-internal DNS name.  Disclosing it to
an unauthenticated caller is acceptable — the name is not reachable from
outside the cluster.

---

## 9. Deviations from briefing

| Item | Briefing | Implementation | Reason |
|------|----------|----------------|--------|
| `/health` scope | `tools:health.read` required | No auth on `/health` | K8s probes cannot carry tokens — decision #22 |
| Scope check on MCP path | Per-tool scope enforcement | Blanket `tools:classify.submit` for all `/mcp*` requests | MCP SDK routes all tool calls through `/mcp` — tool name is inside the MCP protocol envelope, not the HTTP path. Phase 1 can add protocol-level inspection. |
| JWKS cache implementation | TTL cache, 5 minutes | Simple module-level dict + monotonic timestamp | Sufficient for Phase 0 single-replica. Phase 1 should use `cachetools.TTLCache` for thread-safety. |

---

## 10. Phase 1 improvements

- Replace simple JWKS cache with `cachetools.TTLCache` for thread safety
- Add per-tool scope inspection inside the MCP protocol envelope (not just HTTP path)
- Add network policy to restrict MCP server egress to worker + Hydra JWKS only
- Add rate limiting per client identity (`sub` claim)
- Add audit storage integration (metadata only, no payload)
- Pin exact dependency versions after integration testing
