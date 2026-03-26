# MCP + Presidio Sensitivity Classification MVP Specification

## 0. Scope adjustment captured

Per direction, the original artifact set has been adjusted:

1. Component diagram
2. API / MCP tool schemas
3. Deployment model
4. Security controls
5. Phased backlog and acceptance criteria
6. Deferred classification policy model and grouping design

The classification policy model is intentionally deferred. For MVP, the system will detect sensitivity indicators and return bounded result metadata without releasing payload contents. Classification grouping logic will be formalized later and is treated as a contained downstream policy concern.

---

## 1. Component diagram

## 1.1 Goal

Provide a front-end entry point through MCP that accepts a payload, invokes a tightly bounded sensitivity scan using an ephemeral Presidio-backed worker, and returns only a minimized result indicating whether sensitivity was identified and at what severity band the request should be treated.

## 1.2 Logical component diagram

```text
[MCP Client]
    |
    |  MCP tool invocation
    v
[MCP Server / Orchestrator]
    - request validation
    - authentication / authorization
    - content-type and size enforcement
    - correlation ID creation
    - policy profile lookup
    - dispatch to scan execution path
    |
    +------------------------------+
    |                              |
    | direct invocation            | queued invocation
    v                              v
[Ephemeral Scan Worker]        [Job Queue]
    - short-lived runtime           |
    - loads Presidio analyzer       v
    - applies approved recognizers [Ephemeral Scan Worker]
    - computes bounded result
    - discards payload
    |
    v
[Result Minimizer]
    - strips payload
    - strips raw spans by default
    - retains summary only
    |
    v
[Audit / Result Store]
    - scan_id
    - request metadata
    - detector version
    - policy profile used
    - entity counts / categories
    - max severity band
    - timestamps
    - no payload persistence
    |
    v
[MCP Server Response]
    - minimized result only
```

## 1.3 Runtime responsibilities

### MCP client
- Invokes the classification tool.
- Does not require direct awareness of Presidio.
- Receives only the summarized result.

### MCP server / orchestrator
- Serves as the control plane and trust boundary.
- Owns request validation, authorization, request shaping, audit correlation, and minimization rules.
- Must not become a long-lived repository of raw payloads.

### Ephemeral scan worker
- Performs the actual analysis.
- Lives only for the execution window or short bounded TTL.
- Loads Presidio and approved recognizers.
- Returns only structured findings needed for decisioning.

### Result minimizer
- Converts raw detector output into a bounded schema.
- Removes raw payload, offsets, excerpts, and matched substrings unless explicitly enabled in a future privileged mode.

### Audit / result store
- Stores only operational and governance metadata.
- Supports traceability, tuning, and incident response without retaining sensitive source content.

## 1.4 Design boundaries

### In scope for MVP
- Text payload scanning
- Sensitivity indication
- Severity band output
- Summary-only return contract
- Ephemeral analysis path
- Request auditing without payload retention

### Out of scope for MVP
- Payload release back to caller
- Automatic anonymization or transformation
- User override workflows
- File/image/native binary inspection unless text extraction exists upstream
- Final enterprise classification taxonomy

---

## 2. API / MCP tool schemas

## 2.1 MCP tool strategy

This capability should be exposed through MCP as a tool rather than a resource.

Reasoning:
- The interaction is execution-oriented.
- The caller submits a payload and receives a computed result.
- The operation is bounded, side-effect-aware, and suitable for audit.

## 2.2 Recommended tool name

`classify_payload_sensitivity`

Alternative internal implementation names may exist, but the externally exposed tool name should remain stable.

## 2.3 Functional contract

### Purpose
Analyze an input payload for sensitivity indicators and return only a summarized classification-oriented result.

### Input schema

```json
{
  "content": "string",
  "content_type": "text/plain",
  "language": "en",
  "tenant_policy": "default",
  "threshold_profile": "default",
  "return_details": false,
  "request_metadata": {
    "source_system": "optional string",
    "workflow_id": "optional string"
  }
}
```

## 2.4 Input field definitions

### `content`
- Required.
- Raw text content to be analyzed.
- Maximum request size must be enforced by the orchestrator.

### `content_type`
- Required.
- Initially allow:
  - `text/plain`
  - `application/json`
- Additional types may be supported later only when a safe extraction path exists.

### `language`
- Optional with default.
- Initial MVP can default to `en`.
- Multilingual expansion can be added later.

