# Decision Log

All architectural, security, and compliance decisions that deviate from the
ideal or industry standard are recorded here with rationale.
Council members are required to raise a critical flag immediately if any
future decision would prevent properly implementing a deferred capability.

---

## DEC-004 — Local cluster platform: migrate from kind to k3d before Phase 2

**Date:** 2026-03-25
**Status:** Accepted — pre-Phase 2 gate
**Raised by:** Technical Implementation Lead / Product Lead
**Decided by:** Council (all three personas)

### Decision
Migrate the local development cluster from kind to k3d before Phase 2 work begins.
kind remains in use for Phase 1 completion. No Phase 1 deliverable is blocked.

### Rationale
kind was the correct Phase 1 choice: zero prerequisites beyond Docker, minimal config,
deterministic setup. Three Phase 2 concerns make it the wrong choice going forward:

1. **No local registry.** Every image change requires `kind load docker-image` — a manual
   step that is slow (~10–30s per image), non-parallelisable with the build, and not
   representative of how images are delivered in any real environment. k3d ships a
   built-in registry (`k3d registry create`) that eliminates this entirely: `docker push`
   to the local registry, and the cluster pulls automatically.

2. **kindnet CNI has partial NetworkPolicy enforcement.** `validate-networkpolicy.sh`
   verifies that NetworkPolicy objects exist with correct selectors, but kindnet does not
   enforce all NetworkPolicy semantics at the kernel level. Phase 2 requires Cilium for
   real eBPF enforcement. k3d supports disabling its default CNI (Flannel) and installing
   Cilium — the same path as kind, but with faster cluster creation so the CNI swap is
   less painful to iterate on.

3. **Phase 2 Istio resource pressure.** Istio control plane (~2 GB), Cilium, Jaeger,
   Presidio (spaCy model ~500 MB loaded), Keycloak, MCP server — all on a single-node
   Docker-in-Docker cluster. k3s (which k3d runs) has a meaningfully lighter control
   plane than full Kubernetes (kind runs kubeadm), freeing headroom for the Istio sidecar
   load.

### What changes
| Component | Current (kind) | Target (k3d) |
|---|---|---|
| Cluster create | `kind create cluster --config kind-config.yaml` | `k3d cluster create` with config or flags |
| Cluster config | `infrastructure/kind-config.yaml` | `infrastructure/k3d-config.yaml` |
| Image load | `kind load docker-image <image> --name <cluster>` | `docker push k3d-mcp-registry:5000/<image>` |
| Image pull policy | `pullPolicy: Never` (both values.local.yaml) | `pullPolicy: Always` |
| Image repository | bare name (`mcp-presidio-sensitivity`) | registry-prefixed (`k3d-mcp-registry:5000/mcp-presidio-sensitivity`) |
| Port mapping | `extraPortMappings` in kind-config.yaml | `--port` flags in k3d config (same host ports) |
| Cluster check | `kind get clusters \| grep ...` | `k3d cluster list \| grep ...` |
| Teardown | `kind delete cluster --name ...` | `k3d cluster delete ...` (+ registry delete) |
| CNI (Phase 2) | kindnet → Cilium swap | Flannel → Cilium swap (same procedure) |
| Prerequisites | kind binary | k3d binary (kind binary removed) |

### What does not change
- All Kubernetes manifests (keycloak-local.yaml, jaeger.yaml, NetworkPolicy templates)
- All Helm chart templates and values.yaml (production values unchanged)
- All Dockerfiles
- All application source code and tests
- kubectl, helm, docker — same versions
- The overall dev workflow (setup → rebuild → test → demo)

### Work breakdown
The migration is scoped to infrastructure and scripts only. No application code changes.

**Phase A — Cluster and registry setup**
- A1. Add k3d to prerequisites table in CLAUDE.md; remove kind entry
- A2. Create `infrastructure/k3d-config.yaml` with port mappings matching current kind config
- A3. Update `setup-local.sh`:
  - Step 0: create k3d registry (`k3d-mcp-registry` on port 5000) if not exists
  - Replace `kind create/delete/get clusters` with k3d equivalents
  - Replace `kind load docker-image` with `docker push` to local registry

