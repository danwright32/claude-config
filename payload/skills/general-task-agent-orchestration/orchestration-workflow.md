# Orchestration Workflow

12-phase protocol from brain dump to fully verified, delivered output. Each phase references artifact templates in `artifact-templates/` and execution surface definitions in `execution-surfaces.md`.

---

## Phase 0: Setup

**Actor:** Main agent

1. Verify hard prerequisites:
   - **Playwright MCP** is available (test with a simple `browser_navigate`)
   - **Peekaboo CLI** is installed (test with `peekaboo list apps`)
   - If either fails, stop and inform the user. Do not proceed without both.
2. Create orchestration folder: `.claude/orchestration-<auto-slug>/` where slug is auto-generated from the project idea (e.g., `orchestration-course-launch`, `orchestration-hiring-campaign`)
3. Create subfolders: `research/`, `tasks/`, `skills/`, `reports/`

---

## Phase 1: Brain Dump to Project Brief

**Actor:** Main agent

1. Receive the user's brain dump (could be a paragraph, a conversation, a doc, a rambling voice-to-text, or a reference to existing materials)
2. Read template: `artifact-templates/project-brief.md`
3. Synthesize into a structured Project Brief, strictly under 500 lines
4. Save to: `.claude/orchestration-<slug>/PROJECT-BRIEF.md`
5. Present the brief to user for quick confirmation before proceeding

**Output:** `PROJECT-BRIEF.md`

---

## Phase 2: First Research Wave

**Actor:** Parallel background subagents (one per domain)

The number of subagents depends on how many distinct domains the project spans. Each subagent researches one angle of the Project Brief.

1. Main agent reads the Project Brief and identifies distinct research domains. These vary by project type:
   - **Content creation:** platforms, formats, audience analysis, distribution channels, content strategy
   - **Course/curriculum:** learning design, platform options, assessment methods, engagement patterns
   - **Research projects:** methodologies, data sources, analysis tools, literature landscape
   - **Operations setup:** tooling, automation platforms, workflow patterns, integration options
   - **Event coordination:** venue/platform options, logistics, scheduling, communication
   - **Outreach/hiring:** channels, templates, CRM tools, pipeline management, evaluation criteria

2. For each domain, spawn a background subagent with this prompt pattern:

```
You are a research agent for the "<domain>" aspect of this project.

Read the Project Brief at: .claude/orchestration-<slug>/PROJECT-BRIEF.md

Research thoroughly:
- Current best practices for <domain>
- Available tools, platforms, services
- Common pitfalls and edge cases
- Patterns that work well for this type of project
- Any relevant integrations, APIs, or automations
- What execution surfaces (browser, native apps, files, APIs) are relevant

Store your complete research in a single file at:
.claude/orchestration-<slug>/research/<domain-slug>.md

Follow the research file template at: ~/.claude/skills/general-task-agent-orchestration/artifact-templates/research-file.md

Be thorough - this research will inform all execution decisions.
```

3. Wait for all research subagents to complete

**Output:** Multiple files in `research/` folder

---

## Phase 3: Discovery Questions

**Actor:** Main agent

This is the most critical phase. The agent asks the user MANY questions to fully clarify scope, preferences, constraints, and decisions. The goal is production-ready clarity - every ambiguity resolved, every edge case addressed, every integration specified.

### 3a. User's Workspace Research

Before asking questions, research the user's broader workspace for context:

1. Explore the user's project directory structure, any existing CLAUDE.md files, README files, or documentation
2. Identify existing projects, businesses, communities, audiences, workflows
3. Find existing assets, templates, tools, accounts, or resources that could be leveraged
4. Understand the user's workflow patterns, communication style, and preferences
5. This context informs smarter, more relevant discovery questions

### 3b. Comprehensive Q&A

1. Read ALL research files from Phase 2
2. Read template: `artifact-templates/discovery.md`
3. Ask the user a comprehensive series of questions, organized by domain. The template includes category-specific question sets for:
   - Content creation projects
   - Course/curriculum projects
   - Research projects
   - Operations/workflow setup
   - Event/project coordination
   - Outreach/hiring campaigns
