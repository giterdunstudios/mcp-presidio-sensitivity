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

## Prerequisites — New Machine Setup

### Required host tools (pinned versions used in development)

| Tool | Version | Install |
|---|---|---|
| Docker | 29.3.0 | https://docs.docker.com/engine/install/ |
| kind | 0.23.0 | `go install sigs.k8s.io/kind@v0.23.0` or https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| kubectl | 1.35.3 | https://kubernetes.io/docs/tasks/tools/ |
| helm | 3.20.1 | https://helm.sh/docs/intro/install/ |

Newer patch versions of the same minor are generally fine. Avoid mixing major
versions (e.g. helm 2.x vs 3.x).

### WSL2 specifics (Ubuntu)

```bash
# Add your user to the docker group — required for kind and docker commands
sudo usermod -aG docker $USER
newgrp docker        # apply without logout (interactive shells only)

# setup-local.sh uses 'sg docker -c ...' to handle the WSL2 case where
# newgrp doesn't propagate to non-interactive subshells. No extra steps needed
# beyond adding yourself to the docker group above.
```

### First-time setup

```bash
git clone <repo>
cd projects/mcp-presidio-sensitivity

./scripts/setup-local.sh           # bootstraps kind cluster, Keycloak, worker, MCP server
./scripts/keycloak-admin.sh set-ttl 60   # enforce DEC-002 token TTL
./scripts/status.sh                # confirm everything is healthy
```

### Dependency lock file update procedure

Both services use `requirements.lock.txt` as the authoritative pip install source
(not `requirements.txt`, which is constraints-only). When you add or update a
package in `requirements.txt`, regenerate the lock file:

```bash
# For mcp_server:
docker run --rm -v $(pwd)/src/mcp_server:/work python:3.11.15-slim \
  sh -c 'pip install -q pip-tools && cd /work && pip-compile --no-header \
         --strip-extras -o requirements.lock.txt requirements.txt'

# For worker:
docker run --rm -v $(pwd)/src/worker:/work python:3.11.15-slim \
  sh -c 'pip install -q pip-tools && cd /work && pip-compile --no-header \
         --strip-extras -o requirements.lock.txt requirements.txt'
```

After regenerating, rebuild both images and run `./scripts/test.sh` to confirm
nothing broke.

## Dev Scripts
All operational scripts for this project are in `scripts/`. See `scripts/README.md`
for when to use each one.

Quick reference:
- **Start of session:** `./scripts/status.sh`
- **After source changes:** `./scripts/rebuild.sh [mcp|worker]`
- **Run tests:** `./scripts/test.sh`
- **To classify a payload:** `./scripts/classify.sh "your text here"`
- **After auth changes:** `./scripts/keycloak-admin.sh discovery-check` then `./scripts/auth-test.sh`
- **Before sign-off:** `./scripts/auth-test.sh` then `./scripts/validate-networkpolicy.sh` then `./scripts/demo.sh a`

@scripts/README.md

## Key Decisions
Architectural decisions with rationale are in `planning/decision-log.md`.
- DEC-001: Internal network trust boundary — mTLS deferred post-Phase 1
- DEC-002: Token TTL reduced to 60s (from Keycloak default 300s)

@planning/decision-log.md

## Planning Documents
@planning/auth-flows.md
@planning/pipeline.md
