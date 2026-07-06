---
name: plan-lite
description: Quick, mid-weight planner for a feature that needs more rigor than a normal plan but doesn't warrant the full plan-council panel. Drafts a grounded plan, has ONE independent red-team agent attack it, then revises and reality-checks. Use for medium features; use /plan-council for large/ambiguous/architectural ones, and just plan inline for small changes. Invoke ONLY when the user explicitly asks for plan-lite (slash command or by name in prose); NEVER unprompted.
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion, Agent
---

# plan-lite

The middle gear between planning a small change inline and convening the full `/plan-council` panel. One drafter, one independent skeptic, a revision, a reality-check. No heavy multi-agent workflow — just enough adversarial pressure to catch the obvious holes.

Use for: medium features. For large / ambiguous / architectural features use `/plan-council`. For small or mechanical changes, just plan inline — don't invoke this.

## Steps

### 1. Quick frame  👤
In one short exchange, confirm: the feature (a sentence or two), the **project directory**, and any hard constraints or success criteria the user cares about. Keep this light — if it needs heavy framing or has genuinely rival approaches, suggest `/plan-council` instead.

### 2. Draft (grounded)
Read the real code: the relevant files, the project's CLAUDE.md, and the live Supabase schema (MCP) if the feature touches data. Write a concrete, phased plan. Do NOT invent files, APIs, or tables — only reference what you've verified exists. If you can't reach the code or schema, say so plainly rather than guessing — and note exactly what you couldn't reach so you can flag it at the end (step 5). Weigh cost: default to the free/cheapest approach; if a paid option would be meaningfully better, present it alongside the free one and let the user choose (step 5) — never silently pick a paid path. Don't favor an approach for being quicker to build — right beats fast; build effort is not a factor (recurring cost still is).

### 3. Independent red-team (Agent tool)
Spawn ONE subagent with the **Agent** tool whose only job is to attack the draft: "Here is a plan for <feature>. Try to find its real failure modes, wrong assumptions about the codebase, missing edge cases, and hidden costs. Be skeptical; assume it has at least one serious flaw and find it." Pass it the draft plan and enough context to ground itself. Using a separate agent (not your own re-read) is what keeps the critique genuinely independent.

### 4. Revise + reality-check
Revise the plan to address each red-team point (or note why you're pushing back). Then quickly re-verify the revised plan's concrete claims against the actual code/schema.

### 5. Present  👤
- **Grounding first:** if you could NOT read the relevant code or reach the Supabase schema, LEAD with that — warn which parts are best-effort / ungrounded and name what you couldn't reach. A confident plan built blind is the main risk.
- Give a plain-language summary: the plan, what the red-team caught and how you handled it, and any open risks.
- If a genuine values trade-off remains (only the user can decide), present it with **AskUserQuestion**, not prose.

### 6. Offer a tracking milestone  👤
After the plan is settled, offer to turn it into a GitHub milestone with one issue per phase — the standard way to track a feature. Ask with **AskUserQuestion**; skip silently if declined. On yes, confirm the repo (`gh repo view --json nameWithOwner -q .nameWithOwner` from the project dir, then confirm with the user), build a temp JSON (`title` = feature, `description` = short summary, `issues` = one `{title, body}` per plan phase), preview, then create:

    DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>   # preview
    bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>             # create

Relay the `MILESTONE <url>`. Same helper as `/plan-council` and `/milestone`.

## Notes
- Much cheaper than `/plan-council` (a couple of agents vs. a full panel). If midway it's clear the feature has several genuinely competing approaches worth scoring against each other, stop and recommend `/plan-council`.
- Appears after a Claude Code restart (new skill).