4. Universal domains to always cover:
   - Vision and goals
   - Scope and boundaries (what's IN, what's OUT)
   - Tool and platform preferences
   - Workflow and process decisions
   - Quality and output standards
   - External services and integrations
   - Scheduling and timeline
   - Edge cases and error handling
   - Communication and distribution
   - Existing assets and resources
   - Verification criteria (how do we know each piece is "done"?)
   - Any domain-specific decisions
5. Use AskUserQuestion tool for each batch of questions
6. After EVERY question is answered, store the Q&A in DISCOVERY.md
7. Continue asking until the full scope is clear - err on the side of asking too many questions
8. Number every decision (D1, D2, D3...) for cross-referencing

### 3c. Discovery Completeness Check (MANDATORY)

**Before moving to Phase 4, the agent MUST perform a self-audit.** This is not optional.

1. Re-read the complete DISCOVERY.md and all research files
2. For EACH of the following categories, verify that sufficient decisions exist. If any category has gaps, ask MORE questions before proceeding:

   | Category | Check |
   |----------|-------|
   | **Objectives** | Are all deliverables clearly defined with acceptance criteria? |
   | **Every execution surface** | Is it clear which surfaces each deliverable touches? |
   | **Every external service** | Is every platform, tool, and integration fully specified (auth method, access, configuration)? |
   | **Every output/artifact** | Is the exact format, structure, quality standard, and delivery method defined? |
   | **Error handling** | What happens when each step fails? Fallback strategy? |
   | **Verification** | How will each deliverable be verified as complete and correct? |
   | **Edge cases** | Delays, partial failures, unavailable services, retries? |
   | **Timeline** | Deadlines, milestones, dependencies, scheduling constraints? |
   | **Workflow** | How does the user interact with the system during and after execution? |
   | **Distribution/delivery** | Where does each output go? How is it delivered? Who receives it? |
   | **Existing assets** | What templates, accounts, credentials, content already exists? |
   | **Platform constraints** | Character limits, file size limits, format requirements per platform? |

3. Ask yourself: **"If an execution agent read only DISCOVERY.md, could it make every execution decision without guessing?"** If the answer is NO, identify the gaps and ask more questions.

4. Only proceed to Phase 4 when the answer is YES.

**Output:** `DISCOVERY.md` - the top authority document for all decisions, verified complete

---

## Phase 4: Second Research Wave

**Actor:** Parallel background subagents

Now that the user's clarifications exist in DISCOVERY.md, deploy a second wave of research subagents. These research with a new lens - through the user's answers.

1. Main agent identifies new research domains needed post-discovery. This wave focuses on:
   - **Execution-focused research** - how to accomplish what was decided, filtered by DISCOVERY.md
   - **Tool and surface research** - what tools, MCP servers, CLIs, native apps are needed for each execution surface
   - **Human action research** - what accounts, credentials, configurations need to be set up (the agent will do these via Playwright/Peekaboo where possible)
   - **Verification strategy research** - how to verify each deliverable on its target surface
   - **Distribution research** - how to deliver/publish each output to its destination

2. For each domain, spawn a background subagent:

```
You are a second-wave research agent for "<domain>".

FIRST, read these files:
- DISCOVERY.md at: .claude/orchestration-<slug>/DISCOVERY.md
- Relevant first-wave research at: .claude/orchestration-<slug>/research/<relevant-files>

Then research with the lens of the user's clarified decisions:
- Execution approaches that align with DISCOVERY.md decisions
- Specific tools, MCP servers, CLIs, native apps needed for each surface
- What accounts/API keys/tokens need to be configured (and how to configure them)
- Verification strategies: how to confirm each deliverable is complete and correct
- How to deliver/distribute each output to its destination

Store output at: .claude/orchestration-<slug>/research/<domain-slug>-execution.md
Follow template: ~/.claude/skills/general-task-agent-orchestration/artifact-templates/research-file.md
```

3. Wait for all subagents to complete

**Output:** Additional files in `research/` folder (execution-focused)

---

## Phase 5: Tool + Surface Setup

**Actor:** Main agent (with user providing credentials when needed)

