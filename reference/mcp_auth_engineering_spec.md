# Engineering Specification

## Project
**Authenticated MCP façade for an unauthenticated downstream service**

## Goal
Expose a protected MCP server that:
- authenticates callers
- authorizes access per tool/action
- invokes a backend service that does not implement auth
- never passes client tokens through to the backend

This matches MCP’s model where the MCP server is the OAuth resource server, and it avoids the token-passthrough anti-pattern forbidden by MCP security guidance.

---

# 1. Scope

## In scope
- HTTP-based remote MCP server
- Built-in token validation in the MCP server
- Tool-level authorization checks
- Protected Resource Metadata discovery
- 401 challenges with `WWW-Authenticate`
- Internal call from MCP server to backend service
- Audit logging
- Minimal secrets handling
- Agent-dividable implementation plan

## Out of scope for v1
- NGINX or external API gateway
- Dynamic client registration unless required
- Multi-tenant auth complexity
- End-user session UI beyond what is needed for the auth flow
- Policy engine externalization
- Fine-grained ABAC/RBAC beyond scoped tool access
- Token exchange / downstream delegated auth

---

# 2. Architecture

## v1 logical flow

**MCP Client**  
→ **Authenticated MCP Server**  
→ **Internal Backend Service (no auth)**

## Security boundary
The MCP server is the enforcement point:
- validates tokens
- checks issuer/audience/expiry
- checks required scopes for requested MCP operations
- maps tool calls to allowed backend actions
- calls backend over private/internal network path only

The downstream service must not be internet-facing and must not trust arbitrary callers.

---

# 3. Recommended auth model

## Recommended v1 model
**OAuth-based authorization enforced directly in the MCP server**

Why:
- MCP HTTP auth is defined around the MCP server acting as the protected resource / resource server.
- It is the smallest architecture with the fewest moving parts.
- The MCP server is the only component that understands MCP tools/resources well enough to apply tool-level authorization correctly.
- It avoids introducing an edge proxy before it is needed.

## Principal types supported
### User-driven callers
Use the standard MCP authorization flow for HTTP-based transport. This is the fit when a human is authorizing access.

### Service-driven callers
Support OAuth client credentials only if needed in v1. If enabled, prefer JWT bearer assertions over client secrets, as recommended by the MCP client-credentials extension.

## Explicit non-goal
Do **not** pass upstream client tokens through to the backend service.

---

# 4. Functional requirements

## FR-1: MCP server transport
The server shall expose an HTTP-based MCP endpoint.

## FR-2: Protected server behavior
When an unauthenticated request is received, the server shall return `401 Unauthorized` with a `WWW-Authenticate: Bearer ...` challenge that includes `resource_metadata`, and should include `scope` guidance where appropriate.

## FR-3: Protected Resource Metadata
The MCP server shall publish Protected Resource Metadata at the appropriate well-known location and include at least one authorization server in `authorization_servers`.

## FR-4: Token validation
On every authenticated request, the MCP server shall validate:
- signature
- issuer
- audience / resource binding for this MCP server
- expiry / not-before if present
- required scopes for requested action

## FR-5: Tool authorization
Each MCP tool/resource/action shall declare required scopes.  
The MCP server shall deny requests when the presented token lacks required scopes.

## FR-6: Backend mediation
The MCP server shall invoke the backend service only after successful authn/authz.  
The backend service shall receive only trusted internal context required for business execution.

## FR-7: Audit logging
The MCP server shall log:
- request ID / correlation ID
- caller principal type: user or service
- subject identifier
- issuer
- audience
- requested MCP method/tool
- authorization decision
- backend action invoked
- timestamp
- outcome

## FR-8: Secrets handling
Secrets shall be stored in a secrets manager or secure deployment secret store, never in source control.

---

# 5. Non-functional requirements

## NFR-1: Simplicity
The v1 implementation shall not require an external reverse proxy solely for authentication.

## NFR-2: Least privilege
Scopes shall be narrow and mapped per tool or capability, not catch-all.

## NFR-3: Internal isolation
The backend service shall not be directly reachable by untrusted clients.

## NFR-4: Secure transport
HTTPS shall be enforced in production for the MCP endpoint and authorization endpoints.

## NFR-5: Observability
All auth decisions and backend calls shall be observable with correlation IDs.

## NFR-6: Evolvability
The design shall allow insertion of NGINX / API gateway later without changing the MCP authorization model.

---

# 6. Authorization design

## Scope model
Define narrow scopes by capability.

Example:
- `tools:classify`
- `tools:classify.read`
- `tools:classify.submit`
- `tools:health.read`

Avoid:
- `admin:*`
- `tools:*`
- generic broad audiences

## Tool mapping example
- MCP tool `classify_payload` → requires `tools:classify.submit`
- MCP tool `get_policy_info` → requires `tools:classify.read`
- MCP tool `health_check` → requires `tools:health.read`

## Principal policy
### User token
Allowed where a human user is the real actor.

### Service token
Allowed for scheduled or backend automation. If used, validate as machine principal and apply service-specific allowed scopes.

---

# 7. Backend trust model

The backend service cannot perform auth, so it must trust only the MCP server path.

## Required controls
- backend bound to private interface/network only
- network ACL / security group / firewall restricts access to MCP server host or runtime
- optional internal shared credential or mTLS between MCP server and backend
- backend does not accept end-user bearer tokens
- backend does not make its own auth decisions in v1

## Internal context contract
The MCP server may pass a minimized internal context object:
- `caller_type`
- `subject_id`
- `tenant_id` if applicable
- `authorized_action`
- `correlation_id`

