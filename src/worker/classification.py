"""
Interim classification model (spec §6.3).

Maps Presidio entity types to grouped categories, severity bands, and decisions.
These are operational placeholders — not final governance labels.
The full taxonomy is deferred until Phase 1 generates empirical detector behaviour.

No payload content, matched substrings, or offsets flow through this module.
"""

from __future__ import annotations

from typing import Optional

# ---------------------------------------------------------------------------
# Entity → grouped category mapping
# ---------------------------------------------------------------------------

ENTITY_TO_CATEGORY: dict[str, str] = {
    # direct_identifier
    # DATE_TIME is intentionally excluded: a date/time value alone is not
    # a direct identifier — it is contextually ambiguous (e.g. "next month",
    # "quarterly"). It falls into the generic severity path (medium/low).
    # When DATE_TIME co-occurs with a true identifier (PERSON, US_SSN etc.)
    # the severity is determined by that identifier, not by DATE_TIME itself.
    # A dedicated DATE_OF_BIRTH recogniser should be added in Phase 2 for
    # cases where date context clearly identifies an individual.
    "PERSON": "direct_identifier",
    "AGE": "direct_identifier",
    # financial_identifier
    "CREDIT_CARD": "financial_identifier",
    "IBAN_CODE": "financial_identifier",
    "US_BANK_NUMBER": "financial_identifier",
    # government_identifier
    "US_SSN": "government_identifier",
    "US_PASSPORT": "government_identifier",
    "US_DRIVER_LICENSE": "government_identifier",
    "NRP": "government_identifier",
    # contact_data
    "EMAIL_ADDRESS": "contact_data",
    "PHONE_NUMBER": "contact_data",
    "IP_ADDRESS": "contact_data",
    "URL": "contact_data",
    # secrets_like_data
    "CRYPTO": "secrets_like_data",
    "AWS_ACCESS_KEY": "secrets_like_data",
    # regulated_like_data
    "MEDICAL_LICENSE": "regulated_like_data",
    "US_ITIN": "regulated_like_data",
    # internal_business_sensitive — reserved, no entity types mapped at MVP
}

# ---------------------------------------------------------------------------
# Category sets used for severity band logic
# ---------------------------------------------------------------------------

HIGH_SEVERITY_CATEGORIES: frozenset[str] = frozenset(
    {"direct_identifier", "financial_identifier", "government_identifier"}
)

CRITICAL_SEVERITY_CATEGORIES: frozenset[str] = frozenset(
    {"secrets_like_data"}
)

# Score threshold used to distinguish "high-confidence" from "low-confidence"
HIGH_CONFIDENCE_THRESHOLD: float = 0.75


# ---------------------------------------------------------------------------
# Severity band computation
# ---------------------------------------------------------------------------

def compute_severity_band(
    findings: list[dict],  # each dict: {"entity_type": str, "score": float}
) -> Optional[str]:
    """
    Return the maximum severity band across all findings.

    Severity logic (spec §lane-b-presidio-worker.md):
      critical — any finding in secrets_like_data category
      high     — any finding in direct_identifier, financial_identifier,
                 or government_identifier category
      medium   — multiple low-confidence findings OR 1 high-confidence
                 non-critical finding
      low      — exactly 1 low-confidence finding in a non-critical category
      None     — no findings
    """
    if not findings:
        return None

    has_critical = False
    has_high = False
    high_confidence_non_critical_count = 0
    low_confidence_count = 0

    for f in findings:
        category = ENTITY_TO_CATEGORY.get(f["entity_type"], "")
        score = f["score"]

        if category in CRITICAL_SEVERITY_CATEGORIES:
            has_critical = True
        elif category in HIGH_SEVERITY_CATEGORIES:
            has_high = True
        else:
            if score >= HIGH_CONFIDENCE_THRESHOLD:
                high_confidence_non_critical_count += 1
            else:
                low_confidence_count += 1

    if has_critical:
        return "critical"
    if has_high:
        return "high"
    if high_confidence_non_critical_count >= 1 or low_confidence_count > 1:
        return "medium"
    if low_confidence_count == 1:
        return "low"

    return "low"


# ---------------------------------------------------------------------------
# Decision mapping
# ---------------------------------------------------------------------------

SEVERITY_TO_DECISION: dict[Optional[str], str] = {
    None: "allow",
    "low": "allow",
    "medium": "flag",
    "high": "block",
    "critical": "block",
}


def severity_to_decision(band: Optional[str]) -> str:
    """Map a severity band to a policy decision."""
    return SEVERITY_TO_DECISION.get(band, "block")


# ---------------------------------------------------------------------------
# Category derivation from entity types
# ---------------------------------------------------------------------------

def derive_categories(entity_types: list[str]) -> list[str]:
    """
    Return the deduplicated list of grouped categories present in the finding set.
    Order reflects discovery order; duplicates are suppressed.
    """
    seen: set[str] = set()
    result: list[str] = []
    for et in entity_types:
        cat = ENTITY_TO_CATEGORY.get(et)
        if cat and cat not in seen:
            seen.add(cat)
            result.append(cat)
    return result
