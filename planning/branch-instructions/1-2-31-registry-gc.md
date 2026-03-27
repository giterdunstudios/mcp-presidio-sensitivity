---
branch: 1-2-31-registry-gc
wave: 2
items: "#1, #2, #31"
impl_owner: Engineering Practices Lead
validation_owner: Technical Implementation Lead
status: ready
---

# Branch: 1-2-31-registry-gc

## Goal
Add a registry garbage-collection script, document the registry management process in `scripts/README.md`, and fix any stale content in `scripts/README.md` that no longer matches current behaviour.

## Items covered
| # | Item |
|---|------|
| #1 | Registry GC script (`scripts/registry-gc.sh`) |
| #2 | Registry process documentation in `scripts/README.md` |
| #31 | `scripts/README.md` accuracy review and corrections |

## Acceptance criteria

### Item #1 — Registry GC script
- [ ] New file `scripts/registry-gc.sh` created and marked executable (`chmod +x`)
- [ ] Script connects to the k3d local registry and removes untagged/dangling layers using the registry garbage-collect command
- [ ] Script lists registry images before and after with counts (or total size)
- [ ] `--dry-run` flag: shows what the garbage-collect operation would do without executing it
- [ ] Script is safe to run while the cluster is live
- [ ] Script has a `When to use` header comment block consistent with other scripts in `scripts/`

### Item #2 — Registry process documentation
- [ ] `scripts/README.md` has a new "Registry management" section covering:
  - When to run GC (after merging branches, before long sessions)
  - How to check registry disk usage
  - How image tags accumulate (one per git SHA per `rebuild.sh` run)
  - Auth: local registry has no auth (note as known gap)
- [ ] `registry-gc.sh` entry added to the README with when-to-use guidance

### Item #31 — README accuracy review
- [ ] `scripts/README.md` read end-to-end; stale content corrected
- [ ] `branch-test.sh` entry is present and accurate
- [ ] `devtools-run.sh` entry is present and accurate
- [ ] `rebuild.sh` docs reflect SHA-based image tags (not fixed tags)
- [ ] Any references to `kind load docker-image` removed (k3d migration complete)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/registry-gc.sh` | Create | New executable script |
| `scripts/README.md` | Modify | Add registry section + accuracy fixes |

## Files to leave alone
`scripts/rebuild.sh`, `scripts/test.sh`, `scripts/setup-local.sh`, `scripts/branch-test.sh`, `scripts/auth-test.sh`, `scripts/demo.sh`, `scripts/classify.sh`, `scripts/status.sh`, `scripts/keycloak-admin.sh` — these scripts are not in scope for this branch. All `src/`, `helm/` files.

## Decisions that apply to this branch
- DEC-004: k3d is the cluster platform. The registry container is named `k3d-mcp-registry`. Push from host uses `localhost:5000`; cluster-internal address is `k3d-mcp-registry:5000`. These are two names for the same registry.
- DEC-004 Wave 3 finding: `scripts/devtools-run.sh` is established for toolchain isolation. Scripts that need k3d/kubectl/helm should document using `devtools-run.sh` as an alternative when those tools are not on the host.
- Image tags are git SHA-based (`git rev-parse --short HEAD`). Each `rebuild.sh` run produces a new tag, accumulating in the registry. GC is needed to manage this growth.

## How to validate

```bash
# 1. Test registry-gc.sh --dry-run (safe — no changes)
./scripts/registry-gc.sh --dry-run

# 2. Test registry-gc.sh (live run — check before and after output)
./scripts/registry-gc.sh

# 3. Run branch-test.sh to confirm nothing broken
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

The `--dry-run` test must complete without error even if the registry has no dangling layers to collect. Verify the "before" and "after" counts are printed in both modes.

## What the validation owner checks
- `scripts/registry-gc.sh` exists and is executable (`ls -la scripts/registry-gc.sh`)
- `--dry-run` flag works and does not modify the registry
- Live run completes without error on a running cluster
- `scripts/README.md` registry section is present with all four required items
- README accuracy: `branch-test.sh` and `devtools-run.sh` entries are present and correct
- No `kind load docker-image` references remain in the README
- `branch-test.sh` passes

## Notes / constraints

### Registry GC implementation
The k3d registry runs the standard Docker Distribution registry server. Garbage collection is performed using the registry binary inside the container:

```bash
docker exec k3d-mcp-registry registry garbage-collect \
  /etc/docker/registry/config.yml
```

For `--dry-run`:
```bash
docker exec k3d-mcp-registry registry garbage-collect \
  --dry-run /etc/docker/registry/config.yml
```

The registry must be running for this to work. Check with `docker ps --filter name=k3d-mcp-registry` before running.

Image listing before/after can use the Docker Registry HTTP API v2:
```bash
# List repositories
curl -s http://localhost:5000/v2/_catalog

# List tags for a repository
curl -s http://localhost:5000/v2/mcp-presidio-sensitivity/tags/list
```

### Disk usage check
```bash
docker exec k3d-mcp-registry du -sh /var/lib/registry
```

### No auth on local registry
The local registry has no authentication. This is acceptable for a local dev registry but must be noted as a gap. Do not add auth on this branch — that is a separate item (#21 if scheduled).
