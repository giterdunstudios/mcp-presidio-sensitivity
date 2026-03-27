# Task Plan: Presidio Vertical Scanning Templates

## Goal
Determine whether and how to add regulation-named scanning template support to `classify_payload_sensitivity`, enabling callers to select a compliance profile (e.g. `hipaa_core`, `pci_dss`) that pre-configures which Presidio entity types and custom recognizers are activated.

## Phases

### Phase 1: Council Research — Ecosystem & Gap Analysis
**Status:** `complete`
**Goal:** Understand the Presidio extensibility model, compliance framework PII requirements, competitive template packaging patterns, and the gap between Presidio defaults and what each vertical needs.
**Steps:**
- [x] Define council research charter (Security/Privacy Lead, Tech Lead, Product Lead)
- [x] Tech Lead: Presidio extensibility model, OSS ecosystem, YAML format
- [x] Security/Privacy Lead: Compliance framework → PII mapping, Presidio coverage vs gaps
- [x] Product Lead: Vertical community usage, competitor template packaging, integration surface
- [x] Council synthesis: naming convention, base/enhanced split, out-of-scope boundaries, open decisions
**Output:** findings.md Phase 1 section + memory record

---

### Phase 2: Community Recognizer Evaluation
**Status:** `complete`
**Goal:** For each priority custom recognizer gap identified in Phase 1, find and evaluate any existing community implementations (GitHub, HuggingFace, blog posts) to determine reuse vs. build.
**Steps:**
- [x] Search for existing NPI (National Provider Identifier) recognizer implementations
- [x] Search for DEA number recognizer implementations
- [x] Search for ABA routing number recognizer implementations
- [x] Search for SWIFT/BIC code recognizer implementations
- [x] Search for EU national ID recognizers (FR NIR, DE Tax ID, NL BSN, BE RRN, SE Personnummer, DK CPR)
- [x] Search for Medicare Beneficiary ID (MBI) recognizer implementations
- [x] Search for CVV/card security code recognizer implementations
- [x] Research alternate secret scanners (OSS status, licenses, embedding options)
- [x] Evaluate each: pattern quality, license, maintenance status, Presidio fit
**Output:** findings.md Phase 2 section — reuse vs build table per custom recognizer

---

### Phase 3: Worker Architecture Spec
**Status:** `not_started`
**Goal:** Define how templates are discovered, loaded, versioned, and cached inside the presidio-worker service. Resolve the three open council decisions.
**Steps:**
- [ ] Resolve open decision: secrets/credentials vertical — Presidio templates or separate scanner?
- [ ] Resolve open decision: custom recognizer delivery — YAML vs Python packages vs worker images
- [ ] Resolve open decision: geographic scoping — per-jurisdiction or composite tags?
- [ ] Spec template directory structure in worker (`templates/` directory layout)
- [ ] Spec template versioning scheme (semver in metadata, scan ID records version)
- [ ] Spec template loading path (startup load vs. per-request lazy load vs. cached AnalyzerEngine instances)
- [ ] Spec template registry API (how worker exposes available templates to MCP server)
- [ ] Write architecture decision record (DEC-00X) for council ratification
**Output:** findings.md Phase 3 section + draft DEC entry for planning/decision-log.md

---

### Phase 4: Audit Trail & API Additions
**Status:** `not_started`
**Goal:** Define the changes to the MCP tool interface and audit trail required to support templates.
**Steps:**
- [ ] Define `template` parameter spec for `classify_payload_sensitivity`
- [ ] Define precedence rules: explicit `entities` → named `template` → default
- [ ] Define response additions: `template`, `template_display_name`, `entities_scanned`, `template_version`
- [ ] Define audit trail additions: template slug + version recorded per scan
- [ ] Review impact on existing test suite (test_classify.py, test_auth.py)
- [ ] Identify any Helm values changes needed (template directory mounting, config)
**Output:** findings.md Phase 4 section + draft tool interface spec

---

### Phase 5: Enhancement Proposal (Council Gate)
**Status:** `not_started`
**Goal:** Package all findings into a formal enhancement proposal for council consideration. This is the gate before any implementation begins.
**Steps:**
- [ ] Draft enhancement proposal document
- [ ] Include: motivation, proposed template set, API spec, architecture, open risks
- [ ] Council review: Security/Privacy Lead sign-off on template scope boundaries
- [ ] Council review: Tech Lead sign-off on architecture
- [ ] Council review: Product Lead sign-off on API and naming
- [ ] Decision: schedule for Phase 2 implementation alongside Istio work, or defer to Phase 3
**Output:** planning/vertical-templates/enhancement-proposal.md + council decision

