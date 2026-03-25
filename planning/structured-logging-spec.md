# Engineering Spec: Structured Logging

**Status:** `ready-for-implementation`
**Stream:** Phase 1 — Stream 4 (Observability), prerequisite to Prometheus metrics
**Author:** Engineering
**Last updated:** 2026-03-24

---

## Problem Statement

The two services have divergent logging implementations:

- **MCP server** has a dedicated `observability/logging.py` module with a `JsonFormatter`,
  a `log_request` helper, and a `configure_logging` entry-point. Its shape is close to right
  but has two gaps: auth-denial events are logged at `INFO` (they should be `WARNING`), and
  there are no service-identity fields in every record.

- **Worker** has an inline `_JsonFormatter` class defined in `main.py`, no shared module,
  and no service-identity fields. The formatter is less capable than the MCP server's version
  and will drift further over time without a shared foundation.

Neither service follows a named industry convention. Log aggregators (Loki, CloudWatch, etc.)
cannot reliably query across both services with consistent field names.

---

## Design Principles

### 1. Convention: OpenTelemetry Log Data Model (flattened)

Align field names to the [OpenTelemetry log data model](https://opentelemetry.io/docs/specs/otel/logs/data-model/)
and [semantic conventions](https://opentelemetry.io/docs/specs/semconv/). Because we write
to stdout (not an OTel collector), we flatten the resource/scope/body hierarchy into a single
JSON object — this is standard practice for Kubernetes workloads targeting Loki or similar.

OTel field mappings used in this spec:

| OTel concept                  | JSON field in our output   |
|-------------------------------|----------------------------|
| `Resource["service.name"]`    | `service_name`             |
| `Resource["service.version"]` | `service_version`          |
| `Resource["deployment.environment"]` | `environment`       |
| `SeverityText`                | `level`                    |
| `Timestamp`                   | `timestamp`                |
| `Body`                        | `message`                  |
| `TraceId`                     | `trace_id`                 |
| `SpanId`                      | `span_id`                  |
| `Attributes["*"]`             | top-level fields           |

`trace_id` carries the request `correlation_id` until full OpenTelemetry instrumentation
is added in a later stream. `span_id` is omitted until then (not emitted, not an empty string).

### 2. Log Level Policy

| Level     | When to use                                                             |
|-----------|-------------------------------------------------------------------------|
| `DEBUG`   | Verbose internals. Suppressed in production. Gated by `LOG_LEVEL=DEBUG` env var. Never emitted by current code — reserved for future deep inspection. |
| `INFO`    | Normal operation: startup complete, scan completed (any decision), request allowed, health probe serving. |
| `WARNING` | Expected anomalies that require attention: auth denied (401/403), request rejected for protocol reasons (413/415/400), scan engine called with a recognised bad input. |
| `ERROR`   | Unexpected failures: analysis engine crash, worker unreachable, startup unable to warm Presidio, JWKS fetch failure. Service is degraded. |
| `CRITICAL`| Service cannot operate at all. Not used in current code — reserved. |

Key level decisions:
- `block` is a legitimate scan outcome. It is logged at `INFO`, not `WARNING`.
- 401/403 are auth enforcements. They are `WARNING` because they indicate a caller misconfiguration or potential probing.
- 413/415/400 are protocol-level rejections. They are `WARNING` — valid callers should not trigger these.
- `logger.exception()` maps to `ERROR` plus traceback. Used only for engine failures.

### 3. Sensitivity Policy

Fields PROHIBITED from appearing in any log record at any level:

| Prohibited field class            | Examples                                                   | Rationale |
|-----------------------------------|------------------------------------------------------------|-----------|
| Payload content                   | `content`, `text`, `body`, `payload`                       | Primary sensitive data — must never leave the analysis boundary. |
| Entity text / spans               | `entity_text`, `entity_value`, `start`, `end`, `offset`   | Presidio returns character offsets with matched text. Logging these reconstructs payload fragments. |
| Raw request/response bodies       | Any serialised request body or Presidio `RecognizerResult` with text fields | Same as above. |

Fields PERMITTED and defined:

| Field              | Type    | Level gating | Notes |
|--------------------|---------|--------------|-------|
| `scan_id`          | string  | INFO+        | UUID identifying the scan. Safe — opaque identifier. |
| `correlation_id`   | string  | INFO+        | Request correlation UUID. Also surfaces as `trace_id`. |
| `trace_id`         | string  | INFO+        | Alias of `correlation_id` for OTel compat. |
| `caller_subject`   | string  | INFO+        | JWT `sub` claim — UUID from Keycloak, not a human-readable name. |
| `decision`         | string  | INFO+        | Bounded enum: allow / block / flag / error. |
| `max_severity_band`| string  | INFO+        | Bounded enum: low / medium / high / critical. |
| `findings_count`   | int     | INFO+        | Count of findings. Safe — no text. |
| `entity_type`      | string  | INFO+        | Entity class name only (e.g., `CREDIT_CARD`). No text or offset. |
| `policy_profile`   | string  | INFO+        | Profile identifier. |
| `detector_version` | string  | INFO+        | Detector version string. |
| `workflow_id`      | string  | INFO+        | Caller-supplied workflow ID for traceability. |
| `auth_decision`    | string  | WARNING+     | allow / deny-401 / deny-403. |
| `error_code`       | string  | WARNING+     | Machine-readable error code. |
| `duration_ms`      | float   | INFO+        | Request duration. |
| `size_bytes`       | int     | WARNING+     | Payload size — only logged on rejection, not on success. |

---

## Target Log Schema

Every record emitted by either service MUST contain:

```json
{
  "timestamp":       "2026-03-24T21:30:00.123456+00:00",
  "level":           "INFO",
  "service_name":    "presidio-worker",
  "service_version": "0.1.0",
  "environment":     "local",
  "logger":          "presidio-worker",
  "message":         "scan completed",
  "trace_id":        "9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef"
}
```

Event-specific fields are appended at the top level. Example — scan completed:

```json
{
  "timestamp":        "2026-03-24T21:30:00.123456+00:00",
  "level":            "INFO",
  "service_name":     "presidio-worker",
  "service_version":  "0.1.0",
  "environment":      "local",
  "logger":           "presidio-worker",
  "message":          "scan completed",
  "trace_id":         "9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef",
  "scan_id":          "9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef",
  "workflow_id":      "wf-abc123",
  "decision":         "block",
  "max_severity_band":"high",
  "findings_count":   3,
  "policy_profile":   "default",
  "detector_version": "presidio-analyzer==2.2.354"
}
```

Example — auth denial (WARNING):

```json
{
  "timestamp":      "2026-03-24T21:30:00.456789+00:00",
  "level":          "WARNING",
  "service_name":   "mcp-presidio-sensitivity",
  "service_version":"0.1.0",
  "environment":    "local",
  "logger":         "mcp-presidio-sensitivity",
  "message":        "request",
  "trace_id":       "4a9ff585-0965-4579-b35c-2193344746a1",
  "correlation_id": "4a9ff585-0965-4579-b35c-2193344746a1",
  "caller_subject": "anonymous",
  "tool":           "/mcp/mcp",
  "auth_decision":  "deny-401",
  "duration_ms":    1.2
}
```

---

## Implementation Plan

### Files to change

#### MCP server

**`src/mcp_server/config.py`**
- Add `SERVICE_VERSION: str` — env var `SERVICE_VERSION`, default `"0.1.0"`
- Add `ENVIRONMENT: str` — env var `ENVIRONMENT`, default `"production"`

**`src/mcp_server/observability/logging.py`** (existing file — update in place)

1. Add `_ServiceContextFilter(logging.Filter)` class:
   - Constructor accepts `service_name`, `service_version`, `environment`
   - `filter()` injects these plus `trace_id` (set to `""` at filter level; callers set it via `extra=`)
   - Actually: inject static fields only (`service_name`, `service_version`, `environment`);
     `trace_id` comes from caller via `extra={"trace_id": correlation_id}`

2. Update `JsonFormatter.format()`:
   - Emit fixed fields in a defined order: `timestamp`, `level`, `service_name`,
     `service_version`, `environment`, `logger`, `message`, `trace_id` (if present),
     then all remaining non-reserved extras.
   - `service_name`, `service_version`, `environment` come from `record.__dict__`
     (injected by the filter), not from the formatter itself. Formatter is stateless.

3. Update `configure_logging(level, service_name, service_version, environment)`:
   - Accept new params (with defaults from `config` module at call-site, not in this function)
   - Instantiate `_ServiceContextFilter` and attach to the handler
   - Existing guard `if not root.handlers` retained

4. Update `log_request(...)`:
   - Change log level: `logger.warning()` when `auth_decision` starts with `"deny"`;
     `logger.info()` otherwise.
   - Add `trace_id=correlation_id` to the `extra=` dict so it surfaces in the schema
     field order defined above.

**`src/mcp_server/main.py`**
- Update `configure_logging()` call to pass:
  `service_name="mcp-presidio-sensitivity"`, `service_version=config.SERVICE_VERSION`,
  `environment=config.ENVIRONMENT`

---

#### Worker

**`src/worker/config.py`**
- Add `SERVICE_VERSION: str` — env var `SERVICE_VERSION`, default `"0.1.0"`
- Add `ENVIRONMENT: str` — env var `ENVIRONMENT`, default `"production"`

**`src/worker/observability/__init__.py`** (new file)
- Empty — makes `observability` a package.

**`src/worker/observability/logging.py`** (new file)
- Port `JsonFormatter` from MCP server — identical implementation. Single source of truth
  exists only in that it must match schema; both copies are intentionally independent
  (no cross-service import).
- Add `_ServiceContextFilter` — identical interface to MCP server version.
- Add `configure_logging(level, service_name, service_version, environment)` — same signature.
- Add `log_scan` helper:
  ```python
  def log_scan(
      *,
      logger: logging.Logger,
      event: str,           # "scan started" | "scan completed" | "scan rejected" | "scan failed"
      scan_id: str,
      level: int = logging.INFO,
      **kwargs,             # decision, max_severity_band, findings_count, etc.
  ) -> None:
  ```
  Emits a single log record at the given level. No `content` parameter exists on this function.

**`src/worker/main.py`**
- Remove inline `_JsonFormatter` class, `_handler` setup, and manual `logging.root` setup.
- Import: `from observability.logging import configure_logging`
- Replace manual setup with: `configure_logging(service_name="presidio-worker", service_version=config.SERVICE_VERSION, environment=config.ENVIRONMENT)`
- **Migrate `@app.on_event("startup")` to `lifespan`** — `@app.on_event` is deprecated in
  FastAPI. Since this file is being touched for the logging changes anyway, migrate
  Presidio pre-warming to a `lifespan` asynccontextmanager and pass it to the `FastAPI`
  constructor. This is the same pattern already used in the MCP server. Do not leave the
  file with deprecated startup hooks.
- In `scan()`: add `trace_id` to all `extra=` dicts. Source: `scan_request.request_metadata.workflow_id` for `workflow_id`; generate a per-request UUID for `trace_id` if no `workflow_id` is present.

---

### Helm values

Both services need `SERVICE_VERSION` and `ENVIRONMENT` available as env vars in pods.

**`helm/mcp-server/templates/deployment.yaml`** and
**`helm/presidio-worker/templates/deployment.yaml`**:
- Add env vars:
  ```yaml
  - name: SERVICE_VERSION
    value: {{ .Chart.AppVersion }}
  - name: ENVIRONMENT
    value: {{ .Values.environment | default "production" }}
  ```

**`helm/mcp-server/values.yaml`** and **`helm/presidio-worker/values.yaml`**:
- Add `environment: production`

**`helm/mcp-server/values.local.yaml`** and **`helm/presidio-worker/values.local.yaml`**:
- Add `environment: local`

---

## Acceptance Criteria

1. Every log line from both services is valid JSON parseable by `json.loads()`.
2. Every record contains: `timestamp`, `level`, `service_name`, `service_version`,
   `environment`, `logger`, `message`.
3. `timestamp` is ISO 8601 with UTC timezone offset (not a bare `Z` suffix — use
   `datetime.fromtimestamp(..., tz=timezone.utc).isoformat()`).
4. Auth-denial events (`deny-401`, `deny-403`) are emitted at `WARNING`.
5. Request-rejection events (413, 415, 400) are emitted at `WARNING`.
6. Scan-completed events (any decision including `block`) are emitted at `INFO`.
7. Analysis engine failures are emitted at `ERROR`.
8. No log record from either service contains: `content`, `text` (as a key),
   `entity_text`, `start`, `end`, `offset`.
9. `kubectl logs` output for both pods has consistent field ordering across records.
10. `environment` reads `local` in the local cluster (values.local.yaml override applied).

---

## Out of Scope (this spec)

- OpenTelemetry SDK integration (trace propagation, OTLP export) — Phase 1 Stream 4 follow-on.
- `span_id` emission — requires OTel SDK.
- Log shipping / aggregation configuration (Promtail, Loki, etc.) — infrastructure concern.
- Audit trail (dedicated append-only audit log per scan) — Phase 1 Stream 2 separate spec.
- Prometheus metrics — Phase 1 Stream 4 separate spec.
