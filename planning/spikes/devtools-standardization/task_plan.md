---
spike: devtools-run Standardization
owner: Engineering Practices Lead
status: research_complete
created: 2026-03-27
---

# Spike: Should devtools-run.sh Be the Standard Execution Model?

## Question

`devtools-run.sh` is a thin launcher script that runs any command inside a pinned-toolchain
Docker container (k3d v5.7.4, kubectl v1.30.0, helm v3.14.4, docker-cli, python3, curl).
Currently it is an opt-in pattern — referenced in `branch-test.sh` documentation but not
enforced as the standard entry point.

Should we standardize `devtools-run.sh` as the execution model for all scripts, some scripts,
or no additional scripts?

## Scope

- Audit all scripts in `scripts/` for host tool dependencies and isolation patterns
- Produce pros/cons for three options: do nothing, partial standardization, full standardization
- Estimate impact and effort
- Propose demoable technical milestones if proceeding
- Treat "do nothing" as a first-class option

## Out of scope

Implementation. This spike produces a recommendation; scheduling and execution are separate.

## Tasks

- [x] Understand the devtools pattern (`devtools-run.sh`, `infrastructure/devtools.Dockerfile`)
- [x] Audit all 10 scripts: host tool requirements, own isolation, devtools suitability
- [x] Analyze Option A (do nothing), Option B (full standardization), Option C (partial)
- [x] Produce demoable milestones for recommended option
- [x] Write recommendation with rationale

## Output

See `findings.md` in this directory.

## Backlog entry

BP-026 in `planning/best-practices-backlog.md`.
