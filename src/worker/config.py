"""
Worker configuration constants.

All tunable values are read from environment variables at startup.
Defaults mirror the Helm values.yaml specification.
"""

import os

# Maximum accepted payload size in bytes (default: 1 MiB)
MAX_PAYLOAD_BYTES: int = int(os.environ.get("MAX_PAYLOAD_BYTES", 1_048_576))

# Language passed to the Presidio AnalyzerEngine
DEFAULT_LANGUAGE: str = os.environ.get("DEFAULT_LANGUAGE", "en")

# Policy profile identifier returned in scan results
POLICY_PROFILE: str = os.environ.get("POLICY_PROFILE", "default")

# Supported content-type values — anything outside this list is rejected early
SUPPORTED_CONTENT_TYPES: frozenset[str] = frozenset(
    {
        "text/plain",
        "application/json",
    }
)

# Minimum recognizer score threshold for a finding to be included
MIN_SCORE_THRESHOLD: float = float(os.environ.get("MIN_SCORE_THRESHOLD", 0.4))

# Service identity (used in structured log records)
SERVICE_VERSION: str = os.environ.get("SERVICE_VERSION", "0.1.0")
ENVIRONMENT: str = os.environ.get("ENVIRONMENT", "production")
