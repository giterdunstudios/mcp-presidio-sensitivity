"""
Unit tests for main.py — HTTP endpoints and classify_payload_sensitivity tool handler.

Cases:
  1.  GET /health → 200, {"status": "ok"}
  2.  GET /.well-known/oauth-protected-resource → 200
  3.  /.well-known/... → required RFC 9728 fields present
      (resource, authorization_servers, bearer_methods_supported, scopes_supported)
  4.  /.well-known/... → authorization_servers contains ISSUER_URL
  5.  /.well-known/... → scopes_supported contains tools:classify.submit
  6.  /.well-known/... → resource matches SERVER_RESOURCE_URL config value
  7.  write_audit_record has no 'content' parameter — structural guarantee
      that payload cannot reach the audit layer
  8.  classify_payload_sensitivity success → result dict returned
  9.  classify_payload_sensitivity success → audit record written
 10.  classify_payload_sensitivity success → SCAN_COMPLETIONS metric incremented
 11.  classify_payload_sensitivity WorkerError → RuntimeError raised
 12.  classify_payload_sensitivity WorkerError → error_code in RuntimeError message
 13.  classify_payload_sensitivity WorkerError → audit record written with error
 14.  classify_payload_sensitivity WorkerError → RuntimeError message contains no payload
 15.  RequestContextMiddleware → x-jwt-subject header extracted as caller_subject
 16.  RequestContextMiddleware → correlation_id generated as valid UUID per request
"""

from __future__ import annotations

import inspect
import logging
import uuid
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

import config
from backend.models import WorkerConfidenceSummary, WorkerScanResponse
from backend.worker_client import WorkerError
from audit.trail import write_audit_record
from main import app, classify_payload_sensitivity


# ---------------------------------------------------------------------------
# Module-level TestClient — lifespan (MCP session manager) runs once only
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


# ---------------------------------------------------------------------------
# Shared test data
# ---------------------------------------------------------------------------

SCAN_RESPONSE = WorkerScanResponse(
    scan_id=uuid.UUID("9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef"),
    status="ok",
    sensitivity_detected=True,
    max_severity_band="high",
    matched_categories=["financial_identifier"],
    entity_summary={"CREDIT_CARD": 1},
    decision="block",
    confidence_summary=WorkerConfidenceSummary(highest_score=1.0, findings_count=1),
    policy_profile="default",
    detector_version="presidio-analyzer==2.2.354",
    timestamp="2026-03-24T21:00:00Z",
)

WORKER_ERROR = WorkerError(error_code="SCAN_TIMEOUT", message="Worker timed out")

CLASSIFY_KWARGS = dict(
    content="test payload — never logged",
    content_type="text/plain",
)


# ---------------------------------------------------------------------------
# Case 1 — GET /health
# ---------------------------------------------------------------------------

def test_health_returns_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


# ---------------------------------------------------------------------------
# Cases 2–6 — GET /.well-known/oauth-protected-resource (RFC 9728)
# ---------------------------------------------------------------------------

def test_rfc9728_returns_200(client):
    assert client.get("/.well-known/oauth-protected-resource").status_code == 200


def test_rfc9728_required_fields_present(client):
    body = client.get("/.well-known/oauth-protected-resource").json()
    for field in ("resource", "authorization_servers", "bearer_methods_supported", "scopes_supported"):
        assert field in body, f"RFC 9728 required field '{field}' missing"


def test_rfc9728_authorization_servers_contains_issuer(client):
    body = client.get("/.well-known/oauth-protected-resource").json()
    assert config.ISSUER_URL in body["authorization_servers"]


def test_rfc9728_scopes_supported_contains_classify(client):
    body = client.get("/.well-known/oauth-protected-resource").json()
    assert "tools:classify.submit" in body["scopes_supported"]


def test_rfc9728_resource_matches_server_resource_url(client):
    body = client.get("/.well-known/oauth-protected-resource").json()
    assert body["resource"] == config.SERVER_RESOURCE_URL


# ---------------------------------------------------------------------------
# Case 7 — payload isolation: write_audit_record has no 'content' parameter
# ---------------------------------------------------------------------------

def test_audit_record_has_no_content_parameter():
    sig = inspect.signature(write_audit_record)
    assert "content" not in sig.parameters, (
        "write_audit_record must never accept a 'content' parameter"
    )


