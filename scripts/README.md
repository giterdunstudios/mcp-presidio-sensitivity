# mcp-presidio-sensitivity — Dev Scripts

These scripts are specific to this project. They have the k3d cluster name
(`mcp-presidio`), namespace (`mcp-presidio`), Keycloak realm (`mcp-local`),
client credentials, and port mappings (`8000`, `8080`, `8090`) hardcoded.
They are not generic utilities.

Image tags are **not** hardcoded — `rebuild.sh` defaults to the short git SHA
of HEAD (`IMAGE_TAG=$(git rev-parse --short HEAD)`), producing unique per-branch
tags so parallel branch builds don't overwrite each other in the registry.
Override with `IMAGE_TAG=my-tag ./scripts/rebuild.sh`.

Each script has a detailed `When to use` block in its header.

---

## setup-local.sh
Bootstraps the mcp-presidio k3d registry and cluster from scratch.

**When:** First-time setup, after a WSL2 restart that wiped the cluster, or after
`--teardown`. NOT for routine code changes — use `rebuild.sh` instead.

After running, always follow up:
```bash
./scripts/keycloak-admin.sh set-ttl 60   # enforce DEC-002 token TTL
./scripts/status.sh                       # confirm stack healthy
```

```bash
./scripts/setup-local.sh               # full setup
./scripts/setup-local.sh --skip-build  # skip image build
./scripts/setup-local.sh --teardown    # delete the cluster
```

---

## rebuild.sh
Rebuilds one or both Docker images, pushes them to the local k3d registry
(k3d-mcp-registry:5000), and performs a rolling restart.

**When:** After any source change to `src/mcp_server/` or `src/worker/`, after a
Dockerfile change, or after merging a branch that touches application code.
Replaces the manual `docker build --no-cache` + `docker push` + `kubectl rollout
restart` + `kubectl rollout status` sequence.

```bash
./scripts/rebuild.sh              # rebuild both images (most common)
./scripts/rebuild.sh mcp          # mcp-presidio-sensitivity image only
./scripts/rebuild.sh worker       # presidio-worker image only
```

---

## status.sh
Full health and compliance check for the mcp-presidio-sensitivity stack.

**When:** Start of every dev session, after a rebuild, before running the demo, or
any time a service is behaving unexpectedly.

Checks:
- mcp-presidio k3d cluster exists
- All pods in `mcp-presidio` namespace are Running
- Keycloak, worker, and MCP server health endpoints
- Token acquisition and TTL (DEC-002: must be ≤ 60s)
- RFC 9728: `WWW-Authenticate` carries `resource_metadata`
- RFC 9728: `/.well-known/oauth-protected-resource` returns valid document

```bash
./scripts/status.sh
```

---

## keycloak-admin.sh
Admin operations against the mcp-local Keycloak realm.

**When:**
- `status` — verify realm config at session start or after a cluster rebuild
- `set-ttl 60` — apply DEC-002 after a rebuild (Keycloak may revert to 300s default)
- `discovery-check` — before any auth-related release or after editing
  `auth/errors.py` or `config.py`

```bash
./scripts/keycloak-admin.sh status
./scripts/keycloak-admin.sh set-ttl 60
./scripts/keycloak-admin.sh discovery-check
./scripts/keycloak-admin.sh token           # decode claims + DEC-002 check
./scripts/keycloak-admin.sh token --raw     # also print the raw Bearer token
```

---

## demo.sh
End-to-end demonstration covering auth boundaries, PII detection, enforcement, and
observability. Always run `status.sh` first.

**When:** Verify the full request path after a rebuild, demonstrate capabilities to
stakeholders, or validate a specific scenario.

```bash
./scripts/demo.sh        # interactive menu
./scripts/demo.sh 1      # single case (e.g. credit card detection)
./scripts/demo.sh a      # all cases in sequence — use for Phase 1 sign-off
```

Demo cases: `0` auth boundary · `t` token claims · `f` RFC 9728 discovery flow ·
`1` credit card · `2` name/email/phone · `3` SSN · `4` clean text · `5` date-only ·
`6` rich payload · `7` oversized payload · `8` bad content type · `l` lifecycle trace · `a` all

---

## classify.sh
Send a payload through the full MCP path and get the classification result.
Performs the RFC 9728 discovery chain from the MCP URL — no Keycloak URL
needed. The same path a compliant agent client would take.

**When:** Any time you want to test or verify classification of a specific
payload without writing curl commands by hand.

```bash
./scripts/classify.sh "Call Jane Smith on 555-867-5309"
./scripts/classify.sh path/to/file.txt
./scripts/classify.sh /absolute/path/to/file.txt
echo "some text" | ./scripts/classify.sh
```

