---
name: plan-council
description: Plan a big or ambiguous feature by first grilling the user on the framing, then convening a panel of independent expert role-agents (architect, frontend, backend, data, security, …) that each propose an approach, distill into 2-3 rival whole options, champion and red-team them, score against criteria set up front, and synthesize the BEST (not merely doable) plan — then reality-check it against the real codebase, audit it against the recorded lessons from past mistakes, and post the debate + plan to a GitHub Discussion. Use for large, ambiguous, or architectural features worth deep planning. Invoke ONLY when the user explicitly asks for plan-council (slash command or by name in prose); NEVER unprompted (spawns many agents).
allowed-tools: Read, Glob, Grep, Bash, WebFetch, AskUserQuestion, Skill, Workflow, Agent
---

# plan-council

A heavyweight, robust planner for big features. A panel of independent specialist agents debate rival approaches and converge on the **best** plan — not the most agreeable one. The real multi-agent debate runs through the **Workflow engine** (genuinely independent subagents, so the anti-groupthink design actually holds); this skill handles the framing conversation, the GitHub record, and presenting decisions to the user.

Use for: large, ambiguous, or architectural features. NOT for small or mechanical changes — use normal planning there.

Gates marked 👤 require the user before continuing.

## 1. Frame the problem  👤
**First, a gate — does this even need the panel?** Research shows a single strong pass beats a multi-agent panel on most tasks. Only run plan-council when the feature is genuinely big: multiple defensible approaches worth scoring against each other, cross-cutting impact, or real architectural uncertainty. If it is only medium, recommend `/plan-lite`; if small, just plan inline. Don't reach for the panel out of habit.

Then, in conversation with the user, establish:
- The **feature** (one or two sentences), the **target project directory** (so agents read the right repo), and its **GitHub repo** (owner/name).
- **Hard constraints** (stack, deadlines, must-not-break, compliance).
- **Success criteria** — what "done well" means.
- The **roles that matter for THIS feature** — pick 3-6; do not use a fixed cast. Reusable definitions live in `~/.claude/agents/` (plan-architect, plan-product, plan-backend, plan-frontend, plan-ux, plan-data, plan-security, plan-redteam). Pass each chosen role in `args.roles` as `{ key, brief, agentType: 'plan-<role>' }` so the workflow spawns the real definition; add an ad-hoc role (key + brief, no agentType) when none fits.
- The **weighted criteria that define "best"** — always include **cost / recurring spend** (default stance: prefer free; a paid option must clearly earn its bill), plus e.g. correctness & robustness, user impact, maintainability, risk/reversibility. Do NOT include build time / effort as a criterion — the user's standing rule is "right is always better than fast." SET THESE NOW, before any option exists, so "best" cannot be bent toward the easy option later.

**GRILL the user to close context gaps — BEFORE the panel disperses.** Once the workflow launches, the specialist agents run in parallel and CANNOT ask you anything; whatever context they're missing, they'll guess. So the main agent's job at this gate is to surface and fill those gaps now, and a few batched questions are not enough pressure to find them.

First take a quick read of the repo so your questions are sharp and specific, not generic. Then **invoke the `grilling` skill** (`Skill` tool, skill name `grilling`) and run the interview it describes: **one question at a time**, waiting for each answer before asking the next, every question carrying YOUR recommended answer, and anything the codebase can answer gets answered by reading the codebase instead of being asked. Ask through **AskUserQuestion** so each one is a picker. Invoke `grilling`, NOT `grill-me` — `grill-me` is a user-typed command (`disable-model-invocation: true`) and you cannot call it.

The grilling is not optional and not a formality: this is the last moment a human can correct the panel's understanding, and a wrong premise here is paid for by every agent downstream. Cover all of the following, plus whatever the repo read makes you suspicious of:
- What problem are we really solving, and for whom? (the intent behind the feature, not just the feature)
- What is explicitly IN and OUT of scope?
- Known constraints or landmines — things that must not break, past attempts that failed, hard deadlines, the budget ceiling.
- Existing code/work to reuse vs. replace (name the specific things you found in the repo).
- What does "done well" look like, and do you already hold a strong preference on the approach?

Ask only what you genuinely cannot determine from the code yourself — don't quiz the user on what a quick read answers. Keep grilling until you could hand the panel a brief with no critical unknowns left; stop when the answers stop changing your understanding, not after a fixed number of questions.

