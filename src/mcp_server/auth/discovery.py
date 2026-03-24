"""
OIDC discovery fetcher with TTL cache.

Fetches the OpenID Connect provider metadata from the well-known discovery
endpoint and caches the result for `config.JWKS_CACHE_TTL_SECONDS` seconds.

Interface:
    get_oidc_config() -> dict   — full OIDC configuration document
    get_jwks_uri()    -> str    — config["jwks_uri"]
    get_issuer()      -> str    — config["issuer"]

Security note:
    On any fetch failure the functions raise TokenInvalidError so the server
    fails closed — callers never see a 500 and no response body is logged.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

import httpx

import config
from auth.errors import TokenInvalidError

logger = logging.getLogger("mcp-presidio-sensitivity.auth")

# ---------------------------------------------------------------------------
# Module-level TTL cache (thread-safe via _lock)
# ---------------------------------------------------------------------------

_lock = threading.Lock()
_cached_config: dict[str, Any] | None = None
_cached_at: float = 0.0  # epoch seconds


def _is_cache_valid() -> bool:
    return (
        _cached_config is not None
        and (time.monotonic() - _cached_at) < config.JWKS_CACHE_TTL_SECONDS
    )


def get_oidc_config() -> dict[str, Any]:
    """
    Return the full OIDC provider metadata document, TTL-cached.

    Fetches from `config.OIDC_DISCOVERY_URL` on first call and after cache
    expiry.  Raises TokenInvalidError if the fetch fails.
    """
    global _cached_config, _cached_at

    with _lock:
        if _is_cache_valid():
            return _cached_config  # type: ignore[return-value]

        try:
            response = httpx.get(config.OIDC_DISCOVERY_URL, timeout=5.0)
            response.raise_for_status()
            data: dict[str, Any] = response.json()
        except Exception as exc:
            logger.warning(
                "OIDC discovery fetch failed: %s", type(exc).__name__
            )
            raise TokenInvalidError("Unable to fetch OIDC configuration") from exc

        _cached_config = data
        _cached_at = time.monotonic()
        return _cached_config


def get_jwks_uri() -> str:
    """Return the JWKS URI from the OIDC discovery document."""
    return get_oidc_config()["jwks_uri"]


def get_issuer() -> str:
    """Return the issuer from the OIDC discovery document."""
    return get_oidc_config()["issuer"]
