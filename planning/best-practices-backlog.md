# Best Practices Backlog

Owned by: Engineering Practices Lead
Maintained per §4.5 and §5b of `role-instructions/ways-of-working.md`.

Items in this backlog are cross-cutting improvements to governance, testing, reproducibility,
and dev/prod parity. Each role is responsible for implementing items in their own area.
Coordination items are tracked in `planning/council-workboard.md`.

When an item is proposed and no role schedules it for valid project reasons,
it must be raised at the next council meeting per §5c.

**Last updated:** 2026-03-27 (BP-026 spike added — devtools-run standardization)

---

## Status legend
- `proposed` — identified, not yet scheduled
- `scheduled` — assigned to a role and phase
- `in_progress` — actively being worked
- `complete` — done, acceptance criteria met
- `deferred` — explicitly deferred with documented rationale and re-evaluation trigger
- `escalated` — raised to council meeting; awaiting scheduling decision

---

## Governance

| ID | Item | Status | Owner role | Phase | Notes |
|----|------|--------|-----------|-------|-------|
| BP-027 | Temporal coupling analysis — Phase 1: script + data file | `complete` | Engineering Practices Lead | Pre-wave (urgent) | Council-approved 2026-03-27 (DEC-007). Implement `scripts/coupling-analysis.sh` + generate initial `planning/coupling-data.json`. Run before wave work restarts. See `planning/temporal-coupling-spec.md`. |
| BP-028 | Temporal coupling analysis — Phase 2: agent integration + branch instruction `## Files touched` tables | `proposed` | Engineering Practices Lead | After BP-027 proven | Structured file footprint tables in branch instructions + agent invocation guide. See `planning/temporal-coupling-spec.md` Phase 2. |
| BP-029 | Re-add pre-Istio JWT auth enforcement gate | `proposed` | Security/Privacy Lead + Technical Implementation Lead | **URGENT — Pre-Phase 2** | `JWTAuthMiddleware` was removed in `aa7c97b` (Phase 2 migration) before Istio was deployed. The `/mcp` endpoint currently accepts unauthenticated requests. Options: (1) re-add a temporary `JWTAuthMiddleware` until Istio is live, or (2) document as accepted gap with council sign-off. Discovered during BP-011 teardown verification 2026-03-27. |
| BP-001 | SBOM automated regeneration via cdxgen in `rebuild.sh` | `proposed` | Security/Privacy Lead (approves); Technical Implementation Lead (implements) | Pre-Phase 2 | See automation plan below. **Gate:** Security/Privacy Lead commits this row's status to `approved-for-implementation` — that commit is the signal for Tech Lead to start. Concerns → council review before status changes. |
| BP-002 | SBOM acceptance criteria for Phase 1 exit sign-off | `complete` | Security/Privacy Lead | Phase 1 exit | `bom.json` is valid JSON, fresh UUID serialNumber, all components and vulnerability present. Accepted for Phase 1. Automation is pre-Phase 2 work. |
| BP-003 | `bom.json` serialNumber should be generated (not static) | `complete` | Security/Privacy Lead | Phase 1 exit | Resolved 2026-03-26: fresh UUID generated. Full automation (BP-001) will regenerate on every build. |
| BP-004 | Verify all roles have read `ways-of-working.md` v1.1 | `complete` | Engineering Practices Lead | 2026-03-26 | Ratification session served as read-through. |
| BP-005 | Pin exact k3d version in CLAUDE.md prerequisites table | `proposed` | Engineering Practices Lead | Wave 3 | Currently listed as `5.x`. Pin to installed version (5.7.4) after Wave 3 setup-local.sh run. See tech-debt-backlog.md #1 note: version confirmed as 5.7.4. |
| BP-016 | Registry GC script (`scripts/registry-gc.sh`) | `proposed` | Engineering Practices Lead | Pre-Phase 3 | Unreferenced image layers accumulate on every rebuild — silent disk growth. See tech-debt-backlog.md #1. |
| BP-017 | Registry process documentation in `scripts/README.md` | `proposed` | Engineering Practices Lead | Pre-Phase 3 | No documented policy for when/how to run GC. See tech-debt-backlog.md #2. |
| BP-018 | SBOM refresh post-Phase 2 | `proposed` | Security/Privacy Lead | Post-Phase 2 | auth/ deleted, Istio/Envoy CRDs added — current SBOM doesn't reflect running system. See tech-debt-backlog.md #4. |
| BP-019 | requirements.lock.txt sync check in test.sh or rebuild.sh | `proposed` | Technical Implementation Lead | Pre-Phase 3 | Nothing verifies lock file matches requirements.txt — could ship wrong deps silently. See tech-debt-backlog.md #5. |
| BP-020 | Hardcoded credential pre-prod gate | `proposed` | Security/Privacy Lead | Pre-Phase 3 | CLIENT_SECRET / ADMIN_PASSWORD have change-in-prod values with no enforcement gate. See tech-debt-backlog.md #6. |
| BP-021 | Helm chart version bump policy | `proposed` | Engineering Practices Lead | Pre-Phase 3 | Both charts frozen at 0.1.0 — can't correlate running pod to chart version in audit trail. See tech-debt-backlog.md #13. |
| BP-022 | Helm test hooks | `proposed` | Technical Implementation Lead | Pre-Phase 3 | No post-deploy smoke test; Helm native support unused. See tech-debt-backlog.md #14. |
| BP-030 | `setup-local.sh` smoke test race condition — worker port not yet ready | `proposed` | Engineering Practices Lead | Pre-Phase 2 | Smoke test checks `localhost:8090/health` immediately after Helm rollout completes. Worker passes Kubernetes readiness (internal healthcheck on port 8080) but external port is not yet accessible. Smoke test exits 1 spuriously. Fix: add retry loop (e.g. 3 attempts × 10s) before failing. Discovered 2026-03-27 during BP-011. |
| BP-023 | Registry authentication gap — document as known gap | `proposed` | Engineering Practices Lead | Pre-Phase 3 | Unauthenticated pushes accepted — undocumented, not a deliberate decision. See tech-debt-backlog.md #21. |
| BP-026 | Standardize devtools-run.sh as launcher for infra-heavy scripts | `scheduled` | Engineering Practices Lead | Pre-Phase 2 — HIGH PRIORITY | **Priority: HIGH.** Spike complete 2026-03-27. Recommendation: Option C (partial) — wrap setup-local.sh, rebuild.sh, status.sh, validate-networkpolicy.sh, branch-test.sh; leave test.sh, classify.sh, auth-test.sh, demo.sh, keycloak-admin.sh direct. **Implementation must use `/.dockerenv`-aware guard pattern** — do not remove tool checks outright; both direct and wrapped invocations must work simultaneously to enable parallel branch development and safe cut-over. Estimated effort: ~1 day. Demoable milestones defined. See `planning/spikes/devtools-standardization/findings.md`. |
| BP-024 | Image vulnerability scanning (Trivy/Grype in rebuild.sh) | `proposed` | Security/Privacy Lead | Pre-Phase 3 | No CVE check for images handling PII data. See tech-debt-backlog.md #20. |
| BP-025 | Image signing (Cosign) | `proposed` | Security/Privacy Lead | Pre-Phase 3 | Images are unsigned — no integrity guarantee. See tech-debt-backlog.md #28. |

