# Vertical Templates — Phase Proposal for Council Vote

## What Is Already Resolved (Not in Scope for This Vote)

DEC-006 (2026-03-26) established the following as implemented decisions:

- **`llm_default`** is the default template for `classify_payload_sensitivity` when no
  template is specified. It composes `general_pii` built-ins with three prefix-anchored
  secret patterns (AWS `AKIA/ASIA/AROA/AIDA`, GitHub `gh[pousr]_`, GCP `AIza`).
  Pattern-only — no entropy scanning, no subprocess. Deterministic latency. **Done.**
- **`general_pii`** is the Presidio built-ins baseline (approximately 40–45 entities).
  No custom recognizers. **Done.**
- Vertical templates (`hipaa_core`, `pci_dss`, `gdpr_core`, etc.) are **opt-in overlays**
  for domain-aware callers — not the default. They require explicit `template` parameter.

This proposal covers only the remaining vertical template work. `llm_default` and
`general_pii` are not in scope.

---

## Background

Phases 1 and 2 of the vertical templates research task (`planning/vertical-templates/task_plan.md`)
are complete:

- **Phase 1** (council research): Presidio extensibility model, compliance framework coverage
  analysis, competitor template packaging patterns, naming conventions, base/enhanced split
  rationale, out-of-scope boundary definitions.
- **Phase 2** (community recognizer evaluation): Reuse vs. build assessment for NPI, DEA, MBI,
  ABA routing, SWIFT/BIC, CVV, EU national IDs (FR, DE, NL, BE, SE, DK), and API keys/secrets.
  OSS credential scanner comparison (detect-secrets, Gitleaks, TruffleHog, ggshield).

Three open decisions that blocked scheduling were identified during Phase 1. All three now have
proposed resolutions from the Phase 2 investigation. They require council ratification before
Phase 3 implementation begins.

---

## Open Decisions Requiring Council Ratification

These are not unresolved questions. Each has a proposed resolution from the research findings.
The council is asked to ratify or amend the proposed resolution.

### OD-1 — Secrets/Credentials: Presidio Templates vs. External Secret Scanner

**Proposed resolution:**
- Prefix-anchored secrets (AWS, GitHub, GCP) → `PatternRecognizer` entries in YAML.
  Near-zero false positives; no external dependency; YAML-portable. Already in `llm_default`.
- Generic/entropy-based secrets (high entropy strings, unknown key formats) →
  `detect-secrets` (Yelp, Apache-2.0) as an in-process companion inside the `soc2_cloud`
  template only. Python-native `SecretsCollection`, no subprocess overhead.
- Gitleaks (Go, MIT) as an optional subprocess complement for broader sweep coverage in
  the batch scanner context. **Not** in the real-time worker.
- TruffleHog v3 eliminated: AGPL-3.0 constraint + live API verification adds per-scan
  network latency. ggshield eliminated: cloud-dependent SaaS engine, cannot send PII
  off-cluster.

**Council is asked:** Ratify OD-1 as stated. If not ratified, specify what changes.

---

### OD-2 — Custom Recognizer Delivery: YAML vs. Python Packages vs. Worker Images

**Proposed resolution:**
- **YAML** for all pattern-based and deny-list recognizers. Shared between the real-time
  worker and the batch worker. Loaded via `PatternRecognizer.from_dict()` — native
  Presidio support, no custom loader.
- **ML-backed recognizers** (spaCy clinical NER, HuggingFace transformers, ICD-10 code
  list lookup) ship in a separate ephemeral batch worker image. Not loaded in the real-time
  worker, which keeps worker latency predictable.
- The real-time worker and batch job share the same YAML template definitions; the batch
  job loads a superset (YAML templates plus ML recognizer configuration).

**Note on batch scope:** The batch scanner service is explicitly out of scope until
real-time templates are fully developed and released. All batch-related open questions
(trigger mechanism, results delivery, ML worker image, Gitleaks subprocess, `gdpr_special`
template) are deferred. The proposed OD-2 resolution defines the architecture boundary;
it does not schedule batch implementation.

**Council is asked:** Ratify OD-2 as stated. If not ratified, specify what changes.

---

### OD-3 — Geographic Scoping: Per-Jurisdiction Variants vs. Composite Tags

**Proposed resolution:**
- Geographic jurisdiction is a **design requirement** for the template schema and registry.
  The schema must accommodate jurisdiction variants (e.g., `gdpr_core` for EU-wide coverage,
  with possible future `gdpr_de`, `gdpr_fr` variants activating jurisdiction-specific
  national ID recognizers).
