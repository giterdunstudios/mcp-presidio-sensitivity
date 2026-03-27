---
branch: 13b-helm-version-bump
wave: 4
items: "#13b"
impl_owner: Engineering Practices Lead
validation_owner: Technical Implementation Lead
status: BLOCKED
---

# Branch: 13b-helm-version-bump

## Goal
Bump both Helm charts from `0.1.0` to `0.2.0` in a single coordinated PR to reflect all Phase 2 changes, consistent with the versioning policy in `planning/helm-versioning-policy.md`.

## Items covered
| # | Item |
|---|------|
| #13b | Coordinated Helm 0.1.0 → 0.2.0 bump |

## GATE: Do not start until both of these are merged to main

| Blocking item | Branch | What it adds |
|---|---|---|
| #14 | `14-helm-test-hooks` | Helm test hooks for both charts |
| #26 | `26-prometheus-worker-scraping` | Prometheus scraping fix for worker |

Check before starting:
```bash
git log --oneline main | head -20  # confirm both branches are present in main
```

If either is not yet merged, do not open this branch. Wait.

## Acceptance criteria
- [ ] `helm/mcp-server/Chart.yaml`: `version` → `0.2.0`, `appVersion` → `0.2.0`
- [ ] `helm/presidio-worker/Chart.yaml`: `version` → `0.2.0`, `appVersion` → `0.2.0`
- [ ] `helm lint helm/mcp-server` passes with no errors
- [ ] `helm lint helm/presidio-worker` passes with no errors
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes
- [ ] PR description includes the classification table per `planning/helm-versioning-policy.md` — this is a Minor bump (new features added in Phase 2)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `helm/mcp-server/Chart.yaml` | Modify | version: 0.2.0, appVersion: 0.2.0 |
| `helm/presidio-worker/Chart.yaml` | Modify | version: 0.2.0, appVersion: 0.2.0 |

## Files to leave alone
All Helm templates (`helm/mcp-server/templates/`, `helm/presidio-worker/templates/`). All `values.yaml` and `values.local.yaml` files. All `src/`, `scripts/`, `planning/` files.

## Decisions that apply to this branch
- `planning/helm-versioning-policy.md` defines the bump classification. A `0.1.0 → 0.2.0` bump is a Minor bump under SemVer (new features added, backwards compatible). Phase 2 adds Istio sidecar support, EnvoyFilter CRDs, Prometheus metrics, and OTel tracing — all new capabilities, no breaking changes.
- Both charts are bumped together in a single PR. The charts are co-deployed and should share the same version number. Staggered bumps create confusion about which version of each chart is compatible with which.

## How to validate

```bash
# 1. Verify the blocking branches are merged
git log --oneline main | grep -E "14-helm-test-hooks|26-prometheus-worker-scraping"

# 2. Bump Chart.yaml files
# Edit helm/mcp-server/Chart.yaml
# Edit helm/presidio-worker/Chart.yaml

# 3. Lint both charts
./scripts/devtools-run.sh helm lint helm/mcp-server
./scripts/devtools-run.sh helm lint helm/presidio-worker

# 4. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- Both `Chart.yaml` files show `version: 0.2.0` and `appVersion: 0.2.0`
- No template files were modified (only `Chart.yaml`)
- Both `helm lint` commands pass
- `branch-test.sh` passes
- PR description includes the classification table from `planning/helm-versioning-policy.md`
- Confirms blocking items #14 and #26 are present in main before approving

## Notes / constraints
- This is a bookkeeping change. If `helm lint` fails after only changing the version fields, there is a pre-existing template problem — investigate before merging.
- `appVersion` should reflect the application version deployed. If `mcp_server` and the worker have separate semantic versions tracked elsewhere, use those. If not tracked separately, `0.2.0` is appropriate as it aligns with the chart version and signals the Phase 2 capability set.
- Do not bump to `1.0.0` — that signals a production-stable API and the project is still in active Phase development.