**If the plan will read, parse, classify, or geo-locate external source pages, fetch a real example of each source FIRST and quote its raw strings into the framing**, the same way you read the DB schema before writing SQL. For a scraper the external pages ARE part of the system under design; grounding only in the code produces plans that are internally rigorous and wrong about the world. On a past run the panel fitted a parser to the one source it had ever scouted and picked a winner that two 30-second `WebFetch` calls then refuted. Hand the panel those verbatim snippets so it designs against the real pages, not the exception.

Then present the full framing (roles + criteria + scope + what you learned in the interview) with **AskUserQuestion** for approval or edits. Do not skip this gate — it is what keeps the run grounded and cheap-to-correct, and it is the user's last input before the panel runs autonomously.

## 2. Run the debate (Workflow engine)
Call the **Workflow** tool with:

    {
      scriptPath: "<HOME>/.claude/skills/plan-council/panel.workflow.js",
      args: {
        feature: "<the feature>",
        constraints: "<hard constraints>",
        weightedCriteria: "<criteria + weights agreed above>",
        roles: [ { key: "architect", brief: "…" }, { key: "backend", brief: "…" } ],
        projectDir: "<absolute path to the repo>",
        repo: "<owner/name>"
      }
    }

Substitute `<HOME>` with this machine's home directory (run `echo $HOME`). It is a placeholder because this config syncs between two Macs whose home directories differ, and the Workflow tool takes `scriptPath` as a literal string: it does not expand `~` or `$HOME`.

