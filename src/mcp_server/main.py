"""
MCP server entrypoint.

Architecture:
  - FastAPI application hosts all endpoints.
  - Istio/Envoy sidecar handles JWT validation and scope enforcement (DEC-003).
  - RequestContextMiddleware extracts the caller subject forwarded by Envoy
    and generates a correlation ID for request tracing.
  - MCP SDK (FastMCP) handles tool registration and MCP protocol framing.
  - The MCP SDK app is mounted on a sub-path of the FastAPI router.
  - Protected endpoints: /mcp (Envoy enforces auth before the app sees these)
  - Unprotected endpoints: GET /health, GET /.well-known/oauth-protected-resource

Request flow:
  1. Request arrives at the Envoy sidecar
  2. Envoy validates Bearer JWT (RequestAuthentication CRD)
  3. Envoy enforces scope via AuthorizationPolicy CRD
  4. Envoy forwards x-jwt-subject header to the app
  5. RequestContextMiddleware injects correlation_id and caller_subject
  6. MCP SDK processes the tool invocation
  7. Tool handler (tools/classify.py) calls the Presidio worker
  8. Response returned to caller

Security constraints non-negotiable at this layer:
  - Caller's Authorization header is stripped before any call to the backend.
  - No payload content in any log line.
  - Correlation ID is generated for every request and forwarded to the worker.
"""

from __future__ import annotations

import logging
import time
import uuid
from contextvars import ContextVar
from typing import Any, Optional

from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from mcp.server.fastmcp import FastMCP
from starlette.middleware.base import BaseHTTPMiddleware

import config
from audit.trail import write_audit_record
from backend.worker_client import WorkerError, call_worker
from observability.logging import configure_logging, log_request
from observability.metrics import (
    AUTH_DECISIONS,
    REQUEST_DURATION,
    SCAN_COMPLETIONS,
    SCAN_ERRORS,
    set_build_info,
    timer,
    WORKER_CALL_DURATION,
)
from observability.tracing import configure_tracing, get_tracer
from opentelemetry.trace import SpanKind, StatusCode

# ---------------------------------------------------------------------------
# Logging — must be configured before any logger.getLogger() calls fire
# ---------------------------------------------------------------------------

configure_logging(
    service_name="mcp-presidio-sensitivity",
    service_version=config.SERVICE_VERSION,
    environment=config.ENVIRONMENT,
)
logger = logging.getLogger("mcp-presidio-sensitivity")

# ---------------------------------------------------------------------------
# Context variable — carries correlation_id from middleware into tool handler
# ---------------------------------------------------------------------------

_current_correlation_id: ContextVar[str] = ContextVar(
    "_current_correlation_id", default=""
)
_current_caller_subject: ContextVar[str] = ContextVar(
    "_current_caller_subject", default="unknown"
)

# ---------------------------------------------------------------------------
# MCP tool registration
# ---------------------------------------------------------------------------

mcp = FastMCP(
    name="mcp-presidio-sensitivity",
    instructions=(
        "Classify text payloads for data sensitivity. "
        "Returns a bounded summary result — never the payload content."
    ),
)

# Build the sub-app now so mcp._session_manager is initialised before the
# lifespan function and FastAPI app are constructed below.
mcp_app = mcp.streamable_http_app()


@mcp.tool()
async def classify_payload_sensitivity(
    content: str,
    content_type: str,
    language: str = "en",
    tenant_policy: str = "default",
    threshold_profile: str = "default",
    return_details: bool = False,
    workflow_id: Optional[str] = None,
) -> dict[str, Any]:
    """
    Classify the sensitivity of a text payload.

    Submits the payload to the Presidio sensitivity scanner and returns
    a bounded summary result. The payload is never logged, stored, or
    returned in the response.

    Args:
        content: Raw text content to classify. Never logged or returned.
        content_type: MIME type — text/plain or application/json.
        language: Language code for the analyzer (default: en).
        tenant_policy: Policy profile identifier (default: default).
        threshold_profile: Threshold profile identifier (default: default).
        return_details: Reserved — bounded result is always returned at MVP.
        workflow_id: Optional caller workflow ID for traceability.

    Returns:
        Bounded sensitivity scan result including:
        - scan_id, status, sensitivity_detected, max_severity_band
        - matched_categories, entity_summary, decision
        - confidence_summary, policy_profile, detector_version, timestamp
    """
    # Retrieve context vars injected by RequestContextMiddleware.
    # Fallbacks fire only when called outside the middleware context (e.g. tests).
    correlation_id = _current_correlation_id.get(str(uuid.uuid4()))
    caller_subject = _current_caller_subject.get("unknown")

    effective_workflow_id = workflow_id or correlation_id

    with get_tracer().start_as_current_span("tool.classify_payload_sensitivity") as span:
        # SECURITY: never set content or any payload-derived attribute on the span
        span.set_attribute("caller_subject", caller_subject)
        span.set_attribute("correlation_id", effective_workflow_id)

        try:
            result = await call_worker(
                content=content,
                content_type=content_type,
                language=language,
                tenant_policy=tenant_policy,
                threshold_profile=threshold_profile,
                correlation_id=effective_workflow_id,
                source_system="mcp-presidio-sensitivity",
            )
            write_audit_record(
                correlation_id=effective_workflow_id,
                caller_subject=caller_subject,
                result=result,
            )
            SCAN_COMPLETIONS.labels(
                decision=result.decision,
                max_severity_band=result.max_severity_band or "none",
            ).inc()
            span.set_attribute("scan_id", result.scan_id)
            span.set_attribute("decision", result.decision)
            return result.model_dump(mode="json")
        except WorkerError as exc:
            span.set_status(StatusCode.ERROR, exc.error_code)
            SCAN_ERRORS.labels(error_code=exc.error_code).inc()
            write_audit_record(
                correlation_id=effective_workflow_id,
                caller_subject=caller_subject,
                error=exc,
            )
            # Raise as a plain exception — MCP SDK surfaces this as a tool error.
            # No payload content in exc.message (WorkerError never receives payload).
            raise RuntimeError(f"{exc.error_code}: {exc.message}") from exc


