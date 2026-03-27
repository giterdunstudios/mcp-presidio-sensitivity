---
title: Temporal Coupling Proof-of-Value Experiment
status: ready to run
owner: Engineering Practices Lead
depends_on: BP-027 complete (coupling-analysis.sh + baseline coupling-data.json)
---

# Temporal Coupling — Proof-of-Value Experiment

## Purpose

Validate that the temporal coupling analysis produces actionable signal:
1. Co-change scores shift in the predicted direction after a wave of merges
2. Pairs the model rated as safe were safe; pairs rated as risky conflicted or required coordination
3. The planning agent's collision analysis improves parallelization decisions compared to the static map alone

A null result (scores don't shift, predictions don't hold) would indicate the history
is too thin or the excluded paths are filtering too aggressively — both actionable findings.

---

## Baseline (already captured)

**File:** `planning/coupling-data.json` committed at `eff6993`
**Run date:** 2026-03-27
**Stats:** 72 commits processed, 4 excluded, 77 files tracked, 80 pairs

**Notable strong pairs in baseline (the predictions to validate):**

| Pair | Score | Confidence |
|------|-------|------------|
| `scripts/keycloak-admin.sh` ↔ `scripts/rebuild.sh` | 1.00 | early |
| `helm/presidio-worker/values.local.yaml` ↔ `helm/presidio-worker/values.yaml` | 1.00 | sparse |
| `scripts/rebuild.sh` ↔ `scripts/validate-networkpolicy.sh` | 0.80 | early |
| `scripts/rebuild.sh` ↔ `scripts/setup-local.sh` | 0.80 | early |
| `scripts/README.md` ↔ `scripts/rebuild.sh` | 0.75 | early |

These are the model's claims. The experiment tests them.

---

## Experiment design

### Wave selection

