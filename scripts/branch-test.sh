#!/usr/bin/env bash
# Full branch validation suite — run before opening a PR or requesting a merge.
#
# Designed for agent and developer use. Runs the complete test sequence
# sequentially and reports a single pass/fail result. Agents should run
# this via devtools-run.sh so all required tools (k3d, kubectl, helm) are
# available without host installation:
#
#   ./scripts/devtools-run.sh ./scripts/branch-test.sh
#   ./scripts/devtools-run.sh ./scripts/branch-test.sh --full
#
# Or directly on the host if all tools are installed:
#
#   ./scripts/branch-test.sh
#   ./scripts/branch-test.sh --full
#
# Steps:
#   1  Unit tests     — Docker only, no cluster; safe to run in parallel with
#                       other branches. Exits fast if unit tests fail.
#   2  Rebuild        — Builds images tagged with git SHA, pushes to registry,
#                       helm upgrade + rolling restart. Requires exclusive
#                       cluster access (sequential — do not overlap with other
#                       branch deployments).
#   3  Status         — Full stack health check.
#   4  Auth test      — 5-case auth enforcement matrix.
#                       NOTE: case 5 (expired token) waits 65 seconds.
#   5  NetworkPolicy  — Live enforcement validation.
#   6  Demo (--full)  — End-to-end demo all cases. Only with --full flag.
#
# Exit codes:
#   0 — all steps passed
#   1 — one or more steps failed (summary printed at end)
#
# CLUSTER COORDINATION:
#   Steps 2–5 (and 6) modify and query the shared k3d cluster. Only one
#   branch should be deployed at a time. Unit tests (step 1) run before the
#   lock is acquired so multiple agents can test in parallel up to that point.
#   A flock on LOCK_FILE serialises everything from step 2 onward — the second
#   agent blocks until the first releases (on exit, even if it crashes).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="${TMPDIR:-/tmp}/mcp-presidio-cluster.lock"
LOCK_TIMEOUT=300   # seconds to wait before giving up

FULL=false
for arg in "$@"; do
  [[ "$arg" == "--full" ]] && FULL=true
done

pass()   { printf '  \033[32m✔\033[0m  %s\n' "$*"; }
fail()   { printf '  \033[31m✘\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }

FAILURES=0
STEP_RESULTS=()

run_step() {
  local label="$1"
  shift
  header "Step: $label"
  if "$@"; then
    pass "$label"
    STEP_RESULTS+=("PASS  $label")
  else
    fail "$label"
    STEP_RESULTS+=("FAIL  $label")
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — Unit tests (isolated, no cluster)
# ---------------------------------------------------------------------------

run_step "Unit tests (test.sh)" "$SCRIPT_DIR/test.sh"

# Fail fast on unit tests — no point deploying broken code
if [[ $FAILURES -gt 0 ]]; then
  echo ""
  printf '\033[31m\033[1mUnit tests failed — aborting branch validation.\033[0m\n'
  exit 1
fi

# ---------------------------------------------------------------------------
# Acquire cluster lock — serialises steps 2–5 across all agents.
# flock releases automatically when this process exits (clean or crash).
# ---------------------------------------------------------------------------

BRANCH=$(git -C "$SCRIPT_DIR/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

header "Acquiring cluster lock"
printf '  \033[2m--\033[0m  lock file: %s\n' "$LOCK_FILE"
printf '  \033[2m--\033[0m  branch:    %s\n' "$BRANCH"
printf '  \033[2m--\033[0m  timeout:   %ss\n' "$LOCK_TIMEOUT"

exec 9>"$LOCK_FILE"
if ! flock -x -w "$LOCK_TIMEOUT" 9; then
  printf '\n\033[31m\033[1mCould not acquire cluster lock after %ds.\033[0m\n' "$LOCK_TIMEOUT"
  printf 'Another agent is deploying. Check: lsof %s\n' "$LOCK_FILE"
  exit 1
fi

printf '  \033[32m✔\033[0m  Lock acquired — cluster is ours\n'

# ---------------------------------------------------------------------------
# Step 2 — Rebuild and deploy (cluster required — sequential)
# ---------------------------------------------------------------------------

run_step "Rebuild and deploy (rebuild.sh)" "$SCRIPT_DIR/rebuild.sh"

# ---------------------------------------------------------------------------
# Step 3 — Full stack status
# ---------------------------------------------------------------------------

run_step "Stack health (status.sh)" "$SCRIPT_DIR/status.sh"

# ---------------------------------------------------------------------------
# Step 4 — Auth enforcement matrix (includes 65s wait for expired token case)
# ---------------------------------------------------------------------------

run_step "Auth enforcement (auth-test.sh)" "$SCRIPT_DIR/auth-test.sh"

# ---------------------------------------------------------------------------
# Step 5 — NetworkPolicy live enforcement
# ---------------------------------------------------------------------------

run_step "NetworkPolicy (validate-networkpolicy.sh)" "$SCRIPT_DIR/validate-networkpolicy.sh"

# ---------------------------------------------------------------------------
# Step 6 — Full demo (optional, --full only)
# ---------------------------------------------------------------------------

if $FULL; then
  run_step "End-to-end demo (demo.sh a)" "$SCRIPT_DIR/demo.sh" a
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
printf '\033[1m%s\033[0m\n' "Branch validation summary"
printf '%s\n' "──────────────────────────────"
for result in "${STEP_RESULTS[@]}"; do
  if [[ "$result" == PASS* ]]; then
    printf '  \033[32m%s\033[0m\n' "$result"
  else
    printf '  \033[31m%s\033[0m\n' "$result"
  fi
done
printf '%s\n' "──────────────────────────────"

SHA=$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo "unknown")
printf '  Branch: %s  SHA: %s\n' "$BRANCH" "$SHA"
echo ""

if [[ $FAILURES -eq 0 ]]; then
  printf '\033[32m\033[1mAll steps passed — branch ready for review.\033[0m\n'
  exit 0
else
  printf '\033[31m\033[1m%d step(s) failed — branch not ready for merge.\033[0m\n' "$FAILURES"
  exit 1
fi
