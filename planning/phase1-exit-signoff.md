# Phase 1 Exit Sign-off

**Date:** 2026-03-26
**Status:** SIGNED OFF — Phase 2 unblocked

---

## Sign-off Gate Requirements

| Gate | Owner | Status |
|---|---|---|
| Track A complete (A1–A4I) | Technical Implementation Lead | ✅ |
| Track B complete (B1, B2a, B2b, B3/B4 deferred) | Technical Implementation Lead | ✅ |
| Gate 1 — Audit trail sign-off | Security/Privacy Lead | ✅ |
| Gate 2 — NetworkPolicy sign-off | Security/Privacy Lead | ✅ |
| Gate 3 — Prometheus spec scope | Product Lead | ✅ |
| Pre-Phase 2 gate — k3d migration (DEC-004) | Platform/Cluster Infrastructure Lead | ✅ CLEARED |
| BP-002 — SBOM acceptance criteria met | Security/Privacy Lead | ✅ (see below) |
| BP-005 — k3d version pinned in CLAUDE.md | Engineering Practices Lead | ✅ v5.7.4 |
| BP-006 — Test coverage audit complete | Engineering Practices Lead | ✅ (see below) |
| Test suite passing | Technical Implementation Lead | ✅ 42/42 |

---

## BP-006 — Test Coverage Audit

**Engineering Practices Lead sign-off**

### Current test suite: 42 tests across 3 files

| File | Cases | Behaviour area |
|---|---|---|
| `test_audit_trail.py` | 17 tests / 15 use cases | Audit trail write, field presence, log levels, OTel fallback |
| `test_observability.py` | 15 tests / 15 use cases | OTel tracing config, tracer lifecycle, JSON log formatter |
| `test_worker_client.py` | 10 tests / 10 use cases | Worker HTTP client: success, timeout, errors, schema validation |

### Coverage gaps identified

| Gap | Severity | Disposition |
|---|---|---|
| `classify_payload_sensitivity` tool handler not directly unit tested | Low | Tool logic delegates to `call_worker` + `write_audit_record` (both tested). Acceptable for Phase 1. Add in Phase 2 alongside template work. |
| RFC 9728 `/.well-known/oauth-protected-resource` endpoint not unit tested | Low | Covered by `status.sh` live check (automated, runs in CI equivalent). Unit test to be added in Phase 2 (BP-007). |
| `JWTAuthMiddleware` not unit tested | None | Being retired in Phase 2 (DEC-003). Not worth adding unit tests to code being removed. Covered by `auth-test.sh` live test matrix. |
| `auth/token_verifier.py`, `authorization/policy.py` not unit tested | None | Being retired in Phase 2 (DEC-003). Not worth adding unit tests to code being removed. |
| Rate limiting tests deleted | None | Correct — deleted per DEC-003 when SlowAPI was deferred. Will be covered by Phase 2 integration tests against Envoy (checklist in DEC-003 cases 21–30). |

**Finding:** The 42-test suite provides strong coverage of the three core behaviours that carry Phase 1 risk: audit trail correctness, observability correctness, and worker client error handling. All gaps are either acceptable-for-Phase-1 or being resolved by Phase 2 work. No gaps block Phase 1 exit.

**Engineering Practices Lead:** ✅ APPROVED for Phase 1 exit

---

## BP-002 — SBOM Acceptance Criteria and Sign-off

**Security/Privacy Lead sign-off**

### Acceptance criteria for `bom.json`

1. **Format:** CycloneDX 1.6 or later ✅
2. **Application services:** Both `mcp-presidio-sensitivity` and `presidio-worker` present as components ✅
3. **Python dependencies:** All direct and transitive dependencies from both `requirements.lock.txt` files present with pinned versions ✅
4. **Infrastructure containers:** Keycloak and Jaeger present as container components ✅
5. **CVE status:** pip-audit run with zero unmitigated HIGH or CRITICAL CVEs. Results documented at `src/worker/.pip-audit-ignore` ✅
6. **Tooling documented:** `pip-tools` and `pip-audit` listed as tools in metadata ✅
7. **Regeneration trigger:** `bom.json` must be regenerated after any dependency change (see CLAUDE.md lock file procedure) ✅

### Known gap accepted for Phase 1

- **BP-003:** `serialNumber` is a static UUID (`urn:uuid:c4a1f1e2-...`). This will be resolved by BP-001 (cdxgen automation in Phase 2), which generates a fresh UUID on each regeneration. Accepted for Phase 1 — static UUID does not affect CVE auditing or dependency tracking.

### Verification

`bom.json` reviewed against acceptance criteria above. All criteria met. BP-003 gap documented and accepted.

**Security/Privacy Lead:** ✅ SBOM ACCEPTED — Phase 1 exit unblocked

---

## Phase 1 Exit Declaration

All Track A, Track B, and pre-Phase 2 gate items are complete. All Phase 1 exit blocking criteria are met. The test suite passes at 42/42. NetworkPolicy enforcement is confirmed live under k3s/Flannel.

**Phase 2 (Istio / Cilium / cert-manager) is hereby unblocked.**

Deferred items carrying forward into Phase 2:
- B3/B4 — Rate limiting (DEC-003: moves to Istio/Envoy, checklist in DEC-003)
- DEC-001 — mTLS (resolved by Istio in Phase 2)
- BP-001 — SBOM automation (cdxgen, pre-Phase 2)
- BP-003 — SBOM serialNumber generation (resolved by BP-001)
- BP-007 — RFC 9728 discovery chain integration test
- BP-008 — Synthetic test corpus coverage gate (Detection/Data Researcher surge role)
- BP-010 — Disaster recovery runbook
- BP-011 — Teardown clean verification
- BP-012 — k3d version floor check in setup-local.sh
- BP-013 — Dev/prod parity delta document
- BP-014 — Acceptable parity threshold definition

**Signed:**
- Security/Privacy Lead ✅
- Engineering Practices Lead ✅
- Technical Implementation Lead ✅ (Wave 3 validation, 42/42 tests)
- Product Lead ✅
