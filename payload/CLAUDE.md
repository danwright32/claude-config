@RTK.md
@LESSONS-INDEX.md

The lessons index above is one line per lesson: the rule, without the evidence it came from. The
full text lives in ~/.claude/LESSONS.md and is deliberately NOT loaded into the session. Read the
whole entry whenever a rule is about to decide something, with
`~/claude-config-sync/claude-sync lesson L174` or by reading the entry in that file: the body is
where the failure behind the rule is described, and the rule alone is often too short to apply
correctly.

## General Behavior

- When given a multi-part request, read and acknowledge the FULL request before starting work. Do not launch parallel agents or begin executing until the complete scope is understood. Always outline a numbered plan and wait for approval before starting, even when the steps are small.
- Whenever you ask what to do next, or offer a choice between options, present it as an AskUserQuestion clickable picker, not as a prose list. The user wants to answer by selecting.
- Ask AskUserQuestion questions ONE at a time (one question per call). Multi-question calls have lost answers mid-selection.

## Driving Dan's Machine (keyboard, mouse, screen)

- **Tell Dan BEFORE taking control of the keyboard, mouse, or screen, and wait for him to be ready** (his words, 2026-07-12: "let me know when you need to take control so I'm ready"). This covers synthetic keystrokes, clicks, and anything that steals focus.
- **Never send a keystroke without first PROVING the intended app is frontmost, and abort if it is not.** An "activate the app" step can fail silently; on 2026-07-12 a Cmd+N intended for Overture landed in Adobe Lightroom and opened a New Snapshot dialog on the photo Dan had open. Verify the frontmost process, and send nothing when it does not match.
- **Identify the target process by PID resolved from its EXECUTABLE PATH, never by app name or bundle id, and prove that PID is the right one independently of the guard that uses it.** On 2026-08-04 a Cmd+W meant for a Debug build quit Dan's live Overture instead. Two copies were running, both named `Overture`; System Events resolved `first application process whose bundle identifier is "com.danwright.overture.debug"` to the RELEASE app, and `set frontmost` on that specifier brought the Release app forward. The frontmost guard then compared the frontmost PID against the PID that same bad lookup had produced, so both sides were the wrong app, the check agreed with itself, and it passed. **A guard whose two sides come from one lookup can only ever confirm the lookup is consistent, never that it is correct.** So: get the PID from `pgrep -f <full executable path>`, assert the frontmost PID equals it AND does not equal any other candidate's, and when two builds of one app can run at once, quit the one you are not targeting so only the target exists.
- Prefer read-only inspection (a screenshot, an accessibility query of the UI tree) over anything that types or clicks. When a click is genuinely needed, target the element through the accessibility tree rather than blind screen coordinates. Confirm the action LANDED rather than assuming it did: an accessibility press can be a silent no-op (it was on every control tried on 2026-08-04, while synthetic keystrokes worked), and a modal or panel over the window can swallow a menu command with no error, so re-read the state and try another route rather than repeating the one that did nothing.

## Progress & Feedback (UI)

- **Time-taking actions must always show working / still-alive / failed as visibly distinct states.** Any action that does not return instantly (network calls, sends, detached AI or background runs, long computations) must never present a bare indefinite spinner. The user has to be able to tell, at a glance, three things apart: it actually started, it is still alive (elapsed time, a heartbeat, streamed progress, or a count), and it failed or stalled (a timeout that converts the in-progress state into an actionable error/retry). A spinner that looks identical whether the work is progressing, hung, or dead is a defect. Apply this to every such surface by default, not just the one a bug was reported on. (Dan, 2026-06-28: "that's a principle we should apply everywhere.")

## Build-Time Reliability Rules

These come from a 2026-07-06 audit of roughly 850 historical GitHub issues across all 4 active projects: the same handful of root causes kept recurring, self-discovered by Claude only after the fact instead of being caught while building. Apply these by default, not just retroactively.

- **Fail loud, not silent.** Any error path (a catch block, a background or scheduled job, a retry, a fetch against an external API) must surface failure by throwing, logging and alerting, or returning a real error, instead of silently defaulting to a blank result or a fake success. A catch block that swallows an error and returns "it worked" or an empty result is a defect, not defensive coding.
- **Assume it runs twice.** Any multi step write (reschedule, cancel, retry, background job, an operation spanning a database write plus an external API call) must be designed assuming it can run concurrently with itself, be retried, or crash mid way. Use a database constraint, a lock, or an idempotency key. Do not rely on careful ordering in application code alone.
- **Security scoping by default.** Before considering a new API route or endpoint done, explicitly state and enforce two things: who is allowed to call it (authentication) and whose data it can touch (tenant or org scoping). Do not treat authorization and data scoping as a later security pass; build them in with the route.
- **Check platform limits, not just schema.** The existing rule to read the full database schema before writing SQL also covers the platform's real operational limits: default row caps (for example Supabase PostgREST's 1,000 row cap), pagination defaults, and rate limits. Verify these before writing code that depends on a query returning everything or a request always succeeding.

