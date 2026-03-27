---
branch: 28-image-signing
wave: 4
items: "#28"
impl_owner: Security / Privacy Lead
validation_owner: Technical Implementation Lead
status: ready
---

# Branch: 28-image-signing

## Goal
Add Cosign image signing to `rebuild.sh` so every image pushed to the local k3d registry is signed — providing integrity verification and establishing the signing workflow before production adoption.

## Items covered
| # | Item |
|---|------|
| #28 | Image signing (Cosign) |

## Acceptance criteria
- [ ] `rebuild.sh` calls `cosign sign` after each `docker push`, using a local keyless or key-based signing mode
- [ ] Cosign not installed: print a warning and continue (same optional tooling pattern as Trivy and cdxgen)
- [ ] Signing applies to whichever images were just pushed (mcp, worker, or both)
- [ ] `scripts/README.md` updated: note that Cosign signing runs automatically when Cosign is installed
- [ ] `scripts/check-credentials.sh` does NOT scan for Cosign private keys (signing uses keyless or ephemeral key — no persistent secret)
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes (Cosign skipped in devtools container)

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/rebuild.sh` | Modify | Add Cosign sign after each docker push |
| `scripts/README.md` | Modify | Document Cosign signing under rebuild.sh |

## Files to leave alone
All `src/` files. All `helm/` files. All `infrastructure/` files. All other scripts.

## Decisions that apply to this branch

### Signing mode: keyless (preferred) vs key-based
**Keyless signing** (`cosign sign --key keyless`) requires OIDC token issuance via Sigstore's Fulcio CA. This works well for GitHub Actions (GITHUB_TOKEN) but is awkward in a local dev environment with no OIDC provider. It requires internet access to Sigstore's transparency log.

**Key-based signing** is simpler for local dev: generate an ephemeral key pair during first use, store the private key in a `.cosign/` directory (gitignored), sign images with it. The public key can be committed to the repo for future verification.

**Recommended approach for this branch:**
Use key-based signing with a generated local key. The private key is stored at `.cosign/cosign.key` (gitignored). The public key is stored at `.cosign/cosign.pub` (committed to the repo). If the key doesn't exist yet, generate it on first run.

### Why sign local dev images
The local k3d registry is unauthenticated (item #21). Signing does not add authentication, but it does establish the signing workflow and key management before production. When the project adopts a production registry, the signing infrastructure (key rotation, verification policy, transparency log) is already in place.

### Signature storage
For the local k3d registry, Cosign stores signatures as OCI artifacts in the same registry alongside the signed image. This is the default `cosign sign` behaviour. No additional infrastructure needed.

### verify step
This branch adds signing only. A future item can add `cosign verify` to the deployment step (before `helm upgrade`) to enforce that only signed images are deployed. That is explicitly out of scope here.

## How to validate

```bash
# 1. Confirm Cosign is installed
cosign version

# 2. Generate a signing key (first time only)
mkdir -p .cosign
cosign generate-key-pair --output-key-prefix .cosign/cosign
# This creates .cosign/cosign.key (private, gitignored) and .cosign/cosign.pub (public, committable)

# 3. Run rebuild — should see signing output
./scripts/rebuild.sh mcp 2>&1 | grep -E "cosign|sign|Signing"

# 4. Verify the signature was stored
cosign verify --key .cosign/cosign.pub localhost:5000/mcp-presidio-sensitivity:$(git rev-parse --short HEAD)
echo "Exit code: $?"   # must be 0

# 5. Simulate Cosign not installed
which cosign  # note path
sudo mv $(which cosign) /tmp/cosign-backup
./scripts/rebuild.sh mcp
echo "Exit code: $?"   # must be 0 with a warning
sudo mv /tmp/cosign-backup $(which cosign)

# 6. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- `rebuild.sh` diff shows cosign sign after each docker push, with missing-tool guard
- `cosign verify` succeeds for a freshly pushed image
- `.cosign/cosign.key` is in `.gitignore` (private key must not be committed)
- `.cosign/cosign.pub` is committed (public key enables future verification)
- Cosign not installed → exit 0 with a warning
- `branch-test.sh` passes (Cosign skipped in devtools container)

## Notes / constraints

### .gitignore update
Before committing `.cosign/cosign.pub`, ensure `.cosign/cosign.key` and `.cosign/cosign.pub.key` are in `.gitignore`:

```gitignore
# Cosign local signing key — never commit private key
.cosign/*.key
```

The `.cosign/cosign.pub` file (public key) IS committed. Only the private key (`cosign.key`) is gitignored.

### Cosign sign invocation pattern
```bash
cosign_sign() {
  local image="$1"
  if ! command -v cosign &>/dev/null; then
    log "WARNING: cosign not installed — skipping image signing for $image"
    log "         Install: https://docs.sigstore.dev/cosign/system_config/installation/"
    return 0
  fi
  local pubkey="$PROJECT_ROOT/.cosign/cosign.pub"
  local privkey="$PROJECT_ROOT/.cosign/cosign.key"
  if [ ! -f "$privkey" ]; then
    log "WARNING: cosign key not found at .cosign/cosign.key — skipping signing"
    log "         Generate: cosign generate-key-pair --output-key-prefix .cosign/cosign"
    return 0
  fi
  log "Signing $image..."
  COSIGN_PASSWORD="" cosign sign --key "$privkey" --yes "$image"
  log "$image signed"
}
```

Call `cosign_sign` immediately after each push:

```bash
if $BUILD_MCP && $BUILD_WORKER; then
  ...push both...
  wait
  cosign_sign "$MCP_IMAGE_REMOTE"
  cosign_sign "$WORKER_IMAGE_REMOTE"
elif $BUILD_MCP; then
  ...push mcp...
  cosign_sign "$MCP_IMAGE_REMOTE"
elif $BUILD_WORKER; then
  ...push worker...
  cosign_sign "$WORKER_IMAGE_REMOTE"
fi
```

### COSIGN_PASSWORD
When generating the key with `cosign generate-key-pair`, Cosign prompts for a passphrase. For local dev use, an empty passphrase is acceptable (set `COSIGN_PASSWORD=""`). Document this in the script. For production, the key would be stored in a secrets manager — the empty passphrase is a known local dev limitation, analogous to the `test-agent-secret` credential.

### Relationship to check-credentials.sh
`scripts/check-credentials.sh` (branch #6) scans for known default credential patterns. Cosign private keys are not in the scan scope (they are gitignored, not hardcoded values). No change to `check-credentials.sh` is needed.

### Future: cosign verify on deploy
A future item should add `cosign verify --key .cosign/cosign.pub IMAGE` before each `helm upgrade` in `rebuild.sh` to enforce that only signed images are deployed. This is not in scope for this branch.
