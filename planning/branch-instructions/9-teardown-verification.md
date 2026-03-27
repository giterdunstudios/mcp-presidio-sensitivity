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
- [ ] `k3d registry list` shows no `mcp-registry` after teardown (or it was deleted and recreated cleanly by the subsequent setup)
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
k3d registry list                   # check for any lingering mcp-registry
docker ps --filter name=k3d         # check for any lingering k3d containers
docker volume ls | grep k3d         # check for orphaned volumes

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
*(Fill this section in during verification — leave blank until verification is complete)*

**Date verified:**

**Investigator:**

**Pre-teardown state:**
- Cluster: (k3d cluster list output)
- Registry: (k3d registry list output)
- Containers: (docker ps filter output)
- Volumes: (docker volume ls filter output)

**Post-teardown state:**
- Cluster: (k3d cluster list output)
- Registry: (k3d registry list output)
- Orphaned containers: (docker ps filter output — none expected)
- Orphaned volumes: (docker volume ls output — list any k3d-related)

**Fresh setup duration (wall clock):**

**status.sh result after fresh setup:** [ ] All green  [ ] Issues found (describe)

**branch-test.sh result:** [ ] All 5 steps passed  [ ] Failures (describe)

**Orphaned resources found:** [ ] None  [ ] Yes (describe + backlog item #)

**Conclusion:**
