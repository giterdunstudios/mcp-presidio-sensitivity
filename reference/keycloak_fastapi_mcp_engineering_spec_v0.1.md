# Engineering Specification
## Project: Keycloak + FastAPI MCP Gateway for an Unauthenticated Backend
**Version:** v0.1  
**Status:** Draft for coding-agent implementation  
**Chosen route:** Keycloak for token issuance + FastAPI MCP server with local JWT/JWKS validation + private backend service

---

## 1. Executive summary

Build a **remote HTTP MCP server** in Python that sits in front of an internal backend service that does not perform external authentication.

The MCP server will:

- accept bearer access tokens issued by **Keycloak**
- validate JWTs locally using **Keycloak OIDC discovery + JWKS**
- validate issuer, audience/resource binding, expiry, and scopes/roles
- authorize access to MCP tools before any backend call is made
- call the backend service over a private/internal path only
- never pass the external bearer token to the backend service

This design keeps authentication issuance and client registration in **Keycloak**, while keeping **resource-server enforcement** and **tool-level authorization** in the MCP server.

---

## 2. Goals

### 2.1 Primary goals
- Use **standard OAuth 2.0 client credentials** for service-to-service access
- Avoid building a custom auth framework
- Keep the system lightweight and production-ready
- Preserve a clean trust boundary at the MCP server
- Support future hardening to **private-key JWT** and possibly **mTLS** without rewriting the core authorization model

### 2.2 Non-goals for v1
- No login UI
- No user-delegated auth flow
- No external policy engine
- No NGINX requirement
- No oauth2-proxy requirement
- No token introspection unless forced by a future token format choice
- No token passthrough to downstream services
- No backend-side external auth

---

## 3. Design decisions already locked

### 3.1 Locked auth pattern
**Caller service** → obtains token from **Keycloak** using **client credentials** → calls **FastAPI MCP server** with bearer token → MCP server validates token locally → MCP server authorizes tool access → MCP server calls **backend service**

### 3.2 Locked technology choices
- **Identity provider:** Keycloak
- **MCP server framework:** FastAPI
- **MCP implementation:** Python MCP SDK
- **JWT validation:** local validation against JWKS inside the MCP server
- **Protocol style:** HTTP-based remote MCP
- **Principal type for v1:** service principal only

### 3.3 Pinned baseline
- **Python:** `3.12`
- **MCP SDK:** `mcp==1.23.1`
- **FastAPI:** `fastapi==0.135.2`
- **Keycloak image:** `quay.io/keycloak/keycloak:26.5.6`

---

## 4. Standards and protocol context

This implementation is based on the following model:

- The **MCP server** is the **protected resource / resource server**
- The **authorization server** issues access tokens for use at the MCP server
- For HTTP-based MCP, authorization should follow the MCP authorization model
- For machine-to-machine use, the intended direction is the MCP **OAuth client credentials extension**
- Access tokens are sent as `Authorization: Bearer <token>`
- The MCP server must validate that the token was issued for that MCP server

This spec therefore treats the MCP server as the security boundary, not as a blind relay.

---

## 5. High-level architecture

```text
+------------------+        +------------------+        +--------------------------+        +-------------------+
| Caller Service   | -----> | Keycloak         | -----> | FastAPI MCP Server       | -----> | Backend Service   |
| (service client) | token  | (token issuer)   | bearer | (JWT validation + authz) |        | (private only)    |
+------------------+        +------------------+        +--------------------------+        +-------------------+
```

### Trust boundaries
1. **External auth boundary:** caller service must authenticate to Keycloak
2. **Protected resource boundary:** caller must present a valid access token to the MCP server
3. **Internal trust boundary:** backend only trusts requests from the MCP server path

---

## 6. Core security model

### 6.1 What Keycloak does
Keycloak is responsible for:
- client registration
- confidential client configuration
- service account / client credentials support
- token issuance
- signing keys
- OIDC discovery metadata
- JWKS publication

