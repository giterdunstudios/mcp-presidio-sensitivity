# Disaster Recovery Runbook

## How to use this runbook

Each scenario follows the same structure:

- **Symptom:** What you observe
- **Diagnose:** Command(s) to confirm the root cause
- **Recover:** Commands to restore the stack, in order

After any recovery, always run the canonical post-recovery sequence in Section 6.

## Data loss warning

**Audit records are written to container stdout only.** Running
`./scripts/setup-local.sh --teardown` destroys the cluster and all container
logs permanently. There is no recovery path for audit records that existed only
in container stdout. If you need to preserve audit records before tearing down,
capture them first:

```bash
./scripts/devtools-run.sh kubectl logs -n mcp-presidio deployment/mcp-presidio-sensitivity > audit-backup-$(date +%Y%m%d-%H%M%S).txt
```

---

## Toolchain note

If `k3d`, `kubectl`, and `helm` are not on your host `PATH`, prefix all cluster
management commands with `./scripts/devtools-run.sh`. That wrapper runs the
command inside the devtools container, which has all three tools at pinned
versions (k3d 5.7.4, kubectl 1.30.0, helm 3.14.4).

Examples in this runbook show the `./scripts/devtools-run.sh` prefix where
cluster tools are required. If you have the tools installed on your host you
can omit the prefix.

**WSL2 note:** `setup-local.sh` uses `sg docker -c ...` internally to handle
the case where `newgrp docker` does not propagate to non-interactive subshells.
This is expected — you do not need to do anything extra beyond having your user
in the `docker` group.

---

## 1. k3d cluster gone (WSL2 restart, Docker crash, or accidental deletion)

### Symptom

- `./scripts/status.sh` reports cluster not found
- `./scripts/devtools-run.sh kubectl get pods -n mcp-presidio` returns an error
  (connection refused or no such cluster)
- Services at `localhost:8000`, `localhost:8080` are unreachable

### Diagnose

```bash
./scripts/devtools-run.sh k3d cluster list
```

If the `mcp-presidio` cluster is absent or shows status `stopped`, proceed to
recovery.

### Recover

**Important:** `setup-local.sh` does NOT reinstall Istio or apply
`infrastructure/istio/*.yaml`. After a full cluster rebuild, Istio manifests
must be re-applied manually before auth enforcement is active (Phase 2).

**Timing:**
- Cold rebuild (fresh image builds + spaCy model download): approximately 10–15 minutes
- With `--skip-build` (images already exist in registry): approximately 5 minutes

```bash
# Step 1 — destroy any partial cluster state, then rebuild from scratch
./scripts/setup-local.sh --teardown     # safe to run even if cluster is already gone
./scripts/setup-local.sh

# Step 2 — apply DEC-002 token TTL (Keycloak reverts to 300s default on fresh realm import)
./scripts/keycloak-admin.sh set-ttl 60

# Step 3 — (Phase 2 only) re-apply Istio manifests
# Skip this step if Istio is not installed (Phase 1 stack)
./scripts/devtools-run.sh kubectl apply -f infrastructure/istio/
./scripts/devtools-run.sh kubectl label namespace mcp-presidio istio-injection=enabled --overwrite
./scripts/devtools-run.sh kubectl rollout restart deployment/mcp-presidio-sensitivity -n mcp-presidio
./scripts/devtools-run.sh kubectl rollout status deployment/mcp-presidio-sensitivity -n mcp-presidio

# Step 4 — confirm the stack is healthy
./scripts/status.sh
```

Then continue with Section 6 (post-recovery sequence).

---

## 2. Registry unreachable (push fails or images not pulling)

### Symptom

- `./scripts/rebuild.sh` fails with a connection refused error pushing to
  `localhost:5000`
- Pods are stuck in `ImagePullBackOff` or `ErrImagePull`
- `./scripts/status.sh` shows pods not Running

There are two distinct sub-cases with different recovery commands.

### Diagnose

```bash
docker ps --filter name=k3d-mcp-registry
```

- If the container appears with status `Up` — the registry is running; look
  elsewhere for the push failure.
- If the container appears with status `Exited` — the registry container is
  stopped (sub-case a).
- If the container is absent from the output — the registry was deleted
  (sub-case b).

