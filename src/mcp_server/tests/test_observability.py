"""
Unit tests for observability/tracing.py and the OTel injection in
observability/logging.py (JsonFormatter).

Use cases covered:
  1.  configure_tracing — no-op when OTEL_EXPORTER_OTLP_ENDPOINT is unset
  2.  configure_tracing — no-op when endpoint is empty string
  3.  configure_tracing — no-op when endpoint is whitespace-only
  4.  configure_tracing — installs TracerProvider when endpoint is set
  5.  configure_tracing — resource carries service_name and service_version
  6.  configure_tracing — BatchSpanProcessor added to provider
  7.  get_tracer — returns a Tracer from the current provider
  8.  get_tracer — default name is "mcp-presidio-sensitivity"
  9.  get_tracer — accepts a custom name
 10.  JsonFormatter — injects trace_id + span_id when active OTel span is valid
 11.  JsonFormatter — does not inject OTel fields when span context is invalid
 12.  JsonFormatter — falls back to record.trace_id when no active OTel span
 13.  JsonFormatter — no trace_id key when neither OTel nor record provides one
 14.  JsonFormatter — OTel takes precedence over record-level trace_id
 15.  JsonFormatter — OTel injection is resilient; ImportError does not crash logging
"""

from __future__ import annotations

import json
import logging
import os
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_formatter() -> "JsonFormatter":
    """Import and return a fresh JsonFormatter (no handler wiring needed)."""
    from observability.logging import JsonFormatter
    return JsonFormatter()


def _format(formatter, msg: str, **extras) -> dict:
    """Emit a log record through *formatter* and return the parsed JSON dict."""
    record = logging.LogRecord(
        name="test",
        level=logging.INFO,
        pathname="",
        lineno=0,
        msg=msg,
        args=(),
        exc_info=None,
    )
    for k, v in extras.items():
        setattr(record, k, v)
    # _ServiceContextFilter normally injects these; set defaults here
    record.service_name = "test-svc"
    record.service_version = "0.0.0"
    record.environment = "test"
    return json.loads(formatter.format(record))


def _make_valid_span_context(trace_id: int = 0xDEADBEEF_CAFEBABE_12345678_ABCDEF01,
                              span_id: int = 0xFACEB00C_DEADBEEF):
    """Return a mock SpanContext that reports is_valid=True."""
    ctx = MagicMock()
    ctx.is_valid = True
    ctx.trace_id = trace_id
    ctx.span_id = span_id
    return ctx


def _make_invalid_span_context():
    ctx = MagicMock()
    ctx.is_valid = False
    return ctx


# ---------------------------------------------------------------------------
# configure_tracing — no-op paths
# ---------------------------------------------------------------------------


class TestConfigureTracingNoop:
    def test_no_op_when_env_unset(self):
        """Case 1: No endpoint env var → set_tracer_provider never called."""
        env = {k: v for k, v in os.environ.items() if k != "OTEL_EXPORTER_OTLP_ENDPOINT"}
        with patch.dict(os.environ, env, clear=True):
            with patch("opentelemetry.trace.set_tracer_provider") as mock_set:
                from observability.tracing import configure_tracing
                configure_tracing("svc", "0.1.0")
                mock_set.assert_not_called()

    def test_no_op_when_env_empty(self):
        """Case 2: Empty string endpoint → no-op."""
        with patch.dict(os.environ, {"OTEL_EXPORTER_OTLP_ENDPOINT": ""}):
            with patch("opentelemetry.trace.set_tracer_provider") as mock_set:
                from observability.tracing import configure_tracing
                configure_tracing("svc", "0.1.0")
                mock_set.assert_not_called()

    def test_no_op_when_env_whitespace(self):
        """Case 3: Whitespace-only endpoint → no-op (strip() guard)."""
        with patch.dict(os.environ, {"OTEL_EXPORTER_OTLP_ENDPOINT": "   "}):
            with patch("opentelemetry.trace.set_tracer_provider") as mock_set:
                from observability.tracing import configure_tracing
                configure_tracing("svc", "0.1.0")
                mock_set.assert_not_called()


# ---------------------------------------------------------------------------
# configure_tracing — provider installation paths
# ---------------------------------------------------------------------------


class TestConfigureTracingInstall:
    def _run_with_endpoint(self, endpoint: str = "http://jaeger:4317"):
        """Patch heavy OTel classes and run configure_tracing, return mocks."""
        mock_provider = MagicMock()
        mock_exporter = MagicMock()
        mock_processor = MagicMock()

        with patch.dict(os.environ, {"OTEL_EXPORTER_OTLP_ENDPOINT": endpoint}):
            with patch("observability.tracing.TracerProvider", return_value=mock_provider) as mock_tp_cls, \
                 patch("observability.tracing.OTLPSpanExporter", return_value=mock_exporter) as mock_exp_cls, \
                 patch("observability.tracing.BatchSpanProcessor", return_value=mock_processor) as mock_bsp_cls, \
                 patch("observability.tracing.trace.set_tracer_provider") as mock_set:
                from observability.tracing import configure_tracing
                configure_tracing("my-service", "1.2.3")
                return {
                    "provider": mock_provider,
                    "exporter": mock_exporter,
                    "processor": mock_processor,
                    "tp_cls": mock_tp_cls,
                    "exp_cls": mock_exp_cls,
                    "bsp_cls": mock_bsp_cls,
                    "set_provider": mock_set,
                }

    def test_installs_tracer_provider(self):
        """Case 4: Endpoint set → set_tracer_provider called with the new provider."""
        mocks = self._run_with_endpoint()
        mocks["set_provider"].assert_called_once_with(mocks["provider"])

    def test_resource_carries_service_identity(self):
        """Case 5: Resource passed to TracerProvider includes service_name + version."""
        from opentelemetry.sdk.resources import SERVICE_NAME, SERVICE_VERSION, Resource
        mocks = self._run_with_endpoint()
        call_kwargs = mocks["tp_cls"].call_args
        resource = call_kwargs[1].get("resource") or call_kwargs[0][0]
        assert resource.attributes.get(SERVICE_NAME) == "my-service"
        assert resource.attributes.get(SERVICE_VERSION) == "1.2.3"

    def test_batch_span_processor_added(self):
        """Case 6: BatchSpanProcessor wrapping the exporter is added to provider."""
        mocks = self._run_with_endpoint()
        mocks["bsp_cls"].assert_called_once_with(mocks["exporter"])
        mocks["provider"].add_span_processor.assert_called_once_with(mocks["processor"])


