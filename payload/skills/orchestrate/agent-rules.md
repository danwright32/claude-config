# Rules for an agent working one item of an orchestrated list

You are one of several agents, each working one item while the orchestrator session coordinates. Your brief says what your item is, where to work and what belongs to other agents. These rules apply to every item.

## Scope

- Work only your item. Something else you notice gets recorded, not fixed:
  `bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "<item number> agent"`
- Never touch anything your brief names as another agent's.
- Write working files only under the scratchpad folder your brief names.

## Building

- Build in your own worktree, never in the main checkout, and never switch its branch:
  `git -C <repo> fetch origin`
  `git -C <repo> worktree add <worktree path> -b <branch> origin/main`
- Use absolute literal paths, one plain command per call: no shell variables, no loops.
- Test first with `superpowers:test-driven-development`. The test goes in the same commit as the fix and covers a failure path, not only the happy path. Run the project's whole suite, typecheck and build.
- Write the commit message to a file and commit with `git commit -F <file>`. End it with the `Claude-Session:` line from your brief. Nothing may say or suggest Claude wrote the work.
- No dashes as punctuation and no emoji in new lines. Never use `SKIP_TEST_CHECK`, `SKIP_STYLE_CHECK` or any other override; if a hook blocks you, fix the cause.
- Push your branch. Do not open or merge a pull request. Write the PR description to `pr-body.md` in your scratchpad folder, ending with the session link line from your brief.

## Never do these yourself

Delete or drop data, apply migrations to a shared database, send anything to people, re-run a job that has side effects, change production settings, or spend money. Draft the action and its rollback, and report it for Dan to decide. Against production data, run read only queries and never print customer rows.

## Tools

- Never drive the Playwright browser. Read pages with WebFetch, or with the Claude in Chrome tools in a tab you create.
- Never end your turn waiting on your own background work. Wait in the foreground or stop it. Stop any dev server you started before you hand back.

## Your report

Hand back one report, in this order:

1. Outcome in one sentence.
2. Cause, with evidence (counts, times in ET, the change responsible). Say plainly what you could not access.
3. What you changed: branch, commit sha and the path to `pr-body.md`, or "no change".
4. Tests: the output of the new test failing before the fix, and the final counts run against the counts that exist.
5. What you could not verify.
6. Anything that needs Dan's decision, with the options and what each one does.
