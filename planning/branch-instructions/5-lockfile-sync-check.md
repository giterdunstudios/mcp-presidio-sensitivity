---
branch: 5-lockfile-sync-check
wave: 3
items: "#5"
impl_owner: Technical Implementation Lead
validation_owner: Engineering Practices Lead
status: ready
gate: Wave 2 must be fully merged before starting (rebuild.sh contention)
---

# Branch: 5-lockfile-sync-check

## Goal
Add a lock file sync check to `rebuild.sh` that fails the build if `requirements.lock.txt` is out of sync with `requirements.txt` — preventing the silent deployment of wrong dependency versions.

## Items covered
| # | Item |
|---|------|
| #5 | requirements.lock.txt sync check in rebuild.sh |

## GATE: Do not start until Wave 2 is fully merged

Wave 2 branches that touch `rebuild.sh`:
- `6-credential-gate` — adds `check-credentials.sh` call to rebuild.sh

Check before starting:
```bash
git log --oneline main | head -20  # confirm 6-credential-gate is in main
```

## Acceptance criteria
- [ ] `rebuild.sh` calls `check_lockfile_sync` for each service being rebuilt (mcp, worker, or both)
- [ ] Check runs inside Docker (`python:3.11.15-slim`) — no host pip required (host pip is PEP 668 blocked)
- [ ] Check executes `pip-compile --check --no-header --strip-extras -o requirements.lock.txt requirements.txt` inside the container
- [ ] Stale lock file: rebuild fails with an informative error message that includes the exact regeneration command from `CLAUDE.md`
- [ ] In-sync lock file: check passes silently (one log line only)
- [ ] Check is positioned after prerequisites check and credential scan, before the first `docker build` call
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes (lock files are currently in sync)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/rebuild.sh` | Modify | Add lock file sync check before docker build |

## Files to leave alone
All `src/` files. All `helm/` files. `scripts/setup-local.sh`, `scripts/test.sh`, `scripts/status.sh`, `scripts/demo.sh`, `scripts/auth-test.sh`, `scripts/validate-networkpolicy.sh`, `scripts/branch-test.sh`, `scripts/check-credentials.sh`. Do not modify `requirements.txt` or `requirements.lock.txt`.

## Decisions that apply to this branch
- The check runs inside Docker using the same image as `test.sh` (`python:3.11.15-slim`). The host cannot run `pip-compile` directly (PEP 668 managed environment).
- The check is **blocking** (exits 1 on stale lock). A stale lock file means the running image may have different package versions than what `requirements.txt` specifies — a silent correctness and security risk.
- `pip-compile --check` exits 0 if the output would be identical to the existing lock file, 1 if it would differ. Available in pip-tools ≥7.3.0.
- The check runs only for the service(s) being rebuilt — if only `mcp` is passed, only the MCP lock file is checked; if only `worker`, only the worker.
- The check mounts only the service directory (`src/mcp_server/` or `src/worker/`) — no full project mount needed.

## How to validate

```bash
# 1. Confirm lock files are currently in sync (should pass)
./scripts/rebuild.sh mcp
echo "Exit code: $?"   # must be 0

# 2. Simulate a stale lock file
echo "# stale-marker" >> src/mcp_server/requirements.lock.txt

# 3. Confirm check catches it
./scripts/rebuild.sh mcp
echo "Exit code: $?"   # must be 1 with informative error

# 4. Restore lock file
git checkout src/mcp_server/requirements.lock.txt

# 5. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- `rebuild.sh` diff shows the sync check function and two call sites (mcp and worker guards)
- Check is positioned before the first `docker_build` call
- Stale lock file test (step 2–3 above) exits 1 with regeneration command in error message
- In-sync run exits 0 with a single log line
- `branch-test.sh` passes end-to-end
- Error message includes the exact `docker run ... pip-compile` command from `CLAUDE.md`

## Notes / constraints

### Where to insert in rebuild.sh
Find the block after prerequisites check and credential scan (currently after `"$SCRIPT_DIR/check-credentials.sh"`), before the `docker_build()` function body is invoked. Insert a `check_lockfile_sync` function definition and call it:

```bash
# ---------------------------------------------------------------------------
# Lock file sync check — fail fast if requirements.lock.txt is stale
# ---------------------------------------------------------------------------

check_lockfile_sync() {
  local svc="$1" workdir="$2"
  log "Checking $svc requirements.lock.txt sync..."
  if ! docker run --rm -v "$workdir:/work" python:3.11.15-slim \
       sh -c 'pip install -q pip-tools && cd /work && pip-compile --check \
              --no-header --strip-extras -o requirements.lock.txt requirements.txt' \
       >/dev/null 2>&1; then
    fail "$svc requirements.lock.txt is out of sync with requirements.txt.
Regenerate with:
  docker run --rm -v \$(pwd)/${workdir##*/src/}:/work python:3.11.15-slim \\
    sh -c 'pip install -q pip-tools && cd /work && pip-compile --no-header \\
           --strip-extras -o requirements.lock.txt requirements.txt'"
  fi
  log "$svc lock file in sync"
}

if $BUILD_MCP; then
  check_lockfile_sync "mcp_server" "$PROJECT_ROOT/src/mcp_server"
fi
if $BUILD_WORKER; then
  check_lockfile_sync "worker" "$PROJECT_ROOT/src/worker"
fi
```

The `docker run` invocation is modelled after the regeneration commands in `CLAUDE.md`. The `pip-compile --check` flag exits 0 if the lock file is up to date, 1 otherwise.

### pip-compile --check availability
`pip-compile --check` was added in pip-tools 7.3.0 (released 2023). Installing pip-tools inside the Docker container gets the latest version. If for any reason the flag is unavailable, an alternative is to run pip-compile into a temp file and diff with the existing lock file.

### Timing
The Docker pull of `python:3.11.15-slim` adds ~2s overhead if the image is cached, ~30s on cold pull. On a developer machine with the image cached, this is negligible. On first run after a machine reset, it will pull the image — this is acceptable.