---

## Testing

| ID | Item | Status | Owner role | Phase | Notes |
|----|------|--------|-----------|-------|-------|
| BP-006 | Test coverage audit: map test cases to solution behaviours | `complete` | Engineering Practices Lead + Technical Implementation Lead | Phase 1 exit | 58 tests passing. test_main.py added: /health, RFC 9728 endpoint, classify tool handler (success + error), RequestContextMiddleware. Zero-coverage modules resolved. |
| BP-007 | Integration test for RFC 9728 discovery chain | `complete` | Technical Implementation Lead | Phase 1 exit | test_main.py cases 2–6: all required RFC 9728 fields, ISSUER_URL in authorization_servers, scopes_supported, SERVER_RESOURCE_URL. Live chain covered by status.sh + auth-test.sh. |
| BP-008 | Synthetic test corpus coverage gate: require corpus case for each new entity type added | `proposed` | Detection / Data Researcher (when active) | Phase 1+ | Coordinate with Engineering Practices Lead on acceptance threshold. |
| BP-009 | Wave 3 regression validation (D1–D6) — k3d migration | `complete` | Technical Implementation Lead | Pre-Phase 2 gate | All 6 scripts green (2026-03-26). Pre-Phase 2 gate cleared. |

---

## Reproducibility and Disaster Recovery

| ID | Item | Status | Owner role | Phase | Notes |
|----|------|--------|-----------|-------|-------|
| BP-010 | Disaster recovery runbook for local dev stack | `proposed` | Engineering Practices Lead | Pre-Phase 2 | Document: what breaks, what the recovery path is, how long `setup-local.sh` takes from zero. Inform DR expectations. |
| BP-011 | Verify `setup-local.sh --teardown` + re-run leaves no orphaned resources | `proposed` | Technical Implementation Lead | Wave 3 | Confirm k3d registry + cluster teardown is clean. Part of Wave 3 pass. |
| BP-012 | `setup-local.sh` should verify k3d version meets minimum and warn if newer | `proposed` | Engineering Practices Lead | Pre-Phase 2 | Currently checks presence only. Version floor prevents silent behavioural changes from k3d upgrades. |

