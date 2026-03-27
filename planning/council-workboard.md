# Council Workboard

Cross-role visibility into active work, queued items, and coordination requests.
Read this file at the start of every session before doing any work.
Maintained per §5b of `role-instructions/ways-of-working.md`.

**Last updated:** 2026-03-27 — Phase 1 EXIT COMPLETE

---

## Phase 1 Status: COMPLETE ✅

**Signed off:** 2026-03-27
**Gate run:** `branch-test.sh` — 58/58 unit tests, rebuild, status, auth (5/5), NetworkPolicy (cases 11–20)
**Signed by:** Security/Privacy Lead, Engineering Practices Lead, Product/Scope Lead

---

## Product / Scope Lead

### Active
- Phase 2 scope definition — now unblocked

### Queued
- Vertical templates implementation phase scheduling — research complete 2026-03-26; needs phase slot
- SLO definition — p99 latency + error rate targets; needs phase slot

### Needs coordination
- Phase 2 scope definition — requires: all roles; timing: next session

---

## Security / Privacy Lead

### Active
- None

### Queued
- SBOM automation review (BP-001: cdxgen) — approve toolchain before implementation
- Phase 2 auth offload design review (DEC-003: Istio JWT validation)
- SBOM refresh post-Phase 2 — auth/ deleted, Istio CRDs added; current SBOM will be stale
- Hardcoded credential pre-prod gate (BP-020) — CLIENT_SECRET / ADMIN_PASSWORD enforcement
- Image vulnerability scanning (BP-024) — Trivy/Grype in rebuild.sh
- Image signing (BP-025) — Cosign; images unsigned

### Needs coordination
- SBOM automation (BP-001) — requires: Technical Implementation Lead (cdxgen); timing: pre-Phase 2

---

## Technical Implementation Lead

### Active
- None

### Queued
- Phase 2 design: Istio install into k3d cluster (DEC-003, DEC-004 Phase E)
- Worker pod restart root cause investigation — OOMKill? Probe misconfiguration?
- requirements.lock.txt sync check (BP-019) — verify lock matches requirements.txt
- BP-011: Verify teardown + re-run clean
- Helm test hooks (BP-022)
- Prometheus → Worker direct scraping — NetworkPolicy exemption rule

### Completed this session
- Wave 3 validation (D1–D6) ✅
- test_main.py — 16-case suite (BP-006, BP-007) ✅
- classify.sh worker check fix ✅
- status.sh k3d fallback + observability URLs ✅

### Needs coordination
- Cilium CNI (Phase E): timing: Phase 2 start, coordinate with Security/Privacy Lead
- SBOM automation (BP-001): Technical Implementation Lead implements cdxgen once Security/Privacy Lead approves

---

## Engineering Practices Lead

### Active
- None

### Queued
- Dev/prod parity baseline (BP-013) — document delta between k3d local and Phase 2 target
- Onboarding review — validate new contributor path via CLAUDE.md + scripts/README.md
- Disaster recovery runbook (BP-010)
- BP-012: k3d version floor check in setup-local.sh
- Registry GC script (BP-016)
- Registry process documentation in scripts/README.md (BP-017)
- Registry authentication gap — document as known gap (BP-023)
- Helm chart version bump policy (BP-021)

### Completed this session
- BP-027: coupling-analysis.sh + coupling-data.json ✅ — 72 commits, 8 strong / 24 moderate pairs
- BP-002/003: SBOM valid JSON, fresh UUID ✅
- BP-005: k3d version pinned in CLAUDE.md ✅
- BP-006: Test coverage audit — 58 tests, main.py covered ✅
- BP-007: RFC 9728 unit tests ✅
- BP-009: Wave 3 regression ✅
- BP-015: Flannel NetworkPolicy enforcement confirmed ✅
- BP-026: devtools-run standardization spike complete ✅ — Option C (partial wrap) recommended, parallel-compatible `/.dockerenv` guard pattern required, HIGH priority Pre-Phase 2; see `planning/spikes/devtools-standardization/findings.md`

### Needs coordination
- Dev/prod parity standard — requires: Technical Implementation Lead, Product/Scope Lead; timing: before Phase 2 scope opens

---

## Detection / Data Researcher

### Active
- Inactive (surge role — not currently triggered)

### Queued
- Test corpus coverage standard: coordinate with Engineering Practices Lead on synthetic test corpus quality gates when activated

---

## Platform / Cluster Infrastructure Lead

### Status: DEACTIVATED (2026-03-26)

Wave 3 validation (D1–D6) passed. k3d migration complete.

### Completed
- Wave 1: k3d-config.yaml, setup-local.sh, registry workflow
- Wave 2: rebuild.sh, values.local.yaml (pullPolicy + registry prefix)
- Wave 3: status.sh, scripts/README.md, kind-config.yaml removed; full D1–D6 regression passed

---

## Needs coordination
- None currently blocking Phase 2 start