**This phase is MANDATORY.** The agent must actually configure every tool and verify access to every execution surface - not just list what's needed. The agent autonomously completes all setup steps via Playwright (web) and Peekaboo (native apps), only asking the user for credentials it cannot obtain on its own.

### 5a. Tool and Surface Inventory

1. Read all second-wave research files
2. Compile a comprehensive inventory of EVERY tool, service, platform, and surface access needed:

   | Category | Examples |
   |----------|----------|
   | **MCP servers** | Any new MCP servers to install and configure |
   | **API keys** | Every external API that needs a key/token |
   | **Accounts** | Services where accounts need to be created or accessed |
   | **Browser sessions** | Web platforms requiring login (via Playwright) |
   | **Native app access** | macOS apps to configure (via Peekaboo) |
   | **CLI tools** | Any CLI tools to install (npm, pip, brew, etc.) |
   | **Environment variables** | Every .env variable or config the project needs |
   | **Configuration files** | Any config files to create (JSON, YAML, etc.) |
   | **File templates** | Any document templates to download or create |

3. For each item, classify the setup action:
   - **Agent can do autonomously** - install via CLI, generate config files, etc.
   - **Agent can do via Playwright** - configure in web dashboards
   - **Agent can do via Peekaboo** - configure in native macOS apps
   - **Requires user credentials** - user must provide login credentials
   - **User must do manually** - truly cannot be automated (e.g., phone verification, payment)

### 5b. Credential Collection

1. Present the user with a clear list of credentials needed:
   - Which services need login (username/password or existing session)
   - Which API keys the user already has
   - Which accounts need to be created
2. Ask the user to provide credentials or confirm access

### 5c. Autonomous Configuration

The agent MUST execute these steps, not just document them:

1. **Install MCP servers** - Run install commands, verify they respond
2. **Install CLI tools** - Run install commands, verify with `--version`
3. **Configure web platforms** - Navigate to dashboards via Playwright, configure settings, generate keys
4. **Configure native apps** - Open and set up macOS apps via Peekaboo as needed
5. **Create .env file** - Write all API keys, tokens, and configuration
6. **Create config files** - Generate any configuration files needed
7. **Download templates** - Fetch any required templates or assets
8. **Install dependencies** - Run package manager install commands

### 5d. Setup Verification

After each tool/surface is configured, immediately test it:
- Make a test API call with each API key
- Verify each MCP server responds
- Verify each CLI tool runs
- Verify Playwright can navigate to each web platform
- Verify Peekaboo can see each native app
- Verify each file path is accessible

If any setup fails, debug and retry before moving on. Only escalate to user if truly stuck.

**Output:** All tools configured, surfaces accessible, credentials stored, everything verified working

---

## Phase 6: Surface Verification

**Actor:** Main agent

**This phase is MANDATORY and cannot be skipped.** Every single tool and surface must be verified with a real operation before proceeding. If Phase 5d already verified inline, this phase serves as a comprehensive re-verification and produces the formal verification report.

### Verification Protocol

For EACH item in the inventory, perform the appropriate verification:

| Surface/Tool | Verification Method |
|--------------|-------------------|
| **Playwright MCP** | Navigate to a target URL, take snapshot, verify content |
| **Peekaboo CLI** | `peekaboo see --app "<App>" --json`, verify element tree returned |
| **API key** | Make a real API call (not just auth check), verify response data |
| **CLI tool** | Run `--version` or `--help`, verify expected output |
| **Browser session** | Navigate to authenticated page via Playwright, verify logged-in state |
| **Native app** | Open app via Peekaboo, verify app responds and shows expected state |
| **File system** | Verify all required directories exist and are writable |
| **Config file** | Parse the config, verify all required keys are present and valid |
| **Environment vars** | Verify all required variables are set and non-empty |
| **MCP server** | Call a real read/list operation, verify valid response |

### Verification Report

Create a verification report at `.claude/orchestration-<slug>/reports/surface-verification.md`:

```
| Tool/Surface | Type | Status | Test Performed | Notes |
|-------------|------|--------|---------------|-------|
| Playwright MCP | MCP | PASS | Navigated to target URL | - |
| Peekaboo CLI | CLI | PASS | Listed running apps | - |
| Google Calendar | Web Platform | PASS | Read today's events | - |
| Keynote | Native App | PASS | Opened and captured state | - |
| ...
```