---

## Dev/Prod Parity

| ID | Item | Status | Owner role | Phase | Notes |
|----|------|--------|-----------|-------|-------|
| BP-013 | Document current delta: k3d local vs Phase 2 target production topology | `proposed` | Engineering Practices Lead + Technical Implementation Lead | Before Phase 2 scope opens | Known delta: no Istio, no Cilium enforcement, no mTLS, single-node. Needs formal baseline. Needs coordination (see workboard). |
| BP-014 | Define acceptable parity threshold: what cannot be simplified away | `proposed` | Engineering Practices Lead + Product/Scope Lead | Before Phase 2 scope opens | Rule of thumb needed: "if X is not present locally, you cannot test Y." Needs coordination. |
| BP-015 | Validate NetworkPolicy enforcement is real under k3d/k3s CNI (kindnet → Flannel change) | `complete` | Security/Privacy Lead + Engineering Practices Lead | Wave 3 | Flannel in k3s enforces NetworkPolicy ingress — confirmed under k3s v1.30.4+k3s1. Cases 13+14 enabled in `validate-networkpolicy.sh`. `validate-networkpolicy.sh` results are live enforcement, not just object presence checks. |

---

## SBOM Automation Plan (BP-001)

**Status:** Proposed — pre-Phase 2. Security/Privacy Lead must approve toolchain before implementation begins.

### Why automate

The current `bom.json` is hand-maintained. Every dependency update in `requirements.lock.txt` requires a manual edit to `bom.json`. This will be missed. The `serialNumber` is now a one-time generated UUID — it should be fresh on every build to distinguish BOM versions. The vulnerability list will drift as new CVEs are found and old ones are fixed.

### Chosen tool: cdxgen

`cdxgen` (CycloneDX generator, Apache-2.0) reads `requirements.lock.txt` directly and emits a valid CycloneDX 1.6 JSON BOM. It runs as a Docker container — no host install required, consistent with the devtools pattern.

```bash
# How it runs (one-liner, no host install)
docker run --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  ghcr.io/cyclonedx/cdxgen:latest \
  -r /workspace/src/mcp_server \
  -t python \
  -o /workspace/bom-mcp-server.json

docker run --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  ghcr.io/cyclonedx/cdxgen:latest \
  -r /workspace/src/worker \
  -t python \
  -o /workspace/bom-worker.json
```

### Integration point: `rebuild.sh`

After image push, regenerate and merge:
1. Run cdxgen against `src/mcp_server/` → `bom-mcp-server.json`
2. Run cdxgen against `src/worker/` → `bom-worker.json`
3. Merge both into `bom.json` with a Python merge script: union components, deduplicate by purl, preserve infrastructure components and vulnerability entries that cdxgen cannot know about (Keycloak, Jaeger, Prometheus, Grafana, the CVE entry)
4. Inject fresh `serialNumber` UUID and current timestamp
5. Validate output parses as JSON before overwriting `bom.json`

### What cdxgen cannot generate automatically (must be preserved in merge)

- Infrastructure container components (Keycloak, Jaeger, Prometheus, Grafana) — cdxgen only sees Python deps
- Vulnerability entries with `analysis.state` and `justification` — cdxgen detects CVEs but cannot supply risk acceptance rationale
- `metadata.component` description and license
- `dependencies` graph (service-to-library mapping) — cdxgen generates flat lists, not service-scoped dep trees

### Merge script location

`scripts/generate-sbom.sh` — callable standalone or from `rebuild.sh`. Keeps `rebuild.sh` clean.

### Acceptance criteria for BP-001 completion

- [ ] `generate-sbom.sh` runs without host dependencies (Docker only)
- [ ] Output is valid CycloneDX 1.6 JSON (`python3 -m json.tool bom.json` passes)
- [ ] `serialNumber` is a fresh UUID on every run
- [ ] `timestamp` matches current UTC time
- [ ] All Python deps from both `requirements.lock.txt` files are present
- [ ] Infrastructure components preserved
- [ ] Vulnerability entry with risk acceptance rationale preserved
- [ ] `rebuild.sh` calls `generate-sbom.sh` after image push
- [ ] Security/Privacy Lead sign-off on output format

---

## Escalated items

None currently. Any item unscheduled after two council cycles moves here.