---

## Decision Log

| # | Decision | Rationale | Source | Date |
|---|----------|-----------|--------|------|
| 1 | Regulation-first naming (`hipaa_core`, `pci_dss`) not vertical-first (`healthcare`) | Anchors template to a testable compliance obligation; matches Purview/Google DLP pattern | research:Purview docs + agent-reasoning | 2026-03-26 |
| 2 | Base/Enhanced split (`hipaa_core` vs `hipaa_extended`) | Base = minimum structured identifiers; Enhanced = adds contextual entities with higher FP risk. Gives operators a choice. | research:Microsoft Purview DLP templates | 2026-03-26 |
| 3 | GDPR Art. 9 special categories out of scope for pattern-based templates | Health, genetic, biometric, sexual orientation cannot be reliably regex-detected. A false-precision detector is worse than none. | agent-reasoning (Security/Privacy Lead) | 2026-03-26 |
| 4 | Financial behavioral data (balances, transactions, income) out of scope | Requires semantic NLP, not pattern matching. Outside Presidio's pattern-based recognizer model. | agent-reasoning (Security/Privacy Lead) | 2026-03-26 |
| 5 | Server-side template registry only — no inline caller-supplied templates | Caller-supplied templates could bypass governance by omitting all entities. Registry enforces scope. | agent-reasoning (Product Lead) | 2026-03-26 |
| 6 | Template versioning required | Scan IDs in audit trail must be reproducible; requires recording template slug + version per scan. | agent-reasoning (Product Lead + Security/Privacy Lead) | 2026-03-26 |
| 7 | YAML as primary template format | Native Presidio support via `PatternRecognizer.from_dict()`; portable, auditable, no runtime Python eval. | research:Presidio docs (Tech Lead) | 2026-03-26 |
| 8 | detect-secrets as in-process secrets companion | Apache-2.0, Python-native, `SecretsCollection` directly importable, runs in same worker container as presidio-analyzer. No subprocess overhead. Slow update cadence acceptable supplemented with custom plugins. | research:OSS scanner comparison (Phase 2) | 2026-03-26 |
| 9 | TruffleHog eliminated | AGPL-3.0 constrains code-level embedding; live API verification adds per-scan network latency — unsuitable for low-latency payload classification. | research:OSS scanner comparison (Phase 2) | 2026-03-26 |
| 10 | ggshield eliminated | Detection engine is SaaS cloud-dependent. Cannot send PII payloads off-cluster. | research:OSS scanner comparison (Phase 2) | 2026-03-26 |
| 11 | Prefix-anchored secrets (AWS/GitHub/GCP) as PatternRecognizer entries | Near-zero false positives, no external dependency, YAML-portable. Belong in soc2_cloud template directly rather than delegating to external scanner. | research:community patterns (Phase 2) | 2026-03-26 |

## Open Decisions (require council)

| # | Question | Options | Blocking Phase |
|---|----------|---------|----------------|
| OD-1 | ~~Secrets/credentials vertical — Presidio templates or separate secret scanner?~~ **RESOLVED: detect-secrets in-process (Apache-2.0) + prefix-anchored PatternRecognizers for known formats; Gitleaks subprocess for broader coverage** | — | — |
| OD-2 | ~~Custom recognizer delivery — YAML vs Python packages vs separate worker images for ML?~~ **RESOLVED: YAML for pattern/deny-list (shared between real-time and batch); ML-backed recognizers in separate ephemeral batch worker image** | — | — |
| OD-3 | ~~Geographic scoping — per-jurisdiction or composite tags?~~ **RESOLVED: Geographic scoping is a design requirement — the template schema and registry must accommodate jurisdiction variants. Not implemented in initial dev but architecture must not foreclose it.** | — | — |

## Errors Encountered
| Error | Attempt # | Resolution |
|-------|-----------|------------|
| WebSearch/WebFetch unavailable in research agents | 1 | Agents used training-data knowledge (Presidio stable through Aug 2025); flagged for verification |

## Notes
- This is an **enhancement candidate** — no implementation scheduled yet
- Phase 5 council gate is the decision point for scheduling
- The k3d migration (Wave 3 validation) and Phase 2 Istio work take priority
- Presidio entity catalog should be verified against live docs before Phase 2 begins (agents could not fetch live URLs)
- **Batch job is explicitly out of scope until payload scanning (real-time templates) is fully developed and released.** All batch-related open questions (trigger mechanism, results delivery, ML worker image, Gitleaks subprocess, gdpr_special) are deferred until that point. Do not let batch scope creep into the template implementation work.