### 6.2 What the MCP server does
The MCP server is responsible for:
- accepting bearer tokens
- validating token signature via JWKS
- validating issuer
- validating audience or resource binding
- validating expiry / not-before if applicable
- extracting scopes and/or roles
- mapping tools to required permission claims
- returning `401` for invalid tokens
- returning `403` for insufficient permissions
- mediating backend access
- logging security-relevant events

### 6.3 What the backend does
The backend service is responsible only for:
- business logic
- accepting internal requests from the MCP server
- processing authorized operations

The backend is **not** responsible for:
- validating external bearer tokens
- making external authn/authz decisions
- exposing a public endpoint to untrusted callers

---

## 7. Functional requirements

### FR-1: HTTP MCP endpoint
The system shall expose an HTTP-based MCP endpoint.

### FR-2: Bearer token support
The MCP server shall require bearer tokens for protected operations.

### FR-3: JWT validation
The MCP server shall validate the bearer token locally using Keycloak OIDC discovery metadata and JWKS.

### FR-4: Issuer validation
The token issuer (`iss`) shall exactly match the configured Keycloak realm issuer.

### FR-5: Audience/resource validation
The token must be valid for the MCP server as the intended resource/audience.

### FR-6: Expiry validation
Expired tokens shall be rejected.

### FR-7: Tool-level authorization
Each MCP tool shall declare a required scope or role. Calls lacking the required permission shall be rejected with `403`.

### FR-8: Backend mediation
The MCP server shall call the backend only after successful validation and authorization.

### FR-9: No token passthrough
The MCP server shall never pass the external `Authorization` bearer token to the backend service.

### FR-10: Audit logging
The MCP server shall emit structured logs for all authentication and authorization decisions.

### FR-11: MCP authorization metadata
For HTTP-based MCP, the server shall support the required protected resource metadata and `WWW-Authenticate` behavior for `401` responses.

---

## 8. Non-functional requirements

### NFR-1: Lightweight
The v1 system shall not require NGINX or an external auth proxy.

### NFR-2: Production-ready
The design shall be valid for controlled production deployment, not only for local experimentation.

### NFR-3: Evolvable
The design shall allow future migration from client secret to private-key JWT and later mTLS without redesigning the MCP authorization core.

### NFR-4: Least privilege
Scopes/roles must be narrow and mapped to explicit capabilities.

### NFR-5: Observability
The system shall emit logs and correlation IDs sufficient for auth debugging and audit trails.

### NFR-6: Isolation
The backend shall be reachable only from trusted internal paths.

---

## 9. Token model

### 9.1 v1 token acquisition method
Use **OAuth 2.0 Client Credentials Grant** with:
- `client_id`
- `client_secret`

### 9.2 v2 hardening path
Upgrade to:
- client credentials with **private-key JWT**

### 9.3 Explicitly deferred
- mTLS-bound access tokens
- user-delegated OAuth flows
- password grant
- implicit flow

---

## 10. Authorization model

### 10.1 Recommended permission representation
Use one of:
- **scopes**
- **client roles**
- **realm roles**

For v1, the preferred design is:
- use **client-scoped roles or scopes** tied specifically to the MCP service capability model

### 10.2 Recommended v1 scope/role set
Example permissions:
- `mcp.health.read`
- `mcp.classify.submit`
- `mcp.classify.read`
- `mcp.tools.list`

### 10.3 Example tool-to-permission mapping
| MCP Tool | Required Permission |
|---|---|
| `health_check` | `mcp.health.read` |
| `classify_payload` | `mcp.classify.submit` |
| `get_policy_info` | `mcp.classify.read` |
| `list_tools_safe` | `mcp.tools.list` |

### 10.4 Authorization policy rule
A request is allowed only if:
1. the token is valid
2. the token is intended for this MCP server
3. the token contains the required permission for the requested tool
4. any input-specific policy checks pass

---

## 11. Sequence flows

### 11.1 Token acquisition
1. Caller service sends token request to Keycloak token endpoint
2. Caller authenticates using `client_id` and `client_secret`
3. Keycloak returns access token
4. Caller caches token until expiry minus a safety margin

### 11.2 MCP call
1. Caller service sends HTTP request to MCP endpoint with:
   - `Authorization: Bearer <token>`
