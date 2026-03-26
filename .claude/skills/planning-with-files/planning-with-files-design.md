# Planning-with-Files Skill — Design Document
**For: Claude.ai (claude.ai chat interface)**  
**Based on: OthmanAdi/planning-with-files v2.22.0**  
**Output format default: Markdown (.md)**

---

## 1. Design Overview

### Core Philosophy
> Context Window = RAM (volatile, limited)  
> Filesystem = Disk (persistent, unlimited)  
> → Anything important gets written to disk.

The skill adapts the Manus-style planning pattern for claude.ai. Since claude.ai lacks Claude Code's hook system (no PreToolUse/PostToolUse/Stop bash hooks), all hook behaviors are **baked directly into the skill's instructions** as explicit rules Claude must follow during every session.

---

### What Changes from the Original

| Original (Claude Code) | Claude.ai Adaptation |
|------------------------|----------------------|
| Bash hooks auto-run before/after tools | Explicit rules Claude follows manually |
| `session-catchup.py` script | Manual session recovery checklist |
| `init-session.sh` script | Claude creates files directly via `create_file` tool |
| `check-complete.sh` stop hook | Claude self-checks before declaring done |
| Plugin install via `npx` / `/plugin` | Installed via `.skill` file upload in settings |
| Files written to project directory | Files written to `/mnt/user-data/outputs/` and presented to user |

---

### The 3-File Pattern (Unchanged)

Every complex task begins with creating these three files:

```
task_plan.md    → Phases, progress, decisions, errors
findings.md     → Research, discoveries, notes
progress.md     → Session log, what was done, test results
```

---

## 2. Skill Architecture

### SKILL.md Structure

```
planning-with-files/
├── SKILL.md               ← Core instructions (what we're building)
├── templates/
│   ├── task_plan.md       ← Phase tracking template
│   ├── findings.md        ← Research storage template
│   └── progress.md        ← Session log template
└── references/
    └── examples.md        ← Real-world usage examples
```

### Trigger Conditions
The skill activates when the user:
- Starts a software project or multi-step task
- Says "plan this", "let's build", "create a roadmap"
- Describes a task with 3+ steps
- Uploads docs and asks Claude to act on them
- Asks for research + implementation together

### What the Skill Instructs Claude to Do

**On session start:**
1. Check if planning files already exist (session recovery)
2. If yes → read them and produce a catchup summary before proceeding
3. If no → create all 3 files from templates immediately

**During work (replacing PreToolUse hook):**
- Before any major decision: re-read `task_plan.md` (top 30 lines)
- After every 2 read/search/fetch operations: write findings to `findings.md`
- After completing any phase: update phase status in `task_plan.md`

**On errors (3-Strike Protocol):**
- Attempt 1: Diagnose and fix
- Attempt 2: Different approach, never repeat exact same action
- Attempt 3: Broader rethink, question assumptions
- After 3 failures: Stop and explain to user, ask for guidance

**Before finishing (replacing Stop hook):**
- Self-check: Are all phases marked complete?
- If any phase is `in_progress` or `not_started` → do not declare done
- Present final planning files to user for download

---

## 3. Expected Workflows

### Workflow A — New Project (Most Common)

```
User: "I want to build a [project]. Here's my plan..."
  ↓
Skill triggers
  ↓
Claude: "Starting planning session. Creating 3 files..."
  ↓
Creates: task_plan.md, findings.md, progress.md
  ↓
Presents files to user
  ↓
Begins Phase 1, re-reads plan before each major decision
  ↓
After every 2 operations → writes to findings.md
  ↓
Phase complete → updates task_plan.md checkbox
  ↓
Repeat until all phases done
  ↓
Self-check all phases complete
  ↓
Presents final updated files to user
```

### Workflow B — Session Recovery

```
User starts new chat, references previous work
  ↓
Claude: "Do you have planning files from a previous session?"
  ↓
User uploads task_plan.md / findings.md / progress.md
  ↓
Claude reads all 3, produces catchup summary:
  - Where we left off
  - What was completed
  - What's next
  ↓
Continues from correct phase
```

### Workflow C — Mid-Task Error Handling

```
Action fails
  ↓
Claude logs error to task_plan.md Errors table
  ↓
Attempt 2: Different approach
  ↓
If fails again → logs, tries Attempt 3
  ↓
After 3 failures → surfaces to user with full error log
  ↓
User decides: adjust approach, provide info, or skip
```

