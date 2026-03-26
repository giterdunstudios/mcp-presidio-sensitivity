# Engineering Spec: Prometheus Metrics & Grafana Dashboard

**Status:** `ready-for-implementation`
**Stream:** Phase 1 — Stream 4 (Observability), follows OTel tracing (A3)
**Depends on:** otel-spec.md (tracing must be instrumented; trace exemplars require active spans)
**Feeds into:** A4I implementation task
**Last updated:** 2026-03-25

---

## Goal

Expose application-level Prometheus metrics from both services so that a single
Grafana dashboard answers the operational questions: Is the system healthy? Are scans
succeeding? Are auth boundaries holding? How long do scans take?

Jaeger (A3) answers "what happened in this request". Prometheus answers "what is
happening across all requests". This spec covers the metrics schema, the `/metrics`
endpoint, the Prometheus + Grafana deployment, and the dashboard layout.

---

## Decisions

| Concern | Decision | Rationale |
|---|---|---|
| Metrics library | `prometheus-client` (official Python client) | Standard, no OTel metrics SDK coupling; pull model matches Prometheus natively |
| Exposition | `/metrics` endpoint on each service (Prometheus scrape target) | Standard Prometheus pull pattern; no collector/agent needed |
| Auth on `/metrics` | Exempt (no JWT required) | Same policy as `/health`; endpoint is cluster-internal only (ClusterIP service) |
| Prometheus deployment | Standalone K8s manifest (`infrastructure/prometheus.yaml`) | Same pattern as Jaeger — dev-only, no operator, no Helm subchart |
| Grafana deployment | Standalone K8s manifest (`infrastructure/grafana.yaml`) | Pre-provisioned data sources (Prometheus + Jaeger); no manual config |
| Dashboard provisioning | ConfigMap with Grafana JSON model | Dashboard loads at startup; no UI clicks required; version-controlled |
| Metric naming | `mcp_` prefix (MCP server), `worker_` prefix (Presidio worker) | OTel semantic conventions use dots; Prometheus convention uses underscores. These are Prometheus-native metrics, not OTel-exported, so underscore prefix is correct |
| Histogram buckets | Default Prometheus buckets for latency; custom for payload size | Default covers 5ms–10s which fits scan latency profile |
| Phase 2 boundary | Network-level metrics (request rate, TCP, mTLS) move to Istio/Envoy | App metrics here are business-level; Istio RED metrics are infrastructure-level — complementary, not overlapping |

---

## Metrics Schema — MCP Server

All metrics are registered in a new module `src/mcp_server/observability/metrics.py`.

### Counters

| Metric | Type | Labels | Description |
|---|---|---|---|
| `mcp_auth_decisions_total` | Counter | `outcome` | Auth middleware decisions. Label values: `allow`, `deny_401`, `deny_403`, `exempt` |
| `mcp_scan_completions_total` | Counter | `decision`, `max_severity_band` | Successful scan completions. `decision`: `allow` / `block` / `flag`. `max_severity_band`: `none` / `low` / `medium` / `high` / `critical` |
| `mcp_scan_errors_total` | Counter | `error_code` | Worker call failures. `error_code`: `SCAN_TIMEOUT` / `SCAN_FAILED` / `PAYLOAD_TOO_LARGE` / `UNSUPPORTED_CONTENT_TYPE` / `INVALID_REQUEST` |

### Histograms

| Metric | Type | Labels | Buckets | Description |
|---|---|---|---|---|
| `mcp_request_duration_seconds` | Histogram | `path`, `status_code` | default | Full request duration (middleware entry to response) |
| `mcp_worker_call_duration_seconds` | Histogram | — | default | HTTP call to worker (httpx round-trip) |

### Info / Gauge

| Metric | Type | Labels | Description |
|---|---|---|---|
| `mcp_build_info` | Info | `version`, `environment` | Static service identity; set once at startup |

---

## Metrics Schema — Presidio Worker

All metrics are registered in `src/worker/observability/metrics.py`.

### Counters

| Metric | Type | Labels | Description |
|---|---|---|---|
| `worker_scan_completions_total` | Counter | `decision`, `max_severity_band` | Scans that completed analysis successfully |
| `worker_scan_rejections_total` | Counter | `error_code` | Pre-analysis guard rejections. `error_code`: `PAYLOAD_TOO_LARGE` / `UNSUPPORTED_CONTENT_TYPE` / `INVALID_REQUEST_SCHEMA` |
| `worker_scan_failures_total` | Counter | — | Analysis engine errors (catch-all for `engine.analyze()` exceptions) |

### Histograms

