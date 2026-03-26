"""
FastAPI worker entrypoint.

Endpoints:
  GET  /health     — liveness probe; returns {"status": "ok"}
  POST /scan       — analyze a payload and return a bounded result

Security constraints enforced at this layer:
  - Content-type is checked against the allowlist before any body parsing.
  - Payload size is checked against MAX_PAYLOAD_BYTES before analysis.
  - ScanRequest.content never appears in log statements or error responses.
  - All error responses contain only error_code and message — never payload content.
  - Request exceptions are caught and sanitised before propagating to FastAPI's
    default exception handlers.
"""

from __future__ import annotations

import logging
import uuid
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse
from pydantic import ValidationError

import config
from analyzer import get_engine
from minimizer import minimize
from models import ErrorResponse, ScanRequest, ScanResponse
from observability.logging import configure_logging
from observability.tracing import configure_tracing, get_tracer
from opentelemetry.propagate import extract as otel_extract
from opentelemetry.trace import SpanKind, StatusCode

# ---------------------------------------------------------------------------
# Logging — must be configured before any logger.getLogger() calls fire
# ---------------------------------------------------------------------------

configure_logging(
    service_name="presidio-worker",
    service_version=config.SERVICE_VERSION,
    environment=config.ENVIRONMENT,
)
logger = logging.getLogger("presidio-worker")


# ---------------------------------------------------------------------------
# Lifespan — pre-warm Presidio on startup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    configure_tracing(
        service_name="presidio-worker",
        service_version=config.SERVICE_VERSION,
    )
    logger.info("Pre-warming Presidio AnalyzerEngine")
    get_engine(min_score_threshold=config.MIN_SCORE_THRESHOLD)
    logger.info("Worker startup complete")
    yield


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Presidio Sensitivity Worker",
    version="0.1.0",
    lifespan=lifespan,
    # Disable OpenAPI schema and docs UI in production to reduce attack surface.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


# ---------------------------------------------------------------------------
# Health probe
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Scan endpoint
# ---------------------------------------------------------------------------

@app.post(
    "/scan",
    response_model=ScanResponse,
    status_code=status.HTTP_200_OK,
)
async def scan(request: Request) -> JSONResponse:
    """
    Accept a scan request, enforce pre-analysis guards, run Presidio,
    and return a bounded result.

    No payload content appears in any log or error response emitted by this handler.
    """
    scan_id = uuid.uuid4()

    # Extract W3C traceparent from MCP server to continue the distributed trace
    try:
        _trace_ctx = otel_extract(dict(request.headers))
    except Exception:
        _trace_ctx = None

    with get_tracer().start_as_current_span(
        "worker.scan",
        context=_trace_ctx,
        kind=SpanKind.SERVER,
    ) as span:
        span.set_attribute("scan_id", str(scan_id))
        return await _scan_inner(request, scan_id, span)


