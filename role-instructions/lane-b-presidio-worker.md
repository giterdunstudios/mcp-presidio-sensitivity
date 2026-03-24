# Agent Briefing: Lane B — Presidio Worker
**Phase:** 0
**Status:** Ready to start
**Blocked by:** Nothing — start immediately
**Blocks:** MCP Server (Group 2) — Security/Privacy Lead must review before wiring

---

## Your objective

Build the Presidio scanner worker as a containerized Python service with a Helm chart.
The worker accepts a text payload, runs it through Presidio, applies the result minimizer,
and returns only a bounded summary result. The payload must never leave the worker's memory
or appear in any log, response, or error output.

---

## Read before starting

You must read these files before doing any work:

| File | Location |
|------|----------|
| Ways of working | `role-instructions/ways-of-working.md` |
| Task plan | `planning/task_plan.md` |
| Findings | `planning/findings.md` |
| MVP spec | `shared/private/mcp_presidio_mvp_spec.md` |

Pay particular attention to:
- Spec §1.3 — worker runtime responsibilities
- Spec §3.4 — embedded library mode (your implementation pattern)
- Spec §4.3 — required security controls (your non-negotiable constraints)

---

## What you are building

```
[HTTP request: payload + config]
    |
    v
[Worker entrypoint]
    - validate request schema
    - enforce max payload size
    - reject unsupported content types
    |
    v
[Presidio AnalyzerEngine]
    - load approved recognizers only
    - analyze text
    - return raw findings (internal only)
    |
    v
[Result Minimizer]
    - compute entity counts by type
    - compute max severity band
    - assign matched_categories (interim model)
    - assign decision (allow/flag/block/review)
    - strip all raw spans, offsets, matched substrings
    - return bounded result only
    |
    v
[HTTP response: bounded result]
    - no payload
    - no matched substrings
    - no raw Presidio spans
```

---

## Interim classification model

Use these placeholder values until the full taxonomy is formalized (spec §6.3):

### Severity bands
- `low` — 1 low-confidence finding, non-critical category
- `medium` — multiple low-confidence or 1 high-confidence non-critical
- `high` — any direct_identifier, financial_identifier, or government_identifier
- `critical` — credentials, secrets, or multiple high-confidence critical findings

### Grouped categories (map from Presidio entity types)
| Category | Presidio entity types |
|----------|-----------------------|
| `direct_identifier` | PERSON, DATE_TIME, AGE |
| `financial_identifier` | CREDIT_CARD, IBAN_CODE, US_BANK_NUMBER |
| `government_identifier` | US_SSN, US_PASSPORT, US_DRIVER_LICENSE, NRP |
| `contact_data` | EMAIL_ADDRESS, PHONE_NUMBER, IP_ADDRESS, URL |
| `secrets_like_data` | CRYPTO, AWS_ACCESS_KEY (if recognizer available) |
| `regulated_like_data` | MEDICAL_LICENSE, US_ITIN |
| `internal_business_sensitive` | (none mapped at MVP — reserved for future) |

### Decision mapping
| Max severity | Decision |
|-------------|----------|
| `low` | `allow` |
| `medium` | `flag` |
| `high` | `block` |
| `critical` | `block` |
| No findings | `allow` |

---

## Output schema

Your worker must return exactly this shape (from spec §2.5):

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

Failure response shape (from spec §2.7):
```json
{
  "scan_id": "uuid",
  "status": "rejected",
  "error_code": "PAYLOAD_TOO_LARGE",
  "message": "Request exceeds maximum supported size."
}
```

---

## Implementation requirements

### Language and dependencies
- Python 3.11+
- `presidio-analyzer` (embedded library mode — no Presidio REST service)
- `fastapi` + `uvicorn` for the HTTP interface
- `pydantic` for request/response schema validation
- `uuid` for scan IDs

### Max payload size
Enforce 1MB as the default limit. Reject with `PAYLOAD_TOO_LARGE` if exceeded.

### Supported content types for MVP
- `text/plain`
- `application/json`

