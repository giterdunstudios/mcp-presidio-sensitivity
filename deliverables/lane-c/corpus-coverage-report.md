# Corpus Coverage Report
**Lane:** C — Synthetic Test Corpus
**Phase:** 0
**Date:** 2026-03-24
**Status:** Complete

---

## 1. Total Test Case Count

**Total cases across all corpus files: 41**

---

## 2. Count Per File and Category

| File | Category Covered | Case Count |
|------|-----------------|------------|
| `corpus/direct-identifier.yaml` | direct_identifier | 6 |
| `corpus/financial-identifier.yaml` | financial_identifier | 6 |
| `corpus/government-identifier.yaml` | government_identifier | 6 |
| `corpus/contact-data.yaml` | contact_data | 6 |
| `corpus/secrets-like.yaml` | secrets_like_data | 5 |
| `corpus/mixed-sensitivity.yaml` | mixed (multiple categories) | 5 |
| `corpus/negative.yaml` | negative (no sensitivity) | 6 |
| `corpus/edge-cases.yaml` | edge cases / adversarial | 6 |

**Cases with expected_sensitivity_detected: true:** 30
**Cases with expected_sensitivity_detected: false:** 11

---

## 3. Entity Type Coverage Against Interim Classification Model

The interim classification model defines the following grouped categories (spec §6.3):

| Category | Entity Types Targeted | Coverage Status |
|----------|-----------------------|----------------|
| direct_identifier | PERSON, DATE_TIME, AGE | Covered — dir-001 through dir-006 |
| financial_identifier | CREDIT_CARD, IBAN_CODE, US_BANK_NUMBER | Covered — fin-001 through fin-006 |
| government_identifier | US_SSN, US_PASSPORT, US_DRIVER_LICENSE | Covered — gov-001 through gov-006 |
| contact_data | EMAIL_ADDRESS, PHONE_NUMBER, IP_ADDRESS, URL | Covered — con-001 through con-006 |
| secrets_like_data | API key patterns, credentials, tokens | Covered — sec-001 through sec-005 |
| regulated_like_data | — | Not covered — see gap note below |
| internal_business_sensitive | — | Not covered — see gap note below |

---

## 4. Entity Types Not Covered and Reasons

### 4.1 `regulated_like_data`

**Not covered in this corpus.**

The interim classification model defines `regulated_like_data` as a category but does not enumerate specific entity types within it (the full taxonomy is deferred per spec §6). Without concrete entity types to target, no corpus cases can be constructed that reliably test Presidio recognizer coverage for this category.

Examples of what might fall under this category in a future taxonomy:
- NPI (US National Provider Identifier — healthcare)
- DEA numbers (healthcare)
- HIPAA-protected fields (diagnosis codes, procedure codes)
- UK NHS numbers

None of these are supported by Presidio's built-in recognizers. If this category is formalized, custom recognizers will be required.

**Recommendation:** When the regulated_like_data category is formally scoped in Phase 1 or later, add a `corpus/regulated-like.yaml` file with cases matched to the specific entity types defined.

---

### 4.2 `internal_business_sensitive`

**Not covered in this corpus.**

This category is entirely organization-specific and cannot be represented with a generic synthetic corpus. By definition, internal business sensitive data (trade secrets, board communications, M&A documentation, internal pricing) requires domain context from the deploying organization to define meaningfully.

Presidio has no built-in recognizers for internal business sensitive content. This category would require custom recognizers, keyword lists, or classification rules specific to each tenant's data definitions.

**Recommendation:** Treat this category as out of scope for automated Presidio-based detection in Phase 1. Define the category boundaries with stakeholders before building any detection logic. This is consistent with the deferred classification policy model (spec §6).

---

## 5. Recognizer Gaps Identified

The following are gaps or limitations observed while constructing this corpus. These represent areas where Presidio's built-in recognizer set is likely to produce false negatives, require custom recognizers, or produce notable false positives.

### 5.1 API key and credential patterns (sec-001, sec-002, sec-005)

**Gap type:** Missing built-in recognizer.

Presidio does not include built-in recognizers for:
- `sk-test-` prefixed API keys (OpenAI-style format)
- Config file password fields (`password =`, `secret =`, `api_key =`)
- JWT token strings in log output

These are high-value detection targets for the `secrets_like_data` category. Custom recognizers using regex patterns anchored on key-name prefixes and common credential format patterns are required.

**Recommendation:** Build custom recognizers for credential patterns in Phase 1. Prioritize: (1) API key prefix formats, (2) config-file credential assignments, (3) JWT format strings.

---

### 5.2 Company and brand name false positives (dir-006, neg-005)

**Gap type:** False positive risk from PERSON recognizer over-triggering on ORG and brand names.

