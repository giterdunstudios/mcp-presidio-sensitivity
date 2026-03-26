---
name: planning-with-files
version: "1.1.0"
description: >
  Use for any task requiring 3+ steps or multiple sessions. Creates and maintains
  task_plan.md, findings.md, and progress.md as persistent working memory —
  writing decisions, findings, and progress to files rather than holding state
  in context. Triggers on: multi-step projects, "plan this", "let's build",
  "create a roadmap", session recovery from uploaded planning files,
  or when the user references previous planning files by URL.
default-output-format: markdown
---

# Planning with Files

Work like Manus: use persistent markdown files as your "working memory on disk."
Every important thought, finding, decision, and error gets written to a file —
not held in context.

```
Context Window = RAM  (volatile, limited)
Filesystem     = Disk (persistent, unlimited)

→ Anything important gets written to disk.
```

---

## FIRST: Session Recovery Check

Before starting any work, ask:

> "Do you have planning files from a previous session?
> If so, please paste the contents of task_plan.md, findings.md, and progress.md
> — or share the raw GitHub URLs and I'll fetch them."

If previous files are provided:
1. Read all 3 files
2. Produce a **Catchup Summary**:
   - Phases completed ✅
   - Current phase and where it left off
   - Key findings so far
   - Errors previously encountered
   - What comes next
3. Confirm with user before proceeding
4. Continue from the correct phase — never restart from zero

If no previous files exist → proceed to Quick Start.

---

## Quick Start (New Session)

Before ANY complex task, create all 3 planning files immediately.
Do not begin executing work until all 3 files exist.

Use the templates below. Fill in the task name, goal, and phases
based on what the user has described.

---

## The 3 Files

### File 1 — task_plan.md template

```markdown
# Task Plan: [Task Name]

## Goal
[One sentence: what does success look like?]

## Phases

### Phase 1: [Name]
**Status:** `not_started` | `in_progress` | `complete` | `blocked`
**Goal:** [What this phase achieves]
**Steps:**
- [ ] Step 1
- [ ] Step 2
- [ ] Step 3
**Output:** [What file or result this phase produces]

### Phase 2: [Name]
**Status:** `not_started`
**Goal:**
**Steps:**
- [ ]
**Output:**

### Phase 3: [Name]
**Status:** `not_started`
**Goal:**
**Steps:**
- [ ]
**Output:**

---

## Decision Log
> **Mandatory.** Every project must maintain this log. Every decision must have a source.

| # | Decision | Rationale | Source | Date |
|---|----------|-----------|--------|------|
| 1 | | | | |

**Source types:**
- `spec` — from the project specification or brief
- `user` — stated by the user in conversation
- `research:[url or tool]` — from web search or fetched document
- `agent-reasoning` — Claude's own analysis (use sparingly, prefer cited sources)
- `prior-session` — carried forward from a previous planning session

## Errors Encountered
| Error | Attempt # | Resolution |
|-------|-----------|------------|
| | | |

## Notes
[Anything else worth tracking]
```

---

### File 2 — findings.md template

```markdown
# Findings: [Task Name]

## Summary
[Running 1-3 sentence summary of key discoveries. Update as you go.]

---

## Research Findings

### [Topic / Source]
- Finding 1
- Finding 2
- Finding 3

### [Topic / Source]
- Finding 1

---

## Key Decisions Informed by Findings
| Finding | Decision It Drove |
|---------|-------------------|
| | |

---

## Open Questions
- [ ] Question 1
- [ ] Question 2
```

---

### File 3 — progress.md template

```markdown
# Progress Log: [Task Name]

## Session: [Date / Session #]

### What Was Done
- [Action taken]
- [Action taken]

### Files Created / Modified
| File | Change |
|------|--------|
| | |

### Test Results
| Test | Result | Notes |
|------|--------|-------|
| | | |

### What's Next
- [ ] Next action

---

## Previous Sessions
[Append new sessions above this line]
```

---

## Core Rules

### Rule 1 — Plan First, Always
Never begin executing a complex task without first creating `task_plan.md`.
This is non-negotiable. The plan comes before the first tool call.

### Rule 2 — The 2-Action Rule
After every 2 read / search / fetch operations, immediately write key
findings to `findings.md` before continuing. Do not let discoveries
accumulate in context — write them to disk.

```
search → search → WRITE TO findings.md → search → search → WRITE → ...
```

