# CLAUDE.md Orchestration Section Template

Use this template when adding the orchestration section to the project's CLAUDE.md (Phase 12). This section gives any agent (or new session) immediate context about the orchestration system.

---

```markdown
# <Project Name>

<One-line description of the project>

## Quick Reference

| What | Where |
|------|-------|
| **Top authority** | `.claude/orchestration-<slug>/DISCOVERY.md` - all decisions |
| **Action plan** | `.claude/orchestration-<slug>/PHASES.md` - <N> tasks across <N> phases |
| **Progress tracker** | `PROGRESS.md` - task status, verification results |
| **Task files** | `.claude/orchestration-<slug>/tasks/phase-N/task-N-M.md` - per-task specs |
| **Orchestrator** | `.claude/orchestration-<slug>/START.md` - how to run the system |
| **Research** | `.claude/orchestration-<slug>/research/` - <N> research files |

## Authority Rule

DISCOVERY.md overrides everything. If a research file, skill, or this document contradicts DISCOVERY.md, follow DISCOVERY.md. If still unsure, ask the human.

## Tool Stack

| Tool | Surface | Purpose |
|------|---------|---------|
| Playwright MCP | Browser (Web) | Web automation + verification |
| Peekaboo CLI | Native macOS | Desktop app automation + verification |
| <Tool> | <Surface> | <Purpose> |
| ... | ... | ... |

## Execution Surfaces

| Surface | Primary Tool | Verification Method |
|---------|-------------|-------------------|
| Browser (Web) | Playwright MCP | `browser_snapshot` + content check |
| Native macOS | Peekaboo CLI | `peekaboo see` + element check |
| Files | Bash / Read / Write | Read back + validate |
| Communication | Playwright / Peekaboo / API | Delivery confirmation |
| Calendar | Playwright / Peekaboo / API | Read events back |
| APIs/MCPs | MCP tools / curl | Follow-up call + response check |
| Code | Bash | Exit code + output check |

## Scope Constraints (DO NOT execute)

<Comma-separated list of excluded items from DISCOVERY.md>

## Verification

Every action follows the verification loop:
1. Execute on target surface
2. Verify using surface-specific method
3. Record evidence in PROGRESS.md
4. If fail: Analyze -> Adjust -> Retry (max 3) -> Escalate

## Skills

Agents MUST read relevant skill files before starting a task.

<List of project skills with one-line descriptions>

## MCP Servers

| Server | Surface | Purpose |
|--------|---------|---------|
| Playwright | Browser | Web automation + verification |
| <Server> | <Surface> | <Purpose> |
| ... | ... | ... |

## For Subagents

If you are a subagent spawned to execute a task:
1. Read your task file at `.claude/orchestration-<slug>/tasks/phase-N/task-N-M.md` first
2. Follow the Task Execution Protocol in `.claude/orchestration-<slug>/PHASES.md`
3. Read ALL skills listed in your task's Skills field
4. Check PROGRESS.md for current state before starting
5. Run the verification loop for every action (Execute -> Verify -> Retry -> Escalate)
6. Record verification evidence in PROGRESS.md when done
```

---

## Guidelines for CLAUDE.md Section

- **Concise** - this is a quick reference, not the full spec
- **Ephemeral** - this section is specific to the orchestration run, not permanent
- **Points to files** - don't duplicate content, just reference the right files
- **Includes surfaces table** - agents need to know which surfaces are active and how to verify on each
- **Includes subagent instructions** - every subagent reads CLAUDE.md, so include their protocol
- **Tool stack and scope** - quick-scannable for any agent entering the project