Reject anything else with `UNSUPPORTED_CONTENT_TYPE`.

### Worker lifecycle
- Stateless — no in-memory state between requests
- No disk writes
- No database
- Payload must not be assigned to any variable that persists beyond the analysis call

---

## File structure

```
src/worker/
  main.py              ← FastAPI app entrypoint
  analyzer.py          ← Presidio AnalyzerEngine wrapper
  minimizer.py         ← Result minimizer — strips spans, produces bounded result
  models.py            ← Pydantic request/response models
  config.py            ← Max size, supported content types, policy profile
  classification.py    ← Entity → category mapping, severity logic, decision mapping
Dockerfile
helm/
  presidio-worker/
    Chart.yaml
    values.yaml
    values.local.yaml
    templates/
      deployment.yaml
      service.yaml
      configmap.yaml
```

---

## Dockerfile requirements

```dockerfile
FROM python:3.11-slim
# Non-root user
# No shell tools (sh is acceptable, bash is not required)
# Read-only filesystem where possible
# CPU and memory limits enforced via Helm, not Dockerfile
```

---

## Helm chart requirements

`values.yaml` must include:
```yaml
resources:
  limits:
    memory: 512Mi
    cpu: 500m
  requests:
    memory: 256Mi
    cpu: 250m

config:
  maxPayloadBytes: 1048576
  defaultLanguage: en
  policyProfile: default
```

---

## Security constraints — non-negotiable

These come directly from spec §4.3 and findings.md. Violations block Security/Privacy Lead sign-off.

| Rule | Implementation requirement |
|------|---------------------------|
| No raw payload logging | Never log `content`, matched substrings, or raw Presidio spans |
| No payload persistence | Do not write payload to disk, database, or any external store |
| No payload in error responses | Error responses contain only error_code and message — never content |
| No payload in matched output | `entity_summary` contains counts only — no matched text |
| Worker is stateless | No in-memory store between requests |
| Non-root runtime | Dockerfile must specify a non-root user |
| Restricted content types | Reject anything not in the allowlist early, before analysis |

---

## Deliverables

| File | Location | Contents |
|------|----------|----------|
| Worker source code | `src/worker/` | All Python files |
| Dockerfile | `src/worker/Dockerfile` | Worker container definition |
| Helm chart | `helm/presidio-worker/` | Full chart with values |
| `worker-design-notes.md` | `deliverables/lane-b/` | Design decisions made, any deviations from spec, recognizer coverage notes |
| `security-checklist.md` | `deliverables/lane-b/` | Self-review against each item in spec §4.6 |

Write all files to disk. **Do not commit or push — the coordinator handles all git operations.**

When all files are written, notify the coordinator by ending your session with a clear summary of:
- All files written and their paths
- All decisions made (for logging to `task_plan.md`)
- Definition of done checklist status
- Any deviations from spec to flag for Security/Privacy Lead review

---

## Definition of done

- [ ] Worker starts and responds to `GET /health`
- [ ] `POST /scan` with a synthetic text payload returns a bounded result
- [ ] No payload content appears in logs, response, or error output (verified manually)
- [ ] Oversized payload returns `PAYLOAD_TOO_LARGE`
- [ ] Unsupported content type returns `UNSUPPORTED_CONTENT_TYPE`
- [ ] Dockerfile uses non-root user
- [ ] Helm chart deploys cleanly to `mcp-presidio` namespace
- [ ] `security-checklist.md` completed and written to disk
- [ ] All decisions noted in your completion summary for the coordinator to log

---

## Handoff

When done, notify the operator and flag for Security/Privacy Lead review.

**Do not proceed to MCP server wiring until the Security/Privacy Lead has reviewed
`security-checklist.md` and the payload handling implementation.**

The MCP server (Group 2) needs the following from your output:
- Worker service name and port inside the cluster
- Exact request and response schema (confirm against spec §2.3–2.5)
- Any deviations from the spec documented in `worker-design-notes.md`