2. MCP server parses and validates token
3. MCP server determines requested MCP operation/tool
4. MCP server checks required permission
5. If denied:
   - return `401` or `403` as appropriate
6. If allowed:
   - MCP server sends internal request to backend
   - MCP server transforms backend response into MCP response

### 11.3 Error flow
- invalid signature → `401`
- wrong issuer → `401`
- wrong audience/resource → `401`
- expired token → `401`
- missing permission → `403`
- malformed auth header → `400` or `401` depending on handler policy
- backend unavailable → controlled `5xx` or mapped MCP-safe error

---

## 12. Keycloak engineering requirements

### 12.1 Local deployment mode
Use Keycloak in a container for local development.

### 12.2 Realm
Create a dedicated realm for this system, for example:
- `mcp-local`

### 12.3 Client
Create a dedicated confidential client for the calling service, for example:
- `svc-caller`

### 12.4 Client settings
The confidential client shall:
- be allowed to use client credentials
- have a service account if role assignment is required
- be restricted to the minimum needed scope/role set

### 12.5 Realm import
Provide a realm import JSON for local bootstrap to avoid manual clicking.

### 12.6 Admin bootstrap
For local dev only, use bootstrap admin credentials from environment variables.

### 12.7 Secrets
Do not hardcode Keycloak client secrets in source control. Store them in local dev environment files excluded from version control and in managed secret stores for deployed environments.

---

## 13. FastAPI MCP server engineering requirements

### 13.1 Framework responsibility split
FastAPI application shall contain:
- MCP transport handler
- auth middleware or dependency layer
- token validation module
- authorization module
- backend client adapter
- observability layer

### 13.2 Required auth validations
The auth module shall validate:
- bearer token presence
- JWT signature
- token issuer
- token audience/resource
- token expiry
- required claims for the requested action

### 13.3 JWKS behavior
The MCP server shall:
- discover JWKS from Keycloak metadata
- cache signing keys
- support key rotation without restart where practical
- fail closed when validation cannot be completed safely

### 13.4 Required server behavior
- protected endpoints return `401` when token is missing or invalid
- protected endpoints return `403` when permission is insufficient
- MCP metadata/auth discovery behavior must align with HTTP MCP expectations

### 13.5 Internal context propagation
The MCP server may pass an internal context object to the backend:
- `caller_type`
- `subject_id`
- `client_id`
- `authorized_permission`
- `correlation_id`

The MCP server shall **not** forward the raw external bearer token.

---

## 14. Backend trust boundary requirements

### 14.1 Connectivity
The backend shall not be internet-facing.

### 14.2 Access restriction
The backend shall only accept requests from:
- localhost on the same runtime
- internal network only
- explicitly allowed service identity / network policy

### 14.3 No external auth assumptions
The backend shall not assume the caller can present a valid external bearer token.

### 14.4 Optional internal hardening
The backend may optionally require one of:
- internal static shared secret
- mTLS from MCP server to backend
- network allowlisting
- service mesh identity

This is internal-to-platform hardening and separate from the external OAuth model.

---

## 15. Configuration requirements

### 15.1 Environment variables for the MCP server
Minimum required variables:

```env
APP_ENV=local
MCP_SERVER_URL=http://localhost:8000/mcp
KEYCLOAK_BASE_URL=http://localhost:8080
KEYCLOAK_REALM=mcp-local
KEYCLOAK_ISSUER=http://localhost:8080/realms/mcp-local
KEYCLOAK_OIDC_CONFIG_URL=http://localhost:8080/realms/mcp-local/.well-known/openid-configuration
EXPECTED_AUDIENCE=mcp-gateway
BACKEND_BASE_URL=http://backend:9000
AUTH_REQUIRED=true
LOG_LEVEL=INFO
```

### 15.2 Environment variables for caller service
```env
KEYCLOAK_TOKEN_URL=http://localhost:8080/realms/mcp-local/protocol/openid-connect/token
KEYCLOAK_CLIENT_ID=svc-caller
KEYCLOAK_CLIENT_SECRET=local-dev-secret
TOKEN_SCOPE=mcp.classify.submit
MCP_SERVER_URL=http://localhost:8000/mcp
```

