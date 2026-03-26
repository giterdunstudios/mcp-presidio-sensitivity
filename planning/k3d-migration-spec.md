# Engineering Spec: k3d Migration

**Status:** `ready-for-implementation`
**Gate:** Pre-Phase 2 (DEC-004) — blocks Phase 2 start
**Depends on:** nothing (standalone infrastructure work)
**Last updated:** 2026-03-26

---

## Burst Role: Platform / Cluster Infrastructure Lead

**Activated for this migration only.**

**Owns:**
- k3d cluster design — `infrastructure/k3d-config.yaml`, registry configuration, port mappings
- Local image delivery pipeline — registry creation, `docker push` workflow
- `setup-local.sh` rewrite — cluster lifecycle, registry bootstrap, image loading
- Handoff contract publication before Wave 2 begins

**Deactivated after:** Phase D validation passes (all 6 scripts green).

---

## Council Roles in Scope

| Role | Owns in this migration |
|------|----------------------|
| Platform / Cluster Infrastructure Lead | Wave 1 design; handoff contract; k3d-config.yaml; setup-local.sh |
| Technical Implementation Lead | `rebuild.sh` rewrite (Lane B1); Helm values changes (Lane B2+B3); integration review |
| Security / Privacy Lead | Validates NetworkPolicy enforcement preserved under k3d/k3s CNI; registry access controls |
| Product / Scope Lead | Phase D gate definition; critical constraint enforcement (registry prefix never in production values.yaml) |

---

## Implementation Waves

### Wave 1 — Design (Platform Lead; serial; unblocks Wave 2)

These two items must be completed together — they establish all conventions that Wave 2 depends on.

**A2 — Create `infrastructure/k3d-config.yaml`**
- Port mappings matching current `infrastructure/kind-config.yaml`:
  - host 8000 → MCP server (NodePort 30800)
  - host 8080 → Keycloak (NodePort 30880)
  - host 8090 → Worker (NodePort 30890)
  - host 9090 → Prometheus (NodePort 30900)
  - host 3000 → Grafana (NodePort 30300)
  - host 16686 → Jaeger (NodePort 30686)
- Single-node cluster (1 server, 0 agents) — same footprint as current kind cluster

**A3 — Rewrite `scripts/setup-local.sh`**
- Step 0: create k3d registry (`k3d-mcp-registry` on port 5000) if not exists
- Replace `kind create cluster` with `k3d cluster create` using `k3d-config.yaml`
- Replace `kind load docker-image` with `docker tag` + `docker push` to local registry
- Replace `kind get clusters | grep` check with `k3d cluster list | grep`
- Replace `kind delete cluster` (teardown path) with `k3d cluster delete` + `k3d registry delete`

### Wave 1 — Parallel (independent; no dependencies)

**A1 — Update `CLAUDE.md` prerequisites table**
- Remove kind entry; add k3d entry with pinned version

---

## Handoff Contract (Wave 1 → Wave 2)

Platform Lead must publish these decisions before any Wave 2 lane begins. All Wave 2 agents depend on this information.

| Decision | Value |
|----------|-------|
| Registry name | `k3d-mcp-registry` |
| Registry port | `5000` |
| Cluster name | `mcp-presidio` |
| MCP server image | `k3d-mcp-registry:5000/mcp-presidio-sensitivity:0.1.0` |
| Worker image | `k3d-mcp-registry:5000/presidio-worker:0.1.0` |
| Pull policy | `Always` |
| k3d cluster create command | `k3d cluster create mcp-presidio --config infrastructure/k3d-config.yaml` |
| k3d cluster list command | `k3d cluster list` |
| k3d cluster delete command | `k3d cluster delete mcp-presidio` |

---

## Wave 2 — Parallel Implementation

All five lanes are independent. Each requires the handoff contract above. Assign one agent per lane.

### Lane B1 — `scripts/rebuild.sh`

**Files touched:** `scripts/rebuild.sh`

Replace `kind load docker-image <image> --name mcp-presidio` with:
```bash
docker tag <image>:<tag> k3d-mcp-registry:5000/<image>:<tag>
docker push k3d-mcp-registry:5000/<image>:<tag>
```
No other changes to rebuild logic.

### Lane B2+B3 — Helm local values files

**Files touched:** `helm/mcp-server/values.local.yaml`, `helm/presidio-worker/values.local.yaml`

For each file:
- `image.pullPolicy`: `Never` → `Always`
- `image.repository`: bare name → `k3d-mcp-registry:5000/<name>`

Production `values.yaml` files: **do not touch**.

### Lane C1 — `scripts/status.sh`

**Files touched:** `scripts/status.sh`

Replace `kind get clusters | grep mcp-presidio` check with `k3d cluster list | grep mcp-presidio`.
No other changes.

### Lane C2+C3 — README + remove kind config

**Files touched:** `scripts/README.md`, `infrastructure/kind-config.yaml` (delete)

- `scripts/README.md`: remove all references to `kind load docker-image`; document `docker push` to `k3d-mcp-registry:5000` as the image load step
- `infrastructure/kind-config.yaml`: delete

---

## Wave 3 — Full Regression Validation (council gate)

Serial. All six must pass before Phase 2 begins. No partial green.

| Step | Command | Pass condition |
|------|---------|---------------|
| D1 | `./scripts/setup-local.sh` | Cluster up; all pods Running |
| D2 | `./scripts/status.sh` | All checks green |
| D3 | `./scripts/test.sh` | 42/42 |
| D4 | `./scripts/auth-test.sh` | All 5 cases pass |
| D5 | `./scripts/validate-networkpolicy.sh` | All cases pass |
| D6 | `./scripts/demo.sh a` | Full end-to-end including Jaeger trace |

---

## What Does NOT Change

- All Kubernetes manifests (`keycloak-local.yaml`, `jaeger.yaml`, NetworkPolicy templates)
- All Helm chart templates and production `values.yaml`
- All Dockerfiles and application source
- All tests (42/42 baseline unchanged)
- `kubectl`, `helm`, `docker` versions
- Overall dev workflow (setup → rebuild → test → demo)

---

## Critical Constraint

`k3d-mcp-registry:5000` must only appear in `values.local.yaml` files — never in production `values.yaml`. Any change that hardcodes the local registry prefix into a production values file permanently couples the production chart to a local dev registry. Violation requires immediate escalation to council.

---

## Phase E — Cilium CNI (optional; Phase 2 only — not a pre-Phase 2 gate)

| Step | Action |
|------|--------|
| E1 | Add `--k3s-arg '--flannel-backend=none@server:0'` to `k3d-config.yaml` to disable Flannel |
| E2 | Install Cilium via Helm at cluster creation time in `setup-local.sh` |
| E3 | Re-run `./scripts/validate-networkpolicy.sh` to verify enforcement under Cilium |

Phase E is Phase 2 work. Do not include it in the pre-Phase 2 migration.
