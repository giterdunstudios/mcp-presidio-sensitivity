---
branch: 9-teardown-verification
wave: 1
items: "#9"
impl_owner: Technical Implementation Lead
validation_owner: Engineering Practices Lead
status: ready
---

# Branch: 9-teardown-verification

## Goal
Confirm that `./scripts/setup-local.sh --teardown` followed by `./scripts/setup-local.sh` produces a clean stack with no orphaned k3d volumes or registry layers; document findings.

## Items covered
| # | Item |
|---|------|
| #9 | BP-011 Verify setup-local.sh --teardown leaves no orphaned resources |

## Acceptance criteria
- [ ] Teardown completes without errors; `k3d cluster list` shows no `mcp-presidio` cluster afterwards
- [ ] `k3d registry list` shows no `k3d-mcp-registry` after teardown (or it was deleted and recreated cleanly by the subsequent setup)
- [ ] `./scripts/setup-local.sh` completes without errors after teardown
- [ ] `./scripts/status.sh` — all checks green after fresh setup
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` — all 5 steps pass after fresh setup
- [ ] Findings documented in this instruction file as a findings addendum (see template at bottom)
- [ ] If orphaned resources are found: a new backlog item is opened describing the fix; no fix is applied on this branch

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `planning/branch-instructions/9-teardown-verification.md` | Modify | Add findings addendum at bottom |

## Files to leave alone
All `src/`, `helm/`, `scripts/` files — no code changes. If teardown leaves orphaned resources and a fix is needed, open a new backlog item. Do not fix it on this branch.

## Decisions that apply to this branch
- DEC-004: The cluster is `mcp-presidio` (k3d). The registry is `k3d-mcp-registry` on port 5000. Both are created by `setup-local.sh` and should be destroyed by `setup-local.sh --teardown`.
- DEC-002: After fresh setup, `keycloak-admin.sh set-ttl 60` must be run before `status.sh` will pass the token TTL check.
- Wave 3 finding: registry push from the host uses `localhost:5000`; the cluster-internal address is `k3d-mcp-registry:5000`. Both must be working after a clean setup.

## How to validate

Run these steps in order. Use `./scripts/devtools-run.sh kubectl ...` and `./scripts/devtools-run.sh k3d ...` if those tools are not installed on the host.

```bash
# Step 1: Record pre-teardown state
k3d cluster list
k3d registry list
docker ps --filter name=k3d

# Step 2: Run teardown
./scripts/setup-local.sh --teardown

# Step 3: Verify clean state
k3d cluster list                    # must show NO mcp-presidio cluster
k3d registry list                   # must show NO k3d-mcp-registry
kubectl config get-contexts | grep mcp-presidio  # expected: no output (context removed by k3d)
docker ps --filter name=k3d         # check for any lingering k3d containers
docker volume ls | grep k3d         # check for orphaned volumes — expected: no output

# Step 4: Fresh setup
./scripts/setup-local.sh

# Step 5: Apply DEC-002 TTL (required after every fresh setup)
./scripts/keycloak-admin.sh set-ttl 60

# Step 6: Health check
./scripts/status.sh

# Step 7: Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

Record the output of each docker volume / docker ps check in the findings addendum. Note any containers or volumes that survive teardown and whether they are expected (e.g. Docker system containers) or unexpected (e.g. k3d-specific containers).

## What the validation owner checks
- Findings addendum is present and clearly states whether orphaned resources were found
- If orphaned resources found: a new backlog item number is cited
- Confirms `branch-test.sh` passed after the fresh setup
- Confirms no src/, helm/, or scripts/ files were modified
- Timing data is present (how long did setup take?)

## Notes / constraints
- This branch requires exclusive cluster access during the teardown/rebuild cycle. Do not run this while another branch is deployed to the shared cluster.
- `setup-local.sh` timing: the spaCy model download for the worker is the long pole (~3–10 minutes on first run if the model is not in the Docker layer cache; much faster if the image was previously built). Record actual wall-clock time in findings.
- If teardown fails partway through (e.g. registry delete fails), do not retry blindly. Note the error, check `docker ps` and `k3d cluster list`, and manually clean up before re-running teardown.
- The devtools container (`infrastructure/devtools.Dockerfile`) has k3d, kubectl, and helm installed. Use `./scripts/devtools-run.sh` for those operations if the host does not have them.

---

## Findings Addendum

**Date verified:** 2026-03-27

**Investigator:** Engineering Practices Lead

**Pre-teardown state:**
- Cluster: `mcp-presidio` (1 server, 0 agents, loadbalancer — running)
- Registry: `k3d-mcp-registry` (running)
- Containers: `k3d-mcp-presidio-serverlb`, `k3d-mcp-presidio-server-0`, `k3d-mcp-registry`
- Volumes: `local k3d-mcp-presidio-images`

**Post-teardown state:**
- Cluster: no `mcp-presidio` line — ✅ clean
- Registry: no `k3d-mcp-registry` line — ✅ clean
- kubeconfig context: removed (no output) — ✅ clean
- Orphaned containers: none — ✅ clean
- Orphaned volumes: none (`docker volume ls | grep k3d` returned no output) — ✅ clean

**Fresh setup duration (wall clock):** ~3 minutes (images fully cached from prior build; no spaCy model download needed)

**Smoke test note:** `setup-local.sh` exited with error on the smoke test step ("Worker health — could not reach http://localhost:8090/health"). The worker pod had just started (~90s old); the spaCy model was still initialising and the external port was not yet accepting connections. All pods showed Running+Ready within 30s of the error. The smoke test timing issue does not reflect orphaned resources — it is a pre-existing race condition between pod startup and the smoke test check. New backlog item recommended (see below).

**status.sh result after fresh setup:** [x] Issues found
- All pods Running (6/6) ✅
- Keycloak, worker, MCP server health endpoints ✅
- Token acquisition (60s TTL) ✅
- RFC 9728 discovery document ✅
- **FAIL: RFC 9728 WWW-Authenticate auth challenge missing `resource_metadata`** — pre-existing issue, not introduced by teardown (see BP-029 below)

**branch-test.sh result:** [x] Failures
- Unit tests ✅ (58/58)
- Rebuild and deploy ✅
- Stack health ✅ (status.sh warning noted above)
- **FAIL: Auth enforcement** — Case 1: received HTTP 200 (expected 401/403). Pre-existing issue — see BP-029.
- NetworkPolicy ✅ (all 10 cases pass)

**Orphaned resources found:** [x] None — teardown is clean.

**Pre-existing issue discovered — BP-029:**

The auth enforcement failure is not caused by teardown/rebuild. Root cause: `JWTAuthMiddleware` was removed in commit `aa7c97b` ("feat(phase2): migrate auth enforcement to Istio/Envoy") before Istio was installed. The MCP server's `RequestContextMiddleware` assumes Envoy has already validated the JWT — no application-level auth guard remains. With Istio not yet deployed (Phase 2 work), the `/mcp` endpoint accepts unauthenticated requests.

This is a security gap that predates Wave 1. It requires a decision: either re-add a temporary `JWTAuthMiddleware` for the pre-Istio period, or accept the gap and document it as "auth enforcement requires Phase 2 Istio deployment." Tracked as **BP-029** in the best-practices backlog.

**Conclusion:** Teardown is clean — no orphaned containers, volumes, or kubeconfig contexts. Fresh setup completes correctly (images cached). The `branch-test.sh` auth failure is a pre-existing architectural gap (BP-029) unrelated to teardown behaviour. BP-011 acceptance criterion on teardown cleanliness is met.
