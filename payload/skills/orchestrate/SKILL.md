---
name: orchestrate
description: Use when Dan asks this session to act as an orchestrator, hands over a list of alerts, bugs or things to check on and wants a subagent working each one, or types /orchestrate. Also use when he adds items to a list already being orchestrated.
---

# orchestrate

Dan hands over a list and wants each item worked by its own subagent while this session coordinates. This session plans, briefs, queues, reviews and merges. It never works an item itself, and agents never merge their own pull requests.

## 1. Intake

Number every item and say it back in one line, in Dan's words. Settle what you can check cheaply before planning: which repo and checkout each item lives in, whether an alert is still firing. Ask Dan only about an item you cannot place, one picker per question.

## 2. Dispatch board

Build the board, one row per item:

| # | Item | Repo and area | Kind | Agent | Model | Wave | Waits on |
|---|---|---|---|---|---|---|---|

Kind is `check` (read only answer), `investigate` (cause and recommendation) or `build` (fix, pushed as a branch). Model comes from "Which model a builder runs on" below.

Matching items to agents:
- Two items that edit the same files, component, workflow, job or table never run at the same time. If they are one fix, give both to ONE agent in one brief. Otherwise the later one waits until the earlier one's pull request has merged.
- Two symptoms that may share a cause (two complaints about one service) go to one agent, or run side by side with each brief naming the other item.
- Different areas of one repo may run together, each agent in its own worktree.
- Wave 1 is the most urgent four: live harm to customers first. Quick checks fill slots as they free.
- Anything irreversible (dropping or deleting data, sending to people, re-running a job with side effects, spending money, changing production settings) is `investigate` only. The agent drafts the action; Dan decides it later with a picker that states the specific consequence.

Show the board, then one picker: start as planned, or change something. Nothing is dispatched before he says yes.

### Which model a builder runs on

A builder agent's model is set by the kind of task (Dan, 2026-11-01, claude-config#1961). This section is the rule's one home: the global CLAUDE.md, and anything else that dispatches builders, points here instead of restating it.

- Sonnet, with `model: "sonnet"` on the Agent call, for three kinds: a rename or move that changes no behaviour, filling in tests for code that already exists, and a fix for a review comment.
- Opus, with `model: "opus"`, for everything else. Design, security and compliance work always runs on Opus, even when it is also one of the three kinds above.
- A fork ignores `model`, so a Sonnet builder is never a fork.
- To run one brief on the other model, suggest it to Dan with the reason: on the board, as that row's Model with the reason beside it, or before dispatching when there is no board.

## 3. Briefs

Every brief has exactly these parts, in this order, and nothing else:

1. `Read ~/.claude/skills/orchestrate/agent-rules.md before anything else and follow it.`
2. The item in Dan's words, plus what is already known (alert text, times in ET, links). State what is known and what is ruled out; never state your guess at the cause as fact.
3. The repo's absolute path, and either the worktree path and branch name to build on, or "read only".
4. What is off limits because another agent owns it, naming that item.
5. The scratchpad folder: `<scratchpad>/<item number>-<short name>/`.
6. What done means for this item, and what must come back to Dan instead of being done.
7. For a `build` item only: the `Claude-Session:` line for commits and the session link line for the PR body, copied from this session's attribution note.

The rules every agent shares live in `agent-rules.md`, so a brief never restates them. Send a whole wave in one message, one `Agent` call per agent, all in the background, each carrying the `model` its board row shows.

## 4. While agents run

- At most four agents running, a reviewer agent you start included. When one returns, start the next queued item in the same response.
- Reprint the board whenever anything changes, with each item's state: `queued`, `running since 2:14 PM ET`, `reported`, `in review`, `merged`, `live`, `needs Dan`, `failed: <why>`. Running, stuck and failed must never look alike.
- An agent silent well past what its item should take: check it with `ListAgents`, then ask it with `SendMessage` for a one paragraph status (found so far, waiting on what, how long). Never read its output file; it is the whole transcript. If it is stuck, stop it with `TaskStop` and restart the item with a brief carrying what it found and what hung it, or mark it failed and say why.
- Dan adds items mid run: add them to the board and run the matching rules again. When a running agent already owns that area, send the new item to it with `SendMessage` instead of starting another agent: it fixes both on its branch only if they are one fault, and otherwise finishes its own item, reports on the new one, and builds it once its own pull request has merged.
- An agent's question that only Dan can answer becomes one picker while the others keep running.
- Never report or predict a result an agent has not handed back.

## 5. When an agent reports

1. Read the report against its brief. For a fix, check its claim that the test failed first: in its worktree, put back main's version of the fixed file with `git checkout origin/main -- <file>`, run the test, then restore the file.
2. Open the pull request yourself (an agent in a worktree cannot), using its `pr-body.md` after `/no-ai-tells`.
3. Review the full diff against the item. Send problems back to the same agent with `SendMessage`, naming each one; it pushes again.
4. One merge at a time per repo. Merge in the background with `bash ~/.claude/hooks/lib/merge-when-ready.sh <n> --repo <owner>/<name> --delete-branch`, which brings a branch that has fallen behind up to date and waits for checks. Confirm with `gh pr view <n> --json state`.
5. Run the repo's post merge deploy step and confirm the change is live. Then release whatever waited on this merge.

## 6. Finish

When nothing is running or queued:
- A final table: item, outcome in one sentence, pull request and live status, and anything that still needs Dan.
- One git status line per repo.
- Each decision left for Dan as its own picker, one at a time.
- Stop anything this session started in the background, and say so.
- Then `/next-issue`.

## Common mistakes

| Mistake | Instead |
|---|---|
| Shared rules copied into every brief, drifting apart | One line pointing at `agent-rules.md` |
| Two builders in the same files because the items read differently | Match on files touched, not on wording |
| Board kept in your head | Reprint it on every change |
| A new item started as a new agent in an area already owned | `SendMessage` to the owner |
| Merging the moment checks go green | Review the diff first, one merge per repo at a time |
