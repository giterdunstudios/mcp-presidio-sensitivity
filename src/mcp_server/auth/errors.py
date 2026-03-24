"""
Auth error types and HTTP response builders.

Returns RFC 6750-compliant WWW-Authenticate challenges on 401.
Returns RFC 6749-style error bodies on 403.

Security note:
  Error responses never include token content, payload data,
  or internal exception detail beyond what is defined here.
"""

from __future__ import annotations

from fastapi import status
from fastapi.responses import JSONResponse


# ---------------------------------------------------------------------------
# Exception types
# ---------------------------------------------------------------------------


class TokenMissingError(Exception):
    """No Authorization header was present on the request."""


class TokenInvalidError(Exception):
    """Token present but failed signature/issuer/audience/expiry validation."""


class InsufficientScopeError(Exception):
    """Token is valid but does not carry the required scope."""


# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------


def build_401_response(reason: str = "invalid_token") -> JSONResponse:
    """
    Build a 401 Unauthorized response with a WWW-Authenticate Bearer challenge.

    RFC 6750 §3 requires the WWW-Authenticate header on 401.
    The `error` parameter is included per RFC 6750 §3.1.
    """
    return JSONResponse(
        status_code=status.HTTP_401_UNAUTHORIZED,
        content={"error": reason, "error_description": "Token validation failed."},
        headers={
            "WWW-Authenticate": (
                'Bearer realm="mcp-presidio-server",'
                f' error="{reason}",'
                ' error_description="Token validation failed"'
            )
        },
    )


def build_403_response(required_scope: str) -> JSONResponse:
    """
    Build a 403 Forbidden response when a valid token lacks the required scope.

    RFC 6750 §3.1: use `insufficient_scope` error code.
    """
    return JSONResponse(
        status_code=status.HTTP_403_FORBIDDEN,
        content={
            "error": "insufficient_scope",
            "error_description": (
                f"The token does not carry the required scope: {required_scope}"
            ),
        },
        headers={
            "WWW-Authenticate": (
                'Bearer realm="mcp-presidio-server",'
                ' error="insufficient_scope",'
                f' scope="{required_scope}"'
            )
        },
    )
