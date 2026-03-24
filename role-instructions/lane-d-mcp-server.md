# Agent Briefing: Lane D — MCP Server
**Phase:** 0
**Status:** Ready to start
**Blocked by:** Nothing — start immediately
**Blocks:** Phase 0 exit criteria (end-to-end auth flow validation)

---

## Read before starting

| File | Location |
|------|----------|
| Ways of working | `role-instructions/ways-of-working.md` |
| Task plan | `planning/task_plan.md` |
| Findings | `planning/findings.md` |
| MVP spec | `shared/private/mcp_presidio_mvp_spec.md` — §1, §2, §4 |
| Auth engineering spec | `shared/private/mcp_auth_engineering_spec.md` — all sections |
| Worker design notes | `deliverables/lane-b/worker-design-notes.md` |
| Token validation report | `deliverables/lane-a/token-validation-report.md` |

Pay particular attention to:
- Auth spec §3 — recommended auth model (OAuth enforced in MCP server)
- Auth spec §4 — all functional requirements, especially FR-4 (token validation) and FR-6 (backend mediation)
- Auth spec §7 — backend trust model (no token passthrough)
- MVP spec §1.3 — MCP server runtime responsibilities
- MVP spec §4.3 — security controls required at MVP

---

## What you are building

The MCP server is the trust boundary and control plane for the entire system. It sits between the caller (agent or service) and the Presidio worker.

```
[Caller — agent or service]
    |
    | HTTP POST with Bearer JWT
    v
[MCP Server]  ← YOU ARE BUILDING THIS
    - validate JWT (signature, issuer, audience, expiry, scope)
    - return 401 if no/invalid token
    - return 403 if valid token but wrong scope
    - proxy scan request to Presidio worker (no token passthrough)
    - return bounded result to caller
    |
    | internal HTTP (no auth header forwarded)
    v
[Presidio Worker]  ← already built and running
    http://presidio-worker.mcp-presidio.svc.cluster.local:8080
```

---

## Confirmed inputs from Group 1

### From Lane A — Hydra OAuth configuration

| Parameter | Confirmed value |
|-----------|----------------|
| Issuer URL (in-cluster) | `http://hydra.mcp-presidio.svc.cluster.local:4444` |
| JWKS URI (in-cluster) | `http://hydra.mcp-presidio.svc.cluster.local:4444/.well-known/jwks.json` |
| Expected audience | `mcp-presidio-server` |
| Signing algorithm | `RS256` |
| Scope — submit scan | `tools:classify.submit` |
| Scope — health check | `tools:health.read` |
| Token format | JWT; scope claim is `scp` (array), not `scope` (string) |

**Important:** Hydra uses `scp` as the scope claim name (not the standard `scope`). Your token verifier must read `scp` when extracting scopes from the token.

### From Lane B — Presidio worker

| Parameter | Confirmed value |
|-----------|----------------|
| Worker internal URL | `http://presidio-worker.mcp-presidio.svc.cluster.local:8080` |
| Scan endpoint | `POST /scan` |
| Health endpoint | `GET /health` |
| Request Content-Type | `application/json` |
| Supported payload content_types | `text/plain`, `application/json` |
| Max payload size | 1 MiB (enforced by worker — also enforce at MCP layer) |

Worker request schema (send this body to `POST /scan`):
```json
{
  "content": "string (required)",
  "content_type": "text/plain | application/json (required)",
  "language": "en",
  "tenant_policy": "default",
  "threshold_profile": "default",
  "return_details": false,
  "request_metadata": {
    "source_system": "mcp-server",
    "workflow_id": "<correlation_id>"
  }
}
```

Worker response schema (pass this through to the caller, unchanged):
```json
{
  "scan_id": "uuid",
  "status": "completed",
  "sensitivity_detected": true,
  "max_severity_band": "high",
  "matched_categories": ["financial_identifier"],
  "entity_summary": {"CREDIT_CARD": 1},
  "decision": "block",
  "confidence_summary": {"highest_score": 1.0, "findings_count": 1},
  "policy_profile": "default",
  "detector_version": "presidio-2.2.362",
  "timestamp": "2026-03-24T00:00:00Z"
}
```

---

## What to build for Phase 0

Phase 0 requires enough to validate the authenticated end-to-end flow. It does not require audit storage, rate limiting, or queue dispatch — those are Phase 1.

### Required for Phase 0

**1. MCP server using the Python MCP SDK**
- Use the `mcp` Python SDK (`fastmcp` interface) for tool registration and MCP protocol handling
- Transport: Streamable HTTP (not SSE — better for agent callers)
- Register the tool `classify_payload_sensitivity` using the `@mcp.tool()` decorator
- Mount the MCP SDK app on FastAPI so JWT middleware can be applied
- Expose `GET /health` — no auth required, probe-compatible
- Expose `GET /.well-known/oauth-protected-resource` — Protected Resource Metadata (see auth spec §4, FR-3)

**2. JWT validation middleware**
On every request to protected endpoints:
- Fetch signing keys from JWKS URI (cache with TTL of 5 minutes)
- Verify RS256 signature
- Verify `iss` matches configured issuer
- Verify `aud` contains `mcp-presidio-server`
- Verify `exp` is in the future
- Verify `nbf` if present
- Return `401` with `WWW-Authenticate: Bearer` challenge if any check fails