### `tenant_policy`
- Optional.
- Identifies which approved recognizer or policy profile set to use.
- In MVP, may default to `default` and map to a server-side profile.

### `threshold_profile`
- Optional.
- Selects sensitivity detection thresholds approved for the tenant or workflow.
- User configurability can be bounded later.

### `return_details`
- Optional.
- Default `false`.
- In MVP, even if `true`, the server should still return only bounded details unless the caller is explicitly authorized for enriched output.

### `request_metadata`
- Optional.
- Non-sensitive routing and audit hints.
- Must be validated and size-limited.

## 2.5 Output schema

```json
{
  "scan_id": "uuid",
  "status": "completed",
  "sensitivity_detected": true,
  "max_severity_band": "high",
  "matched_categories": ["financial_identifier", "direct_identifier"],
  "entity_summary": {
    "CREDIT_CARD": 1,
    "PERSON": 1
  },
  "decision": "block",
  "confidence_summary": {
    "highest_score": 0.93,
    "findings_count": 2
  },
  "policy_profile": "default",
  "detector_version": "presidio-x.y.z",
  "timestamp": "2026-03-24T00:00:00Z"
}
```

## 2.6 Output field definitions

### `scan_id`
- Unique identifier for traceability and audit.

### `status`
- Example values:
  - `completed`
  - `rejected`
  - `failed`

### `sensitivity_detected`
- Boolean summary of whether sensitive indicators were found above the active threshold.

### `max_severity_band`
- Temporary bounded severity result.
- Intended to support workflow gating before full classification policy modeling is complete.

### `matched_categories`
- High-level grouped categories only.
- Should not expose matched substrings.

### `entity_summary`
- Aggregated counts by entity type.
- Optional in stricter deployments.

### `decision`
- Initial bounded outcomes:
  - `allow`
  - `flag`
  - `block`
  - `review`
- For MVP, decisioning can remain conservative.

### `confidence_summary`
- Allows downstream operators to understand whether the result was strong or ambiguous without exposing source data.

### `policy_profile`
- Indicates which approved policy bundle was applied.

### `detector_version`
- Supports operational traceability when tuning recognizers.

### `timestamp`
- Completion timestamp in UTC.

## 2.7 Failure responses

```json
{
  "scan_id": "uuid",
  "status": "rejected",
  "error_code": "PAYLOAD_TOO_LARGE",
  "message": "Request exceeds maximum supported size."
}
```

Suggested error codes:
- `PAYLOAD_TOO_LARGE`
- `UNSUPPORTED_CONTENT_TYPE`
- `INVALID_REQUEST_SCHEMA`
- `UNAUTHORIZED`
- `FORBIDDEN`
- `SCAN_TIMEOUT`
- `SCAN_FAILED`

## 2.8 Internal service interface

The orchestrator may call the worker over one of the following:
- synchronous internal HTTP
- message queue + callback/result channel
- job runner interface

The internal contract may include raw detector output, but the external response contract must remain minimized.

---

## 3. Deployment model

## 3.1 MVP deployment objective

Deploy a bounded, auditable sensitivity scanning service with isolation between the MCP entry point and the Presidio execution path.

## 3.2 Recommended MVP topology

### Option A — direct ephemeral worker invocation
Best for early MVP with lower concurrency.

```text
[MCP Server]
   |
   v
[Ephemeral Worker Runtime]
   |
   v
[Presidio Analyzer]
```

Characteristics:
- Lower complexity
- Easier debugging
- Simpler deployment path
- Less elasticity under burst load

### Option B — queued ephemeral worker invocation
Best when concurrency, retry handling, or workload smoothing matters.

```text
[MCP Server] --> [Queue] --> [Ephemeral Worker] --> [Result Channel / Store]
```

Characteristics:
- Better isolation for spikes
- Easier retry strategy
- More moving parts
- Better fit for future scale

## 3.3 Recommended phased deployment choice

For MVP:
- Use Option A if speed of implementation is the dominant goal.
- Use Option B if ephemeral isolation and operational separation are dominant from day one.

Given the stated direction, Option B is the stronger architectural fit, provided the team accepts the added platform complexity.

## 3.4 Runtime choices

### MCP server
- Containerized service
- Small footprint
- No payload persistence
- Horizontal scaling based on request rate

### Worker runtime
- Short-lived container or job
- TTL bounded
- Memory and CPU limits enforced
- Temporary storage disabled or mounted in memory only

### Presidio execution mode
Two valid patterns:

