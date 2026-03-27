---
title: File Coupling Map
purpose: Parallelization planning — before assigning two branches to the same wave, look up each file they touch here and verify their coupled sets do not overlap.
updated: 2026-03-27
---

# File Coupling Map

For each solution artifact: what else typically needs to change alongside it.
**Planning rule:** if two branches share any file in each other's coupling sets, they cannot safely run in parallel.

---

## Collision hotspots (files touched by the most branches)

| File | Branches that touch it | Safe to parallelize? |
|------|----------------------|----------------------|
| `scripts/README.md` | #1-2-31, #6, #7, #20, #22, #28 | No — serialize |
| `scripts/rebuild.sh` | #5, #6, #20, #22, #28 | No — serialize |
| `scripts/setup-local.sh` | #10, #21 | No — serialize |
| `planning/dev-prod-parity.md` | #11 (creates), #21 (modifies) | No — #11 must land first |
| `bom.json` | #4 (manual edit), #22 (overwrites) | No — #4 must land first |
| `helm/mcp-server/Chart.yaml` | #13b | Single branch — safe |
| `helm/presidio-worker/Chart.yaml` | #13b | Single branch — safe |
| `helm/presidio-worker/templates/networkpolicy.yaml` | #14 | Single branch — safe |

---

## Scripts

### `scripts/rebuild.sh`
Rebuilds images, pushes to k3d registry, runs `helm upgrade`.
**When changed, also review:**
- `scripts/README.md` — usage docs reflect new steps or flags
- `CLAUDE.md` — if workflow changes (new required step, new flag)
- `helm/mcp-server/Chart.yaml` + `helm/presidio-worker/Chart.yaml` — helm upgrade uses chart version; bump if chart changes accompany the rebuild change
- `src/mcp_server/Dockerfile` / `src/worker/Dockerfile` — if build args or base image change, rebuild.sh context paths must match

### `scripts/setup-local.sh`
Bootstraps k3d cluster, registry, Keycloak, and both services from scratch.
**When changed, also review:**
- `infrastructure/k3d-config.yaml` — cluster spec it creates
- `infrastructure/keycloak-local.yaml` — manifest it applies
- `keycloak/realm-import/mcp-local-realm.json` — ConfigMap it creates from this file
- `helm/mcp-server/values.local.yaml` + `helm/presidio-worker/values.local.yaml` — values passed at install time
- `scripts/README.md` — if setup procedure changes
- `CLAUDE.md` — prerequisites table and first-time setup section

### `scripts/status.sh`
Health check for all services.
**When changed, also review:**
- `scripts/README.md` — documents what status.sh checks
- `infrastructure/prometheus.yaml` / `infrastructure/jaeger.yaml` — if new UI URLs are added
- `scripts/branch-test.sh` — status.sh is step 3; if its exit codes change, branch-test.sh must adapt

### `scripts/README.md`
Documents every script: when to use it, flags, examples.
**When changed, also review:**
- `CLAUDE.md` — `@scripts/README.md` is included inline; changes appear in both

### `scripts/auth-test.sh`
JWT enforcement test matrix (5 cases).
**When changed, also review:**
- `scripts/branch-test.sh` — calls auth-test.sh as step 4
- `infrastructure/istio/request-authentication.yaml` — JWT authn policy under test
- `infrastructure/istio/authorization-policy.yaml` — scope enforcement under test
- `keycloak/realm-import/mcp-local-realm.json` — token TTL case 5 (sets realm TTL to 2s)

### `scripts/branch-test.sh`
Full branch validation (unit tests → rebuild → status → auth → networkpolicy).
**When changed, also review:**
- `scripts/test.sh`, `scripts/rebuild.sh`, `scripts/status.sh`, `scripts/auth-test.sh`, `scripts/validate-networkpolicy.sh` — each called as a step; exit code contracts must hold

### `scripts/validate-networkpolicy.sh`
Validates live NetworkPolicy enforcement via busybox test pod.
**When changed, also review:**
- `helm/mcp-server/templates/networkpolicy.yaml`
- `helm/presidio-worker/templates/networkpolicy.yaml`
- `infrastructure/istio/peer-authentication.yaml` — mTLS interacts with NetworkPolicy enforcement

### `scripts/classify.sh`
Demo client — RFC 9728 discovery chain → token → classify.
**When changed, also review:**
- `scripts/demo.sh` — calls classify.sh; output format changes break demo parsing
- `src/mcp_server/main.py` — `/mcp` endpoint and `/.well-known/oauth-protected-resource` under test

