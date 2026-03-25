"""
Tests for rate limiting middleware — Stream 3 pre-implementation checklist cases 21–30.

These tests are written BEFORE SlowAPI is implemented. They will fail until the
implementation is in place. They also serve as the middleware spike validation:
if the rate limiter does not intercept requests to the mounted /mcp sub-app,
case 28 will fail regardless of implementation correctness elsewhere.

  21. Request under per-minute limit     → not 429
  22. Request exceeding limit            → 429, Retry-After: 60, error_code RATE_LIMITED
  23. GET /health                        → never 429 regardless of volume
  24. GET /.well-known/...               → never 429 regardless of volume
  25. Two callers, different subjects    → independent counters
  26. RATE_LIMIT_ENABLED=false           → no 429 regardless of volume
  27. 429 body contains only error_code and message — no payload data
  28. Rate limit fires on /mcp       → sub-app path is intercepted (spike validation)
  29. Rate limit key is caller_subject   → proven by case 25 (requests share same IP)
  30. WARNING log emitted on breach      → caller_subject in log record, no payload

Setup:
  - RATE_LIMIT_PER_MINUTE=3 (set in conftest.py — limit is hit after 3 requests)
  - verify_token mocked to return controlled claims without hitting Keycloak
  - call_worker mocked to return a valid scan response without hitting the worker
  - All requests originate from the same source IP (TestClient loopback) — proves
    case 29: if key were IP-based, case 25 would fail because counter would be shared
"""

import json
import logging
import os
import pytest
import httpx
from unittest.mock import AsyncMock, patch, MagicMock

from tests.conftest import make_claims, make_valid_worker_response

# ---------------------------------------------------------------------------
# App import — must come after conftest sets env vars
# ---------------------------------------------------------------------------

from main import app  # noqa: E402  (env vars set in conftest before this import)

# ---------------------------------------------------------------------------
# MCP initialize payload — opens a session, required before tool calls
# ---------------------------------------------------------------------------

_INIT_PAYLOAD = json.dumps({
    "jsonrpc": "2.0",
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "1.0"},
    },
    "id": 1,
})

_MCP_HEADERS = {
    "Authorization": "Bearer test-valid-token",
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


def _make_verify_token_mock(subject: str = "test-subject"):
    """Return a mock for verify_token that accepts any Bearer token."""
    def _verify(auth_header):
        return make_claims(subject=subject)
    return _verify


async def _send_n_requests(client, n: int, headers: dict = None) -> list[int]:
    """Send n POST requests to /mcp and return their status codes."""
    h = headers or _MCP_HEADERS
    codes = []
    for _ in range(n):
        r = await client.post("/mcp", content=_INIT_PAYLOAD, headers=h)
        codes.append(r.status_code)
    return codes


# ---------------------------------------------------------------------------
# Shared test context manager: mock verify_token + call_worker
# ---------------------------------------------------------------------------

from contextlib import asynccontextmanager
from backend.worker_client import WorkerScanResponse as _WSR


def _worker_response_mock():
    from backend.models import WorkerScanResponse, WorkerConfidenceSummary
    return WorkerScanResponse(
        **make_valid_worker_response()
    )


# ---------------------------------------------------------------------------
# Use case 21 — under limit → not 429
# ---------------------------------------------------------------------------

async def test_under_limit_not_rate_limited():
    """Case 21: Requests within the limit are not rejected with 429."""
    with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock()):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            # Send fewer requests than the limit (limit=3, send 2)
            codes = await _send_n_requests(client, 2)
    assert 429 not in codes, f"Got unexpected 429 within limit: {codes}"


# ---------------------------------------------------------------------------
# Use case 22 — over limit → 429 with correct structure
# ---------------------------------------------------------------------------

async def test_over_limit_returns_429():
    """Case 22: The (limit+1)th request returns 429."""
    with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock()):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            # Exhaust the limit (3 requests), then send one more
            await _send_n_requests(client, 3)
            response = await client.post("/mcp", content=_INIT_PAYLOAD, headers=_MCP_HEADERS)

    assert response.status_code == 429


# ---------------------------------------------------------------------------
# Use case 22 (continued) — 429 includes Retry-After header
# ---------------------------------------------------------------------------

async def test_over_limit_has_retry_after_header():
    """Case 22: 429 response includes Retry-After header."""
    with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock()):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            await _send_n_requests(client, 3)
            response = await client.post("/mcp", content=_INIT_PAYLOAD, headers=_MCP_HEADERS)

    assert "retry-after" in response.headers


# ---------------------------------------------------------------------------
# Use case 23 — GET /health never 429
# ---------------------------------------------------------------------------

async def test_health_endpoint_never_rate_limited():
    """Case 23: /health is exempt from rate limiting regardless of volume."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        # Send well above any rate limit
        codes = [
            (await client.get("/health")).status_code
            for _ in range(20)
        ]
    assert 429 not in codes, "Health endpoint must never be rate-limited"
    assert all(c == 200 for c in codes)


# ---------------------------------------------------------------------------
# Use case 24 — GET /.well-known/... never 429
# ---------------------------------------------------------------------------

async def test_well_known_endpoint_never_rate_limited():
    """Case 24: /.well-known/oauth-protected-resource is exempt from rate limiting."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        codes = [
            (await client.get("/.well-known/oauth-protected-resource")).status_code
            for _ in range(20)
        ]
    assert 429 not in codes, "Well-known endpoint must never be rate-limited"


