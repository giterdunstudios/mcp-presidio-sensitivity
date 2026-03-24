"""
classify_payload_sensitivity tool handler.

This module contains the tool implementation invoked by the MCP SDK.
It receives pre-validated, pre-authorized request arguments and
dispatches to the Presidio worker backend.

Security constraints enforced at this layer:
  - `content` is passed directly to the worker — never logged.
  - The correlation_id flows through to the worker request_metadata.
  - If the worker call fails, a sanitised error is raised — no payload
    content leaks in the exception message.
"""

from __future__ import annotations

import logging
from typing import Any, Optional

from backend.worker_client import WorkerError, call_worker

logger = logging.getLogger("mcp-server.tools.classify")


async def run_classify(
    *,
    content: str,
    content_type: str,
    language: str = "en",
    tenant_policy: str = "default",
    threshold_profile: str = "default",
    return_details: bool = False,
    workflow_id: Optional[str] = None,
    correlation_id: str,
) -> dict[str, Any]:
    """
    Invoke the Presidio worker scan and return the bounded result dict.

    Args:
        content:            Raw payload text.  Never logged or returned.
        content_type:       MIME type of the content.
        language:           Language code for the analyzer.
        tenant_policy:      Policy profile identifier.
        threshold_profile:  Threshold profile identifier.
        return_details:     Ignored at MVP — bounded result is always returned.
        workflow_id:        Optional caller-supplied workflow ID.
        correlation_id:     Request-scoped UUID for traceability.

    Returns:
        Bounded scan result dict (mirrors WorkerScanResponse).

    Raises:
        WorkerError: If the worker call fails.
    """
    # Use caller's workflow_id as the correlation anchor if provided,
    # otherwise use the MCP server's own correlation_id.
    effective_workflow_id = workflow_id or correlation_id

    result = await call_worker(
        content=content,
        content_type=content_type,
        language=language,
        tenant_policy=tenant_policy,
        threshold_profile=threshold_profile,
        correlation_id=effective_workflow_id,
        source_system="mcp-server",
    )

    return result.model_dump(mode="json")