### Recover — sub-case a: registry container stopped

```bash
# Restart the stopped registry container — no cluster rebuild needed
docker start k3d-mcp-registry

# Verify it is now running
docker ps --filter name=k3d-mcp-registry

# Rebuild and push images
./scripts/rebuild.sh
```

### Recover — sub-case b: registry deleted

The registry and cluster are tightly coupled. A deleted registry requires a
full teardown and rebuild.

```bash
./scripts/setup-local.sh --teardown
./scripts/setup-local.sh
./scripts/keycloak-admin.sh set-ttl 60
./scripts/status.sh
```

Then continue with Section 6.

---

## 3. Pod crashlooping (worker or MCP server in CrashLoopBackOff)

### Symptom

- `./scripts/status.sh` reports one or more pods not Running
- `kubectl get pods -n mcp-presidio` shows `CrashLoopBackOff` or
  `Error` status for `presidio-worker` or `mcp-presidio-sensitivity`

### Diagnose

```bash
# Check pod status
./scripts/devtools-run.sh kubectl get pods -n mcp-presidio

# Get the most recent log output from the crashing pod (replace <pod-name>)
./scripts/devtools-run.sh kubectl logs -n mcp-presidio <pod-name> --previous

# Describe the pod for events and exit codes
./scripts/devtools-run.sh kubectl describe pod -n mcp-presidio <pod-name>
```

Common causes:
- **OOMKilled** — the pod ran out of memory. Check `kubectl describe pod` for
  `OOMKilled` in the last state. The worker loads the spaCy model (~500 MB) at
  startup; ensure the cluster node has enough memory.
- **Config error** — a bad environment variable or missing secret. Check logs
  for a Python traceback at startup.
- **Image pull failure** — the registry was unreachable at deploy time. Check
  pod events in `kubectl describe`. Recover using Scenario 2 steps, then
  restart the pod.

### Recover

```bash
# Attempt a rolling restart first — resolves transient failures
./scripts/devtools-run.sh kubectl rollout restart deployment/presidio-worker -n mcp-presidio
./scripts/devtools-run.sh kubectl rollout status deployment/presidio-worker -n mcp-presidio

./scripts/devtools-run.sh kubectl rollout restart deployment/mcp-presidio-sensitivity -n mcp-presidio
./scripts/devtools-run.sh kubectl rollout status deployment/mcp-presidio-sensitivity -n mcp-presidio
```

If the pod continues to crashloop after the rolling restart:

```bash
# Rebuild the affected image and redeploy
./scripts/rebuild.sh worker      # for presidio-worker
./scripts/rebuild.sh mcp         # for mcp-presidio-sensitivity
./scripts/rebuild.sh             # rebuild both

# Confirm pods are now Running
./scripts/status.sh
```

If crashlooping persists after a rebuild, check the logs for a startup
traceback and resolve the configuration issue before rebuilding again.

---

## 4. Keycloak realm missing or reset

### Symptom

- Token acquisition fails with `401` or `realm not found`
- `./scripts/status.sh` fails the token TTL check
- `./scripts/keycloak-admin.sh status` reports the `mcp-local` realm is absent
- `./scripts/auth-test.sh` case 4 (valid token, correct scope) returns `401`

### Diagnose

```bash
# Check Keycloak pod is running
./scripts/devtools-run.sh kubectl get pods -n mcp-presidio -l app.kubernetes.io/name=keycloak

# Check realm exists and verify config
./scripts/keycloak-admin.sh status
```

If `status` shows the realm is absent, or if the token TTL is 300s instead of
60s, the realm import was not applied (or Keycloak restarted without
persistence and reverted to defaults).

### Recover

The realm is re-imported automatically when Keycloak starts. If the realm is
missing, the Keycloak pod likely needs to be restarted so it re-reads the
import ConfigMap.

```bash
# Restart Keycloak to trigger realm re-import
./scripts/devtools-run.sh kubectl rollout restart deployment/keycloak -n mcp-presidio
./scripts/devtools-run.sh kubectl rollout status deployment/keycloak -n mcp-presidio

# Re-apply DEC-002 token TTL (realm import sets Keycloak default of 300s)
./scripts/keycloak-admin.sh set-ttl 60

# Verify realm config is correct
./scripts/keycloak-admin.sh status
./scripts/keycloak-admin.sh discovery-check
```