### Workflow D — Research Task

```
User: "Research X and then build Y"
  ↓
task_plan.md created with Phase 1 = Research, Phase 2 = Build
  ↓
Phase 1: Every 2 searches/fetches → write to findings.md
  ↓
Phase 1 complete → mark done, update task_plan.md
  ↓
Phase 2: Uses findings.md as source of truth (not context)
  ↓
Avoids context stuffing — findings persist on disk
```

---

## 4. Testing Approach

Since we're on claude.ai (no subagents), testing is **qualitative and iterative** — you review outputs directly in chat.

### Test Cases (5 Scenarios)

#### Test 1 — Basic Trigger
**Prompt:** "I want to build a personal finance tracker app. Help me plan it out."  
**Expected:** Skill triggers, 3 files created immediately, phases defined, files presented.  
**Pass criteria:** All 3 files exist, task_plan.md has at least 3 phases, no work started before planning.

#### Test 2 — 2-Action Rule Compliance
**Prompt:** "Research the best React state management libraries and summarize your findings."  
**Expected:** After every 2 searches, Claude writes to findings.md before continuing.  
**Pass criteria:** findings.md is updated mid-task, not just at the end.

#### Test 3 — Session Recovery
**Prompt:** Upload a previous `task_plan.md` and say "Continue where we left off."  
**Expected:** Claude reads the file, produces a catchup summary, resumes from correct phase.  
**Pass criteria:** Claude correctly identifies completed vs incomplete phases.

#### Test 4 — Error Logging
**Prompt:** Give Claude a task where one step will fail (e.g., fetch a bad URL).  
**Expected:** Error logged in task_plan.md errors table, alternative approach taken.  
**Pass criteria:** Error appears in file, Claude does not repeat the exact same action.

#### Test 5 — Completion Gate
**Prompt:** Ask Claude to stop early before all phases are done.  
**Expected:** Claude flags that phases are incomplete before wrapping up.  
**Pass criteria:** Claude does not present work as done with open phases remaining.

### Review Method
For each test:
1. Run the prompt in a fresh chat with the skill installed
2. Download the output `.md` files
3. Check pass criteria manually
4. Note anything to improve → feed back into SKILL.md iteration

### Iteration Loop
```
Draft SKILL.md → Run 5 test cases → Review outputs → 
Note failures → Update SKILL.md → Repeat until all 5 pass
```

---

## 5. Rollout Strategy

### Phase 1 — Build & Package (We do this now, in this chat)
- [ ] Write `SKILL.md` with claude.ai-adapted instructions
- [ ] Write 3 template files (`task_plan.md`, `findings.md`, `progress.md`)
- [ ] Write `examples.md` reference file
- [ ] Package as `.skill` file
- [ ] Present `.skill` file for download

### Phase 2 — Install the Skill
1. Download the `.skill` file from this chat
2. Go to **Claude.ai → Settings → Skills**
3. Upload the `.skill` file
4. Confirm it appears in your skills list as `planning-with-files`

### Phase 3 — Smoke Test (First Real Use)
- Start a new chat
- Describe your software project
- Confirm the skill triggers and creates the 3 files
- Download and inspect `task_plan.md`
- If something's off, bring the file back here and we iterate

### Phase 4 — Use on Your Project
- Every new complex task → skill auto-triggers
- Planning files get created and presented at each session
- You build up a library of past `task_plan.md` files you can reuse for session recovery

### Phase 5 — Iterate & Improve (Ongoing)
- After a few real uses, note what's missing or annoying
- Come back, describe the issue, we update the `SKILL.md` and repackage
- The skill evolves with your workflow

---

## 6. Key Constraints & Decisions

| Decision | Rationale |
|----------|-----------|
| Default all docs to `.md` | Portable, version-controllable, convertible to docx/pdf/pptx |
| No bash hooks | Not supported in claude.ai; behavior baked into instructions instead |
| Files go to `/mnt/user-data/outputs/` | Only location user can download from in claude.ai |
| Session recovery is manual (upload files) | No filesystem persistence between claude.ai sessions |
| 3-Strike before escalating | Prevents infinite loops, keeps user informed |

---

*Ready to proceed to build once you confirm this design.*
