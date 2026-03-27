---
branch: 10-k3d-version-check
wave: 2
items: "#10"
impl_owner: Engineering Practices Lead
validation_owner: Technical Implementation Lead
status: ready
---

# Branch: 10-k3d-version-check

## Goal
Make `setup-local.sh` verify the installed k3d version meets the minimum required version and warn if newer — catching version drift before it causes cluster creation failures.

## Items covered
| # | Item |
|---|------|
| #10 | BP-012 k3d version floor check in setup-local.sh |

## Acceptance criteria
- [ ] `scripts/setup-local.sh` checks k3d version early (after the prerequisites section, before any k3d commands)
- [ ] k3d version < 5.7.4: prints a clear error message and exits 1
- [ ] k3d version > 5.7.4: prints a warning (does not exit — newer may work, but flag it)
- [ ] k3d version = 5.7.4: silent (no output for this check)
- [ ] Version comparison uses `sort -V` or equivalent shell arithmetic — not string comparison
- [ ] `./scripts/devtools-run.sh ./scripts/branch-test.sh` passes

## Files to create / modify
| File | Action | Notes |
|------|--------|-------|
| `scripts/setup-local.sh` | Modify | Add version check block after prerequisites section |

## Files to leave alone
All other scripts (`rebuild.sh`, `status.sh`, `branch-test.sh`, `auth-test.sh`, `demo.sh`, `classify.sh`, `keycloak-admin.sh`). All `src/`, `helm/`, `planning/` files. `CLAUDE.md` already documents the pinned version — do not modify it.

## Decisions that apply to this branch
- DEC-004: k3d v5.7.4 is the pinned version used in development. It is documented in `CLAUDE.md` prerequisites table and in `infrastructure/devtools.Dockerfile`.
- The devtools container runs k3d v5.7.4 exactly. When using `./scripts/devtools-run.sh`, the version check will always pass (5.7.4 = 5.7.4 → silent). The check targets direct host invocations where version drift is possible.

## How to validate

```bash
# 1. Check current k3d version on host (or in devtools)
k3d version

# 2. Run setup-local.sh --skip-build to exercise the version check
#    (--skip-build avoids a full rebuild just to test the check)
./scripts/setup-local.sh --skip-build

# 3. Manual test of the comparison logic (if you can temporarily alter the
#    REQUIRED_K3D_VERSION variable in the script for testing):
#    - Set required to 99.0.0 → should error and exit 1
#    - Set required to 0.0.1 → should warn (version is newer)
#    - Set required to installed version → silent

# 4. Full branch validation
./scripts/devtools-run.sh ./scripts/branch-test.sh
```

## What the validation owner checks
- The version check block is present in `setup-local.sh` and positioned before any `k3d cluster` commands
- Version comparison uses `sort -V` or `printf '%s\n' ... | sort -V` — not lexicographic string comparison
- Confirms: version below floor → exit 1; version above floor → warning only; exact match → silent
- `branch-test.sh` passes (devtools container has k3d 5.7.4 exactly, so the check should be silent)

## Notes / constraints

### k3d version output format
`k3d version` prints:
```
k3d version v5.7.4 (HEAD, ...)
k3s version v1.30.4+k3s1 (default)
```

Parse the first line. Extract the version number (strip the leading `v`):
```bash
K3D_INSTALLED=$(k3d version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
```
**Note:** Do NOT use `grep -oP` (PCRE). The devtools container runs Alpine Linux with BusyBox grep, which does not support `-P`. Use `grep -oE` instead — it works on BusyBox grep, GNU grep, and macOS BSD grep.

After parsing, add an empty-string guard before the comparison:
```bash
[ -z "$K3D_INSTALLED" ] && { echo "[setup] ERROR: could not parse k3d version output. Run 'k3d version' manually." >&2; exit 1; }
```

### Version comparison with sort -V
`sort -V` performs version-aware sorting. Use it to compare two version strings:

```bash
REQUIRED="5.7.4"
INSTALLED="$K3D_INSTALLED"

# Returns the lower of the two versions
LOWER=$(printf '%s\n%s\n' "$REQUIRED" "$INSTALLED" | sort -V | head -1)

if [ "$LOWER" = "$INSTALLED" ] && [ "$INSTALLED" != "$REQUIRED" ]; then
  # installed < required
  echo "ERROR: k3d version $INSTALLED is below the required minimum $REQUIRED"
  exit 1
elif [ "$INSTALLED" != "$REQUIRED" ]; then
  # installed > required
  echo "WARNING: k3d $INSTALLED is newer than tested version $REQUIRED. NetworkPolicy enforcement and cluster behavior may differ. Run ./scripts/validate-networkpolicy.sh after setup to confirm enforcement is intact."
fi
# else: installed = required, silent
```

### Where to insert in setup-local.sh
Read `setup-local.sh` first to understand its structure. The prerequisites check section typically verifies that required binaries are present (docker, k3d, kubectl, helm). Insert the version check immediately after the "k3d is installed" check. Do not insert it before the binary existence check — if k3d is not installed, `k3d version` will fail and the error message will be confusing.

### devtools container behaviour
`./scripts/devtools-run.sh` runs commands inside `infrastructure/devtools.Dockerfile` which has k3d v5.7.4 installed. When `branch-test.sh` calls setup-local.sh via devtools-run.sh, the version check will find 5.7.4 = 5.7.4 and be silent. This is the expected behaviour.
