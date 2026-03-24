"""
Pydantic request and response models for the MCP server tool endpoint.

Security note:
  ClassifyRequest.content must never appear in any log statement, error
  response, or structured log field.  All handlers must treat this field as
  opaque payload data that must not be propagated beyond the backend call.
"""

from __future__ import annotations

from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


# ---------------------------------------------------------------------------
# Inbound tool request
# ---------------------------------------------------------------------------


class RequestMetadata(BaseModel):
    """Optional caller-supplied routing and correlation hints."""

    source_system: Optional[str] = Field(default=None, max_length=128)
    workflow_id: Optional[str] = Field(default=None, max_length=128)


class ClassifyRequest(BaseModel):
    """
    Input model for the classify_payload_sensitivity tool.

    SECURITY: The `content` field contains potentially sensitive payload text.
    It must not be logged, persisted, or included in any response or error output.
    """

    content: str = Field(
        ...,
        description="Raw text content to be analyzed.  Never logged or returned.",
    )
    content_type: str = Field(
        ...,
        description="MIME content type of the payload (text/plain or application/json).",
    )
    language: str = Field(default="en", max_length=10)
    tenant_policy: str = Field(default="default", max_length=64)
    threshold_profile: str = Field(default="default", max_length=64)
    return_details: bool = Field(
        default=False,
        description="Ignored at MVP — bounded result is always returned.",
    )
    request_metadata: Optional[RequestMetadata] = None

    @field_validator("content_type")
    @classmethod
    def content_type_must_not_be_blank(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("content_type must not be blank")
        return v.strip().lower()


# ---------------------------------------------------------------------------
# Outbound tool response (mirrors worker ScanResponse — passed through)
# ---------------------------------------------------------------------------


class ConfidenceSummary(BaseModel):
    highest_score: float
    findings_count: int


class ClassifyResponse(BaseModel):
    """
    Bounded scan result returned to the caller.
    Contains no payload data, matched substrings, or offsets.
    """

    scan_id: UUID
    status: str
    sensitivity_detected: bool
    max_severity_band: Optional[str]
    matched_categories: list[str]
    entity_summary: dict[str, int]
    decision: str
    confidence_summary: ConfidenceSummary
    policy_profile: str
    detector_version: str
    timestamp: str


# ---------------------------------------------------------------------------
# Error response
# ---------------------------------------------------------------------------


class MCPErrorResponse(BaseModel):
    """
    Structured error response.
    Contains only error metadata — never payload content.
    """

    error_code: str
    message: str
    correlation_id: Optional[str] = None
