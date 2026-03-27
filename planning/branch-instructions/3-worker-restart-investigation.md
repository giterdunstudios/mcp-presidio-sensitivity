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
- [ ] If root cause is OOMKill: document memory usage pattern; propose raising the `resources.limits.memory` in `helm/presidio-worker/values.yaml` as a new backlog item (512Mi is a configured limit, not a hardware constraint — it can be increased)
- [ ] If root cause is readiness/liveness probe misconfiguration: document specific probe config fields with current vs proposed values; open new backlog item
- [ ] If root cause is application crash: provide full stack trace; open a council review session before committing findings — do not commit without council alignment
- [ ] If root cause is tmpfs exhaustion: document `/tmp` usage vs 128Mi `sizeLimit` and Presidio scratch behavior; open new backlog item
- [ ] If root cause is Istio sidecar init failure: document sidecar container logs and istiod state; open new backlog item
- [ ] If root cause is Other: document the finding in full and open a new backlog item regardless of severity
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
- `OOMKilled` in the describe output (Last State section). Note: OOMKill exit code is 137. Memory limit is `512Mi` in `helm/presidio-worker/values.yaml`; spaCy `en_core_web_lg` alone is ~500MB resident, leaving limited headroom per-request. If OOMKill is confirmed, the fix is to raise the limit in `values.yaml` — this is a configured ceiling, not a hardware constraint, and there is room to increase it.
- Probe failures (`Liveness probe failed`, `Readiness probe failed`)
- Application-level errors in logs (Python tracebacks, spaCy model load failures)
- `ENOSPC` errors in tracebacks — indicates `/tmp` exhaustion (128Mi `sizeLimit` in `helm/presidio-worker/values.yaml`). This is distinct from OOMKill — `kubectl describe` will NOT show `OOMKilled`.
- Istio sidecar init failures — check sidecar container: `./scripts/devtools-run.sh kubectl logs -c istio-proxy -n mcp-presidio <pod> --previous`
- `kubectl top pod` memory vs the limit in `helm/presidio-worker/values.yaml`; if `kubectl top pod` returns "metrics not available", check `./scripts/devtools-run.sh kubectl get pods -n kube-system | grep metrics-server`

