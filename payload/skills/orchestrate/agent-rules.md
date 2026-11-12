# Rules for an agent working one item of an orchestrated list

You are one of several agents, each working one item while the orchestrator session coordinates. Your brief says what your item is, where to work and what belongs to other agents. These rules apply to every item.

## Scope

- Work only your item. Something else you notice gets recorded, not fixed:
  `bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "<item number> agent"`
- Never touch anything your brief names as another agent's.
- Write working files only under the working folder your brief names, which is in the session's notes folder (`~/.claude/state/session-notes/...`), never in the scratchpad under `/private/tmp`: a restart of the Mac empties that (claude-config#2490).

## Reading code

- Find the place first with `grep -n` or `rg -n`, then read only those lines and about 30 around them, at most 150 lines in one read. Never read a whole large file to look around. Everything you read is read again on every later request you make.
- When a notice says you are past the context line, do what it says: write `handoff.md` in your working folder, then hand back unless only the push and the report are left. The orchestrator gives the rest to a fresh agent that starts from your note.

## Building

- Build in your own worktree, never in the main checkout, and never switch its branch:
  `git -C <repo> fetch origin`
  `git -C <repo> worktree add <worktree path> -b <branch> origin/main`
  The worktree path is the one your brief names, inside the repository's own `.claude/worktrees/` folder. Never put a worktree under `/tmp`, `/private/tmp` or the scratchpad: a restart of the Mac empties them, and an uncommitted fix goes with it (claude-config#2490).
- Then read `git -C <worktree path> config --get core.hooksPath`. When it names a folder that is not there in the worktree, run the install that creates it in the worktree before your first commit (`pnpm install` beside a `pnpm-lock.yaml`, and likewise for yarn, bun or npm). Until that folder exists git runs none of the repository's own hooks, on a commit or a push, and `push-scope-notice.sh` refuses your push (claude-config#2070, #2098).
- Use absolute literal paths, one plain command per call: no shell variables, no loops.
- Test first with `superpowers:test-driven-development`. The test goes in the same commit as the fix and covers a failure path, not only the happy path. Run the project's whole suite, typecheck and build.
- Write the commit message to a file and commit with `git commit -F <file>`. End it with the `Claude-Session:` line from your brief. Nothing may say or suggest Claude wrote the work.
- No dashes as punctuation and no emoji in new lines. Never use `SKIP_TEST_CHECK`, `SKIP_STYLE_CHECK` or any other override; if a hook blocks you, fix the cause.
- Push your branch. Do not open or merge a pull request. Write the PR description to `pr-body.md` in your working folder, ending with the session link line from your brief.

## Never do these yourself

Delete or drop data, apply migrations to a shared database, send anything to people, re-run a job that has side effects, change production settings, or spend money. Draft the action and its rollback, and report it for Dan to decide. Against production data, run read only queries and never print customer rows.

## Tools

- Never drive the Playwright browser. Read pages with WebFetch, or with the Claude in Chrome tools in a tab you create.
- With the Claude in Chrome tools, call `tabs_create_mcp` once, keep the tabId it returns, and pass that tabId on every Claude in Chrome call, each call inside `browser_batch` included. Every agent shares one tab group, and a call naming no tab acts on the group's first tab, which can be another agent's. Never use a tabId read from `tabs_context_mcp`, which lists every agent's tabs. Close your tab with `tabs_close_mcp` before you hand back. `hooks/chrome-subagent-tab-gate.sh` refuses a call from you that names no tabId.
- Never end your turn waiting on your own background work. Wait in the foreground or stop it. Stop any dev server you started before you hand back.

## Your report

Hand back one report of at most 300 words, in this order. Detail goes in files in your working folder, named in the report, for the orchestrator to read only when it needs them: the full test output in `tests.txt`, the evidence in `evidence.md`. Never write a `.md` file whose name starts with findings, report, summary or analysis (any case): Claude Code's Write tool refuses that name from a subagent whatever the file holds (claude-config#2671), so use the names given here.

1. Outcome in one sentence.
2. Cause, with the evidence that settles it (counts, times in ET, the change responsible). Say plainly what you could not access.
3. What you changed: branch, commit sha and the path to `pr-body.md`, or "no change".
4. Tests: the new test's failing line before the fix, and the final counts run against the counts that exist.
5. What you could not verify.
6. Anything that needs Dan's decision, with the options and what each one does.
