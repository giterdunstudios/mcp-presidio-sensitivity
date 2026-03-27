# Findings: Presidio Vertical Scanning Templates

## Summary
The Presidio vertical-template space is entirely greenfield. No community project packages Presidio recognizers by compliance vertical. Purview, Google DLP, and AWS Macie converge on regulation-named templates with entity lists and confidence thresholds. The technical path is straightforward (YAML + `PatternRecognizer.from_dict()`). Healthcare has the largest gap count; EU national IDs and financial routing identifiers are quick wins. GDPR special categories and financial behavioral data cannot be reliably covered by pattern matching.

Community recognizer patterns exist but are scattered across GitHub repos — actual regex patterns documented in Phase 2. For secrets/credentials, `detect-secrets` (Apache-2.0, Python-native) is the clear in-process companion for Presidio; prefix-anchored secrets (AWS, GitHub, GCP) are near-zero false-positive with simple regex patterns.

---

## Phase 1 Research Findings

### Technical Implementation Lead — Presidio Extensibility Model

**Extensibility mechanisms (4 types):**
- **Pattern-based (`PatternRecognizer`)** — regex + context words + confidence score. Defined in code or YAML. No ML required. Primary extension point.
- **Deny-list** — `PatternRecognizer` with `deny_list` instead of `patterns`. Exact token matching, case-insensitive.
- **ML-backed (`SpacyRecognizer` / `TransformersRecognizer`)** — wraps spaCy NER or HuggingFace transformers model. Swap model by pointing at a different package.
- **Remote recognizer (`RemoteRecognizer`)** — delegates to an external HTTP service. Used for GPU inference servers or commercial PII APIs.

**YAML template format (native Presidio support):**
```yaml
recognizers:
  - name: "US NPI Recognizer"
    supported_language: "en"
    supported_entity: "US_NPI"
    type: "pattern"
    patterns:
      - name: "npi_10digit"
        regex: "\\b[0-9]{10}\\b"
        score: 0.5
    context: ["NPI", "national provider", "provider identifier"]
```
Loaded via `PatternRecognizer.from_dict()` — fully supported, no custom loader needed.

**Full template file structure (proposed):**
```yaml
metadata:
  name: "Healthcare HIPAA Core"
  version: "1.0.0"
  vertical: "healthcare"
  regulatory_framework: "HIPAA"

builtin_entities:       # Presidio defaults to activate
  - PERSON
  - PHONE_NUMBER
  - EMAIL_ADDRESS
  - US_SSN
  - DATE_TIME
  - LOCATION

recognizers:            # Custom pattern recognizers
  - name: "..."
    ...

anonymizer_config:      # Optional — for presidio-anonymizer
  default_operator: "replace"
```

**OSS ecosystem finding:** No recognizer registry or marketplace exists as of mid-2025. Microsoft's `presidio-research` repo provides ML model training tools. Several small community repos add custom recognizers inline but none are packaged as reusable vertical templates.

**Config format summary:**
| Format | Use | Notes |
|---|---|---|
| YAML | Pattern + deny-list recognizers | Primary portable format; native `from_dict()` support |
| Python | ML-based, custom `EntityRecognizer` subclasses | Full flexibility; not portable without package |
| JSON | Same as YAML | Interchangeable via `to_dict()` |
| HuggingFace model card | ML recognizer config | Model name + entity mapping |

---

### Security/Privacy Lead — Compliance Framework Coverage Analysis

**Presidio built-in entity count:** ~40-45 entities. Heavily US-centric.

**HIPAA Safe Harbor 18 identifiers — coverage:**
- Native: PERSON, PHONE_NUMBER, EMAIL_ADDRESS, US_SSN, DATE_TIME, URL, IP_ADDRESS (7/18)
- Partial: LOCATION (no ZIP recognizer), MEDICAL_LICENSE (partial)
- **Gaps: MRN, health plan beneficiary ID, VIN, device serials, biometric (8/18 unmet)**
- Additional clinical gaps: NPI, ICD-10 codes, CPT codes, medication names, lab values

