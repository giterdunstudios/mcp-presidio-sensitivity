# Engineering Spec: OpenTelemetry Distributed Tracing

**Status:** `ready-for-implementation`
**Stream:** Phase 1 — Stream 4 (Observability), before Prometheus metrics
**Depends on:** structured-logging-spec.md (service fields must be in place)
**Feeds into:** audit-trail-spec.md (audit records carry `trace_id` from OTel span)
**Last updated:** 2026-03-24

---

## Goal

Instrument both services with OpenTelemetry so that a single client request — from JWT
validation through MCP tool dispatch to Presidio analysis — produces one distributed trace
spanning both services. The trace is exported to Jaeger. The active `trace_id` surfaces in
structured log records and audit trail entries, enabling log/trace correlation from Grafana.

---

## Decisions

| Concern | Decision | Rationale |
|---|---|---|
| Collector | Jaeger (in-cluster, Helm) | Self-hosted, Kubernetes-native, well-supported OTel backend |
| Propagation format | W3C TraceContext (`traceparent` header) | IETF standard; supported by all OTel SDKs and Jaeger without configuration |
| Cross-service propagation | Header injection in `call_worker()`, header extraction in worker | More maintainable than body-field correlation; decouples transport from schema |
| HTTP instrumentation | Auto (`opentelemetry-instrumentation-fastapi`, `opentelemetry-instrumentation-httpx`) | Covers all HTTP spans with zero per-route code |
| Scan lifecycle instrumentation | One manual span around `engine.analyze()` in the worker | Enables Presidio CPU time isolation and scan business attribute attachment |
| Grafana integration | Jaeger data source plugin; Prometheus exemplars for trace/metric correlation | Single observability UI; no additional tooling |
| `trace_id` in logs | Extracted from active OTel span at log emission time via `logging.Filter` | Connects log lines to traces without manual threading |

---

## Trace Structure

A successful classify call produces this span tree:

```
[MCP server — POST /mcp]                           ← auto (fastapi instrumentation)
  │  trace_id: abc123
  │  span attrs: http.method, http.route, http.status_code
  │
  └── [MCP server — call_worker HTTP POST /scan]    ← auto (httpx instrumentation)
        span attrs: http.url, http.status_code
        outbound header: traceparent: 00-abc123-spanB-01
        │
        └── [Worker — POST /scan]                   ← auto (fastapi instrumentation)
              │  trace_id: abc123  (continued — same trace)
              │  span attrs: http.method, http.route, http.status_code
              │
              └── [Worker — presidio.analyze]       ← MANUAL span
                    span name: "presidio.analyze"
                    span attrs:
                      scan.id = "9a3427e6..."
                      scan.decision = "block"
                      scan.severity = "high"
                      scan.findings_count = 3
                      scan.entity_types = "CREDIT_CARD,US_SSN"   ← comma-joined, no text
                      scan.language = "en"
                      scan.policy_profile = "default"
```

Auth-denied requests produce a single span on the MCP server with `http.status_code=401`
or `403`. No worker span exists (worker is never called).

---

## Sensitivity Constraints on Spans

The same sensitivity policy from `structured-logging-spec.md` applies to span attributes:

**PROHIBITED on any span attribute:**
- `content`, `text`, entity text, entity offsets (`start`, `end`)
- Any fragment reconstructable from the payload

**PERMITTED:**
- `scan.id` — opaque UUID
- `scan.decision` — bounded enum
- `scan.severity` — bounded enum
- `scan.findings_count` — integer count
- `scan.entity_types` — comma-joined entity class names only (e.g., `"CREDIT_CARD,PERSON"`)
- `scan.language`, `scan.policy_profile`, `scan.detector_version`

---

## `trace_id` in Structured Logs

Once OTel is instrumented, every log record must carry the `trace_id` from the active span
so that Grafana can jump from a log line to the corresponding Jaeger trace.

Mechanism: a `logging.Filter` subclass (`_OtelTraceFilter`) queries
`opentelemetry.trace.get_current_span()` at log emission time and injects
`trace_id` and `span_id` into the `LogRecord`. The `JsonFormatter` in
`observability/logging.py` already surfaces these as top-level fields.

```python
class _OtelTraceFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        span = opentelemetry.trace.get_current_span()
        ctx = span.get_span_context()
        if ctx.is_valid:
            record.trace_id = format(ctx.trace_id, "032x")
            record.span_id  = format(ctx.span_id, "016x")
        return True
```

