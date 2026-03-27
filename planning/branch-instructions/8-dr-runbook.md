---
branch: 8-dr-runbook
wave: 1
items: "#8"
impl_owner: Engineering Practices Lead
validation_owner: Product / Scope Lead
status: ready
---

# Branch: 8-dr-runbook

## Goal
Write a concise runbook that tells a developer exactly what to do when the local dev stack breaks — symptom, diagnosis, recovery — with no ambiguity about command order.

## Items covered
| # | Item |
|---|------|
| #8 | BP-010 Disaster recovery runbook |

## Acceptance criteria
- [ ] New file `planning/dr-runbook.md` created
- [ ] Covers all five scenarios: k3d cluster gone (WSL2 restart), registry unreachable, pod crashlooping, Keycloak realm missing, Istio sidecar injection broken
- [ ] Each scenario follows the format: symptom → diagnosis command(s) → recovery command(s)
- [ ] Documents approximate time `setup-local.sh` takes from zero (wall clock, not just "a while")
- [ ] Documents the canonical post-recovery sequence: `setup-local.sh` → `keycloak-admin.sh set-ttl 60` → `status.sh` → `branch-test.sh`
- [ ] File is readable end-to-end without referencing any external conversation or prior context

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `planning/dr-runbook.md` | Create | New file |

## Files to leave alone
All `src/`, `helm/`, `scripts/` files. This is a documentation-only branch.

## Decisions that apply to this branch
- DEC-004: The cluster is k3d (`mcp-presidio`), registry is `k3d-mcp-registry` on port 5000. All setup is done via `scripts/setup-local.sh`.
- DEC-002: After any cluster rebuild, `keycloak-admin.sh set-ttl 60` must be run to re-apply the 60s token TTL (Keycloak reverts to its 300s default on a fresh realm import).
- Phase 2: Istio is installed into the cluster. Sidecar injection issues are a realistic failure mode not present in Phase 1.
- `scripts/devtools-run.sh` is the correct wrapper for k3d/kubectl/helm commands if those tools are not installed directly on the host.

## How to validate
Read `planning/dr-runbook.md` end-to-end and verify:
- Every command in the runbook is a real command (check against `scripts/` and `infrastructure/`)
- No command references a tool not listed in CLAUDE.md prerequisites (Docker, k3d, kubectl, helm, curl)
- The post-recovery sequence matches what `scripts/README.md` documents
- Approximate timing for `setup-local.sh` is plausible (check by running it or asking the impl owner for a measurement)

No `branch-test.sh` run required — this is a documentation-only branch.

## What the validation owner checks
- File exists at `planning/dr-runbook.md`
- All five required scenarios are present
- Each scenario has symptom + diagnosis + recovery (not just recovery)
- Post-recovery sequence is correct and complete
- No broken references to files or scripts that do not exist
- Language is direct and imperative ("Run X", "If you see Y, run Z") — not advisory ("you might want to consider")

## Notes / constraints
- The runbook is for a developer working on a fresh WSL2 session or returning after a machine restart. Assume they have all prerequisites installed (per CLAUDE.md) but the cluster may be gone.
- WSL2 caveat: `newgrp docker` does not propagate to non-interactive subshells. `setup-local.sh` uses `sg docker -c ...` to handle this. Document this in the runbook so developers know why the script looks the way it does.
- Istio sidecar injection failure: the most common cause is the namespace label `istio-injection=enabled` being absent after a cluster rebuild. Recovery: `kubectl label namespace mcp-presidio istio-injection=enabled` followed by rolling restart of all pods.
- Do not speculate about Phase 3 failure modes. Scope is Phase 2 running system only.

---

## Runbook template (use as a starting point)

```markdown
# Disaster Recovery Runbook

## How to use this runbook
Each scenario follows the same structure:
- **Symptom:** What you observe
- **Diagnose:** Command to confirm the root cause
- **Recover:** Commands to restore the stack

After any recovery, always run the post-recovery sequence (Section 6).

---

## 1. k3d cluster gone (WSL2 restart or accidental deletion)
## 2. Registry unreachable (push fails or images not pulling)
## 3. Pod crashlooping
## 4. Keycloak realm missing or reset
## 5. Istio sidecar injection broken

---

## 6. Post-recovery sequence (always run after any recovery)
```
