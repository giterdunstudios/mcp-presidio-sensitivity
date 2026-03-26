# Council Workboard

Cross-role visibility into active work, queued items, and coordination requests.
Read this file at the start of every session before doing any work.
Maintained per §5b of `role-instructions/ways-of-working.md`.

**Last updated:** 2026-03-26

---

## Product / Scope Lead

### Active
- Phase 1 exit sign-off — pending Security/Privacy Lead and Engineering Practices Lead sign-off gates

### Queued
- Phase 2 scope definition — pre-Phase 2 gate cleared; unblocked pending Phase 1 exit sign-off

### Needs coordination
- Phase 1 exit criteria review — requires: Security/Privacy Lead, Engineering Practices Lead; timing: now unblocked (Wave 3 passed)

---

## Security / Privacy Lead

### Active
- SBOM (`bom.json`) ownership — reviewing current manual version; defining acceptance criteria for phase exit sign-off

### Queued
- Phase 1 exit sign-off — requires: Engineering Practices Lead to confirm testing gate passed
- SBOM automation review (BP-001: cdxgen) — Security/Privacy Lead must approve toolchain before it replaces the manual SBOM
- Phase 2 auth offload design review (DEC-003: Istio JWT validation) — blocked until pre-Phase 2 gate clears

### Needs coordination
- SBOM automation acceptance — requires: Technical Implementation Lead (cdxgen integration); timing: before Phase 1 exit sign-off

---

## Technical Implementation Lead

### Active
- None

### Queued
- Phase 2 design: Istio install into k3d cluster (DEC-003, DEC-004 Phase E)

### Completed this session
- Wave 3 validation (D1–D6): all 6 scripts green ✅
  - Flannel NetworkPolicy enforcement confirmed — cases 13+14 now live
  - MCP server ingress rule added for external clients
  - `devtools.Dockerfile` + `devtools-run.sh` added
  - `serverResourceUrl` added to `values.local.yaml`

### Needs coordination
- Cilium CNI (Phase E, optional): Platform / Cluster Infrastructure Lead deactivated; timing: Phase 2 start, coordinate with Security/Privacy Lead

---

## Engineering Practices Lead

### Active
- Monitoring team workflow health across all roles post-council ratification

### Queued
- Test coverage audit: map current 42 test cases to solution behaviours; identify gaps
- Dev/prod parity baseline: document current delta between k3d local and Phase 2 target topology
- Onboarding review: validate that a new contributor can reach a working stack using only `CLAUDE.md` and `scripts/README.md`
- Disaster recovery runbook for local dev stack
- BP-005: pin exact k3d version in CLAUDE.md (now that Wave 3 is complete, installed version is known)

### Completed this session
- BP-009 (Wave 3 regression D1–D6): complete ✅
- BP-015 (Flannel NetworkPolicy enforcement): complete ✅ — Flannel in k3s enforces NetworkPolicy ingress; cases 13+14 now active in `validate-networkpolicy.sh`

### Needs coordination
- Test coverage gap review — requires: Technical Implementation Lead; timing: Phase 1 exit prep
- Dev/prod parity standard definition — requires: Technical Implementation Lead, Product/Scope Lead; timing: before Phase 2 scope is opened

---

## Detection / Data Researcher

### Active
- Inactive (surge role — not currently triggered)

### Queued
- Test corpus coverage standard: when activated, coordinate with Engineering Practices Lead on synthetic test corpus quality gates

---

## Platform / Cluster Infrastructure Lead

### Status: DEACTIVATED (2026-03-26)

Wave 3 validation (D1–D6) passed. k3d migration complete. Burst role deactivated per handoff contract in `planning/k3d-migration-spec.md`.

### Completed
- Wave 1: k3d-config.yaml, setup-local.sh, registry workflow
- Wave 2: rebuild.sh, values.local.yaml (pullPolicy + registry prefix)
- Wave 3: status.sh, scripts/README.md, kind-config.yaml removed; full D1–D6 regression passed

### Needs coordination
- None — deactivated