Output includes a human-readable summary (decision, severity, categories,
entities, scan ID) followed by the full structured JSON response.

---

## test.sh
Run the mcp_server unit test suite inside a Docker container.

**When:** After any source change to `src/mcp_server/`, before committing, or any
time you want to verify the test suite is green. Uses `python:3.11.15-slim` with
pinned package versions — no venv or host pip install required.

The host Python is PEP 668 managed (Ubuntu), so host-level `pip install` is
blocked. Docker is the test runner.

```bash
./scripts/test.sh              # run all tests (default: -v)
./scripts/test.sh -k auth      # pass any pytest args through
./scripts/test.sh -v -x        # verbose, stop on first failure
```

---

## auth-test.sh
Auth enforcement test matrix. Runs five cases against the live MCP server and
passes/fails each one.

**When:** After any change to `auth/errors.py`, `auth/middleware.py`, or
`config.py`. Required gate before Phase 1 sign-off alongside
`validate-networkpolicy.sh`.

Cases:
- `1` No token → 401 + RFC 9728 `WWW-Authenticate`
- `2` Malformed token → 401
- `3` Valid token, wrong scope → 403
- `4` Valid token, correct scope → 200
- `5` Expired token → 401 (sets realm TTL to 2s, restores to 60s after)

```bash
./scripts/auth-test.sh
```

---

## validate-networkpolicy.sh
Validates the mcp-presidio NetworkPolicy rules against the live k3d cluster.
Deploys and cleans up a temporary busybox test pod automatically.

**When:** After any change to Helm NetworkPolicy templates, after a cluster rebuild,
or before Phase 1 exit sign-off (required gate per `planning/decision-log.md` DEC-001).

```bash
./scripts/validate-networkpolicy.sh
```

Covers cases 11–20: MCP→worker allowed, non-MCP→worker denied, MCP→Keycloak
allowed, MCP→internet denied, NetworkPolicy resource presence checks.

---

## branch-test.sh
Full branch validation suite — run before opening a PR or requesting a merge.
Designed for agent and developer use. Runs all steps sequentially and reports
a single pass/fail result.

**When:** On any branch before merge. Agents should run this via
`devtools-run.sh` so k3d/kubectl/helm are available without host installation.

**Cluster coordination:** Steps 2–5 require the shared cluster. Only one
branch should be deployed at a time. Unit tests (step 1) are isolated and
safe to run in parallel on multiple branches.

```bash
# Standard (unit + rebuild + status + auth + networkpolicy)
./scripts/devtools-run.sh ./scripts/branch-test.sh

# Full (adds demo.sh a)
./scripts/devtools-run.sh ./scripts/branch-test.sh --full
```

Steps:
1. **Unit tests** — Docker only, no cluster. Fails fast if broken.
2. **Rebuild** — builds images tagged with git SHA, deploys to cluster.
3. **Status** — full stack health check.
4. **Auth test** — 5-case enforcement matrix (includes 65s wait for case 5).
5. **NetworkPolicy** — live enforcement validation.
6. **Demo** (`--full` only) — end-to-end all cases.

---

## coupling-analysis.sh
Mines git commit history to compute co-change frequency between solution artifacts.
Outputs `planning/coupling-data.json` — the empirical coupling matrix used by the
planning agent to evaluate parallelization safety before wave construction.

**When:** After every merge to main, before a wave planning session. Run on main
only — feature branch history produces misleading pair counts.

```bash
./scripts/coupling-analysis.sh                          # regenerate JSON (default)
./scripts/coupling-analysis.sh --format table           # human-readable table
./scripts/coupling-analysis.sh --format table | grep -E "strong|moderate"
./scripts/coupling-analysis.sh --since pre-wave-work    # limit to post-tag history
./scripts/devtools-run.sh ./scripts/coupling-analysis.sh
```

See `planning/temporal-coupling-spec.md` for the full coupling tier and confidence
tier definitions, and the planning agent operating model.

---

## Typical session workflow

```bash
# 1. Start of session — confirm the stack is healthy
./scripts/status.sh

# 2. After source changes
./scripts/rebuild.sh mcp       # or worker, or both
./scripts/test.sh              # run unit tests
./scripts/status.sh

# 3. After any auth-related change
./scripts/keycloak-admin.sh discovery-check

# 4. Full validation before Phase 1 sign-off
./scripts/auth-test.sh
./scripts/validate-networkpolicy.sh
./scripts/demo.sh a

# 5. Branch validation before merge (agents: run via devtools-run.sh)
./scripts/devtools-run.sh ./scripts/branch-test.sh

# 6. Before wave planning — regenerate coupling data from merged history
./scripts/coupling-analysis.sh
```
