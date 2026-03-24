# Hydra Configuration Report
**Lane:** A
**Phase:** 0
**Date:** 2026-03-24
**Status:** Complete

---

## Environment

| Detail | Value |
|--------|-------|
| Cluster | `kind-mcp-presidio` |
| Namespace | `mcp-presidio` |
| Helm release | `hydra` |
| Hydra version | v26.2.0 |
| Helm chart revision | 3 |

---

## Configuration applied

Values file: `helm/hydra-values.local.yaml`

```yaml
hydra:
  dev: true
  config:
    dsn: memory
    urls:
      self:
        issuer: http://hydra.mcp-presidio.svc.cluster.local:4444
    secrets:
      system:
        - local-dev-secret-change-in-prod
    strategies:
      access_token: jwt
```

### Configuration decisions
- `dev: true` — required to allow HTTP issuer URL in local environment. Must be `false` in production with HTTPS issuer.
- `dsn: memory` — in-memory store for local dev. Clients reset on pod restart. Must be replaced with a persistent database in production.
- `strategies.access_token: jwt` — enables JWT access tokens. Required for MCP server to validate tokens locally without introspection. Added after initial deployment which defaulted to opaque tokens.

---

## OAuth client registered

**Command run:**
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

**Result:** Client registered successfully.

| Field | Value |
|-------|-------|
| `client_id` | `test-agent-client` |
| `grant_types` | `client_credentials` |
| `scope` | `tools:classify.submit tools:health.read` |
| `audience` | `mcp-presidio-server` |
| `token_endpoint_auth_method` | `client_secret_post` |

---

## Issues encountered

| Issue | Resolution |
|-------|------------|
| Hydra crashed on first deploy — HTTP issuer rejected | Added `dev: true` to values and upgraded |
| Tokens were opaque (not JWT) on second deploy | Added `strategies.access_token: jwt` to values and upgraded |
| Port-forwards dropped after pod restart on upgrade | Re-established port-forwards and re-registered client (expected — memory DSN) |
| Client must be re-registered after each pod restart | Known limitation of `dsn: memory` — acceptable for local dev |
