# Council Workboard

Cross-role visibility into active work, queued items, and coordination requests.
Read this file at the start of every session before doing any work.
Maintained per §5b of `role-instructions/ways-of-working.md`.

**Last updated:** 2026-03-27 (tech debt audit backlog logged — see planning/tech-debt-backlog.md)

---

## Product / Scope Lead

### Active
- Phase 1 exit sign-off — pending Security/Privacy Lead and Engineering Practices Lead sign-off gates

### Queued
- Phase 2 scope definition — pre-Phase 2 gate cleared; unblocked pending Phase 1 exit sign-off
- Vertical templates implementation phase scheduling (tech-debt-backlog.md #18) — research complete 2026-03-26; planning task only
- SLO definition (tech-debt-backlog.md #19) — p99 latency + error rate targets; planning task only

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
- SBOM refresh post-Phase 2 (BP-018 / tech-debt-backlog.md #4) — auth/ deleted, Istio CRDs added; current SBOM stale
- Hardcoded credential pre-prod gate (BP-020 / tech-debt-backlog.md #6) — CLIENT_SECRET / ADMIN_PASSWORD enforcement gate
- Image vulnerability scanning (BP-024 / tech-debt-backlog.md #20) — Trivy/Grype in rebuild.sh; no CVE check for PII images
- Image signing (BP-025 / tech-debt-backlog.md #28) — Cosign; images unsigned

### Needs coordination
- SBOM automation acceptance — requires: Technical Implementation Lead (cdxgen integration); timing: before Phase 1 exit sign-off

---

## Technical Implementation Lead

### Active
- None

### Queued
- Phase 2 design: Istio install into k3d cluster (DEC-003, DEC-004 Phase E)
- Worker pod restart root cause investigation (tech-debt-backlog.md #3) — 9 restarts observed; OOMKill? Probe misconfiguration?
- requirements.lock.txt sync check (BP-019 / tech-debt-backlog.md #5) — verify lock matches requirements.txt in test.sh or rebuild.sh
- BP-007: RFC 9728 discovery chain integration test (tech-debt-backlog.md #7)
- BP-011: Verify teardown + re-run clean (tech-debt-backlog.md #9)
- Helm test hooks (BP-022 / tech-debt-backlog.md #14)
- Prometheus → Worker direct scraping (tech-debt-backlog.md #26) — NetworkPolicy exemption rule

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
- Test coverage audit: map current 42 test cases to solution behaviours; identify gaps (BP-006 / tech-debt-backlog.md #10)
- Dev/prod parity baseline: document current delta between k3d local and Phase 2 target topology (BP-013 / tech-debt-backlog.md #11)
- Onboarding review: validate that a new contributor can reach a working stack using only `CLAUDE.md` and `scripts/README.md` (tech-debt-backlog.md #13)
- Disaster recovery runbook for local dev stack (BP-010 / tech-debt-backlog.md #8)
- BP-005: pin exact k3d version in CLAUDE.md — confirmed 5.7.4 (tech-debt-backlog.md #1 note)
- BP-012: k3d version floor check in setup-local.sh (tech-debt-backlog.md #10)
- Registry GC script (BP-016 / tech-debt-backlog.md #1)
- Registry process documentation in scripts/README.md (BP-017 / tech-debt-backlog.md #2)
- Registry authentication gap — document as known gap (BP-023 / tech-debt-backlog.md #21)
- Helm chart version bump policy (BP-021 / tech-debt-backlog.md #13)

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
