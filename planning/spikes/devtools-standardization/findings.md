---
spike: devtools-run Standardization
owner: Engineering Practices Lead
status: complete — implementation constraint added 2026-03-27
date: 2026-03-27
---

# Findings: devtools-run.sh Standardization Spike

## The Pattern

`devtools-run.sh` is a thin launcher that runs any command inside a Docker container with
a pinned toolchain: k3d v5.7.4, kubectl v1.30.0, helm v3.14.4, docker-cli, python3, curl.
It mounts the project root, the host Docker socket, and the kube config, so cluster operations
from inside the container interact with the real local cluster.

**Problem it was built to solve:** Infrastructure scripts require tools not guaranteed to be
installed on every developer machine or CI agent. `devtools-run.sh` eliminates host tool
dependencies for cluster management operations.

---

## Per-Script Audit

| Script | Host tools required | Own isolation? | Currently via devtools-run? | Suitable for devtools-run wrap? | Notes |
|--------|--------------------|---------|----|---|-----|
| `setup-local.sh` | k3d, kubectl, helm, docker | YES — `sg docker` group reapplication | No | **Yes** | Fails fast if tools missing. Would become simple wrapper call. |
| `rebuild.sh` | docker, k3d, kubectl, helm | YES — `sg docker` | No | **Yes** | Prerequisite checks + sg docker. Docker group handling not needed inside container. |
| `status.sh` | k3d (fallback to kubectl), kubectl, curl, python3 | YES — `sg docker` | No | **Yes** | k3d fallback to kubectl would simplify — container guarantees k3d present. |
| `validate-networkpolicy.sh` | kubectl, curl, python3 | No | No | **Yes** | Pure kubectl + curl. No code change needed; just wrap invocation. |
| `branch-test.sh` | bash, git, flock | No (orchestrates others) | Partially (docs reference it) | **Yes** | Meta-script; wrapping it covers all infra sub-scripts. |
| `test.sh` | docker only | YES — runs pytest inside Docker | No | **No** | Already Docker-based. Socket mount in devtools-run.sh means this works (Docker-in-Docker via socket), but adds overhead with zero isolation benefit. |
| `classify.sh` | curl, python3 | No | No | **No** | Pure HTTP + JSON. No cluster tools. Wrapper adds ~100–200ms startup cost for no benefit. |
| `auth-test.sh` | curl, python3, optionally kubectl | No | No | **No** | HTTP test matrix. No cluster tools. Same as classify.sh. |
| `demo.sh` | curl, python3, kubectl exec | No | No | **No** | Interactive: uses `read` for input pauses. `devtools-run.sh` does not allocate a TTY (`-i` only, no `-t`). Would break `pause()` function. |
| `keycloak-admin.sh` | curl, python3 | No | No | **No** | Pure HTTP admin operations. No cluster tools. No benefit to wrapping. |

---

## Option A: Do Nothing

**Current state:** devtools-run.sh exists as an opt-in tool. Scripts with hard tool requirements
(k3d, kubectl, helm) check at startup and fail fast with actionable error messages. sg docker
handling is explicit in setup-local.sh and rebuild.sh.

**What works well:**
- Scripts run fast with no Docker overhead
- Developers with tools installed have zero friction
- Easy to debug — native shell error messages, no container layer
- Self-documenting prerequisite checks (lines 48–52 of setup-local.sh)

**Ongoing pain:**
- **Real:** New developers without k3d/kubectl/helm hit tool-not-found errors on first run. They must
  either install the tools or learn devtools-run.sh is available — this is not surfaced automatically.
- **Real:** CI agents need k3d/kubectl/helm pre-installed, or the pipeline fails. devtools-run.sh would
  eliminate this entirely — only Docker required.
- **Real:** Tool version drift if a developer's host k3d version differs from the pinned container version.
  Not a frequent problem today, but grows as the project ages.
- **Theoretical:** Fork-bomb risk of each script independently checking tools — no single enforcement point.

**Verdict:** Leaving devtools-run.sh as purely opt-in means the primary benefit (reproducible toolchain)
is only realised by developers who already know to look for it.

---

## Option B: Standardize devtools-run as the Universal Launcher

