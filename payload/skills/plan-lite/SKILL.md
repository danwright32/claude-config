---
name: plan-lite
description: Quick, mid-weight planner for a feature that needs more rigor than a normal plan but doesn't warrant the full plan-council panel. Grills the user on the framing first, drafts a grounded plan, has an independent red-team agent attack it and a lessons auditor check it against the recorded past mistakes, then revises and reality-checks. Use for medium features; use /plan-council for large/ambiguous/architectural ones, and just plan inline for small changes. Invoke ONLY when the user explicitly asks for plan-lite (slash command or by name in prose); NEVER unprompted.
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion, Skill, Agent
---

# plan-lite

The middle gear between planning a small change inline and convening the full `/plan-council` panel. One drafter, one independent skeptic, a revision, a reality-check. No heavy multi-agent workflow — just enough adversarial pressure to catch the obvious holes.

Use for: medium features. For large / ambiguous / architectural features use `/plan-council`. For small or mechanical changes, just plan inline — don't invoke this.

## Steps

### 1. Frame by grilling  👤
Confirm the basics first: the feature (a sentence or two), the **project directory**, and any hard constraints or success criteria. Then take a quick read of the repo and **invoke the `grilling` skill** (`Skill` tool, skill name `grilling`) to pressure-test the framing before you draft: **one question at a time**, waiting for each answer, every question carrying YOUR recommended answer, asked through **AskUserQuestion**, and anything the code can answer gets answered by reading the code instead of being asked. Invoke `grilling`, NOT `grill-me` — `grill-me` is a user-typed command and you cannot call it.

Grill for the things a wrong answer would waste the whole draft on: the real problem and who has it, what is explicitly out of scope, what must not break, what already exists to reuse rather than rebuild, and whether the user already holds a strong preference on the approach. Keep it proportionate — this is the middle gear, so stop as soon as the answers stop changing your understanding. If the grilling reveals heavy framing or genuinely rival approaches worth scoring against each other, stop and suggest `/plan-council` instead.

### 2. Draft (grounded)
Read the real code: the relevant files, the project's CLAUDE.md, and the live Supabase schema (MCP) if the feature touches data. **If the plan will read, parse, classify, or geo-locate external source pages, also fetch a real example of each source FIRST and quote its raw strings into the draft** (for a scraper the external pages are part of the system under design; grounding only in the code produces plans that are internally rigorous and wrong about the world). Write a concrete, phased plan. Do NOT invent files, APIs, or tables — only reference what you've verified exists. If you can't reach the code or schema, say so plainly rather than guessing — and note exactly what you couldn't reach so you can flag it at the end (step 5). Weigh cost: default to the free/cheapest approach; if a paid option would be meaningfully better, present it alongside the free one and let the user choose (step 5) — never silently pick a paid path. Don't favor an approach for being quicker to build — right beats fast; build effort is not a factor (recurring cost still is).

### 3. Independent red-team + lessons audit (Agent tool)
Spawn TWO subagents with the **Agent** tool, in one message so they run concurrently. A separate agent (not your own re-read) is what keeps either critique genuinely independent — you cannot audit your own draft, because the reading and the writing come from the same assumptions.

1. **Red-team** — its only job is to attack the draft: "Here is a plan for <feature>. Try to find its real failure modes, wrong assumptions about the codebase, missing edge cases, and hidden costs. Be skeptical; assume it has at least one serious flaw and find it." Pass it the draft plan and enough context to ground itself.
2. **Lessons auditor** — tell it to read `~/.claude/LESSONS.md` in full plus the build-time rules in `~/.claude/CLAUDE.md`, then report every place the plan repeats a mistake already recorded there, or plainly ignores a lesson that applies (a background job with no alert on failure or on a missing run, a guard that fails open, a multi-step write that breaks if it runs twice, a route with no stated caller and no tenant scoping, a destructive step with no backup or undo, an error rendered as an empty state, a test that cannot fail). Each finding: the lesson id, the exact part of the plan at fault, why it is the same mistake, and the concrete fix. Require it to state whether it actually read the lessons file — an audit that could not read it reports **"could not audit"**, never "clean".

### 4. Revise + reality-check
Revise the plan to address each red-team point and each lesson violation (or note why you're pushing back on one, with your reason — never silently drop it). Fix violations **in the plan itself**, changing the design, not by appending a note beside it. Then quickly re-verify the revised plan's concrete claims against the actual code/schema.

### 5. Present  👤
- **Grounding first:** if you could NOT read the relevant code or reach the Supabase schema, LEAD with that — warn which parts are best-effort / ungrounded and name what you couldn't reach. A confident plan built blind is the main risk.
- **Lessons audit next:** any violation you did NOT fix gets led with, by lesson id, along with why you pushed back. If the auditor could not read the lessons file, say plainly that the plan was never checked against them, because unaudited is not clean and must never be reported as "no issues found". If it came back clean, one line saying so is enough.
- Give a plain-language summary: the plan, what the red-team caught and how you handled it, and any open risks.
- If a genuine values trade-off remains (only the user can decide), present it with **AskUserQuestion**, not prose.

### 6. Offer a tracking milestone  👤
After the plan is settled, offer to turn it into a GitHub milestone with one issue per phase, the standard way to track a feature. This is one of the only three places a milestone gets created (`/plan-council` and `/milestone` are the others), so the title matters: it NAMES the feature, with NO punctuation at all (a comma or colon is refused at any length) and at most 8 words (`Saved views`, `Bulk contact enrichment for scouted shows`), never a narrative sentence and never a category like `Accessibility`, since categories are labels. The helper refuses a title that is not shaped like a feature name. Every issue also needs a `priority-p0` to `priority-p4` label and at least one category label, both of which you choose per phase (these are your plan's phases, not something Dan should have to grade). The helper files nothing if any phase is missing either. Both rules: `~/.claude/skills/milestone/NAMING.md`.

Ask with **AskUserQuestion**; skip silently if declined. On yes, confirm the repo (`gh repo view --json nameWithOwner -q .nameWithOwner` from the project dir, then confirm with the user), build a temp JSON (`title` = feature, `description` = short summary, `issues` = one `{title, body, priority, labels}` per plan phase), preview, then create:

    DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>   # preview
    bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>             # create

Relay the `MILESTONE <url>`. Same helper as `/plan-council` and `/milestone`.

## Notes
- Much cheaper than `/plan-council` (two subagents vs. a full panel). If midway it's clear the feature has several genuinely competing approaches worth scoring against each other, stop and recommend `/plan-council`.
- Appears after a Claude Code restart (new skill).
