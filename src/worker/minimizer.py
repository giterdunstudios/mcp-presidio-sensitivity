"""
Result minimizer (spec §1.3, §lane-b-presidio-worker.md).

Converts the stripped finding list from the analyzer into the bounded
ScanResponse schema.  This is the final gate before any data leaves the worker.

Security guarantees enforced here:
- No payload content, matched substrings, or offsets enter this module.
  The input is the stripped list [{entity_type, score}] produced by analyzer.py.
- entity_summary contains counts only — never matched text.
- The returned ScanResponse matches the spec §2.5 output schema exactly.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Optional

from importlib.metadata import version as _pkg_version

from classification import (
    compute_severity_band,
    derive_categories,
    severity_to_decision,
)
from models import ConfidenceSummary, ScanResponse


def _detector_version() -> str:
    """Return a stable detector version string for audit output."""
    return f"presidio-{_pkg_version('presidio-analyzer')}"


def minimize(
    findings: list[dict],  # [{entity_type: str, score: float}]
    policy_profile: str,
    scan_id: Optional[uuid.UUID] = None,
) -> ScanResponse:
    """
    Produce a bounded ScanResponse from stripped findings.

    This function never receives payload text, raw Presidio spans, or offsets.
    """
    if scan_id is None:
        scan_id = uuid.uuid4()

    # Entity summary — counts only, no matched text
    entity_summary: dict[str, int] = {}
    for f in findings:
        et = f["entity_type"]
        entity_summary[et] = entity_summary.get(et, 0) + 1

    entity_types = [f["entity_type"] for f in findings]
    matched_categories = derive_categories(entity_types)

    severity_band: Optional[str] = compute_severity_band(findings)
    decision = severity_to_decision(severity_band)

    sensitivity_detected = len(findings) > 0

    highest_score = max((f["score"] for f in findings), default=0.0)
    findings_count = len(findings)

    return ScanResponse(
        scan_id=scan_id,
        status="completed",
        sensitivity_detected=sensitivity_detected,
        max_severity_band=severity_band,
        matched_categories=matched_categories,
        entity_summary=entity_summary,
        decision=decision,
        confidence_summary=ConfidenceSummary(
            highest_score=highest_score,
            findings_count=findings_count,
        ),
        policy_profile=policy_profile,
        detector_version=_detector_version(),
        timestamp=datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
