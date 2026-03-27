---
branch: 13-helm-version-policy
wave: 2
items: "#13"
impl_owner: Engineering Practices Lead
validation_owner: Technical Implementation Lead
status: COMPLETE
---

# Branch: 13-helm-version-policy

## Goal
(Completed) Establish a written policy for when and how Helm chart versions are bumped — Part A of item #13.

## Items covered
| # | Item |
|---|------|
| #13 | Helm chart version bump policy (Part A — policy document) |

## Status note

**This branch item is DONE. No work is required.**

The policy document `planning/helm-versioning-policy.md` was written and committed to `main` on 2026-03-27 as part of cross-persona flag resolution. Part A of item #13 is therefore complete.

## What was delivered
- `planning/helm-versioning-policy.md` — committed to main, covers SemVer classification table, bump trigger rules, and the coordination requirement for Part B.

## What is NOT done (Part B)
Part B — the coordinated `0.1.0 → 0.2.0` bump of both Helm charts — is a separate item (`#13b`) tracked in `planning/branch-instructions/13b-helm-version-bump.md`. It is blocked until items `#14` (helm-test-hooks) and `#26` (prometheus-worker-scraping) merge to main.

## Action required
Mark #13 as complete in `planning/tech-debt-backlog.md` on the next planning update. No branch work needed for this item.

## Files to leave alone
Everything. This branch has no implementation work remaining.

## Acceptance criteria
*(All criteria met — item complete)*
- [x] `planning/helm-versioning-policy.md` exists on main
- [x] Policy covers SemVer classification, bump triggers, and coordination requirements
- [x] Part B blocked on #14 and #26 per the policy document