### 15.3 Environment variables for Keycloak container
```env
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=change_me
```

---

## 16. Local deployment model

### 16.1 Recommended local stack
- `keycloak` container
- `mcp-server` Python service
- `backend` service
- optional `caller-service` test harness

### 16.2 Recommended orchestration
Use `docker compose` for local development.

### 16.3 Local Keycloak startup approach
Use:
- development mode for local only
- optional realm import on startup

### 16.4 Production note
A future production deployment must not use dev-mode defaults and must explicitly configure:
- database
- TLS strategy
- secret management
- logging
- memory limits
- backup strategy

---

## 17. Repository structure

```text
mcp-keycloak-gateway/
  README.md
  docs/
    engineering-spec.md
    architecture.md
    security-model.md
    keycloak-setup.md
    test-plan.md
  deployment/
    docker-compose.yml
    keycloak/
      realm-import/
        mcp-local-realm.json
      env/
        keycloak.local.env.example
    mcp-server/
      Dockerfile
      env/
        mcp.local.env.example
    caller-service/
      env/
        caller.local.env.example
  src/
    app/
      main.py
      config.py
    auth/
      discovery.py
      jwks.py
      validator.py
      claims.py
      errors.py
    authorization/
      permissions.py
      policy.py
      decision.py
    mcp/
      server.py
      tools/
        classify_payload.py
        get_policy_info.py
        health_check.py
    backend/
      client.py
      models.py
      mapper.py
    observability/
      logging.py
      tracing.py
      metrics.py
  tests/
    unit/
    integration/
    security/
  requirements.txt
  pyproject.toml
```

---

## 18. Work breakdown for coding agents

### Agent 1 — Solution scaffolding
Deliver:
- repository skeleton
- Python environment setup
- `pyproject.toml` and/or `requirements.txt`
- base FastAPI app
- basic MCP route skeleton

### Agent 2 — Keycloak local bootstrap
Deliver:
- docker-compose Keycloak service
- realm import JSON
- confidential client configuration
- local README for realm/client bootstrap
- example env files

### Agent 3 — JWT validation module
Deliver:
- OIDC discovery fetcher
- JWKS retrieval and caching
- JWT validation functions
- issuer/audience/expiry enforcement
- validation unit tests

### Agent 4 — Authorization policy module
Deliver:
- tool-to-permission map
- authorization evaluator
- 401/403 mapping behavior
- tests for allow/deny cases

### Agent 5 — MCP server integration
Deliver:
- auth integration into MCP request handling
- protected resource metadata support
- `WWW-Authenticate` behavior
- correlation ID propagation
- structured error mapping

### Agent 6 — Backend adapter
Deliver:
- internal backend client
- context propagation model
- timeout/retry policy
- no-token-passthrough enforcement
- integration tests with a mock backend

### Agent 7 — Observability and audit
Deliver:
- structured logging
- log schema for auth decisions
- request correlation
- metrics for auth failures and tool usage

### Agent 8 — Test automation
Deliver:
- unit tests
- integration tests
- negative/security tests
- local test harness for obtaining a Keycloak token and calling MCP

---

## 19. Acceptance criteria

### AC-1
A caller service can obtain a token from Keycloak using client credentials.

### AC-2
The MCP server successfully validates a valid Keycloak-issued JWT locally.

### AC-3
A request with an invalid signature is rejected with `401`.

### AC-4
A request with the wrong issuer is rejected with `401`.

### AC-5
A request with the wrong audience/resource is rejected with `401`.

### AC-6
A request with an expired token is rejected with `401`.

### AC-7
A request without the required permission is rejected with `403`.

### AC-8
A valid authorized request reaches the backend successfully.

### AC-9
The backend never receives the original external bearer token.

### AC-10
Protected resource metadata and `WWW-Authenticate` behavior are implemented for the MCP endpoint.

### AC-11
All auth decisions are logged with correlation identifiers.

---

## 20. Test strategy

### 20.1 Unit tests
- valid token accepted
- invalid signature rejected
- wrong issuer rejected
- wrong audience rejected
- expired token rejected
- permission map enforced

