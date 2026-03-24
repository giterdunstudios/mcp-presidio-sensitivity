"""
Internal request/response models for the Presidio worker backend adapter.

These mirror the worker's ScanRequest / ScanResponse schemas.
They are kept separate from the MCP server's public models (models.py)
so that changes to the worker's internal schema do not automatically
ripple through to the MCP tool contract.
"""

from __future__ import annotations

from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Worker request (sent to POST /scan)
# ---------------------------------------------------------------------------


class WorkerRequestMetadata(BaseModel):
    source_system: str = "mcp-server"
    workflow_id: Optional[str] = None


class WorkerScanRequest(BaseModel):
    """
    Body sent to the Presidio worker's POST /scan endpoint.

    SECURITY: The `content` field is the raw payload — never logged.
    The caller's Authorization header is never included in this request.
    """

    content: str
    content_type: str
    language: str = "en"
    tenant_policy: str = "default"
    threshold_profile: str = "default"
    return_details: bool = False
    request_metadata: WorkerRequestMetadata = Field(
        default_factory=WorkerRequestMetadata
    )


# ---------------------------------------------------------------------------
# Worker response (received from POST /scan)
# ---------------------------------------------------------------------------


class WorkerConfidenceSummary(BaseModel):
    highest_score: float
    findings_count: int


class WorkerScanResponse(BaseModel):
    """
    Bounded result received from the worker.
    Passed through to the caller unchanged (no re-enrichment).
    """

    scan_id: UUID
    status: str
    sensitivity_detected: bool
    max_severity_band: Optional[str]
    matched_categories: list[str]
    entity_summary: dict[str, int]
    decision: str
    confidence_summary: WorkerConfidenceSummary
    policy_profile: str
    detector_version: str
    timestamp: str


# ---------------------------------------------------------------------------
# Worker error response
# ---------------------------------------------------------------------------


class WorkerErrorResponse(BaseModel):
    scan_id: Optional[UUID] = None
    status: str = "failed"
    error_code: str
    message: str
