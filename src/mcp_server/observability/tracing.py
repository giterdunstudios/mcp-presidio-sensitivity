"""
OpenTelemetry tracing configuration for the MCP server.

Tracing is fully optional — if OTEL_EXPORTER_OTLP_ENDPOINT is unset or empty
the global tracer provider remains the SDK default no-op and no spans are emitted.
When the endpoint is set, spans are exported to a Jaeger (or any OTLP-compatible)
collector via gRPC.

Security note:
  Span attributes must never include payload content.  Only metadata is permitted:
  correlation IDs, caller subjects, HTTP paths, status codes, scan IDs.
"""

from __future__ import annotations

import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import SERVICE_NAME, SERVICE_VERSION, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def configure_tracing(service_name: str, service_version: str) -> None:
    """
    Install a TracerProvider that exports spans via OTLP gRPC.

    If OTEL_EXPORTER_OTLP_ENDPOINT is unset or empty, this function is a no-op
    and the default no-op tracer provider remains active.

    Call once at application startup before any spans are created.
    """
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()
    if not endpoint:
        return

    resource = Resource({
        SERVICE_NAME: service_name,
        SERVICE_VERSION: service_version,
    })
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)


def get_tracer(name: str = "mcp-presidio-sensitivity") -> trace.Tracer:
    """Return a tracer for the given instrumentation scope."""
    return trace.get_tracer(name)
