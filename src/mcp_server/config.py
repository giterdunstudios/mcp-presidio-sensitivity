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
# ---------------------------------------------------------------------------

# OIDC Discovery URL — used to derive JWKS URI and issuer at runtime.
# The discovery document is TTL-cached; JWKS URI and issuer are never
# hardcoded.
OIDC_DISCOVERY_URL: str = os.environ.get(
    "OIDC_DISCOVERY_URL",
    "http://keycloak.mcp-presidio.svc.cluster.local:8080/realms/mcp-local/.well-known/openid-configuration",
)

# Issuer URL — exposed in Protected Resource Metadata (/.well-known/…) and
# startup logging.  Token validation derives the issuer from OIDC discovery
# rather than this value; keeping it here avoids modifying main.py.
ISSUER_URL: str = os.environ.get(
    "ISSUER_URL",
    "http://keycloak.mcp-presidio.svc.cluster.local:8080/realms/mcp-local",
)

# Expected audience — the `aud` claim in incoming JWTs must include this value.
AUDIENCE: str = os.environ.get("AUDIENCE", "mcp-presidio-server")

# JWKS cache TTL in seconds (default: 5 minutes).
# Reused by the discovery module for its own TTL cache.
JWKS_CACHE_TTL_SECONDS: int = int(os.environ.get("JWKS_CACHE_TTL_SECONDS", 300))

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
WORKER_TIMEOUT_SECONDS: float = float(os.environ.get("WORKER_TIMEOUT_SECONDS", 30.0))

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
