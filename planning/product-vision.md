---
title: Product Vision — Solutions Goal
status: council-ratified
date: 2026-03-27
authors: Product/Scope Lead + full council refinement
---

# Solutions Goal

## One-sentence statement

Give companies an easily deployable, self-hosted sensitivity classification
service that their LLM-adjacent clients (chat interfaces, IDEs, apps) can call
before sending data to an LLM — so users get immediate feedback on what they are
sharing, without requiring each company to build or maintain the detection
infrastructure themselves.

---

## The problem we solve

Most companies using LLMs have no systematic way to tell users when they are
about to share sensitive data. The tooling exists (Presidio, spaCy, pattern
libraries) but assembling it into a reliable, auth-gated, observable service
that integrates with MCP-capable clients is non-trivial. Companies that try to
build this themselves spend engineering time on infrastructure rather than their
core product.

This is not a solved space. The gap is real and present, not theoretical.

---

## Who we serve

**Primary customer:** a company whose employees use LLM clients (chat, IDE
plugins, internal apps) and whose IT or platform team needs a policy control
point before data reaches external LLM APIs.

**Secondary customer:** the company's end users — developers, analysts, anyone
whose prompt might contain sensitive data — who receive immediate, actionable
feedback without needing to understand what was detected.

**Not the customer (v1):** individual developers, consumer products, or
companies that want a hosted SaaS where their data transits our infrastructure.

---

## Deployment model: on-prem first

**Payload content never leaves the customer's infrastructure. This is a hard
design principle, not a configuration option.**

The service is deployed by the customer's platform team inside their own
environment (Kubernetes cluster, Docker Compose, etc.). We ship the software;
we never see the data. This means:

- We are a software vendor, not a data processor
- GDPR/HIPAA obligations stay with the customer, not us
- Enterprise adoption is not blocked by legal review of data sharing agreements
- Air-gapped and regulated-industry deployments are possible

The current Helm chart architecture is the right delivery mechanism. Phase 2
hardening (Istio, mTLS, Cilium) makes it enterprise-deployable. The charts are
the product.

---

## What "feedback" means in v1

**v1 mode: warn.** The service classifies the payload and returns a structured
result. The calling client decides what to do with it (show a warning, prompt
for confirmation, proceed, abort). The service does not block.

This is the right v1 choice because:
- Client behaviour varies — an IDE plugin and a chat interface need different
  UX affordances; the service should not dictate them
- Blocking requires the service to be in the critical path with strict latency
  SLOs; warn mode is advisory and latency is less punishing
- Companies can implement their own block policy in their client using the
  structured classification result

**v2 modes (future):**
- **Block** — service returns a deny decision; client must stop the request;
  service becomes critical-path
- **Annotate** — service adds metadata to the payload that travels with it to
  the LLM; LLM can respond differently based on sensitivity context

---

## Configuration model

**Zero-configuration default:** the `llm_default` template (DEC-006) works out
of the box for general LLM use cases — common PII, credentials, secrets. A
company installs the service and their clients get detection without writing a
single line of config.

**Compliance overlays:** companies with specific regulatory requirements
(`hipaa_core`, `pci_dss`, `gdpr_baseline`, etc.) apply a named template. One
config field in the Helm values. No code changes.

**Custom templates (future):** companies define their own entity patterns
(internal project codenames, proprietary identifiers) as extensions.

**The configuration surface a company's platform team touches:**
1. Keycloak client credentials (auth)
2. Template selection (sensitivity policy)
3. Resource URL for RFC 9728 discovery (so their clients can auto-discover)
4. That's it for v1.

---

## Quality bar: time-to-first-classification

**A competent platform engineer should reach their first successful
classification within 30 minutes of starting from the README.**

This is the primary onboarding quality metric. If it takes longer, we have
a documentation or configuration complexity problem, not just a nice-to-have
polish issue. Every friction point between download and first classification
is a reason a company's IT team recommends against adoption.

Current blockers to this goal (to be resolved before v1 release):
- Keycloak TTL must be set manually after setup (`keycloak-admin.sh set-ttl 60`)
- No single-command install path (multi-step: cluster + Keycloak + charts)
- No "is it working?" confirmation beyond running status.sh

---

## Monetization (future, Phase 3+)

Usage-based pricing beyond a free tier. Companies pay for volume above a
threshold — measured in classifications per month.

**Architecture constraint:** usage telemetry must report call counts only.
No payload content, no entity types detected, no caller-subject identifiers
— only aggregate volume per installation. The telemetry mechanism must be
reviewed by the Security/Privacy Lead before implementation.

This requires a licence key / installation ID concept in the architecture.
No current implementation exists. Flag for Phase 3 scope definition.

---

## How this shapes technical priorities

| Vision element | Technical implication |
|----------------|----------------------|
| On-prem first | Helm charts are the product; must be production-grade |
| Payload never leaves customer infra | Audit trail never contains payload — already enforced |
| 30-min time-to-first-classification | Setup simplification, single-command path, clear README |
| Warn mode v1 | Classification result is the API; latency matters but not critical-path SLO |
| Zero-config default (`llm_default`) | DEC-006 already decided; vertical templates are the config surface |
| Enterprise deployable | Phase 2 Istio/mTLS/Cilium is the hardening layer that enables this |
| Usage-based billing | Architecture placeholder in Phase 3; no implementation yet |
| Multi-client support | RFC 9728 discovery already implemented — MCP clients auto-discover |

---

## What this is not

- Not a hosted SaaS (v1) — we do not run the infrastructure; companies do
- Not a consumer product — target is company IT/platform teams, not individuals
- Not a blocking gateway (v1) — warn mode only; clients own enforcement policy
- Not a general-purpose data loss prevention (DLP) product — scoped to
  pre-LLM payload sensitivity classification via the MCP tool interface

---

## Council notes

**Security/Privacy Lead:** the "payload never leaves customer infrastructure"
principle must be enforced architecturally and documented as a guarantee, not
just a default. Any Phase 3+ hosted-SaaS path would require a full council
review and a new decision log entry — it represents a fundamentally different
data handling posture.

**Technical Implementation Lead:** the vertical templates work (DEC-006,
research complete) becomes the core configuration product, not a nice-to-have.
Prioritise its implementation phase accordingly.

**Engineering Practices Lead:** the 30-minute benchmark should be measured
against a real setup attempt (not by someone who built the system) before v1
release. Add an onboarding test to the DR runbook.

**Product/Scope Lead:** the on-prem model is also the sales motion — "you keep
your data, we give you the tooling." That is a stronger enterprise story than
a hosted alternative for regulated industries. Lean into it.
