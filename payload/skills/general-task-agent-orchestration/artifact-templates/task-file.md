# Task File Template

Use this template when creating detailed task files (Phase 10). Each task file IS the complete prompt that an execution subagent receives. It must contain everything the agent needs to work autonomously.

---

```markdown
# Task N.M: <Title>

## Objective

<Clear, concise description of what this task accomplishes. 2-3 sentences.>

## Context

<How this task fits into the broader phase and project. What came before it and what depends on it.>

## Target Surfaces

| Surface | Tool | What's Done on This Surface |
|---------|------|----------------------------|
| <Surface> | <Tool> | <Brief description> |
| ... | ... | ... |

## Dependencies

- <Task X.Y> - <What it provides that this task needs>
- Or: None (first task)

## Blocked By

- <List of tasks that must complete before this one starts>

## Research Findings

Key findings from research files relevant to this task:

- From `<research-file>.md`: <Key finding>
- From `<research-file>.md`: <Key finding>

## Execution Plan

### Step 1: <Name>

**Surface:** [<surface-tag>]

<Detailed execution guidance. Include:>
- What to do on which surface
- Tool commands or operations to use
- Configuration details
- Key decisions from DISCOVERY.md that apply

**Verification:**
- <How to verify this step succeeded on this surface>

### Step 2: <Name>

**Surface:** [<surface-tag>]

<Detailed execution guidance>

**Verification:**
- <How to verify this step>

### Step N: <Name>

**Surface:** [<surface-tag>]

<Detailed execution guidance>

**Verification:**
- <How to verify this step>

## Artifacts to Create

- `<path/to/artifact>` - <Purpose> - [<surface>]
- ...

## Artifacts to Modify

- `<path/to/artifact>` - <What to change> - [<surface>]
- ...

## Contracts

### Provides (for downstream tasks)

- <Output>: <Format/location> - used by Task X.Y
- <Data>: <Schema or format>
- <Artifact>: <Description>

### Consumes (from upstream tasks)

- <Output from Task X.Y>: <How this task uses it>
- <Artifact from Task X.Y>: <How this task depends on it>

## Acceptance Criteria

- [ ] <Measurable criterion>
- [ ] <Measurable criterion>
- [ ] <Measurable criterion>
- [ ] All verifications pass

## Verification Protocol

### Per-Surface Verification

#### [browser] Web Verification
- Navigate to: <URL>
- Snapshot: Check for <expected elements/content>
- Screenshot: Capture <key state> as evidence
- User-emulating flow: <Step-by-step as a real user would>

#### [native] Native App Verification
- App: <App name>
- `peekaboo see --app "<App>"`: Check for <expected elements/content>
- Verify: <What to check in the element tree>

#### [file] File Verification
- Read: `<path/to/file>` - verify <expected content/structure>
- For scripts: Execute and check exit code + output
- For structured data: Parse and validate schema

#### [api] API Verification
- Call: <endpoint or MCP tool>
- Expected response: <What should come back>
- Follow-up read: Confirm the action took effect

#### [comm] Communication Verification
- Check sent folder / delivery confirmation
- Verify message content matches expected

#### [calendar] Calendar Verification
- Read back events
- Confirm: title, time, date, attendees, location

#### [code] Code Verification
- Run: <command>
- Expected exit code: 0
- Expected output: <What to check in stdout/stderr>

### Cross-Surface Coherence
- <Check data consistency between surfaces>
- <Verify handoffs between surfaces>

## Skills to Read

- `<skill-name>` - <Why>
- `<skill-name>` - <Why>

## Research Files to Read

- `.claude/orchestration-<slug>/research/<file>.md` - <Why>

## Execution Surfaces Reference

Read execution surface definitions and verification loop at: ~/.claude/skills/general-task-agent-orchestration/execution-surfaces.md
```

---

## Guidelines for Task File Creation

- **Self-contained** - the execution agent should need nothing beyond this file, the referenced skills, and the current project state
- **Specific** - include exact paths, configurations, platform details
- **Surface-tagged** - every action has a [surface] tag telling the agent which tool to use
- **Verification per step** - every step has a verification check on its target surface
- **Verification loop** - agents follow Execute -> Verify -> Retry (max 3) -> Escalate
- **Evidence captured** - verification output (snapshots, screenshots, reads, responses) recorded in PROGRESS.md
- **Reference skills and research** - point to the exact files the agent should read
- **Include contracts** - what this task provides to and consumes from other tasks
- **Step-by-step execution** - guide the agent through the work, don't just state requirements
- **Include edge cases** - don't just verify the happy path
- **Cross-surface coherence** - when task spans surfaces, include handoff verification
