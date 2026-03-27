---
branch: 6-credential-gate
wave: 2
items: "#6"
impl_owner: Security / Privacy Lead
validation_owner: Engineering Practices Lead
status: ready
---

# Branch: 6-credential-gate

## Goal
Create a standalone script that detects hardcoded default credentials and call it from `rebuild.sh` — non-blocking by default, with a `--strict` flag for future CI enforcement.

## Items covered
| # | Item |
|---|------|
| #6 | Hardcoded credential pre-prod gate |

## Acceptance criteria
- [ ] New file `scripts/check-credentials.sh` created and marked executable (`chmod +x`)
- [ ] Script scans `helm/mcp-server/values.local.yaml`, `helm/presidio-worker/values.local.yaml`, and `keycloak/` directory for known default values: `change-in-prod`, `test-agent-secret`, `admin` password patterns
- [ ] Default behaviour (no flags): prints findings with `file:line` references, exits 0 regardless of findings
- [ ] `--strict` flag: exits 1 if any findings; exits 0 if clean
- [ ] `scripts/rebuild.sh` calls `"$SCRIPT_DIR/check-credentials.sh"` (without `--strict`) early in the script — after the prerequisites check, before the docker build
- [ ] Script added to `scripts/README.md` with when-to-use guidance
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/check-credentials.sh` | Create | New executable script |
| `scripts/rebuild.sh` | Modify | Add one call line early in the script |
| `scripts/README.md` | Modify | Add entry for check-credentials.sh |

## Files to leave alone
`scripts/test.sh`, `scripts/setup-local.sh`, `scripts/branch-test.sh`, `scripts/auth-test.sh`, `scripts/demo.sh`, `scripts/classify.sh`, `scripts/status.sh`, `scripts/keycloak-admin.sh`. All `src/` files. All `helm/` template files and `values.yaml` (production values). Do not modify values in `helm/` — only scan them.

## Decisions that apply to this branch

### Design decisions (resolved before branch was opened)
- Implementation: standalone `scripts/check-credentials.sh` — NOT inline logic in `rebuild.sh`. Rebuild.sh calls the script in one line.
- Default behaviour: non-blocking (exit 0 with findings printed). This means `rebuild.sh` continues even if credentials are found. The intention is to warn the developer without breaking the workflow.
- `--strict` flag: exit 1 on any finding. Reserved for future CI enforcement. Do NOT add `--strict` to the `rebuild.sh` call.
- Scan scope: `values.local.yaml` files and `keycloak/` only. These are the files that contain local dev credentials that must not reach production. The scan is not a general secrets scanner.

### Why non-blocking by default
Production deployments do not use `values.local.yaml` — those files are local-only overrides. The `--strict` flag gives future CI pipelines a way to enforce clean production values files when those are added. For now, a visible warning in the rebuild output is sufficient.

## How to validate

```bash
# 1. Test default behaviour (should print findings, exit 0)
./scripts/check-credentials.sh
echo "Exit code: $?"   # must be 0

# 2. Test --strict with known findings (should exit 1)
./scripts/check-credentials.sh --strict
echo "Exit code: $?"   # must be 1 (values.local.yaml has test-agent-secret)

# 3. Run rebuild to confirm the call is wired in and non-blocking
./scripts/rebuild.sh mcp 2>&1 | head -30   # should see credential check output early

# 4. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- `scripts/check-credentials.sh` exists and is executable
- Default (no flags) exits 0 even when findings are present
- `--strict` exits 1 when `test-agent-secret` is found in `values.local.yaml`
- `rebuild.sh` diff shows exactly one new line calling `check-credentials.sh` (no `--strict`)
- The call in `rebuild.sh` is positioned after prerequisites check, before `docker build`
- `scripts/README.md` has a new entry for `check-credentials.sh`
- `branch-test.sh` passes

## Notes / constraints

### Patterns to scan for
The script must detect these known default values:

| Pattern | Context |
|---|---|
| `change-in-prod` | Generic placeholder value used in local Helm values |
| `test-agent-secret` | The MCP client secret in `values.local.yaml` |
| Password fields set to `admin` | Keycloak admin credentials in `keycloak/` |

Use `grep -rn` with the pattern list and print matching lines in `file:line:content` format. Do not use complex parsing — grep is sufficient for these known literal strings.

### Script header format
All scripts in this project have a `When to use` header block. Use the same style:

```bash
#!/usr/bin/env bash
# scripts/check-credentials.sh
#
# Scans local config files for known default/hardcoded credentials.
#
# When to use:
#   - Automatically called by rebuild.sh before every build (non-blocking)
#   - Run manually with --strict before opening a PR that touches Helm values
#   - Run with --strict in CI pipelines that validate production values files
#
# Usage:
#   ./scripts/check-credentials.sh           # warn only, exit 0
#   ./scripts/check-credentials.sh --strict  # exit 1 if any findings
```

### rebuild.sh integration
Find the section of `rebuild.sh` after the prerequisites check (typically after verifying docker/k3d/kubectl are available) and before the first `docker build` command. Insert:

```bash
# Credential scan (non-blocking — warn only)
"$SCRIPT_DIR/check-credentials.sh"
```

`$SCRIPT_DIR` should already be defined in `rebuild.sh` as `$(cd "$(dirname "$0")" && pwd)`. Verify this before adding the call.
