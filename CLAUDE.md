# mcp-presidio-sensitivity

## Project Overview
MCP server that classifies text payloads for data sensitivity using Microsoft
Presidio. Exposes a single MCP tool (`classify_payload_sensitivity`) behind JWT
authentication (Keycloak, OAuth 2.0 client credentials). Returns bounded scan
results — never payload content. Deployed to a local kind cluster for development.

Key components:
- `src/mcp_server/` — FastAPI + FastMCP server, JWT middleware, audit trail
- `src/worker/` — Presidio analyzer worker (internal, not directly exposed)
- `helm/` — Helm charts for both services
- `keycloak/` — Realm import for local Keycloak instance
- `infrastructure/` — kind cluster config, Keycloak deployment manifest
- `scripts/` — All dev scripts (see below)
- `planning/` — Specs, decision log, auth flow diagrams, pipeline diagram

## Dev Scripts
All operational scripts for this project are in `scripts/`. See `scripts/README.md`
for when to use each one.

Quick reference:
- **Start of session:** `./scripts/status.sh`
- **After source changes:** `./scripts/rebuild.sh [mcp|worker]`
- **After auth changes:** `./scripts/keycloak-admin.sh discovery-check`
- **Before sign-off:** `./scripts/validate-networkpolicy.sh` then `./scripts/demo.sh a`

@scripts/README.md

## Key Decisions
Architectural decisions with rationale are in `planning/decision-log.md`.
- DEC-001: Internal network trust boundary — mTLS deferred post-Phase 1
- DEC-002: Token TTL reduced to 60s (from Keycloak default 300s)

@planning/decision-log.md

## Planning Documents
@planning/auth-flows.md
@planning/pipeline.md
