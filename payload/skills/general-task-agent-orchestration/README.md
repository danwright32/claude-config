# General Task Agent Orchestration

A Claude Code skill that converts any complex multi-step project into a fully orchestrated, phased action plan with autonomous agent execution across six surfaces.

## What It Does

Give it a brain dump (paragraph, doc, voice-to-text, conversation) and it transforms it through a 12-phase protocol into an autonomously executable project with verification at every step.

Works for **any complex task**:
- Content creation and publishing pipelines
- Course and curriculum design
- Research projects
- Operations and workflow setup
- Event and project coordination
- Outreach and hiring campaigns

---

## Prerequisites Setup

### 1. Claude Code

Install Claude Code if you haven't: https://docs.anthropic.com/en/docs/claude-code

### 2. Claude in Chrome (Web Browser Automation)

Install the Claude in Chrome extension and connect it to Claude Code. Agents read pages with WebFetch and interact with web apps through Claude in Chrome, each in a tab it creates.

Verify it works by asking Claude Code to open a new tab and navigate to any website.

Agents do not use Playwright MCP. Execution agents are subagents, and Playwright MCP is one browser shared by the whole session, so a parallel agent can navigate the page another is reading; a hook refuses every Playwright call from a subagent. Browser work that truly needs Playwright stays in the main session.

### 3. Peekaboo CLI (macOS Native UI Automation)

Peekaboo lets Claude see and interact with any macOS application - Keynote, Calendar, Mail, Finder, or any third-party app.

Install via Homebrew:

```bash
brew install withpeekaboo/tap/peekaboo
```

Or visit https://peekaboo.dev for alternative install methods.

Verify it's installed:

```bash
peekaboo --version
```

### 4. macOS Permissions (Required for Peekaboo)

Peekaboo needs two macOS permissions. Grant these in **System Settings > Privacy & Security**:

1. **Screen Recording** - Add your terminal app (Terminal, iTerm2, Warp, etc.)
2. **Accessibility** - Add your terminal app

Check permission status:

```bash
peekaboo list permissions
```

Both should show "Granted" before proceeding. You may need to restart your terminal after granting permissions.

---

## Installation

Copy the skill folder into your Claude Code skills directory:

```bash
cp -r general-task-agent-orchestration ~/.claude/skills/general-task-agent-orchestration
```

### Verify Installation

Claude Code auto-detects skills via SKILL.md. Test by telling Claude:

> "Orchestrate a course launch"

Claude should activate the skill and begin the 12-phase workflow.

---

## The 12-Phase Protocol

| Phase | Name | What Happens |
|-------|------|-------------|
| 0 | Setup | Verify Claude in Chrome + Peekaboo, create orchestration folder |
| 1 | Brain Dump to Project Brief | Synthesize user input into structured brief |
| 2 | First Research Wave | Parallel subagents research each domain |
| 3 | Discovery | Comprehensive Q&A with user, category-specific questions |
| 4 | Second Research Wave | Execution-focused research filtered by user decisions |
| 5 | Tool + Surface Setup | Install and configure all tools, verify surface access |
| 6 | Surface Verification | Formal verification report - all tools/surfaces tested |
| 7 | Skill Creation | Create knowledge packets for every tool/domain/strategy |
| 8 | Context Compact | User compacts context; state is in files |
| 9 | PHASES.md | Master action plan with surface-tagged tasks |
| 10 | Task Sharding | Expand plan into detailed per-task files |
| 11 | Synergy Review | Cross-phase and cross-surface coherence check |
| 12 | Final Artifacts | PROGRESS.md, START.md, CLAUDE.md section |

## Six Execution Surfaces

The key differentiator - agents don't just write files, they operate across six real-world surfaces:

| Surface | Tool | What It Covers |
|---------|------|---------------|
| Browser (Web) | WebFetch / Claude in Chrome | Web apps, dashboards, SaaS platforms |
| Native macOS | Peekaboo CLI | Desktop apps (Keynote, Calendar, Mail, any app) |
| Files | Bash / Read / Write | Documents, configs, data, scripts |
| Communication | Claude in Chrome / Peekaboo | Email, messaging, notifications |
| Calendar | Claude in Chrome / Peekaboo | Scheduling, events, time blocks |
| APIs/MCPs | MCP tools / curl | External services, integrations |

## Verification Loop

Every action follows: **Execute -> Verify -> (fail?) Analyze -> Adjust -> Retry (max 3) -> Escalate**

Each surface has its own verification method (snapshots, screenshots, file reads, API calls). Evidence is recorded in PROGRESS.md so nothing is assumed - everything is proven.

## File Structure

```
general-task-agent-orchestration/
  SKILL.md                              # Entry point, auto-discovered by Claude Code
  README.md                             # This file
  orchestration-workflow.md             # Master 12-phase protocol
  execution-surfaces.md                 # 6 surfaces, tool mappings, verification loop
  artifact-templates/
    project-brief.md                    # Project brief template (Phase 1)
    research-file.md                    # Research output format (Phases 2, 4)
    discovery.md                        # Discovery Q&A with category-specific questions (Phase 3)
    phases.md                           # Action phases template (Phase 9)
    task-file.md                        # Per-task spec with surface tags (Phase 10)
    progress.md                         # Progress tracker template (Phase 12)
    start.md                            # Orchestrator protocol (Phase 12)
    claude-md-section.md                # CLAUDE.md section template (Phase 12)
```

## Usage Examples

```
"Orchestrate a 6-module online course on machine learning"
"Orchestrate a hiring campaign for 3 engineering roles"
"Orchestrate a product launch event for next month"
"Orchestrate a content pipeline for weekly newsletter + social"
"Orchestrate setting up our team's project management workflow"
"Orchestrate a market research study on AI adoption"
```

## Troubleshooting

### "Peekaboo not found"

Make sure Peekaboo is on your PATH:

```bash
which peekaboo
```

If not found, reinstall or add to PATH manually.

### "Screen recording permission required"

Grant Screen Recording permission to your terminal app in System Settings > Privacy & Security > Screen Recording. Restart the terminal after granting.

### "Claude in Chrome not available"

Check the extension is installed and enabled in Chrome, then run `/chrome` in Claude Code to reconnect it.

### "Playwright refused for a subagent"

That refusal is deliberate. Move the step to Claude in Chrome in the agent's own tab, or to WebFetch if it only reads, or run it in the main session.

---

Built for the [Agent Architects](https://www.skool.com/agent-architects) community.