### `scripts/demo.sh`
End-to-end smoke test.
**When changed, also review:**
- `scripts/classify.sh` — called for each test case
- `deliverables/lane-c/corpus/` — test payload files referenced

### `scripts/keycloak-admin.sh`
Keycloak realm admin operations.
**When changed, also review:**
- `keycloak/realm-import/mcp-local-realm.json` — realm config it reads and sets
- `scripts/auth-test.sh` — case 5 restores TTL to 60s via keycloak-admin.sh

### `scripts/test.sh`
Runs mcp_server pytest suite in Docker.
**When changed, also review:**
- `src/mcp_server/tests/` — test discovery path
- `src/mcp_server/requirements-test.txt` — test dependencies installed inside container

### `scripts/devtools-run.sh`
Launches infrastructure/devtools.Dockerfile container with project mounted.
**When changed, also review:**
- `infrastructure/devtools.Dockerfile` — the container it runs

---

## Source — MCP Server

### `src/mcp_server/main.py`
FastAPI + FastMCP entry point; hosts `/mcp`, `/health`, `/.well-known/oauth-protected-resource`, `/metrics`.
**When changed, also review:**
- `src/mcp_server/config.py` — any new env var must be added here
- `helm/mcp-server/templates/configmap.yaml` — any new env var must be wired through the chart
- `helm/mcp-server/values.yaml` — default value for new env var
- `src/mcp_server/backend/worker_client.py` — if worker call changes
- `src/mcp_server/audit/trail.py` — if audit fields change
- `src/mcp_server/tests/test_main.py` — test coverage
- `infrastructure/istio/authorization-policy.yaml` — if new paths need scope enforcement
- `planning/auth-flows-diagram.md` — if discovery or auth flow changes

### `src/mcp_server/config.py`
Reads environment configuration.
**When changed, also review:**
- `helm/mcp-server/templates/configmap.yaml` — config values sourced here
- `helm/mcp-server/values.yaml` + `values.local.yaml` — default and override values
- `src/mcp_server/main.py` — consumer of config values

### `src/mcp_server/backend/worker_client.py`
HTTP client for Presidio worker; strips auth headers, enforces no-payload-in-logs.
**When changed, also review:**
- `src/mcp_server/config.py` — WORKER_URL, WORKER_TIMEOUT_SECONDS
- `src/mcp_server/backend/models.py` — request/response schemas
- `src/worker/main.py` — worker endpoint contract (must stay compatible)
- `src/mcp_server/tests/test_worker_client.py`
- `planning/architecture-diagram.md` — MCP→Worker edge

### `src/mcp_server/audit/trail.py`
Structured audit log writer (no payload content, caller_subject, scan_id, decision).
**When changed, also review:**
- `src/mcp_server/main.py` — calls write_audit_record
- `src/mcp_server/backend/models.py` — WorkerScanResponse fields used
- `src/mcp_server/tests/test_audit_trail.py`

### `src/mcp_server/Dockerfile`
MCP server container image.
**When changed, also review:**
- `src/mcp_server/requirements.txt` + `requirements.lock.txt` — installed inside
- `bom.json` — Dockerfile reference pinned in SBOM (internal:dockerfile property)
- `scripts/rebuild.sh` — build context and args
- `helm/mcp-server/values.yaml` — image repository and tag convention

### `src/mcp_server/requirements.txt`
Dependency constraints.
**When changed, also review:**
- `src/mcp_server/requirements.lock.txt` — must be regenerated (see CLAUDE.md lock file procedure)
- `bom.json` — SBOM reflects resolved package versions
- `src/mcp_server/Dockerfile` — installs from lock file

### `src/mcp_server/requirements.lock.txt`
Pip-compiled exact-version lock.
**When changed, also review:**
- `src/mcp_server/Dockerfile` — uses this to install deps
- `bom.json` — SBOM reflects these versions
- `scripts/rebuild.sh` — rebuild required after lock change

---

## Source — Worker

### `src/worker/main.py`
FastAPI entry point; `/scan`, `/health`, `/metrics`; content-type guard, payload size guard.
**When changed, also review:**
- `src/worker/config.py` — new env vars
- `helm/presidio-worker/templates/configmap.yaml` — env var wiring
- `helm/presidio-worker/values.yaml` — default values
- `src/mcp_server/backend/worker_client.py` — caller; API contract must stay compatible
- `src/worker/models.py` — request/response schemas
- `planning/architecture-diagram.md` — if worker behaviour changes

### `src/worker/classification.py`
Severity mapping and decision logic.
**When changed, also review:**
- `src/worker/minimizer.py` — calls compute_severity_band, derive_categories, severity_to_decision
- `planning/decision-log.md` — classification policy decisions recorded here

