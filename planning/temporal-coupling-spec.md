---
title: Temporal Coupling Analysis — Engineering Spec
status: proposed
priority: high
phase: pre-wave (tooling)
owner: Engineering Practices Lead
council_review: required before implementation begins
---

# Temporal Coupling Analysis

## Problem statement

Static coupling maps (see `planning/file-coupling-map.md`) describe what files
*structurally* depend on each other — imports, config references, template
consumers. They are useful as a prior but blind to empirical reality: files that
always change together in practice, regardless of whether the code makes that
relationship explicit (e.g. a script and its documentation, two config files that
move in lockstep for operational reasons).

Wave planning currently relies on the static map plus human judgement. As the
project accumulates commit history, the empirical pattern of what changes
together becomes the stronger signal. This spec describes a system that mines
that signal, expresses it as conditional probabilities, and feeds it into wave
planning decisions — including a calibrated risk model that allows parallel
execution with known and accepted collision probability rather than binary
serialize/parallelize choices.

---

## Concepts

### Co-change coupling

Two files A and B are *co-change coupled* if they frequently appear together in
the same commit or pull request. The strength of coupling is expressed as a
conditional probability:

```
P(B changes | A changes) = |commits containing both A and B| / |commits containing A|
P(A changes | B changes) = |commits containing both A and B| / |commits containing B|
```

These are asymmetric. `P(README changes | rebuild.sh changes)` may be 0.9 while
`P(rebuild.sh changes | README changes)` is 0.4 — README changes for many reasons,
but rebuild.sh changes almost always bring a README update.

The *coupling score* for a pair is the higher of the two directional values,
representing the worst-case collision risk when either file is in scope.

### History confidence

Probabilities computed from few observations are unreliable. A 1/2 result and a
10/20 result are both 50%, but mean very different things. A *confidence tier*
is assigned to each pair based on the number of times the more-frequent file has
been committed:

| Tier | Observation threshold | Interpretation |
|------|-----------------------|----------------|
| `sparse` | < 5 commits | Probability unreliable; defer to static coupling map |
| `early` | 5–19 commits | Directional signal; treat as advisory |
| `established` | 20–49 commits | Meaningful; use as primary signal |
| `mature` | ≥ 50 commits | High confidence; override static map |

### Coupling tiers

| Coupling score | Tier | Planning recommendation |
|----------------|------|------------------------|
| ≥ 0.70 | `strong` | Serialize — collision near-certain |
| 0.40–0.69 | `moderate` | Parallel with explicit risk acceptance |
| 0.15–0.39 | `weak` | Parallel; note in branch instruction |
| < 0.15 | `negligible` | Safe to parallelize |

---

## Components

### 1. Analysis script — `scripts/coupling-analysis.sh`

Mines git history and produces a machine-readable coupling report.

**Inputs (flags):**

| Flag | Default | Description |
|------|---------|-------------|
| `--since REF` | first commit | Limit history to commits reachable from REF |
| `--exclude-paths GLOB` | `planning/**` | Paths to ignore (planning docs, branch instructions, test fixtures) |
| `--min-observations N` | `3` | Omit pairs where the anchor file has fewer than N commits |
| `--output FILE` | `planning/coupling-data.json` | Output path |
| `--format json\|table` | `json` | Output format (`table` for human review) |

**Algorithm:**

```
1. git log --name-only --diff-filter=ACDMR --pretty=format:"%H %P"
   → one commit per line, followed by filenames changed
   → filter merge commits (commits with two parents) unless --include-merges

2. For each commit C:
   files(C) = set of changed files (after exclusion filter)
   For each pair (A, B) in files(C):
     co_change[A][B] += 1
     co_change[B][A] += 1  (symmetric raw count)
     total_changes[A] += 1
     total_changes[B] += 1

3. For each pair (A, B) where co_change[A][B] > 0:
   p_b_given_a = co_change[A][B] / total_changes[A]
   p_a_given_b = co_change[A][B] / total_changes[B]
   coupling_score = max(p_b_given_a, p_a_given_b)
   confidence_tier = tier(max(total_changes[A], total_changes[B]))
   coupling_tier = tier(coupling_score)

4. Sort output by coupling_score descending, filter by min_observations
```

**Output schema (`planning/coupling-data.json`):**

