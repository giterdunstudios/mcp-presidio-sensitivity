# Agent Briefing: Lane A — Hydra OAuth Configuration
**Phase:** 0
**Status:** Ready to start
**Blocked by:** Nothing — start immediately
**Blocks:** MCP Server (Group 2)

---

## Your objective

Configure Hydra as a working OAuth Authorization Server for the project.
By the end of this lane, an agent or service must be able to request a token
using OAuth client credentials and receive a valid signed JWT that the MCP server
can verify.

---

## Read before starting

You must read these files before doing any work:

| File | Location |
|------|----------|
| Ways of working | `role-instructions/ways-of-working.md` |
| Task plan | `planning/task_plan.md` |
| Findings | `planning/findings.md` |
| Auth engineering spec | `shared/private/mcp_auth_engineering_spec.md` |

The auth spec §6 defines the scope model. Do not deviate from it.

---

## Environment

Hydra is already deployed in the local Kubernetes cluster.

| Detail | Value |
|--------|-------|
| Cluster | `kind-mcp-presidio` |
| Namespace | `mcp-presidio` |
| Hydra public service | `svc/hydra-public` (port 4444) |
| Hydra admin service | `svc/hydra-admin` (port 4445) |
| Helm release | `hydra` |
| Values file | `helm/hydra-values.local.yaml` |

To reach Hydra admin API from your terminal, port-forward first:
```bash
kubectl port-forward -n mcp-presidio svc/hydra-admin 4445:4445
```

---

## Steps

### 1. Verify Hydra is healthy
```bash
kubectl get pods -n mcp-presidio
curl -s http://localhost:4445/health/ready
```
Expected: all pods Running, health endpoint returns `{"status":"ok"}`

### 2. Register the test service client
Create an OAuth client representing an agent caller.
Use the Hydra admin API:
```bash
curl -s -X POST http://localhost:4445/admin/clients \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "test-agent-client",
    "client_secret": "test-agent-secret-change-in-prod",
    "grant_types": ["client_credentials"],
    "scope": "tools:classify.submit tools:health.read",
    "audience": ["mcp-presidio-server"],
    "token_endpoint_auth_method": "client_secret_post"
  }'
```

### 3. Request a token using client credentials
```bash
curl -s -X POST http://localhost:4444/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=test-agent-client" \
  -d "client_secret=test-agent-secret-change-in-prod" \
  -d "scope=tools:classify.submit" \
  -d "audience=mcp-presidio-server"
```
Expected: response contains `access_token`, `token_type: bearer`, `expires_in`

### 4. Decode and verify the token claims
Decode the JWT (use `jwt.io` locally or `python3 -c` with the `pyjwt` library):
Confirm the token contains:
- `iss` matching the Hydra issuer URL
- `aud` containing `mcp-presidio-server`
- `scope` containing `tools:classify.submit`
- `exp` in the future

### 5. Verify the JWKS endpoint
```bash
curl -s http://localhost:4444/.well-known/jwks.json
```
Expected: response contains at least one key with `kty`, `kid`, `alg`, `use: sig`

### 6. Test unauthorized behavior
Request a token with a wrong scope to confirm Hydra enforces it:
```bash
curl -s -X POST http://localhost:4444/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=test-agent-client" \
  -d "client_secret=test-agent-secret-change-in-prod" \
  -d "scope=tools:admin"
```
Expected: error response — scope not allowed for this client

---

## Deliverables

Produce these files and write them to disk. **Do not commit or push — the coordinator handles all git operations.**

| File | Location | Contents |
|------|----------|----------|
| `hydra-config-report.md` | `deliverables/lane-a/` | What was configured, commands run, results observed, any deviations from plan |
| `token-validation-report.md` | `deliverables/lane-a/` | Decoded token claims, JWKS response, confirmation of all 5 steps passing |

When all files are written, notify the coordinator by ending your session with a clear summary of:
- All files written and their paths
- All decisions made (for logging to `task_plan.md`)
- Definition of done checklist status
- Any issues or deviations to flag

---

## Constraints — read carefully

- **Do not invent new scopes.** The scope model is defined in auth spec §6. Register exactly: `tools:classify.submit` and `tools:health.read`.
- **Do not change the Hydra Helm values** without logging the decision in `task_plan.md` with a source.
- **Do not register additional clients** beyond `test-agent-client` without operator confirmation.
- **Log every admin API command you run** in `hydra-config-report.md` — including failures.
- **Do not hardcode secrets** in any committed file. The test secret in this briefing is for local dev only and is already in the values file.

---

## Definition of done

- [ ] Hydra health check passes
- [ ] `test-agent-client` registered successfully
- [ ] Token requested and received with correct claims
- [ ] JWKS endpoint returns signing key
- [ ] Wrong-scope request returns an error
- [ ] Both deliverable documents written to disk
- [ ] Any decisions noted in your completion summary for the coordinator to log

---

## Handoff

When done, notify the operator. The MCP server (Group 2) needs the following
from your output before it can start:

- Confirmed issuer URL
- Confirmed JWKS URL
- Confirmed audience value (`mcp-presidio-server`)
- Confirmed scope names

These are captured in your `hydra-config-report.md`.
