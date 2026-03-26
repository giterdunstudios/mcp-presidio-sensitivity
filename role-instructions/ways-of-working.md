# Ways of Working: MCP + Presidio Sensitivity Classification
**Version:** 1.0 — Session 4
**Applies to:** All contributors — human and agent

---

## Purpose

This document defines how this project is approached, governed, and organized.
Read it before doing any work. It is the shared operating agreement for the team.

---

## 1. Working method

All work on this project follows this sequence:

1. **Clarify intent** — Understand what is actually being decided, tested, built, or proven. Do not begin solutioning before the real objective is clear.
2. **Decompose** — Break the problem into meaningful components. Separate foundational concerns from peripheral ones.
3. **Assess feasibility** — Determine what is practical now, what is constrained, and what should be deferred.
4. **Plan** — Build a path forward with assumptions made explicit, not hidden inside the plan.
5. **Validate direction** — Confirm with the operator at defined checkpoints before committing significant effort.
6. **Iterate** — Reassess assumptions. Revise structure and priorities as understanding develops.

### Condensed form
> **clarify intent → decompose → assess feasibility → plan → validate direction → iterate**

This sequence is not a rigid waterfall. It is a thinking discipline. Each step informs the next, and any step can trigger a return to an earlier one when new understanding emerges.

---

## 2. Governance principle

> **Stay lean, specialize deliberately, and parallelize only when it earns its cost.**

In practice, this means:
- Do not create roles because concerns exist — create them because a concern is large enough to justify a dedicated owner
- Do not start parallel work while the objective is still being shaped
- Stay mostly serial while direction is unclear — one good decision at a time is faster than three uncertain ones in parallel
- Parallelize only when work lanes are genuinely independent and the speed gain or rework reduction is real
- Stay compute-conscious and cost-conscious throughout

---

## 3. Priority stack

When there is tension between competing concerns, resolve it in this order:

1. **Correctness and bounded behavior** — The system must not leak payload data under any condition, including failure paths. This is the non-negotiable foundation of the product.
2. **Security integrity** — All security controls must hold before anything ships. No phase is complete without security sign-off.
3. **Operational reliability** — The service must be auditable, traceable, and stable under expected conditions.
4. **Expansion only where evidence justifies it** — New capabilities, content types, and classification depth are added only when there is a demonstrated need.

Speed is a valid concern but is never the top priority. A fast delivery that compromises correctness or security is worse than a slower one that does not.

---

## 4. Council structure

The project operates with a small, deliberate council. Roles are created only when the concern is large enough to justify a dedicated owner.

---

### 4.1 Core roles

#### Role 1 — Product / Scope Lead

**Owns:**
- Objective clarity and phase boundaries
- What is in and out of scope for each phase
- Managing deferred items and defining when they should be re-evaluated
- Operator confirmation checkpoints
- Decision log maintenance

**Why this role exists:**
Prevents build effort from drifting away from the defined phase boundary and from reopening settled decisions without justification. This role is the connective tissue between the spec and what actually gets built.

**Failure mode prevented:**
A technically thorough implementation that builds beyond what the current phase requires, or that solves a question the operator has not yet confirmed.

---

#### Role 2 — Security / Privacy Lead

**Owns:**
- Trust model and trust boundary definition
- Payload handling rules — what is logged, stored, and retained at every stage
- Audit schema design
- Recognizer and policy bundle governance
- Review and sign-off of all security controls before any phase ships
- Failure path analysis — confirming that no payload leaks under error, timeout, or rejection conditions

**Why this role exists:**
Security is architecturally central to this project, not a compliance step added at the end. The core design principle is that the MCP server and orchestrator enforce the trust boundary — not Presidio. This role protects that boundary from being eroded by implementation decisions made under time pressure.

**Failure mode prevented:**
A working scanner that leaks payload data on a scan timeout, logs matched substrings inside an error message, or ships without enforcing caller authentication.

> **Note for all contributors:** Presidio is a detection tool, not a security control. Do not treat Presidio's behavior as the boundary. The orchestration layer owns trust.

---

#### Role 3 — Technical Implementation Lead

**Owns:**
- MCP server architecture and orchestration design
- Ephemeral worker design and lifecycle management
- Presidio integration pattern (embedded library mode preferred — see spec §3.4)
- Deployment topology and environment design (dev / test / production)
- Build sequencing and module boundaries
- Anti-complexity guardrails
- Integration and API contract ownership (absorbed until a dedicated split is justified — see §4.3)

**Why this role exists:**
Turns the specification into a shippable, maintainable system while protecting against accidental complexity and scope blowout.

**Failure mode prevented:**
Overengineering before the core scanning path is proven, or underspecifying isolation boundaries in a way that creates security or reliability risks downstream.

