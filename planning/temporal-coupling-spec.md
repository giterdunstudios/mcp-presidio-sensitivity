---
title: Temporal Coupling Analysis — Engineering Spec
status: council-approved
priority: urgent — implement before wave work restarts
phase: pre-wave (ways of working)
owner: Engineering Practices Lead
council_reviewed: 2026-03-27
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
the same commit. The strength of coupling is expressed as a conditional probability:

```
P(B changes | A changes) = |commits containing both A and B| / |commits containing A|
P(A changes | B changes) = |commits containing both A and B| / |commits containing B|
```

These are asymmetric. `P(README changes | rebuild.sh changes)` may be 0.9 while
`P(rebuild.sh changes | README changes)` is 0.4 — README changes for many reasons,
but rebuild.sh changes almost always bring a README update.

The *coupling score* for a pair is the higher of the two directional values,
representing the worst-case collision risk when either file is in scope.

**Analysis unit: commits, not PRs.** The git commit log is the authoritative
history. PR-level analysis would be more semantically grouped but introduces a
GitHub API dependency and rate limit concerns. Revisit in Phase 3 only if
commit-level produces meaningfully noisy results.

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

### Agent operating mode transition

The planning agent operates in one of two modes depending on the maturity of the
coupling data for the wave being planned:

- **Prior-dominant mode:** fewer than 30% of relevant file pairs for the proposed
  wave are in `established` or `mature` confidence tier. Agent leads with the
  static coupling map; empirical data is surfaced as secondary signal only.
- **Empirical-dominant mode:** 30% or more of relevant pairs are `established`
  or `mature`. Agent leads with coupling scores; static map used as sanity check.

The agent always announces which mode it is operating in and why.

---

## Components

### 1. Analysis script — `scripts/coupling-analysis.sh`

Mines git history and produces a machine-readable coupling report.

**Inputs (flags):**

| Flag | Default | Description |
|------|---------|-------------|
| `--since REF` | first commit | Limit history to commits reachable from REF |
| `--exclude-paths GLOB` | see below | Colon-separated glob patterns to exclude |
| `--max-files-per-commit N` | `15` | Commits touching more than N files are treated as outliers (mass-update, reformat) and excluded; count is logged in `_meta` |
| `--min-observations N` | `3` | Omit pairs where the anchor file has fewer than N commits |
| `--output FILE` | `planning/coupling-data.json` | Output path |
| `--format json\|table` | `json` | Output format (`table` for human review) |

**Default excluded paths:**
```
planning/**
deliverables/**
.claude/**
```

These are excluded because:
- `planning/**` — branch instructions and specs are ephemeral work items, not solution artifacts
- `deliverables/**` — test fixtures and corpus files; changes don't reflect solution coupling
- `.claude/**` — settings and hook files; administrative commits that don't represent solution work

Additional paths can be appended via `--exclude-paths`. The full effective list is
recorded in `_meta.excluded_paths` in the output.

**Algorithm:**

```
1. git log --no-merges --name-only --diff-filter=ACDMR --pretty=format:"%H"
   → non-merge commits only (squash-merge repo; merge commits are empty or duplicative)
   → ACDMR: Added, Copied, Deleted, Modified, Renamed (excludes type-change-only)

2. For each commit C:
   raw_files(C) = set of changed files from git log output
   files(C) = raw_files(C) after applying exclusion filters

   if |files(C)| > max_files_per_commit:
     log as outlier; skip; increment excluded_commit_count
     continue

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

4. Sort output by coupling_score descending
5. Filter: omit pairs where min(observations_a, observations_b) < min_observations
```

**Output schema (`planning/coupling-data.json`):**

```json
{
  "_meta": {
    "generated": "2026-03-27T14:00:00Z",
    "commit_count": 47,
    "excluded_commit_count": 3,
    "file_count": 83,
    "excluded_paths": ["planning/**", "deliverables/**", ".claude/**"],
    "max_files_per_commit": 15,
    "min_observations": 3,
    "note": "INTERNAL ONLY — do not publish in public repositories without security review"
  },
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

`coupling-data.json` is treated as **internal only**. It contains the full file
path surface of the solution. Do not publish in a public repository without a
security review — the coupling map is a free reconnaissance document for an
attacker trying to understand which files move together.

**Invocation:**

```bash
# Regenerate after merging branches (run on main only)
./scripts/coupling-analysis.sh

