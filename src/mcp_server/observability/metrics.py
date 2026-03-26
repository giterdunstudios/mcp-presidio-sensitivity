"""
Prometheus metrics for the MCP server.

All metrics use bounded label values only — no payload content, caller_subject,
scan_id, or correlation_id (high cardinality / PII risk).

Metrics are registered in the default CollectorRegistry and served by
prometheus_client.make_asgi_app() mounted at /metrics on the FastAPI app.
"""

from __future__ import annotations

import time
from contextlib import contextmanager

from prometheus_client import Counter, Histogram, Info

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

AUTH_DECISIONS = Counter(
    "mcp_auth_decisions_total",
    "Auth middleware decisions",
    ["outcome"],  # allow | deny_401 | deny_403 | exempt
)

SCAN_COMPLETIONS = Counter(
    "mcp_scan_completions_total",
    "Successful scan completions",
    ["decision", "max_severity_band"],
)

SCAN_ERRORS = Counter(
    "mcp_scan_errors_total",
    "Worker call failures",
    ["error_code"],
)

# ---------------------------------------------------------------------------
# Histograms
# ---------------------------------------------------------------------------

REQUEST_DURATION = Histogram(
    "mcp_request_duration_seconds",
    "Full request duration (middleware entry to response)",
    ["path", "status_code"],
)

WORKER_CALL_DURATION = Histogram(
    "mcp_worker_call_duration_seconds",
    "HTTP call to worker (httpx round-trip)",
)

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------

BUILD_INFO = Info(
    "mcp_build",
    "Static service identity",
)


def set_build_info(version: str, environment: str) -> None:
    """Set build info labels once at startup."""
    BUILD_INFO.info({"version": version, "environment": environment})


# ---------------------------------------------------------------------------
# Timer helper
# ---------------------------------------------------------------------------

@contextmanager
def timer(histogram: Histogram, **labels):
    """Context manager that observes elapsed time on a histogram."""
    start = time.monotonic()
    try:
        yield
    finally:
        histogram.labels(**labels).observe(time.monotonic() - start) if labels else histogram.observe(time.monotonic() - start)