### 20.2 Integration tests
- local Keycloak bootstraps correctly
- confidential client can obtain token
- MCP route accepts valid token
- invalid token returns `401`
- missing permission returns `403`
- valid request reaches backend
- backend response is correctly mapped into MCP response

### 20.3 Security tests
- verify raw bearer token is not forwarded downstream
- verify server fails closed when JWKS fetch fails unexpectedly
- verify malformed `Authorization` header is handled safely
- verify backend cannot be reached directly from an untrusted path
- verify over-broad permissions are not accidentally granted

### 20.4 Regression tests
- new tools require explicit permission mapping
- key rotation does not silently break validation behavior
- future migration to private-key JWT does not require rewriting the authorization module

---

## 21. Logging and observability

### 21.1 Required log fields
- timestamp
- log level
- request ID / correlation ID
- client ID if available
- subject identifier if available
- issuer
- audience/resource
- requested tool
- decision (`allow` / `deny`)
- denial reason
- backend target
- duration

### 21.2 Metrics
At minimum, expose counters for:
- successful token validations
- failed token validations
- authorization denies
- successful tool invocations
- backend failures

### 21.3 Sensitive data rules
Never log:
- full bearer tokens
- client secrets
- private keys
- raw backend credentials

---

## 22. Future evolution plan

### 22.1 Phase 2 hardening
Upgrade caller auth to:
- **private-key JWT** for client authentication to Keycloak

### 22.2 Phase 3 optional hardening
Evaluate:
- mTLS client auth to Keycloak
- mTLS between MCP server and backend
- gateway/ingress in front of MCP for TLS/rate limiting
- policy engine externalization

### 22.3 Deliberate non-breaking design rule
The JWT validation and authorization core must stay reusable across:
- client secret
- private-key JWT
- future mTLS

Only the **caller → Keycloak client authentication method** should change.

---

## 23. Risks and mitigations

### Risk 1: confusion over audience/resource claim handling
Mitigation:
- make expected audience/resource explicit in configuration
- add tests for wrong-resource tokens

### Risk 2: JWKS/network dependency failures
Mitigation:
- cache JWKS
- fail closed safely
- expose operational error logs

### Risk 3: over-broad permissions
Mitigation:
- narrow per-tool permission mapping
- require explicit mapping for each new tool

### Risk 4: local setup friction
Mitigation:
- use docker compose
- provide realm import
- provide example env files
- provide a simple token acquisition smoke test

### Risk 5: future migration to stronger client auth
Mitigation:
- isolate caller-to-Keycloak auth config from MCP server validation logic

---

## 24. Deliverables expected from the team

The first complete iteration shall include:

1. a shareable repo with the structure described above  
2. a working local Keycloak container setup  
3. a realm import file  
4. a FastAPI MCP server that validates Keycloak JWTs locally  
5. a mock backend service  
6. a sample caller script/service that gets a token and calls the MCP endpoint  
7. automated tests covering success and failure auth paths  
8. basic documentation for local startup and troubleshooting  

---

## 25. Explicit implementation rules

- Do not build a custom OAuth server
- Do not forward external bearer tokens to the backend
- Do not rely on password grant
- Do not make the backend public
- Do not add NGINX unless later required for a separately approved reason
- Do not leave permissions implicit; every protected tool must have an explicit permission requirement
- Do not store secrets in the repository

---

## 26. References

### MCP
- Authorization spec: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- OAuth client credentials extension: https://modelcontextprotocol.io/extensions/auth/oauth-client-credentials

### Keycloak
- OIDC application/service security: https://www.keycloak.org/securing-apps/oidc-layers
- Running Keycloak in a container: https://www.keycloak.org/server/containers

---

## 27. Immediate next iteration candidates

Choose one or more for the next revision:
1. add concrete `docker-compose.yml`
2. add concrete Keycloak realm JSON structure
3. add concrete FastAPI module interfaces
4. add concrete JWT validation pseudocode
5. add concrete MCP tool contract examples
6. add a phased implementation backlog with task ordering