### Failure Protocol

- If ANY tool/surface fails verification: debug, fix, and re-verify
- If it cannot be fixed: escalate to user with specific error details
- **Do NOT proceed to Phase 7 until ALL items pass verification**
- The verification report must show 100% PASS before moving on

**Output:** Verification report with all tools and surfaces confirmed working

---

## Phase 7: Skill Creation

**Actor:** Parallel background subagents

**This phase is MANDATORY and cannot be skipped.** Skills are the knowledge layer that execution agents read to understand HOW to use every tool, service, platform, and pattern in the project. Without skills, execution agents operate blind. Every tool, every external service, every research domain, and every verification strategy MUST have a corresponding skill.

### 7a. Skill Inventory (MANDATORY)

The main agent MUST create skills for ALL of the following categories. This is not a suggestion - it is a requirement. Review each category against the project's research files and DISCOVERY.md:

| Category | What to Create | Example |
|----------|---------------|---------|
| **Each external tool/service** | One skill per external service | `google-calendar-automation`, `mailchimp-campaigns`, `notion-workspace` |
| **Each MCP server** | One skill per MCP server used | `playwright-browser-automation`, `notion-mcp` |
| **Each native app workflow** | One skill per native app used significantly | `keynote-presentation-creation`, `apple-calendar-management` |
| **Each external data source** | One skill per data source | `rss-feed-collection`, `market-research-sources` |
| **Each research domain** | One skill per major research area | `curriculum-design-patterns`, `content-distribution-strategy` |
| **Each verification strategy** | One skill per unique verification approach | `browser-verification-playwright`, `native-app-verification-peekaboo` |
| **Each distribution channel** | One skill per delivery platform | `youtube-publishing`, `email-newsletter-distribution` |
| **Project architecture** | One skill documenting the overall project structure | `course-launch-architecture` (or project-specific equivalent) |

### 7b. Skill Content Requirements

Each skill MUST include (not optional):

1. **What it is** - Clear description of the tool/domain
2. **When to use it** - Trigger conditions for execution agents
3. **Authentication/setup** - How to authenticate, what env vars are needed
4. **Key operations** - Commands, API patterns, UI workflows with examples
5. **Target surface** - Which execution surface this skill operates on
6. **Rate limits and constraints** - What limits exist, how to handle them
7. **Common pitfalls** - Specific things that go wrong and how to avoid them
8. **Verification strategy** - How to verify actions on this surface work correctly
9. **Cost implications** - API costs, rate limits, budget considerations
10. **References** - Links to research files for deeper context

### 7c. Skill Creation Process

1. Main agent compiles the full skill inventory from 7a
2. For each skill, spawn a background subagent:

```
Create a Claude Code skill at: .claude/skills/<skill-name>/SKILL.md

Read these files first for context:
- DISCOVERY.md at: .claude/orchestration-<slug>/DISCOVERY.md
- Relevant research files at: .claude/orchestration-<slug>/research/
- Surface verification report at: .claude/orchestration-<slug>/reports/surface-verification.md

The skill MUST document (all required):
- What the tool/domain is and when to use it
- Authentication and setup (env vars, API keys, session cookies)
- Key operations with examples (commands, API calls, UI workflows)
- Target execution surface and verification method
- Rate limits, constraints, and cost implications
- Common pitfalls with specific mitigations
- References to research files for deeper context

Follow Claude Code skill format:
---
name: <skill-name>
description: <What it does>. Use when <trigger conditions>.
---

Save to: .claude/skills/<skill-name>/SKILL.md
```

3. Wait for ALL skill creation subagents to complete
4. Verify every skill file exists and contains all required sections

### 7d. Skill Completeness Check

Before proceeding, verify:
- Every tool from the verification report has a corresponding skill
- Every research domain has a corresponding skill
- Every verification strategy has a corresponding skill
- Every external platform/service has a corresponding skill
- No skill is a stub or placeholder - all contain actionable execution guidance

**Output:** Comprehensive skills in `.claude/skills/`, one per tool/domain/strategy/platform

---

## Phase 8: Context Compact

**Actor:** User

