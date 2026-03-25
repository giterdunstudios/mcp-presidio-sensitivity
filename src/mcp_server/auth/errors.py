"""
Auth error types and HTTP response builders.

Returns RFC 6750-compliant WWW-Authenticate challenges on 401/403.
Returns RFC 9728-compliant resource_metadata pointer in WWW-Authenticate
so that RFC 9728-aware clients can discover the Authorization Server without
out-of-band configuration.

Security note:
  Error responses never include token content, payload data,
  or internal exception detail beyond what is defined here.
"""

from __future__ import annotations

from fastapi import status
from fastapi.responses import JSONResponse

import config

# RFC 9728 §5: WWW-Authenticate must carry the resource_metadata URL so
# clients can locate the Protected Resource Metadata document and derive
# the Authorization Server token endpoint without prior configuration.
_RESOURCE_METADATA_URL = (
    f"{config.SERVER_RESOURCE_URL}/.well-known/oauth-protected-resource"
)


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
    RFC 9728 §5 requires the resource_metadata URI so clients can discover
    the Authorization Server without out-of-band configuration.
    """
    return JSONResponse(
        status_code=status.HTTP_401_UNAUTHORIZED,
        content={"error": reason, "error_description": "Token validation failed."},
        headers={
            "WWW-Authenticate": (
                'Bearer realm="mcp-presidio-server",'
                f' resource_metadata="{_RESOURCE_METADATA_URL}",'
                f' error="{reason}",'
                ' error_description="Token validation failed"'
            )
        },
    )


def build_403_response(required_scope: str) -> JSONResponse:
    """
    Build a 403 Forbidden response when a valid token lacks the required scope.

    RFC 6750 §3.1: use `insufficient_scope` error code with scope challenge.
    RFC 9728 §5: include resource_metadata so clients can re-authorise with
    the correct scope without out-of-band configuration.
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
                f' resource_metadata="{_RESOURCE_METADATA_URL}",'
                ' error="insufficient_scope",'
                f' scope="{required_scope}"'
            )
        },
    )