This filter is added to the handler in `configure_logging()` after the
`_ServiceContextFilter`. If no active span exists (startup, health probe), the fields
are absent from the record — the formatter skips absent extras gracefully.

---

## Implementation Plan

### Dependencies to add

**`src/worker/requirements.txt`**
```
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-httpx
```

**`src/mcp_server/requirements.txt`**
```
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-httpx
```

After adding, regenerate both `requirements.lock.txt` files via `pip-compile`.

---

### New shared module pattern

Both services get the same module structure. No cross-service import — they are independent
deployments. The pattern is replicated, not shared.

**`src/mcp_server/observability/tracing.py`** (new)
**`src/worker/observability/tracing.py`** (new)

Each contains:

```python
def configure_tracing(
    service_name: str,
    service_version: str,
    environment: str,
    otlp_endpoint: str,          # e.g. "http://jaeger.mcp-presidio.svc.cluster.local:4317"
    enabled: bool = True,
) -> None:
    """
    Initialise the OTel TracerProvider and wire OTLP gRPC exporter.

    Call once at application startup, before the first request is served.
    If enabled=False (local dev with OTEL_ENABLED=false), installs a NoOp
    TracerProvider so instrumented code works unchanged with zero overhead.
    """
```

The function:
1. Builds a `Resource` with `service.name`, `service.version`, `deployment.environment`
2. Creates an `OTLPSpanExporter` pointing at `otlp_endpoint` (gRPC port 4317)
3. Wraps in `BatchSpanProcessor`
4. Sets as global `TracerProvider`
5. If `enabled=False`: sets `NoOpTracerProvider`

---

### MCP server changes

**`src/mcp_server/config.py`**
- Add `OTEL_ENABLED: bool` — env var `OTEL_ENABLED`, default `True`
- Add `OTLP_ENDPOINT: str` — env var `OTLP_ENDPOINT`, default `"http://jaeger-collector.mcp-presidio.svc.cluster.local:4317"`

**`src/mcp_server/observability/logging.py`**
- Add `_OtelTraceFilter` class (see above)
- Add it to the handler in `configure_logging()`, after `_ServiceContextFilter`
- Requires `opentelemetry-api` import (lightweight — no SDK needed in this file)

**`src/mcp_server/main.py`**
- Import `configure_tracing` from `observability.tracing`
- Call `configure_tracing(...)` in `lifespan()` before `mcp._session_manager.run()`
- Call `FastAPIInstrumentor().instrument_app(app)` after `app` is constructed
- Call `HTTPXClientInstrumentor().instrument()` once at module level

**`src/mcp_server/backend/worker_client.py`**
- No change required — `opentelemetry-instrumentation-httpx` auto-injects `traceparent`
  on all outbound HTTPX requests once `HTTPXClientInstrumentor().instrument()` is called.
- Remove manual `workflow_id`-as-correlation-id passing if fully superseded by trace header;
  retain `workflow_id` in request body for audit trail (it is a caller-supplied ID, separate
  from the OTel trace ID).

---

### Worker changes

**`src/worker/config.py`**
- Add `OTEL_ENABLED: bool` — env var `OTEL_ENABLED`, default `True`
- Add `OTLP_ENDPOINT: str` — env var `OTLP_ENDPOINT`, default `"http://jaeger-collector.mcp-presidio.svc.cluster.local:4317"`

**`src/worker/observability/logging.py`**
- Add `_OtelTraceFilter` — identical to MCP server version

**`src/worker/observability/tracing.py`** (new)
- `configure_tracing()` as described above

**`src/worker/main.py`**
- Call `configure_tracing(...)` in `startup_event()`
- Call `FastAPIInstrumentor().instrument_app(app)` after `app` is constructed
- Add manual span around `engine.analyze()`:

```python
from opentelemetry import trace as otel_trace

tracer = otel_trace.get_tracer("presidio-worker")

# inside scan() handler, replacing the bare engine.analyze() call:
with tracer.start_as_current_span("presidio.analyze") as span:
    findings = engine.analyze(
        text=scan_request.content,
        language=scan_request.language or config.DEFAULT_LANGUAGE,
    )
    # span attributes set after analysis — findings contains counts, not text
    span.set_attribute("scan.id", str(scan_id))
    span.set_attribute("scan.language", scan_request.language or config.DEFAULT_LANGUAGE)
    span.set_attribute("scan.policy_profile", config.POLICY_PROFILE)
```