It must not forward the original external bearer token to the backend.

---

# 8. API / protocol behaviors

## Unauthenticated call behavior
Return:
- `401 Unauthorized`
- `WWW-Authenticate: Bearer ...`
- `resource_metadata=<url>`
- optional `scope=<required_scope>`

## Unauthorized call behavior
Return:
- `403 Forbidden` when identity is valid but lacks required scope/policy

## Error handling
Externally:
- generic error messages

Internally logged:
- detailed denial reason
- token validation failure reason
- policy mismatch
- backend invocation failure

---

# 9. Implementation components

## Component A: MCP server
Responsibilities:
- expose MCP endpoint
- return auth challenge / metadata
- validate tokens
- authorize tools
- invoke backend
- log decisions

## Component B: Token verifier module
Responsibilities:
- fetch/signing-key discovery from authorization server metadata/JWKS
- validate JWT signature
- validate issuer
- validate audience/resource
- validate token lifetime
- extract scopes and subject

## Component C: Authorization policy module
Responsibilities:
- map MCP methods/tools to required scopes
- support user/service principal distinction
- perform allow/deny decision
- emit reason codes for logs

## Component D: Backend adapter
Responsibilities:
- translate MCP tool calls to backend API calls
- attach minimal internal trusted context
- normalize backend errors into MCP-safe responses

## Component E: Metadata endpoints
Responsibilities:
- serve Protected Resource Metadata
- declare authorization server locations
- ensure compatibility with MCP client discovery flow

---

# 10. Suggested repo structure

```text
mcp-auth-gateway/
  README.md
  docs/
    architecture.md
    security-model.md
    scopes.md
    test-plan.md
  src/
    app/
      main.(py|ts|go)
      config.*
    auth/
      token_verifier.*
      jwks_cache.*
      claims.*
      auth_errors.*
    authorization/
      policy_engine.*
      scope_map.*
      decision_types.*
    mcp/
      server.*
      tools/
        classify_payload.*
        get_policy_info.*
        health_check.*
    backend/
      client.*
      models.*
      mapper.*
    observability/
      logging.*
      tracing.*
      metrics.*
  tests/
    unit/
    integration/
    security/
  deployment/
    env-example
    helm-or-manifest-later/
```

---

# 11. Work breakdown for coding agents

## Agent 1 — MCP server foundation
Deliver:
- HTTP MCP server skeleton
- unauthenticated 401 behavior
- Protected Resource Metadata endpoint
- basic health endpoint

## Agent 2 — Token validation
Deliver:
- issuer config
- JWKS retrieval / cache
- JWT validation middleware/module
- audience/resource validation
- scope extraction

## Agent 3 — Authorization policy
Deliver:
- tool-to-scope map
- policy evaluator
- 403 deny handling
- decision logging hooks

## Agent 4 — Backend adapter
Deliver:
- backend client wrapper
- internal request context mapping
- retry/error handling rules
- no-token-passthrough guarantee

## Agent 5 — Observability and audit
Deliver:
- structured logs
- correlation IDs
- auth decision events
- metrics for allow/deny/failure classes

## Agent 6 — Test automation
Deliver:
- unit tests for token verification
- unit tests for policy rules
- integration tests for 401/403/200 flows
- security tests for invalid issuer/audience/token expiry
- regression test proving token passthrough is blocked

---

# 12. Acceptance criteria

## AC-1
Unauthenticated requests to the MCP endpoint return `401` with a valid `WWW-Authenticate` challenge and discoverable resource metadata.

## AC-2
Requests with invalid issuer, invalid audience, expired token, or bad signature are rejected.

## AC-3
Requests with valid token but missing required scope are rejected with `403`.

## AC-4
Authorized requests invoke the backend successfully.

## AC-5
No external bearer token is forwarded to the backend in any execution path.

## AC-6
Logs show principal, tool, decision, and correlation ID for all requests.

## AC-7
Backend is unreachable directly from untrusted network paths.

---

# 13. Test plan

## Unit tests
- valid JWT accepted
- invalid signature rejected
- wrong issuer rejected
- wrong audience rejected
- expired token rejected
- scope mapping works per tool

## Integration tests
- no token → 401 + challenge
- valid token + valid scope → success
- valid token + missing scope → 403
- valid token + backend failure → controlled error
- PRM metadata endpoint available and correct

## Security tests
- attempt token meant for other resource server → reject
- attempt generic audience token → reject
- attempt backend direct call from non-MCP path → reject
- verify Authorization header is not forwarded downstream

---

# 14. Deferred items for v2+

- NGINX / API gateway in front for TLS termination and centralized edge controls
- rate limiting at edge
- dynamic client registration if needed
- multi-tenant issuer support
- external policy engine
- machine-to-machine client credentials support if automation callers are added
- mTLS to backend
- fine-grained ABAC/RBAC
- token introspection fallback for non-JWT ecosystems

---

# 15. Direct recommendation

For the simplest version, build:

**An HTTP-based MCP server that directly implements OAuth/JWT validation, Protected Resource Metadata, per-tool scope authorization, and a private backend adapter, with no NGINX in v1 and no token passthrough.**

---

# References

- MCP Authorization Specification (draft): https://modelcontextprotocol.io/specification/draft/basic/authorization
- MCP Security Best Practices: https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices
- MCP Authorization Guidance: https://modelcontextprotocol.io/docs/tutorials/security/authorization
- MCP OAuth Client Credentials Extension: https://modelcontextprotocol.io/extensions/auth/oauth-client-credentials