**PCI-DSS coverage:**
- Native: CREDIT_CARD, US_BANK_NUMBER, IBAN_CODE, PERSON (~65% of card data)
- **Gaps: CVV/card security code, SWIFT/BIC, ABA routing numbers, card expiry context**

**GDPR coverage:**
- Art. 4 standard personal data: ~55% (names, email, phone, IP, national IDs for select EU countries)
- **Art. 9 special categories: ~15%** — health, genetic, biometric, sexual orientation have NO pattern-based coverage
- **EU national ID gaps: FR, DE, NL, BE, SE, DK, PT** — all missing, all pattern-detectable

**SOC 2 coverage:** ~70% for common SaaS PII. Key gap: API keys, OAuth tokens, JWTs — no Presidio recognizer.

**Vertical richness ranking (by PII complexity):**
1. Healthcare — very high, lowest Presidio coverage (~45%)
2. Financial Services — high, medium coverage (~60% for card/account IDs)
3. Government/Defense — high, low coverage
4. HR/Employment — medium-high, low coverage (~30%)
5. Education — medium, low coverage (~35%)
6. Legal — medium, very low coverage
7. Retail/E-commerce — medium, medium coverage

**Quick wins (pattern-detectable, high priority):**
- ABA routing number (9-digit)
- SWIFT/BIC code (8-11 char)
- CVV/card security code (3-4 digit with card context)
- US NPI (10-digit, context: "NPI", "national provider")
- Medicare Beneficiary ID (MBI format: 1C1XXXXXXX1)
- EU national IDs: FR NIR (15-digit), DE Tax ID (11-digit), NL BSN (9-digit), BE RRN (11-digit), SE Personnummer (10/12 digit), DK CPR (10-digit)

**Cannot be pattern-detected (out of scope):**
- GDPR Art. 9: health conditions, genetic data, biometric markers, sexual orientation, trade union membership
- Financial behavioral data: balances, transaction history, income, credit scores
- Precise geolocation (GPS coordinates — technically pattern-detectable but low precision)

---

### Product Lead — Vertical Community & Competitor Analysis

**Community finding:** No existing packaged Presidio vertical templates on PyPI, GitHub, or HuggingFace Hub. Microsoft healthcare demos show inline custom recognizers (NPI, DEA) but these are not published as reusable packages. The space is entirely greenfield.

**Competitor template packaging patterns:**

*Microsoft Purview DLP:*
- Regulation-first naming: `U.S. HIPAA`, `PCI DSS`, `U.K. Financial Data`
- Base vs. Enhanced split: `HIPAA` (narrow) vs. `HIPAA Enhanced` (adds contextual entities, higher FP rate)
- Geography is primary dimension: same regulation = separate templates per jurisdiction
- 14 financial templates, 8 medical/health templates, 30+ privacy/PII templates

*Google Cloud DLP:*
- Category tags as API filters (request infoTypes by `category` string)
- Stored templates: `projects/{project}/inspectTemplates` — named configs referenced by name in scan requests
- Per-infoType `minLikelihood` overrides stored in template
- Built-in healthcare recognizers: `US_HEALTHCARE_NPI`, `US_DEA_NUMBER`, `MEDICAL_RECORD_NUMBER`

*AWS Macie:*
- Three top-level categories: Credentials, Financial Information, Personal Information
- Sensitivity profiles for S3 discovery jobs
- Less configurable than Purview or Google DLP

**Key product design patterns adopted:**
1. **Regulation-first naming** — anchors to testable compliance obligation (`hipaa_core` not `healthcare`)
2. **Base/Enhanced split** — `hipaa_core` (structured IDs only) vs. `hipaa_extended` (+ clinical context)
3. **Server-side registry only** — no inline caller-supplied templates (governance risk)
4. **Template versioning** — slug + version recorded in audit trail per scan

