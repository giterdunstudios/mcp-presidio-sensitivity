---
branch: 22-sbom-cdxgen
wave: 4
items: "#22"
impl_owner: Technical Implementation Lead
validation_owner: Security / Privacy Lead
status: BLOCKED
gate: Security Lead must commit BP-001 status → "approved-for-implementation" in planning/best-practices-backlog.md before this branch starts
---

# Branch: 22-sbom-cdxgen

## Goal
Automate SBOM generation via cdxgen in `rebuild.sh` so `bom.json` is regenerated on every rebuild — eliminating the manual SBOM refresh that currently goes stale after every dependency change.

## Items covered
| # | Item |
|---|------|
| #22 | BP-001 SBOM auto-regen via cdxgen in rebuild.sh |

## GATE: Security Lead sign-off required before starting

The Security Lead must update `planning/best-practices-backlog.md` to change the BP-001 status to `approved-for-implementation`. That commit is the gate. If there are concerns about the cdxgen approach, they must be raised as a council review before the status changes.

Check before starting:
```bash
grep -A5 "BP-001\|cdxgen" planning/best-practices-backlog.md | grep "approved-for-implementation"
```

Do not open this branch if the grep returns nothing.

## Acceptance criteria
- [ ] `rebuild.sh` runs `cdxgen` after successful push to registry, before helm upgrade
- [ ] cdxgen not installed: print a warning and continue (same pattern as Trivy in #20 — optional tooling)
- [ ] Generated `bom.json` is written to the project root (same location as the current hand-maintained file)
- [ ] SBOM covers both services (full project scan, not per-service) — cdxgen supports multi-module projects
- [ ] `bom.json` includes a `serialNumber` using `cdxgen`-generated UUID (resolves backlog item #23)
- [ ] `bom.json` `version` field increments on each generation (cdxgen handles this)
- [ ] SBOM specVersion remains 1.6 (cdxgen default for recent versions; verify with `cdxgen --version`)
- [ ] `scripts/README.md` updated: add cdxgen note under rebuild.sh section
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes (cdxgen skipped in devtools container)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/rebuild.sh` | Modify | Add cdxgen invocation after push |
| `scripts/README.md` | Modify | Document SBOM auto-regen |

## Files to leave alone
`bom.json` is OVERWRITTEN by this branch (that is the point). All `src/`, `helm/`, `planning/` files other than README updates.

## Decisions that apply to this branch
- cdxgen is the SBOM generation tool selected by the Security Lead (BP-001 resolution). Do not substitute pip-licenses or other tools.
- cdxgen is optional tooling — not a project prerequisite. The build must not fail if cdxgen is absent.
- SBOM generation runs after push (not after build) because the push confirms the image was successfully produced. A stale SBOM from a failed build would be misleading.
- The generated `bom.json` replaces the hand-maintained file. The entire point of automation is that the hand-maintained file becomes the cdxgen output.
- Backlog item #23 (serialNumber generation) is automatically resolved by cdxgen — it generates a unique UUID per invocation. No separate work needed.

## How to validate

```bash
# 1. Confirm cdxgen is installed
cdxgen --version

# 2. Run rebuild — SBOM should be regenerated
./scripts/rebuild.sh mcp 2>&1 | grep -i "cdxgen\|sbom\|bom.json"

# 3. Confirm bom.json was updated
git diff bom.json | head -30

# 4. Verify serialNumber is a unique UUID (resolves #23)
python3 -c "import json; d=json.load(open('bom.json')); print(d.get('serialNumber'))"

# 5. Verify specVersion is 1.6
python3 -c "import json; d=json.load(open('bom.json')); print(d.get('specVersion'))"

# 6. Simulate cdxgen not installed
which cdxgen  # note path
sudo mv $(which cdxgen) /tmp/cdxgen-backup
./scripts/rebuild.sh mcp
echo "Exit code: $?"   # must be 0 with a warning
sudo mv /tmp/cdxgen-backup $(which cdxgen)

# 7. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- Security Lead confirms the gate commit exists before review begins
- `rebuild.sh` diff shows cdxgen invocation after push, with missing-tool guard
- `bom.json` after rebuild: specVersion 1.6, valid serialNumber UUID, components list includes both mcp_server and worker deps
- `bom.json` does NOT contain PII from source code comments — cdxgen scans package metadata only
- `branch-test.sh` passes (cdxgen skipped in devtools container)

## Notes / constraints

### cdxgen invocation pattern
```bash
sbom_regen() {
  if ! command -v cdxgen &>/dev/null; then
    log "WARNING: cdxgen not installed — skipping SBOM regeneration"
    log "         Install: npm install -g @cyclonedx/cdxgen"
    return 0
  fi
  log "Regenerating bom.json (cdxgen)..."
  cdxgen -r --spec-version 1.6 -o "$PROJECT_ROOT/bom.json" "$PROJECT_ROOT"
  log "bom.json updated"
}
```

Call after the push block completes (both images pushed, or single image pushed).

### cdxgen version and specVersion
Verify `cdxgen --version` outputs ≥9.x (the version that correctly handles Python multi-module projects). Earlier versions have known PURL issues. If version < 9, print a warning and skip rather than generating a potentially incorrect SBOM.

### Multi-module scanning
cdxgen with `-r` (recursive) scans the project tree for all supported manifests (`requirements.lock.txt` in both `src/mcp_server/` and `src/worker/`). Both services appear as components in the single `bom.json`. This is the correct structure for the project.

### Relationship to branch #4 (sbom-refresh)
Branch `4-sbom-refresh` (Wave 1) produces a hand-corrected `bom.json`. Branch `22-sbom-cdxgen` (Wave 4) automates future updates. If `4-sbom-refresh` has not yet merged when this branch starts, start from the current `bom.json` on main. If it has merged, the cdxgen output will replace the hand-corrected version — verify the cdxgen output is at least as complete as the hand-corrected version (check the PURL consistency criteria from branch #4).
