---
branch: 18-19-planning
wave: 1
items: "#18, #19"
impl_owner: Product / Scope Lead
validation_owner: Engineering Practices Lead
status: ready
---

# Branch: 18-19-planning

## Goal
Produce a vertical templates phase proposal ready for council vote (#18), and an initial SLO definition with baseline metrics and measurement methods (#19).

## Items covered
| # | Item |
|---|------|
| #18 | Vertical templates scheduling — phase proposal for council vote |
| #19 | SLO definition — latency, error rate, scan duration targets |

## Acceptance criteria

### Item #18 — Vertical templates phase proposal
- [ ] New file `planning/vertical-templates/phase-proposal.md` created
- [ ] Opens by acknowledging what DEC-006 already established: `llm_default` is implemented; `general_pii` is the built-ins baseline; vertical templates (`hipaa_core`, `pci_dss`, etc.) are opt-in overlays for domain-aware callers. The phase proposal scopes the remaining vertical templates only — `llm_default` is NOT in scope, it is already done.
- [ ] Presents the three open decisions from `findings.md` (OD-1, OD-2, OD-3) with their existing resolution text from `task_plan.md` and flags them as "requiring council ratification" — not as still-open questions (they have proposed resolutions, not unresolved questions)
- [ ] Describes what `task_plan.md` Phases 3 and 4 (Worker Architecture Spec, Audit Trail/API Additions) cover and proposes their sequencing relative to the project Phase 3 (post-Istio) work — this is the concrete scheduling question the item is meant to answer
- [ ] Includes a compliance disclaimer section: vertical template names are classification aids only — they do not confer compliance status on the caller's data processing
- [ ] Document ends with a council vote request section listing discrete yes/no questions (not narrative), structured per `task_plan.md` Phase 5 gate: three sign-offs required (Security Lead, Tech Lead, Product Lead)

### Item #19 — SLO definition
- [ ] New file `planning/slo-definition.md` created
- [ ] Uses a table with columns: `SLO | Target | Metric | Query | Window | Aspirational/Measured | Baseline`
- [ ] Defines p50 and p99 latency SLO for `classify_payload_sensitivity` using metric `mcp_request_duration_seconds{path="/mcp", status_code="200"}` (filter to successful MCP calls only)
- [ ] Defines error rate SLO; notes that auth denial counts (401/403) are counted by the Envoy sidecar, not by `mcp_scan_errors_total` — these are not captured by app metrics
- [ ] Defines scan duration SLO using metric `mcp_worker_call_duration_seconds` (the only worker-side timing proxy available from the MCP server — the worker's own `/metrics` cannot be scraped due to NetworkPolicy)
- [ ] Defines an availability SLO placeholder, marked `[PLACEHOLDER — metric not yet instrumented]` with a note pointing to backlog item #39 (heartbeat metric or synthetic probe needed)
- [ ] Rolling window duration is specified for each SLO (not left implicit)
- [ ] If the cluster is accessible at `http://localhost:3000`, pull actual baseline numbers before setting targets; if not, use placeholder targets. Warm-path Presidio p99 latency is typically 200–500ms for short payloads — use this as a calibration point for placeholders
- [ ] Notes which targets are aspirational vs measured

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `planning/vertical-templates/phase-proposal.md` | Create | New file |
| `planning/slo-definition.md` | Create | New file |

## Files to leave alone
All `src/`, `helm/`, `scripts/` files. All existing `planning/vertical-templates/` files (read-only reference). Documentation-only branch.

## Decisions that apply to this branch

### Vertical templates context
- DEC-006: The default template is `llm_default` (not `general_pii`). Vertical templates (`hipaa_core`, `pci_dss`, etc.) are opt-in overlays for domain-aware callers.
- The vertical templates research synthesis is in `planning/vertical-templates/findings.md` and `planning/vertical-templates/task_plan.md`. Read these before writing the proposal.
- The three open decisions that blocked scheduling were identified in the council research synthesis. They are: (1) whether a "secrets/credentials" vertical should be a named template or whether `llm_default` already covers it sufficiently; (2) how custom recognizers are delivered (baked into the worker image vs loaded at runtime); (3) whether GDPR-specific geographic entity types should be gated by a `gdpr_eu` template or included in `general_pii`.

### SLO context
- The MCP server exposes a `/metrics` endpoint (Prometheus format). Grafana is deployed at `http://localhost:3000` (host port). Jaeger is at `http://localhost:16686`.
- Real metric names (cross-check in `src/mcp_server/observability/metrics.py`): `mcp_request_duration_seconds` (labels: `path`, `status_code`), `mcp_worker_call_duration_seconds` (no labels), `mcp_scan_errors_total` (label: `error_code`).
- The Presidio worker exposes `/metrics` but Prometheus cannot scrape it directly due to NetworkPolicy — `mcp_worker_call_duration_seconds` (recorded by the MCP server when it calls the worker) is the only proxy for worker scan time available from accessible metrics.
- Auth denial counts (401/403) are counted by the Envoy sidecar, not the MCP server application. The error rate SLO must document this gap: app-side `mcp_scan_errors_total` does not capture auth failures.
- Phase 2 Istio sidecar adds ~2–5ms latency overhead per hop. Account for this in target-setting.
- Availability SLO requires a heartbeat metric or external synthetic probe (neither exists today — see backlog item #39). Mark availability target as `[PLACEHOLDER — metric not yet instrumented]`.

## How to validate

### For #18
```bash
# Read the existing research documents first
cat planning/vertical-templates/findings.md
cat planning/vertical-templates/task_plan.md

# Then read the proposal you wrote
cat planning/vertical-templates/phase-proposal.md
```
Confirm: proposal is concrete (names a phase, not just "future work"), three open decisions are present and marked, council vote request section exists.

### For #19
```bash
# Check if Grafana is accessible
curl -s http://localhost:3000/api/health | python3 -m json.tool

# If accessible, check available metrics
curl -s http://localhost:9090/api/v1/label/__name__/values | python3 -m json.tool | grep classify

# Read the SLO definition
cat planning/slo-definition.md
```
Confirm: all three SLO categories present (latency, error rate, scan duration), measurement methods specified, placeholder markers present if baseline was not measured.

No `branch-test.sh` run required — documentation-only branch.

## What the validation owner checks

### For #18
- File exists at `planning/vertical-templates/phase-proposal.md`
- Three open decisions are explicitly named and marked as requiring council decision
- Proposal does not pre-decide the open questions (it surfaces them, not resolves them)
- Council vote request section clearly states what the council is being asked to approve
- Content is consistent with `planning/vertical-templates/findings.md` (no contradictions)

### For #19
- File exists at `planning/slo-definition.md`
- p50 and p99 latency targets are present
- Error rate target is present
- Scan duration target is present
- Prometheus metric names cited are real (cross-check against `src/mcp_server/` metrics implementation)
- Any placeholder targets are clearly marked
- Worker metrics limitation (NetworkPolicy blocks direct Prometheus scrape) is noted

## Notes / constraints
- Item #18 produces a proposal for council vote, not a council decision. Do not make design decisions in this document. Surface the open questions with enough context for the council to decide.
- Item #19 SLO targets should be achievable, not aspirational marketing numbers. If baseline data is not available, use placeholder targets and flag them explicitly. Unrealistic SLOs that are never measured are worse than no SLOs.
- The two items are independent — they can be written in either order. They share a branch because both are planning documents with no code changes.
- Reference `planning/decision-log.md` DEC-006 for the default template decisions already made. The phase proposal builds on top of what is already resolved.
