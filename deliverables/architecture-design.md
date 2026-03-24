# Architecture Design: mcp-presidio-sensitivity

**Phase:** 0
**Date:** 2026-03-24
**Status:** Draft — Phase 0 deliverable

---

## 1. Overview

This document describes the architecture of `mcp-presidio-sensitivity`, a sensitivity
classification service exposed as an MCP tool. It covers all components as implemented
or designed in Phase 0.

**Scope of this document:**
- Component responsibilities and boundaries
- Request flow for a successful scan
- Auth and trust model
- Security controls required for MVP
- Data flow and persistence boundaries
- Deployment topology (local and production)
- Key design decisions with decision log references
- Known limitations and deferred items
- Phase 0 exit criteria

**Out of scope:**
- Final enterprise classification taxonomy (deferred to Phase 4 — spec §6)
- Queue-based worker dispatch (Option B — recommended path, deferred to Phase 2)
- Payload release workflows (Phase 3)
- Multi-language support and structured document handling (Phase 4)
- Tenant-specific recognizers (Phase 4)

---

## 2. System Context

**Callers:** Agents and automated services only. No human invokes this tool directly
in production. Developer use is integration testing only. This is a service-to-service
integration.

**Auth:** OAuth 2.0 client credentials flow. Hydra (ORY) is the Authorization Server.
Callers present JWT bearer tokens.

**What this service does:** Accept a text payload, run an ephemeral Presidio-backed
sensitivity scan, and return only a bounded summary result. The payload is never
returned, logged, or persisted.

**What this service does not do:**
- Redact or transform payload content
- Store payload data in any form
- Return matched substrings or offsets
- Make authorization decisions for the calling agent's downstream workflow — it
  returns a `decision` field (allow / flag / block / review) that the caller may
  act on, but enforcement is the caller's responsibility

**External dependencies:**
- Keycloak AS: token issuance and JWKS endpoint
- Presidio Analyzer: embedded as a Python library in the worker process

---

## 3. Component Architecture

Three components. Each has a distinct responsibility boundary.

```
+----------------------------------------------------------+
|  EXTERNAL CALLER (agent or service)                      |
|  OAuth client credentials → JWT bearer token             |
+---------------------------+------------------------------+
                            |
                            | HTTPS  Bearer JWT
                            v
+---------------------------+------------------------------+
|  HYDRA AUTHORIZATION SERVER                              |
|  - Issues access tokens (client credentials flow)        |
|  - Hosts JWKS endpoint for public key distribution       |
|  - Validates client identity and scope at issuance       |
+---------------------------+------------------------------+
                            |
                            | Bearer JWT (in Authorization header)
                            v
+---------------------------+------------------------------+
|  MCP SERVER  [mcp-presidio-sensitivity]                  |
|  Trust boundary — all callers are untrusted until here   |
|                                                          |
|  FastAPI + JWTAuthMiddleware                             |
|  - Verifies Bearer JWT (RS256, iss, aud, exp, nbf)       |
|  - Checks scope (tools:classify.submit)                  |
|  - Rejects 401/403 before reading request body           |
|  - Strips Authorization header before any backend call   |
|  - Emits structured audit log (no payload content)       |
|                                                          |
|  FastMCP (MCP SDK)                                       |
|  - Tool: classify_payload_sensitivity                    |
|  - MCP protocol framing, tool registration               |
|  - Mounted at /mcp — all /mcp* requests require auth     |
|                                                          |
|  WorkerClient (httpx)                                    |
|  - POSTs to /scan on the worker                          |
|  - Headers: Content-Type + X-Correlation-ID only         |
|  - No Authorization header forwarded                     |
+---------------------------+------------------------------+
                            |
                            | HTTP (cluster-internal, ClusterIP)
                            | No Authorization header
                            v
+---------------------------+------------------------------+
|  PRESIDIO WORKER  [presidio-worker]                      |
|  ClusterIP only — unreachable from outside cluster       |
|                                                          |
|  FastAPI                                                 |
|  - Guard 1: content-type allowlist (before body read)    |
|  - Guard 2: payload size limit (1 MiB)                   |
|  - Guard 3: schema validation                            |
|  - Guard 4: content_type field consistency check         |
|                                                          |
|  PresidioAnalyzerWrapper                                 |
|  - Embedded presidio-analyzer (library mode)             |
|  - Allowlisted entity types only                         |
|  - Strips RecognizerResult objects immediately           |
|  - Returns only {entity_type, score} per finding         |
|                                                          |
|  Minimizer                                               |
|  - Classification model (interim taxonomy)               |
|  - Severity band computation                             |
|  - Decision mapping                                      |
|  - Bounded ScanResponse — no payload, no offsets         |
+----------------------------------------------------------+
```

