# Task Plan: MCP + Presidio Sensitivity Classification

## Goal
Build a sensitivity classification service exposed as an MCP tool. Agents and services
invoke it when they need to evaluate whether data they are working with is potentially
sensitive before proceeding. The service accepts a payload, runs an ephemeral
Presidio-backed scan, and returns only a bounded summary result — never the payload.

---

## Current Architecture

```
[Agent / Service]
    |
    | MCP tool invocation (classify_payload_sensitivity)
    v
[MCP Server / Orchestrator]   ← trust boundary, auth, validation, policy dispatch
    |
    +-------------------------+
    | direct                  | queued (recommended)
    v                         v
[Ephemeral Scan Worker]    [Job Queue]
    - loads Presidio                |
    - applies recognizers           v
    - computes bounded result  [Ephemeral Scan Worker]
    - discards payload
    |
    v
[Result Minimizer]            ← strips payload, strips raw spans, summary only
    |
    v
[Audit / Result Store]        ← metadata only, no payload persistence
    |
    v
[MCP Tool Response]           ← bounded result returned to caller
```

**Caller:** Agents and services only. No human invokes this tool directly in production.
**Auth:** OAuth client credentials (JWT bearer assertions). Hydra is the Authorization Server.
**Deployment:** Helm charts throughout — local (Docker Desktop / Kubernetes), staging, production.
**Presidio:** Detection tool only — not the security boundary. The orchestrator owns trust.

---

## Phases

### Phase 0: Design and Proving
**Status:** `in_progress`
**Goal:** Validate architecture, confirm Presidio fit for target data types, establish
the minimized output contract. Produce enough to submit synthetic text and receive
a bounded result through the full authenticated path.
**Steps:**
- [x] Define ways of working and council structure
- [x] Scaffold planning files
- [ ] Confirm Docker Desktop with Kubernetes enabled (WSL2)
- [ ] Write local Helm values file (`values.local.yaml`) — Hydra + MCP server + Presidio worker
- [ ] Deploy Hydra locally via Helm — confirm token issuance and JWKS endpoint
- [ ] Configure a test client (service account + client credentials) in Hydra
- [ ] Confirm Presidio recognizer coverage against target data types (synthetic test)
- [ ] Produce architectural design document
- [ ] Confirm tool schema — input and output contracts
- [ ] Build minimal worker prototype (Helm chart, ephemeral worker, embedded Presidio)
- [ ] Build synthetic test corpus
- [ ] Wire MCP server to Hydra — validate 401/403/200 flows end-to-end
- [ ] Confirm failure paths do not leak payload data
**Exit Criteria:**
- Full local stack running via Helm (`helm install` or `helm upgrade`)
- Test client can obtain a token from Hydra and invoke `classify_payload_sensitivity`
- Valid token + correct scope → bounded result returned
- Invalid/missing token → 401 returned
- Valid token + wrong scope → 403 returned
- No raw payload returned in any response including error paths
- Failure paths documented and understood

---

### Phase 1: MVP Implementation
**Status:** `not_started`
**Goal:** Deliver the MCP tool with ephemeral scanning path, summary-only results,
and audit metadata without payload persistence.
**Build order (from spec):**
- [ ] Define MCP tool contract and result schema
- [ ] Build MCP server with schema validation and auth hooks
- [ ] Implement ephemeral worker with embedded Presidio analysis
- [ ] Add result minimizer — guarantee summary-only responses
- [ ] Add audit storage with no payload persistence
- [ ] Add monitoring, rate limiting, and operational controls
- [ ] Revisit classification policy model after empirical detector behavior is understood
**Exit Criteria:**
- Supported content types validated and enforced
- Oversized payloads rejected
- Valid payloads produce a `scan_id` and bounded result
- Raw payload is not logged or stored anywhere
- Worker runtime is ephemeral and bounded
- Authenticated caller can invoke successfully
- Unauthorized caller is rejected

---

### Phase 2: Operational Hardening
**Status:** `not_started`
**Goal:** Improve reliability, scalability, and governance.
**Steps:**
- [ ] Queue-based worker dispatch (if not already in Phase 1)
- [ ] Retry strategy
- [ ] Rate limiting
- [ ] Enhanced monitoring and alerting
- [ ] Version-controlled recognizer bundles
**Exit Criteria:**
- Stable under expected concurrency
- Timeouts and retries behave predictably
- Monitoring identifies failures and abnormal severity spikes
- Detector and policy bundle versions are traceable

---

