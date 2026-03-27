---
branch: 11-parity-delta
wave: 1
items: "#11"
impl_owner: Engineering Practices Lead
validation_owner: Product / Scope Lead
status: ready
---

# Branch: 11-parity-delta

## Goal
Write a clear baseline document describing what is simplified or absent in the k3d local environment compared to the Phase 2 production target, so developers know which production behaviours cannot be reliably tested locally.

## Items covered
| # | Item |
|---|------|
| #11 | BP-013 Document dev/prod parity delta |

## Acceptance criteria
- [ ] New file `planning/dev-prod-parity.md` created
- [ ] Dated baseline header: "Delta as of 2026-03-27 — update when Phase 2 target changes"
- [ ] Covers all required gaps: Istio (present locally), Cilium CNI (absent — Flannel), IngressGateway (absent — port mapping), HA/multi-replica (absent — single node), Redis (absent — rate limit is per-pod local_ratelimit), external JWKS cache (absent)
- [ ] For each gap: explicitly states "if X is absent locally, you cannot reliably test Y"
- [ ] Scope is Phase 2 target only — no Phase 3 speculation
- [ ] Header repeats: "Delta as of 2026-03-27 — update when Phase 2 target changes"

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `planning/dev-prod-parity.md` | Create | New file |

## Files to leave alone
All `src/`, `helm/`, `scripts/` files. Documentation-only branch.

## Decisions that apply to this branch
- DEC-004 Wave 3 finding: Flannel (k3s default CNI) enforces NetworkPolicy ingress rules. Basic NetworkPolicy enforcement is real locally — but this is not eBPF L7 enforcement. Cilium is the Phase 2 production target for identity-aware enforcement.
- DEC-003: Phase 2 target includes Istio (present locally), Redis-backed global rate limiter (not present locally — replaced by per-pod EnvoyFilter local_ratelimit per DEC-005), and Cilium for L7 policy.
- DEC-005: `local_ratelimit` (EnvoyFilter) uses per-pod counters. In production, a global rate limit service (Redis-backed) with per-identity keys is required. This gap means DEC-003 cases 25 and 29 cannot be tested locally.
- The Phase 2 production target topology is described in `planning/architecture-diagram.md`. Use that as the authoritative reference for what "production" looks like.

## How to validate
Read `planning/dev-prod-parity.md` end-to-end:
- Confirm all required gaps are present
- Confirm each gap has a "cannot reliably test" consequence
- Confirm no Phase 3 items are mentioned (no speculation beyond the Phase 2 architecture diagram)
- Confirm the dated header is present

No `branch-test.sh` run required — documentation-only branch.

## What the validation owner checks
- File exists at `planning/dev-prod-parity.md`
- All six required gaps are documented: Istio, Cilium, IngressGateway, HA, Redis, external JWKS cache
- Each gap explicitly states what cannot be tested locally as a result
- No Phase 3 items mentioned (no Redis-backed rate limit replacement, no cert-manager, no dynamic client registration — those are Phase 3)
- Scope is precisely Phase 2: what we have targeted vs what is simplified in the k3d setup
- Validation owner confirms scope is constrained; no scope creep into Phase 3 speculation

## Notes / constraints
- Reference `planning/architecture-diagram.md` for the Phase 2 target topology. The gaps document what that diagram shows as present that is absent or simplified locally.
- "Istio present locally" is a gap entry even though Istio is installed — the gap is in the specific Istio configuration: no IngressGateway (using NodePort instead), PERMISSIVE mode in some places for local convenience, etc.
- The purpose of this document is to help developers set accurate expectations, not to create a to-do list. The Phase 3 work to close these gaps is tracked separately.
- Keep the document concise. A table of gaps with a one-sentence consequence per gap is sufficient. Do not write a design document — write a reference card.

---

## Suggested document structure

```markdown
# Dev/Prod Parity Delta

**Delta as of 2026-03-27 — update when Phase 2 target changes.**

This document lists gaps between the local k3d development environment and the
Phase 2 production target (see `planning/architecture-diagram.md`). For each gap,
it states what cannot be reliably tested locally as a result.

## Gaps

| Component | Local (k3d) | Phase 2 Production Target | What you cannot reliably test locally |
|---|---|---|---|
| Istio | Installed (single-node) | Installed (multi-node) | ... |
| CNI | Flannel (NetworkPolicy enforced at L3/L4) | Cilium (eBPF L7 identity) | ... |
| Ingress | NodePort (port mapping) | IngressGateway | ... |
| Replicas | 1 per service | Multiple (HA) | ... |
| Rate limiting | Per-pod local_ratelimit (EnvoyFilter) | Redis-backed global ratelimit service | ... |
| JWKS cache | In-process (Istio pilot-agent) | External shared cache | ... |

## How to update this document
When the Phase 2 production target changes (new component added, gap closed),
update the table and bump the date in the header.
```