# ---------------------------------------------------------------------------
# Cases 8–10 — classify_payload_sensitivity success path
# ---------------------------------------------------------------------------

async def test_classify_success_returns_result_dict():
    with patch("main.call_worker", new=AsyncMock(return_value=SCAN_RESPONSE)):
        result = await classify_payload_sensitivity(**CLASSIFY_KWARGS)
    assert result["decision"] == "block"
    assert result["scan_id"] == "9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef"
    assert "sensitivity_detected" in result


async def test_classify_success_writes_audit_record():
    records = []

    class Cap(logging.Handler):
        def emit(self, r):
            records.append(r)

    logger = logging.getLogger("mcp-presidio-sensitivity.audit")
    h = Cap()
    logger.addHandler(h)
    try:
        with patch("main.call_worker", new=AsyncMock(return_value=SCAN_RESPONSE)):
            await classify_payload_sensitivity(**CLASSIFY_KWARGS)
    finally:
        logger.removeHandler(h)

    assert len(records) == 1
    assert records[0].__dict__["audit_event"] == "scan_completed"


async def test_classify_success_increments_scan_completions():
    from observability.metrics import SCAN_COMPLETIONS
    labels = dict(decision="block", max_severity_band="high")
    before = SCAN_COMPLETIONS.labels(**labels)._value.get()

    with patch("main.call_worker", new=AsyncMock(return_value=SCAN_RESPONSE)):
        await classify_payload_sensitivity(**CLASSIFY_KWARGS)

    assert SCAN_COMPLETIONS.labels(**labels)._value.get() > before


# ---------------------------------------------------------------------------
# Cases 11–14 — classify_payload_sensitivity WorkerError path
# ---------------------------------------------------------------------------

async def test_classify_worker_error_raises_runtime_error():
    with patch("main.call_worker", new=AsyncMock(side_effect=WORKER_ERROR)):
        with pytest.raises(RuntimeError):
            await classify_payload_sensitivity(**CLASSIFY_KWARGS)


async def test_classify_worker_error_message_contains_error_code():
    with patch("main.call_worker", new=AsyncMock(side_effect=WORKER_ERROR)):
        with pytest.raises(RuntimeError, match="SCAN_TIMEOUT"):
            await classify_payload_sensitivity(**CLASSIFY_KWARGS)


async def test_classify_worker_error_writes_audit_record():
    records = []

    class Cap(logging.Handler):
        def emit(self, r):
            records.append(r)

    logger = logging.getLogger("mcp-presidio-sensitivity.audit")
    h = Cap()
    logger.addHandler(h)
    try:
        with patch("main.call_worker", new=AsyncMock(side_effect=WORKER_ERROR)):
            with pytest.raises(RuntimeError):
                await classify_payload_sensitivity(**CLASSIFY_KWARGS)
    finally:
        logger.removeHandler(h)

    assert len(records) == 1
    assert records[0].__dict__["decision"] == "error"
    assert records[0].__dict__["error_code"] == "SCAN_TIMEOUT"


async def test_classify_worker_error_message_contains_no_payload():
    with patch("main.call_worker", new=AsyncMock(side_effect=WORKER_ERROR)):
        with pytest.raises(RuntimeError) as exc_info:
            await classify_payload_sensitivity(**CLASSIFY_KWARGS)
    assert CLASSIFY_KWARGS["content"] not in str(exc_info.value)


# ---------------------------------------------------------------------------
# Cases 15–16 — RequestContextMiddleware
# ---------------------------------------------------------------------------

def test_middleware_extracts_x_jwt_subject(client, caplog):
    with caplog.at_level(logging.INFO, logger="mcp-presidio-sensitivity"):
        client.get("/health", headers={"x-jwt-subject": "svc-account-99"})

    assert any(
        r.__dict__.get("caller_subject") == "svc-account-99"
        for r in caplog.records
    ), "caller_subject 'svc-account-99' not found in log records"


def test_middleware_generates_uuid_correlation_id(client, caplog):
    with caplog.at_level(logging.INFO, logger="mcp-presidio-sensitivity"):
        client.get("/health")

    cids = [r.__dict__.get("correlation_id") for r in caplog.records if r.__dict__.get("correlation_id")]
    assert cids, "No correlation_id found in log records"
    for cid in cids:
        uuid.UUID(cid)  # raises ValueError if not a valid UUID