1. Prompt the user to compact the context window (the conversation is likely large at this point)
2. All critical state is in files (DISCOVERY.md, research/, skills/) so nothing is lost

**Output:** Fresh context, all state persisted in files

---

## Phase 9: PHASES.md Creation

**Actor:** Main agent

This is the master action plan. The main agent synthesizes everything into a phased execution plan.

1. Read template: `artifact-templates/phases.md`
2. Read ALL of:
   - DISCOVERY.md (top authority)
   - All research files (both waves)
   - All skills created
   - PROJECT-BRIEF.md
3. Create PHASES.md with:
   - Scope constraints (what's NOT being done)
   - Tool stack summary (tools + surfaces)
   - Skills reference table
   - Tools/MCP/surfaces reference table
   - Verification methods table
   - Phase overview table
   - Per-phase sections with task lists
   - Each task includes: objective, acceptance criteria, actions to perform (with surface tags), dependencies (blocking/blocked-by), contracts with adjacent tasks, verification criteria
   - **Last task in every phase**: full verification sweep of that phase's tasks across all surfaces
   - **Last phase**: entirely dedicated to comprehensive multi-surface verification of all deliverables
   - Dependency graph showing cross-phase relationships
   - Task execution protocol

4. Save to: `.claude/orchestration-<slug>/PHASES.md`

**Output:** `PHASES.md` - the master action plan

---

## Phase 10: Task File Sharding

**Actor:** Parallel background subagents (one per phase)

Each phase gets a subagent that expands the PHASES.md task summaries into detailed, self-contained task files.

1. For each phase, spawn a background subagent:

```
You are creating detailed task files for Phase N of the execution plan.

Read these files first:
- PHASES.md at: .claude/orchestration-<slug>/PHASES.md
- DISCOVERY.md at: .claude/orchestration-<slug>/DISCOVERY.md
- Relevant research files in: .claude/orchestration-<slug>/research/
- Relevant skills in: .claude/skills/
- Task file template at: ~/.claude/skills/general-task-agent-orchestration/artifact-templates/task-file.md
- Execution surfaces reference at: ~/.claude/skills/general-task-agent-orchestration/execution-surfaces.md

For each task in Phase N of PHASES.md:
1. Read the task summary from PHASES.md
2. Do deeper ideation into the actions, surfaces, and broader context
3. Read relevant skills and research files
4. Create a detailed task file following the template
5. Tag every action with its target surface: [browser], [native], [file], [api], [comm], [calendar], [code]
6. Include surface-specific verification for each action

Each task file is the COMPLETE prompt that an execution subagent will receive.
It must include everything the agent needs to execute the task autonomously.

Save each file to: .claude/orchestration-<slug>/tasks/phase-N/task-N-M.md
```

2. Wait for all phase subagents to complete

**Output:** Detailed task files in `tasks/phase-N/` folders

---

## Phase 11: Synergy Review

**Actor:** Parallel background subagents

Evaluate cross-phase and cross-surface coherence. Use as few subagents as possible while covering all phases.

1. Spawn review subagents that each cover multiple phases:

```
You are reviewing task files for synergy issues.

Read ALL task files in: .claude/orchestration-<slug>/tasks/
Read PHASES.md at: .claude/orchestration-<slug>/PHASES.md
Read execution surfaces at: ~/.claude/skills/general-task-agent-orchestration/execution-surfaces.md

Evaluate:
- Are there contradictions between tasks in different phases?
- Do data contracts between tasks align (shared data, formats, outputs feeding inputs)?
- Are dependencies correctly declared?
- Do verification strategies reference the right methods for each surface?
- Are there gaps - things assumed but never explicitly created?
- Do later tasks correctly build on earlier tasks' outputs?
- **Cross-surface coherence**: When data moves between surfaces (e.g., file created then uploaded via browser), is the handoff explicit?
- **Surface tag consistency**: Does every action have a surface tag? Are tags correct?
- **Verification completeness**: Does every action have a matching verification step?

For each issue found, propose a specific fix (which file, what change).

Save your review to: .claude/orchestration-<slug>/reports/synergy-review.md
```

2. Wait for review subagents to complete
3. Present all synergy issues to user for approval
4. Apply approved fixes to task files

**Output:** Synergy-reviewed, coherent task files

---

## Phase 12: Final Artifacts

**Actor:** Main agent

Create the remaining orchestration artifacts and update project configuration.

1. Read template: `artifact-templates/progress.md`
   - Create `PROGRESS.md` with phase overview table and per-task status rows (all "pending")
   - Include "Surface" column in task tables
   - Save to project root or orchestration folder

2. Read template: `artifact-templates/start.md`
   - Create `START.md` - the orchestrator protocol that defines how to spawn execution subagents
   - Integrate the verification loop from `execution-surfaces.md` into the subagent protocol
   - Save to: `.claude/orchestration-<slug>/START.md`

3. Read template: `artifact-templates/claude-md-section.md`
   - Add orchestration section to the project's `CLAUDE.md` (create if it doesn't exist)
   - Include: quick reference table, authority rule, tool stack, surfaces table, skill references, verification methods