Scan business attributes (`decision`, `findings_count`, `entity_types`) are set on
the same span *after* `minimize()` runs — they are not available during `engine.analyze()`.
Add a `span` reference held across the minimization step for this purpose, or open the
span to wrap both `engine.analyze()` and `minimize()`.

---

### Jaeger deployment

Jaeger is deployed as a **standalone K8s manifest** in `infrastructure/jaeger.yaml` —
not as a Helm subchart or chart dependency. This minimises complexity: no chart values
schema to manage, no subchart versioning, no Helm release for a dev-only component.

**`infrastructure/jaeger.yaml`** (new file)

Contains two K8s resources in a single file:
1. `Deployment` — `jaeger-all-in-one` image; single replica; no persistence
2. `Service` — ClusterIP exposing:
   - port 4317 (OTLP gRPC inbound from MCP server and worker)
   - port 16686 (Jaeger UI — access via `kubectl port-forward`)

`jaeger-all-in-one` is sufficient for local/dev:
- Single pod: collector + query + UI
- No persistence (traces lost on restart — acceptable for dev/local)
- No external dependencies

**`scripts/setup-local.sh`** — add Jaeger apply step:
```bash
kubectl apply -f "$PROJECT_ROOT/infrastructure/jaeger.yaml"
kubectl rollout status deployment/jaeger -n mcp-presidio --timeout=60s
```

Access UI locally:
```bash
kubectl port-forward svc/jaeger 16686:16686 -n mcp-presidio
# then open http://localhost:16686
```

**`helm/mcp-server/values.yaml`** and **`helm/presidio-worker/values.yaml`**
- Add:
  ```yaml
  otel:
    enabled: true
    otlpEndpoint: "http://jaeger-collector.mcp-presidio.svc.cluster.local:4317"
  ```

**`helm/mcp-server/values.local.yaml`** and **`helm/presidio-worker/values.local.yaml`**
- Override can remain identical for local — Jaeger runs in the same namespace.

**`helm/mcp-server/templates/deployment.yaml`** and worker equivalent:
- Add env vars:
  ```yaml
  - name: OTEL_ENABLED
    value: {{ .Values.otel.enabled | quote }}
  - name: OTLP_ENDPOINT
    value: {{ .Values.otel.otlpEndpoint }}
  ```

**`scripts/setup-local.sh`**
- Add Jaeger deployment step before MCP server and worker are deployed
- Add Jaeger pod readiness check (wait for port 16686 to serve)
- Add Jaeger UI URL to end-of-script summary output

---

## Relationship to Audit Trail (Stream 2)

The audit trail spec (`planning/audit-trail-spec.md`) must be written after this spec is
implemented, or at least after the `trace_id` mechanism is confirmed working. The audit
record schema includes `trace_id` as a mandatory field — it is extracted from the active
OTel span at the moment the audit record is written (same `_OtelTraceFilter` mechanism).

If audit trail is implemented before OTel tracing is live, `trace_id` in the audit record
falls back to `correlation_id` (the existing UUID). The field name stays the same; the value
is a real trace ID once OTel is active.

---

## Acceptance Criteria

1. A POST to `classify_payload_sensitivity` produces a trace visible in the Jaeger UI with
   spans from both the MCP server and the worker under the same `trace_id`.
2. The `presidio.analyze` span is present under the worker's POST /scan span.
3. `presidio.analyze` span attributes include `scan.id`, `scan.decision`,
   `scan.findings_count`, `scan.entity_types`. No payload text present.
4. Auth-denied requests (401/403) produce a single MCP server span with the correct
   HTTP status code. No worker span exists.
5. Structured log records from both services include `trace_id` matching the Jaeger trace
   for that request.
6. With `OTEL_ENABLED=false`, both services start and serve requests normally with no
   OTel-related errors.
7. Jaeger UI is accessible via `kubectl port-forward` in the local cluster.
8. From Grafana, the Jaeger data source returns traces when queried by `service.name`.

---

## Out of Scope (this spec)

- Log shipping to Loki — infrastructure concern, separate from instrumentation.
- OTel metrics export (OTLP metrics) — Prometheus pull model used instead (Stream 4).
- Baggage propagation — not needed at MVP; revisit if per-request policy context is needed.
- Sampling configuration — default is 100% (AlwaysOnSampler); tune in Phase 2 under load.
