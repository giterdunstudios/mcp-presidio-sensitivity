# Worker Design Notes — Lane B: Presidio Worker

**Phase:** 0
**Date:** 2026-03-24
**Author:** Lane B agent (Claude Sonnet 4.6)

---

## 1. Implementation pattern

### Embedded library mode
Presidio is imported as a Python library dependency (`presidio-analyzer`) rather
than being invoked via a Presidio REST sidecar.  This matches spec §3.4 and
decision log entry #2.  Benefits:

- Fewer network hops per scan
- Better per-job isolation — no shared Presidio process state across requests
- Payload never crosses a network boundary inside the worker

### Single AnalyzerEngine instance (module-level singleton)
The `AnalyzerEngine` is initialised once at startup and shared across requests.
This is safe because Presidio's AnalyzerEngine does not hold per-request state.
Loading NLP models on every request would be prohibitively slow and was
rejected.

---

## 2. Payload handling design

### Where payload appears
The raw payload text (`content`) is present in exactly two places:
1. `ScanRequest.content` (Pydantic model field, created during schema validation)
2. The `text` argument passed into `AnalyzerEngine.analyze()`

### Where payload must not appear
- Log statements (enforced in `main.py` — log calls never reference `content`)
- Exception messages (try/except blocks catch all exceptions and emit sanitised
  messages only)
- Error responses (all `ErrorResponse` instances contain only `error_code` and
  `message`)
- `findings` list returned by `analyzer.py` (contains only `entity_type` and
  `score` — raw `RecognizerResult` objects are stripped immediately)
- `ScanResponse` (produced by `minimizer.py` from stripped findings — no payload
  data enters this module)

### Explicit del statements
`main.py` uses `del body_bytes` and `del scan_request` to remove references to
payload data as soon as they are no longer required.  Python's garbage collector
is not deterministic, but removing references prevents accidental re-use after
the analysis is complete.

---

## 3. Recognizer coverage

### Approved entity types at MVP

| Entity type | Category |
|-------------|----------|
| PERSON | direct_identifier |
| DATE_TIME | direct_identifier |
| CREDIT_CARD | financial_identifier |
| IBAN_CODE | financial_identifier |
| US_BANK_NUMBER | financial_identifier |
| US_SSN | government_identifier |
| US_PASSPORT | government_identifier |
| US_DRIVER_LICENSE | government_identifier |
| NRP | government_identifier |
| EMAIL_ADDRESS | contact_data |
| PHONE_NUMBER | contact_data |
| IP_ADDRESS | contact_data |
| URL | contact_data |
| CRYPTO | secrets_like_data |
| MEDICAL_LICENSE | regulated_like_data |
| US_ITIN | regulated_like_data |

### Entity types from the briefing not included at MVP

| Entity type | Reason |
|-------------|--------|
| AGE | Not a Presidio built-in recognizer by default; deferred |
| AWS_ACCESS_KEY | Not in Presidio's standard built-in set; deferred |

`AGE` and `AWS_ACCESS_KEY` are listed in the classification model but were
excluded from `APPROVED_ENTITY_TYPES` because they are not part of Presidio's
standard built-in recognizer bundle.  Adding them requires either custom
recognizers or additional Presidio packages.  This is a Phase 1 item.

The category mappings for both are retained in `classification.py` so they take
effect when the recognizers are added without code changes elsewhere.

---

## 4. Severity band logic

The severity band is computed in `classification.py::compute_severity_band()`.
The logic follows the spec directly:

- `critical` — any finding in `secrets_like_data`
- `high` — any finding in `direct_identifier`, `financial_identifier`, or
  `government_identifier`
- `medium` — multiple low-confidence findings OR 1 high-confidence non-critical
  finding (threshold: score >= 0.75)
- `low` — exactly 1 low-confidence finding in a non-critical category
- `None` (no findings) → decision: `allow`

---

## 5. Deviations from spec

| Item | Spec | Implementation | Reason |
|------|------|----------------|--------|
| AGE entity type | Listed in briefing category map | Not enabled | Not a Presidio built-in; requires custom recognizer |
| AWS_ACCESS_KEY entity type | Listed in briefing category map | Not enabled | Not in standard Presidio built-in set |
| `return_details` field | Optional — enriched output requires explicit authorization | Always returns bounded result; field accepted but ignored | MVP does not implement enriched output path |
| OpenAPI docs UI | No spec requirement | Disabled (docs_url=None, redoc_url=None) | Reduces attack surface in production |

---

## 6. Service name and port for MCP server wiring

The MCP server (Group 2 / Lane A) should address the worker using:

```
Service name:  presidio-worker  (Helm release name + chart name)
Namespace:     mcp-presidio
Port:          8080
Internal URL:  http://presidio-worker.mcp-presidio.svc.cluster.local:8080
```

Endpoints:
- `GET  /health` — liveness probe, returns `{"status": "ok"}`
- `POST /scan`   — scan endpoint, accepts `application/json` body conforming
  to the input schema (spec §2.3)

---

## 7. Request schema (internal worker interface)

The worker's `/scan` endpoint accepts the same input schema as the MCP tool
contract (spec §2.3):

```json
{
  "content": "string (required)",
  "content_type": "text/plain | application/json (required)",
  "language": "en (optional, default: en)",
  "tenant_policy": "default (optional)",
  "threshold_profile": "default (optional)",
  "return_details": false,
  "request_metadata": {
    "source_system": "optional string",
    "workflow_id": "optional string"
  }
}
```

The `Content-Type` HTTP header must also be set to `application/json` for the
request body (the `content_type` field in the body refers to the type of the
scanned content, not the request body itself).

---

## 8. Open items for Phase 1

- Add AGE and AWS_ACCESS_KEY recognizers (custom or via extended Presidio packages)
- Add structured `extra` fields to all log records for centralised log ingestion
- Pin exact dependency versions after integration testing resolves version
  constraints (currently using ranges)
- Add a network policy manifest to the Helm chart to restrict worker egress
- Implement scan timeout enforcement (currently relies on uvicorn worker timeout)