#### Embedded library mode
- Worker imports Presidio as a Python dependency.
- Fewer network hops.
- Better for per-job isolation.

#### Sidecar/service mode
- Worker communicates with a Presidio REST service.
- Easier to standardize operationally.
- Weaker isolation if the Presidio service becomes long-lived.

For this design, embedded library mode is preferred because it fits the ephemeral worker boundary better.

## 3.5 Environment layout

### Development
- Local MCP server
- Local worker container execution
- Mock or local audit store
- Non-production recognizer set

### Test / integration
- Shared MCP endpoint
- Real ephemeral worker lifecycle
- Test audit store
- Synthetic datasets only

### Production
- Authenticated MCP endpoint
- Ephemeral workers
- Encrypted transport
- Strict audit controls
- Policy and recognizer bundles under change control

## 3.6 Operational controls

- Worker image immutability
- Versioned recognizer bundles
- Versioned policy profiles
- Config injected at runtime through approved secret/config channel
- Metrics for scan rate, latency, failure rate, rejection rate, severity distribution
- Health monitoring on MCP server and worker substrate

## 3.7 Suggested deployment sequence

1. MCP server with stubbed scanner
2. Embedded Presidio worker in a bounded container
3. Result minimization layer
4. Audit metadata store
5. Queue-based worker dispatch if needed
6. Scale, tuning, and warm optimization

---

## 4. Security controls

## 4.1 Security objective

Ensure that submitted payloads are handled only for the minimum time and scope required to derive a summarized sensitivity result, while minimizing persistence, propagation, and exposure.

## 4.2 Core trust assumptions

- Presidio itself is not the security boundary.
- The MCP server and orchestration layer enforce trust controls.
- The worker runtime is treated as high-sensitivity transient compute.
- Auditability must not depend on retaining raw payloads.

## 4.3 Required controls for MVP

### Identity and access
- Strong authentication in front of the MCP endpoint.
- Authorization by tenant, workflow, or tool scope.
- No anonymous access.
- Separate service identities for orchestrator and worker substrate.

### Transport protection
- TLS for all remote transport.
- Internal service-to-service encryption where supported by platform.
- No plaintext transport across network boundaries.

### Request validation
- Strict JSON schema validation.
- Content-type allowlist.
- Maximum payload size.
- Input normalization rules.
- Reject malformed or oversized requests early.

### Payload handling
- No raw payload logging.
- No payload persistence in audit store.
- No matched substring persistence.
- Avoid writing payloads to disk.
- If temporary storage is unavoidable, use memory-backed storage with aggressive cleanup.

### Worker isolation
- Short TTL.
- Non-root runtime where possible.
- Network egress restricted to only required dependencies.
- Read-only filesystem where feasible.
- CPU and memory limits.
- No shell/debug tools in production image unless explicitly justified.

### Secret handling
- Secrets injected at runtime.
- No secrets baked into images.
- Separate credentials per environment.
- Rotation support.

### Audit and observability
- Log request ID, caller identity, tenant, policy profile, latency, result severity band, error codes.
- Do not log source payload.
- Sensitive operational dashboards access-controlled.

### Supply chain
- Pin worker image versions.
- Scan images and dependencies.
- Track Presidio version and recognizer bundle version in audit output.
- Approve custom recognizers through change control.

## 4.4 Abuse and misuse controls

- Rate limiting per caller or tenant.
- Burst controls to prevent denial of service.
- Scan timeout enforcement.
- Queue depth alarms if using asynchronous execution.
- Request deduplication optional for repeated workflow retries.

## 4.5 Data governance posture

For MVP, this system should be treated as a high-sensitivity processing component even though it is not intended to retain payload data.

Governance assumptions:
- It processes potentially sensitive data in memory.
- It can influence downstream allow/block decisions.
- It needs change control for detector logic and thresholds.
- It requires explicit owner accountability.

## 4.6 Security review checklist

Before production release, confirm:
- Authn/authz implemented
- TLS enforced
- Payload logging disabled and tested
- Max size and timeout controls tested
- Worker isolation verified
- Audit schema reviewed
- Recognizer bundle versioning implemented
- Dependency scan clean or risk-accepted
- Failure paths do not leak payload data

---

## 5. Phased backlog and acceptance criteria

## 5.1 Phase 0 — design and proving path

### Objectives
- Validate architecture choice.
- Confirm Presidio fit for target data types.
- Establish minimized output contract.

### Deliverables
- Architectural design
- Tool schema draft
- Minimal worker prototype
- Synthetic test corpus