```json
{
  "generated": "2026-03-27T14:00:00Z",
  "commit_count": 47,
  "file_count": 83,
  "excluded_paths": ["planning/**", "deliverables/**"],
  "pairs": [
    {
      "file_a": "scripts/rebuild.sh",
      "file_b": "scripts/README.md",
      "co_change_count": 9,
      "p_b_given_a": 0.90,
      "p_a_given_b": 0.64,
      "coupling_score": 0.90,
      "coupling_tier": "strong",
      "history_confidence": "early",
      "observations_a": 10,
      "observations_b": 14
    }
  ]
}
```

**Invocation:**

```bash
# Regenerate after merging branches
./scripts/coupling-analysis.sh

# Table view for human review
./scripts/coupling-analysis.sh --format table

# Only strong + moderate pairs
./scripts/coupling-analysis.sh --format table | grep -E "strong|moderate"
```

**Regeneration trigger:** run after every merge to main. This can be added as a
post-merge hook or called manually before wave planning sessions. Do not run
on feature branches — only main has the merged history that matters.

---

### 2. Coupling data store — `planning/coupling-data.json`

Machine-readable output of the analysis script. Committed to main after each
regeneration run. Serves as the primary input to the planning agent.

This file is committed to the repo so that:
- Planning agents have access without running the script
- History of how coupling evolves is visible in git log
- Council reviews can see what the agent was working from

The file should never be hand-edited. It is always regenerated by
`coupling-analysis.sh`.

---

### 3. Static coupling map — `planning/file-coupling-map.md`

The architecture-derived prior (already built). Used as the fallback when
`coupling-data.json` is in the `sparse` confidence tier for a given pair, or
when a file has never appeared in any commit yet.

**Priority rule:**
- `established` or `mature` tier in coupling-data.json → use empirical score
- `early` tier → blend: flag empirical signal but note low confidence
- `sparse` tier or file never committed → fall back to static coupling map

---

### 4. Planning agent — operating model

The planning agent is invoked before wave construction. It does not require a
dedicated tool beyond the two data files above. Its role is to ingest a proposed
set of branch assignments, evaluate collision risk, and recommend adjustments.

#### Inputs the agent reads

1. `planning/coupling-data.json` — empirical coupling scores
2. `planning/file-coupling-map.md` — static coupling prior
3. Each relevant `planning/branch-instructions/*.md` — file footprint of each branch
4. The proposed wave assignment (provided inline by the user or read from
   `planning/wave-plan-diagram.md`)

#### What the agent produces

For each proposed parallel group in the wave:

```
Wave N — Proposed parallel group: [branch-A, branch-B, branch-C]

Collision analysis:
  branch-A × branch-B
    Shared files: scripts/rebuild.sh
    Coupling score: 0.90 (strong) — confidence: early (10 observations)
    Recommendation: SERIALIZE — collision near-certain
    Risk if parallelized: merge conflict in rebuild.sh requiring manual resolution

  branch-A × branch-C
    Shared files: none
    Static coupling check: no shared coupled sets
    Recommendation: SAFE TO PARALLELIZE

  branch-B × branch-C
    Shared files: scripts/README.md
    Coupling score: 0.43 (moderate) — confidence: sparse (3 observations)
    Note: sparse history — falling back to static coupling map
    Static map: README.md appears in rebuild.sh coupling set; branch-C does not touch rebuild.sh
    Recommendation: PARALLEL WITH AWARENESS — low empirical signal, static map clear

Revised grouping:
  Group 1 (parallel safe): branch-B, branch-C
  Group 2 (after Group 1 merges): branch-A
```

#### Early-stage operating behaviour

When history is thin (most pairs in `sparse` tier), the agent operates in
**prior-dominant mode**:

