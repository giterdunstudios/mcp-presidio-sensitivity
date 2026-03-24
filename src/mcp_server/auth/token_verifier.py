"""
JWT validation with JWKS-backed key fetching and in-memory key cache.

Validation steps (in order):
  1. Extract Bearer token from Authorization header
  2. Fetch signing keys from JWKS URI (with TTL cache)
  3. Decode and verify RS256 signature using fetched public key
  4. Verify `iss` matches configured ISSUER_URL
  5. Verify `aud` contains configured AUDIENCE
  6. Verify `exp` is in the future
  7. Verify `nbf` if present (token not yet valid)

On any failure: raise TokenMissingError or TokenInvalidError.
Callers translate these to 401 responses — see auth/errors.py.

Security constraints:
  - JWKS endpoint is always fetched from the configured issuer URI.
    Public keys are never hardcoded.
  - Algorithm is pinned to RS256.  `alg: none` and symmetric algorithms
    are explicitly rejected by the jose library when algorithms= is set.
  - JWKS fetch errors surface as TokenInvalidError (not 5xx) so the
    server does not expose backend connectivity information to callers.
"""

from __future__ import annotations

import logging
import time
from typing import Any

import httpx
from jose import JWTError, jwk, jwt
from jose.utils import base64url_decode

import config
from auth.claims import extract_scopes, extract_subject
from auth.errors import TokenInvalidError, TokenMissingError

logger = logging.getLogger("mcp-server.auth")

# ---------------------------------------------------------------------------
# JWKS cache
# ---------------------------------------------------------------------------

_jwks_cache: dict[str, Any] = {}
_jwks_fetched_at: float = 0.0


def _fetch_jwks() -> dict[str, Any]:
    """
    Fetch the JWKS document from the configured URI.

    Returns the parsed JSON object.  Raises TokenInvalidError if the
    fetch fails — this prevents the server from returning 5xx on auth paths.
    """
    try:
        response = httpx.get(config.JWKS_URI, timeout=5.0)
        response.raise_for_status()
        return response.json()
    except Exception as exc:
        logger.warning("JWKS fetch failed: %s", type(exc).__name__)
        raise TokenInvalidError("Unable to fetch signing keys") from exc


def _get_jwks() -> dict[str, Any]:
    """
    Return the cached JWKS document, refreshing if the TTL has expired.

    Cache TTL is controlled by config.JWKS_CACHE_TTL_SECONDS (default 300s).
    """
    global _jwks_cache, _jwks_fetched_at

    now = time.monotonic()
    if not _jwks_cache or (now - _jwks_fetched_at) > config.JWKS_CACHE_TTL_SECONDS:
        _jwks_cache = _fetch_jwks()
        _jwks_fetched_at = now

    return _jwks_cache


# ---------------------------------------------------------------------------
# Token extraction
# ---------------------------------------------------------------------------


def _extract_bearer_token(authorization_header: str | None) -> str:
    """
    Parse the Bearer token from an Authorization header value.

    Raises TokenMissingError if absent or malformed.
    """
    if not authorization_header:
        raise TokenMissingError("Authorization header is absent")

    parts = authorization_header.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise TokenMissingError("Authorization header is not a Bearer token")

    return parts[1]


# ---------------------------------------------------------------------------
# JWT verification
# ---------------------------------------------------------------------------


def verify_token(authorization_header: str | None) -> dict[str, Any]:
    """
    Extract, decode, and validate a Bearer JWT.

    Returns the decoded claims dict on success.
    Raises TokenMissingError or TokenInvalidError on any failure.

    The returned claims dict includes a pre-extracted `_scopes` key
    (frozenset) and `_subject` key (str) for convenience.
    """
    raw_token = _extract_bearer_token(authorization_header)

    jwks_doc = _get_jwks()

    try:
        claims = jwt.decode(
            raw_token,
            jwks_doc,
            algorithms=["RS256"],
            audience=config.AUDIENCE,
            issuer=config.ISSUER_URL,
            options={
                "verify_exp": True,
                "verify_nbf": True,
                "verify_iss": True,
                "verify_aud": True,
                "verify_at_hash": False,
            },
        )
    except JWTError as exc:
        logger.warning("JWT validation failed: %s", type(exc).__name__)
        raise TokenInvalidError("Token validation failed") from exc

    # Annotate claims with extracted scopes and subject for downstream use
    claims["_scopes"] = extract_scopes(claims)
    claims["_subject"] = extract_subject(claims)

    return claims
