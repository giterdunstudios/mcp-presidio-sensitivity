# Agent Briefing: Lane C — Synthetic Test Corpus
**Phase:** 0
**Status:** Ready to start
**Blocked by:** Nothing — start immediately
**Blocks:** Phase 0 sign-off (corpus required for exit criteria validation)

---

## Your objective

Produce a structured set of synthetic test payloads that cover all target entity types,
sensitivity levels, and edge cases. This corpus is used to validate Presidio recognizer
coverage in Phase 0 and will serve as the regression test baseline for all future phases.

No real personal data, credentials, or sensitive information should appear anywhere
in this corpus. All data must be clearly synthetic and non-operational.

---

## Read before starting

| File | Location |
|------|----------|
| Ways of working | `role-instructions/ways-of-working.md` |
| Task plan | `planning/task_plan.md` |
| Findings | `planning/findings.md` — interim classification model |
| MVP spec | `shared/private/mcp_presidio_mvp_spec.md` — §6.3 grouped categories |

---

## Corpus structure

Produce one YAML file per category. Each file contains a list of test cases.
Each test case has:
- `id` — unique identifier
- `description` — what this case is testing
- `payload` — the synthetic text input
- `expected_sensitivity_detected` — true or false
- `expected_categories` — list of expected grouped categories
- `expected_severity_band` — low / medium / high / critical
- `expected_decision` — allow / flag / block / review
- `notes` — edge case notes if applicable

### Example entry
```yaml
- id: fin-001
  description: Single credit card number in plain text
  payload: "Please process payment for card 4111111111111111 expiry 12/28"
  expected_sensitivity_detected: true
  expected_categories:
    - financial_identifier
  expected_severity_band: high
  expected_decision: block
  notes: Luhn-valid test card number — not a real card
```

---

## Required test files

### `corpus/direct-identifier.yaml`
Cover: PERSON, DATE_TIME, AGE

Must include:
- Full name only
- Name embedded in a sentence
- Date of birth
- Age combined with name
- Multiple direct identifiers in one payload
- A payload that mentions a name-like string but is not a person (e.g. a product name)

---

### `corpus/financial-identifier.yaml`
Cover: CREDIT_CARD, IBAN_CODE, US_BANK_NUMBER

Must include:
- Credit card number (use Luhn-valid test numbers only — e.g. 4111111111111111)
- IBAN (use clearly synthetic format — e.g. GB00TEST12345678901234)
- Bank account number
- Mixed financial payload (card + IBAN together)
- A number that looks financial but is not (e.g. a product SKU of similar length)

---

### `corpus/government-identifier.yaml`
Cover: US_SSN, US_PASSPORT, US_DRIVER_LICENSE

Must include:
- SSN in standard format (use 000-00-0000 or 999-99-9999 — clearly invalid)
- SSN embedded in a sentence
- Passport number
- Driver license number
- Mixed government ID payload

---

### `corpus/contact-data.yaml`
Cover: EMAIL_ADDRESS, PHONE_NUMBER, IP_ADDRESS, URL

Must include:
- Email address only
- Phone number only (US format)
- IP address (use TEST-NET ranges: 192.0.2.x, 198.51.100.x, 203.0.113.x)
- URL containing no other sensitive data
- Email + phone combined
- An IP address in a technical log context (legitimate system log)

---

### `corpus/secrets-like.yaml`
Cover: Credential patterns, API key patterns

Must include:
- A string matching common API key patterns (e.g. `sk-test-` prefix format)
- A password in a config-like context
- A string that looks like a secret but is a placeholder (e.g. `YOUR_API_KEY_HERE`)
- A base64-encoded string that is not a secret

---

### `corpus/mixed-sensitivity.yaml`
Multi-entity payloads that span multiple categories

Must include:
- Name + email + phone (direct + contact)
- Credit card + name (financial + direct)
- SSN + bank account (government + financial)
- A rich paragraph containing 4+ entity types
- A payload at high volume (repeat entities to test counting behavior)

---

### `corpus/negative.yaml`
Payloads that should produce NO sensitivity findings

Must include:
- A generic business memo with no personal data
- A technical document describing a system (no real IPs, no real names)
- A lorem ipsum paragraph
- A paragraph of numbers that are not sensitive (order quantities, product IDs)
- A paragraph with words that sound like names but are not (e.g. company names)
- An empty string (edge case — should return `allow`, `sensitivity_detected: false`)

---

### `corpus/edge-cases.yaml`
Boundary and adversarial cases

Must include:
- A payload at exactly the maximum size boundary (use a long neutral text)
- A payload with unicode characters and non-ASCII text
- A payload where the sensitive data is split across a line break
- A payload with a low-confidence partial match (e.g. a partial phone number)
- A payload where the same entity appears 10+ times
- A payload in a code block format (e.g. JSON or Python dict containing an email)

---

## Naming and formatting rules

- All IDs follow pattern: `{category-prefix}-{zero-padded number}` (e.g. `fin-001`)
- All credit card numbers must be Luhn-valid test numbers (not real cards)
- All SSNs must use 000-xx-xxxx or 999-xx-xxxx format (IRS-reserved invalid ranges)
- All IPs must use IANA TEST-NET ranges
- All email domains must use `example.com`, `test.example`, or `invalid.test`
- No real names of real people — use clearly fictional names (e.g. Jane Testperson, John Synthetic)
- No real addresses

---

## Deliverables

| File | Location |
|------|----------|
| `corpus/direct-identifier.yaml` | `deliverables/lane-c/` |
| `corpus/financial-identifier.yaml` | `deliverables/lane-c/` |
| `corpus/government-identifier.yaml` | `deliverables/lane-c/` |
| `corpus/contact-data.yaml` | `deliverables/lane-c/` |
| `corpus/secrets-like.yaml` | `deliverables/lane-c/` |
| `corpus/mixed-sensitivity.yaml` | `deliverables/lane-c/` |
| `corpus/negative.yaml` | `deliverables/lane-c/` |
| `corpus/edge-cases.yaml` | `deliverables/lane-c/` |
| `corpus-coverage-report.md` | `deliverables/lane-c/` |

### `corpus-coverage-report.md` must contain:
- Total test case count
- Count per category
- Any entity types from findings.md interim model that could not be covered with synthetic data and why
- Any recognizer gaps suspected (e.g. entity types Presidio may not detect reliably)
- Recommendations for Phase 1 corpus expansion

---

## Definition of done

- [ ] All 8 corpus files produced with minimum case counts met
- [ ] No real personal data, real credentials, or real sensitive information in any file
- [ ] All IDs unique across the corpus
- [ ] `corpus-coverage-report.md` completed and committed
- [ ] All files committed to repo

---

## Handoff

When done, notify the operator. This corpus feeds directly into:
- Phase 0 exit criteria: Presidio recognizer coverage validation
- Phase 1 acceptance testing
- Ongoing regression testing for all future phases

No infrastructure required. This lane can be completed entirely without the cluster.