### Phase 3: Controlled Release Workflows
**Status:** `not_started`
**Goal:** Introduce the possibility of returning payload content only when below an
approved threshold. Disabled by default.
**Steps:**
- [ ] Configurable release policy gate
- [ ] Per-tenant controls
- [ ] Additional review and audit rules
- [ ] Optional transformation / redaction path
**Exit Criteria:**
- Default behavior remains summary-only
- Release paths require explicit enablement
- Release actions logged with policy version and actor context
- Threshold changes are governed and traceable

---

### Phase 4: Expanded Content and Enterprise Features
**Status:** `not_started`
**Goal:** Extend detection breadth and classification maturity.
**Steps:**
- [ ] Additional language support
- [ ] Structured document handling
- [ ] Tenant-specific recognizers
- [ ] Classification model completion (promoted from deferred)
- [ ] Review workflows and analyst tooling
**Exit Criteria:**
- New content types have validated extraction paths
- Classification grouping model is approved by data governance stakeholders
- Expanded detectors meet defined quality thresholds

---

## Deferred: Classification Policy Model
**Status:** `deferred`
**Deferred because:** Detection capability can be validated before final taxonomy design.
False-positive and false-negative behavior from real usage should inform grouping.
Business classification requires stakeholder alignment beyond engineering.
**Interim approach:** Temporary severity bands (low / medium / high / critical) and
temporary grouped categories (direct_identifier, financial_identifier,
government_identifier, contact_data, secrets_like_data, regulated_like_data,
internal_business_sensitive). These are operational placeholders, not governance labels.
**Re-evaluate when:** MVP Phase 1 has generated empirical detector behavior data.

---

## Google Drive Folder Structure
Not applicable — this project lives in GitHub only.

---

## Canonical Paths Reference
```bash
PROJECT_ROOT="/home/james/dev/projects/data-sensitivity-poc/projects/mcp-presidio-sensitivity"
PLANNING="$PROJECT_ROOT/planning"
ROLE_INSTRUCTIONS="$PROJECT_ROOT/role-instructions"
SPECS="$PROJECT_ROOT/specs"
DELIVERABLES="$PROJECT_ROOT/deliverables"
```

---

## Decision Log
> Every decision must have a source. Source types: `spec` | `user` | `research:[url]` | `agent-reasoning` | `prior-session`

| # | Decision | Rationale | Source | Date |
|---|----------|-----------|--------|------|
| 1 | Classification policy model deferred from MVP | Detection can be validated before taxonomy design. False-positive/negative behavior should inform grouping. Premature taxonomy design risks rework. Business classification requires stakeholder alignment beyond engineering. | `spec` §6 | Session 4 |
| 2 | Embedded library mode preferred over sidecar/service mode for Presidio | Fits the ephemeral worker boundary better — fewer network hops, better per-job isolation | `spec` §3.4 | Session 4 |
| 3 | Option B (queued worker dispatch) is the recommended architectural fit | Better isolation for spikes, easier retry strategy, better fit for future scale. Accepted additional platform complexity. | `spec` §3.3 | Session 4 |
| 4 | Lean council: 3 core roles + optional Detection/Data Researcher | Project complexity at MVP does not justify more. Concerns not yet large enough to split. Anti-sprawl rule applied. | `user` + `agent-reasoning` | Session 4 |
| 5 | Priority stack: correctness/bounded behavior → security → reliability → expansion | Security is non-negotiable. No human catches a wrong answer at invocation time. Speed is valid but never top priority. | `user` + `spec` §4 | Session 4 |
| 6 | Caller is agents and services only — service-to-service auth | Tool is invoked programmatically in agentic workflows. No human invokes directly in production. Developer use is for integration testing only. | `user` | Session 4 |
| 7 | Helm as deployment model from Phase 0 | WSL2 with Docker Desktop supports Helm. Starting with Helm means local environment mirrors production from day one — isolation, network policies, and resource limits are real and tested, not retrofitted. Environment promotion is a values file swap, not a runtime model change. | `user` | Session 4 |
| 8 | Hydra (ORY) as Authorization Server | Purpose-built for machine-to-machine OAuth client credentials. Lighter than Keycloak. No UI overhead. Official Helm chart available. Directly maps to production OAuth AS configuration for service-to-service flows. JWT bearer assertions preferred over client secrets per auth spec §3. | `user` + `agent-reasoning` | Session 4 |

---

## Errors Encountered
| Error | Attempt # | Resolution |
|-------|-----------|------------|

---

## Open Questions
All Stage 1 questions resolved. See ways-of-working.md §9.
