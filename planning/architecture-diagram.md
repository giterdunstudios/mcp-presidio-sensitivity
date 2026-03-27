# Architecture Diagram — Phase 2 (Istio/Envoy)

Shows all components and communication paths as of Phase 2 (DEC-003).
Auth enforcement, rate limiting, and RFC 9728 WWW-Authenticate header
injection are handled by the Envoy sidecar — not application code.

```mermaid
flowchart TB
    subgraph ext["External (host)"]
        Agent["Agent / Client"]
    end

    subgraph kc_ns["mcp-presidio namespace"]
        KC["Keycloak :8080\nAuthorization Server\nmcp-local realm"]

        subgraph mcp_pod["MCP Server Pod"]
            MCP_ENV["Envoy Sidecar\n─────────────\nJWT authn (RequestAuthentication)\nScope enforcement (AuthorizationPolicy)\nRate limit — 60 req/min (EnvoyFilter)\nWWW-Authenticate injection (EnvoyFilter Lua)"]
            MCP_APP["MCP Server App\n─────────────\nclassify_payload_sensitivity\naudit trail\n/health  /metrics\n/.well-known/oauth-protected-resource"]
        end

        subgraph wrk_pod["Presidio Worker Pod"]
            WRK_ENV["Envoy Sidecar"]
            WRK_APP["Worker App\n─────────────\nPresidio analyzer\n/scan  /health  /metrics"]
        end

        JAEGER["Jaeger :16686"]
        PROM["Prometheus :9090"]
        GRAFANA["Grafana :3000"]
    end

    subgraph istio_sys["istio-system namespace"]
        ISTIOD["istiod\nxDS config · cert signing"]
    end

    %% ── Token acquisition ──────────────────────────────────────────
    Agent -- "POST /token  client_credentials" --> KC
    KC -- "JWT  TTL 60s" --> Agent

    %% ── Request path ───────────────────────────────────────────────
    Agent -- "POST /mcp  Bearer JWT\n(host port 8000)" --> MCP_ENV
    MCP_ENV -- "validated request\nx-jwt-subject header added" --> MCP_APP
    MCP_APP -- "POST /scan  plain HTTP\n(cluster-internal, NetworkPolicy: MCP label only)" --> WRK_ENV
    WRK_ENV --> WRK_APP
    WRK_APP -- "ScanResponse (no payload)" --> MCP_APP
    MCP_APP -- "tool result" --> Agent

    %% ── Istio control plane ────────────────────────────────────────
    ISTIOD -- "xDS config  :15012" --> MCP_ENV
    ISTIOD -- "xDS config  :15012" --> WRK_ENV
    ISTIOD -- "JWKS fetch\n(cluster-internal :8080)" --> KC

    %% ── Observability ──────────────────────────────────────────────
    MCP_APP -- "OTLP traces" --> JAEGER
    WRK_APP -- "OTLP traces" --> JAEGER
    PROM -- "scrape /metrics  :8000" --> MCP_APP
    PROM -- "scrape /metrics\n(kubectl exec — NetworkPolicy blocks direct)" --> WRK_APP
    GRAFANA -- "query" --> PROM
    GRAFANA -- "query" --> JAEGER
```

## Key boundaries

| Boundary | Rule |
|---|---|
| Worker ingress | NetworkPolicy: allow from MCP server pod label only — no direct external access |
| MCP server egress | NetworkPolicy: worker + Keycloak + istiod + DNS only — no internet |
| istiod → Keycloak | Uses cluster-internal URL (`keycloak.mcp-presidio.svc.cluster.local`) not `localhost:8080` |
| Prometheus → Worker | Cannot scrape directly (NetworkPolicy); uses `kubectl exec` — Phase 3 fix needed |
| EnvoyFilter CRDs | Accepted for Phase 2 only; replace before Phase 3 (see DEC-005) |