# ---------------------------------------------------------------------------
# Lifespan — starts the MCP StreamableHTTPSessionManager task group.
# mcp_app is created above so mcp._session_manager exists before this runs.
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    configure_tracing(
        service_name="mcp-presidio-sensitivity",
        service_version=config.SERVICE_VERSION,
    )
    set_build_info(version=config.SERVICE_VERSION, environment=config.ENVIRONMENT)
    logger.info(
        "MCP server starting",
        extra={
            "issuer_url": config.ISSUER_URL,
            "worker_url": config.WORKER_URL,
            "port": config.PORT,
            "auth_mode": "istio-envoy",
        },
    )
    async with mcp._session_manager.run():
        yield


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(
    title="MCP Presidio Sensitivity Server",
    version="0.1.0",
    lifespan=lifespan,
    # Disable OpenAPI docs UI — reduces attack surface in production
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

# ---------------------------------------------------------------------------
# Request context middleware
#
# JWT validation and scope enforcement are handled by the Istio/Envoy sidecar
# (DEC-003). This middleware is responsible only for:
#   - Generating a correlation_id for request tracing
#   - Extracting the caller subject from x-jwt-subject (forwarded by Envoy's
#     JWT authn filter via outputClaimToHeaders)
#   - Injecting both into context vars for downstream access
# ---------------------------------------------------------------------------


class RequestContextMiddleware(BaseHTTPMiddleware):
    """
    Lightweight request context middleware.

    Auth is handled upstream by Envoy. This middleware injects the
    caller identity forwarded by Envoy and generates a correlation ID.
    """

    async def dispatch(self, request: Request, call_next):
        start_time = time.monotonic()
        correlation_id = str(uuid.uuid4())

        token = _current_correlation_id.set(correlation_id)

        # Envoy forwards the validated JWT sub claim as x-jwt-subject
        # via RequestAuthentication outputClaimToHeaders configuration.
        caller_subject = request.headers.get("x-jwt-subject", "unknown")
        caller_subject_token = _current_caller_subject.set(caller_subject)

        request.state.correlation_id = correlation_id
        request.state.caller_subject = caller_subject

        path = request.url.path

        with get_tracer().start_as_current_span(
            "http.request",
            kind=SpanKind.SERVER,
        ) as span:
            span.set_attribute("http.path", path)
            span.set_attribute("http.method", request.method)
            span.set_attribute("correlation_id", correlation_id)
            span.set_attribute("caller_subject", caller_subject)

            response = await call_next(request)
            span.set_attribute("http.status_code", response.status_code)

            duration_ms = (time.monotonic() - start_time) * 1000
            REQUEST_DURATION.labels(
                path=path, status_code=str(response.status_code)
            ).observe(duration_ms / 1000)

            # All requests reaching the app have been authorized by Envoy.
            # Track as allowed; denied requests are counted by Envoy metrics.
            if path not in ("/health", "/metrics"):
                AUTH_DECISIONS.labels(outcome="allow").inc()

            worker_status = getattr(request.state, "worker_status", None)

            log_request(
                logger=logger,
                correlation_id=correlation_id,
                caller_subject=caller_subject,
                tool=path,
                auth_decision="allow",
                worker_status=worker_status,
                duration_ms=duration_ms,
            )

            _current_correlation_id.reset(token)
            _current_caller_subject.reset(caller_subject_token)
            return response


app.add_middleware(RequestContextMiddleware)

# ---------------------------------------------------------------------------
# Unprotected endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> dict:
    """Liveness probe — no auth required."""
    return {"status": "ok"}


@app.get("/.well-known/oauth-protected-resource")
async def oauth_protected_resource() -> dict:
    """
    OAuth 2.0 Protected Resource Metadata (RFC 9728 / draft-ietf-oauth-resource-metadata).

    Allows clients to discover the Authorization Server and supported scopes
    without prior out-of-band configuration.

    Required by auth spec §4, FR-3.
    """
    return {
        "resource": config.SERVER_RESOURCE_URL,
        "authorization_servers": [config.ISSUER_URL],
        "bearer_methods_supported": ["header"],
        "scopes_supported": [
            "tools:classify.submit",
            "tools:health.read",
        ],
    }


# ---------------------------------------------------------------------------
# Prometheus metrics endpoint — no auth required (cluster-internal only)
# ---------------------------------------------------------------------------

from prometheus_client import make_asgi_app as _prometheus_app  # noqa: E402
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST  # noqa: E402


@app.get("/metrics")
async def metrics_endpoint():
    """Prometheus metrics — served directly to avoid mount/trailing-slash issues."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


app.mount("/metrics", _prometheus_app())

# ---------------------------------------------------------------------------
# Mount MCP SDK application
# ---------------------------------------------------------------------------
# The FastMCP app is mounted at /.  The SDK's streamable HTTP transport
# registers its endpoint at /mcp, making the effective path /mcp.
# Explicit routes (/health, /.well-known/...) are defined above and matched
# first by FastAPI's router before the catch-all mount is reached.
# Envoy enforces JWT auth and scope on /mcp before the app sees the request.

app.mount("/", mcp_app)