**3. Scope authorization**
After token validation:
- `POST /tools/classify_payload_sensitivity` requires scope `tools:classify.submit`
- `GET /health` requires scope `tools:health.read` (or no auth — see clarifications)
- Return `403 Forbidden` if valid token lacks required scope

**4. Backend adapter**
After successful authn/authz:
- Forward the scan request to the Presidio worker
- Pass `correlation_id` (generated or from request metadata) in `request_metadata.workflow_id`
- Do NOT forward the caller's `Authorization` header to the worker
- Translate worker error responses into MCP-appropriate error responses
- If the worker is unreachable, return a `503` with error code `SCAN_FAILED`

**5. Protected Resource Metadata endpoint**
```json
{
  "resource": "http://mcp-server.mcp-presidio.svc.cluster.local:<PORT>",
  "authorization_servers": [
    "http://hydra.mcp-presidio.svc.cluster.local:4444"
  ],
  "bearer_methods_supported": ["header"],
  "scopes_supported": ["tools:classify.submit", "tools:health.read"]
}
```

**6. Structured logging**
Log on every request (no payload content in any log line):
- `correlation_id`
- `caller_subject` (from JWT `sub` claim)
- `tool` (endpoint called)
- `auth_decision` (allow / deny-401 / deny-403)
- `worker_status` (if backend was called)
- `duration_ms`
- `timestamp`

---

## Security constraints — non-negotiable

These are carried forward from the worker review and auth spec. Violations block Security/Privacy Lead sign-off.

| Rule | Requirement |
|------|-------------|
| No token passthrough | Never forward the caller's `Authorization` header to the worker |
| No payload logging | Never log `content` or any matched substrings |
| No payload in error responses | Error responses contain only error code and message |
| 401 before any business logic | Token validation must happen before the request body is read |
| JWKS must be fetched from issuer | Do not hardcode public keys |
| Audience must be validated | Reject tokens not intended for `mcp-presidio-server` |
| Correlation ID on all requests | Every request gets a UUID correlation ID, logged and forwarded to worker |

---

## File structure

```
src/mcp_server/
  main.py              ← FastAPI app entrypoint, MCP SDK mount, middleware wiring
  auth/
    token_verifier.py  ← JWT validation, JWKS fetch + cache
    claims.py          ← Claim extraction helpers (scp → scope set)
    errors.py          ← Auth error types and 401/403 response builders
  authorization/
    policy.py          ← Tool → required scope mapping, allow/deny decision
  tools/
    classify.py        ← classify_payload_sensitivity tool handler
  backend/
    worker_client.py   ← HTTP client for Presidio worker
    models.py          ← Internal request/response models
  observability/
    logging.py         ← Structured log configuration
  config.py            ← Issuer URL, JWKS URI, audience, worker URL, port
  models.py            ← Request/response Pydantic models for the MCP endpoint
Dockerfile
helm/
  mcp-server/
    Chart.yaml
    values.yaml
    values.local.yaml
    templates/
      deployment.yaml
      service.yaml
      configmap.yaml
```

---

## Dockerfile requirements

```dockerfile
FROM python:3.11-slim
# Non-root user (uid 1001 — distinct from worker uid 1000)
# No secrets baked in
# CPU/memory limits via Helm
```

---

## Helm chart requirements

`values.yaml` must include:
```yaml
resources:
  limits:
    memory: 256Mi
    cpu: 500m
  requests:
    memory: 128Mi
    cpu: 100m

config:
  issuerUrl: "http://hydra.mcp-presidio.svc.cluster.local:4444"
  jwksUri: "http://hydra.mcp-presidio.svc.cluster.local:4444/.well-known/jwks.json"
  audience: "mcp-presidio-server"
  workerUrl: "http://presidio-worker.mcp-presidio.svc.cluster.local:8080"
  jwksCacheTtlSeconds: 300
```

`values.local.yaml` must set:
```yaml
service:
  type: NodePort
  port: 8000
  nodePort: 30800
```

---

## Deliverables

| File | Location |
|------|----------|
| MCP server source | `src/mcp_server/` |
| Dockerfile | `src/mcp_server/Dockerfile` |
| Helm chart | `helm/mcp-server/` |
| `mcp-server-design-notes.md` | `deliverables/lane-d/` |
| `security-checklist.md` | `deliverables/lane-d/` |

Write all files to disk. **Do not commit or push — the coordinator handles all git operations.**

---

## Definition of done

- [ ] `GET /health` returns `{"status": "ok"}`
- [ ] `POST /tools/classify_payload_sensitivity` with no token returns `401` with `WWW-Authenticate` header
- [ ] Valid token + correct scope → worker is called, bounded result returned to caller
- [ ] Valid token + wrong scope → `403 Forbidden`
- [ ] Invalid token (bad signature, wrong issuer, wrong audience, expired) → `401`
- [ ] Caller's `Authorization` header is NOT forwarded to the worker (verified in design notes)
- [ ] No payload content in any log line (verified manually)
- [ ] `GET /.well-known/oauth-protected-resource` returns valid PRM document
- [ ] Helm chart deploys cleanly to `mcp-presidio` namespace
- [ ] `security-checklist.md` completed
- [ ] All decisions logged in completion summary for coordinator

---

## Handoff

When done, notify the coordinator. Flag for Security/Privacy Lead review of:
- Token passthrough guarantee (confirm `Authorization` header is not forwarded)
- Failure path analysis (confirm no payload content leaks on worker error, timeout, or schema rejection)