### Component responsibilities summary

| Component | Owns |
|-----------|------|
| Hydra AS | Token issuance, JWKS, scope grant |
| MCP Server | Trust boundary, JWT validation, scope enforcement, audit logging, worker dispatch |
| Presidio Worker | Payload analysis, result minimization, payload non-leakage within the scan path |

---

## 4. Request Flow

A successful `classify_payload_sensitivity` invocation proceeds as follows:

```
1. Caller acquires token
   POST http://hydra:4444/oauth2/token
   grant_type=client_credentials
   scope=tools:classify.submit
   → 200 {access_token, token_type: Bearer, ...}

2. Caller invokes MCP tool
   POST http://mcp-server:8000/mcp
   Authorization: Bearer <access_token>
   {MCP protocol envelope wrapping classify_payload_sensitivity args}

3. JWTAuthMiddleware fires (before body is read)
   a. Extract Bearer token from Authorization header
   b. Fetch signing key from Hydra JWKS URI (cached, TTL 300s)
   c. jwt.decode() — RS256, verify iss + aud + exp + nbf
   d. Extract scopes from scp claim (fallback: scope)
   e. Check tools:classify.submit in scopes
   f. On failure → 401 or 403 (no body parsed, no payload seen)
   g. On success → inject claims into request.state + ContextVar

4. FastMCP processes MCP protocol, invokes tool handler
   classify_payload_sensitivity(content, content_type, ...)

5. Tool handler calls worker
   POST http://presidio-worker.mcp-presidio.svc.cluster.local:8080/scan
   Content-Type: application/json
   X-Correlation-ID: <uuid>
   {content, content_type, language, tenant_policy, ...}
   NOTE: Authorization header is NOT forwarded

6. Worker guards (in order, before analysis)
   a. Content-type header allowlist check
   b. Payload size check (≤ 1 MiB)
   c. Schema validation (Pydantic)
   d. content_type body field consistency check

7. Worker analysis
   AnalyzerEngine.analyze(text=content, language=..., entities=[...])
   RecognizerResult objects stripped immediately → [{entity_type, score}]
   del scan_request (removes reference to raw payload)

8. Minimizer produces bounded result
   - compute_severity_band(findings)
   - severity_to_decision(band)
   - derive_categories(entity_types)
   → ScanResponse (no payload, no offsets, no matched text)

9. Worker returns ScanResponse to MCP server
   {scan_id, sensitivity_detected, max_severity_band,
    matched_categories, decision, confidence_summary,
    policy_profile, detector_version, timestamp}

10. MCP server returns bounded result to caller via MCP protocol
    Authorization header was already stripped at step 5 — not echoed
```

**Error paths:** Any failure at steps 3–8 returns a sanitised error code and message.
No payload content, matched substrings, raw exception messages, or token fragments
appear in any error response or log line at any step.

---

## 5. Auth and Trust Model

### Trust boundary

The MCP server is the OAuth resource server and the single trust boundary.
Presidio operates inside the trust boundary as a detection tool, not a security control.

```
[Untrusted callers] → [MCP Server — trust boundary] → [Presidio Worker — private network]
```

The worker is not the trust boundary. It is an internal component, reachable only
via cluster-internal DNS. It performs no caller authentication.

### What is validated at the MCP server

| Check | Mechanism |
|-------|-----------|
| Bearer token present | Authorization header parse |
| RS256 signature | PyJWT + JWKS public key |
| Issuer (`iss`) | Must match `ISSUER_URL` config |
| Audience (`aud`) | Must contain `AUDIENCE` config |
| Expiry (`exp`) | Must be in the future |
| Not-before (`nbf`) | Validated if present |
| Scope | `tools:classify.submit` must be in `scp` claim |

Algorithm is pinned to RS256. `alg: none` and symmetric algorithms are rejected.
JWKS public keys are never hardcoded — always fetched from the configured Hydra URI.

