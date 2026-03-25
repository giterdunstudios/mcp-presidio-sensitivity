"""
HTTP client for the Presidio worker backend.

Security constraints (non-negotiable):
  - The caller's Authorization header is NEVER forwarded to the worker.
    The only headers sent are Content-Type and an internal correlation ID.
  - Worker responses are parsed strictly — unknown fields are ignored.
  - On worker error, timeout, or parse failure, a sanitised MCPError is
    raised.  No payload content appears in any exception message.
  - The worker URL is internal-only (ClusterIP) — unreachable externally.

See: auth spec §7 (backend trust model) and briefing §4 (backend adapter).
"""

from __future__ import annotations

import logging
from typing import Optional

import httpx
from pydantic import ValidationError

import config
from backend.models import WorkerRequestMetadata, WorkerScanRequest, WorkerScanResponse

logger = logging.getLogger("mcp-presidio-sensitivity.backend")


# ---------------------------------------------------------------------------
# Public error type
# ---------------------------------------------------------------------------


class WorkerError(Exception):
    """Raised when the worker call fails for any reason."""

    def __init__(self, error_code: str, message: str) -> None:
        self.error_code = error_code
        self.message = message
        super().__init__(message)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


async def call_worker(
    *,
    content: str,
    content_type: str,
    language: str = "en",
    tenant_policy: str = "default",
    threshold_profile: str = "default",
    correlation_id: str,
    source_system: str = "mcp-presidio-sensitivity",
) -> WorkerScanResponse:
    """
    Forward a scan request to the Presidio worker and return the parsed response.

    Args:
        content: The raw payload text.  Never logged.
        content_type: MIME type of the content (text/plain or application/json).
        language: Language code for the Presidio analyzer.
        tenant_policy: Policy profile identifier.
        threshold_profile: Threshold profile identifier.
        correlation_id: UUID string for request traceability.
        source_system: Caller identity label for worker audit metadata.

    Returns:
        WorkerScanResponse with bounded scan result.

    Raises:
        WorkerError: On any HTTP error, timeout, or parse failure.
    """
    request_body = WorkerScanRequest(
        content=content,
        content_type=content_type,
        language=language,
        tenant_policy=tenant_policy,
        threshold_profile=threshold_profile,
        request_metadata=WorkerRequestMetadata(
            source_system=source_system,
            workflow_id=correlation_id,
        ),
    )

    # ------------------------------------------------------------------
    # SECURITY: Build headers explicitly.
    # Do NOT include Authorization or any caller-derived header.
    # ------------------------------------------------------------------
    headers = {
        "Content-Type": "application/json",
        "X-Correlation-ID": correlation_id,
    }

    scan_url = f"{config.WORKER_URL.rstrip('/')}/scan"

    try:
        async with httpx.AsyncClient(timeout=config.WORKER_TIMEOUT_SECONDS) as client:
            response = await client.post(
                scan_url,
                content=request_body.model_dump_json(),
                headers=headers,
            )
    except httpx.TimeoutException:
        logger.warning(
            "worker call timed out",
            extra={"correlation_id": correlation_id},
        )
        raise WorkerError(
            "SCAN_TIMEOUT",
            "The scan worker did not respond within the allowed time.",
        )
    except Exception as exc:
        logger.warning(
            "worker call failed: %s",
            type(exc).__name__,
            extra={"correlation_id": correlation_id},
        )
        raise WorkerError(
            "SCAN_FAILED",
            "The scan worker is currently unavailable.",
        ) from exc

    # ------------------------------------------------------------------
    # Translate HTTP errors
    # ------------------------------------------------------------------
    if response.status_code == 413:
        raise WorkerError("PAYLOAD_TOO_LARGE", "Request exceeds maximum supported size.")

    if response.status_code == 415:
        raise WorkerError("UNSUPPORTED_CONTENT_TYPE", "Content type is not supported.")

    if response.status_code == 400:
        raise WorkerError("INVALID_REQUEST", "The scan request was rejected by the worker.")

    if response.status_code != 200:
        logger.warning(
            "worker returned unexpected status",
            extra={
                "correlation_id": correlation_id,
                "status_code": response.status_code,
            },
        )
        raise WorkerError(
            "SCAN_FAILED",
            f"Worker returned an unexpected status: {response.status_code}",
        )

    # ------------------------------------------------------------------
    # Parse response — do not let parse errors leak response body content
    # ------------------------------------------------------------------
    try:
        return WorkerScanResponse.model_validate(response.json())
    except (ValidationError, Exception) as exc:
        logger.warning(
            "worker response parse failed: %s",
            type(exc).__name__,
            extra={"correlation_id": correlation_id},
        )
        raise WorkerError(
            "SCAN_FAILED",
            "Worker response could not be parsed.",
        ) from exc
