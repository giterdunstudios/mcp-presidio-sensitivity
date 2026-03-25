"""
Tests for backend/worker_client.py

Covers use cases 1–10 from the Stream 3 pre-implementation checklist:

  1.  Successful 200 response            → WorkerScanResponse returned
  2.  httpx.TimeoutException             → WorkerError(error_code="SCAN_TIMEOUT")
  3.  httpx.ConnectError                 → WorkerError(error_code="SCAN_FAILED"), not SCAN_TIMEOUT
  4.  Worker returns 413                 → WorkerError(error_code="PAYLOAD_TOO_LARGE")
  5.  Worker returns 415                 → WorkerError(error_code="UNSUPPORTED_CONTENT_TYPE")
  6.  Worker returns 400                 → WorkerError(error_code="INVALID_REQUEST")
  7.  Worker returns 500                 → WorkerError(error_code="SCAN_FAILED")
  8.  Worker 200 but unparseable body    → WorkerError(error_code="SCAN_FAILED")
  9.  httpx.AsyncClient receives correct timeout value from config
 10.  Default WORKER_TIMEOUT_SECONDS is 10.0
"""

import pytest
import httpx
from unittest.mock import AsyncMock, MagicMock, patch, call

from backend.worker_client import call_worker, WorkerError
from tests.conftest import make_valid_worker_response

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_CALL_KWARGS = dict(
    content="test payload",
    content_type="text/plain",
    correlation_id="test-correlation-id",
)


def _mock_response(status_code: int, body: dict) -> MagicMock:
    r = MagicMock()
    r.status_code = status_code
    r.json.return_value = body
    return r


def _patch_httpx_post(*, side_effect=None, return_value=None):
    """
    Patch httpx.AsyncClient so that .post() either raises or returns a mock response.
    Returns (patcher, mock_client).
    """
    mock_client = AsyncMock()
    if side_effect is not None:
        mock_client.post.side_effect = side_effect
    else:
        mock_client.post.return_value = return_value

    ctx = MagicMock()
    ctx.__aenter__ = AsyncMock(return_value=mock_client)
    ctx.__aexit__ = AsyncMock(return_value=False)

    return patch("httpx.AsyncClient", return_value=ctx), mock_client


# ---------------------------------------------------------------------------
# Use case 1 — success
# ---------------------------------------------------------------------------

async def test_success_returns_scan_response():
    """Case 1: 200 OK with valid body → WorkerScanResponse, no exception."""
    patcher, _ = _patch_httpx_post(return_value=_mock_response(200, make_valid_worker_response()))
    with patcher:
        result = await call_worker(**_CALL_KWARGS)
    assert result.decision == "block"
    assert str(result.scan_id) == "9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef"
    assert result.confidence_summary.findings_count == 1


# ---------------------------------------------------------------------------
# Use case 2 — timeout → SCAN_TIMEOUT (the renamed error code)
# ---------------------------------------------------------------------------

async def test_timeout_raises_scan_timeout():
    """Case 2: TimeoutException must produce SCAN_TIMEOUT, not SCAN_FAILED."""
    patcher, _ = _patch_httpx_post(side_effect=httpx.TimeoutException("timed out"))
    with patcher:
        with pytest.raises(WorkerError) as exc_info:
            await call_worker(**_CALL_KWARGS)
    assert exc_info.value.error_code == "SCAN_TIMEOUT"


# ---------------------------------------------------------------------------
# Use case 3 — connection refused → SCAN_FAILED (not SCAN_TIMEOUT)
# ---------------------------------------------------------------------------

async def test_connect_error_raises_scan_failed_not_scan_timeout():
    """Case 3: Connection refused is SCAN_FAILED — distinct from a timeout."""
    patcher, _ = _patch_httpx_post(side_effect=httpx.ConnectError("connection refused"))
    with patcher:
        with pytest.raises(WorkerError) as exc_info:
            await call_worker(**_CALL_KWARGS)
    assert exc_info.value.error_code == "SCAN_FAILED"
    # Explicitly confirm it is NOT SCAN_TIMEOUT
    assert exc_info.value.error_code != "SCAN_TIMEOUT"


# ---------------------------------------------------------------------------
# Use cases 4–7 — HTTP error codes
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("status_code,expected_error_code", [
    (413, "PAYLOAD_TOO_LARGE"),       # case 4
    (415, "UNSUPPORTED_CONTENT_TYPE"),# case 5
    (400, "INVALID_REQUEST"),          # case 6
    (500, "SCAN_FAILED"),              # case 7
])
async def test_http_error_codes(status_code, expected_error_code):
    """Cases 4–7: Worker HTTP errors map to the correct WorkerError.error_code."""
    patcher, _ = _patch_httpx_post(return_value=_mock_response(status_code, {}))
    with patcher:
        with pytest.raises(WorkerError) as exc_info:
            await call_worker(**_CALL_KWARGS)
    assert exc_info.value.error_code == expected_error_code


# ---------------------------------------------------------------------------
# Use case 8 — 200 but invalid response schema → SCAN_FAILED
# ---------------------------------------------------------------------------

async def test_unparseable_response_raises_scan_failed():
    """Case 8: A 200 response with an invalid body raises SCAN_FAILED."""
    patcher, _ = _patch_httpx_post(return_value=_mock_response(200, {"unexpected": "schema"}))
    with patcher:
        with pytest.raises(WorkerError) as exc_info:
            await call_worker(**_CALL_KWARGS)
    assert exc_info.value.error_code == "SCAN_FAILED"


# ---------------------------------------------------------------------------
# Use case 9 — timeout value passed to httpx.AsyncClient
# ---------------------------------------------------------------------------

async def test_timeout_value_passed_to_httpx_client():
    """Case 9: httpx.AsyncClient is constructed with the configured timeout."""
    import config

    with patch("httpx.AsyncClient") as MockClient:
        ctx = MagicMock()
        mock_client = AsyncMock()
        mock_client.post.side_effect = httpx.TimeoutException("timed out")
        ctx.__aenter__ = AsyncMock(return_value=mock_client)
        ctx.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = ctx

        with pytest.raises(WorkerError):
            await call_worker(**_CALL_KWARGS)

        MockClient.assert_called_once_with(timeout=config.WORKER_TIMEOUT_SECONDS)


# ---------------------------------------------------------------------------
# Use case 10 — default timeout is 10.0 seconds
# ---------------------------------------------------------------------------

def test_default_timeout_is_10_seconds():
    """Case 10: WORKER_TIMEOUT_SECONDS default is 10.0, not 30.0."""
    import importlib
    import config as cfg_module

    # Read the module-level default without relying on the env var set in conftest
    # by temporarily removing the env var override
    import os
    original = os.environ.pop("WORKER_TIMEOUT_SECONDS", None)
    try:
        importlib.reload(cfg_module)
        assert cfg_module.WORKER_TIMEOUT_SECONDS == 10.0
    finally:
        if original is not None:
            os.environ["WORKER_TIMEOUT_SECONDS"] = original
        importlib.reload(cfg_module)