4. Report to user: orchestration system is ready. Tell them to run `/start` to begin execution.

**Output:** `PROGRESS.md`, `START.md`, updated `CLAUDE.md`

---

## Execution (Post-Setup)

Once all 12 phases are complete, the system is ready for autonomous execution via `/start`:

1. Orchestrator reads PROGRESS.md to find next pending task
2. Spawns a subagent pointed at the task file
3. Subagent reads task file, relevant skills, executes actions, runs verification loop, records evidence
4. Orchestrator verifies PROGRESS.md was updated, moves to next task
5. After each phase's verification sweep passes, the phase is complete
6. After all phases complete, the project is fully executed and verified

### Task Execution Flow (per task)

Each execution subagent follows this flow:

1. **Orient** - Read task file, read skills, read PROGRESS.md
2. **Plan** - Explore current state, plan approach
3. **Execute** - Perform actions on target surfaces using tagged tools
4. **Verify** - Run the verification loop for each action:
   - Execute -> Verify -> (pass?) continue : (fail?) Analyze -> Adjust -> Retry (max 3) -> Escalate
   - Record evidence in PROGRESS.md
5. **Complete** - Update PROGRESS.md with status, date, evidence, and notes

### Phase Verification Sweep (last task of each phase)

1. Re-verify ALL deliverables from the phase across all surfaces
2. Run surface-specific checks:
   - Browser: snapshot and screenshot key states
   - Native apps: capture app state via Peekaboo
   - Files: read back and validate
   - APIs: call and verify responses
   - Communication: confirm delivery
   - Calendar: read back events
3. Check cross-surface coherence
4. If failures: create fix, re-verify until green
5. Record all evidence in PROGRESS.md

### Final Phase (always the last phase)

The final phase is entirely dedicated to comprehensive verification of all deliverables:
- Every deliverable checked on its target surface
- Every cross-surface handoff verified
- All external service integrations confirmed
- Quality standards validated
- Delivery/distribution confirmed
- Iterate until all checks pass

---

## Naming Conventions

| Artifact | Naming Pattern |
|----------|---------------|
| Orchestration folder | `.claude/orchestration-<auto-slug>/` |
| Research files | `research/<domain-slug>.md`, `research/<domain-slug>-execution.md` |
| Task files | `tasks/phase-N/task-N-M.md` |
| Skills | `.claude/skills/<descriptive-name>/SKILL.md` |
| Reports | `reports/synergy-review.md`, `reports/surface-verification.md` |

---

## Failure Handling (3-Tier Escalation)

**Tier 1: Subagent Self-Recovery**
- Debug and fix within its own session
- Retry failed actions with different parameters
- Try alternative surface or tool
- Create missing dependencies inline

**Tier 2: Orchestrator Intervention**
- Read error output and PROGRESS.md notes
- Spawn a targeted fix subagent
- Re-run original task after fix

**Tier 3: User Escalation** (last resort)
- Provide: task number, what was attempted, the error, suggested fix
- Continue with next unblocked task while waiting

---

## Session Boundaries

- PROGRESS.md enables session continuity - any new session picks up where the last left off
- If context is getting large, report progress and suggest compacting or starting fresh
- All state is in files, nothing is lost between sessions