Wrap all 10 scripts in devtools-run.sh. Scripts that don't need cluster tools still go through
the container.

**Pros:**
- Truly universal: `devtools-run.sh ./scripts/<anything>` always works
- CI agents need only Docker
- Tool versions guaranteed consistent across all operations
- One mental model: always use the launcher

**Cons:**
- **Docker-in-Docker for test.sh:** Wrapping test.sh (which already runs Docker containers for pytest)
  creates a nesting layer. Technically sound (socket mount approach, not privileged mode), but adds
  startup overhead and deeper error stacks with zero reproducibility benefit — the inner container is
  already isolated.
- **TTY issue for demo.sh:** demo.sh uses `read` for interactive pauses. `devtools-run.sh` passes `-i`
  but not `-t`; adding conditional `--tty` is plumbing that benefits exactly one script.
- **Latency cost:** classify.sh and auth-test.sh pay ~100–200ms Docker startup overhead per invocation.
  These are the scripts developers run most frequently during iteration. Repeated wrapping cost is felt.
- **Effort:** ~2–3 days. Modifying demo.sh for TTY, documenting exceptions, updating all invocation docs.

**Verdict:** Overhead outweighs benefit for non-infra scripts. The real friction is with k3d/kubectl/helm,
not with curl and python3.

---

## Option C: Partial Standardization — Wrap Infra-Heavy Scripts Only (Recommended)

Wrap the 5 scripts that require k3d, kubectl, or helm. Leave the remaining 5 scripts as direct invocations.

**Scripts to wrap:**
- `setup-local.sh` — k3d, kubectl, helm, docker
- `rebuild.sh` — docker, k3d, kubectl, helm
- `status.sh` — k3d/kubectl, docker
- `validate-networkpolicy.sh` — kubectl
- `branch-test.sh` — orchestrator; wrapping it covers infra sub-scripts

**Scripts to leave direct:**
- `test.sh` — already Docker-based; no cluster tools; no benefit
- `classify.sh` — no cluster tools; latency matters for interactive use
- `auth-test.sh` — no cluster tools; pure HTTP test matrix
- `demo.sh` — interactive (TTY required); no cluster tool dependency
- `keycloak-admin.sh` — no cluster tools; pure HTTP admin ops

**Pros:**
- Solves the real problem: cluster bootstrap and management work without host tool installation
- CI agents need only Docker for the full setup → test → rebuild → validate pipeline
- Fast paths stay fast: test.sh, classify.sh, auth-test.sh run natively — no Docker overhead on the iteration loop
- No Docker-in-Docker complexity; no TTY plumbing
- Clear mental model: "cluster management uses devtools-run.sh; testing and demos run direct"
- Smaller effort than Option B: ~1 day including docs

**Cons:**
- Two invocation patterns co-exist (wrapped vs direct) — documentation must make this clear
- Developers still need Docker installed (true for all three options; universally accepted)
- Developers without k3d cannot run setup-local.sh _directly_ — but this is an acceptable constraint:
  setup-local.sh is a high-barrier, one-time operation, and "use devtools-run.sh for cluster setup"
  is a clear, memorable rule

**Effort estimates:**
| Script | Change | Effort |
|--------|--------|--------|
| `setup-local.sh` | Replace tool checks with `/.dockerenv`-aware guard | S |
| `rebuild.sh` | Replace tool checks and sg docker with `/.dockerenv`-aware guard | S |
| `status.sh` | Replace sg docker with `/.dockerenv`-aware guard; simplify k3d fallback | S |
| `validate-networkpolicy.sh` | No code change; update invocation docs | XS |
| `branch-test.sh` | Update README invocation examples | XS |
| `scripts/README.md` | Add devtools-run.sh decision tree section | S |
| **Total** | | **~1 day** |

---

## Demoable Technical Milestones (Option C)

### Milestone 1: Wrap setup-local.sh
**What:** Run `./scripts/devtools-run.sh ./scripts/setup-local.sh` on a machine with no k3d, kubectl,
or helm installed.

**Test:** Remove k3d from PATH, run the wrapper. Cluster comes up. Keycloak, worker, MCP server
accessible on localhost ports. `./scripts/status.sh` (run directly, Docker not needed for that) passes.

