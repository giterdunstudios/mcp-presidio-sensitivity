# Helm Chart Versioning Policy

## Overview

Two charts live in this repo: `helm/mcp-server` and `helm/presidio-worker`. Both are versioned independently from the application images they deploy.

**Chart version** (`version` in Chart.yaml) tracks the Helm chart itself — templates, values schema, configmap keys, Kubernetes resource structure. It changes when the chart changes, regardless of whether the application image changed.

**appVersion** (`appVersion` in Chart.yaml) tracks the application release tag (e.g. `0.2.0`). It is informational — the actual image deployed is set at runtime via `--set image.tag=<sha>`. appVersion and image.tag will often differ; that is expected.

These two fields move independently. A template fix bumps the chart version without touching appVersion. An application release bumps appVersion without necessarily touching the chart version.

---

## Versioning Scheme (SemVer)

Both charts follow [Semantic Versioning](https://semver.org/).

| Bump | Trigger |
|---|---|
| **Patch** `x.x.N` | Template bug fixes, values corrections, comment/label changes, no new exposed configuration |
| **Minor** `x.N.0` | New optional values added, new template features (e.g. sidecar annotations), new configmap keys, new Kubernetes resources added to the chart |
| **Major** `N.0.0` | Breaking changes: values removed or renamed, previously optional values made required, template incompatibility requiring values migration |

When in doubt between patch and minor: if a deployer upgrading from the previous version needs to read the diff to decide whether to set new values, it is a minor bump.

---

## Multi-Chart Coordination Rule

When a change affects both charts (shared pattern, new infrastructure layer, cluster-wide policy), bump both charts in a single coordinated PR. Do not let the two charts diverge in version without a documented reason in the PR description or decision log.

If charts must diverge (e.g. a worker-specific fix shipped before a coordinated change), document the divergence and the target version at which they will re-align.

---

## Audit Trail

The standard Helm labels helper (`{{ include "*.labels" . }}`) includes `helm.sh/chart: chartname-version` in pod labels automatically. No additional work is required to track which chart version deployed a running pod.

To inspect:

```bash
kubectl get pods -n mcp-presidio --show-labels
kubectl get pod <pod-name> -n mcp-presidio -o jsonpath='{.metadata.labels.helm\.sh/chart}'
```

This provides a direct correlation between a running pod and the chart version that deployed it.

---

## Current State and Next Bump

| Chart | Current version | appVersion |
|---|---|---|
| `helm/mcp-server` | `0.1.0` | `0.1.0` |
| `helm/presidio-worker` | `0.1.0` | `0.1.0` |

**Queued bump: 0.1.0 → 0.2.0 (Minor)**

Phase 2 changes qualify as a minor bump:

| Change | Classification |
|---|---|
| Istio sidecar injection annotations added to Deployment templates | Minor — new template feature |
| mTLS PeerAuthentication resources added | Minor — new Kubernetes resources |
| EnvoyFilter resources added (rate limit, WWW-Authenticate injection) | Minor — new Kubernetes resources |
| Open ingress rule on port 8000 in MCP server NetworkPolicy | Minor — new values/template behavior |

This bump will be delivered in a single coordinated PR targeting both charts simultaneously.

**Dependency:** This bump PR (Part B) waits on:
- Item #14 (helm test hooks) — test infrastructure should be in place before incrementing
- Item #26 (Prometheus→Worker NetworkPolicy) — the NetworkPolicy change belongs in the same minor bump

---

## How to Bump in Practice

1. **Edit Chart.yaml in each affected chart** — update `version` (and `appVersion` if the release tag changed):

   ```yaml
   # helm/mcp-server/Chart.yaml
   version: 0.2.0
   appVersion: "0.2.0"
   ```

2. **Lint both charts**:

   ```bash
   helm lint helm/mcp-server -f helm/mcp-server/values.local.yaml
   helm lint helm/presidio-worker -f helm/presidio-worker/values.local.yaml
   ```

3. **Run full branch validation**:

   ```bash
   ./scripts/devtools-run.sh ./scripts/branch-test.sh
   ```

4. Open a PR. The PR description must state:
   - Which charts were bumped and from/to which version
   - The bump classification (patch/minor/major) and the triggering changes
   - If charts were bumped independently, the reason for divergence and re-alignment plan