It starts with a **preflight** that confirms it can actually reach your code and database, then runs with real independent subagents: independent first-passes → distill to 2-3 rival whole options → champion + red-team each → score against the criteria and pick the survivor → synthesize the winner (grafting the runner-up's best ideas, recording overruled dissent and the ideal-vs-doable gap) → **reality-check** against the actual codebase/schema, alongside a **lessons audit** that reads `~/.claude/LESSONS.md` and flags anywhere the plan repeats a mistake already paid for on a past project → **fix-and-reverify**: if either check finds a problem (a broken file path, or a design that repeats a recorded defect), it corrects the plan *inline* and re-runs both checks (up to 2 rounds), so the plan you read carries neither known-wrong citations nor known-bad designs. The rival options always span a **cost spread** (at least one free/cheapest; a paid option only when clearly better), and every product / scope / cost trade-off — including free-vs-paid — is **escalated to you, not locked by the panel**. It returns `{ plan, selection, options, advocacy, realityCheck, lessonsAudit, preflight, rcRounds, … }`.

## 3. Record to GitHub (the audit surface)
Build a markdown body (final plan, rival options + scores, overruled dissent, ideal-vs-doable gap, open risks, reality-check verdict) and write it to a temp file. Then run the bundled helper, which handles every fallback for you:

    bash ~/.claude/skills/plan-council/post-discussion.sh "<owner/name>" "<title>" <body-file> "<milestone title, optional>"

It tries a GitHub Discussion first, then a tracking issue, then a local `PLAN-<slug>.md`, and prints one line: `DISCUSSION <url>`, `ISSUE <url>`, or `FILE <path>`. Tell the user which happened (and, if it fell back, that enabling Discussions on the repo would give a nicer home next time).

If it fell back to an issue and also printed `NO-MILESTONE <url> ...`, that issue has no milestone yet, because the plan's milestone does not exist until step 5. **Carry that URL to step 5 and attach it there.** Do not leave it orphaned.

## 4. Present + decide  👤
Open with any CAVEATS before the summary — the user must never mistake a partly-checked plan for a clean one:
- **If the plan is still unverified, say so LOUDLY first.** The workflow auto-corrects wrong references but only tries twice (see `rcRounds`). If the returned `realityCheck.verdict` is still `needs-fixes` or `realityCheck.broken` is non-empty, LEAD your reply with a prominent warning that the plan still contains unverified or wrong claims, and list them. Do not bury this below the summary.
- **Check the lessons audit next.** The workflow audits the plan against `~/.claude/LESSONS.md` and tries to correct violations inline, same as the reality-check. Read `lessonsAudit`:
  - `violations` non-empty after the fix rounds → LEAD with them, each with its lesson id and the part of the plan at fault. These are mistakes already paid for on a past project, so they are not stylistic notes.
  - `verdict: "could-not-audit"`, or `lessonsFileRead: false`, or `lessonsSeen: 0` → say plainly that the plan was **never checked** against the lessons. Unaudited is not clean, and it must never be reported as "no issues found".
  - Clean audit → one line saying it was checked against the recorded lessons and how many were considered. Do not inflate this into a guarantee.
- **Check grounding next:** if `preflight` reported `repoReadable:false` or `schemaReachable:false`, lead with that too — warn the user the plan may be partly ungrounded and name the unreachable source (e.g. "Supabase wasn't connected for this project, so the data parts are best-effort"). A confident plan built blind is the main risk.
- Give a plain-language summary: the recommended plan, why it won over the alternatives, the ideal-vs-doable gap, and the reality-check verdict — especially anything the reality-check found **broken**.
- If the workflow returned **escalatedDecisions** (genuine values trade-offs only the user should make), present them with **AskUserQuestion** — never bury them in prose.
- Link the GitHub Discussion (or note the fallback artifact).

## 5. Offer a tracking milestone  👤
Once the plan is approved, offer to turn it into a GitHub milestone with one issue per plan phase — this is how big features get tracked. Ask with **AskUserQuestion** ("Create a GitHub milestone + one issue per phase for this plan?"); skip silently if the user declines. On yes:
1. Build a temp JSON file: `title` = the feature, `description` = a short summary plus the Discussion/issue link from step 3, `issues` = one `{title, body, priority, labels}` per phase of the synthesized plan (phase name as title, the phase's scope as body).

   This is one of only three places a milestone gets created (`/plan-lite` and `/milestone` are the others), so the title matters: it NAMES the feature, with NO punctuation at all (a comma or colon is refused at any length) and at most 8 words (`Saved views`, `Bulk contact enrichment for scouted shows`), never a narrative sentence and never a category like `Accessibility`, since categories are labels and an issue can be two at once. The helper exits 8 refusing a title that is not shaped like a feature name. Every issue also needs a `priority-p0` to `priority-p4` label and at least one category label, both of which you choose per phase. The helper files nothing if any phase is missing either. Both rules: `~/.claude/skills/milestone/NAMING.md`.
2. Preview with a dry run, then create:

       DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>   # preview
       bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>             # create

3. Relay the milestone URL it prints. Same helper backs `/plan-lite` and `/milestone`, so milestones look identical across all three paths. The helper reuses an existing milestone with that title rather than creating a second one, and stops to ask if the title closely resembles an open milestone.
4. If step 3 printed `NO-MILESTONE <url>`, adopt that tracking issue into the milestone now, so the plan record lives with the work it describes:

       gh issue edit <url> --milestone "<milestone title>"

## Revise mode — fold in the user's GitHub comments
When the user has commented on the Discussion and wants the plan updated (e.g. "revise the plan-council plan from <discussion-url>"):
1. Fetch the discussion body + comments for that URL with `gh api graphql` (or `gh` REST).
2. Call the **Workflow** tool with the same `scriptPath` and args, plus `mode: "revise"`, `priorPlan: "<original plan text>"`, and `comments: "<fetched comments>"`. It runs a lighter revise → reality-check path and returns `{ revised: { plan, responses, openRisks }, realityCheck }`.
3. Post the revised plan back as an update/comment on the same Discussion (reuse the helper or `gh`), and show the user the point-by-point `responses` for how each comment was handled.

## Notes
- **Cost is intended.** At full rigor this spawns many agents per run (independent passes + a champion and red-team per option + judge + synthesizer + verifier). That depth is the point; it is why this is user-invoked only.
- **Grounding is mandatory.** Every agent is told to read the real code, CLAUDE.md, and the Supabase schema (MCP) and to verify files/APIs/tables exist. A plan that is internally agreed but wrong about the codebase is exactly the failure the reality-check phase exists to catch.
- **The recorded lessons are part of the debate, not just a final filter.** The red-team is told to cite lesson ids, the judge weights a cited lesson above a hypothetical objection, and the synthesizer is told to design against the file before writing. The audit phase is the backstop, so a violation reaching it means the earlier phases missed it.
- **Revise mode gets the same treatment**, with one bounded correction round rather than two.
- **First run = the prototype.** Expect to tune the roles, criteria, and phase prompts after seeing it work once on a real feature.
