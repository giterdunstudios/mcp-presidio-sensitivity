"""
Authorization policy — maps tools/endpoints to required scopes.

After a token has been validated by the token verifier, the policy
module decides whether the caller is allowed to invoke the requested
tool.

Rules (from auth spec FR-4, FR-6 and briefing §3):
  - classify_payload_sensitivity requires scope: tools:classify.submit
  - /health requires no scope (Kubernetes probes cannot carry tokens)

Returns True if the caller is allowed, False otherwise.
Callers must return 403 if this returns False.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Scope constants
# ---------------------------------------------------------------------------

SCOPE_CLASSIFY_SUBMIT = "tools:classify.submit"
SCOPE_HEALTH_READ = "tools:health.read"

# ---------------------------------------------------------------------------
# Tool → required scope mapping
# ---------------------------------------------------------------------------

# Maps tool/endpoint names to their required scope.
# Health is excluded — no auth required on that endpoint.
TOOL_SCOPE_MAP: dict[str, str] = {
    "classify_payload_sensitivity": SCOPE_CLASSIFY_SUBMIT,
}


# ---------------------------------------------------------------------------
# Policy check
# ---------------------------------------------------------------------------


def is_authorized(tool: str, scopes: frozenset[str]) -> tuple[bool, str]:
    """
    Determine whether the caller's scopes satisfy the requirement for `tool`.

    Returns (True, "") if authorized.
    Returns (False, required_scope) if the required scope is absent.
    Returns (True, "") for tools not in the map (no scope constraint).
    """
    required = TOOL_SCOPE_MAP.get(tool)
    if required is None:
        # No scope constraint for this tool
        return True, ""

    if required in scopes:
        return True, ""

    return False, required