---

### 4.2 Optional surge role — Detection / Data Researcher

**Activate only when needed for:**
- Evaluating Presidio recognizer quality against the target data types for this project
- Assessing false-positive and false-negative behavior using synthetic or real test data
- Evaluating multilingual support requirements
- Benchmarking new content type handling
- Generating empirical observations that feed the deferred classification policy model (see spec §6)

**Why this role is optional:**
This concern is real but not required in every cycle. Activating it before there is actual detector output to analyze produces speculative findings that may not survive contact with real behavior. Activate when evidence-gathering is the specific goal.

---

### 4.3 Future role — Integration / API Lead

**Not active now.** Currently absorbed by the Technical Implementation Lead.

**What this role will own when activated:**
- Tool contract stability and versioning
- Caller experience and API consumer requirements
- Schema design from a consumer perspective
- Error handling from the caller's point of view

**Trigger this split when any of the following occur:**
- Multiple distinct caller types exist with meaningfully different contract requirements
- The API surface grows to the point where consumer experience is a dedicated design concern
- A dedicated external team or integration partner is consuming the tool

---

### 4.4 Anti-sprawl rule

The following concerns exist but must not become permanent standing roles at this stage:

- Compliance specialist
- Data governance analyst
- Platform / infrastructure engineer
- QA / test engineer
- DevOps / release engineer
- Classification policy analyst

These concerns are real and will matter at later phases. Absorb them into the three core roles until there is a clear, specific reason to separate them. Creating roles prematurely adds coordination overhead without adding delivery speed.

---

### 4.5 Engineering Practices Lead

**Status:** Permanent core role (5th standing member). Ratified by council 2026-03-26.

**Owns:**
- Best practices backlog (`planning/best-practices-backlog.md`) — cross-cutting items that don't belong exclusively to any one role
- Team workflow health: monitoring that all roles are producing, unblocked, and coordinating effectively
- Communication standards: how the team communicates decisions, handoffs, and state across roles and sessions
- Onboarding standards: ensuring the project can be picked up by a new contributor without tribal knowledge — documentation quality, setup reproducibility, orientation materials
- `ways-of-working.md` maintenance — keeping the shared operating agreement current as the team evolves
- Testing strategy: what gets tested, at what level (unit / integration / e2e), and what the exit gate looks like for each phase
- Dev environment reproducibility: setup-from-scratch capability, prerequisite documentation, disaster recovery of the local stack
- Dev/prod parity standard: defines the acceptable delta between local dev and production topology; flags when simplifications cross the line into risk
- Coordination scheduling: when a best practices item requires collaboration across roles, this role owns getting that scheduled — does not block delivery, prioritises timing
- Temporary ownership: on a small team, this role may carry temporary ownership of items that have no natural home, until a permanent owner is identified

**Does NOT own by default:**
- Security control design or sign-off (Security / Privacy Lead)
- Governance security artifacts — e.g. SBOM (`bom.json`) is owned and signed off by Security / Privacy Lead
- Application architecture decisions (Technical Implementation Lead)
- Scope and phase boundaries (Product / Scope Lead)
- Test *implementation* for a specific feature — each role implements tests for their own work items; this role owns the coverage standard and strategy, not the code

**Relationship to other core roles:**
- With Security / Privacy Lead: coordinates on testing strategy for security controls and on what best practices gates are required before phase exit; does not own security artifacts
- With Technical Implementation Lead: dev/prod parity decisions and reproducibility — Phase 2 (Istio, Cilium) will create pressure on the parity boundary; this role watches for drift
- With Product / Scope Lead: best practices gates are part of phase exit criteria; this role surfaces what is owed at each gate and whether the team's workflows are healthy enough to sustain the next phase

**Failure mode prevented:**
A team that is producing code but not communicating state effectively; a project that cannot be onboarded onto by a new contributor; a dev environment that cannot be rebuilt from scratch; a set of workflows that have drifted from best practices with no one watching.

**Anti-sprawl justification (why this separation is warranted):**
The concern is team workflow health and institutional knowledge — not any single technical deliverable. As the project grows across phases, the risk is that each role optimises locally and no one owns the connective tissue: how we communicate, how we onboard, whether our workflows are reproducible and transparent. That concern is large enough, ongoing enough, and orthogonal enough to the three core technical roles to warrant a dedicated owner.

---

## 5. Stage-gated workflow

Work progresses through stages in sequence. Each stage has a defined confirmation point with the operator before the next stage begins. Do not skip stages. Do not begin the next stage before the confirmation point is reached.

---

### Stage 1 — Intent shaping

**Primary active role:** Product / Scope Lead

