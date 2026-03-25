"""
Structured logging configuration for the Presidio worker.

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
import sys
from datetime import datetime, timezone
from typing import Any


# ---------------------------------------------------------------------------
# Service context filter — injects service identity into every record
# ---------------------------------------------------------------------------


class _ServiceContextFilter(logging.Filter):
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
            "service_name",
            "service_version",
            "environment",
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

        if "trace_id" in record.__dict__:
            doc["trace_id"] = record.__dict__["trace_id"]

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
# Scan log helper
# ---------------------------------------------------------------------------


def log_scan(
    *,
    logger: logging.Logger,
    event: str,
    scan_id: str,
    level: int = logging.INFO,
    **kwargs: Any,
) -> None:
    """
    Emit a single structured log record for a scan lifecycle event.

    Args:
        logger:   Logger instance to write to.
        event:    One of: scan started / scan completed / scan rejected / scan failed.
        scan_id:  UUID identifying the scan.
        level:    Log level (default INFO).
        **kwargs: Additional safe fields (decision, max_severity_band,
                  findings_count, workflow_id, etc.).

    Security note:
        This function has no `content` parameter and must never be given one.
    """
    logger.log(level, event, extra={"scan_id": scan_id, **kwargs})