**Why it matters:** Onboarding friction for the highest-friction operation is eliminated. New developers
with only Docker can bootstrap the full stack.

---

### Milestone 2: Wrap rebuild.sh
**What:** Run `./scripts/devtools-run.sh ./scripts/rebuild.sh` on a machine without k3d/kubectl/helm.

**Test:** Edit a source file in `src/mcp_server/`, run the wrapper. Image rebuilds, pod rolling restart
completes, `./scripts/status.sh` shows updated image SHA.

**Why it matters:** Full CI pipeline is now possible: setup (M1) → code change → rebuild (M2) → test
(direct) — all without host toolchain beyond Docker.

---

### Milestone 3: README decision tree
**What:** New section in `scripts/README.md` titled "When to use devtools-run.sh":

> **Use `devtools-run.sh` for cluster operations** (setup-local.sh, rebuild.sh, status.sh,
> validate-networkpolicy.sh, branch-test.sh). These require k3d, kubectl, and helm.
>
> **Run directly** for everything else (test.sh, classify.sh, auth-test.sh, demo.sh,
> keycloak-admin.sh). These require only Docker, curl, or python3 — available on any dev machine.

**Test:** A new contributor with only Docker installed follows the README and successfully runs the
full onboarding flow (setup → test → classify).

**Why it matters:** Documents the two-path model explicitly. Removes ambiguity about when the
wrapper is needed.

---

## Implementation Design Constraint: Parallel-Compatible Pattern

**Priority: HIGH — required design constraint, not optional polish.**

### The problem with the naive implementation

The obvious approach — removing tool checks from scripts — breaks direct invocation for
developers who already have k3d/kubectl/helm installed. It forces an immediate hard cut-over:
main branch (old direct path) and feature branch (new wrapped path) cannot coexist. You
cannot prove parity before the cut-over because there is no old path left to compare against.

### The solution: `/.dockerenv`-aware guard

Docker places a `/.dockerenv` file in every container it runs. Several scripts already use
this file to skip `sg docker` group reapplication when running inside a container. The same
detection can guard the tool check:

```bash
# At the top of setup-local.sh, rebuild.sh, status.sh (after shebang + header):
if [ ! -f /.dockerenv ] && ! command -v k3d &>/dev/null; then
  echo "k3d not found. Run via: ./scripts/devtools-run.sh $0 $@"
  exit 1
fi
```

### What this enables

| Invocation | Outcome |
|---|---|
| Direct, machine *with* k3d | Works as today — tool check passes |
| Direct, machine *without* k3d | Fails with a clear pointer to the wrapper |
| Via `devtools-run.sh` | Works — `/.dockerenv` present, tool check skipped |

- Feature branch develops the guard pattern; main branch is untouched
- Both invocation styles work simultaneously — no forced cut-over
- Parity can be validated end-to-end on the feature branch before merge
- Developers with host tools installed do not need to change their habits
- Merge = cut-over, de-risked by proven parity

### Implementation rule

**Do not remove tool checks. Replace them with the `/.dockerenv`-aware guard above.**
Any implementation that removes tool checks without the container detection gate violates
this constraint and will break the parallel development path.

---

## Recommendation

**Option C — Partial Standardization.** Wrap the 5 infra-heavy scripts. Leave the 5 direct scripts direct.

**Why not do nothing (Option A):** The onboarding and CI friction is real. setup-local.sh and rebuild.sh
are the entry points for all cluster work; they are where the "I don't have k3d" error happens. devtools-run.sh
already solves this — not pointing developers at it by default leaves the problem in place.

**Why not standardize everything (Option B):** The overhead is real and lands on the wrong scripts.
test.sh is already isolated; wrapping it adds layers without benefit. demo.sh has a real TTY
incompatibility that would require plumbing changes. classify.sh and auth-test.sh are fast, frequent,
no-cluster-tool scripts — adding 100–200ms Docker startup per call degrades the iteration experience
for no benefit.

**Option C is the right scope:** it solves the actual problem (cluster tool dependencies), keeps fast
paths fast, and adds minimal complexity (~1 day effort, clear documentation, no Docker-in-Docker).