### Token passthrough

The caller's `Authorization` header is never forwarded to the worker. The `headers`
dict in `worker_client.py` is constructed from scratch with `Content-Type` and
`X-Correlation-ID` only. There is no code path that copies the inbound header.

### Scope model

| Scope | Required for |
|-------|-------------|
| `tools:classify.submit` | All MCP tool invocations (all `/mcp*` paths) |
| `tools:health.read` | Documented in PRM metadata — not enforced on `/health` (see section 6) |

Internal context passed to worker: `source_system`, `workflow_id` (correlation ID).
Caller identity (`sub` claim) is used for audit logging at the MCP server layer only.

### Protected Resource Metadata

`GET /.well-known/oauth-protected-resource` (unauthenticated) returns the PRM document
per RFC 9728. Discloses the AS URL and supported scopes — both are intentionally public.

---

## 6. Security Controls

These controls are non-negotiable for Phase 0 and must hold before the phase exits.

### Payload non-leakage

- Raw payload text never appears in any log statement at either component.
- `RecognizerResult` objects (which carry start/end offsets) are stripped immediately
  in `analyzer.py` before the findings list leaves the function. Callers receive only
  `{entity_type, score}`.
- `del body_bytes` and `del scan_request` are called explicitly in `worker/main.py`
  after the analysis phase to remove payload references.
- All error responses at the worker contain only `error_code` and `message` — both
  set to fixed strings, not derived from exception messages or input data.
- `WorkerError` at the MCP server carries only `error_code` and `message` — no
  response body content is propagated.

### Worker isolation

- Non-root: `runAsUser: 1000`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`
- Read-only root filesystem: `readOnlyRootFilesystem: true`
- All capabilities dropped: `capabilities.drop: [ALL]`
- `/tmp` mounted as memory-backed `emptyDir` (Decision #16) — satisfies read-only
  root filesystem while allowing uvicorn and spaCy temporary writes without disk
  access on the node
- Resource limits: 512 MiB memory, 500m CPU

### No token passthrough

Enforced structurally — `worker_client.py` constructs the outbound headers dict
from scratch. See section 5.

### Read-only filesystem

`readOnlyRootFilesystem: true` on both the worker and MCP server containers.
Memory-backed `emptyDir` volumes provide writable `/tmp` where needed.

### Non-root

Both containers run as non-root users (UID 1000 for worker, UID 1001 for MCP server)
with `runAsNonRoot: true` enforced.

### OpenAPI docs disabled

`docs_url`, `redoc_url`, and `openapi_url` are set to `None` on both FastAPI
applications in production (Decision #15). Reduces attack surface.

### Health endpoint auth exemption

`GET /health` requires no authentication. Kubernetes liveness/readiness probes
cannot present Bearer tokens. The endpoint returns only `{"status": "ok"}` and
exposes no sensitive information. Accepted deviation from auth spec — Decision #22.

### Result minimization

The `ScanResponse` contains only: `scan_id`, `status`, `sensitivity_detected`,
`max_severity_band`, `matched_categories`, `decision`, `confidence_summary`
(highest score + findings count, no source data), `policy_profile`, `detector_version`,
`timestamp`. No payload, no matched substrings, no offsets, no raw spans.

---

## 7. Data Flow and What Is Never Persisted

### What flows through the system

```
Caller → MCP Server:  {content, content_type, language, tenant_policy, ...}
MCP Server → Worker:  same fields + {source_system, workflow_id}
Worker → MCP Server:  ScanResponse (bounded summary, no payload)
MCP Server → Caller:  ScanResponse (bounded summary, no payload)
```

### What is logged (audit metadata only)

At the MCP server (per request):
- `correlation_id`
- `caller_subject` (`sub` claim)
- `tool` (path)
- `auth_decision` (allow / deny-401 / deny-403 / exempt)
- `worker_status` (if available)
- `duration_ms`

At the worker (per scan):
- `scan_id`
- `decision`
- `max_severity_band`
- `findings_count`
- `policy_profile`
- `detector_version`

### What is never logged or persisted anywhere

- Source payload (`content`)
- Matched substrings or text offsets
- Raw `RecognizerResult` objects
- Any fragment of the caller's Bearer token
- Exception messages derived from input data

### Persistence

Phase 0 has no audit store. Structured log lines are the only persistent record.
An audit store (metadata only, no payload) is a Phase 1 item.

---

## 8. Deployment Topology

### Local (kind)

```
kind cluster (single node)
  Namespace: mcp-presidio

  Services:
    hydra               ClusterIP  4444 (public), 4445 (admin)
    presidio-worker     NodePort   8080 → containerPort 30808
    mcp-presidio-sensitivity  NodePort  8000 → containerPort 30800

  kind extraPortMappings (kind-config.yaml):
    containerPort 30444 → hostPort 4444   (Hydra public)
    containerPort 30445 → hostPort 4445   (Hydra admin)
    containerPort 30808 → hostPort 8080   (worker)
    containerPort 30800 → hostPort 8000   (MCP server)

  localhost access:
    http://localhost:4444  — Hydra public (token issuance, JWKS)
    http://localhost:4445  — Hydra admin  (client registration)
    http://localhost:8080  — Worker /scan (direct debug access preserved)
    http://localhost:8000  — MCP server   /mcp
