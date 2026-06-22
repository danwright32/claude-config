# START.md Template

Use this template when creating the orchestrator protocol (Phase 12). This file defines how the main agent spawns execution subagents and manages the pipeline.

---

```markdown
# <Project Name> Orchestrator

When `/start` is invoked, this orchestrator manages sequential execution of all tasks across all phases. Designed for **fully autonomous execution** across multiple execution surfaces.

---

## Startup Sequence

1. **Read PROGRESS.md** - Determine current state: which tasks are complete, which phase is active
2. **Read PHASES.md** at `.claude/orchestration-<slug>/PHASES.md` - Load the full action plan
3. **Verify surfaces** - Quick check that Playwright MCP and Peekaboo CLI are still accessible
4. **Identify next task** - Find the lowest-numbered pending task whose dependencies are all met
5. **Execute the task** - Spawn a subagent (see below)
6. **After task completes** - Verify PROGRESS.md was updated and verification evidence recorded, then repeat from step 4

---

## Spawning a Subagent

For each task, spawn a `general-purpose` subagent via the Task tool:

```
You are executing Task N.M for <Project Name>.

## Your Task File
Read your full task specification at: .claude/orchestration-<slug>/tasks/phase-N/task-N-M.md

## Execution Protocol

### Phase 0: Orient
- Read PROGRESS.md to confirm this task is next
- Read your task file for full spec, acceptance criteria, surfaces, actions, verification
- Read ALL skill files listed in your task's Skills field
- Read relevant research files listed in your task
- Read execution surfaces reference for verification methods

### Phase 1: Explore & Plan
- Explore existing project state - understand what prior tasks produced
- Read artifacts you'll modify to understand current state
- Plan approach before executing

### Phase 2: Execute
- Perform each action on its tagged surface using the appropriate tool:
  - [browser] -> Playwright MCP (navigate, click, fill, snapshot, screenshot)
  - [native] -> Peekaboo CLI (see, click, type, press, menu, open)
  - [file] -> Read / Write / Edit / Bash
  - [api] -> MCP tools / curl
  - [comm] -> Playwright (web) or Peekaboo (native) or API
  - [calendar] -> Playwright (web) or Peekaboo (native) or API
  - [code] -> Bash

### Phase 3: Verify (MANDATORY)
For EACH action, run the verification loop:

1. **Execute** the action
2. **Verify** using the surface-specific method:
   - [browser]: `browser_snapshot` + content check, screenshot for evidence
   - [native]: `peekaboo see --app` + element/content check
   - [file]: Read back + validate structure/content
   - [api]: Follow-up API call + response validation
   - [comm]: Check sent/delivery confirmation
   - [calendar]: Read events back + confirm details
   - [code]: Check exit code + stdout/stderr
3. **Record evidence** in PROGRESS.md notes
4. **If pass**: Move to next action
5. **If fail**: Analyze -> Adjust -> Retry (max 3 attempts)
6. **If 3 retries fail**: Escalate (see failure handling below)

### Phase 4: Complete
- Update PROGRESS.md with:
  - Status: done
  - Date: today
  - Verification: pass/fail summary
  - Notes: evidence references, key outcomes
- Confirm all acceptance criteria are met

## Available Tools

### Playwright MCP (Browser/Web)
- browser_navigate, browser_click, browser_fill_form, browser_snapshot
- browser_take_screenshot, browser_evaluate, browser_file_upload
- browser_select_option, browser_press_key, browser_wait_for

### Peekaboo CLI (Native macOS)
- peekaboo see, peekaboo click, peekaboo type, peekaboo hotkey
- peekaboo menu click, peekaboo menu list, peekaboo paste
- peekaboo app launch, peekaboo app switch, peekaboo app quit
- peekaboo list apps, peekaboo list windows, peekaboo window focus

### File Operations
- Read, Write, Edit, Glob, Grep, Bash

### Other
<List additional MCP servers and tools available to subagents>

## Key References
- DISCOVERY.md at .claude/orchestration-<slug>/DISCOVERY.md is top authority
- PHASES.md at .claude/orchestration-<slug>/PHASES.md for plan overview
- Skills at .claude/skills/ - read all listed in your task
- Research at .claude/orchestration-<slug>/research/
- Execution surfaces at ~/.claude/skills/general-task-agent-orchestration/execution-surfaces.md
```

---

## Verification Sweep Tasks

Verification sweep tasks (last task of each phase) use a different prompt:

```
This is a VERIFICATION SWEEP task for Phase N.

