---
branch: 21-registry-auth-gap
wave: 4
items: "#21"
impl_owner: Engineering Practices Lead
validation_owner: Security / Privacy Lead
status: ready
---

# Branch: 21-registry-auth-gap

## Goal
Document the unauthenticated k3d registry as a known, deliberate local-dev gap — not an oversight. Add an entry to `planning/dev-prod-parity.md` and a comment in the relevant script so the next developer doesn't silently inherit a misunderstanding.

## Items covered
| # | Item |
|---|------|
| #21 | Registry authentication gap — document as known gap |

## Acceptance criteria
- [ ] `planning/dev-prod-parity.md` contains an entry for the registry auth gap under a "Security" or "Auth" section
- [ ] Entry states: what the gap is, why it is accepted for local dev, and what production must have
- [ ] `scripts/setup-local.sh` has a comment near the `k3d registry create` call noting that the registry is unauthenticated by design (local dev only)
- [ ] No code changes — documentation only
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes (documentation branch — no code changes)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `planning/dev-prod-parity.md` | Modify | Add registry auth gap entry |
| `scripts/setup-local.sh` | Modify | Add comment near k3d registry create |

## Files to leave alone
All `src/` files. All `helm/` files. All scripts except `setup-local.sh`. All `infrastructure/` files. Do not add any authentication to the registry — this is documentation only.

## Decisions that apply to this branch
- The `k3d-mcp-registry` registry is intentionally unauthenticated for the local dev workflow. k3d's built-in registry does not support authentication out of the box without additional configuration.
- The gap is documented, not fixed. Fixing registry auth is Phase 3+ work (requires credential management, Kubernetes image pull secrets, and possibly a different registry solution).
- The parity document (`planning/dev-prod-parity.md`) is the canonical home for gaps of this type. If the file does not yet exist, create it with the format below.

## How to validate

```bash
# 1. Confirm the parity document exists and has the entry
cat planning/dev-prod-parity.md | grep -A10 "registry"

# 2. Confirm setup-local.sh has the comment
grep -n "unauthenticated\|registry.*auth\|auth.*registry" scripts/setup-local.sh

# 3. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- `planning/dev-prod-parity.md` entry clearly states: (1) gap, (2) local dev justification, (3) production requirement
- Comment in `setup-local.sh` is next to the registry creation line — not in a general notes section
- No code logic was modified — diff shows only comments and documentation
- Security Lead confirms the documented production requirement is accurate

## Notes / constraints

### dev-prod-parity.md format
If `planning/dev-prod-parity.md` does not exist, create it. If it does exist (branch `11-parity-delta` may have created it), add to the existing file. The entry format should be consistent with branch #11's structure.

If creating the file from scratch, use this structure:
```markdown
# Dev/Prod Parity Delta

Documents known differences between the local dev stack and a production deployment.
Each gap is deliberate and documented — not an oversight.

---

## Summary table

| # | Component | Gap | Local behavior | Production requirement | Priority |
|---|-----------|-----|----------------|----------------------|----------|
| P1 | Registry | No authentication | k3d registry accepts unauthenticated push from any process on the host | Registry requires authentication; image pull secrets configured in cluster | Medium |
| ... | ... | ... | ... | ... | ... |

---

## Detail

### P1 — Registry: No authentication
...
```

### Why this is a known gap and not a bug
The `k3d-mcp-registry` registry is a local tool for fast developer iteration. It is not reachable from outside the Docker network (the port 5000 is bound to localhost). The security boundary is the host machine, not the registry. A production registry (GCR, ECR, GHCR, Harbor) requires authentication and scanning — this is a Phase 3+ concern.

### Relationship to branch #11
Branch `11-parity-delta` may already have created `planning/dev-prod-parity.md`. If so, add the registry auth entry to the existing file rather than creating a new one. Coordinate merge order or handle the merge conflict by combining entries.
