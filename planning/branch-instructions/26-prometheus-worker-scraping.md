---
branch: 26-prometheus-worker-scraping
wave: 4
items: "#26"
impl_owner: Technical Implementation Lead
validation_owner: Security / Privacy Lead
status: ready
---

# Branch: 26-prometheus-worker-scraping

## Goal
Verify that Prometheus can directly scrape the Presidio worker `/metrics` endpoint (the NetworkPolicy ingress rule and scrape config are already in place) — validate end-to-end, remove the `kubectl exec` workaround from `status.sh`, and update the architecture diagram.

## Items covered
| # | Item |
|---|------|
| #26 | Prometheus → Worker direct scraping |

## Current state (before this branch)
The architecture diagram and `status.sh` treat the worker `/metrics` endpoint as unreachable by Prometheus and use `kubectl exec` as a workaround. **However, as of the Phase 2 / Wave 3 validation:**
- `helm/presidio-worker/templates/networkpolicy.yaml` already has an ingress rule allowing `app: prometheus` pods on port 8080
- `infrastructure/prometheus.yaml` already has a scrape config for `presidio-worker.mcp-presidio.svc.cluster.local:8080`
- The Prometheus pod has `app: prometheus` label matching the NetworkPolicy

This branch validates that scraping is actually working end-to-end and removes the now-unnecessary `kubectl exec` workaround from `status.sh`. It also updates the architecture diagram to reflect the current state.

## Acceptance criteria
- [ ] Prometheus successfully scrapes the worker: confirm `up{job="presidio-worker"}` = 1 in Prometheus
- [ ] `scripts/status.sh` updated: worker `/metrics` check uses direct HTTP request (not `kubectl exec`), OR the comment is updated to reflect that scraping is now working
- [ ] `planning/architecture-diagram.md` updated: remove the "Cannot scrape directly (NetworkPolicy); uses kubectl exec" annotation from the Prometheus → Worker arrow; replace with accurate current state
- [ ] If Prometheus scraping is NOT working (validation step 1 fails): document the exact blocking condition, open a targeted backlog item, and do not close this branch as complete
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/status.sh` | Modify | Update worker metrics check — remove kubectl exec workaround if scraping is verified |
| `planning/architecture-diagram.md` | Modify | Update Prometheus → Worker annotation |

## Files to leave alone
`helm/presidio-worker/templates/networkpolicy.yaml` (already has the rule — do not modify unless verification reveals a bug). `infrastructure/prometheus.yaml` (already has the scrape config — do not modify unless verification reveals a bug). All `src/` files.

## Decisions that apply to this branch

### kubectl exec workaround in status.sh
`status.sh` lines 88–96 and 169–174 use `kubectl exec` to check worker health and metrics because the NetworkPolicy was believed to block direct access. If direct Prometheus scraping is confirmed working, the worker health check in `status.sh` can remain as `kubectl exec` (it's checking internal health, not Prometheus scraping) but the comment should be updated. The `/metrics` check at lines 169–174 can optionally be replaced with a Prometheus query.

### Architecture diagram update
The architecture diagram contains a comment: "Cannot scrape directly (NetworkPolicy); uses kubectl exec — Phase 3 fix needed". This is inaccurate if scraping is now working. Replace with the accurate description.

## How to validate

```bash
# 1. Check if Prometheus is scraping the worker successfully
curl -s "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22presidio-worker%22%7D" | python3 -m json.tool
# Look for: "value": [<timestamp>, "1"]  — 1 = up, 0 = down, absent = not found

# 2. If up=1: check worker metrics are available in Prometheus
curl -s "http://localhost:9090/api/v1/label/__name__/values" | python3 -m json.tool | grep -i worker

# 3. If scraping is working — update status.sh worker metrics check
# Replace the kubectl exec block at lines ~169-174 with a simpler note or Prometheus query

# 4. Validate status.sh still passes
./scripts/status.sh

# 5. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- Prometheus `up{job="presidio-worker"}` = 1 (screenshot or output pasted into PR description)
- `status.sh` diff: comment updated or kubectl exec workaround removed
- Architecture diagram diff: "Cannot scrape" annotation removed, replaced with accurate text
- If scraping is NOT working: a new backlog item exists documenting the blocking condition
- `branch-test.sh` passes

## Notes / constraints

### If up=0 or metric not found
If step 1 returns `up=0` or the metric is absent:

1. Check Prometheus targets: `curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -A10 "presidio-worker"`
2. Check for "connection refused" or timeout in the target state — this indicates the pod is reachable by Prometheus but the port is wrong, or the NetworkPolicy is blocking
3. Check the NetworkPolicy label match: `kubectl get pods -n mcp-presidio -l app=prometheus` — if this returns no pods, the Prometheus pod does not have the expected label and the NetworkPolicy rule won't match
4. Check Prometheus pod labels: `kubectl get pods -n mcp-presidio --show-labels | grep prometheus`

If the blocking condition is a label mismatch: the fix is either to update the NetworkPolicy rule to match the actual Prometheus label, or to label the Prometheus pod correctly. Document the exact finding and open a targeted backlog item before closing this branch.

### Worker metrics port
The worker listens on port 8080 (same port for both the scan endpoint and `/metrics`). The NetworkPolicy ingress rule and Prometheus scrape config both reference port 8080. Verify this matches the actual worker service port:
```bash
kubectl get svc presidio-worker -n mcp-presidio -o yaml | grep -A5 "ports:"
```

### status.sh worker health vs metrics
`status.sh` has two separate kubectl exec blocks for the worker:
1. Lines ~88-96: worker health check via `kubectl exec` (checks `/health`)
2. Lines ~169-174: worker metrics check via `kubectl exec` (checks `/metrics`)

The health check (1) is appropriate to keep as kubectl exec — it verifies internal reachability. The metrics check (2) can be replaced with a Prometheus query if scraping is confirmed working. Both have comments explaining why kubectl exec is used. Update both comments at minimum, even if the kubectl exec logic is retained.

### Architecture diagram change scope
Only the Prometheus → Worker edge annotation needs to change. Do not restructure the diagram or add new components. The change is limited to the comment on that specific edge.
