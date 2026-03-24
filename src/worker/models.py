"""
Pydantic request and response models for the Presidio worker.

Security note:
- ScanRequest.content must never appear in log output, error messages,
  or response payloads.  The field is annotated and all handlers must
  treat it accordingly.
- ScanResponse and ErrorResponse contain only bounded metadata.
  No matched substrings, offsets, or excerpts are present in any
  response model.
"""

from __future__ import annotations

from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


class RequestMetadata(BaseModel):
    """Optional non-sensitive routing and audit hints provided by the caller."""

    source_system: Optional[str] = Field(default=None, max_length=128)
    workflow_id: Optional[str] = Field(default=None, max_length=128)


class ScanRequest(BaseModel):
    """
    Inbound scan request.

    SECURITY: The `content` field contains potentially sensitive payload text.
    It must not be logged, persisted, or included in any response or error output.
    """

    content: str = Field(
        ...,
        description="Raw text content to be analyzed.  Never logged or returned.",
    )
    content_type: str = Field(
        ...,
        description="MIME content type of the payload.",
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


class ConfidenceSummary(BaseModel):
    highest_score: float
    findings_count: int


class ScanResponse(BaseModel):
    """
    Bounded scan result.  Contains no payload data, matched substrings, or offsets.
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


class ErrorResponse(BaseModel):
    """
    Failure response.  Contains only error metadata — never payload content.
    """

    scan_id: UUID
    status: str = "rejected"
    error_code: str
    message: str