If the Keycloak pod is not Running, or if Keycloak itself is unresponsive,
fall back to a full cluster rebuild (Scenario 1).

---

## 5. Istio sidecar injection broken

**Phase 2 — not yet applicable in Phase 1.**

This scenario applies once Istio is installed into the `mcp-presidio` cluster.
If you are on Phase 1 (no Istio), skip this section. If the cluster was just
rebuilt and Istio is not installed yet, use Scenario 1 recovery steps to
re-apply `infrastructure/istio/` manifests before returning here.

### Symptom

- MCP server returns `200` even for requests without a token (JWT enforcement
  is bypassed because the Envoy sidecar is not intercepting traffic)
- `./scripts/auth-test.sh` case 1 (no token → 401) fails — returns `200`
  instead
- `kubectl get pods -n mcp-presidio` shows pods with only `1/1` containers
  ready instead of `2/2` (sidecar not injected)

This scenario is scoped to the case where **istiod is running** but the
namespace label is missing or the pods were deployed before injection was
enabled. If istiod is not installed at all, use Scenario 1 first.

### Diagnose

```bash
# Check sidecar injection label on the namespace
./scripts/devtools-run.sh kubectl get namespace mcp-presidio --show-labels

# Check pod container count (2/2 = app + sidecar; 1/1 = no sidecar)
./scripts/devtools-run.sh kubectl get pods -n mcp-presidio

# Run Istio config analysis for issues
./scripts/devtools-run.sh istioctl analyze -n mcp-presidio
```

If the namespace label `istio-injection=enabled` is missing, apply it and
restart the affected pods. If `istioctl analyze` reports configuration errors,
address those before restarting.

### Recover

```bash
# Re-apply the sidecar injection label to the namespace
./scripts/devtools-run.sh kubectl label namespace mcp-presidio istio-injection=enabled --overwrite

# Rolling restart of the MCP server pod so the new pod gets the sidecar injected
./scripts/devtools-run.sh kubectl rollout restart deployment/mcp-presidio-sensitivity -n mcp-presidio
./scripts/devtools-run.sh kubectl rollout status deployment/mcp-presidio-sensitivity -n mcp-presidio

# Verify pods now show 2/2 containers ready
./scripts/devtools-run.sh kubectl get pods -n mcp-presidio

# Verify auth enforcement is active
./scripts/auth-test.sh
```

If sidecar injection is still not working after the label and restart, check
that the Istio webhook is registered and istiod is healthy:

```bash
./scripts/devtools-run.sh kubectl get mutatingwebhookconfiguration istio-sidecar-injector
./scripts/devtools-run.sh kubectl get pods -n istio-system
./scripts/devtools-run.sh istioctl analyze -n mcp-presidio
```

---

## 6. Post-recovery sequence (always run after any recovery)

Run these steps in order after completing any scenario above. Do not skip steps.

```bash
# 1. Bootstrap the cluster and apply realm import (if cluster was rebuilt)
./scripts/setup-local.sh

# 2. (Phase 2 only) Re-apply Istio manifests
./scripts/devtools-run.sh kubectl apply -f infrastructure/istio/
./scripts/devtools-run.sh kubectl label namespace mcp-presidio istio-injection=enabled --overwrite

# 3. Rolling restart of MCP server pod
#    Required after Istio label changes; safe to run at any time
./scripts/devtools-run.sh kubectl rollout restart deployment/mcp-presidio-sensitivity -n mcp-presidio
./scripts/devtools-run.sh kubectl rollout status deployment/mcp-presidio-sensitivity -n mcp-presidio

# 4. Apply DEC-002 token TTL
#    Always required after setup-local.sh — Keycloak reverts to 300s on a fresh realm import
./scripts/keycloak-admin.sh set-ttl 60

# 5. Full stack health check
./scripts/status.sh

# 6. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

Steps 1–3 are conditional: run them only if the recovery path required a
cluster rebuild or Istio label change. Steps 4–6 are unconditional — always
run them.

**Expected result:** `./scripts/status.sh` passes all checks. Token TTL is
reported as ≤ 60 seconds. All pods are Running. RFC 9728 discovery document
is returned correctly.
