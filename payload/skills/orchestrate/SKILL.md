---
name: orchestrate
description: Use when Dan asks this session to act as an orchestrator, hands over a list of alerts, bugs or things to check on and wants a subagent working each one, or types /orchestrate. Also use when he adds items to a list already being orchestrated.
---

# orchestrate

Dan hands over a list and wants each item worked by its own subagent while this session coordinates. This session plans, briefs, queues, reviews and merges. It never works an item itself, and agents never merge their own pull requests.

## 1. Intake

Number every item and say it back in one line, in Dan's words. Settle what you can check cheaply before planning: which repo and checkout each item lives in, whether an alert is still firing. Ask Dan only about an item you cannot place, one picker per question.

Record where each item came from, so it can be answered there (see "Answering each item at its source" below): for a Slack alert, post or thread, the channel id and message ts of the message it started from; for a Slack list row, the list id and record id; for a GitHub issue, the repo and issue number. An item Dan typed into the chat has no source, and the board says so.

## 2. Dispatch board

Build the board, one row per item:

| # | Item | Source | Repo and area | Kind | Agent | Model | Wave | Waits on |
|---|---|---|---|---|---|---|---|---|

Source is what intake recorded: `Slack <channel id> <ts>`, `list <list id> <record id>`, `<repo>#<n>`, or `chat`. Kind is `check` (read only answer), `investigate` (cause and recommendation) or `build` (fix, pushed as a branch). Model comes from "Which model a builder runs on" below.

Matching items to agents:
- Two items that edit the same files, component, workflow, job or table never run at the same time. If they are one fix, give both to ONE agent in one brief. Otherwise the later one waits until the earlier one's pull request has merged.
- Two symptoms that may share a cause (two complaints about one service) go to one agent, or run side by side with each brief naming the other item.
- Different areas of one repo may run together, each agent in its own worktree.
- Wave 1 is the most urgent items, as many as the session's agent cap (the `[Agent cap]` line at session start): live harm to customers first. Quick checks fill slots as they free.
- Anything irreversible (dropping or deleting data, sending to people, re-running a job with side effects, spending money, changing production settings) is `investigate` only. The agent drafts the action; Dan decides it later with a picker that states the specific consequence.

Show the board, then one picker: start as planned, or change something. Nothing is dispatched before he says yes.

### Claiming an issue before its builder starts

