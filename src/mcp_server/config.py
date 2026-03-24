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
# OAuth / JWKS configuration
# ---------------------------------------------------------------------------

# Issuer URL — the `iss` claim in incoming JWTs must match this value exactly.
ISSUER_URL: str = os.environ.get(
    "ISSUER_URL",
    "http://hydra.mcp-presidio.svc.cluster.local:4444",
)

# JWKS URI — used to fetch the Authorization Server's public signing keys.
JWKS_URI: str = os.environ.get(
    "JWKS_URI",
    "http://hydra.mcp-presidio.svc.cluster.local:4444/.well-known/jwks.json",
)

# Expected audience — the `aud` claim in incoming JWTs must include this value.
AUDIENCE: str = os.environ.get("AUDIENCE", "mcp-presidio-server")

# JWKS cache TTL in seconds (default: 5 minutes)
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
    f"http://mcp-server.mcp-presidio.svc.cluster.local:{PORT}",
)
