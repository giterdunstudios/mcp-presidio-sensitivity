"""
Shared test fixtures and environment setup for the MCP server test suite.

Environment variables must be set before any app module is imported.
All variables are set at module level here — conftest.py is loaded by
pytest before any test module is collected.
"""

import os
import sys

# ---------------------------------------------------------------------------
# Environment — set before any app import
# ---------------------------------------------------------------------------

# Point at a non-existent worker; individual tests mock call_worker directly
os.environ.setdefault("WORKER_URL", "http://test-worker:8080")
os.environ.setdefault("WORKER_TIMEOUT_SECONDS", "10.0")

# ISSUER_URL is used by the RFC 9728 discovery endpoint
os.environ.setdefault("ISSUER_URL", "http://test-keycloak/realms/test")

# Note: OIDC_DISCOVERY_URL, AUDIENCE, JWKS_CACHE_TTL_SECONDS removed —
# JWT validation is now handled by Istio/Envoy sidecar (DEC-003).
# Note: RATE_LIMIT_ENABLED, RATE_LIMIT_PER_MINUTE removed —
# rate limiting moves to Envoy rate limit filter (DEC-003).

# Service identity
os.environ.setdefault("SERVICE_VERSION", "0.0.0-test")
os.environ.setdefault("ENVIRONMENT", "test")

# Ensure the mcp_server source is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------

import pytest
from unittest.mock import AsyncMock, patch
from uuid import UUID


def make_valid_worker_response() -> dict:
    """Return a dict matching WorkerScanResponse schema."""
    return {
        "scan_id": "9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef",
        "status": "ok",
        "sensitivity_detected": True,
        "max_severity_band": "high",
        "matched_categories": ["financial_identifier"],
        "entity_summary": {"CREDIT_CARD": 1},
        "decision": "block",
        "confidence_summary": {"highest_score": 1.0, "findings_count": 1},
        "policy_profile": "default",
        "detector_version": "presidio-analyzer==2.2.354",
        "timestamp": "2026-03-24T21:00:00Z",
    }


def make_claims(subject: str = "test-subject-uuid") -> dict:
    """Return a JWT claims dict as returned by verify_token."""
    return {
        "_subject": subject,
        "_scopes": frozenset({"tools:classify.submit"}),
    }


@pytest.fixture
def valid_worker_response():
    return make_valid_worker_response()


@pytest.fixture
def auth_headers():
    """Authorization header that will be accepted by the mocked verify_token."""
    return {
        "Authorization": "Bearer test-valid-token",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