| Metric | Type | Labels | Buckets | Description |
|---|---|---|---|---|
| `worker_scan_duration_seconds` | Histogram | — | default | Total scan handler time (guard checks + analysis + minimization) |
| `worker_presidio_analyze_duration_seconds` | Histogram | — | default | Presidio `engine.analyze()` call only — isolates NLP model time |
| `worker_findings_per_scan` | Histogram | — | `[0, 1, 2, 3, 5, 8, 13, 21, 50]` | Distribution of findings count per scan |

### Info / Gauge

| Metric | Type | Labels | Description |
|---|---|---|---|
| `worker_build_info` | Info | `version`, `environment` | Static service identity; set once at startup |

---

## Sensitivity Constraints on Metrics

The same sensitivity policy from `structured-logging-spec.md` and `otel-spec.md`
applies to metric labels:

**PROHIBITED as a metric label value:**
- Payload content, entity text, matched substrings, offsets
- `caller_subject` (PII risk at high cardinality — use audit trail for per-caller queries)
- `scan_id`, `correlation_id` (high cardinality → Prometheus label explosion)

**PERMITTED:**
- `decision` — bounded enum (`allow`, `block`, `flag`)
- `max_severity_band` — bounded enum (`none`, `low`, `medium`, `high`, `critical`)
- `error_code` — bounded enum (6 values)
- `outcome` — bounded enum (4 values)
- `path` — bounded to known routes (`/mcp`, `/health`, `/.well-known/oauth-protected-resource`)
- `status_code` — bounded HTTP status codes
- `version`, `environment` — static

---

## `/metrics` Endpoint Integration

Both services expose `/metrics` via `prometheus_client.make_asgi_app()` mounted on
the FastAPI application. The endpoint is added to the JWT middleware exempt paths.

**MCP server — `main.py`:**
```python
from prometheus_client import make_asgi_app as prometheus_app

# Mount before the MCP catch-all mount
metrics_app = prometheus_app()
app.mount("/metrics", metrics_app)
```

Add `/metrics` to `JWTAuthMiddleware.EXEMPT_PATHS`.

**Worker — `main.py`:**
```python
from prometheus_client import make_asgi_app as prometheus_app

metrics_app = prometheus_app()
app.mount("/metrics", metrics_app)
```

No auth change needed (worker has no auth middleware).

---

## Instrumentation Points

### MCP server

| Location | Metric(s) | Notes |
|---|---|---|
| `JWTAuthMiddleware.dispatch` — exempt path early return | `mcp_auth_decisions_total{outcome="exempt"}` | Before `call_next` |
| `JWTAuthMiddleware.dispatch` — 401 return | `mcp_auth_decisions_total{outcome="deny_401"}` | After `TokenMissingError` / `TokenInvalidError` |
| `JWTAuthMiddleware.dispatch` — 403 return | `mcp_auth_decisions_total{outcome="deny_403"}` | After `is_authorized` fails |
| `JWTAuthMiddleware.dispatch` — allow, after `call_next` | `mcp_auth_decisions_total{outcome="allow"}`, `mcp_request_duration_seconds` | At response time |
| `classify_payload_sensitivity` — success path | `mcp_scan_completions_total{decision, max_severity_band}` | After `call_worker` returns |
| `classify_payload_sensitivity` — `WorkerError` path | `mcp_scan_errors_total{error_code}` | In `except WorkerError` |
| `call_worker` — around `client.post()` | `mcp_worker_call_duration_seconds` | Timer wrapping the httpx call |

### Worker

| Location | Metric(s) | Notes |
|---|---|---|
| `scan()` — top-level timer | `worker_scan_duration_seconds` | Wraps entire handler |
| `_scan_inner()` — guard rejections (413, 415, 400) | `worker_scan_rejections_total{error_code}` | One inc per guard branch |
| `_scan_inner()` — around `engine.analyze()` | `worker_presidio_analyze_duration_seconds` | Timer wrapping just the analyze call |
| `_scan_inner()` — analysis exception | `worker_scan_failures_total` | In `except Exception` after analyze |
| `_scan_inner()` — after `minimize()` | `worker_scan_completions_total{decision, max_severity_band}`, `worker_findings_per_scan` | After result is ready |

---

## Prometheus Deployment

Prometheus runs as a standalone single-replica deployment in the `mcp-presidio`
namespace. Same pattern as Jaeger — a dev-only K8s manifest, not a Helm chart.

**`infrastructure/prometheus.yaml`** (new file)

Contains three K8s resources:
1. **ConfigMap** — `prometheus-config` with `prometheus.yml` scrape config
2. **Deployment** — `prom/prometheus:v2.53.0` (latest LTS); single replica; no persistence
3. **Service** — ClusterIP on port 9090

