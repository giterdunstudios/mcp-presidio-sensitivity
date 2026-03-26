"""
Unit tests for audit/trail.py.

Use cases covered:
  1.  Success path — all required fields present in log record
  2.  Success path — sensitivity_detected, max_severity_band, matched_categories,
      findings_count, policy_profile, detector_version present
  3.  Success path — logged at INFO level
  4.  Error path — error_code present in log record
  5.  Error path — result fields absent (no bleed from success schema)
  6.  Error path — logged at WARNING level
  7.  No payload guarantee — write_audit_record has no content parameter
  8.  correlation_id present in both success and error records
  9.  caller_subject present in both success and error records
 10.  scan_id from result on success path
 11.  scan_id is a fresh UUID on error path (result absent)
 12.  decision is "error" on error path
 13.  Neither result nor error raises ValueError
 14.  OTel unavailable — falls back to correlation_id as trace_id
 15.  OTel available but span invalid — falls back to correlation_id
"""

from __future__ import annotations

import inspect
import logging
import uuid
from unittest.mock import MagicMock, patch

import pytest

from audit.trail import write_audit_record
from backend.models import WorkerConfidenceSummary, WorkerScanResponse
from backend.worker_client import WorkerError


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CORRELATION_ID = "corr-1234"
CALLER_SUBJECT = "test-service-account"
SCAN_ID = uuid.UUID("9a3427e6-d9cf-4a5d-86d4-7b4bbc79e5ef")


def make_result() -> WorkerScanResponse:
    return WorkerScanResponse(
        scan_id=SCAN_ID,
        status="ok",
        sensitivity_detected=True,
        max_severity_band="high",
        matched_categories=["financial_identifier"],
        entity_summary={"CREDIT_CARD": 1},
        decision="block",
        confidence_summary=WorkerConfidenceSummary(highest_score=1.0, findings_count=1),
        policy_profile="default",
        detector_version="presidio-analyzer==2.2.354",
        timestamp="2026-03-25T00:00:00Z",
    )


def make_error() -> WorkerError:
    return WorkerError(error_code="SCAN_TIMEOUT", message="Worker timed out")


def capture_audit_record(fn, **kwargs):
    """Call fn and return the LogRecord emitted to the audit logger."""
    records = []

    class CapturingHandler(logging.Handler):
        def emit(self, record):
            records.append(record)

    logger = logging.getLogger("mcp-presidio-sensitivity.audit")
    original_level = logger.level
    logger.setLevel(logging.DEBUG)
    handler = CapturingHandler()
    logger.addHandler(handler)
    try:
        fn(**kwargs)
    finally:
        logger.removeHandler(handler)
        logger.setLevel(original_level)

    assert len(records) == 1, f"Expected 1 audit record, got {len(records)}"
    return records[0]


# ---------------------------------------------------------------------------
# Case 1 — success path: required base fields present
# ---------------------------------------------------------------------------

def test_success_record_has_required_base_fields():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        result=make_result(),
    )
    assert record.__dict__["event_type"] == "audit"
    assert record.__dict__["audit_event"] == "scan_completed"
    assert record.__dict__["scan_id"] == str(SCAN_ID)
    assert record.__dict__["correlation_id"] == CORRELATION_ID
    assert record.__dict__["caller_subject"] == CALLER_SUBJECT
    assert "trace_id" in record.__dict__


# ---------------------------------------------------------------------------
# Case 2 — success path: result-specific fields present
# ---------------------------------------------------------------------------

def test_success_record_has_result_fields():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        result=make_result(),
    )
    assert record.__dict__["sensitivity_detected"] is True
    assert record.__dict__["max_severity_band"] == "high"
    assert record.__dict__["matched_categories"] == ["financial_identifier"]
    assert record.__dict__["findings_count"] == 1
    assert record.__dict__["policy_profile"] == "default"
    assert record.__dict__["detector_version"] == "presidio-analyzer==2.2.354"
    assert record.__dict__["decision"] == "block"


# ---------------------------------------------------------------------------
# Case 3 — success path: logged at INFO
# ---------------------------------------------------------------------------

def test_success_record_logged_at_info():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        result=make_result(),
    )
    assert record.levelno == logging.INFO


# ---------------------------------------------------------------------------
# Case 4 — error path: error_code present
# ---------------------------------------------------------------------------

def test_error_record_has_error_code():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    assert record.__dict__["error_code"] == "SCAN_TIMEOUT"


