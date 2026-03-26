# Best Practices Backlog

Owned by: Engineering Practices Lead
Maintained per §4.5 and §5b of `role-instructions/ways-of-working.md`.

Items in this backlog are cross-cutting improvements to governance, testing, reproducibility,
and dev/prod parity. Each role is responsible for implementing items in their own area.
Coordination items are tracked in `planning/council-workboard.md`.

When an item is proposed and no role schedules it for valid project reasons,
it must be raised at the next council meeting per §5c.

**Last updated:** 2026-03-26

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
| BP-001 | SBOM (`bom.json`) automated regeneration via cdxgen in `rebuild.sh` | `proposed` | Security/Privacy Lead (owns SBOM); Technical Implementation Lead (implements cdxgen) | Pre-Phase 2 | cdxgen integration; SBOM regenerates on every image push. Security/Privacy Lead must approve toolchain. Discussed 2026-03-26. |
| BP-002 | SBOM acceptance criteria for Phase 1 exit sign-off | `scheduled` | Security/Privacy Lead | Phase 1 exit | Security/Privacy Lead owns and signs off on SBOM. Must define criteria before Phase 1 exit. |
| BP-003 | `bom.json` serialNumber should be generated (not static) | `proposed` | Security/Privacy Lead | Pre-Phase 2 | Current serialNumber is a fixed UUID; cdxgen integration (BP-001) resolves this. Blocked on BP-001. |
| BP-004 | Verify all roles have read `ways-of-working.md` v1.1 | `complete` | Engineering Practices Lead | 2026-03-26 | Ratification session served as read-through. |
| BP-005 | Pin exact k3d version in CLAUDE.md prerequisites table | `proposed` | Engineering Practices Lead | Wave 3 | Currently listed as `5.x`. Pin to installed version after Wave 3 setup-local.sh run. |

---

## Testing

| ID | Item | Status | Owner role | Phase | Notes |
|----|------|--------|-----------|-------|-------|
| BP-006 | Test coverage audit: map 42 existing test cases to solution behaviours | `proposed` | Engineering Practices Lead + Technical Implementation Lead | Phase 1 exit prep | Identify untested behaviours before Phase 1 exit. Needs coordination (see workboard). |
| BP-007 | Integration test for RFC 9728 discovery chain (not just unit) | `proposed` | Technical Implementation Lead | Phase 1 exit prep | `auth-test.sh` covers auth cases; no automated test for full discovery chain. |
| BP-008 | Synthetic test corpus coverage gate: require corpus case for each new entity type added | `proposed` | Detection / Data Researcher (when active) | Phase 1+ | Coordinate with Engineering Practices Lead on acceptance threshold. |
| BP-009 | Wave 3 regression validation (D1–D6) — k3d migration | `in_progress` | Technical Implementation Lead | Pre-Phase 2 gate | Not a best practices item per se but tracked here for gate visibility. Passes when all 6 scripts green. |

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
| BP-015 | Validate NetworkPolicy enforcement is real under k3d/k3s CNI (kindnet → Flannel change) | `proposed` | Security/Privacy Lead + Engineering Practices Lead | Wave 3 | kindnet and Flannel have different enforcement characteristics. Confirm `validate-networkpolicy.sh` still meaningful under k3s. |

---

## Escalated items

None currently. Any item unscheduled after two council cycles moves here.
