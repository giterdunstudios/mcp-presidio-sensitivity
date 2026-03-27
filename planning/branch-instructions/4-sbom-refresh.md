---
branch: 4-sbom-refresh
wave: 1
items: "#4"
impl_owner: Security / Privacy Lead
validation_owner: Technical Implementation Lead
status: ready
---

# Branch: 4-sbom-refresh

## Goal
Update `bom.json` to accurately reflect the Phase 2 running system — auth/ modules deleted, Istio/Envoy CRDs added, component list reconciled against current requirements.lock.txt in both services.

## Items covered
| # | Item |
|---|------|
| #4 | SBOM (bom.json) refresh post-Phase 2 |

## Acceptance criteria
- [ ] `bom.json` components reflect current `src/mcp_server/` and `src/worker/` dependencies (cross-checked against `requirements.lock.txt` in both)
- [ ] Components for deleted auth/ modules (`token_verifier`, `policy`) are removed
- [ ] Infrastructure components updated: Istio, Envoy sidecar, EnvoyFilter CRDs noted as infrastructure components
- [ ] `serialNumber` is a freshly generated UUID (not the same as the previous one)
- [ ] `metadata.timestamp` updated to today's date (2026-03-26 or the date of the actual update)
- [ ] File is valid JSON (`python3 -c "import json; json.load(open('bom.json'))"` exits 0)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `bom.json` | Modify | Update components, serialNumber, timestamp |

## Files to leave alone
All `src/`, `helm/`, `scripts/`, `planning/` files (except this instruction file). The SBOM refresh touches only `bom.json`.

## Decisions that apply to this branch
- Phase 2 moved JWT validation and scope enforcement from application code (`auth/token_verifier.py`, `authorization/policy.py`) into the Envoy sidecar (Istio `RequestAuthentication` and `AuthorizationPolicy`). Those Python modules are deleted. The SBOM must not list them.
- Two EnvoyFilter CRDs are active in Phase 2 (see DEC-005): `envoy-rate-limit.yaml` and `rfc9728-www-authenticate.yaml`. These are infrastructure components.
- The SBOM format in this project is CycloneDX JSON. Maintain the same format and schema version as the existing file.

## How to validate

```bash
# 1. Check current requirements.lock.txt for both services
cat src/mcp_server/requirements.lock.txt
cat src/worker/requirements.lock.txt

# 2. Compare against bom.json components
python3 -c "import json; data=json.load(open('bom.json')); [print(c.get('name','?'), c.get('version','?')) for c in data.get('components',[])]"

# 3. Verify no auth/ module references remain
grep -i "token_verifier\|authorization.policy\|jwks" bom.json

# 4. Validate JSON syntax
python3 -c "import json; json.load(open('bom.json')); print('JSON valid')"

# 5. Confirm serialNumber changed
git diff bom.json | grep serialNumber
```

To generate a new UUID for `serialNumber`:
```bash
python3 -c "import uuid; print('urn:uuid:' + str(uuid.uuid4()))"
```

## What the validation owner checks
- Cross-reference the component list in `bom.json` against `src/mcp_server/requirements.lock.txt` — every pinned package in the lock file should have a corresponding component entry
- Cross-reference against `src/worker/requirements.lock.txt` — same
- Confirm no `token_verifier`, `policy`, or `auth/` module components remain
- Confirm `serialNumber` differs from the value in the previous commit (`git show HEAD:bom.json | grep serialNumber`)
- Run the JSON validity check: `python3 -c "import json; json.load(open('bom.json')); print('valid')"`
- Confirm `metadata.timestamp` is updated

## Notes / constraints
- The CycloneDX specification for infrastructure components uses `type: "platform"` or `type: "container"`. Use whichever type the existing file uses for infrastructure entries. Do not introduce a new type category without a note in the PR.
- If `bom.json` does not currently exist, create it from scratch following the CycloneDX 1.4 JSON schema. Check the existing file first with `cat bom.json` before assuming it exists.
- Do not add components that are not in the lock files. The SBOM should reflect what is installed, not what might be added in the future.
- Istio / Envoy version: check the deployed version with `./scripts/devtools-run.sh kubectl -n istio-system get pods -o wide` or check `infrastructure/` for the installed version reference.
