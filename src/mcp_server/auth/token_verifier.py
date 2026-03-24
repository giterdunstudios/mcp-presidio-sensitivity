"""
JWT validation with JWKS-backed key fetching via OIDC discovery.

Validation steps (in order):
  1. Extract Bearer token from Authorization header
  2. Resolve JWKS URI via OIDC discovery (TTL-cached)
  3. Fetch signing key from JWKS URI via PyJWKClient (TTL-cached)
  4. Decode and verify RS256 signature using fetched public key
  5. Verify `iss` matches issuer from OIDC discovery
  6. Verify `aud` contains configured AUDIENCE
  7. Verify `exp` is in the future
  8. Verify `nbf` if present (token not yet valid)

On any failure: raise TokenMissingError or TokenInvalidError.
Callers translate these to 401 responses — see auth/errors.py.

Security constraints:
  - JWKS endpoint is always derived from OIDC discovery, never hardcoded.
    Public keys are never hardcoded.
  - Algorithm is pinned to RS256.  `alg: none` and symmetric algorithms
    are explicitly rejected because algorithms=["RS256"] is set.
  - JWKS fetch errors surface as TokenInvalidError (not 5xx) so the
    server does not expose backend connectivity information to callers.
  - PyJWT is used in place of python-jose to avoid the transitive ecdsa
    dependency (CVE-2024-23342).
"""

from __future__ import annotations

import logging
from typing import Any

import jwt
from jwt import PyJWKClient

import config
from auth import discovery
from auth.claims import extract_scopes, extract_subject
from auth.errors import TokenInvalidError, TokenMissingError

logger = logging.getLogger("mcp-presidio-sensitivity.auth")

# ---------------------------------------------------------------------------
# JWKS client (lazily initialised on first verify_token call)
# ---------------------------------------------------------------------------
# The discovery module owns TTL caching of the OIDC config document.
# We create the PyJWKClient once with the discovered JWKS URI and cache it
# here.  If the discovery module refreshes (after TTL expiry) the URI is
# stable for the same issuer, so the existing client remains valid.

_jwks_client: PyJWKClient | None = None


def _get_jwks_client() -> PyJWKClient:
    """Return the module-level PyJWKClient, initialising it on first use."""
    global _jwks_client
    if _jwks_client is None:
        jwks_uri = discovery.get_jwks_uri()
        _jwks_client = PyJWKClient(
            jwks_uri,
            cache_keys=True,
            lifespan=config.JWKS_CACHE_TTL_SECONDS,
        )
    return _jwks_client


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

    try:
        signing_key = _get_jwks_client().get_signing_key_from_jwt(raw_token)
    except Exception as exc:
        # Catch all exceptions here: PyJWKClientError covers JWKS fetch
        # failures, but jwt.exceptions.DecodeError (raised on malformed
        # tokens) is not a subclass of PyJWKClientError and would otherwise
        # surface as a 500.
        logger.warning("JWKS key fetch failed: %s", type(exc).__name__)
        raise TokenInvalidError("Unable to fetch signing keys") from exc

    try:
        claims = jwt.decode(
            raw_token,
            signing_key.key,
            algorithms=["RS256"],
            audience=config.AUDIENCE or None,
            issuer=config.ISSUER_URL,
            options={
                "verify_exp": True,
                "verify_nbf": True,
                "verify_iss": True,
                "verify_aud": bool(config.AUDIENCE),
            },
        )
    except jwt.exceptions.InvalidTokenError as exc:
        logger.warning("JWT validation failed: %s", type(exc).__name__)
        raise TokenInvalidError("Token validation failed") from exc

    # Annotate claims with extracted scopes and subject for downstream use
    claims["_scopes"] = extract_scopes(claims)
    claims["_subject"] = extract_subject(claims)

    return claims