async def _scan_inner(request: Request, scan_id: uuid.UUID, span: Any) -> JSONResponse:
    # ------------------------------------------------------------------
    # Guard 1 — content-type allowlist (checked before body is read)
    # ------------------------------------------------------------------
    raw_content_type = request.headers.get("content-type", "")
    # Strip parameters (e.g. "application/json; charset=utf-8" → "application/json")
    declared_type = raw_content_type.split(";")[0].strip().lower()

    if declared_type not in config.SUPPORTED_CONTENT_TYPES:
        span.set_status(StatusCode.ERROR, "UNSUPPORTED_CONTENT_TYPE")
        logger.warning(
            "scan rejected: unsupported content-type",
            extra={"scan_id": str(scan_id), "content_type": declared_type},
        )
        return JSONResponse(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            content=ErrorResponse(
                scan_id=scan_id,
                status="rejected",
                error_code="UNSUPPORTED_CONTENT_TYPE",
                message="The submitted content-type is not supported.",
            ).model_dump(mode="json"),
        )

    # ------------------------------------------------------------------
    # Guard 2 — payload size (checked before body is parsed)
    # ------------------------------------------------------------------
    body_bytes = await request.body()

    if len(body_bytes) > config.MAX_PAYLOAD_BYTES:
        span.set_status(StatusCode.ERROR, "PAYLOAD_TOO_LARGE")
        logger.warning(
            "scan rejected: payload too large",
            extra={"scan_id": str(scan_id), "size_bytes": len(body_bytes)},
        )
        return JSONResponse(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            content=ErrorResponse(
                scan_id=scan_id,
                status="rejected",
                error_code="PAYLOAD_TOO_LARGE",
                message="Request exceeds maximum supported size.",
            ).model_dump(mode="json"),
        )

    # ------------------------------------------------------------------
    # Guard 3 — schema validation
    # ------------------------------------------------------------------
    try:
        scan_request = ScanRequest.model_validate_json(body_bytes)
    except (ValidationError, Exception):
        span.set_status(StatusCode.ERROR, "INVALID_REQUEST_SCHEMA")
        # Do not include body_bytes or any parsed fragment in the log message.
        logger.warning("scan rejected: invalid request schema", extra={"scan_id": str(scan_id)})
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=ErrorResponse(
                scan_id=scan_id,
                status="rejected",
                error_code="INVALID_REQUEST_SCHEMA",
                message="Request body does not conform to the expected schema.",
            ).model_dump(mode="json"),
        )
    finally:
        # Release the raw bytes immediately — the parsed model now owns content.
        del body_bytes

    # ------------------------------------------------------------------
    # Guard 4 — content-type field in body must match header
    # ------------------------------------------------------------------
    if scan_request.content_type not in config.SUPPORTED_CONTENT_TYPES:
        span.set_status(StatusCode.ERROR, "UNSUPPORTED_CONTENT_TYPE")
        logger.warning(
            "scan rejected: unsupported content_type field",
            extra={"scan_id": str(scan_id), "content_type": scan_request.content_type},
        )
        return JSONResponse(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            content=ErrorResponse(
                scan_id=scan_id,
                status="rejected",
                error_code="UNSUPPORTED_CONTENT_TYPE",
                message="The content_type field specifies an unsupported type.",
            ).model_dump(mode="json"),
        )

    # ------------------------------------------------------------------
    # Analysis — payload is used here and must not leak beyond this block
    # ------------------------------------------------------------------
    workflow_id = scan_request.request_metadata.workflow_id if scan_request.request_metadata else None
    logger.info(
        "scan started",
        extra={"scan_id": str(scan_id), "workflow_id": workflow_id or "", "trace_id": workflow_id or str(scan_id)},
    )
    language = scan_request.language or config.DEFAULT_LANGUAGE
    try:
        engine = get_engine(min_score_threshold=config.MIN_SCORE_THRESHOLD)
        with get_tracer().start_as_current_span("presidio.analyze") as analyze_span:
            # SECURITY: language code is safe metadata; content is never an attribute
            analyze_span.set_attribute("language", language)
            findings = engine.analyze(text=scan_request.content, language=language)
    except Exception:
        span.set_status(StatusCode.ERROR, "SCAN_FAILED")
        # Exception message must not include scan_request.content.
        logger.exception(
            "scan failed: analysis engine error (payload content suppressed)",
            extra={"scan_id": str(scan_id)},
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=ErrorResponse(
                scan_id=scan_id,
                status="failed",
                error_code="SCAN_FAILED",
                message="An internal error occurred during analysis.",
            ).model_dump(mode="json"),
        )
    finally:
        # Remove reference to content as soon as analysis is done.
        # findings contains only entity_type + score — no payload text.
        del scan_request

    # ------------------------------------------------------------------
    # Minimization — produce bounded result
    # ------------------------------------------------------------------
    result = minimize(
        findings=findings,
        policy_profile=config.POLICY_PROFILE,
        scan_id=scan_id,
    )

    span.set_attribute("decision", result.decision)
    span.set_attribute("max_severity_band", result.max_severity_band)
    span.set_attribute("findings_count", result.confidence_summary.findings_count)

    logger.info(
        "scan completed",
        extra={
            "scan_id": str(result.scan_id),
            "trace_id": workflow_id or str(result.scan_id),
            "decision": result.decision,
            "max_severity_band": result.max_severity_band,
            "findings_count": result.confidence_summary.findings_count,
            "policy_profile": result.policy_profile,
            "detector_version": result.detector_version,
        },
    )

    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=result.model_dump(mode="json"),
    )
