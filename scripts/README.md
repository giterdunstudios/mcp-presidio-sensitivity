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

**Vulnerability scanning:** If [Trivy](https://aquasecurity.github.io/trivy/latest/getting-started/installation/)
is installed on the host, `rebuild.sh` automatically scans each image after
`docker build`, before `docker push`. CRITICAL CVEs block the build (exit 1).
HIGH CVEs print a warning and the build continues. If Trivy is not installed,
a warning is printed and the build proceeds normally — Trivy is optional tooling,
not a prerequisite. To skip the DB update in an offline/airgap environment:
`TRIVY_SKIP_DB_UPDATE=1 ./scripts/rebuild.sh`.

---

## check-credentials.sh
Scans local config files for known default/hardcoded credentials and prints
findings with `file:line` references.

**When:**
- Automatically called by `rebuild.sh` before every build (non-blocking — warns but does not stop the build)
- Run manually with `--strict` before opening a PR that touches Helm values files
- Run with `--strict` in CI pipelines that validate production values files

Scans:
- `helm/mcp-server/values.local.yaml`
- `helm/presidio-worker/values.local.yaml`
- `keycloak/` directory
- `infrastructure/keycloak-local.yaml`
- `helm/keycloak-values.local.yaml` (if present)

```bash
./scripts/check-credentials.sh           # warn only, always exits 0
./scripts/check-credentials.sh --strict  # exits 1 if any findings found
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

## rfc9728-test.sh
RFC 9728 discovery chain integration test. Walks all 6 steps of the
"client needs only MCP server URL" path (Flow 2 in
`planning/auth-flows-diagram.md`) with labelled pass/fail output per step.
Different from `auth-test.sh` — this tests discovery, not enforcement.

**When:** After any change to the RFC 9728 discovery endpoint
(`/.well-known/oauth-protected-resource`), after any change to auth error
responses (`auth/errors.py`), or after an Istio upgrade that could affect
WWW-Authenticate header injection.

**Note:** Steps 1-2 (unauthenticated request returns 401/403 + WWW-Authenticate)
require Istio to be deployed (Phase 2, BP-029). In the current environment
these steps will FAIL — this is expected and intentional, not a test defect.
Steps 3-6 run in all environments and test the discovery document chain
and token acquisition independently.

```bash
./scripts/rfc9728-test.sh
```

Steps:
- `1` Unauthenticated POST → 401/403 + WWW-Authenticate header (fails pre-Istio)
- `2` resource_metadata URL extracted from WWW-Authenticate (fails pre-Istio)
- `3` GET resource_metadata URL → 200 + authorization_servers + scopes_supported
- `4` GET AS /.well-known/openid-configuration → 200 + token_endpoint + issuer
- `5` POST token_endpoint (client credentials) → 200 + access_token
- `6` POST /mcp with discovered token → 200

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

## devtools-run.sh
Runs any script or command inside the pinned devtools container, which provides
k3d, kubectl, helm, and docker CLI without requiring host installation. All tools
are pinned to the same versions used in development.

**When:** Any time k3d, kubectl, or helm are not available on the host PATH, or
when you want a fully reproducible toolchain environment. Required wrapper for
`branch-test.sh` and `coupling-analysis.sh` when those tools are not on the host.

```bash
./scripts/devtools-run.sh ./scripts/setup-local.sh
./scripts/devtools-run.sh ./scripts/branch-test.sh
./scripts/devtools-run.sh ./scripts/branch-test.sh --full
./scripts/devtools-run.sh kubectl get pods -n mcp-presidio
./scripts/devtools-run.sh helm list -n mcp-presidio
./scripts/devtools-run.sh k3d cluster list
```

The devtools image (`mcp-presidio-devtools:latest`) is built automatically on first
run from `infrastructure/devtools.Dockerfile`. To rebuild after a Dockerfile change:
`docker rmi mcp-presidio-devtools:latest` then run any `devtools-run.sh` command.

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

## registry-gc.sh
Runs garbage collection on the local k3d registry (`k3d-mcp-registry`) to reclaim
disk space occupied by unreferenced image layers.

**When:**
- `docker exec k3d-mcp-registry du -sh /var/lib/registry` reports > ~5GB
- After 10 or more `rebuild.sh` runs on an active branch (each run pushes a new
  SHA-tagged image; old layers accumulate until GC runs)
- Before a WSL2 session where disk headroom is tight

GC is a **manual developer responsibility** — it is not automated, to avoid
interrupting concurrent builds (see safety note in the script header).

```bash
./scripts/registry-gc.sh               # live GC — removes dangling layers
./scripts/registry-gc.sh --dry-run     # show what would be removed; no changes made
./scripts/registry-gc.sh --prune-old-tags  # also delete old SHA-tagged manifests
```

**Safety:** Default GC (no flags) is safe when no `rebuild.sh` is running concurrently.
`--prune-old-tags` is destructive — requires operator confirmation that all running
pods reference the current SHA before proceeding (see warning in the script).

---

## Registry management

The local k3d registry (`k3d-mcp-registry`, push address `localhost:5000`) stores
all images built by `rebuild.sh`. It has **no authentication** — this is acceptable
for a local dev registry but is a known gap tracked as issue #21.

### How tags accumulate

Each `rebuild.sh` run tags the built image with the short git SHA of HEAD
(`git rev-parse --short HEAD`). On an active branch with 10+ rebuilds, the registry
accumulates 10+ tags per image name. Default GC removes unreferenced blob layers but
does NOT remove old SHA-tagged manifests — those are still "tagged" as far as the
registry is concerned. The `--prune-old-tags` flag is required to reclaim that space.

### When to run GC

Check registry disk usage:
```bash
docker exec k3d-mcp-registry du -sh /var/lib/registry
```

Run GC when:
- Usage exceeds ~5GB, or
- After 10 or more `rebuild.sh` runs on an active branch

### GC is a manual developer responsibility

GC is not automated. The sweep phase can delete blobs referenced by an in-flight
`docker push` before its manifest is stored. Always ensure no `rebuild.sh` is
running before executing GC.

```bash
./scripts/registry-gc.sh --dry-run   # inspect what would be removed first
./scripts/registry-gc.sh             # remove dangling layers (safe, preserves SHA tags)
./scripts/registry-gc.sh --prune-old-tags  # also remove old SHA manifests (see warning)
```

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