### `src/worker/minimizer.py`
Builds bounded ScanResponse from Presidio findings.
**When changed, also review:**
- `src/worker/classification.py` — provides severity/decision inputs
- `src/worker/models.py` — ScanResponse schema
- `src/mcp_server/backend/models.py` — mirrored response schema on the MCP side

### `src/worker/Dockerfile`
Worker container image (bakes en_core_web_lg at build time).
**When changed, also review:**
- `src/worker/requirements.txt` + `requirements.lock.txt`
- `bom.json` — Dockerfile reference in SBOM
- `scripts/rebuild.sh` — build context
- `helm/presidio-worker/values.yaml` — image convention

### `src/worker/requirements.txt`
Dependency constraints.
**When changed, also review:**
- `src/worker/requirements.lock.txt` — must be regenerated
- `bom.json` — package versions in SBOM
- `src/worker/Dockerfile`

### `src/worker/requirements.lock.txt`
Pip-compiled exact-version lock.
**When changed, also review:**
- `src/worker/Dockerfile`
- `bom.json`
- `scripts/rebuild.sh`

---

## Helm — MCP Server

### `helm/mcp-server/values.yaml`
Production defaults (replicas, resources, security context, image policy).
**When changed, also review:**
- `helm/mcp-server/values.local.yaml` — local overrides; verify no conflict
- `helm/mcp-server/templates/deployment.yaml` — template consumes these values
- `helm/mcp-server/templates/configmap.yaml` — config.* values sourced here
- `scripts/rebuild.sh` — helm upgrade passes `-f values.local.yaml`

### `helm/mcp-server/values.local.yaml`
Local dev overrides (NodePort, k3d registry, localhost URLs).
**When changed, also review:**
- `helm/mcp-server/values.yaml` — must not override production-only fields
- `scripts/setup-local.sh` — helm install uses this file
- `scripts/rebuild.sh` — helm upgrade uses this file

### `helm/mcp-server/templates/configmap.yaml`
Env var ConfigMap for the MCP server container.
**When changed, also review:**
- `helm/mcp-server/values.yaml` — source of config.* values
- `src/mcp_server/config.py` — must have a matching `os.getenv()` call
- `src/mcp_server/main.py` — consumer

### `helm/mcp-server/templates/networkpolicy.yaml`
NetworkPolicy for MCP server ingress/egress.
**When changed, also review:**
- `scripts/validate-networkpolicy.sh` — test cases must reflect new rules
- `helm/presidio-worker/templates/networkpolicy.yaml` — both sides of MCP→Worker must align
- `infrastructure/istio/peer-authentication.yaml` — mTLS interacts with NetworkPolicy
- `planning/architecture-diagram.md` — boundary table