**PII warning:** Before including previous-container log output in the findings addendum or sharing it externally, review it for payload content. If text payload appears in the logs (e.g. in a Python traceback from Presidio's analyzer), redact it and note the redaction in the findings.

## What the validation owner checks
- Findings addendum is present and clearly states one of the three root cause categories
- If OOMKill: memory numbers are cited with evidence (from `kubectl describe` Last State)
- If probe misconfiguration: specific probe config fields cited with current vs proposed values
- If application crash: full stack trace is included
- Confirms no src/, helm/, or scripts/ files were modified on this branch (`git diff HEAD~1 --name-only` should show only `planning/branch-instructions/3-worker-restart-investigation.md`)

## Notes / constraints
- `branch-test.sh` is NOT required for this branch — there are no code changes to validate.
- Run `./scripts/status.sh` first to confirm current pod state before investigating.
- The worker loads a spaCy `en_core_web_lg` model at startup (~500 MB resident). This is a known memory cost — the question is whether the pod is being OOMKilled against its configured limit, or crashing for a different reason.
- Do not attempt to fix the issue on this branch. Document findings and open a new backlog item with the proposed fix.
- If the worker is currently stable (0 recent restarts), check whether the restarts occurred during a previous cluster run (restart count persists across pod restarts within a cluster lifetime but resets on cluster recreate). Note this in findings.

---

## Findings Addendum

**Date investigated:** 2026-03-27

**Investigator:** Technical Implementation Lead

**Restart count at time of investigation:** 0 (current pod; no previous terminated container in this cluster run)

**Root cause category:** [x] OOMKill (imminent risk — not yet triggered in current cluster run, but memory headroom is critically low)

**Evidence:**

Pod `presidio-worker-6cdd5dbb94-cpdfs` was started via a manual rolling restart at `2026-03-27T17:34:32Z` (confirmed by the `kubectl.kubernetes.io/restartedAt` annotation on the pod — this was a `rebuild.sh` deploy, not a crash restart). The pod has been Running for 5h14m with 0 restarts. There are no events in the `mcp-presidio` namespace and no previous terminated container logs. The original "9+ restarts" referenced in the branch goal occurred in a prior cluster run; restart counts reset on cluster recreate.

**Current memory state (from `kubectl top pods --containers`):**

| Container | Limit | Current Usage | Headroom |
|---|---|---|---|
| `presidio-worker` | 768Mi | 757Mi | 11Mi (1.4%) |
| `istio-proxy` | 1Gi | 25Mi | n/a |

The `presidio-worker` container is at **98.6% of its 768Mi limit at idle**. The 768Mi limit is applied via `helm/presidio-worker/values.local.yaml` — it overrides the `values.yaml` default of 512Mi (which would already OOMKill at startup given ~757Mi idle RSS). The 512Mi default in `values.yaml` is therefore incorrect for this workload.

**`kubectl describe pod` — key sections:**

```
State:          Running
  Started:      Fri, 27 Mar 2026 17:34:43 +0000
Ready:          True
Restart Count:  0
Limits:
  cpu:     1
  memory:  768Mi
Requests:
  cpu:      250m
  memory:   512Mi
Liveness:   http-get http://:15020/app-health/presidio-worker/livez delay=45s timeout=5s period=30s #success=1 #failure=3
Readiness:  http-get http://:15020/app-health/presidio-worker/readyz delay=45s timeout=5s period=10s #success=1 #failure=3
Events:     <none>
```

The 45s initial delay on both liveness and readiness probes is appropriate for spaCy model load time (~1-2s observed in current logs, but the delay provides margin).

**No previous container logs available** — `kubectl logs --previous` returned `BadRequest: previous terminated container "presidio-worker" not found`. No OOMKill evidence exists in the current cluster run.

**Memory configuration discrepancy:**
- `helm/presidio-worker/values.yaml` (committed): `limits.memory: 512Mi` — **insufficient for this workload**
- `helm/presidio-worker/values.local.yaml` (override): `limits.memory: 768Mi` — currently deployed limit
- Idle RSS at 757Mi means any in-flight scan that increases memory even marginally will trigger OOMKill

**Conclusion:**

The current cluster run shows 0 restarts, but the pod is operating at 98.6% of its memory limit at idle. The prior "9+ restarts" almost certainly were OOMKills: the `values.yaml` default of 512Mi is well below the spaCy `en_core_web_lg` idle RSS (~757Mi), so any deployment using the default limit without the local override would OOMKill within seconds of startup. The local override of 768Mi keeps the pod alive but provides only 11Mi of headroom — insufficient to handle scan requests involving large payloads or concurrent requests without triggering OOMKill.

The root cause for historical restarts: **OOMKill caused by `values.yaml` default `limits.memory: 512Mi` being below the spaCy model's idle RSS.** The local override of 768Mi is a temporary mitigation, not a safe production configuration.

Secondary risk: the 768Mi local override is itself too low for production use. Any scan request that causes Presidio to hold the scanned payload plus analysis intermediates in memory alongside the 757Mi idle RSS will OOMKill. The limit needs to be raised substantially, and the `values.yaml` default must be corrected so deployments without the local override do not OOMKill immediately.

**Follow-up action:**

Proposed backlog item: **Raise `presidio-worker` memory limit in `values.yaml` to a safe default for the spaCy `en_core_web_lg` workload.**

- Current `values.yaml` default (512Mi) OOMKills at startup. Must be corrected.
- Proposed: raise `values.yaml` `limits.memory` to at least `1Gi` (preferably `1.5Gi`) to accommodate idle RSS (~757Mi) plus per-request headroom for concurrent scans and Presidio analyzer intermediates.
- Update `requests.memory` accordingly (currently 256Mi — also too low; set to `768Mi` or `1Gi`).
- Remove the memory override from `values.local.yaml` once `values.yaml` has a correct default (or retain local override only if local environment has tighter resource constraints than the target).
- Priority: high — the current pod is one large scan away from OOMKill.
- Proposed owner: Technical Implementation Lead.
- Note: this is a `helm/` change; do NOT implement on this investigation branch.
