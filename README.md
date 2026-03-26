# MCP Presidio Sensitivity Scanner

An [MCP](https://modelcontextprotocol.io/) server that classifies text payloads
for data sensitivity using [Microsoft Presidio](https://microsoft.github.io/presidio/).
Designed for AI agent pipelines where payloads must be scanned before storage,
forwarding, or further processing.

## What it does

Send any text payload to the `classify_payload_sensitivity` MCP tool and get
back a bounded result: whether sensitive data was found, what categories
(credit card, email, SSN, etc.), a severity band, and an allow/flag/deny
decision. The payload content is never logged, stored, or returned in the
response.

```
Input:  "Call Jane Smith at 555-867-5309, email jane@example.com"

Output: {
  "sensitivity_detected": true,
  "decision": "flag",
  "max_severity_band": "MEDIUM",
  "matched_categories": ["PERSON", "PHONE_NUMBER", "EMAIL_ADDRESS"],
  "entity_summary": {"PERSON": 1, "PHONE_NUMBER": 1, "EMAIL_ADDRESS": 1},
  "confidence_summary": {"highest_score": 0.85, "findings_count": 3}
}
```

## Architecture

```
                          +-----------------+
                          |   Keycloak      |
                          |  (OAuth 2.0)    |
                          +--------+--------+
                                   |
                          JWT validation (JWKS)
                                   |
  Agent ──── POST /mcp ───> MCP Server ──── POST /scan ───> Presidio Worker
  (client)                  (FastAPI +       (internal)      (Presidio engine)
                             FastMCP)
                               |
                          Audit trail
                          OTel traces → Jaeger
                          Prometheus metrics → Grafana
```

- **MCP Server** — FastAPI application exposing one MCP tool. Handles JWT
  authentication, scope enforcement, audit logging, and RFC 9728 discovery.
- **Presidio Worker** — Internal service running the Microsoft Presidio
  analyzer engine. Not directly exposed; only reachable from the MCP server
  (enforced by NetworkPolicy).
- **Keycloak** — OAuth 2.0 authorization server. Issues short-lived JWTs
  (60s TTL) via client credentials grant.

## Security properties

- Payload content is never logged, returned in responses, or stored
- JWT authentication with scope enforcement (`tools:classify.submit`)
- Audit trail for every scan (append-only, no payload content)
- NetworkPolicy restricts worker access to MCP server pods only
- Non-root containers, no privilege escalation
- Bounded response model: no matched substrings, offsets, or excerpts

## Quick start

### Prerequisites

| Tool | Version |
|---|---|
| Docker | 29.x |
| kind | 0.23.x |
| kubectl | 1.35.x |
| helm | 3.20.x |

On WSL2 (Ubuntu), add your user to the docker group:
```bash
sudo usermod -aG docker $USER
newgrp docker
```

### Setup

```bash
cd projects/mcp-presidio-sensitivity

./scripts/setup-local.sh                   # bootstrap kind cluster + full stack
./scripts/keycloak-admin.sh set-ttl 60     # enforce 60s token TTL
./scripts/status.sh                        # confirm everything is healthy
```

### Classify a payload

```bash
./scripts/classify.sh "My SSN is 123-45-6789 and my email is john@example.com"
```

The script performs the full RFC 9728 discovery chain automatically: discovers
the auth server from the MCP server's protected resource metadata, acquires a
token, opens an MCP session, and calls the tool.

You can also pipe input:
```bash
echo "Call Jane at 555-867-5309" | ./scripts/classify.sh
cat document.txt | ./scripts/classify.sh
```

### Run the demo

```bash
./scripts/demo.sh a    # all cases: auth boundary, PII detection, enforcement
./scripts/demo.sh 1    # single case (e.g. credit card detection)
```

## Tool interface

### `classify_payload_sensitivity`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `content` | string | required | Text to classify. Never logged or returned. |
| `content_type` | string | required | MIME type (`text/plain` or `application/json`) |
| `language` | string | `"en"` | Language code for the analyzer |
| `tenant_policy` | string | `"default"` | Policy profile identifier |
| `threshold_profile` | string | `"default"` | Threshold profile identifier |
| `workflow_id` | string | null | Optional caller workflow ID for traceability |

### Response

| Field | Type | Description |
|---|---|---|
| `scan_id` | UUID | Unique scan identifier |
| `status` | string | `"completed"` |
| `sensitivity_detected` | boolean | Whether any PII entities were found |
| `max_severity_band` | string | Highest severity: `LOW`, `MEDIUM`, `HIGH`, `CRITICAL` |
| `matched_categories` | string[] | Entity types found (e.g. `PERSON`, `EMAIL_ADDRESS`) |
| `entity_summary` | object | Count per entity type |
| `decision` | string | `allow`, `flag`, or `deny` |
| `confidence_summary` | object | `highest_score` (float) and `findings_count` (int) |
| `policy_profile` | string | Policy used for the scan |
| `detector_version` | string | Presidio engine version |
| `timestamp` | string | ISO 8601 scan timestamp |

## Observability

| Service | URL | Description |
|---|---|---|
| Grafana | http://localhost:3000 | Operations dashboard (6 rows, 14 panels) |
| Prometheus | http://localhost:9090 | Metrics store |
| Jaeger | http://localhost:16686 | Distributed traces |

Both services expose `/metrics` for Prometheus scraping. The Grafana dashboard
is auto-provisioned with panels covering request rates, error rates, latency
percentiles, scan decision distribution, auth boundary metrics, Presidio
analyzer internals, and Jaeger trace visualization.

## Development

```bash
./scripts/status.sh              # start of session health check
./scripts/rebuild.sh             # after source changes (rebuilds + redeploys)
./scripts/test.sh                # run unit tests (42 tests, Docker-based)
./scripts/auth-test.sh           # auth enforcement matrix (5 cases)
./scripts/validate-networkpolicy.sh   # NetworkPolicy verification
```

See [scripts/README.md](scripts/README.md) for detailed usage of each script.

## Project structure

```
src/
  mcp_server/          # MCP server (FastAPI + FastMCP)
    auth/              # JWT middleware, token verifier, error types
    authorization/     # Scope enforcement policy
    audit/             # Append-only audit trail
    backend/           # Worker HTTP client
    tools/             # classify_payload_sensitivity handler
    observability/     # Logging, tracing, Prometheus metrics
  worker/              # Presidio worker (FastAPI)
    observability/     # Logging, tracing, Prometheus metrics
helm/                  # Helm charts (mcp-server, presidio-worker)
infrastructure/        # kind config, Keycloak, Jaeger, Prometheus, Grafana
keycloak/              # Realm import JSON
scripts/               # Dev scripts (setup, rebuild, test, demo, etc.)
planning/              # Specs, decision log, pipeline, auth flows
```