### `helm/mcp-server/Chart.yaml`
Chart metadata and version.
**When changed, also review:**
- `scripts/branch-test.sh` — runs `helm lint` against this chart
- `helm/mcp-server/values.yaml` — appVersion should reflect deployed app version
- `helm/presidio-worker/Chart.yaml` — typically bumped together (coordinated via #13b)

---

## Helm — Presidio Worker

### `helm/presidio-worker/values.yaml`
Production defaults.
**When changed, also review:**
- `helm/presidio-worker/values.local.yaml`
- `helm/presidio-worker/templates/deployment.yaml`
- `helm/presidio-worker/templates/configmap.yaml`
- `scripts/rebuild.sh`

### `helm/presidio-worker/values.local.yaml`
Local dev overrides (NodePort 30890, 768Mi, k3d registry).
**When changed, also review:**
- `helm/presidio-worker/values.yaml`
- `scripts/setup-local.sh`
- `scripts/rebuild.sh`

### `helm/presidio-worker/templates/configmap.yaml`
Env var ConfigMap for the worker container.
**When changed, also review:**
- `helm/presidio-worker/values.yaml`
- `src/worker/config.py`
- `src/worker/main.py`

### `helm/presidio-worker/templates/networkpolicy.yaml`
NetworkPolicy for worker (allow ingress from MCP label only, deny egress).
**When changed, also review:**
- `scripts/validate-networkpolicy.sh`
- `helm/mcp-server/templates/networkpolicy.yaml`
- `infrastructure/istio/peer-authentication.yaml`
- `planning/architecture-diagram.md`

### `helm/presidio-worker/Chart.yaml`
Chart metadata and version.
**When changed, also review:**
- `helm/mcp-server/Chart.yaml` — bumped together
- `scripts/branch-test.sh` — helm lint

---

## Infrastructure

### `infrastructure/k3d-config.yaml`
k3d cluster spec (port mappings, server count, traefik disabled).
**When changed, also review:**
- `scripts/setup-local.sh` — references this file directly
- `CLAUDE.md` — prerequisites table and port mapping documentation
- `scripts/README.md` — if port mappings change, URLs in docs must update
- `infrastructure/prometheus.yaml` / `infrastructure/grafana.yaml` — if observability ports change

### `infrastructure/keycloak-local.yaml`
Keycloak Deployment + Service for local dev.
**When changed, also review:**
- `keycloak/realm-import/mcp-local-realm.json` — mounted as ConfigMap volume; import triggered on pod start
- `scripts/setup-local.sh` — applies this manifest
- `infrastructure/istio/request-authentication.yaml` — JWKS URI must match Keycloak service address

### `infrastructure/prometheus.yaml`
Prometheus StatefulSet with scrape config.
**When changed, also review:**
- `infrastructure/grafana.yaml` — Prometheus is a Grafana data source
- `scripts/status.sh` — checks Prometheus endpoint
- `helm/mcp-server/templates/service.yaml` + `helm/presidio-worker/templates/service.yaml` — scrape targets

### `infrastructure/grafana.yaml`
Grafana deployment with Prometheus + Jaeger data sources.
**When changed, also review:**
- `infrastructure/prometheus.yaml` — data source
- `infrastructure/jaeger.yaml` — data source
- `scripts/status.sh` — surfaces Grafana URL

### `infrastructure/istio/request-authentication.yaml`
JWT validation policy (issuer, JWKS URI, audiences, `outputClaimToHeaders`).
**When changed, also review:**
- `infrastructure/istio/authorization-policy.yaml` — depends on JWT claims extracted here
- `keycloak/realm-import/mcp-local-realm.json` — issuer and audience must match
- `scripts/auth-test.sh` — validates this policy
- `src/mcp_server/main.py` — auth middleware removed; Envoy now owns JWT validation

### `infrastructure/istio/authorization-policy.yaml`
Scope enforcement (tools:classify.submit, tools:health.read).
**When changed, also review:**
- `infrastructure/istio/request-authentication.yaml` — JWT claims it reads
- `scripts/auth-test.sh` — cases 3 and 4 test scope enforcement
- `keycloak/realm-import/mcp-local-realm.json` — scope names must match

### `infrastructure/istio/peer-authentication.yaml`
mTLS STRICT enforcement between services.
**When changed, also review:**
- `helm/mcp-server/templates/networkpolicy.yaml`
- `helm/presidio-worker/templates/networkpolicy.yaml`
- `scripts/validate-networkpolicy.sh`
- `planning/decision-log.md` — DEC-001 mTLS status

### `infrastructure/istio/rfc9728-www-authenticate.yaml`
Injects `WWW-Authenticate: Bearer resource_metadata=...` on 401/403.
**When changed, also review:**
- `src/mcp_server/main.py` — `/.well-known/oauth-protected-resource` endpoint it points to
- `scripts/auth-test.sh` — case 1 validates the header
- `scripts/status.sh` — RFC 9728 check
- `planning/auth-flows-diagram.md` — Flow 2 depends on this header

---

## Keycloak

### `keycloak/realm-import/mcp-local-realm.json`
Realm configuration (client, scopes, token TTL, audience).
**When changed, also review:**
- `infrastructure/keycloak-local.yaml` — mounts this as a ConfigMap volume
- `infrastructure/istio/request-authentication.yaml` — issuer and JWKS URI must match
- `infrastructure/istio/authorization-policy.yaml` — scope names must match
- `scripts/keycloak-admin.sh` — admin ops reference realm name `mcp-local`
- `scripts/auth-test.sh` — token acquisition uses client credentials from this realm
- `planning/decision-log.md` — DEC-002 token TTL

---

## Cross-cutting

### `CLAUDE.md`
Living operations doc; includes `@scripts/README.md` inline.
**When changed, also review:**
- `scripts/README.md` — included via `@` directive; changes to README.md appear here automatically
- `planning/decision-log.md` — referenced for DEC-001, DEC-002
- Prerequisites table — tool versions must match `infrastructure/devtools.Dockerfile`

### `bom.json`
CycloneDX SBOM.
**When changed, also review:**
- `src/mcp_server/requirements.lock.txt` + `src/worker/requirements.lock.txt` — package versions must match
- `src/mcp_server/Dockerfile` + `src/worker/Dockerfile` — component references
- `infrastructure/keycloak-local.yaml` — infra component entry
- `src/worker/.pip-audit-ignore` — accepted CVEs should be reflected in bom.json metadata