Scrape config:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "mcp-server"
    static_configs:
      - targets: ["mcp-presidio-sensitivity.mcp-presidio.svc.cluster.local:8000"]
    metrics_path: /metrics

  - job_name: "presidio-worker"
    static_configs:
      - targets: ["presidio-worker.mcp-presidio.svc.cluster.local:8080"]
    metrics_path: /metrics
```

Access locally:
```bash
kubectl port-forward svc/prometheus 9090:9090 -n mcp-presidio
# then open http://localhost:9090
```

---

## Grafana Deployment

Grafana runs as a standalone single-replica deployment with pre-provisioned data
sources and a dashboard loaded from a ConfigMap.

**`infrastructure/grafana.yaml`** (new file)

Contains four K8s resources:
1. **ConfigMap** — `grafana-datasources` with Prometheus + Jaeger data source provisioning
2. **ConfigMap** — `grafana-dashboards-provider` with dashboard provider config
3. **ConfigMap** — `grafana-dashboard-mcp` with the JSON dashboard model
4. **Deployment** — `grafana/grafana:11.1.0`; single replica; anonymous auth enabled (dev-only)
5. **Service** — ClusterIP on port 3000

Data source provisioning (`datasources.yaml`):

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.mcp-presidio.svc.cluster.local:9090
    isDefault: true

  - name: Jaeger
    type: jaeger
    access: proxy
    url: http://jaeger.mcp-presidio.svc.cluster.local:16686
```

Access locally:
```bash
kubectl port-forward svc/grafana 3000:3000 -n mcp-presidio
# then open http://localhost:3000
```

---

## Dashboard Layout

Dashboard title: **MCP Presidio Sensitivity — Operations**

### Row 1 — Golden Signals (4 panels)

| Panel | Type | Query | Description |
|---|---|---|---|
| Scan Rate | Stat + sparkline | `sum(rate(mcp_scan_completions_total[5m]))` | Scans per second (last 5 min) |
| Error Rate | Stat (red threshold) | `sum(rate(mcp_scan_errors_total[5m])) / (sum(rate(mcp_scan_completions_total[5m])) + sum(rate(mcp_scan_errors_total[5m])))` | Error fraction; threshold: >5% = red |
| P95 End-to-End Latency | Stat | `histogram_quantile(0.95, sum(rate(mcp_request_duration_seconds_bucket{path="/mcp"}[5m])) by (le))` | 95th percentile request duration |
| P95 Presidio Analyze | Stat | `histogram_quantile(0.95, sum(rate(worker_presidio_analyze_duration_seconds_bucket[5m])) by (le))` | 95th percentile NLP model time |

### Row 2 — Scan Outcomes (3 panels)

| Panel | Type | Query | Description |
|---|---|---|---|
| Decision Breakdown | Pie chart | `sum by (decision) (mcp_scan_completions_total)` | allow / block / flag distribution |
| Severity Distribution | Bar gauge | `sum by (max_severity_band) (mcp_scan_completions_total)` | none / low / medium / high / critical |
| Scan Errors by Code | Time series (stacked) | `sum by (error_code) (rate(mcp_scan_errors_total[5m]))` | Error rate broken out by error code |

### Row 3 — Auth Boundaries (2 panels)

| Panel | Type | Query | Description |
|---|---|---|---|
| Auth Decisions Over Time | Time series (stacked) | `sum by (outcome) (rate(mcp_auth_decisions_total[5m]))` | allow / deny_401 / deny_403 / exempt |
| Auth Deny Rate | Stat (amber threshold) | `sum(rate(mcp_auth_decisions_total{outcome=~"deny.*"}[5m])) / sum(rate(mcp_auth_decisions_total[5m]))` | Fraction of requests denied; threshold: >20% = amber |

### Row 4 — Worker Internals (3 panels)

| Panel | Type | Query | Description |
|---|---|---|---|
| Presidio Analyze Latency | Heatmap | `sum(rate(worker_presidio_analyze_duration_seconds_bucket[5m])) by (le)` | Latency distribution over time |
| Findings Per Scan | Histogram | `sum(rate(worker_findings_per_scan_bucket[5m])) by (le)` | How many entities found per scan |
| Guard Rejections | Time series | `sum by (error_code) (rate(worker_scan_rejections_total[5m]))` | Pre-analysis rejections by type |

### Row 5 — Traces (2 panels)