### Rule 3 — Read Before Deciding
Before any major decision or before starting a new phase,
re-read the top of `task_plan.md`. This keeps goals in the attention window
and prevents drift.

### Rule 4 — Update After Each Phase
When a phase completes:
- Change status from `in_progress` → `complete`
- Check off all completed steps
- Note any output files produced
- Log any errors in the Errors table

### Rule 5 — Log ALL Errors
Every error, failure, or dead end goes into the Errors table in `task_plan.md`.
No silent retries. No hidden failures.

### Rule 6 — Never Repeat Failures
```
if action_failed:
    next_action != same_action
```
Track what was tried. Mutate the approach before retrying.

### Rule 7 — Decision Log is Mandatory
Every project has a Decision Log in `task_plan.md`. Every decision must be recorded with:
- The decision made
- The rationale behind it
- The **source** backing it (spec, user, research URL, agent-reasoning, or prior-session)
- The date

No decision is valid until it is logged. "Agent-reasoning" as a source should be used
sparingly — prefer cited specs, user statements, or research.

### Rule 8 — Role Instructions Must Always Be Present
For any project involving multiple agents or roles, each role must have a
clearly defined instruction package covering:
- Role name and responsibility scope
- Specific deliverables expected
- Inputs they receive
- Outputs they produce
- Constraints and boundaries

Role instructions are produced at the start of Phase 0 and updated whenever
scope changes. They are stored as part of the planning file set.

```
ATTEMPT 1 — Diagnose & Fix
  → Read the error carefully
  → Identify root cause
  → Apply a targeted fix
  → Log in Errors table

ATTEMPT 2 — Alternative Approach
  → Same error? Try a completely different method
  → Different tool, library, or strategy
  → NEVER repeat the exact same failing action
  → Log in Errors table

ATTEMPT 3 — Broader Rethink
  → Question assumptions
  → Search for solutions
  → Consider updating the plan itself
  → Log in Errors table

AFTER 3 FAILURES — Escalate
  → Stop
  → Explain to the user what was tried
  → Share the specific error
  → Ask for guidance before continuing
```

---

## Read vs Write Decision Matrix

| Situation | Action |
|-----------|--------|
| Just wrote a file | DON'T re-read it — it's in context |
| Completed a web search or fetch | Write findings to findings.md NOW |
| Starting a new phase | Re-read task_plan.md first |
| An error occurred | Read relevant file for current state |
| Resuming after any gap | Read all 3 planning files |
| About to make a major decision | Re-read task_plan.md |

---

## The 5-Question Reboot Test

Before declaring a task complete, verify you can answer all 5:

| Question | Answer Source |
|----------|---------------|
| Where am I in the plan? | Current phase in task_plan.md |
| Where am I going? | Remaining phases |
| What is the goal? | Goal statement in task_plan.md |
| What have I learned? | findings.md |
| What have I done this session? | progress.md |

If you cannot answer any of these from the files → update the files before finishing.

---

## Completion Gate (replaces Stop hook)

Before presenting work as done:
1. Check every phase in `task_plan.md`
2. If ANY phase is `not_started` or `in_progress` → do not declare done
3. Update `progress.md` with what was accomplished this session
4. Present all 3 updated planning files to the user for download
5. Suggest they save these files and commit to their repo for next session

---

## Session Handoff Instructions (End of Every Session)

Tell the user:

> "Here are your 3 updated planning files. To continue in a future session:
> 1. Save these files (or commit them to your repo)
> 2. Start a new chat and paste this URL to load the skill:
>    `https://raw.githubusercontent.com/giterdunstudios/quick-custom-skills/main/.claude/skills/planning-with-files/SKILL.md`
> 3. Share your planning files and I'll pick up exactly where we left off."

---

## When to Use This Skill

**Use for:**
- Software / app projects
- Multi-step research tasks
- Anything requiring 3+ steps or tool calls
- Tasks that will span multiple chat sessions
- Building, designing, planning, creating

**Skip for:**
- Simple one-off questions
- Single file edits
- Quick lookups

---

## Anti-Patterns

| Don't | Do Instead |
|-------|------------|
| Start executing before planning | Create task_plan.md first |
| Hold findings only in context | Write to findings.md every 2 operations |
| Retry the same failed action | Log it, mutate the approach |
| Declare done with open phases | Check all phases before finishing |
| Forget what session this is | Update progress.md throughout |
| Start from scratch next session | Use session recovery from saved files |
