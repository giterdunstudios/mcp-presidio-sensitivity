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
- [ ] `annotated-doc==0.0.4` is added — it appears in both lock files but was absent from the previous `bom.json`
- [ ] Every component's `purl` version field matches its `version` field (two known errors: `typing-extensions` PURL says `0.15.0` but version is `4.15.0`; `tqdm` PURL says `4.67.0` but version is `4.67.3`)
- [ ] Components for deleted auth/ modules (`token_verifier`, `policy`) are removed
- [ ] Infrastructure components updated: all five Phase 2 Istio CRDs noted as infrastructure platform components — `RequestAuthentication`, `AuthorizationPolicy`, `PeerAuthentication`, `EnvoyFilter` (rate-limit), `EnvoyFilter` (WWW-Authenticate). Python library components come from lock files only; infrastructure platform components (Istio, Envoy, Keycloak, Jaeger, Prometheus, Grafana) are sourced from deployed manifests and images, not lock files.
- [ ] `mcp-server` component description updated: remove stale "JWT auth middleware" language; reflect that Envoy sidecar owns JWT validation and scope enforcement, the app owns audit trail, classify tool, and RFC 9728 endpoint
- [ ] `pyjwt` removed from `mcp-server.dependsOn` list as a direct dependency (it is now only transitive via the `mcp` library)
- [ ] `serialNumber` is a freshly generated UUID (not the same as the previous one)
- [ ] `metadata.timestamp` updated to the date of the actual update
- [ ] `version` field incremented from `1` to `2` (material document revision per CycloneDX spec)
- [ ] File is valid JSON (`python3 -c "import json; json.load(open('bom.json'))"` exits 0)
- [ ] No duplicate `bom-ref` values: `python3 -c "import json; data=json.load(open('bom.json')); refs=[c['bom-ref'] for c in data['components']]; dupes=[r for r in refs if refs.count(r)>1]; print('Dupes:', dupes or 'none')"`

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
- The existing `bom.json` uses `specVersion: "1.6"`. Maintain CycloneDX 1.6 — the note "CycloneDX 1.4" anywhere is stale and incorrect.
- Do not add Python library components that are not in the lock files. Infrastructure platform components (Istio, Keycloak, Jaeger, Prometheus, Grafana) are an explicit exception and are sourced from deployed manifests.
- **Istio version is not pinned in any repo file.** Determine the deployed version from the live cluster:
  ```bash
  ./scripts/devtools-run.sh kubectl -n istio-system get deployment istiod \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
  ```
  If the cluster is unavailable, record the Istio component with a property `internal:version-source: not-pinned-in-repo` and whatever version was last observed.
- Prefer a **full-file rewrite** of `bom.json` over surgical line-by-line edits. The components array is a flat list of 88+ entries — surgical edits carry trailing-comma and duplicate-entry risk that a full rewrite avoids. Write the complete updated file, then validate JSON syntax.
