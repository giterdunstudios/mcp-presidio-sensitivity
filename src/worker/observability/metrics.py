"""
Prometheus metrics for the Presidio worker.

All metrics use bounded label values only — no payload content, scan_id,
or correlation_id (high cardinality risk).

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

SCAN_COMPLETIONS = Counter(
    "worker_scan_completions_total",
    "Scans that completed analysis successfully",
    ["decision", "max_severity_band"],
)

SCAN_REJECTIONS = Counter(
    "worker_scan_rejections_total",
    "Pre-analysis guard rejections",
    ["error_code"],
)

SCAN_FAILURES = Counter(
    "worker_scan_failures_total",
    "Analysis engine errors",
)

# ---------------------------------------------------------------------------
# Histograms
# ---------------------------------------------------------------------------

SCAN_DURATION = Histogram(
    "worker_scan_duration_seconds",
    "Total scan handler time",
)

PRESIDIO_ANALYZE_DURATION = Histogram(
    "worker_presidio_analyze_duration_seconds",
    "Presidio engine.analyze() call only",
)

FINDINGS_PER_SCAN = Histogram(
    "worker_findings_per_scan",
    "Distribution of findings count per scan",
    buckets=[0, 1, 2, 3, 5, 8, 13, 21, 50],
)

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------

BUILD_INFO = Info(
    "worker_build",
    "Static service identity",
)


def set_build_info(version: str, environment: str) -> None:
    """Set build info labels once at startup."""
    BUILD_INFO.info({"version": version, "environment": environment})


# ---------------------------------------------------------------------------
# Timer helper
# ---------------------------------------------------------------------------

@contextmanager
def timer(histogram: Histogram):
    """Context manager that observes elapsed time on a histogram."""
    start = time.monotonic()
    try:
        yield
    finally:
        histogram.observe(time.monotonic() - start)
