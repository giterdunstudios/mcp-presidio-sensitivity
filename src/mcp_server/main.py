"""
MCP server entrypoint.

Architecture:
  - FastAPI application hosts all endpoints.
  - JWT middleware validates Bearer tokens before any business logic executes.
  - MCP SDK (FastMCP) handles tool registration and MCP protocol framing.
  - The MCP SDK app is mounted on a sub-path of the FastAPI router.
  - Protected endpoints: /mcp (MCP SDK app mount)
  - Unprotected endpoints: GET /health, GET /.well-known/oauth-protected-resource

Request flow:
  1. Request arrives at FastAPI
  2. JWTAuthMiddleware fires:
     a. Skip check for exempt paths (/health, /.well-known/...)
     b. Extract and validate Bearer JWT (raises 401 on failure)
     c. Check required scope (raises 403 on scope mismatch)
     d. Inject claims into request.state for downstream access
  3. MCP SDK processes the tool invocation
  4. Tool handler (tools/classify.py) calls the Presidio worker
  5. Response returned to caller

Security constraints non-negotiable at this layer:
  - Token validation runs BEFORE request body is read for any protected path.
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

from fastapi import FastAPI, Request
from mcp.server.fastmcp import FastMCP
from starlette.middleware.base import BaseHTTPMiddleware

import config
from auth.errors import (
    TokenInvalidError,
    TokenMissingError,
    build_401_response,
    build_403_response,
)
from auth.token_verifier import verify_token
from authorization.policy import is_authorized
from backend.worker_client import WorkerError, call_worker
from observability.logging import configure_logging, log_request

# ---------------------------------------------------------------------------
# Logging — must be configured before any logger.getLogger() calls fire
# ---------------------------------------------------------------------------

configure_logging()
logger = logging.getLogger("mcp-presidio-sensitivity")

# ---------------------------------------------------------------------------
# Context variable — carries correlation_id from middleware into tool handler
# ---------------------------------------------------------------------------

_current_correlation_id: ContextVar[str] = ContextVar(
    "_current_correlation_id", default=""
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
    # Retrieve correlation_id injected by JWT middleware via context variable.
    # The middleware always sets this before the tool handler fires.
    # The fallback generates a new UUID if called outside the middleware context.
    correlation_id = _current_correlation_id.get(str(uuid.uuid4()))

    effective_workflow_id = workflow_id or correlation_id

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
        return result.model_dump(mode="json")
    except WorkerError as exc:
        # Raise as a plain exception — MCP SDK surfaces this as a tool error.
        # No payload content in exc.message (WorkerError never receives payload).
        raise RuntimeError(f"{exc.error_code}: {exc.message}") from exc


# ---------------------------------------------------------------------------
# Lifespan — starts the MCP StreamableHTTPSessionManager task group.
# mcp_app is created above so mcp._session_manager exists before this runs.
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(
        "MCP server starting",
        extra={
            "issuer_url": config.ISSUER_URL,
            "audience": config.AUDIENCE,
            "worker_url": config.WORKER_URL,
            "port": config.PORT,
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
# JWT authentication middleware
# ---------------------------------------------------------------------------


class JWTAuthMiddleware(BaseHTTPMiddleware):
    """
    Starlette middleware that validates Bearer JWTs on every protected request.

    Exempt paths (no auth required):
      - GET /health
      - GET /.well-known/oauth-protected-resource

    All other paths require a valid Bearer JWT.

    For MCP SDK paths the required scope is tools:classify.submit.

    Token validation runs BEFORE the request body is read (middleware fires
    before route handlers, satisfying the "401 before any business logic"
    requirement).
    """

    EXEMPT_PATHS: frozenset[str] = frozenset(
        {"/health", "/.well-known/oauth-protected-resource"}
    )

    async def dispatch(self, request: Request, call_next):
        start_time = time.monotonic()
        correlation_id = str(uuid.uuid4())

        # Inject correlation_id into context var for tool handler access
        token = _current_correlation_id.set(correlation_id)

        # Store on request state for use in route handlers
        request.state.correlation_id = correlation_id
        request.state.caller_subject = "anonymous"
        request.state.auth_decision = "pending"

        path = request.url.path

        # ------------------------------------------------------------------
        # Exempt paths — no auth required
        # ------------------------------------------------------------------
        if path in self.EXEMPT_PATHS:
            request.state.auth_decision = "exempt"
            response = await call_next(request)
            _current_correlation_id.reset(token)
            return response

        # ------------------------------------------------------------------
        # Token validation
        # ------------------------------------------------------------------
        try:
            claims = verify_token(request.headers.get("Authorization"))
        except TokenMissingError:
            duration_ms = (time.monotonic() - start_time) * 1000
            log_request(
                logger=logger,
                correlation_id=correlation_id,
                caller_subject="anonymous",
                tool=path,
                auth_decision="deny-401",
                duration_ms=duration_ms,
            )
            _current_correlation_id.reset(token)
            return build_401_response("invalid_token")
        except TokenInvalidError:
            duration_ms = (time.monotonic() - start_time) * 1000
            log_request(
                logger=logger,
                correlation_id=correlation_id,
                caller_subject="anonymous",
                tool=path,
                auth_decision="deny-401",
                duration_ms=duration_ms,
            )
            _current_correlation_id.reset(token)
            return build_401_response("invalid_token")

        caller_subject = claims.get("_subject", "unknown")
        scopes: frozenset[str] = claims.get("_scopes", frozenset())

        request.state.caller_subject = caller_subject
        request.state.claims = claims

        # ------------------------------------------------------------------
        # Scope authorization — classify tool requires tools:classify.submit
        # MCP SDK routes its tool calls through /mcp
        # ------------------------------------------------------------------
        # Determine which tool is being called for scope enforcement.
        # MCP routes all tool invocations through the /mcp path; the
        # required scope for all tool calls is tools:classify.submit.
        if path.startswith("/mcp"):
            authorized, required_scope = is_authorized(
                "classify_payload_sensitivity", scopes
            )
            if not authorized:
                duration_ms = (time.monotonic() - start_time) * 1000
                log_request(
                    logger=logger,
                    correlation_id=correlation_id,
                    caller_subject=caller_subject,
                    tool="classify_payload_sensitivity",
                    auth_decision="deny-403",
                    duration_ms=duration_ms,
                )
                _current_correlation_id.reset(token)
                return build_403_response(required_scope)

        request.state.auth_decision = "allow"

        # ------------------------------------------------------------------
        # Forward to route handler
        # ------------------------------------------------------------------
        response = await call_next(request)

        duration_ms = (time.monotonic() - start_time) * 1000
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
        return response


app.add_middleware(JWTAuthMiddleware)

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
# Mount MCP SDK application
# ---------------------------------------------------------------------------
# The FastMCP app is mounted at /.  The SDK's streamable HTTP transport
# registers its endpoint at /mcp, making the effective path /mcp.
# Explicit routes (/health, /.well-known/...) are defined above and matched
# first by FastAPI's router before the catch-all mount is reached.
# The JWT middleware intercepts all requests before the MCP SDK sees them.

app.mount("/", mcp_app)
