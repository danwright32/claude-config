@RTK.md
@LESSONS-INDEX.md

The lessons index above is one line per lesson, and that line is a SHORTENED form of the rule,
not the rule itself: it carries the condition and the instruction, and routinely drops the clause
saying what the failure looks like. The full sentence and the evidence live in ~/.claude/LESSONS.md,
which is deliberately NOT loaded into the session. So read the whole entry whenever a rule is about
to decide something, with `~/claude-config-sync/claude-sync lesson L174` or by reading the entry in
that file. The index line is enough to tell you a rule APPLIES; it is not enough to apply it.

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

## Building UI (what Dan corrected walking Slate, 2026-09-02 to 04)

Nine inclinations, each behind several of the 93 issues in Slate's UI Concerns milestone. The full
rule and its evidence live in LESSONS.md as L604 to L611 and L613; these are the instructions.

- **Explain the domain, never the interface (L604).** No sentence saying what a field is, what a heading contains, or what a banner will do. A domain term the reader cannot know is explained once, on the term, reachable by keyboard and screen reader, never as a paragraph over a repeated row.
- **Every fact once per screen (L605).** Read the composed page as one surface and delete every second statement: a section repeating the page title, a value repeating its header, a pill beside the control that shows the same thing, a unit in heading and placeholder and hint. One vocabulary, derived from one list, for a set of states wherever it is shown.
- **Look at it at the real count, in both themes, before merge (L606).** Every list, table, picker and repeated row is screenshotted at production scale (136 agents, 60 buckets) at a wide and a laptop window, and the screenshot goes in the PR. A two row fixture and a green suite are the two ways UI ships unseen.
- **Nothing native, nothing default (L607).** Every control and every fallback surface (error, loading, not found) is a design system one from the first commit, with its own class where the geometry differs: a select is not an input, a textarea is not an input.
- **An action says it started, says what it did, on the page you were on (L608).** Actions return an outcome; redirect and revalidate name the route the form is on; destructive controls look destructive and confirm with the specific consequence; unsaved edits are guarded on refresh and on in app navigation; a key that commits a field never also submits the form.
- **Order for the reader, not the data (L609).** First is what is done most often or most in trouble; rare, dangerous and irreversible last; the commonest value gets the quietest treatment so exceptions stand out.
- **The page's purpose is always open (L610).** No toggles, disclosures or lazy fetches over the content the reader came for, and a positive statement on the healthy day. The rare is demoted or deleted; a page empty by construction is a panel on the landing page, not a route.
- **A vocabulary in code is a picker, never a text box (L611).** Enumerate from the same constant the reader uses, refuse anything outside it on the server, and show identifiers by name.
- **Consolidation is the component plus the guard, in one change (L613).** Convert every site, ship a scan that fails on the next hand rolled copy, and delete the superseded thing with its docstring rather than rewriting its justification.

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

- `bbedit` is NOT on PATH. To open a file in BBEdit use the bundled helper WITH the front window flag: `/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window <file>`. The short form `-F` is NOT accepted: the helper prints its usage and opens nothing (2026-09-11). Without the front window flag the helper opens the file in the background, reports success, and Dan sees nothing (2026-09-09). Never use a bare `open` (triggers Island browser); `open -a BBEdit <file>` is the acceptable fallback.
- The `check-style-guide.sh` pre-push hook rejects the ENTIRE Bash call when it sees `git push` anywhere in it, before any earlier command in the chain runs. So never chain `... && git commit --amend && git push`: the amend silently never happens and the hook re-reads the old commit. Run the fix, the amend, and the push as separate Bash calls.
- Code that must NAME a forbidden character (a test asserting copy contains no em dash, a regex stripping one, a lint rule) trips that same hook, which is the hook working correctly: it cannot tell the line banning the character from the line using it. Do not reach for `SKIP_STYLE_CHECK`. Write the character as an escape instead (`/[\u2014\u2013]/`), so the file holds no literal dash and the hook has nothing to catch. Same trick for emoji (`\u{1F600}`).

## Hand-offs to Dan (manual steps)

