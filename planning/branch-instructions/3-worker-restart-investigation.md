---
branch: 3-worker-restart-investigation
wave: 1
items: "#3"
impl_owner: Technical Implementation Lead
validation_owner: Engineering Practices Lead
status: ready
---

# Branch: 3-worker-restart-investigation

## Goal
Determine why the presidio-worker pod has accumulated 9+ restarts; document the root cause or escalate as a new code-fix item if changes are needed.

## Items covered
| # | Item |
|---|------|
| #3 | Worker pod restart root cause investigation |

## Acceptance criteria
- [ ] Root cause identified and documented in this file as a findings addendum (see template at bottom)
- [ ] If root cause is OOMKill: document memory usage pattern, propose resource limit adjustment as a new backlog item
- [ ] If root cause is readiness/liveness probe misconfiguration: document and propose fix as new backlog item
- [ ] If root cause is application crash: provide stack trace and escalate immediately to the council
- [ ] No code changes on this branch — investigation and documentation only

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `planning/branch-instructions/3-worker-restart-investigation.md` | Modify | Add findings addendum at bottom of this file |

## Files to leave alone
All `src/`, `helm/`, `scripts/` files — no code changes on this branch. If a fix is required, open a new backlog item and leave the fix for a separate branch.

## Decisions that apply to this branch
- DEC-001: Worker is reached only via the MCP server pod over plain HTTP (cluster-internal). External access to the worker is blocked by NetworkPolicy.
- Phase 2 target: Istio sidecar will be injected into the worker pod. Probe or resource issues that exist now must be resolved before Istio sidecar injection adds additional memory pressure.

## How to validate
Run the following commands to gather evidence. Use `./scripts/devtools-run.sh kubectl ...` if kubectl is not installed on the host.

```bash
# 1. Check current pod state and restart count
./scripts/devtools-run.sh kubectl describe pod -n mcp-presidio \
  -l app.kubernetes.io/name=presidio-worker

# 2. Check current logs
./scripts/devtools-run.sh kubectl logs -n mcp-presidio \
  -l app.kubernetes.io/name=presidio-worker --tail=200

# 3. Check logs from the previous (crashed) container instance
./scripts/devtools-run.sh kubectl logs -n mcp-presidio \
  -l app.kubernetes.io/name=presidio-worker --previous --tail=200

# 4. Check events in the namespace
./scripts/devtools-run.sh kubectl get events -n mcp-presidio \
  --sort-by='.lastTimestamp' | tail -40

# 5. Check resource usage
./scripts/devtools-run.sh kubectl top pod -n mcp-presidio

# 6. Confirm current pod health
./scripts/status.sh
```

Look for:
- `OOMKilled` in the describe output (Last State section)
- Probe failures (`Liveness probe failed`, `Readiness probe failed`)
- Application-level errors in logs (Python tracebacks, spaCy model load failures)
- `kubectl top pod` memory vs the limit in `helm/presidio-worker/values.yaml`

## What the validation owner checks
- Findings addendum is present and clearly states one of the three root cause categories
- If OOMKill: memory numbers are cited with evidence (from `kubectl describe` Last State)
- If probe misconfiguration: specific probe config fields cited with current vs proposed values
- If application crash: full stack trace is included
- Confirms no src/, helm/, or scripts/ files were modified on this branch

## Notes / constraints
- `branch-test.sh` is NOT required for this branch — there are no code changes to validate.
- Run `./scripts/status.sh` first to confirm current pod state before investigating.
- The worker loads a spaCy `en_core_web_lg` model at startup (~500 MB resident). This is a known memory cost — the question is whether the pod is being OOMKilled against its configured limit, or crashing for a different reason.
- Do not attempt to fix the issue on this branch. Document findings and open a new backlog item with the proposed fix.
- If the worker is currently stable (0 recent restarts), check whether the restarts occurred during a previous cluster run (restart count persists across pod restarts within a cluster lifetime but resets on cluster recreate). Note this in findings.

---

## Findings Addendum
*(Fill this section in during investigation — leave blank until investigation is complete)*

**Date investigated:**

**Investigator:**

**Restart count at time of investigation:**

**Root cause category:** [ ] OOMKill  [ ] Probe misconfiguration  [ ] Application crash  [ ] Other

**Evidence:**

**Conclusion:**

**Follow-up action:**
(New backlog item # if applicable, or "no action required")