**Phase B — Image workflow**
- B1. Update `rebuild.sh`: replace `kind load docker-image` with `docker tag` + `docker push` to registry
- B2. Update `helm/mcp-server/values.local.yaml`: pullPolicy → Always, repository → registry-prefixed name
- B3. Update `helm/presidio-worker/values.local.yaml`: same

**Phase C — Supporting scripts**
- C1. Update `status.sh`: replace `kind get clusters` with `k3d cluster list`
- C2. Update `scripts/README.md`: remove kind load references; document registry workflow
- C3. Remove `infrastructure/kind-config.yaml`

**Phase D — Validation (full regression)**
- D1. `./scripts/setup-local.sh` from scratch — cluster up, images loaded, all pods Running
- D2. `./scripts/status.sh` — all checks green
- D3. `./scripts/test.sh` — 42/42
- D4. `./scripts/auth-test.sh` — all 5 cases pass
- D5. `./scripts/validate-networkpolicy.sh` — all cases pass
- D6. `./scripts/demo.sh a` — full end-to-end including Jaeger trace

**Phase E — Optional: Cilium CNI (Phase 2 prep)**
- E1. Add `--k3s-arg '--flannel-backend=none@server:0'` to k3d config to disable Flannel
- E2. Install Cilium via Helm at cluster creation time in setup-local.sh
- E3. Re-run validate-networkpolicy.sh to verify enforcement under Cilium
- This phase is Phase 2 work, not pre-Phase 2 gate

### Critical flag trigger
Any change to Helm chart image references or values.yaml structure that hardcodes
the `k3d-mcp-registry:5000` registry prefix into the production values.yaml (not
values.local.yaml) would permanently couple the production chart to a local dev
registry. All registry-prefixed values must stay in values.local.yaml only.

### Wave 3 validation findings (2026-03-26)

Confirmed during D1–D6 regression run. Material corrections to assumptions above:

**Flannel enforces NetworkPolicy — Cilium not required for basic enforcement.**
DEC-004 rationale stated kindnet did not enforce NetworkPolicy and implied Cilium
was needed. Wave 3 confirmed that k3s v1.30.4+k3s1 with Flannel enforces
NetworkPolicy ingress rules at the kernel level. `validate-networkpolicy.sh`
cases 13 and 14 (non-MCP pod → worker denied) now run live and pass. Cilium
remains the Phase 2 target for eBPF-level L7 identity enforcement, but basic
NetworkPolicy enforcement is already real without it.

**Registry push address splits into two values.**
The `k3d-mcp-registry` hostname is resolvable only within the k3d Docker network
(cluster nodes can reach it). From the host or devtools container, push must use
`localhost:5000`. Kubernetes manifests reference `k3d-mcp-registry:5000/image`
(cluster-internal). These are two names for the same registry — the image path
after the hostname is what matters. Scripts use `REGISTRY_PUSH=localhost:5000`;
`values.local.yaml` retains `k3d-mcp-registry:5000/` as the repository prefix.

**MCP server NetworkPolicy requires an open external ingress rule.**
The original NetworkPolicy template only allowed Prometheus scraping on port 8000.
NodePort traffic (client → serverlb → DNAT → pod) appeared to the NetworkPolicy
as traffic from an unlabelled source, so it was dropped. Fix: added an ingress
rule with no `from` selector on port 8000, allowing all external client traffic.
The worker NetworkPolicy is unchanged — external access to the worker is correctly
blocked per DEC-001.

**`serverResourceUrl` must be set in `values.local.yaml`.**
The MCP server defaults `SERVER_RESOURCE_URL` to the cluster-internal service DNS
name. This causes `resource_metadata` in the 401 WWW-Authenticate header to point
to an unreachable URL for external clients (RFC 9728 discovery chain breaks for
any client running outside the cluster). Fix: override to `http://localhost:8000`
in `values.local.yaml`. Production deployments must set this to the real external
URL of the MCP server.

**Devtools container pattern established for toolchain isolation.**
`infrastructure/devtools.Dockerfile` and `scripts/devtools-run.sh` provide a
pinned toolchain (k3d v5.7.4, kubectl v1.30.0, helm v3.14.4) without host binary
dependencies. All infrastructure operations route through
`./scripts/devtools-run.sh <command>`. Host scripts (demo.sh, test.sh, classify.sh)
run directly since they use Docker (test.sh) or curl/python3 (available on host).

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