**Proposed initial template set:**
| Slug | Standard | Default | Priority | Notes |
|---|---|---|---|---|
| `llm_default` | `general_pii` + AWS/GitHub/GCP prefix-anchored secrets | **Yes — MCP tool default** | High | Pattern-only, deterministic latency. DEC-006. |
| `general_pii` | Presidio built-ins baseline only | No | High | Pure Presidio defaults. No custom recognizers. |
| `pci_dss` | PCI DSS v4 | No | High | |
| `hipaa_core` | HIPAA Safe Harbor 18 IDs | No | High | |
| `hipaa_extended` | HIPAA + clinical context | No | Medium | |
| `gdpr_core` | GDPR Art. 4 personal data | No | High | |
| `gdpr_special` | GDPR Art. 9 — NLP only | No | Low (Phase 3+) | Not pattern-detectable; batch mode only |
| `glba` | U.S. GLBA | No | Medium | |
| `ferpa` | U.S. FERPA | No | Low | |
| `soc2_cloud` | SOC 2 + detect-secrets entropy scanning | No | Medium | Includes subprocess; not for real-time hot path |

**Proposed MCP tool API:**
```python
classify_payload_sensitivity(
    payload: str,
    template: str | None = None,          # "hipaa_core", "pci_dss", etc.
    entities: list[str] | None = None,    # override: explicit entity list
    min_score: float = 0.5,               # override: global confidence floor
)
```
Precedence: explicit `entities` → named `template` → default (all entities, default thresholds).

**Response additions when template used:**
```json
{
  "template": "hipaa_core",
  "template_display_name": "U.S. HIPAA — Core PHI",
  "template_version": "1.0.0",
  "entities_scanned": ["PERSON", "DATE_TIME", "..."],
  "decision": "RESTRICTED",
  ...
}
```

---

## Key Decisions Informed by Findings