## Code Editing Rules

- Before editing any file, verify you are editing the CORRECT file. If multiple files could share the same name, use Grep/Glob to find all copies and confirm which one is actively used by the project before making changes.

## Shell Commands

- Always use absolute paths in Bash commands. The working directory can reset between calls, so relative `cd apps/web` style commands fail repeatedly. Project paths may contain spaces; quote them.
- Quote glob patterns (zsh errors on unmatched globs like `--include=*.tsx`). Use `rg` or `grep -r`, not `fd` (not installed).
- Never run a command that will show an interactive prompt (wrangler, supabase, npx installers). Find the non-interactive form (flags, piped values) first; a raw y/n prompt handed to the user has derailed sessions.

## Local tooling gotchas

- `bbedit` is NOT on PATH. To open a file in BBEdit use the bundled helper: `/Applications/BBEdit.app/Contents/Helpers/bbedit_tool <file>`. Never use `open` (triggers Island browser).
- The `check-style-guide.sh` pre-push hook rejects the ENTIRE Bash call when it sees `git push` anywhere in it, before any earlier command in the chain runs. So never chain `... && git commit --amend && git push`: the amend silently never happens and the hook re-reads the old commit. Run the fix, the amend, and the push as separate Bash calls.
- Code that must NAME a forbidden character (a test asserting copy contains no em dash, a regex stripping one, a lint rule) trips that same hook, which is the hook working correctly: it cannot tell the line banning the character from the line using it. Do not reach for `SKIP_STYLE_CHECK`. Write the character as an escape instead (`/[\u2014\u2013]/`), so the file holds no literal dash and the hook has nothing to catch. Same trick for emoji (`\u{1F600}`).

## Hand-offs to Dan (manual steps)

Dan does not write code or live in the terminal. When a step genuinely requires him:
- FIRST check whether it is already done (query the system, look at the state). Do not ask him to redo something he already did.
- Give numbered steps with exactly ONE copy-paste command per code block. Nothing goes inside a block that should not be copied verbatim, no placeholders he has to notice and edit inline.
- For a manual file edit: put the find text in one code block and the replacement text in a second block, so he can cmd+F (his spec, 2026-06-25).
- NEVER put a secret value inside a command, code block, or anything that echoes to the terminal (a GitHub token was leaked this way once). For secrets: open the target env file in BBEdit with a named placeholder for him to fill in, then verify the secret landed afterward.

## Code Standards

- Use 2 space indentation where no config exists.
- TypeScript everywhere. Avoid `any`.
- **Consolidate from the start.** Before building something, check whether it duplicates logic that already exists (or that you are about to write twice) and reuse/share one implementation instead. Do not create a second copy of the same behavior and leave consolidation as a later cleanup. Dan has flagged repeated "two things doing the same job" more than once.

## Bug Fixes & Learning

- The user does not write code. All code is written by Claude. When fixing a bug, identify what mistake caused it (wrong assumption, missed constraint, incorrect API usage, etc.) and save it to memory so the same mistake is not repeated in future sessions.

## Testing & Data

- Before writing any test data, seeder code, or mock data, read the full database schema for all tables involved. List every NOT NULL constraint, check constraint, foreign key, and enum type. Write data that satisfies ALL constraints on the first attempt.
- Before ANY SQL against a real database (queries, migrations, backfills, not just test data), read the actual schema of every table involved first. Never guess a column name: guessed columns have failed dozens of times. Every data-modifying statement must report how many rows it affected.
- To run SQL or migrations, use the `/db-apply` skill (`~/.claude/skills/db-apply/SKILL.md`) instead of handing SQL to the user to run and paste back.

## Claude Code Automation (all projects)