### Acceptance criteria
- Team can submit synthetic text and receive a bounded result.
- No raw payload is returned in the prototype response.
- Failure paths are understood.

## 5.2 Phase 1 — MVP implementation

### Objectives
- Deliver MCP tool with ephemeral scanning path.
- Return only bounded sensitivity results.
- Capture audit metadata without payload persistence.

### Deliverables
- MCP server
- Ephemeral worker
- Embedded Presidio analyzer
- Result minimizer
- Audit store
- Basic metrics and logs

### Acceptance criteria
- Supported content types are validated and enforced.
- Oversized payloads are rejected.
- Valid payloads produce a `scan_id` and bounded result.
- Raw payload is not logged or stored.
- Worker runtime is ephemeral and bounded.
- Authenticated caller can invoke the tool successfully.
- Unauthorized caller is rejected.

## 5.3 Phase 2 — operational hardening

### Objectives
- Improve reliability, scalability, and governance.
- Reduce ambiguity in operational handling.

### Deliverables
- Queue-based execution if not already present
- Retry strategy
- Rate limiting
- Enhanced monitoring and alerting
- Version-controlled recognizer bundles

### Acceptance criteria
- Service remains stable under expected concurrency.
- Timeouts and retries behave predictably.
- Monitoring identifies failures and abnormal severity spikes.
- Detector and policy bundle versions are traceable.

## 5.4 Phase 3 — controlled release workflows

### Objectives
- Introduce the possibility of returning or forwarding payload content only when below an approved threshold.
- Keep this disabled by default.

### Deliverables
- Configurable release policy gate
- Per-tenant controls
- Additional review and audit rules
- Optional transformation/redaction path

### Acceptance criteria
- Default behavior remains summary-only.
- Release paths require explicit enablement.
- Release actions are logged with policy version and actor context.
- Threshold changes are governed and traceable.

## 5.5 Phase 4 — expanded content and enterprise features

### Objectives
- Extend detection breadth and classification maturity.

### Deliverables
- Additional languages
- Structured document handling
- Tenant-specific recognizers
- Classification model completion
- Review workflows and analyst tooling

### Acceptance criteria
- New content types have validated extraction paths.
- Classification grouping model is approved.
- Expanded detectors meet defined quality thresholds.

---

## 6. Deferred classification policy model and grouping design

## 6.1 Deferral note

This section is intentionally deferred from the MVP core. The system can still operate by returning bounded severity bands and grouped categories without fully formalizing the enterprise classification taxonomy.

## 6.2 Why deferral is appropriate

- Detection capability can be validated before final taxonomy design.
- False-positive and false-negative behavior should inform grouping decisions.
- Business classification often requires stakeholder alignment beyond engineering.
- Premature taxonomy design risks rework.

## 6.3 Interim approach for MVP

Use a temporary bounded model:
- low
- medium
- high
- critical

And a temporary grouped category model:
- direct_identifier
- financial_identifier
- government_identifier
- contact_data
- secrets_like_data
- regulated_like_data
- internal_business_sensitive

These are operational placeholders, not final governance labels.

## 6.4 Inputs needed later to complete the model

- Business classification standards
- Regulatory obligations by tenant or environment
- Internal data handling requirements
- False-positive/false-negative observations from MVP usage
- Downstream workflow decisions required for each level

## 6.5 Future deliverables for this section

When promoted from deferred to active work, this section should include:
- Formal classification taxonomy
- Entity-to-classification mapping rules
- Compound condition escalation rules
- Decision matrix for allow / flag / review / block / release
- Tenant override model
- Governance and approval workflow for threshold changes

## 6.6 Deferred acceptance criteria

This section is complete when:
- Severity bands are replaced or formally ratified
- Grouping categories are approved by data governance stakeholders
- Decision rules are documented and tested
- Threshold change process is defined
- Downstream release conditions are formally governed

---

## Closing implementation guidance

For immediate engineering execution, the recommended build order is:

1. Define MCP tool contract and result schema.
2. Build the MCP server with schema validation and auth hooks.
3. Implement an ephemeral worker with embedded Presidio analysis.
4. Add the result minimizer to guarantee summary-only responses.
5. Add audit storage with no payload persistence.
6. Add monitoring, rate limiting, and operational controls.
7. Revisit and formalize the classification policy model after empirical detector behavior is understood.

This preserves the core design intent while avoiding premature lock-in on taxonomy details.

