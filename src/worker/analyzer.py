"""
Presidio AnalyzerEngine wrapper (embedded library mode — spec §3.4).

This module owns the single point of contact with presidio-analyzer.
It is the only place in the worker that ever sees raw Presidio RecognizerResult
objects, and it ensures that nothing beyond entity type and score is propagated
to callers.

Security constraints enforced here:
- The text argument is never logged (not in exceptions, not in tracebacks surfaced
  to callers).
- Raw RecognizerResult objects (which carry start/end offsets and matched text
  context) are stripped immediately — callers receive only {entity_type, score}.
- Engine initialisation loads only the approved built-in recognizer set;
  no custom recognizers are added at MVP without explicit change control.
"""

from __future__ import annotations

import logging

from presidio_analyzer import AnalyzerEngine

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Approved recognizer entity types for MVP
# This allowlist controls which entity types the engine is permitted to return.
# Any Presidio built-in not listed here is suppressed at the result level.
# ---------------------------------------------------------------------------

APPROVED_ENTITY_TYPES: frozenset[str] = frozenset(
    {
        # direct_identifier
        "PERSON",
        "DATE_TIME",
        # financial_identifier
        "CREDIT_CARD",
        "IBAN_CODE",
        "US_BANK_NUMBER",
        # government_identifier
        "US_SSN",
        "US_PASSPORT",
        "US_DRIVER_LICENSE",
        "NRP",
        # contact_data
        "EMAIL_ADDRESS",
        "PHONE_NUMBER",
        "IP_ADDRESS",
        "URL",
        # secrets_like_data
        "CRYPTO",
        # regulated_like_data
        "MEDICAL_LICENSE",
        "US_ITIN",
    }
)


class PresidioAnalyzerWrapper:
    """
    Thin wrapper around AnalyzerEngine.

    Thread safety: AnalyzerEngine is stateless with respect to input text;
    a single instance can be shared across concurrent requests.
    """

    def __init__(self, min_score_threshold: float = 0.4) -> None:
        self._min_score = min_score_threshold
        # Initialise once at startup — loading NLP models is expensive.
        logger.info("Initialising Presidio AnalyzerEngine")
        self._engine = AnalyzerEngine()
        logger.info("Presidio AnalyzerEngine ready")

    def analyze(self, text: str, language: str) -> list[dict]:
        """
        Analyze text and return a stripped finding list.

        Each element is a plain dict: {"entity_type": str, "score": float}.
        Raw Presidio RecognizerResult objects — which carry start/end offsets
        and matched text context — are never passed to callers.

        SECURITY: `text` must not appear in any log statement, raised exception
        message, or propagated error that could be captured by the framework.
        """
        try:
            raw_results = self._engine.analyze(
                text=text,
                language=language,
                entities=list(APPROVED_ENTITY_TYPES),
                score_threshold=self._min_score,
            )
        except Exception:
            # Log the failure without including the text argument.
            logger.exception("Presidio analysis raised an exception (text content suppressed)")
            raise

        stripped = []
        for result in raw_results:
            if result.entity_type not in APPROVED_ENTITY_TYPES:
                continue
            stripped.append(
                {
                    "entity_type": result.entity_type,
                    "score": round(result.score, 4),
                }
            )

        # text and raw_results go out of scope here; the caller holds only stripped.
        return stripped


# Module-level singleton initialised lazily on first import.
# This ensures the NLP model is loaded once per worker process.
_engine_instance: PresidioAnalyzerWrapper | None = None


def get_engine(min_score_threshold: float = 0.4) -> PresidioAnalyzerWrapper:
    """Return the shared AnalyzerEngine wrapper, initialising on first call."""
    global _engine_instance
    if _engine_instance is None:
        _engine_instance = PresidioAnalyzerWrapper(min_score_threshold=min_score_threshold)
    return _engine_instance