# ---------------------------------------------------------------------------
# Case 5 — error path: result fields absent
# ---------------------------------------------------------------------------

def test_error_record_has_no_result_fields():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    for field in ("sensitivity_detected", "max_severity_band", "matched_categories",
                  "findings_count", "policy_profile", "detector_version"):
        assert field not in record.__dict__, f"Result field '{field}' leaked into error record"


# ---------------------------------------------------------------------------
# Case 6 — error path: logged at WARNING
# ---------------------------------------------------------------------------

def test_error_record_logged_at_warning():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    assert record.levelno == logging.WARNING


# ---------------------------------------------------------------------------
# Case 7 — no payload guarantee: write_audit_record has no content parameter
# ---------------------------------------------------------------------------

def test_no_content_parameter():
    sig = inspect.signature(write_audit_record)
    assert "content" not in sig.parameters, (
        "write_audit_record must never accept a 'content' parameter"
    )


# ---------------------------------------------------------------------------
# Case 8 — correlation_id present in both paths
# ---------------------------------------------------------------------------

def test_correlation_id_in_success_record():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        result=make_result(),
    )
    assert record.__dict__["correlation_id"] == CORRELATION_ID


def test_correlation_id_in_error_record():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    assert record.__dict__["correlation_id"] == CORRELATION_ID


# ---------------------------------------------------------------------------
# Case 9 — caller_subject present in both paths
# ---------------------------------------------------------------------------

def test_caller_subject_in_success_record():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        result=make_result(),
    )
    assert record.__dict__["caller_subject"] == CALLER_SUBJECT


def test_caller_subject_in_error_record():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    assert record.__dict__["caller_subject"] == CALLER_SUBJECT


# ---------------------------------------------------------------------------
# Case 10 — scan_id from result on success path
# ---------------------------------------------------------------------------

def test_scan_id_matches_result_on_success():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        result=make_result(),
    )
    assert record.__dict__["scan_id"] == str(SCAN_ID)


# ---------------------------------------------------------------------------
# Case 11 — scan_id is a fresh UUID on error path
# ---------------------------------------------------------------------------

def test_scan_id_is_uuid_on_error():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    scan_id = record.__dict__["scan_id"]
    # Must be a valid UUID string
    parsed = uuid.UUID(scan_id)
    assert parsed is not None
    # Must not be the result's scan_id (no result was provided)
    assert scan_id != str(SCAN_ID)


# ---------------------------------------------------------------------------
# Case 12 — decision is "error" on error path
# ---------------------------------------------------------------------------

def test_decision_is_error_on_error_path():
    record = capture_audit_record(
        write_audit_record,
        correlation_id=CORRELATION_ID,
        caller_subject=CALLER_SUBJECT,
        error=make_error(),
    )
    assert record.__dict__["decision"] == "error"


# ---------------------------------------------------------------------------
# Case 13 — neither result nor error raises ValueError
# ---------------------------------------------------------------------------

def test_neither_result_nor_error_raises():
    with pytest.raises(ValueError):
        write_audit_record(
            correlation_id=CORRELATION_ID,
            caller_subject=CALLER_SUBJECT,
        )


# ---------------------------------------------------------------------------
# Case 14 — OTel unavailable: trace_id falls back to correlation_id
# ---------------------------------------------------------------------------

def test_trace_id_falls_back_to_correlation_id_when_otel_unavailable():
    with patch("audit.trail._OTEL_AVAILABLE", False):
        record = capture_audit_record(
            write_audit_record,
            correlation_id=CORRELATION_ID,
            caller_subject=CALLER_SUBJECT,
            result=make_result(),
        )
    assert record.__dict__["trace_id"] == CORRELATION_ID


# ---------------------------------------------------------------------------
# Case 15 — OTel available but span invalid: falls back to correlation_id
# ---------------------------------------------------------------------------

def test_trace_id_falls_back_when_otel_span_invalid():
    mock_span = MagicMock()
    mock_span.get_span_context.return_value = MagicMock(is_valid=False)

    with patch("audit.trail._OTEL_AVAILABLE", True), \
         patch("audit.trail._otel_trace") as mock_trace:
        mock_trace.get_current_span.return_value = mock_span
        record = capture_audit_record(
            write_audit_record,
            correlation_id=CORRELATION_ID,
            caller_subject=CALLER_SUBJECT,
            result=make_result(),
        )
    assert record.__dict__["trace_id"] == CORRELATION_ID
