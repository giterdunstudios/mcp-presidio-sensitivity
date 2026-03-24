# Token Validation Report
**Lane:** A
**Phase:** 0
**Date:** 2026-03-24
**Status:** All checks pass

---

## Step 1 — Hydra health check

```bash
curl -s http://localhost:4445/health/ready
```
**Result:** `{"status":"ok"}` ✅

---

## Step 2 — Token issuance

**Command:**
```bash
curl -s -X POST http://localhost:4444/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=test-agent-client \
      &client_secret=test-agent-secret-change-in-prod \
      &scope=tools:classify.submit&audience=mcp-presidio-server"
```

**Result:** JWT received ✅

---

## Step 3 — Decoded token claims

```json
{
  "aud": ["mcp-presidio-server"],
  "client_id": "test-agent-client",
  "exp": 1774380632,
  "ext": {},
  "iat": 1774377033,
  "iss": "http://hydra.mcp-presidio.svc.cluster.local:4444",
  "jti": "91279433-292f-488f-b2c9-f384d06416eb",
  "nbf": 1774377033,
  "scp": ["tools:classify.submit"],
  "sub": "test-agent-client"
}
```

### Claims verification

| Claim | Expected | Actual | Pass |
|-------|----------|--------|------|
| `iss` | `http://hydra.mcp-presidio.svc.cluster.local:4444` | matches | ✅ |
| `aud` | `mcp-presidio-server` | matches | ✅ |
| `scp` | `tools:classify.submit` | matches | ✅ |
| `exp` | future timestamp | 1774380632 (future) | ✅ |
| `sub` | `test-agent-client` | matches | ✅ |

---

## Step 4 — JWKS endpoint

```bash
curl -s http://localhost:4444/.well-known/jwks.json
```

**Result:** Two RS256 signing keys returned ✅

| Field | Value |
|-------|-------|
| `kty` | RSA |
| `alg` | RS256 |
| `use` | sig |
| Key count | 2 (key rotation supported) |

---

## Step 5 — Wrong scope rejection

```bash
curl -s -X POST http://localhost:4444/oauth2/token \
  -d "...&scope=tools:admin"
```

**Result:**
```json
{
  "error": "invalid_scope",
  "error_description": "The OAuth 2.0 Client is not allowed to request scope 'tools:admin'."
}
```
Scope enforcement working correctly ✅

---

## MCP Server handoff values

These values are confirmed and ready for the MCP server implementation:

| Parameter | Value |
|-----------|-------|
| Issuer URL | `http://hydra.mcp-presidio.svc.cluster.local:4444` |
| JWKS URI | `http://hydra.mcp-presidio.svc.cluster.local:4444/.well-known/jwks.json` |
| Token endpoint | `http://hydra.mcp-presidio.svc.cluster.local:4444/oauth2/token` |
| Expected audience | `mcp-presidio-server` |
| Signing algorithm | `RS256` |
| Scope: classify | `tools:classify.submit` |
| Scope: health | `tools:health.read` |

---

## Definition of done checklist

- [x] Hydra health check passes
- [x] `test-agent-client` registered successfully
- [x] Token requested and received with correct claims
- [x] JWKS endpoint returns RS256 signing keys
- [x] Wrong-scope request returns `invalid_scope` error
- [x] Both deliverable documents committed to repo
