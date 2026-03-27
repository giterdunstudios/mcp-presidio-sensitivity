---
branch: 7-rfc9728-integration-test
wave: 2
items: "#7"
impl_owner: Technical Implementation Lead
validation_owner: Security / Privacy Lead
status: ready
---

# Branch: 7-rfc9728-integration-test

## Goal
Add a live integration test script that walks the full RFC 9728 discovery chain exactly as a compliant client would follow it, with pass/fail output per step and an exit code that CI can use.

## Items covered
| # | Item |
|---|------|
| #7 | BP-007 RFC 9728 discovery chain integration test |

## Acceptance criteria
- [ ] New file `scripts/rfc9728-test.sh` created and marked executable (`chmod +x`)
- [ ] All 6 chain steps are tested with labelled pass/fail output per step
- [ ] Exit 0 when all steps pass; exit 1 when any step fails
- [ ] Script is self-contained — no pre-obtained tokens or pre-configured Keycloak URL needed
- [ ] Script added to `scripts/README.md` with when-to-use guidance
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes (this script is standalone — `branch-test.sh` does NOT call it)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/rfc9728-test.sh` | Create | New executable script |
| `scripts/README.md` | Modify | Add entry for rfc9728-test.sh |

## Files to leave alone
`scripts/auth-test.sh`, `scripts/branch-test.sh`, `scripts/status.sh`, all other existing scripts. All `src/`, `helm/` files.

## Decisions that apply to this branch

### What this tests vs what auth-test.sh tests
`auth-test.sh` tests auth enforcement: no-token 401, malformed token 401, wrong scope 403, valid token 200, expired token 401. It pre-obtains tokens using a known Keycloak URL.

`rfc9728-test.sh` tests the discovery chain: starting from only the MCP server URL, can a client discover the token endpoint and acquire a token without any pre-configured Keycloak URL? This is the "client needs only MCP server URL" path from `planning/auth-flows-diagram.md` Flow 2.

These are complementary, not duplicate.

### The 6-step chain to implement

**Step 1 — Unauthenticated request triggers 401/403**
```
POST http://localhost:8000/mcp (no Authorization header)
Expect: HTTP 401 or 403
Expect: WWW-Authenticate header present
```
Note: Istio may return 403 instead of 401 for missing tokens. Accept either.

**Step 2 — Extract resource_metadata URL from WWW-Authenticate**
```
Parse WWW-Authenticate header
Extract: resource_metadata="<url>"
Expect: URL is non-empty and starts with http
```

**Step 3 — Fetch OAuth Protected Resource document**
```
GET <resource_metadata_url>
Expect: HTTP 200
Expect: JSON body with "authorization_servers" array (non-empty)
Expect: JSON body with "scopes_supported" array containing "tools:classify.submit"
Extract: authorization_servers[0] as AS_URL
```

**Step 4 — Fetch OpenID Connect discovery document**
```
GET <AS_URL>/.well-known/openid-configuration
Expect: HTTP 200
Expect: JSON body with "token_endpoint"
Expect: JSON body with "issuer"
Extract: token_endpoint
```

**Step 5 — Acquire token via client credentials**
```
POST <token_endpoint>
  grant_type=client_credentials
  client_id=mcp-agent
  client_secret=<from values.local.yaml or hardcoded for test>
  scope=tools:classify.submit
Expect: HTTP 200
Expect: JSON body with "access_token"
Extract: access_token
```

**Step 6 — Authenticated request succeeds**
```
POST http://localhost:8000/mcp
  Authorization: Bearer <access_token>
  Content-Type: application/json
  Body: valid MCP tool call
Expect: HTTP 200
```

## How to validate

```bash
# 1. Start the stack if not running
./scripts/status.sh

# 2. Run the discovery chain test
./scripts/rfc9728-test.sh

# 3. Confirm exit code
echo "Exit code: $?"   # must be 0 when all steps pass

# 4. Simulate a failure (optional manual test)
# Stop the MCP server temporarily and run again — should exit 1

# 5. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- Script exists and is executable
- Six steps are clearly labelled in the output (e.g. `[PASS] Step 1: Unauthenticated request returns 401/403`)
- Exit 0 on clean run
- Each step failure produces a descriptive message (not just "FAIL")
- The `resource_metadata` URL extracted in Step 2 is printed in the output
- The `token_endpoint` discovered in Step 4 is printed in the output
- Script does not hardcode the Keycloak URL — it discovers it from the MCP server
- `scripts/README.md` has a new entry

## Notes / constraints

### Curl patterns
Reference `scripts/auth-test.sh` for working curl patterns against this stack. Key patterns:

```bash
# Capture response headers and body separately
HTTP_CODE=$(curl -s -o /tmp/response_body -w "%{http_code}" ...)
BODY=$(cat /tmp/response_body)
WWW_AUTH=$(curl -sI http://localhost:8000/mcp -X POST | grep -i "www-authenticate")
```

### Extracting resource_metadata from WWW-Authenticate
The header format is:
```
WWW-Authenticate: Bearer resource_metadata="http://localhost:8000/.well-known/oauth-protected-resource"
```

Extract with:
```bash
METADATA_URL=$(echo "$WWW_AUTH" | grep -oP 'resource_metadata="\K[^"]+')
```

### MCP tool call body for Step 6
Use a minimal valid MCP tool call. Reference `scripts/classify.sh` or `scripts/demo.sh` for the correct JSON body format for `classify_payload_sensitivity`.

### Client credentials for Step 5
The client ID and secret are in `helm/mcp-server/values.local.yaml`. Hardcoding them in the test script is acceptable for a local dev test. Add a comment noting these match `values.local.yaml`.

### Step 1 note on 401 vs 403
Istio's JWT authn filter returns 401 for a missing token when properly configured. If the filter is in PERMISSIVE mode or the request matches a bypass rule, behaviour may differ. Accept either 401 or 403 in Step 1 as valid. If neither is returned (e.g. 200), that is a genuine test failure — the auth boundary is not enforced.

### RFC 9728 specification reference
RFC 9728 "OAuth 2.0 Protected Resource Metadata" defines:
- The `WWW-Authenticate` challenge with `resource_metadata` parameter
- The `/.well-known/oauth-protected-resource` endpoint
- The required fields: `resource`, `authorization_servers`, `scopes_supported`

The full chain (Flow 2) is documented in `planning/auth-flows-diagram.md`.