| Panel | Type | Data source | Description |
|---|---|---|---|
| Recent Traces | Traces panel | Jaeger | Span waterfall for recent requests; filterable by `service.name` (`mcp-presidio-sensitivity` or `presidio-worker`). Shows full distributed trace with timing, span hierarchy, and attributes |
| Service Map | Node Graph panel | Jaeger | Service dependency graph derived from trace data; shows MCP server → worker call relationship with edge latency |

The Traces panel is Grafana's native visualization for Jaeger/Tempo data — it
renders the same span waterfall as the Jaeger UI but inline in the dashboard.
Clicking a trace ID expands to the full waterfall detail view.

### Row 6 — Service Info (1 panel)

| Panel | Type | Query | Description |
|---|---|---|---|
| Build Info | Table | `mcp_build_info`, `worker_build_info` | Running version and environment for each service |

---

## Trace ↔ Metric Correlation

Grafana's Traces panel (Row 5) provides direct trace visualization from the Jaeger
data source. For metric → trace correlation, Grafana's split view allows navigating
from a latency spike in a Prometheus panel to the Jaeger Traces panel filtered by
the same time window.

Full exemplar support (embedding `trace_id` on histogram observations) is a Phase 2
enhancement that would require switching to OTel Metrics SDK with OTLP export to a
Prometheus-compatible backend (e.g., Prometheus with OTLP receiver, or Mimir). This
is out of scope for Phase 1.

---

## Dependencies to Add

**`src/mcp_server/requirements.txt`**
```
prometheus-client
```

**`src/worker/requirements.txt`**
```
prometheus-client
```

After adding, regenerate both `requirements.lock.txt` files via `pip-compile`.

---

## Helm Changes

**`helm/mcp-server/values.yaml`** — add:
```yaml
metrics:
  enabled: true
```

**`helm/presidio-worker/values.yaml`** — add:
```yaml
metrics:
  enabled: true
```

No new env vars needed — `prometheus-client` auto-serves the default registry.
The `metrics.enabled` flag is for future use (conditionally mounting `/metrics`).

**NetworkPolicy** — both charts' NetworkPolicy templates must allow Prometheus to
scrape `/metrics`. Add an ingress rule permitting traffic from pods with
`app: prometheus` on the service port. This is an additive rule alongside existing
policy.

---

## Script Changes

**`scripts/setup-local.sh`**
- Add Prometheus and Grafana deployment steps after Jaeger, before MCP server/worker:
  ```bash
  kubectl apply -f "$PROJECT_ROOT/infrastructure/prometheus.yaml"
  kubectl rollout status deployment/prometheus -n mcp-presidio --timeout=60s

  kubectl apply -f "$PROJECT_ROOT/infrastructure/grafana.yaml"
  kubectl rollout status deployment/grafana -n mcp-presidio --timeout=60s
  ```
- Add Grafana URL to end-of-script summary output

**`scripts/status.sh`**
- Add Prometheus targets health check (scrape `http://localhost:9090/api/v1/targets`
  via port-forward and confirm both targets are `up`)
- Add Grafana health check (`/api/health`)

---

## Acceptance Criteria

1. `curl http://localhost:8000/metrics` (via port-forward) returns Prometheus
   exposition format containing all `mcp_*` metrics.
2. `curl http://localhost:8080/metrics` (via port-forward) returns all `worker_*` metrics.
3. Prometheus UI at `localhost:9090` shows both targets as `UP`.
4. After running `./scripts/demo.sh a`, Prometheus queries for `mcp_scan_completions_total`
   and `mcp_auth_decisions_total` return non-zero values.
5. Grafana dashboard at `localhost:3000` loads automatically with all panels populated.
6. Grafana Jaeger data source is functional — traces queryable from Grafana's Explore view.
7. No payload content, `caller_subject`, `scan_id`, or `correlation_id` appears as a
   metric label value.
8. `/metrics` does not require a JWT — confirmed by `curl` without `Authorization` header.
9. NetworkPolicy allows Prometheus → MCP server and Prometheus → worker scraping.
10. `./scripts/test.sh` passes (existing tests unbroken by new dependencies).

---

## Out of Scope (this spec)

- OTel Metrics SDK / OTLP metrics export — Prometheus pull model is simpler for Phase 1.
- Exemplar support (trace_id on histogram buckets) — requires OTel Metrics SDK (Phase 2).
- Alertmanager / alert rules — no alerting in local dev; Phase 2 with Istio.
- Loki / log aggregation — separate concern from metrics instrumentation.
- Rate limiting metrics — rate limiting is deferred to Phase 2 Istio (DEC-003).
- `caller_subject`-level dashboards — use audit trail for per-caller analysis.
- Persistent storage for Prometheus/Grafana — dev-only, ephemeral is acceptable.