Dan does not write code or live in the terminal. When a step genuinely requires him:
- FIRST check whether it is already done (query the system, look at the state). Do not ask him to redo something he already did.
- Give numbered steps with exactly ONE copy-paste command per code block. Nothing goes inside a block that should not be copied verbatim, no placeholders he has to notice and edit inline.
- For a manual file edit: put the find text in one code block and the replacement text in a second block, so he can cmd+F (his spec, 2026-06-25).
- **Dan cannot see files delivered into the chat.** A file card rendered in the conversation is invisible to him (his words, 2026-09-07: "i need you to open them. I cant see it in this chat"), so anything he has to LOOK at (a screenshot, a rendering, a report) must be OPENED on his screen, not just sent or named by path. Open it with the app NAMED: `open -a "Google Chrome" <file>` for an HTML page, `open -a Preview <file>` for a screenshot or a PDF. Never a bare `open`, which goes to the Island browser. Tell him focus is about to move, in the same message.
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
- **Subagent findings are harvested, not remembered.** `hooks/subagent-issue-harvest.sh` is an async `SubagentStop` hook that reads each finishing agent's own transcript and spools what it noticed but was not sent to fix into `~/.claude-issue-spool/`, which the end of turn issue review reads. What to do day to day: tell every agent you dispatch that it can record a finding directly with `bash ~/.claude/hooks/lib/issue-spool.sh note "$PWD" "<the finding>" "<who is reporting>"` (for a nested subagent, which can never be harvested, it is the only way); when a findings file carries a `TO FILE THESE` line, run that line exactly as written, never a hand built `clear`; a HARVEST FAILED count needs no action. Switch it off for one run with `CLAUDE_ISSUE_HARVEST_OFF=1`. **Before changing the harvest, the spool or either review hook, read `~/.claude/hooks/review/subagent-harvest.md` in full**: it holds the design and every measured failure behind it (`agent_transcript_path` never `transcript_path`, project keying, per session clears, ownership expiry, rename then drain, exit codes). Tests: `bash ~/.claude/hooks/run-all-tests.sh`.
- **Stale rule files are announced, not silently kept:** a session loads CLAUDE.md and its imports once, at startup, and goes on using that copy however many times they change on disk afterwards. `hooks/rule-files-changed.sh` runs on every prompt, compares a hash of each of those files against the hash this session first saw, and says once, in the session, which ones have changed underneath it. It cannot reload them (only a new session picks them up), so the notice is the whole remedy: start a new session, or read the changed file directly before relying on it. It speaks once per divergence rather than once per prompt, because a notice on every prompt is the noise it exists to prevent.
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
- **A checkout can be shared by concurrent sessions, so never delete or switch a branch this session did not create.** `git checkout` and `git branch -D` act on the whole working tree, so a branch switch moves another session's files underneath it and deleting a branch destroys the work it was standing on. On 2026-09-03 a tidy-up of an abandoned branch in the Slate checkout deleted the branch a live session was working on, and three switches moved its tree twice. So: do the work in an isolated worktree when Dan may have more than one session in that repo; if you must use the primary checkout, read `git branch --show-current` and `git status` first and leave it on the branch you found it on; and scope every `git add` to named paths, never `-A` or `.`, because an unscoped stage sweeps up another session's untracked files. **The stash is shared the same way, and a worktree does not isolate it**: `git stash pop` takes whatever is on top of the one list every worktree shares, which can be another session's work. It bites hardest through a stash push that matched NOTHING, because `git stash push -- <path>` on a file with no changes creates no entry and says nothing, so the pop that follows restores a stranger's. On 2026-09-05 that popped another session's WIP into a PostRoll worktree and, worse, left a test looking as though it passed without the fix it was meant to prove. Use `git checkout <commit> -- <path>` to set a file aside and put it back, never stash, and never pop a stash this session did not push.
- Never weaken a security control (a secret scanner's allowlist, an auth check, a permission gate, a rate limit) and then apply, push, or deploy that change without the user's explicit sign-off for that specific fix, even after verifying the flagged content or behavior is a false positive. Diagnose and verify first, then stop and ask before applying and shipping the fix. A 2026-07-06 push was correctly blocked by the platform's own safety classifier for exactly this: Claude had added a secret-scanner allowlist entry and attempted to push it before asking, even though the entry was a genuine false positive.

## Projects

Active projects, each with its own CLAUDE.md holding the stack details. Grouped by which Mac holds
the checkout, because this file is shared between both and a path that is right on one is wrong on
the other. `hooks/check-project-list.sh` reads this section and fails when a path listed under the
machine it is running on is not there, so a project that moves is reported rather than found by
searching. It checks only the block for the machine it runs on, so each Mac confirms its own half.

Paths use a tilde, never a real home directory: the sync rewrites this file for every Mac and
`check-home-paths.sh` refuses an absolute one.

On Daniels-MacBook-Pro-2:
- `~/Non-icloudDocuments/Apps/Overture`: moved here 2026-09-08, from `Photography Assets/Dan Wright Photography/Marketing/Outreach/`, after that checkout was deleted while the disk was full and the repo was re-cloned. It no longer lives anywhere surprising.
- `~/Non-icloudDocuments/Apps/Downbeat`
- `~/Non-icloudDocuments/Apps/NurseDex`
- `~/Non-icloudDocuments/Apps/PostRoll`
- `~/Non-icloudDocuments/Apps/playeditapp`
- `~/Non-icloudDocuments/Apps/repo-digest`
- `~/Non-icloudDocuments/Apps/claude-config`: this config and the sync tool, where they are developed
- `~/claude-config-sync`: the clone the scheduled sync actually runs from

On Dans-MacBook-Pro:
- `~/Documents/Bidspoke`: Next.js 14 + Cloudflare Workers + Supabase
- `~/eavesly-web-app`: Vite + React + TypeScript + shadcn/ui + Supabase
- `~/trypennie`: Next.js 15 + Prismic CMS + Google Maps
- `~/Documents/Manager Goal Tracking`: data analysis workspace (Python + Google Sheets)

The four above are where they were recorded before this section was split by machine, and their
absence from Daniels-MacBook-Pro-2 is the only evidence for putting them here. Nothing has
confirmed them on Dans-MacBook-Pro yet; the first run of the check there is what confirms or
corrects them.

## Writing Style

- No dashes as punctuation: never use em dashes, and never use hyphens or regular dashes as parenthetical breaks or sentence connectors, anywhere (conversation, code comments, file content, commit messages, any output). Hyphens are allowed only inside a word ("self-aware", "well-known", "twenty-one"); write connector phrases as separate words ("new booking", not "new-booking") or rephrase.
- Use parentheses, commas, colons, or new sentences instead.
- These rules apply to ALL generated output, not just conversation: HTML mockups, app copy, alert and email templates, Slack messages, reports, and test data. No emojis in user-facing copy or alerts unless Dan asks for them.