Global hooks and skills in `~/.claude` fire in every project:
- **Test first:** when writing or changing code, use TDD. Invoke `superpowers:test-driven-development` and write a failing test before the implementation. A pre push gate blocks `git push` unless each distinct change carries a test. Override a false positive with `SKIP_TEST_CHECK=1 <push command>`.
- **The test comes in the same commit as the change.** A PUSH BLOCKED message from the gate means the process already failed upstream: stop, write the missing test, then push. Do not retry the push hoping it passes, and do not bolt tests on as an afterthought. A skip approval from the user applies to that ONE push only, never as standing permission (Dan, 2026-06-24).
- **End of turn:** after turns that changed something (edits, commands, agents), a reflection runs and an issue review offers any actionable items as an AskUserQuestion picker; durable facts are saved silently by Claude Code's built-in auto-memory. Chat-only and read-only Q&A turns skip the reflection and issue review.
- **Subagent findings are harvested, not remembered.** The issue review above is a `Stop` hook: it fires when the MAIN session stops, on a 30 minute per project cooldown, reading the main transcript. None of that reaches a subagent, so before 2026-08-16 every observation an agent made while working died with it, and a batch of parallel agents got at most one review between them. `hooks/subagent-issue-harvest.sh` is a `SubagentStop` hook that reads the finishing agent's own transcript and spools anything it noticed but was not sent to fix. It asks the agent for nothing, because an instruction to report findings is a rule living only in a prompt (L27) and reaches nothing in exactly the batches where it matters. It runs `async`, so it never delays an agent, and it runs a cheap headless Haiku pass, so it costs one small call per agent. Five things to know before changing it. **The transcript to read is `agent_transcript_path`, never `transcript_path`.** A SubagentStop payload carries both, and `transcript_path` is the transcript of the session that SPAWNED the agent. The first version read that one, which does not fail: it harvests the parent conversation and spools findings that look entirely real, and it was caught only by reading the spool file by hand (2026-08-16, three records, every one of them about the parent session). There is deliberately NO fallback to `transcript_path` in any of the three ways it can arrive wrong (absent, equal to the parent, or naming a file that is not there); each is a loud error record instead, and each error names its own cause, because the same-file guard will otherwise answer for the missing-field guard and a reintroduced fallback passes the suite (seen to survive, then caught). The spool lives at `~/.claude-issue-spool/`, deliberately OUTSIDE `~/.claude`, because anything under `~/.claude` auto pushes to the other Mac within seconds and transcript derived notes are not config. It is keyed through git's common dir, so an agent working in a worktree reaches the same spool as the session that reads it, which keying on the raw directory would not. An agent that found NOTHING still leaves a record saying it looked, and an agent whose harvest FAILED leaves a differently worded one, because otherwise both read as a project with no findings (L98, L11). And reading the spool does not empty it: only `bash ~/.claude/hooks/lib/issue-spool.sh clear "$PWD"` does, run after the picker is answered, so a review that is read and then interrupted leaves the findings behind for the next one. Filing RENAMES the pending file and then drains the copy, rather than copying and truncating, because those are two steps with no lock and anything a finishing agent appends between them is destroyed; that is the one moment worth understanding, and the test for it drives a named seam (`CLAUDE_ISSUE_SPOOL_MIDCLEAR`) rather than racing real processes, which proved nothing because the window happened not to open. Only a real FINDING beats the review's cooldown, never a failure: repeated failures are deduplicated by reason and counted, and a recurring one (a subagent kind that leaves no transcript on disk fires about once a minute here) would otherwise keep the spool permanently non-empty and fire the review on every single turn. The harvest prompt deliberately covers agents whose JOB is finding problems: excluding those as "the task it was sent to do" harvested an agent that reported seventeen concrete defects as having found nothing. And `subagent-digest.py` answers with EXIT CODES (2 unreadable, 1 read fine but the agent said nothing, 0 a digest), because it prints nothing in both of the first two cases and a caller reading only its output files a corrupt transcript as a reassuring "found nothing". **An agent can record a finding DIRECTLY, and for some agents it is the only way**: `bash ~/.claude/hooks/lib/issue-spool.sh note "$PWD" "<the finding>" "<who is reporting>"`. It costs no model call, it does not depend on a transcript existing afterwards, and it lands in the same spool the review reads, so it is worth telling every agent you dispatch to use it. **A NESTED subagent cannot be harvested at all**, and that is not a defect to chase: an agent spawned by another agent fires SubagentStop with an `agent_transcript_path` that is never written, anywhere (measured 2026-08-16, 78 of them from three agent worktrees, none of the files present minutes later, and no nested transcript written under `~/.claude/projects` at all). So a batch of agents that each spawn their own helpers reports one deduplicated HARVEST FAILED line naming the count, which is honest and cheap: the refusal happens before the model is ever called, so those cost nothing. What is genuinely lost is whatever the nested helpers noticed. Turn the whole thing off for one run with `CLAUDE_ISSUE_HARVEST_OFF=1`, and give the model call a different deadline with `CLAUDE_ISSUE_HARVEST_TIMEOUT` (default 150 seconds, deliberately under the hook's own 180 second kill, because a killed hook writes no record at all and absence of a record is the one state this design cannot represent). Tests: `bash ~/.claude/hooks/run-all-tests.sh`.
- **Plain language:** when summarizing work, explaining decisions, or flagging risks, default to plain language for a product manager. Describe technical things by what they affect.
- **Style-guide enforcement:** a pre push hook (`check-style-guide.sh`) blocks a push that introduces an em dash, en dash, or emoji in new lines, matching the Writing Style rule below. This exists because those written rules were violated repeatedly across projects even after being stated. Override with `SKIP_STYLE_CHECK=1 <push command>` for the same one time only reason as the test gate: explain to the user first, never silently.
- **Failure path test requirement:** the pre push test gate's model judge also requires that a test for code touching error handling, retries, background jobs, or external API calls exercises a failure or edge case, not only the happy path, before it counts as coverage.