Presidio's PERSON recognizer is based on spaCy NER, which is known to conflate capitalised multi-word phrases with person names. Product names, company names, and geographic phrases may produce false positive PERSON matches.

**Affected cases:** dir-006 (`Aurora Pro X`), neg-005 (`Meridian Solutions`, `Northern Bridge Analytics`, `Apex Dynamics`, `Pacific Rim`).

**Recommendation:** Evaluate confidence thresholds for the PERSON recognizer. Consider adding a deny-list of known brand/org patterns if false positive rates are unacceptable after Phase 1 validation. Note that suppressing false positives for PERSON carries risk — a misconfigured deny-list could suppress real names.

---

### 5.3 US_BANK_NUMBER recognizer reliability (fin-004)

**Gap type:** Low confidence detection for standalone bank account numbers.

Presidio's US_BANK_NUMBER recognizer performs best when routing numbers and account numbers appear together in a recognizable format. Standalone account numbers without routing context may fall below the default confidence threshold.

**Recommendation:** Test US_BANK_NUMBER detection empirically in Phase 0 with both combined (account + routing) and standalone (account only) formats. Adjust confidence thresholds or add a contextual recognizer rule if standalone detection is insufficient.

---

### 5.4 Line-break evasion (edg-003)

**Gap type:** Recognizers do not cross newline boundaries by default.

SSN `000-23-4567` split across a line break (`000-23-\n4567`) is expected to evade detection. This is a known limitation of regex-based recognizers that operate within line boundaries.

**Recommendation:** For Phase 1, document this as an accepted limitation. If evasion resistance is required, consider pre-processing payloads to normalize whitespace before scanning. Note that aggressive normalization could alter the semantic meaning of structured inputs (e.g. CSV, code blocks).

---

### 5.5 Partial phone number suppression (edg-004)

**Gap type:** Ambiguity between 7-digit local number format and full NANP numbers.

A 7-digit local number (`867-5309`) without area code may or may not be detected by Presidio's PHONE_NUMBER recognizer depending on confidence threshold settings.

**Recommendation:** Document expected behavior for partial phone numbers in the Phase 0 validation run. If 7-digit numbers are detected at default thresholds, consider whether the false positive rate is acceptable given that 7-digit numbers are extremely common in non-phone contexts (order numbers, reference codes, dates written without separators).

---

### 5.6 Base64 and encoded content (sec-004)

**Gap type:** No Presidio mechanism for detecting secrets inside encoded content.

Secrets encoded in base64, hex, or URL-encoded format will not be detected because Presidio operates on the text-as-presented, not on decoded content.

**Recommendation:** This is a Phase 2+ concern. For MVP, document the limitation. If encoding-resistant detection is required, a pre-processing decode step before scanning would be needed — though this raises new complexity and potentially introduces false positives for legitimate encoded content.

---

## 6. Recommendations for Phase 1 Corpus Expansion

1. **Add `corpus/regulated-like.yaml`** when the `regulated_like_data` category is formally scoped with concrete entity types. Minimum cases: 5.

2. **Add custom recognizer test cases** for API key patterns, config-file credential assignments, and JWT strings after Phase 1 custom recognizers are built (see gap 5.1).

3. **Add multilingual cases** when Phase 4 multilingual support is in scope. Start with high-volume languages relevant to the deploying organization's user base.

4. **Add structured content cases** (`application/json` content_type) to test JSON extraction and scanning in Phase 1. The MVP spec supports `application/json` as a content type — the corpus currently covers only `text/plain`-style payloads.

5. **Add performance and concurrency cases** in Phase 2 — payloads specifically sized to probe worker timeout behavior and queue saturation under burst conditions.

6. **Formalize negative case expansion** to include organization-specific non-sensitive internal formats (internal reference numbers, project codes, team identifiers) once the `internal_business_sensitive` category is defined.

---

## 7. Synthetic Data Safety Confirmation

All corpus files have been reviewed against the synthetic data rules:

| Rule | Status |
|------|--------|
| No real personal data | Confirmed — all names are clearly fictional (Jane Testperson, John Synthetic, etc.) |
| All SSNs use 000-xx-xxxx or 999-xx-xxxx format | Confirmed — all SSNs use IRS-reserved invalid ranges |
| All IPs use IANA TEST-NET ranges | Confirmed — 192.0.2.x and 203.0.113.x used |
| All email domains use example.com / test.example / invalid.test | Confirmed |
| All credit card numbers are Luhn-valid test numbers only | Confirmed — 4111111111111111, 5500005555555559 |
| No real addresses | Confirmed — no real street addresses appear anywhere |
| No real credentials or API keys | Confirmed — all credential strings are marked as synthetic and non-operational |
| All IDs unique across corpus | Confirmed — prefixes: dir, fin, gov, con, sec, mix, neg, edg; no duplicate IDs |
