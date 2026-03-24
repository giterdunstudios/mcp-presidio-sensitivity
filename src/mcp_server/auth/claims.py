"""
JWT claim extraction helpers.

Keycloak uses the standard OAuth 2.0 `scope` claim: a space-separated string
per RFC 6749.  This module normalises extraction so the rest of the codebase
works with a plain Python frozenset regardless of which claim name is present.

Supported claim shapes (in priority order):
  1. ``scope`` string  — Keycloak (primary): ``{"scope": "tools:classify.submit openid"}``
  2. ``scp`` array     — Hydra (fallback, defensive compatibility):
                         ``{"scp": ["tools:classify.submit"]}``
"""

from __future__ import annotations

from typing import Any


def extract_scopes(claims: dict[str, Any]) -> frozenset[str]:
    """
    Return the set of scopes from a decoded JWT payload.

    Keycloak encodes scopes in the standard ``scope`` string claim, e.g.:
        {"scope": "tools:classify.submit openid"}

    Falls back to the ``scp`` array claim for defensive Hydra compatibility
    if ``scope`` is absent.
    """
    # Primary: standard OAuth 2.0 `scope` string (Keycloak)
    scope_str = claims.get("scope")
    if scope_str is not None:
        if isinstance(scope_str, str) and scope_str:
            return frozenset(scope_str.split())
        # Defensive: scope present but not a usable string — fall through
        if scope_str:
            return frozenset({str(scope_str)})

    # Fallback: Hydra-style `scp` array
    scp = claims.get("scp")
    if scp is not None:
        if isinstance(scp, list):
            return frozenset(str(s) for s in scp)
        # Defensive: scp present but not a list — treat as single scope
        return frozenset({str(scp)})

    return frozenset()


def extract_subject(claims: dict[str, Any]) -> str:
    """Return the `sub` claim, or 'unknown' if absent."""
    return str(claims.get("sub", "unknown"))