- Leads with static coupling map as primary signal
- Uses sparse empirical data as a secondary flag ("3 co-changes observed, not
  yet statistically meaningful, but noted")
- Is explicit about uncertainty: "I am reasoning from architecture, not history"
- Asks for human confirmation on any call where the static map is ambiguous and
  empirical data is sparse

As history grows (pairs move into `early` and `established` tiers), the agent
shifts to **empirical-dominant mode** automatically, using the coupling scores as
primary signal and the static map only as a sanity check.

#### Risk acceptance workflow

For `moderate` coupling pairs, the agent does not unilaterally serialize. It
presents the risk and asks for an explicit decision:

```
branch-D × branch-E: moderate coupling (0.52) on helm/mcp-server/values.yaml
  Co-change history: 6/11 commits where values.yaml changed also changed Chart.yaml
  If parallelized: ~50% chance of merge conflict in values.yaml
  Options:
    A. Serialize (safe, adds one wave slot)
    B. Parallelize with merge owner assigned to branch-E (accepts conflict risk)
    C. Split branch-E to move values.yaml changes to a separate follow-on branch
  What would you like to do?
```

This keeps humans in the loop on risk acceptance rather than always defaulting
to the conservative path.

#### Feedback capture

When a parallel pair produces a merge conflict (or is later found to have been
wrong), the agent notes it:

```
Post-merge observation: branch-D × branch-E produced a conflict in
helm/mcp-server/values.yaml despite moderate coupling score.
Suggest: treat this pair as strong coupling until empirical data catches up.
Consider adding a note to planning/file-coupling-map.md static entry for
helm/mcp-server/values.yaml.
```

This creates a feedback loop that improves planning before the commit count
reaches statistical significance.

---

## Implementation phases

### Phase 1 — Script + data file (implement first)

Deliverables:
- `scripts/coupling-analysis.sh` — analysis script
- Initial `planning/coupling-data.json` — generated from current history
- `scripts/README.md` update — document coupling-analysis.sh

Acceptance criteria:
- Script runs against this repo's history and produces valid JSON
- Output reflects known co-change patterns (rebuild.sh + README.md should score high)
- Table output is human-readable enough for manual wave planning review

### Phase 2 — Agent integration (implement after Phase 1 is proven)

Deliverables:
- Branch instruction template updated to include a `## Files touched` section
  (structured, not prose) so the agent can parse it without reading the full instruction
- Agent prompt / operating guide (can live in `planning/`) describing how to
  invoke the planning agent and interpret its output
- Wave plan diagram updated to show risk scores alongside branch names

Acceptance criteria:
- Planning agent can take a proposed wave grouping and produce a collision
  analysis within one message, citing coupling scores and confidence tiers
- Agent correctly identifies at least the rebuild.sh / README.md collision class
  from the current backlog

### Phase 3 — Automation hooks (implement when workflow is stable)

Deliverables:
- Post-merge hook that regenerates coupling-data.json after each merge to main
- Coupling data diff surfaced in PR description (optional — useful when the
  merge itself changes coupling patterns)

---

## Constraints and non-goals

- **Non-goal:** real-time coupling computation during a merge. The data file is
  always pre-computed from main history. Agents read the file, not the git log.
- **Non-goal:** coupling across planning documents or branch instruction files.
  These are excluded from the analysis. Coupling is for solution artifacts only.
- **Constraint:** the analysis unit is the commit, not the line. A commit that
  touches 50 files produces 50×49/2 = 1225 pairs — most spurious. Large
  "housekeeping" commits (rename, reformat, mass-update) should be excluded or
  flagged. The `--exclude-paths` flag handles documentation sweeps; very large
  commits (> 20 files changed) should be logged as outliers and optionally
  excluded via `--max-files-per-commit N`.
- **Constraint:** the script must be runnable inside `devtools-run.sh` (no host
  Python or Node dependency — bash + git only, or Python via the devtools container).

---

## Open questions for council review

1. **Commit vs PR as the analysis unit.** PRs group related work more semantically
   than individual commits (a PR may have fixup commits that inflate pair counts).
   Do we use `git log` (commit-level) or `gh pr list` + per-PR diff (PR-level)?
   PR-level is more semantically correct but requires GitHub API access.
   *Recommendation: start with commit-level, add PR-level in Phase 3.*

2. **Threshold values.** The 0.70/0.40/0.15 thresholds above are initial guesses.
   After Phase 1 generates real data, review the distribution and calibrate.

3. **Excluded path list.** `planning/**` and `deliverables/**` are excluded by
   default. Are there other paths that should always be excluded (e.g. `.github/**`,
   `infrastructure/devtools.Dockerfile`)?

4. **Agent authority.** Should the planning agent be able to propose a revised wave
   plan autonomously (write to wave-plan-diagram.md), or should it always produce
   recommendations for human review before any file is changed? Given we are in
   early stages, *recommendation: advisory only — agent outputs text, human
   approves before wave plan is updated.*