## DEC-003 — Phase 2 infrastructure: Istio + Envoy for auth, policy, and mTLS

**Date:** 2026-03-25
**Status:** Accepted — Phase 2 target
**Raised by:** Product Lead (platform engineering perspective)
**Decided by:** Product Lead

### Decision
Phase 2 will introduce Istio (Envoy sidecar) as the service mesh for the
mcp-presidio cluster. Auth enforcement, rate limiting, and mTLS will move
from application code into the mesh layer.

### Rationale
Phase 1 required the MCP server to own JWT validation, scope enforcement,
RFC 9728 discovery compliance, rate limiting (SlowAPI), and JWKS caching
as application code. This was the correct Phase 1 trade-off for speed, but
it creates compounding tech debt:
- Security policy is coupled to the application release cycle.
- Each new Phase 1 stream adds more cross-cutting concern to the app.
- Local dev diverged from any realistic prod topology (kindnet vs real CNI).
- Migrating these concerns out later carries regression risk and re-testing cost.

The platform engineering position: define the target infrastructure first,
deploy simplified versions of it early, and never have the app own what the
mesh can own.

### What moves to Istio/Envoy in Phase 2
| Concern | Current owner | Phase 2 owner |
|---|---|---|
| JWT signature validation + JWKS caching | `auth/token_verifier.py` | Envoy JWT authn filter |
| Scope enforcement | `authorization/policy.py` | Envoy RBAC filter / Istio AuthorizationPolicy |
| Rate limiting | SlowAPI in `main.py` | Envoy rate limit filter |
| mTLS between MCP server and worker | Plain HTTP (DEC-001) | Istio sidecar (resolves DEC-001) |
| NetworkPolicy (L3/L4) | Kubernetes NetworkPolicy | Istio + Cilium (L7 identity) |
| RFC 9728 discovery endpoint | `main.py` route | Stays in app — has service-specific semantics |
| Audit trail | `audit/trail.py` | Stays in app — has data semantics mesh cannot know |

### What stays in the app
- `classify_payload_sensitivity` tool handler — business logic
- Audit trail — scan results, caller subject, decision context
- RFC 9728 `/.well-known/oauth-protected-resource` — service-specific metadata

### Local dev implications
- Replace kindnet with Cilium in the kind cluster config (proper NetworkPolicy enforcement)
- Install Istio into the kind cluster (istioctl or Helm)
- Local dev topology mirrors production from Phase 2 onward

### Compatibility with Phase 1 code
Phase 1 auth middleware (`JWTAuthMiddleware`) can be removed once Istio
handles validation — no structural changes to the route handlers or tool
logic are required. The audit trail and RFC 9728 endpoint are unaffected.

### Critical flag trigger
Any Phase 1 or Phase 2 work that would prevent removing `JWTAuthMiddleware`
cleanly (e.g. business logic embedded in the middleware) requires immediate
escalation.

### Phase 2 validation checklist
These cases were originally implemented as unit tests in `test_rate_limiting.py`
against the SlowAPI in-app implementation. That file has been deleted as rate
limiting moves to Istio. When Phase 2 rate limiting is implemented via the Envoy
rate limit filter, each case below must be covered by integration tests against
the live mesh.

**Rate limiting (cases 21–30)**
- [ ] 21. Request under per-minute limit → not 429
- [ ] 22. Request exceeding limit → 429, `Retry-After` header present, body contains `error_code: RATE_LIMITED`
- [ ] 23. `GET /health` → never 429 regardless of request volume (exempt path)
- [ ] 24. `GET /.well-known/oauth-protected-resource` → never 429 (exempt path)
- [ ] 25. Two callers with different identities → independent counters (exhausting one does not affect the other)
- [ ] 26. Rate limiting disabled via config → no 429 regardless of volume
- [ ] 27. 429 body is safe — contains only `error_code` and `message`, no payload/traceback/content
- [ ] 28. Rate limit fires on `/mcp` (the mounted MCP sub-app path, not just native FastAPI routes)
- [ ] 29. Rate limit key is caller identity, not client IP — proven by case 25 (all requests share same source IP in test)
- [ ] 30. WARNING log emitted on breach — `caller_subject` present, no payload content in log record

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
