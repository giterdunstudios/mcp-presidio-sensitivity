# Findings: MCP + Presidio Sensitivity Classification

## Summary
Sensitivity classification service exposed as an MCP tool for agents and services.
Caller is always programmatic — no human invokes directly in production.
Core design principle: MCP server and orchestrator are the trust boundary, not Presidio.
Payloads are never persisted, logged, or returned. Only bounded summary results leave the system.
Stack: Python (Presidio embedded library), MCP server, ephemeral workers, audit store.

---

## Spec Analysis

### What the spec settles
- Component responsibilities and boundaries (§1)
- Tool name and contract: `classify_payload_sensitivity` (§2)
- Input and output schema with field-level definitions (§2.3–2.6)
- Error codes and failure response shape (§2.7)
- Deployment topology — Option B (queued) recommended (§3.3)
- Presidio execution mode — embedded library preferred (§3.4)
- All required security controls for MVP (§4.3)
- Phased backlog and acceptance criteria for all 5 phases (§5)
- Interim classification model as placeholder (§6.3)

### What the spec defers
- Final enterprise classification taxonomy (§6)
- Payload release workflows (Phase 3)
- Multi-language support (Phase 4)
- Structured document handling (Phase 4)
- Tenant-specific recognizers (Phase 4)

### What the spec does not answer (resolved externally)
- Caller identity: **agents and services only** — resolved Session 4

---

## Key Architectural Constraints

- **Presidio is not the security boundary.** The MCP server and orchestration layer enforce trust. Do not delegate trust decisions to Presidio behavior.
- **No payload persistence anywhere** — not in the worker, not in the audit store, not in error logs, not in matched substring output.
- **Worker is ephemeral.** Short TTL, memory limits enforced, no shell or debug tools in production image.
- **Summary-only response contract.** Even if `return_details: true` is set, enriched output requires explicit caller authorization. Default behavior is always summary-only.
- **Failure paths must not leak.** A scan timeout, rejection, or internal error must not expose payload data in any log or response.

---

## Security Model

### Trust boundary
```
[Caller] → [MCP Server / Orchestrator] → [Ephemeral Worker]
                    ↑
            This is the boundary.
            Presidio operates inside it.
```

### What is logged (audit store)
- scan_id
- Request metadata (caller identity, tenant, policy profile)
- Detector version
- Entity counts and categories (no matched substrings)
- Max severity band
- Timestamps
- Error codes

### What is never logged
- Source payload
- Matched substrings or offsets
- Raw Presidio spans

### Required controls for MVP
| Control | Requirement |
|---------|-------------|
| Authentication | Strong authn on MCP endpoint. No anonymous access. |
| Authorization | By tenant, workflow, or tool scope. Separate service identities for orchestrator and worker. |
| Transport | TLS everywhere. No plaintext across network boundaries. |
| Request validation | Strict JSON schema. Content-type allowlist. Max payload size enforced. Reject malformed/oversized early. |
| Payload handling | No raw payload logging. No persistence. No disk writes if avoidable. Memory-backed storage if unavoidable. |
| Worker isolation | Non-root. Restricted network egress. Read-only filesystem. CPU/memory limits. |
| Secrets | Injected at runtime. Never baked into images. Per-environment credentials. |
| Supply chain | Pin worker image versions. Scan images and dependencies. Track Presidio version in audit output. |

---

## Tool Contract Summary

### Tool name
`classify_payload_sensitivity`

### Key input fields
| Field | Required | Default | Notes |
|-------|----------|---------|-------|
| `content` | Yes | — | Raw text. Max size enforced by orchestrator. |
| `content_type` | Yes | — | `text/plain` or `application/json` for MVP |
| `language` | No | `en` | Multilingual expansion is Phase 4 |
| `tenant_policy` | No | `default` | Maps to server-side profile |
| `threshold_profile` | No | `default` | Bounded user configurability later |
| `return_details` | No | `false` | Enriched output requires explicit authorization even if true |

### Key output fields
| Field | Notes |
|-------|-------|
| `scan_id` | Unique. Used for traceability. |
| `sensitivity_detected` | Boolean. Above threshold or not. |
| `max_severity_band` | Temporary: low / medium / high / critical |
| `matched_categories` | High-level groups only. No matched substrings. |
| `decision` | allow / flag / block / review |
| `confidence_summary` | Highest score + findings count. No source data. |
| `detector_version` | Presidio version used. Supports operational traceability. |

---

## Interim Classification Model (Placeholder)

### Severity bands
- low
- medium
- high
- critical

### Grouped categories
- direct_identifier
- financial_identifier
- government_identifier
- contact_data
- secrets_like_data
- regulated_like_data
- internal_business_sensitive

These are operational placeholders. They are not final governance labels.
The full classification taxonomy is deferred until Phase 1 generates empirical detector behavior.

---

## Technology Decisions

| Concern | Decision | Source |
|---------|----------|--------|
| Presidio execution mode | Embedded library (not sidecar) | `spec` §3.4 |
| Worker dispatch | Option B — queued (recommended) | `spec` §3.3 |
| Worker runtime | Short-lived container, TTL bounded, memory-backed storage | `spec` §3.4 |
| Classification taxonomy | Deferred — placeholder model in use | `spec` §6 |
| Caller type | Agents and services only | `user` Session 4 |
| Auth model | OAuth client credentials, JWT bearer assertions. Hydra as AS. | `user` + `auth-spec` §3 |
| Deployment model | Helm from Phase 0. `values.local.yaml` for local overrides. | `user` Session 4 |

## Auth Architecture

The MCP auth engineering spec defines a two-component system:

```
[Agent / Service]
    |
    v (OAuth client credentials — JWT bearer assertion)
[Hydra AS]  ←  issues tokens, hosts JWKS
    |
    v (Bearer token)
[MCP Server]        ← validates token, checks scopes, trust boundary
    |
    v (internal context only — no token passthrough)
[Presidio Scanner]  ← no auth, private network only
```

### Auth spec key rules
- MCP server is the OAuth resource server and trust boundary
- Never pass the upstream bearer token to the Presidio scanner
- Backend (Presidio) must not be reachable from untrusted network paths
- Scope model: narrow per-tool scopes (`tools:classify.submit`, `tools:health.read`)
- Internal context passed to backend: `caller_type`, `subject_id`, `authorized_action`, `correlation_id`

### Auth spec reference
See `shared/private/mcp_auth_engineering_spec.md` for full functional requirements,
component breakdown, acceptance criteria, and test plan.

---

## Open Questions
All Stage 1 questions resolved. See task_plan.md and ways-of-working.md §9.