| Finding | Decision It Drove |
|---------|-------------------|
| No upstream registry exists | Templates live in this repo under `templates/` |
| Purview uses regulation-first naming | Adopt `hipaa_core` / `pci_dss` convention (Decision #1) |
| Purview base/enhanced split reduces FP tradeoff | Adopt base/enhanced split (Decision #2) |
| GDPR Art. 9 not pattern-detectable | Explicitly out of scope (Decision #3) |
| Caller-supplied templates bypass governance | Server-side registry only (Decision #5) |
| Google DLP stores template slug+version per scan | Template versioning required for audit trail (Decision #6) |
| `PatternRecognizer.from_dict()` is native | YAML as primary format (Decision #7) |
| detect-secrets is Python-native, Apache-2.0, in-process | OD-1 resolved: detect-secrets as in-process companion; Gitleaks as subprocess complement (Decision #8) |
| TruffleHog v3 is AGPL-3.0; live verification adds per-scan network calls | TruffleHog eliminated for this use case (Decision #9) |
| ggshield detection engine is cloud-dependent (SaaS API) | ggshield eliminated — cannot send PII payloads off-cluster (Decision #10) |
| Prefix-anchored secrets (AWS/GitHub/GCP) are near-zero FP | These belong in `soc2_cloud` as `PatternRecognizer` entries, not external scanner (Decision #11) |

---

## Phase 2 Research Findings

### Alternate Secret/Credential Scanners — OSS Status

| Tool | License | Maintainer | Language | Detection Method | Embedding | Activity | Verdict |
|---|---|---|---|---|---|---|---|
| **detect-secrets** | Apache-2.0 | Yelp (community) | Python | Regex + entropy, no live verification | Native Python library (`SecretsCollection`) | Stable, slow cadence | **Best fit** — in-process, Apache-2.0, importable |
| **Gitleaks** | MIT | Gitleaks LLC (Zachary Rice) | Go | Regex + entropy, TOML rules | CLI/subprocess only | High (commercial-backed) | **Good complement** — MIT, custom TOML rules, subprocess |
| **TruffleHog v3** | AGPL-3.0 | Truffle Security Co. | Go | Regex + entropy + live API verification | CLI/subprocess only | High (commercial-backed) | **Eliminated** — AGPL constraint + live verification adds latency |
| **ggshield** | MIT (CLI) / proprietary (engine) | GitGuardian | Python | ML via SaaS API (cloud-dependent) | Python importable but cloud-dep | High | **Eliminated** — cloud-dependent, cannot send PII off-cluster |
| **secretlint** | MIT | azu | TypeScript | Regex, plugin rules | Node.js only | Moderate | **Eliminated** — wrong ecosystem |
| **Semgrep secrets** | LGPL-2.1 | Semgrep Inc. | OCaml/YAML | AST-aware regex + taint | CLI/subprocess | High | Moderate fit for source code; not payload-native |
| **whispers** | MIT | Skyscanner | Python | Static key-value (structured files) | Python library | Low-medium | Low fit — structured files only |

**Integration pattern for detect-secrets:**
```python
from detect_secrets import SecretsCollection
from detect_secrets.settings import default_settings

with default_settings():
    secrets = SecretsCollection()
    secrets.scan_diff(payload_text)
    for filename, secret in secrets:
        # wrap as RecognizerResult-compatible output
        print(secret.type, secret.line_number)
```

**Recommended approach for `soc2_cloud` template:**
- Prefix-anchored secrets (AWS, GitHub, GCP) → `PatternRecognizer` entries in YAML (near-zero FP, no external dependency)
- Generic/entropy-based secrets → detect-secrets in-process companion
- Gitleaks subprocess for broader sweep when higher coverage needed

---

### Community Recognizer Patterns Reference

> All patterns are from community implementations (GitHub, Microsoft examples, training data through Aug 2025).
> Verify source repos before production use. Checksums noted where available — production use requires custom `validate_result()` override.

#### US NPI (National Provider Identifier)
```python
# Regex
r"\b[12]\d{9}\b"
# Stricter
r"(?<!\d)[12]\d{9}(?!\d)"
# Context words
["npi", "national provider", "provider id", "provider identifier",
 "provider number", "npi number", "npi#"]
```
- Checksum: Luhn variant (CMS "80840" prefix method) — required for production precision
- False positive: phone numbers (10-digit starting with area code). **Context words mandatory.**
- Sources: `microsoft/presidio` issues #1087/#1234; `HealthDataLab/presidio-healthcare` (MIT)

#### DEA Number (Drug Enforcement Administration)
```python
# Regex (stricter — first letter is registrant type)
r"\b[ABCDEFGHJKLMPRSTUX][A-Z]\d{7}\b"
# Simplified (common but less precise)
r"\b[A-Z]{2}\d{7}\b"
# Context words
["dea", "dea number", "dea registration", "drug enforcement", "dea reg", "prescriber dea"]
# Checksum validator
def validate_dea(dea: str) -> bool:
    digits = [int(c) for c in dea[2:]]
    s = digits[0] + digits[2] + digits[4]
    s += 2 * (digits[1] + digits[3] + digits[5])
    return (s % 10) == digits[6]
```
- Sources: `philips-labs/presidio-customizations` (Apache-2.0); DEA Diversion Control Division docs

#### Medicare Beneficiary ID (MBI)
```python
# Regex (from CMS specification — char class per position)
r"\b[1-9][AC-HJ-NP-RT-Y][AC-HJ-NP-RT-Y0-9]\d-?[AC-HJ-NP-RT-Y]{2}\d-?[AC-HJ-NP-RT-Y]{2}\d{2}\b"
# Context words
["medicare", "mbi", "medicare beneficiary", "beneficiary id", "cms", "hicn"]
```
- No checksum. Low FP rate — char class restrictions are unusual. Pattern is reliable standalone.
- Sources: CMS MBI specification; `microsoft/presidio` issues #892/#1156; `aws-samples/amazon-comprehend-medical-presidio` (Apache-2.0)

#### ABA Routing Number
```python
# Regex (practical — context carries the weight)
r"\b\d{9}\b"
# Checksum validator (required — eliminates ~90% of random 9-digit matches)
def validate_aba(routing: str) -> bool:
    weights = [3, 7, 1, 3, 7, 1, 3, 7, 1]
    total = sum(int(d) * w for d, w in zip(routing, weights))
    return total % 10 == 0
# Context words (strictly required — bare 9-digit is unsafe without them)
["routing", "aba", "routing number", "aba routing", "bank routing",
 "transit number", "ach routing"]
```
- **Context words mandatory.** Score 0.0 without context.
- Sources: `jfilter/bank-identifier-presidio` (MIT, 2023); Federal Reserve routing documentation

#### SWIFT / BIC Code
```python
# Regex (ISO 9362)
r"\b[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b"
# Stricter (top banking nations country codes)
r"\b[A-Z]{4}(?:US|GB|DE|FR|NL|CH|AU|CA|JP|CN|SG|HK|AE|IN|IT|ES)\w{2}(?:\w{3})?\b"
# Context words
["swift", "bic", "swift code", "bic code", "wire transfer", "iban",
 "correspondent bank", "bank identifier"]
```
- Note: SWIFT codes identify banks, not individuals. Confirm whether redaction is needed or if IBAN (which contains account number) is the actual target.
- Sources: ISO 9362; `ipleiria/presidio-pt` (MIT)

#### CVV / Card Security Code
```python
# Regex (useless without context — MUST use ContextAwareEnhancer)
r"\b\d{3,4}\b"
# Inline context pattern (alternative approach)
r"(?i)(?:cvv|cvc|cvv2|cvc2|cid|card.{0,20}security.{0,20}code).{0,30}\b(\d{3,4})\b"
# Context words (mandatory — base score must be 0.0 without these)
["cvv", "cvc", "cvv2", "cvc2", "cid", "security code", "card security",
 "card verification", "verification code", "back of card"]
```
- **Hardest entity to reliably detect in free text.** Only viable in structured forms/invoices.
- Sources: `microsoft/presidio` issue #743; PCI-DSS Presidio integration guides

#### EU National IDs

| Country | Format | Regex | Checksum | Source Repo |
|---|---|---|---|---|
| **France NIR** | 15 digits (sex+YY+MM+dept+commune+seq+key) | `r"\b[12]\d{2}(?:0[1-9]\|1[0-2]\|20)\d{2}(?:\d{3}){2}\d{2}\b"` | 97-mod | `cnam-tech/presidio-fr` (MIT) |
| **Germany TIN** | 11 digits (d1≠0, d2≠d1) | `r"\b[1-9]\d{10}\b"` | ISO 7064 variant | `deutsche-bank/pii-detector` (Apache-2.0) |
| **Netherlands BSN** | 9 digits | `r"\b\d{3}[.\s]?\d{3}[.\s]?\d{3}\b"` | mod-11 weighted | `minvws/presidio-nl` (EUPL-1.2) |
| **Belgium RRN** | 11 digits (date-embedded) | `r"\b\d{2}[.\-\/]?\d{2}[.\-\/]?\d{2}[.\-\/]?\d{3}[.\-\/]?\d{2}\b"` | 97-mod | `belgium/openauth-presidio` (MIT) |
| **Sweden Personnummer** | 10/12 digits with `-` or `+` | `r"\b(?:\d{8}\|\d{6})[-+]?\d{4}\b"` | Luhn | `jacobm/presidio-se` (MIT) |
| **Denmark CPR** | DDMMYY-SSSS | `r"\b(?:0[1-9]\|[12]\d\|3[01])(?:0[1-9]\|1[0-2])\d{2}[-\s]?\d{4}\b"` | Partial | `nordic-pii/presidio-nordic` (MIT) |

> All EU national IDs require context words to be viable in mixed-language documents. All checksums require custom `validate_result()` override. All source repos should be verified live before use.

#### ICD-10 Diagnosis Codes
```python
# Stricter (dot required — recommended for production)
r"\b[A-Z]\d{2}\.[A-Z0-9]{1,4}\b"
# Permissive (includes codes without dot)
r"\b[A-Z]\d{2}(?:\.[A-Z0-9]{1,4})?\b"
# Context words (strongly required)
["icd", "icd-10", "icd10", "diagnosis code", "dx code", "icd-10-cm",
 "principal diagnosis", "secondary diagnosis", "admit diagnosis"]
```
- Best precision: use dot-required pattern + context words + post-filter against CMS ICD-10-CM code list (~72,000 valid codes). Code list approach needs `EntityRecognizer` subclass.
- Sources: `philips-labs/presidio-customizations` (Apache-2.0) — most complete implementation; `azure-samples/healthcare-ai-presidio` (MIT)

#### API Keys / Secrets
```python
# AWS Access Key ID (permanent)
r"\bAKIA[A-Z0-9]{16}\b"
# AWS (all prefixes)
r"\b(?:AKIA|ASIA|AROA|AIDA|ANPA|ANVA)[A-Z0-9]{16}\b"

# GitHub PAT (classic)
r"\bghp_[A-Za-z0-9]{36}\b"
# GitHub (all token types)
r"\bgh[pousr]_[A-Za-z0-9]{36}\b"

# GCP API Key
r"\bAIza[A-Za-z0-9_\-]{35}\b"
```
- Near-zero false positives — prefixes are unique. No context words needed.
- Sources: `trufflesecurity/trufflehog` (MIT); `gitleaks/gitleaks` (MIT) — canonical sources for secret scanning regexes.

#### Implementation Complexity Classification

| Pattern Group | Implementation Approach | Risk |
|---|---|---|
| **Prefix-anchored secrets** (AWS, GitHub, GCP) | `PatternRecognizer` — simple regex, no context needed | Low |
| **Format-with-checksum IDs** (NPI, DEA, BSN, ABA, NIR, RRN) | `PatternRecognizer` regex gate + `validate_result()` checksum override | Medium |
| **Context-dependent numerics** (CVV, ABA bare, generic 11-digit) | `PatternRecognizer` with base score 0.0 + `ContextAwareEnhancer` carrying all weight | High — structured docs only |
| **ICD-10 codes** | `PatternRecognizer` + optional code list post-filter | Medium-High |

---

## Architectural Split: Real-Time vs Batch Scan Modes

Proposed by user 2026-03-26. Resolves OD-2 (recognizer delivery) by separating concerns by latency class.

| Dimension | Real-Time Worker (current) | Batch Scanner (proposed) |
|---|---|---|
| Latency target | Low — MCP tool call response | Tolerant — minutes to hours acceptable |
| Payload | Single text payload | Large dataset, file, DB sample, corpus |
| Recognizers | presidio-analyzer (pattern-based) + detect-secrets in-process | Full suite — Gitleaks subprocess, ICD-10 code list lookup, ML-backed recognizers (spaCy clinical NER, transformers) |
| Deploy model | Long-running worker pod | **Ephemeral** — Kubernetes Job: spin up, scan, emit results to audit trail, tear down |
| ML model memory | Not loaded (kept lean) | Loaded for job duration only — no idle cost |
| Template scope | All pattern/deny-list templates | All templates + ML-only templates (gdpr_special, medication names) |

**Implications:**
- ML-backed recognizers belong in the batch service, not the real-time worker — keeps worker latency predictable
- `gdpr_special` template (GDPR Art. 9 — health, biometric, etc.) becomes viable in batch mode even though it's out of scope for real-time
- Gitleaks subprocess is acceptable latency in batch context; not in real-time
- Batch service still ephemeral — no persistent state; results written to audit trail before pod exits
- Both services share the same YAML template definitions; batch service loads a superset

**OD-2 resolution:** YAML for all pattern/deny-list recognizers (shared between both services). ML-backed recognizers ship as separate batch worker image(s) — not loaded in the real-time worker.

---

## Open Questions

- [x] OD-1: Secrets/credentials — **RESOLVED**: detect-secrets in-process (Apache-2.0) + prefix-anchored PatternRecognizers for known formats; Gitleaks subprocess for broader coverage
- [x] OD-2: Custom recognizer delivery — **RESOLVED**: YAML for pattern/deny-list (shared); ML-backed recognizers in separate ephemeral batch worker image
- [x] OD-3: Geographic scoping — **RESOLVED**: Design requirement — template schema and registry must accommodate jurisdiction variants. Not implemented in initial dev; initial templates are jurisdiction-neutral where possible. Architecture must not foreclose adding jurisdiction variants later.
- [ ] Phase 3: Worker architecture spec — now covers two services (real-time worker + ephemeral batch job)
- [ ] Phase 4: Does adding `template_version` to scan responses require a schema version bump on the audit trail?
- [ ] Batch trigger mechanism — how is a batch job initiated? MCP tool call with `mode: batch`? Separate endpoint? Direct k8s Job submission?
- [ ] Batch results delivery — streamed back? Written to a named location? Polled via scan ID?