```

The ory/hydra Helm chart does not support the `nodePort` field in values.
Hydra services are patched post-deploy via `kubectl patch` in `setup-local.sh` (Decision #18).

NodePort for the worker is preserved in local dev for direct testing and demo use.
In production this service type reverts to ClusterIP.

### Production mapping

Environment promotion is a values file swap — the deployment model does not change.

| Setting | Local | Production |
|---------|-------|------------|
| Worker `service.type` | NodePort | ClusterIP |
| MCP server `service.type` | NodePort | ClusterIP |
| Hydra JWKS URI | patched NodePort | cluster DNS |
| Worker URL | cluster DNS (same) | cluster DNS |

Worker is unreachable from outside the cluster in production regardless of local
NodePort configuration, because production sets `service.type: ClusterIP` (Decision #17).

### Helm chart structure

```
helm/
  mcp-server/
    values.yaml          — production defaults (ClusterIP, cluster DNS hostnames)
    templates/           — Deployment, Service, ConfigMap, ServiceAccount, RBAC
  presidio-worker/
    values.yaml          — production defaults (ClusterIP, resource limits)
    templates/           — Deployment, Service, ConfigMap, ServiceAccount, RBAC

infrastructure/
  kind-config.yaml       — kind cluster definition with extraPortMappings
