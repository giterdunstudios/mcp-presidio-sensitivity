"""
Audit trail writer for the MCP sensitivity server.

Writes one structured log record to the audit logger on every scan attempt
that reaches the worker — success or failure.  The audit logger uses the same
JsonFormatter as the application logger; records are identifiable by:
  - logger: "mcp-presidio-sensitivity.audit"
  - event_type: "audit"

No payload content, entity text, or offset data may appear in any audit record.
This module has no `content` parameter and must never be given one.

Depends on: structured-logging-spec.md (JsonFormatter and _ServiceContextFilter
must be configured before any audit record is written).
"""

from __future__ import annotations

import logging
import uuid
from typing import Optional

from backend.models import WorkerScanResponse
from backend.worker_client import WorkerError

# ---------------------------------------------------------------------------
# OTel trace_id resolution — graceful fallback until OTel is instrumented
# ---------------------------------------------------------------------------

try:
    import opentelemetry.trace as _otel_trace
    _OTEL_AVAILABLE = True
except ImportError:
    _otel_trace = None  # type: ignore
    _OTEL_AVAILABLE = False


def _resolve_trace_id(fallback: str) -> str:
    """Return the active OTel trace ID, or fallback (correlation_id) if unavailable."""
    if _OTEL_AVAILABLE:
        span = _otel_trace.get_current_span()
        ctx = span.get_span_context()
        if ctx.is_valid:
            return format(ctx.trace_id, "032x")
    return fallback


# ---------------------------------------------------------------------------
# Audit logger
# ---------------------------------------------------------------------------

_audit_logger = logging.getLogger("mcp-presidio-sensitivity.audit")


# ---------------------------------------------------------------------------
# Public writer
# ---------------------------------------------------------------------------


def write_audit_record(
    *,
    correlation_id: str,
    caller_subject: str,
    result: Optional[WorkerScanResponse] = None,
    error: Optional[WorkerError] = None,
) -> None:
    """
    Emit one audit record to the audit logger.

    Exactly one of `result` or `error` must be provided.

    Args:
        correlation_id:  Request correlation UUID from context var.
        caller_subject:  JWT `sub` claim from context var.
        result:          Successful WorkerScanResponse — present on happy path.
        error:           WorkerError — present when worker call failed.

    Security:
        This function has no `content` parameter.  It must never receive payload data.
    """
    if result is None and error is None:
        raise ValueError("write_audit_record requires either result or error")

    trace_id = _resolve_trace_id(correlation_id)

    scan_id = str(result.scan_id) if result else str(uuid.uuid4())
    decision = result.decision if result else "error"

    extra: dict = {
        "event_type": "audit",
        "audit_event": "scan_completed",
        "scan_id": scan_id,
        "correlation_id": correlation_id,
        "trace_id": trace_id,
        "caller_subject": caller_subject,
        "decision": decision,
    }

    if result is not None:
        extra["sensitivity_detected"] = result.sensitivity_detected
        extra["max_severity_band"] = result.max_severity_band
        extra["matched_categories"] = result.matched_categories
        extra["findings_count"] = result.confidence_summary.findings_count
        extra["policy_profile"] = result.policy_profile
        extra["detector_version"] = result.detector_version

    if error is not None:
        extra["error_code"] = error.error_code

    if error is not None:
        _audit_logger.warning("scan_completed", extra=extra)
    else:
        _audit_logger.info("scan_completed", extra=extra)
