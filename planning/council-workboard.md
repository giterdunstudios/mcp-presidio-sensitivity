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
- Pre-Phase 2 gate: confirm k3d migration Wave 3 (D1–D6) validation pass before Phase 2 scope is opened
- Phase 2 scope definition — blocked until pre-Phase 2 gate clears

### Needs coordination
- Phase 1 exit criteria review — requires: Security/Privacy Lead, Engineering Practices Lead; timing: after Wave 3 validation passes

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
- None — awaiting Wave 3 (D1–D6) validation to confirm k3d migration complete

### Queued
- Wave 3 validation (D1–D6): `./scripts/setup-local.sh` → `status.sh` → `test.sh` → `auth-test.sh` → `validate-networkpolicy.sh` → `demo.sh a`
- Phase 2 design: Istio install into k3d cluster (DEC-003, DEC-004 Phase E)

### Needs coordination
- Cilium CNI (Phase E, optional): requires Platform / Cluster Infrastructure Lead if still active; timing: Phase 2 start

---

## Engineering Practices Lead

### Active
- Best practices backlog seeded (`planning/best-practices-backlog.md`) — complete
- Monitoring team workflow health across all roles post-council ratification

### Queued
- Test coverage audit: map current 42 test cases to solution behaviours; identify gaps
- Dev/prod parity baseline: document current delta between k3d local and Phase 2 target topology
- Onboarding review: validate that a new contributor can reach a working stack using only `CLAUDE.md` and `scripts/README.md`
- Disaster recovery runbook for local dev stack

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

### Active
- k3d migration Wave 1 + Wave 2: complete
- Awaiting Wave 3 validation (D1–D6) to confirm deactivation

### Queued
- Deactivation: pending Wave 3 pass

### Needs coordination
- None pending deactivation
