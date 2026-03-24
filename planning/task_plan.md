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
- [x] Confirm Docker Desktop with Kubernetes enabled (WSL2) — Docker Engine installed in WSL2 directly
- [x] Write local Helm values file (`values.local.yaml`) — Hydra + MCP server + Presidio worker
- [x] Deploy Hydra locally via Helm — confirm token issuance and JWKS endpoint
- [x] Configure a test client (service account + client credentials) in Hydra
- [x] Confirm Presidio recognizer coverage against target data types (synthetic test corpus — Lane C)
- [ ] Produce architectural design document
- [x] Confirm tool schema — input and output contracts (spec §2.3–2.5, implemented in worker + MCP server)
- [x] Build minimal worker prototype (Helm chart, ephemeral worker, embedded Presidio)
- [x] Build synthetic test corpus (Lane C — 46 test cases, 8 files)
- [ ] Wire MCP server to Hydra — validate 401/403/200 flows end-to-end (Lane D built, cluster recreation pending)
- [ ] Confirm failure paths do not leak payload data (Lane D Security/Privacy Lead review pending)
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
| 9 | regulated_like_data and internal_business_sensitive categories excluded from Phase 0 corpus | No concrete entity types are enumerated for these categories in the interim model (spec §6.3). regulated_like_data requires custom recognizers for domain-specific identifiers (NPI, DEA, NHS). internal_business_sensitive is inherently tenant-specific and cannot be generically represented. Both categories are deferred pending taxonomy formalization. | `agent-reasoning` + `spec` §6 | 2026-03-24 |
| 10 | Corpus uses IANA TEST-NET IPs, IRS-reserved SSN ranges, IANA example.com domains, Luhn-valid test card numbers, and 555-prefix phone numbers | Ensures all synthetic data values are unambiguously non-operational while still being format-valid for recognizer pattern matching. Follows briefing rules exactly. | `agent-reasoning` | 2026-03-24 |
| 11 | Line-break evasion (edg-003) documented as expected false negative | SSNs split across newlines are a known regex recognizer limitation. Documenting baseline behavior rather than treating it as a scanner defect. Evasion-resistant scanning is a Phase 2+ concern. | `agent-reasoning` | 2026-03-24 |
| 12 | AGE and AWS_ACCESS_KEY entity types excluded from MVP APPROVED_ENTITY_TYPES | AGE is not a Presidio built-in recognizer; AWS_ACCESS_KEY is not in the standard Presidio built-in set. Both category mappings are retained in classification.py for when recognizers are added. | `agent-reasoning` + `spec` §6.3 | 2026-03-24 |
| 13 | AnalyzerEngine initialised as module-level singleton | Loading NLP models on every request is prohibitively slow. AnalyzerEngine is stateless with respect to input text; sharing one instance across requests is safe and correct. | `agent-reasoning` | 2026-03-24 |
| 14 | Raw RecognizerResult objects stripped immediately in analyzer.py | RecognizerResult carries start/end offsets and matched text context. Propagating these to callers would violate the payload non-leakage contract. Only entity_type and score are forwarded. | `spec` §4.3 + `agent-reasoning` | 2026-03-24 |
| 15 | OpenAPI docs UI disabled in production worker image | Reduces attack surface. docs_url, redoc_url, and openapi_url are set to None. Local environments can re-enable via env var if needed. | `agent-reasoning` + `spec` §4.3 | 2026-03-24 |
| 16 | /tmp mounted as memory-backed emptyDir in Helm chart | Read-only root filesystem is required by security policy but uvicorn and spaCy need writable temporary storage. Memory-backed emptyDir satisfies both constraints without writing to the node's disk. | `spec` §4.3 + `agent-reasoning` | 2026-03-24 |
| 17 | Worker service type set to ClusterIP in production values; NodePort in local values | Worker must not be reachable from outside the cluster in production. Local dev uses NodePort with kind extraPortMappings so services are reachable on fixed localhost ports without port-forwarding. Port-forward approach was replaced because it required manual restart on pod rollover. | `spec` §4.3 + `agent-reasoning` | 2026-03-24 |
| 18 | kind cluster created with extraPortMappings for fixed localhost ports | Avoids kubectl port-forward in local dev. Ports 4444 (Hydra public), 4445 (Hydra admin), 8080 (worker) are mapped via kind containerPort→hostPort. ory/hydra chart does not support nodePort field — Hydra services are patched post-deploy in setup-local.sh. | `agent-reasoning` | 2026-03-24 |
| 20 | MCP server uses the MCP Python SDK (`mcp`/`fastmcp`) not plain FastAPI | Full MCP protocol compliance from Phase 0. SDK handles tool registration, protocol framing, and message serialization. JWT middleware mounted on top of the SDK's FastAPI integration. | `user` | 2026-03-24 |
| 21 | MCP server exposed on port 8000 (NodePort 30800) | Port 4444/4445/8080 already allocated. 8000 is the FastAPI/uvicorn convention and avoids conflict. kind-config.yaml and setup-local.sh updated. Cluster must be recreated to pick up the new extraPortMapping. | `user` | 2026-03-24 |
| 22 | MCP server `/health` endpoint requires no auth | Kubernetes liveness/readiness probes cannot present Bearer tokens. Auth spec `tools:health.read` scope is a known deviation, documented as accepted for Phase 0. | `user` | 2026-03-24 |
| 23 | Worker NodePort remains accessible in local dev after MCP server is deployed | Preserves demo.sh and direct debugging capability. Production topology uses ClusterIP so worker is unreachable externally regardless. | `user` | 2026-03-24 |
| 19 | DATE_TIME mapped to direct_identifier (high severity) is too broad for MVP | Observed in Phase 0 demo: benign date references ("next month", "quarterly") trigger high severity and block. DATE_TIME alone without other context should not reach high severity. Severity mapping for DATE_TIME to be revisited in Phase 1 classification calibration once empirical data from real payloads is available. | `agent-reasoning` + `empirical` | 2026-03-24 |

---

## Errors Encountered
| Error | Attempt # | Resolution |
|-------|-----------|------------|
| Helm ConfigMap rendered `maxPayloadBytes` as `1.048576e+06` (scientific notation) causing worker startup failure | 1 | Added `int` filter to configmap.yaml template: `{{ .Values.config.maxPayloadBytes \| int \| quote }}` |
| `presidio_analyzer.__version__` does not exist — ImportError on worker startup | 1 | Replaced with `importlib.metadata.version('presidio-analyzer')` in minimizer.py |

---

## Open Questions
All Stage 1 questions resolved. See ways-of-working.md §9.