On 2026-11-19 two sessions, one on each Mac, built the same fix, because a branch that exists only in a local worktree is invisible to the other Mac and nothing on the issue said the work was taken (claude-config#3317). So a `build` item whose Source is a GitHub issue is claimed on the issue before its builder is dispatched, in the response that dispatches it, in a Bash call of its own just before the `Agent` call:

    bash ~/.claude/skills/orchestrate/claim-issue.sh claim <owner/repo> <issue number> <branch>

It reads the issue's claims, the open pull requests built for it and the remote branches carrying its number, and posts the claim (which Mac, the time in ET, the branch) only when none of them shows another session at work. A pull request is built for an issue when its branch or its title names the issue, or its body names it straight after a closing keyword, "Part of" or "Refs". One that only mentions the number is printed as a `mentioned, not held` line and holds nothing (claude-config#3788). Dispatch on exit 0 only:

- Exit 0, `CLAIMED` or `ALREADY CLAIMED`: dispatch the builder. A `mentioned, not held` line under it names a pull request to glance at, never a reason to hold the item back.
- Exit 1, `HELD` or `CLOSED`: the item is not started. Its board row shows `held by <who>`, taken from the lines the script prints, and Dan is told in one line.
- Exit 2, `COULD NOT CHECK`: the item is not started, and nothing was claimed unless the message says a claim may have been posted, when it names the release command to run straight away. Show the reason it prints on the board and run it again later; never read a failed check as free.

A `check` or `investigate` item changes nothing and needs no claim. `claim-issue.sh check` does the same reads and posts nothing, for a look before the board is shown.

A claimed item that ends any way other than a merged pull request that closes its issue (dropped, parked, handed back unfinished, merged with only a reference) is released on the issue in the same step, so the claim does not block the next session:

    bash ~/.claude/skills/orchestrate/claim-issue.sh release <owner/repo> <issue number> <branch> "<reason>"

A claim with no release stops counting after 24 hours; an open pull request built for the issue, or a remote branch naming it, blocks whatever the claim's age.

### Which model a builder runs on

A builder agent's model is set by the kind of task (Dan, 2026-11-01, claude-config#1961), in three tiers since Fable became his default model (Dan, 2026-11-09, claude-config#2547), keeping ordinary builders off Fable to limit usage. This section is the rule's one home: the global CLAUDE.md, and anything else that dispatches builders, points here instead of restating it.

- Sonnet, with `model: "sonnet"` on the Agent call, only for work that needs no judgement: a rename or move that changes no behaviour, a comment or wording fix, filling in tests for code that already exists. A fix for a review finding that changes logic or behaviour runs on Opus, or on Fable where it changes what a design, security or compliance control decides or shows (Dan, 2026-11-19, claude-config#3290: "why are we using sonnet? we basically should only ever be using fable or opus", then "if it's just comment fixes, renames, etc. Things that any idiot could do, sonnet is fine").
- Fable, with `model: "fable"`, for work that changes what a design, security or compliance control decides or shows a person, and for reviews of such a change (Dan, 2026-11-24, claude-config#3393, choosing "Narrow to what a guard decides" after 8 of 50 sampled Fable briefs changed neither). A guard that enforces process or quality, such as the design round guard or the area check, counts as a security control. Follow on work on such an item that changes neither (a red check, a test flake, a cost case, a comment or wording fix, finishing a merge or a push) runs on Opus, or on Sonnet where it needs no judgement. So what the change does decides the tier, not the item it belongs to or its kind: a wording fix to the message a guard shows a person outside Slack runs on Fable, a comment fix inside that guard does not.
- Opus, with `model: "opus"`, for everything else.
- A fork ignores `model` and runs on the session's own model, so a builder whose tier is not the session's model is never a fork.
- To run one brief on another model, suggest it to Dan with the reason: on the board, as that row's Model with the reason beside it, or before dispatching when there is no board.

What counts as each, as the #3393 sample classed it. Security decides who or what may act, or keeps secrets or private data in; any change to what a guard, gate or permission reader refuses or allows counts, whatever it guards, and a change only to a gate's speed, timing or test runs does not. Compliance is an obligation set outside the codebase (a law, a licence, a vendor's terms); a repository's own rules are not. Design is how something looks or how a person uses it, wording a person reads included when that wording is the main task; how code works inside is not. Writing or rewording a message that code posts to Slack (an alert, an all clear, a reminder, a report) is not design under this rule and runs on Opus: the `slack-alerts` skill and its checker hold the standard (Dan, 2026-11-26). A brief is classed by its main task, and a review by what it looks at.

### Which agent type a builder runs as

A `build` item is dispatched as the builder agent type, with `subagent_type: "builder"` on the Agent call, when the Agent tool's list of agent types names `builder`. Where the list does not name it, leave the type out, as every builder was dispatched before the type existed: a type the list lacks fails the call. A `check` or `investigate` item never uses it, because it may need a connected server and the builder type has none.

The builder type starts with less than a general purpose agent (Dan, 2026-11-25, claude-config#3389: "Servers and rule files (Recommended)"). It lists no connected servers. It does not load the rule files: its own prompt carries the lessons core and the rules a builder must follow from the global CLAUDE.md, written from those files by `render-builder-type.py` in this folder, and `builder-type-rules.tsv` beside it records each section carried or left out and why. For the session dispatching it:

- The model rule above holds for it unchanged. The type sets no model, so every dispatch names one, and `hooks/builder-model-gate.sh` counts a dispatch of the type as a builder whatever else it carries.
- It does not load the project's CLAUDE.md or AGENTS.md, and is told to read that file first. It does not load the project's memory index at all, so part 2 of its brief names any memory file the item depends on, by path.
- It cannot reach Slack, a database or any other connector, so an item that needs one is not dispatched as this type.
- It does not carry the global rules' two UI sections, "Progress & Feedback (UI)" and "Building UI" (Dan, 2026-11-25: "Cut the UI sections first"). The brief for an item that builds or changes anything a person sees on a screen says to read those two sections of `~/.claude/CLAUDE.md` before writing it.

## 3. Briefs

Every brief has exactly these parts, in this order, and nothing else:

1. `Read ~/.claude/skills/orchestrate/agent-rules.md before anything else and follow it.`
2. The item in Dan's words, plus what is already known (alert text, times in ET, links). State what is known and what is ruled out; never state your guess at the cause as fact.
3. The repo's absolute path, and either the worktree path and branch name to build on, or "read only". The worktree path is inside the repo's own `.claude/worktrees/` folder, never under `/tmp`, `/private/tmp` or the scratchpad, which a restart of the Mac empties with any uncommitted work in it (claude-config#2490).
4. What is off limits because another agent owns it, naming that item.
5. The working folder: `<notes folder>/<item number>-<short name>/` for its written notes, under the notes folder the session start notice names (`~/.claude/state/session-notes/<project>/<session>/`), never the scratchpad, which a restart of the Mac empties (claude-config#2490). Bulky scratch (fixtures, repository copies, bisect trees, tar files) goes in the session scratchpad under `<scratchpad>/<item number>-<short name>/` instead, since the daily keep rules remove such leftovers from an ended session's notes folder (claude-config#3235).
6. What done means for this item, and what must come back to Dan instead of being done. Wording does not come back to him by default, never "any new sentence a person reads" (claude-config#2570): a Slack alert's wording follows the `slack-alerts` skill and passes its checker, and a repo wide rewrite of alerts merges when its checks and the lessons review pass, with nothing brought back to him (Dan, 2026-11-17: "it should literally just go through in every repo (separate issues for each repo) and update all alerts without me"). For a `build` item whose issue carries a `Must always be true` list, done includes what keeps each of its rules true, built and seen to fail, and a pull request body that passes the built check, both as `~/.claude/skills/milestone/MUST-ALWAYS-BE-TRUE.md` says. When the issue has no such list, say so in the brief and have the builder write one into `pr-body.md` before it builds.
7. For a `build` item only: the `Claude-Session:` line for commits and the session link line for the PR body, copied from this session's attribution note.

The rules every agent shares live in `agent-rules.md`, so a brief never restates them. Send a whole wave in one message, one `Agent` call per agent, all in the background, each carrying the `model` its board row shows.

## 4. While agents run

- No more agents running than the session's agent cap, a reviewer agent you start included. When one returns, start the next queued item in the same response.
- Reprint the board whenever anything changes, with each item's state: `queued`, `held by <who>`, `running since 2:14 PM ET`, `reported`, `in review`, `merged`, `live`, `needs Dan`, `failed: <why>`. Running, stuck and failed must never look alike.
- An agent silent well past what its item should take: check it with `ListAgents`, then ask it with `SendMessage` for a one paragraph status (found so far, waiting on what, how long). Never read its output file; it is the whole transcript. If it is stuck, stop it with `TaskStop` and restart the item with a brief carrying what it found and what hung it, or mark it failed and say why.
- Dan adds items mid run: add them to the board and run the matching rules again. When a running agent already owns that area, send the new item to it with `SendMessage` instead of starting another agent: it fixes both on its branch only if they are one fault, and otherwise finishes its own item, reports on the new one, and builds it once its own pull request has merged.
- An agent's question that only Dan can answer becomes one picker while the others keep running.
- Never report or predict a result an agent has not handed back.
- An agent that hands back at the context line has not failed: start a fresh agent on the same item with the same brief plus one line, `Read <its working folder>/handoff.md first: it holds what the last agent on this item decided and left.` Its report is at most 300 words; read the files it names only when the report leaves a question open.

## 5. When an agent reports

1. Read the report against its brief. For a fix, check its claim that the test failed first: read its `red.txt` in its working folder, which settles the claim when it names the new test with a failing line (Dan, 2026-11-24, claude-config#3390). Rerun the check only when `red.txt` is missing or does not name the new test: in its worktree, put back main's version of the fixed file with `git checkout origin/main -- <file>`, run the test, then restore the file.
2. Open the pull request yourself (an agent in a worktree cannot), using its `pr-body.md` after `/no-ai-tells`.
3. Review the full diff against the item. Send problems back to the same agent with `SendMessage`, naming each one; it pushes again.
4. One merge at a time per repo. Merge in the background with `bash ~/.claude/hooks/lib/merge-when-ready.sh <n> --repo <owner>/<name> --squash --delete-branch`, run from inside a checkout of the repository, with the repository's recorded merge method in place of `--squash` or, where none is recorded, the one its history uses (it stops, naming them, when the repository allows more than one and none is passed), which brings a branch that has fallen behind up to date and waits for checks. For a log, add `--log=<file>`; never pipe it into `tee`, which reports exit 0 however the helper ended (claude-config#2304). Confirm with `gh pr view <n> --json state`.
5. Run the repo's post merge deploy step and confirm the change is live. Then release whatever waited on this merge.
6. Answer the item at its source, by the section below.

### Answering each item at its source

Every item is answered where it came from, by its Source on the board (Dan, 2026-11-04: "when done, save as draft a reply to the alert, post, etc." and, for lists, "just update the waiting/in progress/done indicator instead. and make sure the claude config makes that mandatory as well"). Both halves are mandatory: an item is not finished, and does not leave the board, until its source has been answered this way.

- **A Slack message (an alert, a post, a thread).** When the item finishes (its answer is in for a `check` or `investigate`, its change is live for a `build`), save a draft reply in that message's thread with `slack_send_message_draft`, passing the recorded channel id as `channel_id` and the recorded ts as `thread_ts`. The reply says in plain words what was found and what was done, with the pull request or issue link, and goes through `/no-ai-tells` first. The draft is written only when every check behind it is finished: it states settled facts, never an inference, and never says a check is under way or promised (global CLAUDE.md, Slack section). Nothing is sent: Dan reads the draft and sends it himself. The one attached draft per channel limit does not apply to thread replies (two thread drafts in one channel were both accepted, measured 2026-11-04), so save one draft per thread, never one combined draft. Keep the `channel_link` each draft returns, for Finish. A draft that fails (`attached_draft_exists` because Dan already has a draft in that thread, `not_in_channel`, anything else) is reported to Dan with the reply text, never retried over his draft.
- **A Slack list row.** It gets no reply: a list record's thread refuses a draft with `channel_not_found` (measured 2026-11-04). Move the row's Status column instead, with `slack_update_list_record` and the recorded list id and record id: In progress when its agent reports, Done once every follow on Dan approved is finished, Waiting when it is parked until a later date or event. Read the list's own Status options first with `slack_read_list` (`schema_only`) and use the option that names that state. A move that fails is reported to Dan, never left silent.
- **A GitHub issue.** Answer it where it came from, as before: a comment on the issue with what was found and what was done, through `/no-ai-tells`, or the pull request that closes it.
- **An item typed into the chat.** The final table is its answer.

## 6. Finish

When nothing is running or queued:
- A final table: item, outcome in one sentence, pull request and live status, and anything that still needs Dan.
- Each draft reply saved, with its link, so Dan knows where to find and send it; and each list row whose Status moved, with the value it now holds.
- One git status line per repo.
- Every claim this session posted for an item that ended without closing its issue, released with `claim-issue.sh release` (see "Claiming an issue before its builder starts").
- Each decision left for Dan as its own picker, one at a time.
- Stop anything this session started in the background, and say so.
- Then `/next-issue`.

## 7. The context line

`hooks/context-size-notice.sh` tells this session once it has dispatched an agent or set a /goal and its last request carries more than 330,000 tokens of work, meaning its context minus the floor it started with (claude-config#1960, #2283). Every request past that rereads the whole conversation, so stop and write down what has been decided before going on, whichever step you are at. Nothing decided may live only in the transcript:

1. The list or goal being worked, in Dan's words, and every constraint he has stated, quoted with its date.
2. Every decision made in this conversation, with its reason and what was ruled out.
3. The state left behind: branches, worktrees, commit shas, pull requests open, merged or live, and agents and background jobs still running, with their ids.
4. The board: each item's state, and the exact next step of each item in progress.
5. Every question waiting on Dan.

A decision that belongs to an issue goes on that issue as a comment, where the next session and the issue's next reader will find it. The rest goes in `handoff.md` at the root of this session's notes folder, with the board: the folder the session start notice and the context line notice name, which a restart of the Mac cannot clear (claude-config#2490). Then call `mcp__status-bar__queue_compact` with that file's absolute path (claude-config#2025). It refuses until the note is there, written since the last compaction and within the hour, and otherwise queues a compact that runs when this turn ends, shown on the status bar with Cancel. A /goal run is one turn until its goal is met or stopped, so there the compact waits until then. Once it has run, the status bar sends this session one prompt to read the note and carry on (claude-config#2082), so the work picks up from the note without Dan typing. Tell Dan in one line that the session is at the context line and where the note is, so he can cancel the compact, type /compact himself if the tool was not there or refused, or start a fresh session from the note. Agents already running carry on either way.

## Common mistakes

| Mistake | Instead |
|---|---|
| Shared rules copied into every brief, drifting apart | One line pointing at `agent-rules.md` |
| Two builders in the same files because the items read differently | Match on files touched, not on wording |
| Board kept in your head | Reprint it on every change |
| A new item started as a new agent in an area already owned | `SendMessage` to the owner |
| A builder started on an issue with nothing on the issue saying so | `claim-issue.sh claim` first, and dispatch on exit 0 only |
| Merging the moment checks go green | Review the diff first, one merge per repo at a time |
| An item finished with its alert or list row left unanswered | A draft in the message's thread, or the row's Status moved |
