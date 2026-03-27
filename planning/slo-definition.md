# SLO Definition — mcp-presidio-sensitivity

## Status

All targets are **aspirational** unless marked otherwise. Grafana is deployed at
`http://localhost:3000` and Prometheus at `http://localhost:9090`, but no baseline
measurements were taken at the time of authoring this document. Targets are set using
the following calibration inputs:

- Presidio warm-path p99 latency for short payloads: typically 200–500ms (community
  benchmark from research findings; not measured on this cluster)
- Phase 2 Istio sidecar overhead: approximately 2–5ms per hop (two hops on the
  classify path: agent → MCP sidecar, MCP sidecar → MCP app)
- Worker call round-trip via httpx includes one additional hop: MCP app → Worker sidecar
  → Worker app → Worker sidecar → MCP app (approximately 4–10ms of sidecar overhead)

When live baseline data is available, replace aspirational targets with measured targets
and update the `Aspirational/Measured` column accordingly.

---

## SLO Table

| SLO | Target | Metric | Query | Window | Aspirational/Measured | Baseline |
|-----|--------|--------|-------|--------|-----------------------|----------|
| **Request latency p50** | ≤ 300ms | `mcp_request_duration_seconds` | `histogram_quantile(0.50, sum(rate(mcp_request_duration_seconds_bucket{path="/mcp",status_code="200"}[5m])) by (le))` | Rolling 5 min | Aspirational | Not measured |
| **Request latency p99** | ≤ 800ms | `mcp_request_duration_seconds` | `histogram_quantile(0.99, sum(rate(mcp_request_duration_seconds_bucket{path="/mcp",status_code="200"}[5m])) by (le))` | Rolling 5 min | Aspirational | Not measured |
| **Application error rate** | ≤ 1% of scan calls | `mcp_scan_errors_total` | `sum(rate(mcp_scan_errors_total[5m])) / sum(rate(mcp_scan_completions_total[5m]) + rate(mcp_scan_errors_total[5m]))` | Rolling 5 min | Aspirational | Not measured |
| **Scan duration p50** | ≤ 250ms | `mcp_worker_call_duration_seconds` | `histogram_quantile(0.50, sum(rate(mcp_worker_call_duration_seconds_bucket[5m])) by (le))` | Rolling 5 min | Aspirational | Not measured |
| **Scan duration p99** | ≤ 600ms | `mcp_worker_call_duration_seconds` | `histogram_quantile(0.99, sum(rate(mcp_worker_call_duration_seconds_bucket[5m])) by (le))` | Rolling 5 min | Aspirational | Not measured |
| **Availability** | ≥ 99.5% | `[PLACEHOLDER — metric not yet instrumented]` | `[PLACEHOLDER]` | Rolling 24h | Aspirational | Not measured |

---

## Notes on Individual SLOs

### Request latency (p50, p99)

**Metric:** `mcp_request_duration_seconds` with labels `path="/mcp"` and `status_code="200"`.

Filter to `status_code="200"` to measure latency only on successful classify calls. Auth
failures (401/403) are handled upstream by the Envoy sidecar and do not reach the
application — including them would inflate sample counts with fast sidecar-only paths.

**p99 target rationale:** 800ms accounts for:
- Presidio warm-path p99 for short payloads: 200–500ms
- Istio sidecar overhead (two hops, inbound): ~4–10ms
- httpx worker call overhead: ~2–5ms
- FastAPI/FastMCP handler overhead: ~5–20ms
- Headroom buffer: ~270–270ms

Cold-path startup (first request, spaCy model loading) will exceed this target. The SLO
applies to the warm path only (pod has been running for at least 60 seconds with at least
one prior request).

**p50 target rationale:** Short text payloads with common PII types typically return in
under 200ms on the warm path. 300ms provides headroom for moderate payload sizes.

---

### Application error rate

**Metric:** `mcp_scan_errors_total` (label: `error_code`) and `mcp_scan_completions_total`
(labels: `decision`, `max_severity_band`).