## Memory

- Project specific facts go to the current project's own memory store (auto saved silently at end of substantive turns).
- Durable cross project rules and preferences go here in `~/.claude/CLAUDE.md`, which loads in every project.

## Workflow

- **Plan first on non trivial work:** for multi step, ambiguous, or architectural tasks, research and propose a short plan for approval before writing code. Do not charge straight into implementation. Trivial or mechanical edits do not need a plan.
- **Verify frontend visually:** when building or changing UI, use the browser tools to load, interact with, and screenshot the rendered result rather than editing blind.
- **Escalate planning by feature size:** for a genuinely big, ambiguous, or architectural feature, proactively suggest `/plan-council` (a panel of specialist agents that debate rival approaches and converge on the best plan). For a medium feature, suggest `/plan-lite`. Both are user invoked. Offer them at the right moment, do not run them unprompted.
- **Track big features as milestones:** `/plan-council` and `/plan-lite` offer, on approval, to create a GitHub milestone with one issue per plan phase. For a feature that did NOT start from a plan (already in flight), use `/milestone` directly. All three share `~/.claude/skills/milestone/create-milestone.sh`.
- **Every issue gets a milestone, a priority, and at least one category, always.** All three are enforced by one PreToolUse gate (`require-issue-fields.sh`) that blocks a `gh issue create` missing any of them and names every one it is missing in a single message. The full rule, the scale, and the label helpers live in one place: `~/.claude/skills/milestone/NAMING.md`. Read it rather than guessing. In short:
  - **Milestone = the overarching feature**, and its issues are what has to be finished for that feature to ship. The title NAMES the feature, with NO punctuation at all (no commas, colons or full stops, at any length) and at most 8 words (`Saved views`, `Bulk contact enrichment for scouted shows`), never a narrative sentence and never a category like `Accessibility` (categories are labels, since an issue is routinely two at once). `ensure-milestone.sh` refuses a title that is not shaped like a feature name.
  - **Creating a milestone belongs to `/plan-council`, `/plan-lite` and `/milestone` only.** It never makes sense to open one for a one-off issue. Everywhere else there are exactly two choices: an existing open milestone, or the repo's catch-all `Ungrouped` milestone, which the helper creates without approval. `Ungrouped` is a real milestone holding the standalone issues, not the absence of one.
  - **Priority is `priority-p0` to `priority-p4`**: p0 broken now, p1 do next, p2 normal (the default), p3 nice to have, p4 someday. It is the only urgency scale; `sev-*` and `severity:*` are retired. `ensure-priority-labels.sh <owner/name>` creates the five in a repo, idempotently.
  - **Category is a label, required, and unrestricted.** Every issue carries at least one label saying what it is about, and as many as genuinely apply (an accessibility fix that is also tech debt gets both). The gate checks a category is present, never which one: prefer a label the repo already has, and invent a short kebab-case one when nothing fits rather than forcing a bad match. Never `claude-suggested`.
  - **Who picks the level depends on who noticed.** If Dan reported it himself, ASK him with an AskUserQuestion picker carrying each level's meaning in its option descriptions, so the scale is in front of him as he chooses. If you found it (an audit, a sweep, the end of turn review), choose it yourself and say which in one line. Suggested issues show their proposed level and milestone in the picker, so he can correct either before anything is filed.
  - Visible overrides, explained to the user first and never silently: `SKIP_MILESTONE_CHECK=1`, `SKIP_PRIORITY_CHECK=1`, `ALLOW_ANY_MILESTONE_TITLE=1`, each good for one command only.
