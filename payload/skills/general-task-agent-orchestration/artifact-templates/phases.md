# PHASES.md Template

Use this template when creating the master action plan (Phase 9). This is the blueprint that gets sharded into individual task files.

---

```markdown
# <Project Name> - Action Phases

**Target**: <Date or milestone>
**Execution**: Sequential phases, autonomous subagent execution
**Authority**: DISCOVERY.md overrides everything

---

## Scope Constraints (from DISCOVERY.md)

These are OUT of scope. Do NOT execute:
- <Excluded item 1>
- <Excluded item 2>
- ...

---

## Tool Stack

| Tool | Surface | Purpose |
|------|---------|---------|
| Playwright MCP | Browser (Web) | Web automation, platform interaction, web verification |
| Peekaboo CLI | Native macOS | Desktop app automation, native verification |
| Bash / Read / Write | Files | File creation, scripts, data processing |
| curl / MCP tools | APIs | External service integration |
| <Tool> | <Surface> | <Purpose> |
| ... | ... | ... |

---

## Skills Reference

All skills at `.claude/skills/`. Agents MUST read relevant skills before starting a task.

| Skill | Use When |
|-------|----------|
| `<skill-name>` | <When to use> |
| ... | ... |

---

## Tools Reference

| Server/Tool | Surface | Use For | Key Operations |
|-------------|---------|---------|----------------|
| **Playwright MCP** | Browser | Web platform interaction, verification | navigate, click, fill, upload, screenshot, snapshot |
| **Peekaboo CLI** | Native | Desktop app automation, native verification | see, click, type, press, menu, open |
| <Tool> | <Surface> | <Purpose> | <Key operations> |
| ... | ... | ... | ... |

---

## Verification Methods

| Surface | Tool | Verification Method |
|---------|------|-------------------|
| Browser (Web) | Playwright | `browser_snapshot` + content assertion, screenshot for evidence |
| Native macOS | Peekaboo | `peekaboo see --app` + element check |
| Files | Read / Bash | Read back + structure/content validation |
| Communication | Playwright / Peekaboo | Confirm delivery in sent folder or via API |
| Calendar | Playwright / Peekaboo | Read events back + confirm details |
| APIs/MCPs | curl / MCP | Follow-up API call + response validation |
| Code | Bash | Exit code + output validation |

---

## Phase Overview

| Phase | Goal | Tasks | Primary Surfaces |
|-------|------|-------|-----------------|
| 1: <Name> | <Goal> | <N> | <Surfaces> |
| 2: <Name> | <Goal> | <N> | <Surfaces> |
| ... | ... | ... | ... |
| N: Verification | Comprehensive multi-surface verification of all deliverables | <N> | All |
| **Total** | | **<Total>** | |

---

## Phase 1: <Name>

**Goal**: <What this phase achieves>

### Task 1.1: <Title>
- **Objective**: <What this task accomplishes>
- **Surface(s)**: <Tagged surfaces this task operates on>
- **Dependencies**: <Blocking tasks, or "None">
- **Blocked by**: <What must complete first>
- **Actions to Perform**:
  - [<surface>] <Action description>
  - [<surface>] <Action description>
- **Contracts**: <Data, outputs, or artifacts shared with other tasks>
- **Acceptance Criteria**:
  - [ ] <Criterion>
  - [ ] <Criterion>
- **Verification**:
  - [ ] [<surface>] <Verification method>: <What to check>
  - [ ] [<surface>] <Verification method>: <What to check>
- **Skills**: <Skill names to read>

### Task 1.2: <Title>
...

### Task 1.V: Phase 1 Verification Sweep
- **Objective**: Full verification of all Phase 1 deliverables across all surfaces
- **Dependencies**: All Phase 1 tasks complete
- **Verification**:
  - [ ] Re-verify every deliverable on its target surface
  - [ ] Cross-surface coherence check
  - [ ] Evidence captured for each verification (snapshots, screenshots, file reads)
  - [ ] All acceptance criteria from Phase 1 tasks confirmed met

---

## Phase 2: <Name>
...

---

## Phase N: Comprehensive Verification

**Goal**: Multi-surface verification of all project deliverables

### Task N.1: <Verification Focus Area>
- Verify every deliverable on its target surface
- Cross-check data consistency across surfaces
- Confirm all outputs meet quality standards from DISCOVERY.md
- Validate all distributions/deliveries reached their destinations

### Task N.2: <Another Verification Focus>
...

---

## Dependency Graph

```
1.1 -> 1.2 -> 1.3
              |
              v
       2.1 -> 2.2
              |
              v
       3.1 -> 3.2
```

---

## Task Execution Protocol

### For each task:
1. **Orient**: Read task file, skills, PROGRESS.md
2. **Plan**: Explore current state, plan approach
3. **Execute**: Perform actions on tagged surfaces using appropriate tools
4. **Verify**: Run verification loop for each action (Execute -> Verify -> Retry if fail -> Escalate)
5. **Complete**: Update PROGRESS.md with status, evidence, and notes

### For verification sweep tasks:
1. Re-verify ALL deliverables from the phase
2. Run surface-specific verification for each
3. Check cross-surface coherence
4. Capture evidence (snapshots, screenshots, reads, responses)
5. Fix any failures, re-verify until green
6. Record all evidence in PROGRESS.md

### For final phase:
1. All tasks are verification on fully completed deliverables
2. Every output and deliverable checked on its target surface
3. Every cross-surface handoff verified
4. All quality standards validated
5. Iterate until all checks pass
```

---

## Guidelines for PHASES.md Creation

- **Read DISCOVERY.md first** - it's the top authority
- **Order phases by dependency** - foundation first, polish last, verification always final
- **Every phase ends with verification sweep** - the last task verifies everything in that phase
- **Every task has acceptance criteria** - measurable, verifiable conditions
- **Every task has verification criteria** - surface-specific checks to run
- **Tag every action with its surface** - [browser], [native], [file], [api], [comm], [calendar], [code]
- **Document contracts** - outputs and data shared between tasks
- **Include the dependency graph** - visual representation of task ordering
- **List skills per task** - agents read these before starting
- **The final phase is always comprehensive verification** - multi-surface, all deliverables