**Gap — auth denial counts are not captured by app metrics:**
The Envoy sidecar intercepts requests before they reach the MCP server application. Auth
denials (HTTP 401 and 403) are counted by the sidecar, not by `mcp_scan_errors_total`.
The application error rate SLO therefore measures **only scan-path failures** (worker
timeouts, worker unavailable, scan validation errors) — not the total request error rate
including auth failures.

To measure total error rate including auth failures, use sidecar-level metrics from Istio
(e.g., `istio_requests_total{response_code=~"4..|5.."}`) rather than application metrics.
This is a Phase 2 observability gap.

`mcp_scan_errors_total` captures the following `error_code` values (from application code):
- `WORKER_TIMEOUT` — httpx timeout calling the Presidio worker
- `WORKER_UNAVAILABLE` — worker pod unreachable
- `SCAN_ERROR` — unexpected error during scan processing

---

### Scan duration (p50, p99)

**Metric:** `mcp_worker_call_duration_seconds` (no labels — single histogram, no label
dimensions).

This metric is recorded by the MCP server when it makes the httpx round-trip call to the
Presidio worker. It is the **only proxy for worker scan time** available from the metrics
endpoint, because the worker's own `/metrics` endpoint cannot be scraped by Prometheus
directly due to the NetworkPolicy restricting ingress to the worker pod to the MCP server
label only (`app.kubernetes.io/name: mcp-presidio-sensitivity`).

`mcp_worker_call_duration_seconds` includes:
- Network latency from MCP server pod to worker pod (cluster-internal)
- Envoy sidecar overhead at both ends (~4–10ms total)
- Worker httpx handler overhead
- Presidio analyzer execution time (the dominant component)

It does not separately measure the Presidio analyzer execution time in isolation. This is
acceptable as a proxy metric because the network and sidecar overheads are small and
stable relative to Presidio execution time.

**p99 target rationale:** 600ms accounts for Presidio p99 of 500ms for short payloads,
plus sidecar and network overhead (~100ms buffer). Payloads that approach the size limit
will likely exceed this target — document as a known ceiling.

---

### Availability

**Status:** `[PLACEHOLDER — metric not yet instrumented]`

Neither a heartbeat/synthetic probe metric nor an external uptime probe is currently
implemented. Availability cannot be measured from existing Prometheus metrics alone —
`mcp_scan_completions_total` and `mcp_request_duration_seconds` only record activity
when requests are made; they do not distinguish "service is up, zero traffic" from
"service is down."

**Backlog item #39:** Implement one of the following to enable availability measurement:
- A periodic synthetic probe (e.g., `curl /health` from a CronJob or external probe)
  recording a counter or gauge (e.g., `mcp_health_probe_result{status="ok|error"}`)
- Istio `ServiceEntry` + `EnvoyFilter` health check probe writing to Prometheus
- External uptime monitoring (Blackbox Exporter or equivalent)

Until backlog item #39 is implemented, availability can only be approximated via manual
health check (`/health` endpoint) or by inference from absence of restart events in
`kube_pod_container_status_restarts_total`.

---

## Measurement Procedure

When a Grafana instance is available at `http://localhost:3000`:

1. Confirm Prometheus data source is configured pointing to `http://localhost:9090`
2. Run each query in the SLO table above in the Grafana Explore view
3. Observe over a representative load window (minimum 30 minutes of actual traffic from
   `demo.sh a` or `classify.sh` calls)
4. Record the 90th-percentile of the observed quantile values as the baseline
5. Set the SLO target at 1.5–2× the measured baseline p50/p99 (provides headroom
   for load variation without setting an unreachable target)
6. Update the `Baseline` column with the measured value and change `Aspirational` to
   `Measured` for each measured SLO

---

## Revision History

| Date | Author | Change |
|------|--------|--------|
| 2026-03-27 | Product / Scope Lead | Initial draft — all targets aspirational, awaiting baseline measurement |
