# Decision Log

All architectural, security, and compliance decisions that deviate from the
ideal or industry standard are recorded here with rationale.
Council members are required to raise a critical flag immediately if any
future decision would prevent properly implementing a deferred capability.

---

## DEC-001 — Internal network trust boundary: plain HTTP accepted for Phase 1

**Date:** 2026-03-25
**Status:** Accepted — Phase 1
**Raised by:** Security/Privacy Lead
**Decided by:** Council (all three personas)

### Decision
The MCP server → Presidio worker communication uses plain HTTP over the
Kubernetes cluster internal network for Phase 1. mTLS between services is
deferred post-Phase 1.

### Rationale
- NetworkPolicy (Phase 1 Stream 3) restricts worker ingress to pods carrying
  the `app.kubernetes.io/name: mcp-presidio-sensitivity` label, providing L3/L4
  isolation as the current compensating control.
- mTLS implementation requires cert-manager or a service mesh and adds
  operational complexity beyond Phase 1 scope.
- The current threat model accepts the cluster internal network as trusted for
  Phase 1. This assumption is acknowledged, not overlooked.

### Conditions
This decision is acceptable ONLY if:
1. No current or future code change introduces a pattern that prevents adding
   mTLS later (see compatibility assessment below).
2. The trust boundary assumption is explicitly revisited at Phase 2 planning.

### mTLS Compatibility Assessment (Technical Implementation Lead)
All council members have reviewed current implementation against mTLS readiness:

| Component | mTLS path | Assessment |
|---|---|---|
| `backend/worker_client.py` — httpx AsyncClient | Add `ssl.SSLContext` with client cert to `httpx.AsyncClient(...)` | **Compatible** — no structural change required |
| Worker — uvicorn entrypoint | Add `--ssl-certfile`, `--ssl-keyfile`, `--ssl-ca-certs`, `--ssl-cert-reqs=CERT_REQUIRED` | **Compatible** — uvicorn supports mutual TLS natively |
| Dockerfiles — non-root, read-only filesystem | Certs mounted as Kubernetes Secret volumes at runtime, not baked in | **Compatible** — tmpfs/volume mount pattern already established |
| Helm — NetworkPolicy | mTLS sits alongside NetworkPolicy (L7 identity + L3/L4 restriction); they are complementary | **Compatible** — no policy changes required |
| Helm — containerSecurityContext | `readOnlyRootFilesystem: true` requires certs mounted at a writable path (e.g. `/run/certs`) | **Compatible** — requires volume mount in Helm templates, no code change |

**No current decision blocks mTLS.** The upgrade path is:
cert-manager → Secret → volumeMount → httpx SSLContext + uvicorn flags.

### Critical flag trigger
Any of the following would require immediate escalation to the full council:
- Hardcoding the worker URL in a way that cannot accept an HTTPS scheme
- Using a shared service account that cannot be bound to a certificate identity
- Introducing a sidecar or proxy pattern incompatible with mutual TLS handshake

---

## DEC-002 — Token TTL: reduce from 300s to 60s

**Date:** 2026-03-25
**Status:** Accepted — implement immediately
**Raised by:** Security/Privacy Lead
**Decided by:** Council (all three personas)

### Decision
Reduce the Keycloak access token TTL from 300 seconds to 60 seconds.

### Rationale
- Token revocation (RFC 7009) is not yet implemented. Without revocation, a
  compromised token is valid for its full lifetime.
- 300s combined with no revocation creates an unnecessary exposure window.
- 60s is within the industry standard range and imposes no meaningful overhead
  at current scale (token requests are cheap; JWKS is cached).
- This is a Keycloak realm configuration change — no code change required.

### Implementation
Update the `mcp-local` realm in Keycloak:
- Access Token Lifespan: 60 seconds
- Verify the realm import file is updated so the setting survives a realm
  re-import (e.g. cluster rebuild).

---
