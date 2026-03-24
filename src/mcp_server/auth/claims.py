"""
JWT claim extraction helpers.

Key Hydra-specific detail:
  Hydra uses `scp` as the scope claim name, not the OAuth 2.0 standard
  `scope` string.  The `scp` claim is a JSON array of scope strings.
  This module normalises the extraction so the rest of the codebase
  works with a plain Python set regardless of claim name.

See token-validation-report.md Step 3 for the confirmed claim structure.
"""

from __future__ import annotations

from typing import Any


def extract_scopes(claims: dict[str, Any]) -> frozenset[str]:
    """
    Return the set of scopes from a decoded JWT payload.

    Hydra encodes scopes in `scp` as a list, e.g.:
        {"scp": ["tools:classify.submit"]}

    Falls back to the standard `scope` string claim if `scp` is absent,
    splitting on whitespace per RFC 6749.
    """
    # Hydra primary claim
    scp = claims.get("scp")
    if scp is not None:
        if isinstance(scp, list):
            return frozenset(str(s) for s in scp)
        # Defensive: scp present but not a list — treat as single scope
        return frozenset({str(scp)})

    # Fallback: standard `scope` string
    scope_str = claims.get("scope", "")
    if scope_str:
        return frozenset(scope_str.split())

    return frozenset()


def extract_subject(claims: dict[str, Any]) -> str:
    """Return the `sub` claim, or 'unknown' if absent."""
    return str(claims.get("sub", "unknown"))