# ---------------------------------------------------------------------------
# Use case 25 & 29 — two callers have independent counters (proves key=caller_subject)
# ---------------------------------------------------------------------------

async def test_two_callers_have_independent_counters():
    """
    Cases 25 & 29: Two different caller_subject values have independent rate limit counters.

    All requests share the same loopback IP. If the key were IP-based, caller B would
    be immediately rate-limited after caller A exhausts the shared counter.
    This test passes only if the key is caller_subject, not client IP.
    """
    def _verify(auth_header):
        # Map token value to different subjects
        if "caller-a" in auth_header:
            return make_claims(subject="subject-caller-a")
        return make_claims(subject="subject-caller-b")

    headers_a = {**_MCP_HEADERS, "Authorization": "Bearer caller-a-token"}
    headers_b = {**_MCP_HEADERS, "Authorization": "Bearer caller-b-token"}

    with patch("auth.token_verifier.verify_token", side_effect=_verify):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            # Exhaust caller A's limit
            await _send_n_requests(client, 3, headers=headers_a)
            last_a = (await client.post("/mcp", content=_INIT_PAYLOAD, headers=headers_a)).status_code

            # Caller B's first request should not be rate-limited
            first_b = (await client.post("/mcp", content=_INIT_PAYLOAD, headers=headers_b)).status_code

    assert last_a == 429, "Caller A should be rate-limited after exhausting their quota"
    assert first_b != 429, (
        f"Caller B was rate-limited (got {first_b}) — "
        "this means the rate limit key is IP-based, not caller_subject-based"
    )


# ---------------------------------------------------------------------------
# Use case 26 — RATE_LIMIT_ENABLED=false disables limiting
# ---------------------------------------------------------------------------

async def test_rate_limit_disabled_no_429():
    """Case 26: When RATE_LIMIT_ENABLED=false, no request returns 429."""
    import importlib
    import main as main_module

    original = os.environ.get("RATE_LIMIT_ENABLED")
    os.environ["RATE_LIMIT_ENABLED"] = "false"
    importlib.reload(main_module)

    try:
        with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock()):
            transport = httpx.ASGITransport(app=main_module.app)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
                codes = await _send_n_requests(client, 10)
        assert 429 not in codes, f"Got 429 when rate limiting is disabled: {codes}"
    finally:
        if original is not None:
            os.environ["RATE_LIMIT_ENABLED"] = original
        else:
            os.environ.pop("RATE_LIMIT_ENABLED", None)
        importlib.reload(main_module)


# ---------------------------------------------------------------------------
# Use case 27 — 429 body is safe (no payload, no stack trace)
# ---------------------------------------------------------------------------

async def test_429_body_is_safe():
    """Case 27: 429 body contains only error_code and message — no payload or stack trace."""
    with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock()):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            await _send_n_requests(client, 3)
            response = await client.post("/mcp", content=_INIT_PAYLOAD, headers=_MCP_HEADERS)

    assert response.status_code == 429
    body = response.json()
    assert body.get("error_code") == "RATE_LIMITED"
    assert "message" in body
    # Must not contain dangerous fields
    for forbidden in ("traceback", "detail", "content", "payload", "text"):
        assert forbidden not in body, f"429 body contains forbidden field: {forbidden}"


# ---------------------------------------------------------------------------
# Use case 28 — rate limit fires on /mcp (mounted sub-app) — SPIKE VALIDATION
# ---------------------------------------------------------------------------

async def test_rate_limit_intercepts_mounted_subapp_path():
    """
    Case 28 (spike): Rate limiting fires on /mcp — the FastMCP mounted sub-app path.

    If SlowAPIMiddleware only intercepts native FastAPI routes and not mounted sub-apps,
    this test will fail because the 4th request will not be 429.

    This is the primary spike validation: proves SlowAPI middleware is applied at the
    Starlette root level, not just to the FastAPI router.
    """
    with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock()):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            codes = await _send_n_requests(client, 3)
            fourth = (await client.post("/mcp", content=_INIT_PAYLOAD, headers=_MCP_HEADERS)).status_code

    assert fourth == 429, (
        f"Got {fourth} instead of 429 on /mcp after limit exhausted. "
        "SlowAPI middleware may not be intercepting the mounted sub-app path."
    )


# ---------------------------------------------------------------------------
# Use case 30 — WARNING log emitted on rate limit breach
# ---------------------------------------------------------------------------

async def test_rate_limit_breach_logs_warning(caplog):
    """Case 30: A rate limit breach emits a WARNING log record with caller_subject."""
    with patch("auth.token_verifier.verify_token", side_effect=_make_verify_token_mock(subject="auditable-subject")):
        with caplog.at_level(logging.WARNING):
            transport = httpx.ASGITransport(app=app)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
                await _send_n_requests(client, 3)
                await client.post("/mcp", content=_INIT_PAYLOAD, headers=_MCP_HEADERS)

    warning_records = [r for r in caplog.records if r.levelno >= logging.WARNING]
    rate_limit_records = [r for r in warning_records if "rate" in r.getMessage().lower() or
                          getattr(r, "error_code", "") == "RATE_LIMITED"]
    assert rate_limit_records, "No WARNING log record emitted on rate limit breach"

    record = rate_limit_records[0]
    # caller_subject must be present — must not log payload or content
    assert hasattr(record, "caller_subject") or "caller_subject" in record.__dict__, \
        "WARNING log missing caller_subject field"
    assert not hasattr(record, "content"), "Rate limit log must not contain payload content"