- Initial templates are jurisdiction-neutral where possible (e.g., `pci_dss` covers card
  formats globally; `hipaa_core` is US-only by regulation scope).
- The architecture must not foreclose adding jurisdiction variants. No jurisdiction variants
  are implemented in the initial release.

**Council is asked:** Ratify OD-3 as stated. If not ratified, specify what changes.

---

## Proposed Template Set

The following templates are proposed for implementation (excluding `llm_default` and
`general_pii`, which are already done):

| Slug | Regulatory Standard | Priority | Recognizer Approach | Notes |
|---|---|---|---|---|
| `pci_dss` | PCI DSS v4 | High | Presidio built-ins + ABA routing, SWIFT/BIC, CVV (context-dependent) | CVV detection viable only in structured forms; documented limitation |
| `hipaa_core` | HIPAA Safe Harbor 18 identifiers | High | Presidio built-ins + NPI, DEA, MBI YAML recognizers | Checksum validators required for NPI (Luhn), DEA, NL BSN, FR NIR |
| `hipaa_extended` | HIPAA + clinical context entities | Medium | `hipaa_core` plus ICD-10 codes, contextual clinical terms | Higher false-positive rate; operator opt-in |
| `gdpr_core` | GDPR Art. 4 personal data | High | Presidio built-ins + EU national ID YAML recognizers (FR, DE, NL, BE, SE, DK) | Initial set; jurisdiction variants deferred per OD-3 |
| `gdpr_special` | GDPR Art. 9 special categories | Low (Phase 3+) | ML-backed recognizers only — batch scanner service | Not pattern-detectable; batch mode only; deferred until batch service exists |
| `glba` | U.S. GLBA | Medium | Presidio built-ins + financial account identifiers | Overlaps substantially with `pci_dss` |
| `ferpa` | U.S. FERPA | Low | Presidio built-ins + student ID patterns | Simple recognizer set |
| `soc2_cloud` | SOC 2 + secrets/credentials | Medium | Prefix-anchored PatternRecognizers + detect-secrets in-process | Not for real-time hot path — detect-secrets introduces variable latency |

**Scheduling note:** `gdpr_special` is a batch-only template and is out of scope until the
batch scanner service is implemented.

---

## Phases 3 and 4 — Scope and Sequencing

### What Phase 3 (Worker Architecture Spec) Covers

Phase 3 produces the implementation spec for how templates are loaded, versioned, and served
inside the `presidio-worker` service. Specifically:

- Template directory layout under `templates/`
- Template versioning scheme (semver in YAML metadata; template slug + version recorded in
  scan responses and audit trail)
- Template loading path: startup load vs. per-request lazy load vs. cached `AnalyzerEngine`
  instances per template
- Template registry API: how the worker exposes available templates to the MCP server
- Architecture decision record (new DEC entry) for council ratification

Phase 3 also covers the real-time/batch architecture boundary established by OD-2, now
confirmed: two services share YAML definitions; ML recognizers are batch-only.

### What Phase 4 (Audit Trail and API Additions) Covers

Phase 4 defines the changes to the MCP tool interface and the audit trail required to
support templates:

- `template` parameter spec for `classify_payload_sensitivity`
- Precedence rules: explicit `entities` override → named `template` → `llm_default`
- Response additions: `template`, `template_display_name`, `entities_scanned`,
  `template_version`
- Audit trail additions: template slug + version recorded per scan
- Impact review on existing test suite (`test_classify.py`, `test_auth.py`)
- Any Helm values changes needed (template directory mounting, worker config)

### Proposed Sequencing Relative to Project Phase 3

The project's current Phase 2 (Istio/Envoy service mesh) is active. The vertical templates
implementation phases (task_plan Phases 3 and 4) interact with Phase 2 in one area:
Phase 4 adds a `template` parameter and response fields to the MCP tool. This is an
application-layer change — it does not interact with Envoy auth, rate limiting, or mTLS.
No blocking dependency exists.

**Proposed sequencing:**