**Questions this stage answers:**
- What is this system actually trying to prove, enforce, or protect against?
- Who is calling this tool, and in what integration context?
- What does a good first delivery actually look like?

**Outputs:**
- Objective statement
- Confirmed caller identity and integration context
- First-delivery thesis

**Confirmation point:**
Operator confirms direction before decomposition deepens. This is the most important checkpoint — an incorrect objective wastes everything that follows.

---

### Stage 2 — Decomposition

**Primary active roles:** Product / Scope Lead, Technical Implementation Lead, Security / Privacy Lead

**Questions this stage answers:**
- What is foundational versus optional versus Phase 2+?
- What are the real complexity and security risks?
- What belongs in Phase 0 versus Phase 1?

**Outputs:**
- Component and responsibility boundaries
- Phase scope refined and confirmed
- Risk list

**Confirmation point:**
Operator can cut scope or redirect before build planning hardens.

---

### Stage 3 — Feasibility and sequencing

**Primary active roles:** Technical Implementation Lead, Security / Privacy Lead

**Questions this stage answers:**
- What can be built fastest without compromising the bounded behavior contract?
- What security and auditability controls must be in place from day one?
- Where are the real implementation traps?

**Outputs:**
- Confirmed build sequence
- Security controls confirmed for the current phase
- Technical assumptions made explicit

**Confirmation point:**
Speed versus depth trade-offs confirmed before engineering execution begins.

---

### Stage 4 — Implementation plan

**Primary active roles:** All core roles

**Questions this stage answers:**
- What exactly are we building in this phase?
- What are the module boundaries?
- What does each contributor build, and in what order?
- What assumptions are still unresolved?

**Outputs:**
- Implementation plan
- Work breakdown
- Handoff map
- Unresolved assumptions list

**Confirmation point:**
Strong checkpoint before concrete engineering execution becomes committed.

---

### Stage 5 — Iteration and learning

**Primary active roles:** Product / Scope Lead, Technical Implementation Lead

**Questions this stage answers:**
- What signals matter after this phase ships?
- What results trigger Phase 2 work?
- What detector behavior observations should feed the deferred classification policy?

**Outputs:**
- Phase 2 trigger conditions
- Observation inputs for the deferred classification model
- Iteration backlog

---

## 5a. Spec completeness standard

A spec is not ready for implementation if any of the following are missing where applicable. Any council member reviewing a spec — or any contributor assisting with planning — must call out missing elements before implementation begins. Do not proceed to implementation with an incomplete spec.

---

### Required elements

**1. Burst role definition**

If the work requires specialized knowledge outside the three core roles, define the burst role before the spec is accepted:
- Activation trigger — what specifically justifies it
- Owned scope — what this role owns and does not own
- Deactivation condition — when the role is dissolved

**2. Council role assignments**

Every spec must state which core council roles are in scope and what they own for this work. Roles not listed are not responsible.

**3. Handoff contract**

If implementation has waves or phases where early work unblocks later work, the handoff contract must be explicitly stated before Wave 2 agents begin:
- What decisions or outputs must exist
- Who publishes them
- What downstream agents cannot start without them

**4. Parallel lanes**

If Wave 2+ work can be parallelized, each lane must define:
- Scope (what it does)
- Files touched (non-overlapping with other lanes)
- Dependencies satisfied by the handoff contract

---

### Enforcement

- Any council member may block a spec from proceeding to implementation if required elements are absent.
- When assisting with planning, proactively identify and flag missing elements — do not wait to be asked.
- The k3d migration spec (`planning/k3d-migration-spec.md`) is the reference implementation of this standard.

---

## 5b. Council workboard and awareness standard

All active roles maintain a section in `planning/council-workboard.md`. This file is required reading at the start of every session (see §10).

### Per-role format

```
## [Role Name]
### Active
- [work item] — note, any cross-role dependency

### Queued
- [work item] — waiting for: [role or condition]

### Needs coordination
- [work item] — requires: [roles], proposed timing: [phase / gate / session]
```

### Protocol

- Any role updates their section when starting or completing a work item.
- When a work item has a cross-role dependency, the initiating role adds it to `Needs coordination` and tags the relevant role(s).
- The tagged role acknowledges by adding the item to their own `Queued` section with a timing note.
- Engineering Practices Lead reviews the full board at each session start and flags stale, unacknowledged, or blocked coordination items to the council.
- Completed items are removed from the board; they do not need to be archived here (git history is sufficient).

---

## 5c. Council meetings

Council meetings are **impromptu** — they have no fixed cadence. Any role may call one. They are used for high-level and strategic discussion, not day-to-day implementation decisions.

