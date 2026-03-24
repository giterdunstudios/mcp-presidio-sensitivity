"""
Structured logging configuration for the MCP server.

Log format is JSON-compatible structured output.  Every request log record
includes a fixed set of fields.  The `content` field is NEVER present in
any log record emitted from this module or any handler that uses it.

Required fields per request (from briefing §6):
  - correlation_id
  - caller_subject  (from JWT `sub` claim)
  - tool            (endpoint called)
  - auth_decision   (allow / deny-401 / deny-403)
  - worker_status   (if backend was called)
  - duration_ms
  - timestamp
"""

from __future__ import annotations

import json
import logging
import logging.config
import sys
from datetime import datetime, timezone
from typing import Any, Optional


# ---------------------------------------------------------------------------
# JSON log formatter
# ---------------------------------------------------------------------------


class JsonFormatter(logging.Formatter):
    """
    Emit log records as single-line JSON objects.

    Extra fields added to the LogRecord by calling code via the `extra=`
    keyword are included in the JSON output.  Standard fields (levelname,
    name, message) are always present.
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
        }
    )

    def format(self, record: logging.LogRecord) -> str:
        record.message = record.getMessage()

        doc: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.message,
        }

        # Include extra fields (caller-supplied via extra={...})
        for key, value in record.__dict__.items():
            if key not in self._RESERVED:
                doc[key] = value

        if record.exc_info:
            doc["exc_info"] = self.formatException(record.exc_info)

        return json.dumps(doc, default=str)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------


def configure_logging(level: str = "INFO") -> None:
    """
    Configure root logger with the JSON formatter.

    Call once at application startup.
    """
    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))

    if not root.handlers:
        handler = logging.StreamHandler(sys.stdout)
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

    Args:
        logger:          Logger instance to write to.
        correlation_id:  UUID string identifying this request.
        caller_subject:  `sub` claim from the validated JWT.
        tool:            Endpoint or tool name (e.g. classify_payload_sensitivity).
        auth_decision:   One of: allow / deny-401 / deny-403.
        worker_status:   HTTP status code from worker call, or None if not called.
        duration_ms:     Total request duration in milliseconds.

    Security note:
        This function has no `content` parameter and must never be given one.
    """
    logger.info(
        "request",
        extra={
            "correlation_id": correlation_id,
            "caller_subject": caller_subject,
            "tool": tool,
            "auth_decision": auth_decision,
            "worker_status": worker_status,
            "duration_ms": round(duration_ms, 2),
        },
    )
