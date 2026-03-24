# Lane D — Open Clarifications
**For:** Coordinator / operator review before Lane D starts
**Status:** Resolved — decisions recorded below. C-4 and C-5 delegated to Lane D agent.

These questions arose from reviewing the Group 1 outputs against the auth spec and MVP spec.
None are blockers on briefing preparation, but all must be resolved before the agent starts building.

---

## C-1 — MCP server port ✅ RESOLVED

**Question:** What port should the MCP server expose on localhost?

**Context:**
The kind cluster was created with three fixed port mappings (4444, 4445, 8080).
The MCP server needs a fourth. The kind config at `infrastructure/kind-config.yaml`
and the setup script at `scripts/setup-local.sh` both need updating.

**Suggested options:**
- Port `3000` — common convention for app servers
- Port `8000` — common FastAPI default
- Port `9000` — avoids any conflict with the worker on 8080

**Decision:** Port `8000`. NodePort `30800`. kind-config.yaml and setup-local.sh updated.

---

## C-2 — MCP SDK vs plain FastAPI ✅ RESOLVED

**Question:** Should the MCP server use the official MCP Python SDK (`mcp` package)
or be built as a plain FastAPI server that exposes an MCP-compatible HTTP interface?

**Context:**
The auth spec and MVP spec describe an HTTP-based MCP server but do not mandate a
specific SDK. Two approaches are possible:

**Option A — MCP Python SDK**
- Uses `mcp` package from PyPI (Anthropic's official SDK)
- Handles MCP protocol framing, tool registration, and message serialization
- The right long-term approach if agents will discover and invoke this via a standard MCP client
- Adds a dependency on the MCP SDK; requires understanding its HTTP transport model (SSE or Streamable HTTP)

**Option B — Plain FastAPI**
- Exposes `POST /tools/classify_payload_sensitivity` as a plain JSON endpoint
- Simpler to build, no MCP-specific protocol framing
- Callers would invoke it as a plain HTTP API, not through MCP tool discovery
- Faster to prove the auth + worker proxy flow in Phase 0
- Can be migrated to the MCP SDK in Phase 1 without changing the auth or backend layers

**Decision:** Use the MCP Python SDK (`mcp` / `fastmcp`). Briefing updated accordingly.

---

## C-3 — Health endpoint auth requirement ✅ RESOLVED

**Question:** Should `GET /health` require a token?

**Context:**
The Kubernetes liveness and readiness probes call `/health` from inside the cluster
without a token. If `/health` requires auth, the probes will fail.

Standard practice is to leave `/health` unauthenticated for cluster-internal use.
The auth spec does list `tools:health.read` as a scope, which implies it could be
token-protected for external callers.

**Options:**
- No auth on `/health` — simplest, probe-compatible (recommended for Phase 0)
- Auth on `/health` with scope `tools:health.read` — matches auth spec but requires
  probes to use a service account token or be configured differently

**Decision:** No auth on `/health`. Probe-compatible. Documented deviation from auth spec scope model.

---

## C-4 — DATE_TIME false positive — action in Phase 0 or Phase 1? ✅ RESOLVED

**Question:** Should the DATE_TIME → direct_identifier → high severity mapping be
adjusted before Lane D ships, or accepted as a known issue for Phase 1?

**Context:**
Observed in Phase 0 demo testing: benign date references ("next month", "quarterly")
trigger a `high` severity `block` decision because `DATE_TIME` is mapped to
`direct_identifier` which always escalates to `high`.

This means the MCP server will return `block` for text like:
> "The quarterly report shows 14% growth."

This is logged in the decision log as Decision 19, but no code change has been made.

**Options:**
- Accept for Phase 0 — document and defer calibration to Phase 1 (recommended)
- Fix now — move `DATE_TIME` out of `direct_identifier` or add context-gating logic

**Decision:** Accept for Phase 0. Deferred to Phase 1 calibration. Lane D test payloads must avoid date-containing text when testing `allow` paths. See Decision 19 in task_plan.md.

---

## C-5 — Scope claim name: `scp` vs `scope` — DELEGATED TO LANE D

**Question (confirmation needed):** Has it been confirmed that Hydra issues `scp`
(array) rather than `scope` (string) in the JWT payload?

**Context:**
The token validation report shows the decoded JWT claims with `"scp": ["tools:classify.submit"]`.
This is Hydra's non-standard claim name. The standard RFC 9068 JWT access token
profile uses `scope` as a space-separated string.

The Lane D token verifier must read `scp` to extract scopes. If this is wrong, all
scope checks will silently fail — the token will appear valid but have no scopes.

**Decision:** Lane D agent to confirm the claim name by decoding a live token at startup. Use this command to inspect:
```bash
curl -s -X POST http://localhost:4444/oauth2/token \
  -d "grant_type=client_credentials&client_id=test-agent-client&client_secret=test-agent-secret-change-in-prod&scope=tools:classify.submit&audience=mcp-presidio-server" \
  | python3 -c "
import sys, base64, json
token = json.load(sys.stdin)['access_token']
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2))
"
```
Confirm which claim name contains the scopes. The token verifier must handle both `scp` (Hydra's non-standard name) and `scope` (RFC standard) defensively. Log the confirmed claim name as a decision in your completion summary.

---

## C-6 — Worker NodePort exposure in local dev ✅ RESOLVED

**Question:** Should the Presidio worker's NodePort (localhost:8080) remain
accessible directly in local dev, or should it be locked down so all traffic
must go through the MCP server?

**Context:**
Currently the worker is reachable directly at `localhost:8080` via NodePort.
This is intentional for demo and testing purposes (demo.sh hits it directly).
Once the MCP server is in front, the "correct" path for all scans is through
the MCP server.

**Options:**
- Leave as-is — worker NodePort stays open for demos and direct testing
- Remove worker NodePort from kind config — all traffic must go via MCP server
  (demo.sh and setup-local.sh would need updating)

**Decision:** Leave worker NodePort accessible. Demo and direct testing continue to work on localhost:8080. Production ClusterIP enforces isolation.