# ---------------------------------------------------------------------------
# get_tracer
# ---------------------------------------------------------------------------


class TestGetTracer:
    def test_returns_tracer(self):
        """Case 7: get_tracer returns an object with start_as_current_span."""
        from observability.tracing import get_tracer
        tracer = get_tracer()
        assert hasattr(tracer, "start_as_current_span")

    def test_default_name(self):
        """Case 8: Default instrumentation scope name."""
        mock_tracer = MagicMock()
        with patch("observability.tracing.trace.get_tracer", return_value=mock_tracer) as mock_get:
            from observability.tracing import get_tracer
            result = get_tracer()
            mock_get.assert_called_once_with("mcp-presidio-sensitivity")
            assert result is mock_tracer

    def test_custom_name(self):
        """Case 9: Custom instrumentation scope name is forwarded."""
        mock_tracer = MagicMock()
        with patch("observability.tracing.trace.get_tracer", return_value=mock_tracer) as mock_get:
            from observability.tracing import get_tracer
            get_tracer("custom-scope")
            mock_get.assert_called_once_with("custom-scope")


# ---------------------------------------------------------------------------
# JsonFormatter — OTel trace context injection
# ---------------------------------------------------------------------------


class TestJsonFormatterOTelInjection:
    def test_injects_trace_and_span_id_when_span_valid(self):
        """Case 10: Active OTel span with valid context → trace_id + span_id in output."""
        span_ctx = _make_valid_span_context(
            trace_id=0xDEADBEEF_CAFEBABE_12345678_ABCDEF01,
            span_id=0xFACEB00C_DEADBEEF,
        )
        mock_span = MagicMock()
        mock_span.get_span_context.return_value = span_ctx

        formatter = _make_formatter()
        with patch("opentelemetry.trace.get_current_span", return_value=mock_span):
            doc = _format(formatter, "hello")

        assert doc["trace_id"] == format(0xDEADBEEF_CAFEBABE_12345678_ABCDEF01, "032x")
        assert doc["span_id"] == format(0xFACEB00C_DEADBEEF, "016x")

    def test_no_otel_fields_when_span_invalid(self):
        """Case 11: Span context is_valid=False → no trace_id or span_id from OTel."""
        mock_span = MagicMock()
        mock_span.get_span_context.return_value = _make_invalid_span_context()

        formatter = _make_formatter()
        with patch("opentelemetry.trace.get_current_span", return_value=mock_span):
            doc = _format(formatter, "hello")

        assert "trace_id" not in doc
        assert "span_id" not in doc

    def test_falls_back_to_record_trace_id(self):
        """Case 12: No active OTel span → record-level trace_id used as fallback."""
        mock_span = MagicMock()
        mock_span.get_span_context.return_value = _make_invalid_span_context()

        formatter = _make_formatter()
        with patch("opentelemetry.trace.get_current_span", return_value=mock_span):
            doc = _format(formatter, "hello", trace_id="corr-fallback-id")

        assert doc["trace_id"] == "corr-fallback-id"
        assert "span_id" not in doc

    def test_no_trace_id_when_neither_source_provides_one(self):
        """Case 13: Invalid span + no record trace_id → trace_id absent from output."""
        mock_span = MagicMock()
        mock_span.get_span_context.return_value = _make_invalid_span_context()

        formatter = _make_formatter()
        with patch("opentelemetry.trace.get_current_span", return_value=mock_span):
            doc = _format(formatter, "hello")

        assert "trace_id" not in doc

    def test_otel_takes_precedence_over_record_trace_id(self):
        """Case 14: Valid OTel span wins over record-level trace_id."""
        span_ctx = _make_valid_span_context(
            trace_id=0xAAAAAAAA_BBBBBBBB_CCCCCCCC_DDDDDDDD,
            span_id=0x1111111_22222222,
        )
        mock_span = MagicMock()
        mock_span.get_span_context.return_value = span_ctx

        formatter = _make_formatter()
        with patch("opentelemetry.trace.get_current_span", return_value=mock_span):
            doc = _format(formatter, "hello", trace_id="should-be-ignored")

        assert doc["trace_id"] == format(0xAAAAAAAA_BBBBBBBB_CCCCCCCC_DDDDDDDD, "032x")
        assert doc["span_id"] == format(0x1111111_22222222, "016x")

    def test_otel_injection_resilient_to_import_error(self):
        """Case 15: If OTel import fails, logging must not raise — record trace_id fallback used."""
        formatter = _make_formatter()
        # Simulate OTel being completely unavailable during formatting
        import builtins
        real_import = builtins.__import__

        def _blocking_import(name, *args, **kwargs):
            if name.startswith("opentelemetry"):
                raise ImportError("otel not available")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=_blocking_import):
            doc = _format(formatter, "hello", trace_id="corr-safe-fallback")

        # Must not raise; should fall back to record-level trace_id
        assert doc["trace_id"] == "corr-safe-fallback"
        assert "span_id" not in doc