**Wave 1 branches** (#3, #8, #9, #18-19) touch only planning and doc files —
all excluded from the analysis. Running the script after Wave 1 merges will
show a small `commit_count` increase but no meaningful pair score changes.
Wave 1 is a control group — scores should be stable, confirming the exclusion
filter works correctly.

**Wave 2 branches** (#1-2-31, #6, #7, #10, #13) are the primary experiment.
They touch `scripts/rebuild.sh`, `scripts/README.md`, `scripts/setup-local.sh`
— the exact files with strong/moderate baseline scores. After Wave 2 merges,
those pair scores should shift. This is where the model gets tested.

**Wave 3 branches** (#5, #14, #20) all touch `scripts/rebuild.sh` sequentially.
After Wave 3 merges, the `rebuild.sh` pair scores should be among the strongest
in the dataset. This is the expected confirmation round.

### What to measure at each checkpoint

**Checkpoint A — after Wave 1 merges:**
```bash
./scripts/coupling-analysis.sh
git diff HEAD~1 planning/coupling-data.json
```
Expected: `commit_count` increases by ~6, pair scores for solution artifact files
unchanged (only planning files added to history). Validates exclusion filter.

**Checkpoint B — after Wave 2 merges:**
```bash
./scripts/coupling-analysis.sh
git diff HEAD~1 planning/coupling-data.json
```
Expected: `scripts/README.md ↔ scripts/rebuild.sh` score increases (both touched
by multiple Wave 2 branches). `scripts/setup-local.sh` pairs may shift.
New pairs may appear for Wave 2 files that moved together.

**Checkpoint C — after Wave 3 merges:**
```bash
./scripts/coupling-analysis.sh
git diff HEAD~1 planning/coupling-data.json
```
Expected: `scripts/rebuild.sh` becomes the highest-degree node — most other
script pairs will show co-change with it. Strong pairs should move toward
`established` confidence tier as observation count grows.

### Collision tracking

For every parallel group in the wave plan, record the outcome:

| Branch pair | Predicted risk | Actual outcome |
|-------------|---------------|----------------|
| #3 × #8 | SAFE (no shared files) | — |
| #3 × #9 | SAFE | — |
| #8 × #9 | SAFE | — |
| #18-19 × any W1 | SAFE | — |
| #1-2-31 × #7 | SAFE (different files) | — |
| #6 × #10 | SAFE (rebuild.sh vs setup-local.sh) | — |

Fill in "Actual outcome" as each wave merges. A clean merge = prediction held.
A conflict = prediction missed. Both are useful data.

---

## Success criteria

The experiment is considered to have produced proof of value if **all three** hold:

1. **Score shift:** At least 3 file pairs show a coupling score change ≥ 0.05
   between Checkpoint A and Checkpoint C. Scores moving in the predicted
   direction (files that moved together in the wave score higher).

2. **No false negatives in safe pairs:** Zero merge conflicts in pairs the model
   rated as SAFE to parallelize. If a conflict occurs in a pair rated safe,
   the model missed a signal — investigate why.

3. **Confidence tier progression:** At least one pair moves from `sparse` to
   `early`, or `early` to `established`. This confirms the history is
   accumulating signal at a useful rate.

### Partial success

If (1) and (3) hold but (2) has one miss: note it, add the pair to the static
coupling map as a known gap, and continue to Phase 2. One miss does not
invalidate the approach — it improves the static prior.

### Null result

If scores don't shift after Wave 2 and 3 merges, possible causes:
- Waves are too small (not enough commits to move needles) — wait for Wave 4
- Excluded paths filter is removing too much — review with `--exclude-paths ""`
- Baseline history is too concentrated in planning commits — check
  `excluded_commit_count` to see if outlier filter is over-aggressive

---

## Comparison methodology

After each checkpoint, run:

```bash
# Regenerate
./scripts/coupling-analysis.sh

# View what changed
git diff planning/coupling-data.json

# Focused: only pairs whose scores changed
git diff planning/coupling-data.json | grep '"coupling_score"'

# Table view filtered to strong + moderate
./scripts/coupling-analysis.sh --format table | grep -E "strong|moderate"
```

To compare baseline directly to a checkpoint:
```bash
git show eff6993:planning/coupling-data.json > /tmp/baseline.json
python3 -c "
import json, sys
a = json.load(open('/tmp/baseline.json'))
b = json.load(open('planning/coupling-data.json'))
a_map = {(p['file_a'],p['file_b']): p['coupling_score'] for p in a['pairs']}
b_map = {(p['file_a'],p['file_b']): p['coupling_score'] for p in b['pairs']}
all_keys = set(a_map) | set(b_map)
changed = [(k, a_map.get(k,0), b_map.get(k,0)) for k in all_keys if abs(a_map.get(k,0) - b_map.get(k,0)) >= 0.05]
for k,before,after in sorted(changed, key=lambda x: abs(x[2]-x[1]), reverse=True):
    print(f'{after:.3f} (was {before:.3f})  {k[0]}  ->  {k[1]}')
"
```

---

## Next steps after proof received

### Immediate (within same session as Checkpoint C)

1. **Record outcome in this file** — fill in the collision tracking table,
   note which predictions held and which missed.

2. **Tag the post-Wave-3 state** — `git tag post-wave-3-coupling-proof` so the
   experiment baseline is preserved in git history.

3. **Update the static coupling map** — any pair the temporal analysis confirmed
   as strong that isn't already in `file-coupling-map.md` should be added.
   Any pair the static map predicted as coupled that never appeared in the
   temporal data can be downgraded from "also review" to a footnote.

### Short-term (next planning session)

4. **Start BP-028 Phase 2** — structured `## Files touched` tables in branch
   instructions + planning agent invocation guide. With the proof in hand,
   the agent integration has validated data to work from.

5. **Add lift metric to coupling-analysis.sh** — the high-frequency scripts
   (rebuild.sh, setup-local.sh, status.sh) appear in many pairs simply because
   they change often. Lift normalises for this: `lift = coupling_score / P(B)`.
   Pairs with high coupling score but lift ≈ 1.0 are frequency noise, not real
   coupling. This sharpens wave planning.

   Add to script output:
   ```
   lift = coupling_score / (observations_b / total_commits)
   ```

6. **Review `role-instructions/ways-of-working.md`** — it appears in the current
   coupling data (co-changes with scripts and helm values). Confirm whether it
   should be added to the default excluded paths or left in as a legitimate
   coupling signal.

### Medium-term (Phase 2 of BP-028)

7. **Decay weighting** — commits older than 90 days weighted at 0.5×; older
   than 180 days at 0.25×. Recent coupling patterns matter more than historical
   ones that may reflect a different architecture. Implement as
   `--decay-half-life N` flag.

8. **Cluster detection** — files that form tight co-change clusters (all pairs
   within the cluster score ≥ 0.60) are candidates for co-location or
   co-ownership review. Surface as a separate section in table output.

9. **Post-merge hook** — automate the `coupling-analysis.sh` regeneration after
   each merge to main. The hook runs the script and commits the updated JSON
   as a follow-on commit. This removes the manual step entirely.

### If proof is NOT received

If the experiment produces a null result after Wave 3:

- Do not start BP-028 agent integration until the signal improves
- Increase wave cadence — run smaller, more frequent waves to accumulate commits faster
- Review outlier filter: run `./scripts/coupling-analysis.sh --max-files-per-commit 30`
  and compare — if significantly more pairs appear, the default of 15 may be too aggressive
  for this repo's commit style
- Revisit after 20+ more commits — the `early` confidence tier (5–19 observations)
  is the threshold where the signal becomes directionally useful
