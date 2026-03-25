# Auth Connection Flows

Three views: what we built, what the ideal looks like, and the industry standard.

---

## Flow 1 — Current Implementation

Client needs **two URLs pre-configured**: Keycloak token endpoint + MCP server URL.
Discovery is skipped; credentials are injected out-of-band (demo script / Helm config).

```mermaid
sequenceDiagram
    actor Agent as Agent / Client
    participant KCK as Keycloak<br/>(Authorization Server)
    participant MCP as MCP Server<br/>(Protected Resource)
    participant WRK as Presidio Worker<br/>(Internal)

    note over Agent: Needs Keycloak URL + MCP URL<br/>pre-configured out-of-band

    Agent->>KCK: POST /token<br/>grant_type=client_credentials<br/>client_id + client_secret + scope
    KCK-->>Agent: 200 access_token (JWT, TTL 300s)

    Agent->>MCP: POST /mcp<br/>Authorization: Bearer JWT
    MCP->>MCP: Validate JWT locally<br/>(JWKS cache from Keycloak)
    MCP->>MCP: Check scope: tools:classify.submit
    MCP->>WRK: POST /scan (internal, no token)
    WRK-->>MCP: ScanResponse (bounded result)
    MCP-->>Agent: 200 tool result (no payload)
```

---

## Flow 2 — Ideal (RFC 9728 Discovery)

Client needs **only the MCP server URL**. Everything else is discovered.
This is what our RFC 9728 fix enables — a compliant client can now do this chain.

```mermaid
sequenceDiagram
    actor Agent as Agent / Client
    participant MCP as MCP Server<br/>(Protected Resource)
    participant KCK as Keycloak<br/>(Authorization Server)
    participant WRK as Presidio Worker<br/>(Internal)

    note over Agent: Needs only MCP server URL

    Agent->>MCP: POST /mcp (no token)
    MCP-->>Agent: 401 WWW-Authenticate:<br/>Bearer resource_metadata=<br/>"https://mcp/.well-known/oauth-protected-resource"

    Agent->>MCP: GET /.well-known/oauth-protected-resource
    MCP-->>Agent: { authorization_servers: ["https://keycloak/realms/mcp-local"],<br/>  scopes_supported: ["tools:classify.submit"] }

    Agent->>KCK: GET /.well-known/openid-configuration
    KCK-->>Agent: { token_endpoint, jwks_uri, issuer, ... }

    Agent->>KCK: POST /token<br/>grant_type=client_credentials + scope
    KCK-->>Agent: access_token (JWT)

    Agent->>MCP: POST /mcp<br/>Authorization: Bearer JWT
    MCP->>MCP: Validate JWT locally (JWKS cache)
    MCP->>MCP: Check scope
    MCP->>WRK: POST /scan
    WRK-->>MCP: ScanResponse
    MCP-->>Agent: 200 tool result
```

---

## Flow 3 — Industry Standard (OAuth 2.1 + MCP Auth Spec)

Full MCP Authorization Specification (2025) + OAuth 2.1 + RFC 7591 Dynamic Client Registration.
Covers both **interactive user clients** (auth code + PKCE) and **M2M agents** (client credentials).
mTLS enforced between all services. Short-lived tokens. Refresh + revocation lifecycle.

```mermaid
sequenceDiagram
    actor User as Human User<br/>(Interactive Client)
    actor Agent as Automated Agent<br/>(M2M Client)
    participant MCP as MCP Server<br/>(Resource + Auth Proxy)
    participant AS as Authorization Server<br/>(e.g. Keycloak / Okta)
    participant WRK as Presidio Worker<br/>(mTLS internal)

    note over User,Agent: Both paths start from MCP URL only

    rect rgb(230, 240, 255)
        note over User,MCP: Interactive path — Authorization Code + PKCE (RFC 7636)

        User->>MCP: GET /mcp (no token)
        MCP-->>User: 401 + resource_metadata URL

        User->>MCP: GET /.well-known/oauth-protected-resource
        MCP-->>User: AS URL + scopes

        User->>AS: Dynamic Client Registration (RFC 7591)<br/>POST /register { redirect_uris, grant_types }
        AS-->>User: client_id (no secret — public client)

        User->>AS: GET /authorize?response_type=code<br/>code_challenge (PKCE S256) + scope
        AS-->>User: Redirect → login UI
        User->>AS: Authenticate (MFA)
        AS-->>User: auth_code (short-lived)

        User->>AS: POST /token<br/>auth_code + code_verifier (PKCE)
        AS-->>User: access_token (JWT, 5min) + refresh_token (24h)

        User->>MCP: POST /mcp Bearer JWT
        MCP->>AS: Validate via JWKS (cached)
        MCP->>WRK: mTLS POST /scan
        WRK-->>MCP: ScanResponse
        MCP-->>User: 200 tool result

        note over User,AS: Token refresh cycle
        User->>AS: POST /token grant_type=refresh_token
        AS-->>User: new access_token + rotated refresh_token

        note over User,AS: Logout / revocation
        User->>AS: POST /revoke (refresh_token)
    end

    rect rgb(230, 255, 235)
        note over Agent,MCP: M2M path — Client Credentials (RFC 6749 §4.4)

        Agent->>MCP: POST /mcp (no token)
        MCP-->>Agent: 401 + resource_metadata URL

        Agent->>MCP: GET /.well-known/oauth-protected-resource
        MCP-->>Agent: AS URL + scopes

        Agent->>AS: POST /register (RFC 7591)<br/>grant_types=[client_credentials]
        AS-->>Agent: client_id + client_secret (confidential client)

        Agent->>AS: POST /token<br/>client_credentials + scope
        AS-->>Agent: access_token (JWT, short TTL)

        Agent->>MCP: POST /mcp Bearer JWT
        MCP->>AS: Validate via JWKS (cached)
        MCP->>WRK: mTLS POST /scan
        WRK-->>MCP: ScanResponse
        MCP-->>Agent: 200 tool result
    end
```

---

## Gap Analysis — Current vs Ideal vs Standard

| Capability | Current | Ideal (Flow 2) | Industry Standard (Flow 3) |
|---|---|---|---|
| Client needs only MCP URL | No — needs Keycloak URL too | **Yes** | **Yes** |
| RFC 9728 resource_metadata in 401 | **Yes** (just fixed) | **Yes** | **Yes** |
| RFC 9728 discovery document | **Yes** | **Yes** | **Yes** |
| Dynamic Client Registration (RFC 7591) | No | No | **Yes** |
| Auth Code + PKCE for interactive users | No | No | **Yes** |
| Client Credentials for M2M | **Yes** | **Yes** | **Yes** |
| Refresh token lifecycle | No | No | **Yes** |
| Token revocation | No | No | **Yes** |
| mTLS between services | No (HTTP internal) | No | **Yes** |
| Short-lived tokens (< 5min) | No (300s) | No (300s) | **Yes** |
| MFA on interactive path | No | No | **Yes** |
