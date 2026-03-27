"""
MCP server configuration constants.

All tunable values are read from environment variables at startup.
Defaults mirror the Helm values.yaml specification.

Security note:
  No secrets are hardcoded here.  All sensitive values (client credentials,
  keys) must be injected via environment variables at runtime.
"""

from __future__ import annotations

import os

# ---------------------------------------------------------------------------
# OAuth / OIDC configuration
#
# JWT validation is handled by the Istio/Envoy sidecar (DEC-003).
# ISSUER_URL is retained for the RFC 9728 Protected Resource Metadata endpoint.
# ---------------------------------------------------------------------------

# Issuer URL — exposed in Protected Resource Metadata (/.well-known/…) and
# startup logging. Envoy's RequestAuthentication CRD also references this.
ISSUER_URL: str = os.environ.get(
    "ISSUER_URL",
    "http://keycloak.mcp-presidio.svc.cluster.local:8080/realms/mcp-local",
)

# ---------------------------------------------------------------------------
# Presidio worker backend
# ---------------------------------------------------------------------------

# Worker internal URL (Kubernetes cluster DNS)
WORKER_URL: str = os.environ.get(
    "WORKER_URL",
    "http://presidio-worker.mcp-presidio.svc.cluster.local:8080",
)

# Maximum payload size enforced at the MCP layer (1 MiB — matches worker)
MAX_PAYLOAD_BYTES: int = int(os.environ.get("MAX_PAYLOAD_BYTES", 1_048_576))

# HTTP timeout when calling the Presidio worker (seconds)
WORKER_TIMEOUT_SECONDS: float = float(os.environ.get("WORKER_TIMEOUT_SECONDS", 10.0))

# ---------------------------------------------------------------------------
# Service identity (used in structured log records)
# ---------------------------------------------------------------------------

SERVICE_VERSION: str = os.environ.get("SERVICE_VERSION", "0.1.0")
ENVIRONMENT: str = os.environ.get("ENVIRONMENT", "production")

# ---------------------------------------------------------------------------
# Server configuration
# ---------------------------------------------------------------------------

# Port the MCP server listens on
PORT: int = int(os.environ.get("PORT", 8000))

# Server resource URL — used in Protected Resource Metadata
SERVER_RESOURCE_URL: str = os.environ.get(
    "SERVER_RESOURCE_URL",
    f"http://mcp-presidio-sensitivity.mcp-presidio.svc.cluster.local:{PORT}",
)

