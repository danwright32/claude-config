---
name: general-task-agent-orchestration
description: Universal agent orchestration framework for any complex multi-step project. Use when coordinating course creation, hiring campaigns, event planning, research projects, operations setup, content pipelines, or any task spanning multiple execution surfaces (browser, native apps, files, APIs, communication, calendar). 12-phase workflow from brain dump to fully verified, delivered output. Requires Peekaboo CLI and Playwright MCP.
---

# General Task Agent Orchestration

A universal framework for autonomous execution of any complex multi-step project. Converts a user's brain dump into a fully orchestrated, phased action plan that subagents execute autonomously with verification at every level across six execution surfaces.

## When to Use

- User has a complex project and wants to execute it end-to-end
- User wants to coordinate work across multiple execution surfaces (web, native apps, files, APIs, etc.)
- Any project that benefits from structured research, planning, and autonomous execution
- Task categories: content creation, course/curriculum, research projects, operations/workflow setup, event/project coordination, outreach/hiring

## Hard Prerequisites

- **Peekaboo CLI** must be installed (`peekaboo` command available) - macOS native UI automation
- **Playwright MCP** must be available - web browser automation
- User must be able to provide brain dump or project brief

## Six Execution Surfaces

| Surface | Primary Tool | When Used |
|---------|-------------|-----------|
| Browser (Web) | Playwright MCP | Web apps, dashboards, online platforms |
| Native macOS Apps | Peekaboo CLI | Desktop apps (Keynote, Pages, Calendar, Mail, etc.) |
| Files | Bash / Read / Write | Documents, configs, data files, exports |
| Communication | Playwright or Peekaboo | Email, messaging, notifications |
| Calendar | Playwright or Peekaboo | Scheduling, event management |
| APIs/MCPs | MCP tools / curl | External service integrations |

## Core Files

| File | Purpose |
|------|---------|
| `orchestration-workflow.md` | Complete 12-phase protocol - the master process |
| `execution-surfaces.md` | Six execution surfaces, tool mappings, verification loop |
| `artifact-templates/project-brief.md` | Initial project brief template (<500 lines) |
| `artifact-templates/research-file.md` | Research output file format |
| `artifact-templates/discovery.md` | DISCOVERY.md Q&A format with category-specific questions |
| `artifact-templates/phases.md` | PHASES.md structure with surface tags |
| `artifact-templates/task-file.md` | Individual task file template (the prompt each execution agent receives) |
| `artifact-templates/progress.md` | PROGRESS.md tracking format |
| `artifact-templates/start.md` | START.md orchestrator protocol |
| `artifact-templates/claude-md-section.md` | CLAUDE.md orchestration section template |

## Key Principles

1. **Every artifact has a template** - agents read the template before creating any artifact
2. **Parallel by default** - subagents run in background wherever independent
3. **Verification at every level** - task-local, phase verification sweep, final comprehensive check
4. **Six execution surfaces** - browser, native apps, files, communication, calendar, APIs
5. **Execute-Verify loop** - every action is verified on its target surface before moving on
6. **Tool-aware** - researches and configures MCP servers, CLIs, external services
7. **Agent-autonomous** - agents do "human steps" via Playwright and Peekaboo, only truly manual steps require user
8. **Generalizable** - works for any project type (content, courses, operations, events, hiring, research)
9. **Discovery completeness** - self-audits discovery questions before proceeding; asks "could an agent execute this without guessing?"
10. **Mandatory surface setup** - agent autonomously configures all tools and verifies access to every required surface

## Quick Start

Read `orchestration-workflow.md` for the full 12-phase protocol. Each phase references the relevant artifact templates.
