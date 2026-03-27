---
branch: 14-helm-test-hooks
wave: 3
items: "#14"
impl_owner: Technical Implementation Lead
validation_owner: Engineering Practices Lead
status: ready
gate: Wave 2 must be fully merged; #13 (helm-versioning-policy.md) must be present in main
---

# Branch: 14-helm-test-hooks

## Goal
Add Helm test hooks to both charts so `helm test` provides a post-deploy smoke test — verifying live service health after every `helm upgrade`.

## Items covered
| # | Item |
|---|------|
| #14 | Helm test hooks |

## GATE: Do not start until these are in main
- Wave 2 must be fully merged
- `planning/helm-versioning-policy.md` must exist (item #13, already committed)

## Acceptance criteria
- [ ] `helm/mcp-server/templates/tests/test-mcp-health.yaml` created — tests MCP server `/health` endpoint
- [ ] `helm/presidio-worker/templates/tests/test-worker-health.yaml` created — tests Presidio worker `/health` endpoint
- [ ] Worker test pod: `helm/presidio-worker/templates/networkpolicy.yaml` updated to allow ingress from pods with label `helm-test: worker` on port 8080
- [ ] MCP test: `wget -qO-` or `curl -sf` to `http://mcp-presidio-sensitivity.mcp-presidio.svc.cluster.local:8000/health` returns HTTP 200 with `"ok"`
- [ ] Worker test: `wget -qO-` or `curl -sf` to `http://presidio-worker.mcp-presidio.svc.cluster.local:8080/health` returns HTTP 200 with `"ok"`
- [ ] Both tests annotated with `helm.sh/hook: test` and `helm.sh/hook-delete-policy: hook-succeeded`
- [ ] `helm test mcp-presidio-sensitivity -n mcp-presidio` passes
- [ ] `helm test presidio-worker -n mcp-presidio` passes
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `helm/mcp-server/templates/tests/test-mcp-health.yaml` | Create | Helm test Job for MCP server |
| `helm/presidio-worker/templates/tests/test-worker-health.yaml` | Create | Helm test Job for worker |
| `helm/presidio-worker/templates/networkpolicy.yaml` | Modify | Add ingress rule for test pod label |

## Files to leave alone
`scripts/rebuild.sh`, all `src/` files, `helm/mcp-server/templates/networkpolicy.yaml`, `helm/*/values.yaml`, `helm/*/values.local.yaml`, `helm/*/Chart.yaml` (bumped separately in `13b-helm-version-bump`).

## Decisions that apply to this branch

### Why modify the worker NetworkPolicy
The worker NetworkPolicy allows ingress only from pods with `app.kubernetes.io/name: mcp-presidio-sensitivity` (the MCP server). A Helm test pod is a separate Job pod with different labels — without an exception it cannot reach the worker and the test will always time out. The cleanest solution is a dedicated label (`helm-test: worker`) on the test pod with a matching ingress rule in the NetworkPolicy. This is a minimal and auditable change.

### Test image
Use `busybox` or `curlimages/curl` (both are tiny). The test only needs `wget` or `curl`. Avoid `alpine` for simplicity since it requires an additional package install.

### NetworkPolicy label for test pod
The test pod must carry the label `helm-test: worker` to match the ingress rule. Set it in the test Job template under `spec.template.metadata.labels`.

### hook-delete-policy
Use `helm.sh/hook-delete-policy: hook-succeeded` so the test pod is cleaned up on success. Failed pods remain for debugging.

## How to validate

```bash
# 1. Rebuild and deploy (test hooks are picked up by helm upgrade in rebuild.sh)
./scripts/rebuild.sh

# 2. Run MCP server Helm test
./scripts/devtools-run.sh helm test mcp-presidio-sensitivity -n mcp-presidio
echo "Exit code: $?"   # must be 0

# 3. Run worker Helm test
./scripts/devtools-run.sh helm test presidio-worker -n mcp-presidio
echo "Exit code: $?"   # must be 0

# 4. Check that test pods were cleaned up (hook-delete-policy: hook-succeeded)
./scripts/devtools-run.sh kubectl get pods -n mcp-presidio | grep test
# Should show no test pods (they are deleted on success)

# 5. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- Both test template files exist in the correct `tests/` subdirectory
- Worker NetworkPolicy diff shows exactly one new ingress rule (for `helm-test: worker` label)
- `helm test` for both charts passes
- No test pods remain after successful tests (hook-delete-policy is set)
- No Helm chart version was bumped (that is #13b scope)
- `branch-test.sh` passes

## Notes / constraints

### Template structure — MCP server test
```yaml
# helm/mcp-server/templates/tests/test-mcp-health.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "mcp-presidio-sensitivity.fullname" . }}-test-health"
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "mcp-presidio-sensitivity.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: test-health
      image: busybox
      command:
        - sh
        - -c
        - |
          wget -qO- http://mcp-presidio-sensitivity.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.service.port }}/health | grep -q '"ok"'
```

### Template structure — Worker test
```yaml
# helm/presidio-worker/templates/tests/test-worker-health.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "presidio-worker.fullname" . }}-test-health"
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "presidio-worker.labels" . | nindent 4 }}
    helm-test: worker   # required to match the NetworkPolicy ingress rule below
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: test-health
      image: busybox
      command:
        - sh
        - -c
        - |
          wget -qO- http://presidio-worker.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.service.port }}/health | grep -q '"ok"'
```

### NetworkPolicy addition — worker
Add this ingress rule to `helm/presidio-worker/templates/networkpolicy.yaml` alongside the existing MCP server and Prometheus rules:

```yaml
    # Helm test hooks — health check from test pod
    - from:
        - podSelector:
            matchLabels:
              helm-test: worker
      ports:
        - protocol: TCP
          port: 8080
```

### Service port values
The MCP server listens on port 8000 (`.Values.service.port`). The worker listens on port 8080 (`.Values.service.port`). Verify these in `values.yaml` before hardcoding — use the Helm template variable to stay consistent.

### Istio sidecar and test pods
The `mcp-presidio` namespace has `istio-injection=enabled`. Helm test pods will receive Istio sidecars. This is expected. The sidecar adds ~2s startup overhead to the test pod. The test pod does not need any special Istio configuration — the MCP server allows traffic on port 8000 with no `from` restriction.
