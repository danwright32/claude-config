@RTK.md

## General Behavior

- When given a multi-part request, read and acknowledge the FULL request before starting work. Do not launch parallel agents or begin executing until the complete scope is understood. Always outline a numbered plan and wait for approval before starting, even when the steps are small.
- Whenever you ask what to do next, or offer a choice between options, present it as an AskUserQuestion clickable picker, not as a prose list. The user wants to answer by selecting.

## Progress & Feedback (UI)

- **Time-taking actions must always show working / still-alive / failed as visibly distinct states.** Any action that does not return instantly (network calls, sends, detached AI or background runs, long computations) must never present a bare indefinite spinner. The user has to be able to tell, at a glance, three things apart: it actually started, it is still alive (elapsed time, a heartbeat, streamed progress, or a count), and it failed or stalled (a timeout that converts the in-progress state into an actionable error/retry). A spinner that looks identical whether the work is progressing, hung, or dead is a defect. Apply this to every such surface by default, not just the one a bug was reported on. (Dan, 2026-06-28: "that's a principle we should apply everywhere.")

## Code Editing Rules

- Before editing any file, verify you are editing the CORRECT file. If multiple files could share the same name, use Grep/Glob to find all copies and confirm which one is actively used by the project before making changes.

## Code Standards

- Follow the project's existing Prettier and ESLint config. Do not override it.
- Use 2 space indentation where no config exists.
- TypeScript everywhere. Avoid `any`.
- Do not add comments unless the logic is not self evident.
- **Consolidate from the start.** Before building something, check whether it duplicates logic that already exists (or that you are about to write twice) and reuse/share one implementation instead. Do not create a second copy of the same behavior and leave consolidation as a later cleanup. Dan has flagged repeated "two things doing the same job" more than once.

## Bug Fixes & Learning

- The user does not write code. All code is written by Claude. When fixing a bug, identify what mistake caused it (wrong assumption, missed constraint, incorrect API usage, etc.) and save it to memory so the same mistake is not repeated in future sessions.

## Testing & Data

- Before writing any test data, seeder code, or mock data, read the full database schema for all tables involved. List every NOT NULL constraint, check constraint, foreign key, and enum type. Write data that satisfies ALL constraints on the first attempt.

## Claude Code Automation (all projects)

Global hooks and skills in `~/.claude` fire in every project:
- **Test first:** when writing or changing code, use TDD. Invoke `superpowers:test-driven-development` and write a failing test before the implementation. A pre push gate blocks `git push` unless each distinct change carries a test. Override a false positive with `SKIP_TEST_CHECK=1 <push command>`.
- **End of turn:** after substantive turns a reflection runs, an issue review offers any actionable items as an AskUserQuestion picker, and a memory checkpoint saves durable facts silently (no banner, no narration).
- **Plain language:** when summarizing work, explaining decisions, or flagging risks, default to plain language for a product manager. Describe technical things by what they affect.

## Memory

- Project specific facts go to the current project's own memory store (auto saved silently at end of substantive turns).
- Durable cross project rules and preferences go here in `~/.claude/CLAUDE.md`, which loads in every project.

## Workflow

- **Plan first on non trivial work:** for multi step, ambiguous, or architectural tasks, research and propose a short plan for approval before writing code. Do not charge straight into implementation. Trivial or mechanical edits do not need a plan.
- **Verify frontend visually:** when building or changing UI, use the browser tools to load, interact with, and screenshot the rendered result rather than editing blind.
- **Escalate planning by feature size:** for a genuinely big, ambiguous, or architectural feature, proactively suggest `/plan-council` (a panel of specialist agents that debate rival approaches and converge on the best plan). For a medium feature, suggest `/plan-lite`. Both are user invoked. Offer them at the right moment, do not run them unprompted.
- **Track big features as milestones:** `/plan-council` and `/plan-lite` offer, on approval, to create a GitHub milestone with one issue per plan phase. For a feature that did NOT start from a plan (already in flight), use `/milestone` directly. All three share `~/.claude/skills/milestone/create-milestone.sh`.
- **Cost aware planning:** when planning anything, default to the free or cheapest approach that does the job. Only propose a paid option when it is clearly, materially better, and when you do, present it alongside the free one as the user's choice. Never silently pick the paid path.
- **Right over fast:** when weighing how to build something, never favor an approach for being quicker or easier to build. Correctness and robustness win. Build time and effort is not a deciding factor (recurring cost still is). "Right is always better than fast."

## Git & Authorship

- Never include "Co-Authored-By: Claude" or any Claude attribution in commit messages, PR descriptions, code comments, file headers, or any other output. Commits should appear as if the user wrote them.

## Skills

- **graphify** (`~/.claude/skills/graphify/SKILL.md`): any input (code, PDFs, markdown, screenshots) to knowledge graph. Trigger: `/graphify`

## Projects

Active projects. Each has its own CLAUDE.md with stack details:
- `~/Documents/Bidspoke`: Next.js 14 + Cloudflare Workers + Supabase (primary)
- `~/eavesly-web-app`: Vite + React + TypeScript + shadcn/ui + Supabase
- `~/trypennie`: Next.js 15 + Prismic CMS + Google Maps
- `~/Documents/Manager Goal Tracking`: data analysis workspace (Python + Google Sheets)

## Writing Style

- No dashes as punctuation: never use em dashes, and never use hyphens or regular dashes as parenthetical breaks or sentence connectors, anywhere (conversation, code comments, file content, commit messages, any output). Hyphens are allowed only inside a word ("self-aware", "well-known", "twenty-one"); write connector phrases as separate words ("new booking", not "new-booking") or rephrase.
- Use parentheses, commas, colons, or new sentences instead.