### When to call a council meeting
- A new role is being proposed or ratified
- A decision is being reversed or significantly modified
- A phase boundary or exit criteria is in dispute
- A best practices item has been raised and **no role is willing to schedule it for valid project reasons** (see escalation rule below)
- A critical flag has been raised (see individual decision entries in `planning/decision-log.md`)
- Strategic direction needs alignment before a phase begins

### Best practices escalation rule

If a best practices item is proposed by the Engineering Practices Lead and all roles decline to schedule it — each for valid, documented project reasons — the item must be raised at the next council meeting. It does not go silently into the backlog indefinitely. At the council meeting, the item is either:
1. Scheduled with an agreed timing, or
2. Explicitly deferred with a documented rationale and a re-evaluation trigger (phase gate, external event, or date)

A best practices item may only be permanently closed without implementation if the full council agrees it is no longer relevant. "We don't have time" is not sufficient — it must become a documented deferral with a trigger.

### Meeting outputs
- Decisions logged in `planning/decision-log.md` with source `council-meeting`
- Updated entries in `planning/council-workboard.md` where scheduling was agreed
- `ways-of-working.md` updated if the meeting changed a standing rule

---

## 6. Parallelism rules

### Stay serial when:
- The objective or caller context is still unresolved
- A confirmation checkpoint could invalidate the work in progress
- Multiple roles would be analyzing the same unresolved question at the same time
- Security controls have not yet been confirmed for the current phase

### Use parallel work when:
- Work lanes are genuinely independent
- Each lane can produce a meaningful output without blocking the others
- Outputs will survive the next confirmation checkpoint
- The speed gain or rework reduction is real and specific

### Good examples of justified parallelism (Phase 1+):
- MCP server skeleton development and worker design after the tool contract is fixed
- Security control review and deployment topology design after the architecture is confirmed
- Audit schema design and result minimizer design after the output schema is fixed

### Bad examples of unjustified parallelism:
- Multiple roles defining the same vague MVP boundary simultaneously
- Security review before the architecture is stable enough to review
- Detection research before there is actual scanner output to evaluate

---

## 7. Handoff protocol

When a role completes their stage deliverables:

1. Commit all output documents to the repo
2. Log all decisions made to the Decision Log in `task_plan.md`
3. Update the phase status in `task_plan.md`
4. Explicitly notify the operator and the next role that the handoff is ready — do not assume it is inferred

### What each handoff must carry

**Product / Scope Lead → all roles:**
- Confirmed objective statement
- Confirmed caller identity and integration context
- Phase scope and boundaries
- Success criteria for the current phase

**Security / Privacy Lead → Technical Implementation Lead:**
- Confirmed trust model
- Required security controls for the current phase
- Payload handling rules
- Audit schema requirements

**Technical Implementation Lead → all downstream work:**
- Module map and system interfaces
- Build order
- Technical assumptions in force
- Placeholder and stub guidance

---

## 8. Decision log

All decisions are recorded in `task_plan.md` under the Decision Log section.

**Format:** `| # | Decision | Rationale | Source | Date |`

**Source types:** `spec` | `user` | `research:[url]` | `agent-reasoning` | `prior-session`

**Rules:**
- Every architectural decision must have a logged source
- `agent-reasoning` alone is not sufficient for security decisions — cite the spec section or an external reference
- Number decisions sequentially — check the current highest number before adding
- All roles write to the shared log
- If a prior decision is reversed, log the reversal as a new entry with the reason

---

## 9. Open questions

All Stage 1 open questions are resolved. No blockers on Stage 2.

| # | Question | Resolution |
|---|----------|------------|
| 1 | Who is the caller? | **Agents and services only.** This tool is invoked programmatically by AI agents or automated services that need to evaluate whether data they are working with is potentially sensitive before proceeding. No human invokes this tool directly in production. Developer invocation is for integration testing only. |

### Implications of this decision

- **Auth model:** service-to-service only. No user-scoped credentials in production.
- **API contract:** optimized for programmatic consumption. No interactive affordances required.
- **No human in the loop at invocation time.** The agent acts on the result directly. This reinforces correctness and bounded behavior as the top priority — a wrong answer has no human catch before the downstream decision executes.

---

## 10. Planning files

The following files are the persistent working memory for this project. All contributors must read them at the start of every session before doing any work.

| File | Purpose |
|------|---------|
| `task_plan.md` | Phases, steps, decision log, open questions |
| `findings.md` | Research findings, key constraints, architectural decisions |
| `progress.md` | Session-by-session log of what was done and what is next |
| `council-workboard.md` | Cross-role active work, queued items, and coordination requests — read first to understand current state across all roles |
| `best-practices-backlog.md` | Engineering Practices Lead backlog — governance, testing, reproducibility, dev/prod parity items |

> These files are the source of truth for project state. If something is not in these files, it did not happen from the project's perspective.