```

Local overrides are applied via `--values values.local.yaml` at helm install/upgrade.
The values files in the chart are production defaults.

---

## 9. Key Design Decisions

The following decisions have the most architectural impact. Full decision log is in
`planning/task_plan.md`.

**Decision #2 — Embedded library mode for Presidio**
Presidio is imported as a Python library inside the worker process, not deployed as a
sidecar REST service. This eliminates an intra-cluster network hop for every scan,
keeps the payload within a single process boundary, and fits the ephemeral worker model.
Per-job isolation is stronger because there is no shared Presidio process state.

**Decision #3 — Direct HTTP dispatch (Phase 0); queued dispatch recommended for Phase 2+**
Phase 0 uses synchronous HTTP from MCP server to worker. The spec recommends Option B
(queued worker dispatch) for production because it gives better isolation under load
spikes, a natural retry hook, and better fit for future scale. Queue-based dispatch
is a Phase 2 item.

**Decision #7 — Helm from Phase 0**
All deployment is via Helm from the start. Local environment mirrors production topology —
isolation, network policies, and resource limits are real and tested, not retrofitted.
Environment promotion is a values file swap, not a runtime model change.

**Decision #8 — Hydra (ORY) as Authorization Server**
Purpose-built for machine-to-machine OAuth client credentials. Lighter than Keycloak.
No UI overhead. Official Helm chart. JWT bearer assertions preferred over client secrets
per the auth spec.

**Decision #13 — AnalyzerEngine as module-level singleton**
Loading spaCy NLP models on every request would be prohibitively slow. AnalyzerEngine
is stateless with respect to input text; sharing one instance across concurrent requests
is safe. Pre-warmed at startup to avoid cold-start latency on the first scan.

**Decision #14 — Raw RecognizerResult objects stripped immediately in analyzer.py**
`RecognizerResult` carries `start`, `end`, and matched text context (effectively a
payload excerpt). These objects are stripped before the findings list leaves
`analyzer.py`. Callers receive only `{entity_type, score}`. This is the primary
structural enforcement of the payload non-leakage contract within the worker.

**Decision #16 — /tmp as memory-backed emptyDir**
`readOnlyRootFilesystem: true` is required by security policy. uvicorn and spaCy need
writable temporary storage. A memory-backed `emptyDir` volume mounted at `/tmp`
satisfies both constraints without writing to the node's disk.

**Decision #17 — Worker ClusterIP in production, NodePort in local**
Worker must not be reachable from outside the cluster in production. ClusterIP enforces
this. Local dev uses NodePort with kind `extraPortMappings` for fixed localhost ports,
avoiding the need for `kubectl port-forward` (which requires manual restart on pod rollover).

**Decision #20 — MCP Python SDK (FastMCP) not plain FastAPI**
Full MCP protocol compliance from Phase 0. The SDK handles tool registration, protocol
framing, and message serialization. JWT middleware is mounted on top of the SDK's
FastAPI integration point. The MCP app is mounted at `/mcp`; the JWT middleware
intercepts all `/mcp*` requests before the SDK sees them.

**Decision #19 — DATE_TIME severity mapping is a known calibration problem**
DATE_TIME is currently mapped to `direct_identifier` (high severity → block decision).
Empirical testing in Phase 0 showed this fires on benign business text containing
temporal language ("next month", "quarterly"), producing high-severity blocks on
non-sensitive payloads. Severity mapping for DATE_TIME is deferred to Phase 1
classification calibration.

---

## 10. Known Limitations and Deferred Items

### DATE_TIME false positive (Decision #19)

DATE_TIME maps to `direct_identifier` → `high` severity → `block` decision. Benign
date references in business text trigger this path. The current classification model
has no context-gating — a single DATE_TIME detection at any confidence level causes
a block. This is the highest-priority calibration item for Phase 1.

### Classification taxonomy is a placeholder (Decision #1)

The seven category groups and four severity bands are operational placeholders, not
approved governance labels. The full enterprise classification taxonomy requires
stakeholder alignment beyond engineering and is deferred until Phase 1 generates
empirical detector behavior data.

### AGE and AWS_ACCESS_KEY recognizers missing (Decision #12)

Both entity types are in the category mapping in `classification.py` but excluded from
`APPROVED_ENTITY_TYPES` in `analyzer.py`. `AGE` is not a Presidio built-in recognizer.
`AWS_ACCESS_KEY` is not in the standard Presidio built-in set. Custom recognizers are
a Phase 1 item. Category mappings are retained so they take effect without code changes
when the recognizers are added.

### Line-break evasion is a known gap (Decision #11)

SSNs and similar patterns split across newlines are not detected — this is a regex
recognizer limitation. Documented as an expected false negative in the Phase 0 corpus.
Evasion-resistant scanning is a Phase 2+ concern.

### No audit store in Phase 0

Structured log lines are the only persistent record. An audit store (metadata only,
no payload) is a Phase 1 item.

### Queue-based worker dispatch not implemented

Direct synchronous HTTP dispatch is used in Phase 0. Queue-based dispatch (Option B,
spec §3.3) is the recommended production path and is deferred to Phase 2.

### JWKS cache is not thread-safe

The current JWKS cache is managed by `PyJWKClient`'s internal cache. For Phase 0
single-replica deployment this is acceptable. Phase 1 should verify concurrent expiry
behavior under load.

### Scope check is at HTTP path level only

The MCP SDK routes all tool calls through `/mcp`. The JWT middleware enforces
`tools:classify.submit` on all `/mcp*` requests. The actual tool name is inside
the MCP protocol envelope, which the middleware does not inspect. Per-tool scope
enforcement at the protocol level is a Phase 1 improvement.

---

## 11. Phase 0 Exit Criteria

From `planning/task_plan.md`:

- Full local stack running via Helm (`helm install` or `helm upgrade`)
- Test client can obtain a token from Hydra and invoke `classify_payload_sensitivity`
- Valid token + correct scope → bounded result returned
- Invalid/missing token → 401 returned
- Valid token + wrong scope → 403 returned
- No raw payload returned in any response including error paths
- Failure paths documented and understood