Re-verify ALL deliverables from this phase across all surfaces:

1. For each completed task in Phase N, read its verification criteria
2. Re-run each verification on the current state:
   - [browser]: Navigate and snapshot key states, screenshot for evidence
   - [native]: `peekaboo see` each relevant app, verify expected state
   - [file]: Read back all created/modified files, validate content
   - [api]: Call APIs, verify responses match expected
   - [comm]: Confirm all messages were delivered
   - [calendar]: Verify all events exist with correct details
   - [code]: Re-run scripts/builds, verify outputs
3. Check cross-surface coherence:
   - Data consistency between surfaces
   - Handoff integrity (outputs from one surface correctly consumed by another)
4. Record ALL evidence in PROGRESS.md verification sweep section
5. If any verification fails:
   - Identify the issue
   - Fix it directly
   - Re-verify until green
6. Update PROGRESS.md with sweep results
```

---

## Final Phase Tasks

The final phase verifies all project deliverables comprehensively:

```
This is a FINAL VERIFICATION task for the completed project.

1. Verify every deliverable exists and meets quality standards from DISCOVERY.md
2. Test every deliverable on its target surface
3. Verify all cross-surface handoffs
4. Confirm all distributions/deliveries reached their destinations
5. Check all external service integrations
6. Validate against every acceptance criterion in DISCOVERY.md
7. Update PROGRESS.md with comprehensive results
```

---

## Orchestrator Rules

### Execution Order
- Execute ONE task at a time (sequential, not parallel)
- Follow task numbering within each phase
- Complete all tasks in a phase before moving to the next
- Verification sweep is always the last task in each phase

### Dependency Checking
- Before spawning, verify all dependency tasks are marked `done` in PROGRESS.md
- The only true blocker is a prior task not being complete

### Failure Handling (3-Tier Escalation)

**Tier 1: Subagent Self-Recovery** (automatic)
- Debug and fix within its own session
- Retry failed actions with different parameters or alternative approach
- Try alternative surface or tool if primary fails
- Create missing dependencies inline

**Tier 2: Orchestrator Intervention** (if subagent reports failure)
- Read error output and PROGRESS.md notes
- Spawn a targeted fix subagent
- Re-run original task after fix

**Tier 3: User Escalation** (last resort)
- Provide: task number, surface, what was attempted, the error, suggested fix
- Continue with next unblocked task while waiting

### Phase Transitions
- After verification sweep passes, update Phase Overview in PROGRESS.md
- Announce phase completion before starting next phase

### Session Boundaries
- If context is getting large, report progress and suggest starting fresh
- PROGRESS.md enables session continuity

---

## File Locations

| File | Path | Purpose |
|------|------|---------|
| Master plan | `.claude/orchestration-<slug>/PHASES.md` | All tasks, skills, verification methods |
| Orchestrator | `.claude/orchestration-<slug>/START.md` | This file |
| Discovery | `.claude/orchestration-<slug>/DISCOVERY.md` | Top authority for decisions |
| Project Brief | `.claude/orchestration-<slug>/PROJECT-BRIEF.md` | Original synthesized brief |
| Research | `.claude/orchestration-<slug>/research/` | Research files |
| Task files | `.claude/orchestration-<slug>/tasks/phase-N/task-N-M.md` | Per-task specs |
| Progress | `PROGRESS.md` | Task status tracker |
| Skills | `.claude/skills/` | Project skills |
| Reports | `.claude/orchestration-<slug>/reports/` | Verification + synergy reports |
```

---

## Guidelines for START.md Creation

- **Include all available tools** - list every MCP tool and CLI the subagents can use, organized by surface
- **Include key file paths** - subagents need to find DISCOVERY.md, PHASES.md, research, skills
- **Verification loop is mandatory** - every action must be verified on its target surface
- **3-tier failure handling** - subagent self-recovery, orchestrator fix, user escalation
- **Session boundary awareness** - PROGRESS.md is the continuity mechanism
- **Customize for the project** - add project-specific tools, platforms, surfaces