| Work | Timing |
|---|---|
| OD-1, OD-2, OD-3 ratification (this vote) | Before any Phase 3 work begins |
| Phase 3: Worker Architecture Spec | Can begin after OD ratification; runs parallel to Istio Phase 2 infra work where coupling analysis confirms no co-change risk |
| Phase 4: Audit Trail & API Additions | Begins after Phase 3 spec is ratified; contains application code changes — runs after Istio auth migration to avoid double-churn on `main.py` and `audit/trail.py` |
| Phase 5 (task_plan): Enhancement Proposal | This document is the Phase 5 output. Council vote below is the Phase 5 gate. |
| Implementation: `pci_dss`, `hipaa_core`, `gdpr_core` (Priority: High) | Project Phase 3 (post-Istio) |
| Implementation: `hipaa_extended`, `glba`, `soc2_cloud` (Priority: Medium) | Project Phase 3, after High priority templates ship |
| Implementation: `ferpa`, `gdpr_special` batch (Priority: Low) | Project Phase 4+ |

**Rationale for Phase 3 start:** Running Phase 3 (spec only, no code) in parallel with
Istio work is low risk. It produces a spec document and a new DEC entry — no application
code touches Istio. Coupling analysis should be run before scheduling to confirm low
co-change frequency between `planning/` and `src/worker/` files.

**Rationale for Phase 4 delay:** The audit trail (`audit/trail.py`) and the MCP tool
handler are both in scope for Istio Phase 2 migration (JWT validation moves to Envoy;
audit trail may gain new context fields from sidecar headers). Changing these in parallel
with template additions risks conflicting diffs and re-test overhead. Sequencing Phase 4
after Istio migration completes avoids this.

---

## Compliance Disclaimer

Vertical template names in this system are **classification aids only**. They indicate
which entity types and recognizers are activated during a scan. They do not:

- Confer compliance status on the caller's data processing operations
- Guarantee detection of all PII types required under a given regulation
- Substitute for a compliance assessment, legal review, or certification process
- Cover all data elements required by the named standard (coverage gaps are documented
  in `planning/vertical-templates/findings.md`)

The term `hipaa_core` means "a template that scans for HIPAA Safe Harbor identifiers
that Presidio can detect." It does not mean "use of this template makes your system
HIPAA-compliant."

Callers operating under regulatory obligations are responsible for understanding coverage
gaps and supplementing with appropriate controls.

---

## Council Vote Request

This section constitutes the formal Phase 5 council gate from `task_plan.md`. Three
sign-offs are required before any Phase 3 implementation work begins.

All questions are yes/no. Amendments should be noted inline.

---

**Security/Privacy Lead**

| # | Question | Decision |
|---|----------|----------|
| S-1 | Ratify OD-1 as proposed (detect-secrets in-process for `soc2_cloud`; prefix-anchored patterns in YAML; TruffleHog and ggshield eliminated)? | [ ] Yes / [ ] No — Amendment: |
| S-2 | Ratify proposed template set and priority ordering? | [ ] Yes / [ ] No — Amendment: |
| S-3 | Accept compliance disclaimer section as written? | [ ] Yes / [ ] No — Amendment: |
| S-4 | Approve proceeding to Phase 3 (Worker Architecture Spec)? | [ ] Yes / [ ] No |

Signature: ___________________________ Date: ___________

---

**Technical Implementation Lead**

| # | Question | Decision |
|---|----------|----------|
| T-1 | Ratify OD-2 as proposed (YAML for pattern/deny-list; ML-backed in separate batch image; batch explicitly deferred)? | [ ] Yes / [ ] No — Amendment: |
| T-2 | Ratify OD-3 as proposed (jurisdiction as schema requirement; no jurisdiction variants in initial release)? | [ ] Yes / [ ] No — Amendment: |
| T-3 | Accept Phase 3/4 sequencing relative to Istio Phase 2? | [ ] Yes / [ ] No — Amendment: |
| T-4 | Approve proceeding to Phase 3 (Worker Architecture Spec)? | [ ] Yes / [ ] No |

Signature: ___________________________ Date: ___________

---

**Product / Scope Lead**

| # | Question | Decision |
|---|----------|----------|
| P-1 | Ratify proposed template slugs and naming convention as consistent with DEC-006 and findings.md? | [ ] Yes / [ ] No — Amendment: |
| P-2 | Confirm `gdpr_special` and batch scanner are deferred — not in scope for Phase 3 implementation? | [ ] Yes / [ ] No — Amendment: |
| P-3 | Accept template precedence: explicit `entities` → named `template` → `llm_default`? | [ ] Yes / [ ] No — Amendment: |
| P-4 | Approve proceeding to Phase 3 (Worker Architecture Spec)? | [ ] Yes / [ ] No |

Signature: ___________________________ Date: ___________

---

**Gate outcome:** Phase 3 work begins only when all three leads have signed P-4 / S-4 / T-4
as Yes. Any No on those questions blocks scheduling until the amendment is incorporated and
a re-vote is held.
