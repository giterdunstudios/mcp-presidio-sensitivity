---
branch: 20-image-vuln-scanning
wave: 3
items: "#20"
impl_owner: Security / Privacy Lead
validation_owner: Technical Implementation Lead
status: ready
gate: #5 (lockfile sync check) must be merged before starting (rebuild.sh contention)
---

# Branch: 20-image-vuln-scanning

## Goal
Add Trivy image vulnerability scanning to `rebuild.sh` — warn on HIGH severity CVEs (exit 0), block on CRITICAL severity CVEs (exit 1). Images handling PII data must not reach the cluster with known critical vulnerabilities.

## Items covered
| # | Item |
|---|------|
| #20 | Image vulnerability scanning (Trivy/Grype in rebuild.sh) |

## GATE: Do not start until #5 (lockfile-sync-check) is merged

`rebuild.sh` contention: Wave 3 items modify rebuild.sh sequentially. #5 must merge first.

Check before starting:
```bash
git log --oneline main | grep "5-lockfile-sync-check"
```

## Acceptance criteria
- [ ] `rebuild.sh` runs `trivy image` after each `docker build`, before `docker push`
- [ ] CRITICAL CVEs: exit 1, rebuild fails with clear error listing the critical findings
- [ ] HIGH CVEs: exit 0, findings printed as warnings; rebuild continues to push + deploy
- [ ] Trivy not installed: print a warning and continue (do NOT fail the build — Trivy is optional tooling, not a project prerequisite)
- [ ] Trivy installed but DB unavailable (offline/airgap): the `--skip-db-update` flag is documented in the script header as an escape hatch; default behavior attempts DB update
- [ ] Scanning applies to whichever images were just built (mcp, worker, or both)
- [ ] `scripts/README.md` updated: add a note under `rebuild.sh` that Trivy scanning runs automatically when Trivy is installed
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/rebuild.sh` | Modify | Add Trivy scan after each docker build |
| `scripts/README.md` | Modify | Document Trivy scanning under rebuild.sh |

## Files to leave alone
All `src/` files. All `helm/` files. All other scripts. The scan is applied after build — do not modify `docker build` invocation.

## Decisions that apply to this branch

### Tool choice: Trivy
Trivy (Aquasecurity) is the industry standard for container image scanning. Grype is an alternative — both produce similar results. This branch uses Trivy. If the developer has Grype instead of Trivy, the script should be clear that Trivy is the expected tool and provide an install hint.

### Severity policy (resolved by council, 2026-03-27)
- CRITICAL: exit 1 (block). Known critical CVEs in PII-processing images are not acceptable.
- HIGH: exit 0 (warn). High severity findings are printed visibly but do not block the build. The intent is awareness, not blockage, until a clean baseline is established.
- MEDIUM/LOW: not scanned in the default invocation. Add `--severity CRITICAL,HIGH` to limit noise.

### Position in rebuild.sh
Scan runs after `docker build` (image exists locally), before `docker push` (do not push vulnerable images to the registry). Position: after the `docker_build` call, before the push block.

### Trivy as optional tooling
Trivy is NOT added to the prerequisites list in `CLAUDE.md`. The dev workflow must not break for developers who do not have Trivy installed. The check is: `if command -v trivy &>/dev/null; then scan; else warn; fi`.

## How to validate

```bash
# 1. Confirm Trivy is installed (or install it)
trivy --version

# 2. Run rebuild — should see scan output
./scripts/rebuild.sh mcp 2>&1 | grep -E "trivy|CRITICAL|HIGH|scan"

# 3. Confirm exit code is 0 (assuming no CRITICAL CVEs in current images)
./scripts/rebuild.sh mcp
echo "Exit code: $?"   # must be 0

# 4. Test warning-only behavior for HIGH findings:
#    This is a visual check — look for WARNING lines in the output

# 5. Simulate Trivy not installed (rename temporarily)
which trivy  # note path
sudo mv $(which trivy) /tmp/trivy-backup
./scripts/rebuild.sh mcp
echo "Exit code: $?"   # must be 0 with a warning about Trivy not found
sudo mv /tmp/trivy-backup $(which trivy)  # restore

# 6. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
# Note: devtools container does NOT have Trivy installed — scan will be skipped with a warning
# This is expected behavior. The branch-test.sh still passes.
```

## What the validation owner checks
- `rebuild.sh` diff shows Trivy scan block after `docker_build` calls, before push
- Trivy not installed → exit 0 with a warning (not a build failure)
- Scan block uses `--severity CRITICAL,HIGH` (not scanning all severities)
- CRITICAL exit code is 1; HIGH exit code remains 0
- `scripts/README.md` has a Trivy note under rebuild.sh
- `branch-test.sh` passes (scan skipped in devtools container)

## Notes / constraints

### Trivy invocation pattern
```bash
trivy_scan() {
  local image="$1"
  if ! command -v trivy &>/dev/null; then
    log "WARNING: trivy not installed — skipping vulnerability scan for $image"
    log "         Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
    return 0
  fi
  log "Scanning $image for vulnerabilities (CRITICAL=block, HIGH=warn)..."
  # CRITICAL check — block
  if ! trivy image --severity CRITICAL --exit-code 1 --quiet "$image"; then
    fail "CRITICAL vulnerabilities found in $image — fix before deploying. Run: trivy image $image"
  fi
  # HIGH check — warn only
  local high_count
  high_count=$(trivy image --severity HIGH --exit-code 0 --quiet --format table "$image" 2>/dev/null | grep -c HIGH || true)
  if [ "$high_count" -gt 0 ]; then
    log "WARNING: $high_count HIGH severity finding(s) in $image — review with: trivy image --severity HIGH $image"
  else
    log "$image scan clean (no CRITICAL or HIGH)"
  fi
}
```

Call `trivy_scan` immediately after each `docker_build` invocation:

```bash
if $BUILD_MCP; then
  docker_build "$MCP_IMAGE" "$PROJECT_ROOT/src/mcp_server/Dockerfile" "$PROJECT_ROOT/src/mcp_server/"
  trivy_scan "$MCP_IMAGE"
fi

if $BUILD_WORKER; then
  docker_build "$WORKER_IMAGE" "$PROJECT_ROOT/src/worker/Dockerfile" "$PROJECT_ROOT/src/worker/"
  trivy_scan "$WORKER_IMAGE"
fi
```

### devtools container and branch-test.sh
The devtools container (`infrastructure/devtools.Dockerfile`) does not have Trivy installed. `branch-test.sh` runs rebuild.sh inside the devtools container. The scan will be skipped with a warning — this is the correct fallback behaviour, not a test failure. Do not add Trivy to the devtools container in this branch (that is a separate decision).

### Trivy DB update latency
Trivy downloads its vulnerability database on first use and updates it on subsequent runs. The first scan after a cold install takes ~30s for the DB download. Subsequent scans are fast (~5s). This is acceptable for a per-build check.

### False positive baseline
Current base images are `python:3.11.15-slim` (mcp_server) and `python:3.11.15-slim` (worker). These are regularly patched by the Python Docker team. At time of writing there are no known CRITICAL CVEs in python:3.11.15-slim. If CRITICAL findings appear after this branch ships, the scan will immediately block rebuilds — this is the intended behavior.