- **Cost aware planning:** when planning anything, default to the free or cheapest approach that does the job. Only propose a paid option when it is clearly, materially better, and when you do, present it alongside the free one as the user's choice. Never silently pick the paid path.
- **Right over fast:** when weighing how to build something, never favor an approach for being quicker or easier to build. Correctness and robustness win. Build time and effort is not a deciding factor (recurring cost still is). "Right is always better than fast."
- **Keep the issue loop moving:** when work on a GitHub issue is finished, do not stop and wait. Merge the green PR yourself (verify with `gh`, never ask Dan to merge or to confirm something you can check), run the project's post-merge deploy step if it has one, and immediately present the next recommended open issues as an AskUserQuestion picker (the `/next-issue` skill). Never end a working session with "we're done" while open issues remain. Dan's spec, stated seven times before it stuck: "You can merge and then always suggest next issues."
- **End every implementation turn with explicit git status:** pushed and merged, pushed and awaiting CI, blocked by the test gate, or intentionally local. Dan should never have to ask "did you push?".
- **Never ask permission to push.** Pushing is standing authorised (Dan, 2026-08-16: "you can always push, no need to check with me for that"), so commit and push green work as part of finishing it, and report the status afterwards rather than asking beforehand. This does not relax anything else: the test gate and style gate still decide whether a push is allowed, and the separate rule about never shipping a weakened security control without explicit sign-off still stands.
- **Scope a readiness check to each feature, not just a big sweep.** At the end of any non trivial feature, before calling it done, run a quick self check against the categories the `/production-ready` skill covers (error handling paths, auth and tenant scoping, a failure path test) scoped to just the files touched. Do not wait for an occasional large retrospective sweep to catch these; that lets gaps accumulate for a long time before anyone notices.
- **Keep docs in sync with architecture changes.** If a change touches deploy process, auth, or infrastructure, check whether the README, deploy docs, or the project's own CLAUDE.md need updating in the same PR. Docs describing a system that no longer exists have repeatedly cost time across every project audited.

## Git & Authorship

- Never include "Co-Authored-By: Claude" or any Claude attribution in commit messages, PR descriptions, code comments, file headers, or any other output. Commits should appear as if the user wrote them.
- Never run `gh auth switch` (or otherwise change the active `gh` CLI account) without asking first, even to fix a "wrong account" symptom. Dan runs concurrent sessions on the same machine under different GitHub accounts; force-switching the shared keyring's active account would silently break whatever else is using it. If a `gh` command needs a specific account, scope the call instead (e.g. `GH_TOKEN=$(gh auth token -u <account>) gh ...`) or ask before switching globally.
- Never weaken a security control (a secret scanner's allowlist, an auth check, a permission gate, a rate limit) and then apply, push, or deploy that change without the user's explicit sign-off for that specific fix, even after verifying the flagged content or behavior is a false positive. Diagnose and verify first, then stop and ask before applying and shipping the fix. A 2026-07-06 push was correctly blocked by the platform's own safety classifier for exactly this: Claude had added a secret-scanner allowlist entry and attempted to push it before asking, even though the entry was a genuine false positive.

## Projects

Active projects. Each has its own CLAUDE.md with stack details:
- `~/Documents/Bidspoke`: Next.js 14 + Cloudflare Workers + Supabase (primary)
- `~/eavesly-web-app`: Vite + React + TypeScript + shadcn/ui + Supabase
- `~/trypennie`: Next.js 15 + Prismic CMS + Google Maps
- `~/Documents/Manager Goal Tracking`: data analysis workspace (Python + Google Sheets)

## Writing Style

- No dashes as punctuation: never use em dashes, and never use hyphens or regular dashes as parenthetical breaks or sentence connectors, anywhere (conversation, code comments, file content, commit messages, any output). Hyphens are allowed only inside a word ("self-aware", "well-known", "twenty-one"); write connector phrases as separate words ("new booking", not "new-booking") or rephrase.
- Use parentheses, commas, colons, or new sentences instead.
- These rules apply to ALL generated output, not just conversation: HTML mockups, app copy, alert and email templates, Slack messages, reports, and test data. No emojis in user-facing copy or alerts unless Dan asks for them.
