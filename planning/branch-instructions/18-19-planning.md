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
- [ ] Proposes a concrete implementation phase: scope, sequencing relative to Phase 3, what is in vs out of scope for that phase
- [ ] Flags the three open decisions that require council resolution before implementation can begin: (1) secrets/credentials vertical scope, (2) custom recognizer delivery mechanism, (3) geographic scoping for GDPR entities
- [ ] Each open decision is clearly marked "requires council decision before implementation"
- [ ] Document ends with a council vote request section that states what the council is being asked to approve

### Item #19 — SLO definition
- [ ] New file `planning/slo-definition.md` created
- [ ] Defines p50 and p99 latency targets for `classify_payload_sensitivity` (end-to-end, measured at the MCP server)
- [ ] Defines error rate target (percentage of non-5xx responses over a rolling window)
- [ ] Defines scan duration distribution target (specifically the worker `/scan` call, not the full round-trip)
- [ ] Specifies measurement method for each target: which Prometheus metric name, which Grafana panel or query
- [ ] If the cluster is accessible at `http://localhost:3000`, pull actual baseline numbers before setting targets; if not, document placeholder targets clearly marked as `[PLACEHOLDER — measure before finalising]`
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
- The Presidio worker exposes `/metrics` but Prometheus cannot scrape it directly due to NetworkPolicy (DEC-001). This means worker-specific metrics may require `kubectl exec` to retrieve — document this constraint in the SLO definition.
- Phase 2 Istio sidecar adds ~2–5ms latency overhead per hop. Account for this in target-setting.

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