# Table view for human review
./scripts/coupling-analysis.sh --format table

# Only strong + moderate pairs
./scripts/coupling-analysis.sh --format table | grep -E "strong|moderate"

# Via devtools container (if cluster tools needed on same host)
./scripts/devtools-run.sh ./scripts/coupling-analysis.sh
```

**Regeneration trigger:** run after every merge to main, before the next wave
planning session. Do not run on feature branches — only main has the merged
history that matters.

---

### 2. Coupling data store — `planning/coupling-data.json`

Machine-readable output of the analysis script. Committed to main after each
regeneration run. Serves as the primary input to the planning agent.

This file is committed to the repo so that:
- Planning agents have access without running the script
- History of how coupling evolves is visible in git log
- Council reviews can see what the agent was working from

The `_meta` block means the meaningful git diff is: when coupling scores change
significantly, not on every trivial commit. The diff is a useful audit trail of
how the project's co-change patterns evolve over time.

**The file must never be hand-edited.** It is always regenerated by
`coupling-analysis.sh`.

---

### 3. Static coupling map — `planning/file-coupling-map.md`

The architecture-derived prior (already built). Used as the fallback when
`coupling-data.json` is in the `sparse` confidence tier for a given pair, or
when a file has never appeared in any commit yet.

**Priority rule:**
- `established` or `mature` tier → use empirical coupling score as primary signal
- `early` tier → flag empirical signal; note low confidence; supplement with static map
- `sparse` tier or file not yet committed → fall back to static coupling map exclusively

---

### 4. Planning agent — operating model

The planning agent is invoked before wave construction. Its role is to ingest a
proposed set of branch assignments, evaluate collision risk, and produce
recommendations for human review.

**The agent is advisory only.** It never writes to `planning/wave-plan-diagram.md`
or any other planning file without explicit human approval. It produces text
output; a human decides whether to act on it. This is a hard constraint, not a
default that relaxes as the system matures.

#### Inputs the agent reads

1. `planning/coupling-data.json` — empirical coupling scores (primary when mature)
2. `planning/file-coupling-map.md` — static coupling prior (primary when sparse)
3. Each relevant `planning/branch-instructions/*.md` — file footprint per branch
4. The proposed wave assignment (provided inline or read from `planning/wave-plan-diagram.md`)

#### What the agent produces

```
Operating mode: PRIOR-DOMINANT (12% of relevant pairs are established/mature)

Wave N — Proposed parallel group: [branch-A, branch-B, branch-C]

Collision analysis:
  branch-A × branch-B
    Shared files: scripts/rebuild.sh
    Empirical: coupling_score=0.90 (strong), confidence=early (10 observations)
    Recommendation: SERIALIZE — collision near-certain
    Risk if parallelized: merge conflict in rebuild.sh requiring manual resolution

  branch-A × branch-C
    Shared files: none
    Static coupling check: no shared coupled sets
    Recommendation: SAFE TO PARALLELIZE

  branch-B × branch-C
    Shared files: scripts/README.md
    Empirical: coupling_score=0.43 (moderate), confidence=sparse (3 observations)
    Falling back to static coupling map — sparse history
    Static map: README.md in rebuild.sh coupling set; branch-C does not touch rebuild.sh
    Recommendation: PARALLEL WITH AWARENESS — static map clear, empirical data thin

Proposed revised grouping (awaiting your approval):
  Group 1 (parallel safe): branch-B, branch-C
  Group 2 (after Group 1 merges): branch-A
```

#### Risk acceptance workflow

For `moderate` coupling pairs the agent does not unilaterally serialize. It
surfaces the risk and requests an explicit decision:

```
branch-D × branch-E: moderate coupling (0.52) on helm/mcp-server/values.yaml
  Co-change history: 6/11 commits touching values.yaml also changed Chart.yaml
  If parallelized: ~50% chance of merge conflict in values.yaml
  Options:
    A. Serialize (safe, one additional wave slot)
    B. Parallelize — assign merge owner to branch-E (explicit risk acceptance)
    C. Split branch-E — move values.yaml changes to a follow-on branch
  Awaiting your decision.
```

#### Feedback capture

When a parallel pair produces a merge conflict despite a safe/moderate
recommendation, the agent flags it for the record:

```
Post-merge observation: branch-D × branch-E conflicted in
helm/mcp-server/values.yaml despite moderate score (0.52).
Suggest: treat this pair as strong coupling until empirical data matures.
Consider updating the static entry for helm/mcp-server/values.yaml in
planning/file-coupling-map.md to reflect this observed pattern.
```

This creates a feedback loop that improves planning before the commit count
reaches statistical significance.

---

## Implementation phases

### Phase 1 — Script + data file (implement now, before wave work restarts)

Deliverables:
- `scripts/coupling-analysis.sh` — analysis script per spec above
- Initial `planning/coupling-data.json` — generated from current history
- `scripts/README.md` entry — document when and how to run coupling-analysis.sh

Acceptance criteria:
- Script runs on this repo and produces valid JSON with correct `_meta` block
- Known co-change patterns appear in output (rebuild.sh + README.md should score high)
- Outlier commits (> 15 files) are counted in `excluded_commit_count`
- Table output is readable for manual wave planning review
- Runnable via `./scripts/devtools-run.sh ./scripts/coupling-analysis.sh`

### Phase 2 — Agent integration (after Phase 1 script is proven)

Deliverables:
- Branch instruction files updated to include a structured `## Files touched` table
  (machine-parseable, not prose) so the agent can extract file footprints without
  reading the full instruction narrative
- Agent invocation guide in `planning/` — how to invoke the planning agent,
  what inputs to provide, how to interpret output
- `planning/wave-plan-diagram.md` updated to show coupling risk tier alongside
  each branch name

Acceptance criteria:
- Planning agent produces a complete collision analysis for a proposed wave in
  one message, citing coupling scores, confidence tiers, and operating mode
- Agent correctly identifies the rebuild.sh / README.md collision class from
  the current backlog without being told

### Phase 3 — Automation (when workflow is stable)

Deliverables:
- Post-merge script or hook that regenerates `coupling-data.json` after each
  merge to main and commits it automatically
- Optional: coupling data diff summary in PR description template

---

## Constraints and non-goals

- **Non-goal:** real-time coupling computation during a merge. The data file is
  always pre-computed from main history. Agents read the file, not the git log.
- **Non-goal:** coupling analysis across planning documents or branch instruction
  files. Excluded by default. Coupling is for solution artifacts only.
- **Non-goal:** PR-level analysis in Phase 1 or 2. Commit-level is the analysis
  unit. Revisit in Phase 3.
- **Hard constraint:** the planning agent is advisory only, permanently. It
  produces text recommendations; humans approve before any planning file changes.
- **Hard constraint:** `--no-merges` is always on. Merge commits are excluded from
  analysis — on a squash-merge repo they are empty or duplicative.
- **Hard constraint:** `coupling-data.json` is internal only. Do not publish in
  a public repository without security review.
- **Implementation constraint:** script must be bash + git only. No host Python or
  Node dependency. Runnable inside `devtools-run.sh`.

---

## Council decisions (2026-03-27)

| Question | Decision | Rationale |
|----------|----------|-----------|
| Commit vs PR as analysis unit | **Commits** — permanent for Phase 1+2 | No GitHub API dependency; revisit in Phase 3 only if commit-level produces noisy results |
| Threshold calibration | Initial values accepted; recalibrate after Phase 1 generates real data | Thresholds are empirical guesses until we see the distribution |
| Default excluded paths | `planning/**`, `deliverables/**`, `.claude/**` | Administrative and ephemeral paths whose changes do not reflect solution coupling |
| `--max-files-per-commit` default | **15** | Outlier commits (mass-update, reformat) inflate pair counts spuriously; excluded count tracked in `_meta` |
| Agent authority | **Advisory only — hard constraint** | Agent proposes; human approves. Not relaxed as system matures. Control gap risk if agent autonomously restructures wave plans that other agents then execute |
| Mode transition threshold | **30% of relevant pairs in established/mature** | Explicit, deterministic, auditable |
