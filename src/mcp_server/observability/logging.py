"""
Structured logging configuration for the MCP server.

Log format is JSON-compatible structured output aligned to the OpenTelemetry
log data model (flattened for stdout/Kubernetes).  The `content` field is
NEVER present in any log record emitted from this module or any handler that
uses it.

Field order in every record:
  timestamp, level, service_name, service_version, environment,
  logger, message, trace_id (if present), then event-specific extras.
"""

from __future__ import annotations

import json
import logging
import logging.config
import sys
from datetime import datetime, timezone
from typing import Any, Optional


# ---------------------------------------------------------------------------
# Service context filter — injects service identity into every record
# ---------------------------------------------------------------------------


class _ServiceContextFilter(logging.Filter):
    """
    Inject static service-identity fields into every LogRecord.

    Fields injected: service_name, service_version, environment.
    These are set by configure_logging() using values from config; the
    formatter then surfaces them in the defined field order.
    """

    def __init__(self, service_name: str, service_version: str, environment: str) -> None:
        super().__init__()
        self._service_name = service_name
        self._service_version = service_version
        self._environment = environment

    def filter(self, record: logging.LogRecord) -> bool:
        record.service_name = self._service_name
        record.service_version = self._service_version
        record.environment = self._environment
        return True


# ---------------------------------------------------------------------------
# JSON log formatter
# ---------------------------------------------------------------------------


class JsonFormatter(logging.Formatter):
    """
    Emit log records as single-line JSON objects.

    Fixed field order: timestamp, level, service_name, service_version,
    environment, logger, message, trace_id (if present), then all remaining
    caller-supplied extras.  Service fields are injected by _ServiceContextFilter
    before this formatter runs.
    """

    # Fields that are part of LogRecord internals — not surfaced as extras
    _RESERVED = frozenset(
        {
            "args",
            "created",
            "exc_info",
            "exc_text",
            "filename",
            "funcName",
            "levelname",
            "levelno",
            "lineno",
            "message",
            "module",
            "msecs",
            "msg",
            "name",
            "pathname",
            "process",
            "processName",
            "relativeCreated",
            "stack_info",
            "taskName",
            "thread",
            "threadName",
            # injected by _ServiceContextFilter — handled explicitly below
            "service_name",
            "service_version",
            "environment",
            # injected by OTel block below — handled explicitly, not via extras loop
            "trace_id",
            "span_id",
        }
    )

    def format(self, record: logging.LogRecord) -> str:
        record.message = record.getMessage()

        doc: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "service_name": getattr(record, "service_name", ""),
            "service_version": getattr(record, "service_version", ""),
            "environment": getattr(record, "environment", ""),
            "logger": record.name,
            "message": record.message,
        }

        # OTel trace context — injected if there is an active span.
        # Takes precedence over any trace_id in record extras.
        # Wrapped in try/except so logging never fails if OTel is unavailable.
        try:
            from opentelemetry import trace as _otel_trace  # noqa: PLC0415
            _span_ctx = _otel_trace.get_current_span().get_span_context()
            if _span_ctx.is_valid:
                doc["trace_id"] = format(_span_ctx.trace_id, "032x")
                doc["span_id"] = format(_span_ctx.span_id, "016x")
        except Exception:
            pass

        # Fallback: record-level trace_id (correlation_id) when no OTel span is active
        if "trace_id" not in doc and "trace_id" in record.__dict__:
            doc["trace_id"] = record.__dict__["trace_id"]

        # Remaining caller-supplied extras
        for key, value in record.__dict__.items():
            if key not in self._RESERVED and key != "trace_id":
                doc[key] = value

        if record.exc_info:
            doc["exc_info"] = self.formatException(record.exc_info)

        return json.dumps(doc, default=str)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------


def configure_logging(
    level: str = "INFO",
    service_name: str = "",
    service_version: str = "",
    environment: str = "",
) -> None:
    """
    Configure root logger with the JSON formatter and service context filter.

    Call once at application startup, passing service identity from config.
    """
    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))

    if not root.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.addFilter(_ServiceContextFilter(service_name, service_version, environment))
        handler.setFormatter(JsonFormatter())
        root.addHandler(handler)


# ---------------------------------------------------------------------------
# Request log helper
# ---------------------------------------------------------------------------


def log_request(
    *,
    logger: logging.Logger,
    correlation_id: str,
    caller_subject: str,
    tool: str,
    auth_decision: str,
    worker_status: Optional[str] = None,
    duration_ms: float,
) -> None:
    """
    Emit a single structured log record for a completed request.

    Level: WARNING for auth denials (deny-401, deny-403); INFO otherwise.

    Args:
        logger:          Logger instance to write to.
        correlation_id:  UUID string identifying this request.
        caller_subject:  `sub` claim from the validated JWT.
        tool:            Endpoint or tool name.
        auth_decision:   One of: allow / deny-401 / deny-403.
        worker_status:   HTTP status code from worker call, or None if not called.
        duration_ms:     Total request duration in milliseconds.

    Security note:
        This function has no `content` parameter and must never be given one.
    """
    extra = {
        "correlation_id": correlation_id,
        "trace_id": correlation_id,
        "caller_subject": caller_subject,
        "tool": tool,
        "auth_decision": auth_decision,
        "worker_status": worker_status,
        "duration_ms": round(duration_ms, 2),
    }

    if auth_decision.startswith("deny"):
        logger.warning("request", extra=extra)
    else:
        logger.info("request", extra=extra)
