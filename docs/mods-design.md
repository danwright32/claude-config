# Mods: the settled design

The design decisions for Claude Code mods (milestone "Claude Code mods"), each settled with Dan
in a rendered design round or a one question picker, with its reason. A new mod starts from these
and settles its own surfaces in rounds of its own before it is built.

## Standing rules (every mod)

1. **Colour only for something Dan has to act on.** A notice Claude handles by itself is neutral
   grey. Settled 2026-10-03 in the guard rounds: asked to colour the blocked card, Dan asked
   whether a block needs anything from him, and on hearing it is a notice Claude works around, he
   chose grey and made it the rule for every mod. What waits on Dan takes amber: the lead line of a
   question, a handoff, a steps card or the held while away card (colour round, 2026-10-04, after
   Dan asked that the steps card not be grey "since it needs my action"). One amber line per
   surface: heading and next step both amber was too much (steps amber round), and the handoff's
   changed since lines are grey under its amber lead (handoff colour round, 2026-10-04). The one
   exception to one amber line per surface is the steps card's amber left edge beside its amber
   heading, which Dan asked for. The exceptions to colour only for action are separate, each
   recorded where it applies: the running PR, running job and kept job, the scope mode label, and
   the goals pane's state colours.
2. **Plain wording.** A refusal says what was blocked and the safe way, in one or two short
   sentences: "Blocked: this would print GITHUB_TOKEN. Check it without printing: test -n, its
   length, or gh auth status." Settled 2026-10-03, then applied to every refusal and toast of the
   three guards at Dan's choice.
3. **Ask before focus moves.** Anything that brings an app forward is announced and waits for Dan
   (CLAUDE.md, and the keystroke guard enforces it).

## Guard surfaces (#607, #608, #609)

| Surface | Decision | Round |
| --- | --- | --- |
| A blocked action in the transcript | A grey boxed card: title "Blocked by <guard>", the reason, then the safe way in dim text. Drawn once, by `mod-kit`, for every guard, as one use of the boxed card any mod's own tool result is drawn as (`$.modkit.card`, #663). | 1 (shape: card over plain error row and two named lines), 3 (colour: grey) |
| The keystroke guard's heads up | The standard question dialog with the chip "Taking over" (12 characters at most; settled in a picker after round 2): "I'm about to type into Overture. Ready?" or "I'm about to bring Google Chrome to the front. Ready?", options Go ahead and Not now | 2 (dialog over a band above the prompt and a card in the transcript) |
| `/style-count` | One line: "Replies with a dash or emoji: 2 this session, 7 in total." When some replies could not be checked it adds "1 reply this session could not be checked." (picker, after the lessons review) | 4 |
| A guard's note (a source it could not read, a check that could not run) | One dim transcript line, the guard named inside the sentence | 5 |
| Toasts | Drawn by Claude Code; only the words are the mod's, in the plain style | (no round: not drawable) |

## Guard behaviour decided with Dan (2026-10-03)

- `open -a` and every other way of bringing an app forward asks first, like typing.
- A Go ahead covers that app until 10 minutes pass with nothing sent to it, for typing and
  opening alike.
- When the style scanner cannot run, the write goes through with a dim note; the push check still
  judges it, and refuses the push if the scanner is broken.
- Chat replies with a dash or emoji are counted silently, read with `/style-count`.
- `.env` values count as secrets when their name says so (TOKEN, KEY, SECRET, PASSWORD as a whole
  part of the name) or they are shaped like a token.
- A source the secret guard cannot read is one dim note per session.

## Collision guard (#605), settled 2026-10-03

| Surface | Decision |
| --- | --- |
| A Proceed | A toast only: "Checked with the other session: safe to edit app.ts." |
| A Worktree or a Stop | The grey blocked card (mod-kit), titled Collision guard |
| The note to the session that was working first | Claude Code's standard incoming message from that session (collision round 1, over a grey card), plus a toast: "Another session wanted app.ts; it was moved to a worktree." |
| A record that cannot be read | Stop, naming the file and how to clear it (picker) |
| A judgment that cannot be had | Stop, as specced (picker) |
| The note cannot be delivered (2026-10-04, picker) | Tried once more; if that fails too, the card gets a dim line under the safe way, "The other session could not be told: <reason>.", which Claude also reads. The block stands either way. |

A session silent for five minutes counts as closed; its latest request is read from its transcript,
never copied into the registry. The transcript is found where it is read (2026-10-04, picker): in
Claude Code's folder for the session's starting directory, else by its session id, and only if that
file exists. The start hook that was meant to hand over its path never reaches a mod. The judge is
told which of three things was missing: no transcript found, one that could not be read, or no
request in it.

### Files changed by shell command (#654), decided 2026-10-04

A Bash command that writes a file is judged and recorded the same way an Edit is: the same cards,
toasts and messages, with no surface of its own. The files come from mod-kit's command reader
(`$.modkit.commands`), which now gives an output redirect (`>`, `>>`, `>|`, `2>`, `&>`, `2>&1`) as
its own word however it is spaced; the collision guard reads which files the words name
(`hooks/collide.ts`, `shellWrites`): redirect targets, `tee`'s files, `sed -i` and `perl -i`'s
files, `touch`'s files, and the destination of `cp` and `mv` (a file inside it when it is a
folder), plus `mv`'s sources, which it takes away. Paths are made absolute against the session's
folder, following a `cd` earlier in the same command. A file another open session edited is judged
before the command runs; once it has run, every file it named is added to this session's edits,
also when the command failed, since it may have written before it failed. Only a refusal leaves the
record alone.

What the words do not name is not guessed at, and is neither judged nor recorded: a script
(`bash ./update.sh`, `python3 -c`, `node -e`, `make`), a path built from a variable, a glob or a
command substitution, and a relative path after a `cd` to a folder that cannot be named (`cd $DIR`,
`cd -`). Stopping every such command would refuse ordinary work (every test run) and cost a judgment
each time, and comparing file times after each command cannot say which session wrote a file, so it
would record the other session's change as this one's. The gap is the same one an Edit made
outside Claude Code always had. A quoted lone `>` is read as a redirect (the reader removes quotes
before anything reads its words), so `grep '>' notes.txt` names notes.txt; the cost is a judgment
that comes back Proceed.

### rm, and scratch kept out of the record (#674), decided 2026-10-04

An `rm` or `unlink` of a file another open session edited is judged the same way, with the same
cards, toasts and messages; the judge is told the command removes the file. An `rm -r` (`-R`,
`--recursive`, in any cluster such as `-rf`) of a folder is judged once on every file another open
session edited inside it (the coordinator on #691): one judgment that names them all, one card or
toast ("3 files in src", or the file's name when there is one), and one message to each other
session naming its own files, which its toast lists by name. An `mv` source is taken away whole in
the same way, so moving a folder is judged the same. Once it has run, the removed path (the folder,
for `rm -r`) is added to this session's edits. An `rm` of a glob or a variable names nothing, as
decided for #654. The card, toast and message keep the words used for any write ("wanted to edit",
"safe to edit"), as the brief for #674 asked.

Only paths inside the session's own root are recorded as its edits: its repository, or its own
folder when it works outside one (the record's `repoRoot`, else its `cwd`). Scratch such as `/tmp`
and the scratchpad is left out, by the edit tools and by shell commands alike, so it cannot push real
edits out of the twenty the judge reads or raise checks between sessions that share scratch space.
A write is still judged wherever it lands, so a scratch file an older record already holds is still
checked. What this gives up: a file in another checkout, edited from this session, is not recorded,
so a session working in that checkout is not judged against it.

## Status bar (#610), settled 2026-10-04

| Surface | Decision |
| --- | --- |
| Layout | The always-shown facts are one long line under the prompt (status round 1; Dan revisits it once he has lived with it, under #610). The amber items are not on it: they sit in the band above the prompt, as the rows below say. |
| Facts always shown | Project, 5 hour limit, weekly limit, cache time left, model and effort, account and org (status round 2) |
| Facts shown only when they need a look | Unpushed commits, PR and checks (failing or running), a running background job, context above 70% (status round 2) |
| Hidden | Branch, uncommitted files, commits behind main (status round 2) |
| Account | Whatever the login file names now, re-read each refresh; no "login changed elsewhere" marker. Dan changes the login in one window expecting it to apply to all of them (picker). |
| Colour | The status line is all grey; the needs-a-look items in the band are amber; the Compact button is Claude Code's own bold white (colour round, design rounds). A deliberate exception to standing rule 1: a running PR, a running job, a job kept on purpose and a scope mode label are amber though nothing needs doing yet, because Dan chose to keep work in flight in view (status round 2, colour round, kept job round) and a mode changes what Claude will do; the scope mode label shows even when nothing else is in the band (scope mode round). |
| Where it is drawn | The always-shown facts stay on the classic status line script below the prompt, fed by the mod. The amber items are drawn by the mod in the band above the prompt, only while something needs a look or a scope mode is on (picker, after the probe below; scope mode round). |
| The band | Two rows when both show: the amber line, then the Compact row carrying the context figure, so context shows once. Either row alone otherwise (design round). |
| Order of the amber line | A scope mode (NO BUILD, WINDING DOWN, AWAY) leads it in bold, since it changes what Claude will do (scope mode round). Then most urgent first: a failing or running PR, a running job, unpushed commits, so a narrow window cuts off what can wait longest (design round) |
| Compact button | Claude Code's default button, `[ Compact ]` in bold white, pressed by clicking or ctrl+x tab then Enter (design round, styles copied from a live probe) |

Built (#610), with what the rounds left to the build, each taken from the rounds' renderings or
the spec rather than chosen afresh, and open to Dan changing:

- The status line reads `claude-config | 5h 68% (1h 52m) | week 91% (4d 14h) | cache 41m |
  Opus 5.5 (high) | Dan, Personal`, as every round drew it: the account is the login's display name
  (its email when it has none) and the organisation. It is drawn by `statusline.sh` in the mod's
  folder, which the `statusLine` setting names; that setting lives in each Mac's own settings and
  does not travel, so it is set once per Mac. A fact that cannot be read says so ("cache unknown"
  when the mod has written nothing for the session, "account unknown" when the login file cannot be
  read), never a blank.
- The amber line's items read as drawn in the rounds: "PR #636 checks failing", "1 job running",
  "dev server kept 2h 14m", "2 unpushed commits", divided by a dim `|` as the status line is.
- A PR whose refresh failed keeps what was last read with its age: "PR #649 checks running, as of
  12m ago" (the spec's "stale with its age"). One that last read as passing stays hidden.
- The Compact row reads "ctx 74%" in amber, then `[ Compact ]`, whether it showed for context or
  for the cache. A compaction that does not run says why in a toast: "Compact did not run: ...".
- The toast 5 minutes before the cache goes cold reads "The prompt cache goes cold in 5 minutes."
- A repository with no remote shows no unpushed commits, since there is nothing to push to.
- A scope mode is set by another mod with `$.statusbar.setModes({ modes })`, the modes that are
  on at once (no build or winding down, and away), or an empty list to clear them; `setMode({ mode })`
  sets one. Two at once read `NO BUILD | AWAY`, each bold, divided like the other items (#616, #621
  build; open to Dan changing, see below).

Why the split: a live probe on 2026-10-04 showed a mod's `$.ui.status` line is drawn by Claude Code
as a warning notice, amber with a warning sign and the mod's name in front, and terminal colour
codes come out as broken characters. A mod cannot own a grey line with amber items through it; the
classic status line command passes colour through, and the band above the prompt draws colour.

## Job watcher and goal tracker (#611, #612), behaviour settled 2026-10-04

- A waiting loop is stopped by the watcher only when the line it keeps repeating reads as an error.
  A loop repeating "waiting" is reported to Claude and never stopped (picker).
- A job kept on purpose, with a reason, still shows in amber in the band like any running job,
  named with its run time ("dev server kept 2h 14m"): kept does not mean out of sight (design round).
- Turn end with a running job that was not kept: never refused, because a mod cannot refuse a turn
  end without Claude Code drawing it ("Stop hook error" or "Stop hook feedback", read from the
  2.1.289 binary). Instead every tool result Claude reads names the unkept job and says to stop it
  or keep it; Dan sees nothing (picker, replacing the earlier "refused, Dan sees nothing").
- A kept job is protected only while its session is open: once that session has closed, a kept
  leftover is judged like any other (Haiku, then Sonnet, then the stuck gate), its quiet flag no
  longer exempting it. The live watcher never stops a kept job (picker). So a lessons review finding
  asking that a closed session's kept and quiet flags carry into the leftover judgment was not
  acted on: it would reverse this decision.
- A stop verdict on a leftover is acted on only when the watcher measured it as stuck (repeating
  one line, or silent past ten minutes), so text in the job's own output can never cause a kill
  (picker).
- No toast when a kept job passes an hour: the band already shows its run time (picker).
- Leftover jobs at session start: no question to Dan, who cannot judge a job from a closed session.
  Haiku decides each one from its command, run time and output; Sonnet tries if Haiku cannot; if
  neither can, the job is left running and judged again next session. Dan sees one dim grey line
  naming what was stopped and what was left (pickers).
- A session shows as failed after three tool calls in a row fail or are refused, a refused question
  included, naming the last failure; the next success clears it. A subagent's calls and to-do list
  are not the session's (picker).

## Goals pane (#612), settled 2026-10-04

| Surface | Decision |
| --- | --- |
| Scope | Every open session on this Mac, in any project (picker) |
| Pane | /goals opens a live pane that updates as sessions move and closes itself when Dan next sends a message (picker) |
| Row | Two lines per session: project and goal on top; state, steps, elapsed time and one detail (the question, the failure, how long quiet, or the step under way) as a dim sentence beneath (design round) |
| Order | Waiting on you, failed, stalled, working, done (design round) |
| State colour | On the state word only: waiting on you and stalled amber, failed red, working blue, done green. A deliberate exception to standing rule 1, so every state reads at a glance; red stays for something genuinely wrong (design round) |
| Notification | One per waiting moment, naming the project: "<project> is waiting on you" with the question, or "<project> needs a permission" with what for. The mod sends all three, the idle "What's next?" only while nothing is being asked, and both notifying settings hooks are removed; if mods are ever off there are no notifications (pickers) |
| Goal text | The /goal condition when one is set, otherwise the session's first request cut to a few words. No model call (picker) |

Not settled with Dan, built in #634 as the plainest reading and open for a round: the pane's
cadence (it reads the registry every five seconds while open); "nothing being asked" read as no
open question and no open permission; the permission's "what for" (the call's own description,
else "a Bash command", never the command itself, which can carry a secret, or the tool and its file); six words for "a few words"; a goal cut to 80
characters; a session with no task list showing no step count; within one state, oldest session
first; a session that records no progress left out; the blue as the theme's `suggestion` colour;
the permission notification keeping the Glass sound the settings hook had; and the words for a
registry that cannot be read, a pane with no rows, a pane waiting for a wider window, and a
notification that cannot be sent (one dim line a session, the guards' note style).

Built in #694 from the last lessons reviews of #634, not put to Dan, each the plainest reading:

- A permission prompt names its call only by tool and input, never by id. It is matched to the
  running call whose arguments it names and held by that call's id, and comes off when that call
  returns or rejects; matching on the tool and the "what for" text let any other Bash call with no
  description ("a Bash command" too) clear it early. When a hook beneath rewrote the call and
  nothing matches, it stands until every call of its tool that was running has returned. Dan's next
  message still clears it at the latest.
- A question and a permission prompt open at once are kept apart: the pane shows the one asked
  latest, and each ending takes off only its own mark.
- Picker manners answers every AskUserQuestion in its own `tool.call` hook without calling `next`.
  Hooks on one event nest by tier (an organisation's prepended plugins, everything a person
  installs, the appended ones, the built in ones) and within a tier in load order, outermost first,
  and the plugin API gives a person's mod no way to say where it sits. So the goal tracker also
  watches picker manners' writes of the question it holds open (`picker-manners.open`), which every
  plugin's `state.set` hook sees wherever it sits, and marks and notifies from those; where it sees
  the call too (sitting above picker manners), the call's id keeps that to one mark and one
  notification. The tests load picker manners both above and beneath the goal tracker, and
  `tests/test-mods.sh` checks picker manners' contract declares the open question in the shape the
  goal tracker reads; one it cannot read is said once a session in one dim line. Which order a live
  session loads them in was not measured. Two differences between the orders remain: beneath
  picker manners, the goal tracker never sees the call, so a question picker manners refuses is not
  counted toward failed; above it, a question picker manners refuses is marked and notified for the
  moment before the refusal, as before #694.

## Add-on notes (#620), behaviour decided while building, 2026-10-04

Not yet put to Dan in a round; each is the conservative reading of the spec, and the reason is given.

- **Only Dan's messages count**: typed at the terminal or sent from the phone through Remote
  Control. A peer session, a background task or a plugin is never an add-on, even with a `+`.
- **A `+` note mid turn** gets context telling the model to finish the step and fold the note in
  at the next break, and the toast "Noted, applying after this step." once the note has entered.
  A note Claude Code refuses gets no toast. A `+` note while idle with no interrupt before it is
  passed through as typed: the spec defines `+` for a running turn only.
- **Not a `+` note** (a `+` then words, or a number after a space, as in "+ 2 more links"): a lone `+`, `++`, `+1`, or a pasted diff (a later line starting with `+`, a
  hunk header `@@`, or a `-` straight onto the text). A `- ` markdown bullet, a dash then a space,
  is a list in the note and keeps it an add-on (lessons review).
- **An interrupt** is a main loop turn that ended because Dan stopped it. A subagent stopped, or a
  turn that died on an API error, is not one. It is used up by Dan's next message whatever that
  says; another session's message does not use it up; /clear forgets it.
- **An amendment after an interrupt** opens with a word Dan uses to add scope (also, and, include,
  including, plus, keep going, carry on, continue, go on, or a `+`, optionally after oh or ok), is
  at most 40 words, and carries no word that turns it around (instead, stop, never mind, scrap,
  cancel, forget it, rather than, not that, wrong, undo, revert, start over, hold off, wait), and
  is not a question: one ending in `?` asks something new and is never told to resume (lessons
  review).
  "Sorry" counts only when followed by carrying on or adding: "sorry, I meant the staging database"
  is a correction. Read this narrowly on purpose: a miss is an ordinary message, read as without the
  mod, while a redirect taken for an add-on would carry on with work Dan just stopped.
- **No toast after an interrupt**: the acknowledgement is Claude's own resume line, the agreed one
  dim grey line. When the reply adds nothing ("keep going"), the line is "+ add-on: Carrying on."
  The mod draws the line dim only where it opens a reply.
- **The words typed are never changed**; the mod only adds context the model reads beside them.
- **A `+` note while a question is open** (picker manners, #615) is left as typed, with no context
  and no toast (#701). The step Claude is on is that question, which picker manners withdraws,
  telling Claude to answer the message first; telling it as well to finish the step and fold the
  note in later, with "Noted, applying after this step.", was the opposite instruction. The mod
  reads picker manners' open question (`picker-manners.open`); one it cannot read leaves the note
  an add-on, as with picker manners not loaded. The plainest reading, not put to Dan.
- **The resume line for other mods** is read through `$.addonNotes.resumeLine({ text })`: the line
  and the rest of the block, or null, by the rule the mod draws it with. Simpler reads it so its
  button sits under the line (Simpler behaviour, below).

## Session registry retention (#633), settled 2026-10-04

A closed session's record is kept 7 days after it closed, a crashed one 7 days after it was last
seen, then deleted at session start, never on a read. A damaged record older than 7 days by its
file's age is deleted too, named in one dim grey line; a newer damaged record still stops guarded
actions, since it may belong to a live session (pickers).

## The remaining mods' surfaces (#613 to #621), settled 2026-10-04

Each in a rendered design round unless marked picker.

| Mod | Surface | Decision |
| --- | --- | --- |
| Picker manners (#615) | A question in the band | The chip and the question on one line, then each option on its own line with its description indented on the line under it (over two columns and a flowing line) |
| Ask before saving (#618) | The question | The rule's exact text and the file it would go to sit between the question and the three answers, set off by a grey rule (over above the question, and in the chat) |
| Scope modes (#616), away and home (#621) | NO BUILD, WINDING DOWN, AWAY | Leads the amber line in the band above the prompt, in bold, so the status line stays all grey; the band shows for as long as the mode is on, even with nothing else in it. Amber is a deliberate exception to standing rule 1 like the running items, since a mode changes what Claude will do (scope mode round, 2026-10-04, over leading the status line in amber, which an earlier round had picked over the footer's mode labels) |
| Handoff (#613) | The band at session start | One line: "Handoff saved 3h ago: Continue milestone 18 design rounds", then Use and Dismiss (over the whole handoff, and the first line plus what it names) |
| Handoff (#613) | Something it names that changed | Its own line under the handoff, one per change: "changed since: #615 closed" (over a list on the same line, and a count), in grey under the amber lead line (handoff colour round, over amber, which made three amber lines) |
| Manual steps (#614) | Where | As the issue says: a side pane, the band when the terminal is narrow. A pane opened unasked needs 144 columns, so at laptop width it is the band (no round: settled in the spec) |
| Manual steps (#614) | One step | Only the next step is open: its title and Done, its link, its clicks, any value with Copy. Later steps show their title alone until they are next (over every step open, and two lines per step) |
| Manual steps (#614) | A finished step | Keeps its line, dimmed and struck through, then how it finished: "already done" grey, "checked" green, "done, per you" grey (over a word alone, and folding them into one count) |
| Manual steps (#614) | Colour | An amber heading and an amber rule down the card's left edge; the step to do is bold white. The steps card only; the question and handoff keep just an amber lead line (Dan asked for heading and rule together; picker on scope) |
| Is it live (#617) | The card | Boxed, the blocked card's shape (over a left rule and plain text). No lead-in sentence from Claude: it would repeat the card |
| Is it live (#617) | Its state | Leads the title: "Live:" green, "Merged, deploying:" grey, "Could not confirm live:" amber (over the right end of the title and a line of its own) |
| Is it live (#617) | The message for whoever asked | Pinned in the band until Dan presses Mark sent, with Copy; the card stays in the chat. Its heading, "Message for Kris", is violet: not amber beside the steps card, and not blue, which reads as a link (Dan changed his first pick, a box under the card; two colour rounds) |
| Simpler (#619) | The button | At the top of the long answer it is about, under Dan's question, drawn into Claude's reply (Dan asked for it there over the band rows). It is clicked: a button in the transcript takes no one-key shortcut, and a very long answer scrolls it off the top |
| Add-on notes (#620) | The resume line | One dim grey line: "+ add-on: Adding a direct link to the commission and carrying on." It names the addition only (picker on the words, round on the shape) |
| Away and home (#621) | Coming home | A boxed card in the band, amber heading "Held while you were away", one row per held thing with its own button and a thin line between rows; nothing opens until pressed (Dan asked for the box with divided rows) |
| Away and home (#621) | A message from the phone while home | One line at the end of Claude's reply: "You're on your phone. Reply away to switch every session." The band does not exist on the phone, so the spec's one button cannot be drawn there (picker) |
| Auto session name (#635) | Its failure line | One dim grey line, the guards' note style (no round: covered by the spec and that pattern) |

### Simpler behaviour (#619), decided in the build, 2026-10-04

No round: each follows from the spec, the settled placement above and the guards' note style.

- **When it shows.** An answer over 250 words, or one of 80 words or more where at least 6% of the
  words are technical terms (identifiers, file paths, flags, issue numbers, each line of a code
  block). Measured on this Mac over 595 replies that ended a turn: the median is 75 words and one
  in five is over 250; of the replies between 80 and 250 words, nine in ten are under 6.2%
  technical, so 6% picks out the densest tenth (a first guess of 15% fired on none). Together the
  button shows on about one reply in four. Under 80 words an answer is already near the 2 to 3
  sentences the button asks for. These are starting values: the presses and the weekly count say
  whether to move them.
- **Which reply.** Only the latest main answer: a newer answer that does not earn it, or an
  interrupted turn, takes it away. A subagent's turn is not a reply to Dan and changes nothing.
- **Beside the resume line** (#701). Simpler and add-on notes both redraw a reply's first block,
  and which sits outermost is the load order, which no mod chooses. A long reply opening with add-on
  notes' resume line reads the same either way: the dim line, the button under it, then the
  answer, since the line opens the reply (its own row) and the button tops the answer. Simpler
  draws the reply through whatever sits beneath it rather than a copy of its own, and asks add-on
  notes where the line ends. The plainest reading of the two settled rows, not put to Dan.
- **Gone once Dan types.** The first edit of the prompt box, or a message he sends from the phone.
  A background task's notice arriving does not count as Dan typing.
- **The press.** The button goes at once; the request is sent as Dan's own words (`asUser`), naming
  the session's folder as the project to take the example from. If the request is refused or
  cannot be sent, the button comes back and a toast says why. Pressing is counted either way,
  since the need was real.
- **Count, don't auto change.** Each press is one store entry with its time and the kind of answer:
  design answer, plan, diagnosis, status report or explanation, read from the answer's own words.
  The store is per Mac, so each Mac counts its own presses.
- **The weekly line.** At the first interactive session start seven days or more after the last
  one, one dim grey transcript line, the guards' note style: "Simpler was pressed 3 times in the
  last 7 days: after 2 design answers and 1 plan." It says so when there were none. The first
  session with the mod starts the week. A press log that cannot be read is named in a dim line and
  the week stays open, so the next session tries again. Two sessions starting together once the
  week is up show it once (#701): the count is claimed on this Mac first, a folder
  (`~/.claude/state/simpler/weekly.lock`) that only one caller can make, read again under the claim,
  and let go once recorded. A claim older than 10 minutes was left by a session that died holding
  it, and is taken over; one that cannot be made at all still shows the count, since a count shown
  twice costs less than a week never shown.

### Auto session name (#635), behaviour decided while building (2026-10-04)

The spec on the issue was agreed with Dan; these are the details it left open, decided in the build
and open to his correction.

- The failure lines, one per failed attempt, in the guards' note style: "Auto session name couldn't
  name this session: Haiku's reply was empty. It will try once more when the session is next idle."
  and, on the second failure, "... It won't try again, so /rename names it." The reasons said apart:
  an empty reply, one too long to be a name, an error from Haiku (with its status), no answer within
  30 seconds, the call refused by the engine, the conversation unreadable.
- A reply is kept up to 8 words or 60 characters though 3 to 6 are asked for, so a reply a word
  over does not cost a failure line and a second call.
- The idle point is the end of a main turn (a subagent's turn is not one). From the 10 minute mark
  on, each one may name the session: the first exchange when nothing was asked by then, and the one
  retry after a failure. A session idle at the time of a failure retries after Dan's next message.
  The mark is read from when the session started as well as from the timer, so a write that failed
  at the mark still leaves the next idle point to name it, as the failure line says (#701).
- One Haiku call and one name per session (#701). `/rename` waits for the session to go idle, so a
  mark that falls mid turn waits out the rest of that turn; the attempt keeps its claim fresh while
  it waits, so the turn's end starts no second attempt. The name Haiku made is kept with the record,
  so an attempt that takes over from one a reload cut off uses it rather than asking again.
- The fallback route checks before it sets: when `/rename` refuses or answers with nothing
  recognisable, Dan's next message carries the name as `sessionTitle` only if that message shows
  the session still has no name. A different name on it, or a `/rename` of Dan's first, wins.
- After a `/clear` (a new session id with no fresh start event) the new conversation is not named.
- The `session-namer.sh` hook, which titled every session `<project>-<MMDD>` on the first prompt,
  is retired in the same change (Dan, picker, 2026-10-04, over keeping both and over keeping only
  the hook). While it ran, every session had a name long before the 10 minute mark, so this mod
  correctly never named anything. A session is now unnamed for its first 10 minutes.

### Scope modes and away and home (#616, #621), built

One mod, `scope-modes`, because the two share their state: the status bar holds one list of modes
for the amber line, both are switched by Dan's own words read off the same prompt, and both judge
the same Bash calls. What the specs and the rounds settled is as above. What they did not settle was
taken from the spec's words or the existing patterns, and each is open to Dan changing it:

- Only Dan's own prompts switch a mode (his Enter, or his phone through Remote Control); a peer
  session's message, a plugin or a notification never does, so nothing else can lift no build.
- One scope mode at a time: turning on no build while winding down replaces it, and the other way.
  Away is separate and can be on with either; both show, the scope mode first.
- The words: `/nobuild` answers "No build is on.", `/winddown` "Winding down is on.", `/build` "No
  build is off." (or "Winding down is off.", or "No scope mode was on."); `/away` and `/home` answer
  "Away is on in this session and 2 others." and name any session that could not be told.
- A no build refusal is the grey blocked card titled "Blocked by No build", with "Claude asks you:
  Switch to build?" as its safe way; a winding down refusal is titled "Winding down"; a held action
  "Away". "Switch to build?" is asked by the mod in Claude Code's question dialog when Claude calls
  its `switch_to_build` tool, so only Dan's press lifts no build: the dialog reads "Claude wants to
  <change>. Switch to build?" with Yes and No.
- Winding down finds what to finish from the branch the session is on when it turns on: its PR, the
  issues the PR closes, and the branch and worktree. The deploy is the is it live mod's verdict for
  that PR (#687), read through `$.isItLive.verdict` in the repository GitHub's own link for the PR
  names, never Claude's word: only Live or "no deploy step recorded" finishes it; deploying, could
  not confirm live, no card yet, and a verdict that cannot be read each keep the turn end refused
  and say which, and with is it live not loaded the deploy is unmeasured, never live. On the default branch with no PR and nothing uncommitted there is nothing to
  finish; outside a repository too. A check that cannot read GitHub never counts as finished. It is
  checked at each turn end and each minute, and the toast reads "Wind down finished: safe to close
  this session."
- Held while away: opening anything (`open`, BBEdit), AppleScript that types, clicks or brings an app
  forward, cliclick and Peekaboo. A row reads as what it would do ("Open report.html in Google
  Chrome", "Type into Overture"), its button "Open" or "Do it". Pressing one takes the row away and
  asks Claude to do that one thing, so it still passes every guard (the keystroke guard's heads up
  included). The same thing held twice is one row. A /clear ends the session and every mode with it.
- The phone line ends every reply to a phone message while home, not only the first.

### Manual steps behaviour (#614), decided in the build, 2026-10-04

No round: each follows from the spec and the settled surfaces above. The ones marked open were
not settled by either and are waiting on Dan; until he decides, the build does the plainest thing.

- **The handover.** Claude pins steps through the `steps` tool: a heading and a list of steps,
  each with a title, a direct `https://` link or, where there is no page, an exact location, the
  click path and any value to paste. A step with no link or location is refused, naming it. Each
  step must also say what Claude found when it checked it against the current state
  (`already-done`, `not-done`, `cannot-check`), so the hand-off rule's check is a required field
  rather than a line in a prompt; a step without it is refused. Pinning replaces the card.
- **Already done.** A step found done arrives finished, struck through with "already done". A card
  whose every step is already done is not pinned, and Claude is told so.
- **Where.** A new card tries the side pane unasked. When Claude Code does not place it (under 144
  columns) the waiting pane is closed and the card is the `steps` row of the band, so it can never
  show in both. `/steps` opens the pane, which an asked pane gets at any width, and the band row
  gives way to it. Closing the pane by hand while steps remain moves the card to the band (open:
  whether closing should instead hide the card). Both are drawn by mod-kit with one drawing of a
  card (#690): the pane is published before it opens, so it never opens empty, and a pane mod-kit
  refuses is not opened at all; the card goes to the band.
- **Done.** The open step's Done sends "step N done" as Dan's own words and shows "sent" in place of
  the button until Claude answers (open: the words for that waiting state). Claude records its
  verdict through `steps_done`: `checked` (green), `per-you` ("done, per you", grey), or
  `not-done`, which opens the step again with its Done. A Done that cannot reach Claude opens the
  step again with a toast saying why.
- **Copy.** Copies the open step's value on the surface pressed, with a toast saying it was copied
  or why not (open: whether a successful copy needs a toast at all).
- **The last step.** Once every step is finished the card goes away and nothing is kept (open:
  whether the finished card should stay a while).
- **Carry over.** Unfinished steps are kept per project (the repository root, else the folder) in
  the mod's store on this Mac. At the next session start there they are held, not shown, and the
  conversation's first message tells Claude to re-check them and pin the ones left; until then
  Done cannot be recorded on them, and `/steps` shows them as they were kept.
- **Away.** While Dan is away (#621) a new card is not shown on the Mac: it goes to the held card
  through `$.scopeModes.hold`, its row labelled with the card's heading, and pressing that row asks
  Claude to check the steps again and pin them. It is still kept for the next session. With the
  scope modes mod not loaded it is home; one that cannot answer is named in a dim line and the
  card is shown, since a card shown while away costs less than steps nobody sees.
- The pane title is "Manual steps" (open: its words).

### The band, shared by every mod

Claude Code gives the band above the prompt one drawing, so the mods that use it compose one tree.
When several want it at once, the status rows come first (the amber needs-a-look line, then the
Compact row), and what waits on Dan sits under them, nearest the prompt where he will act: the
steps card, then a message to send (Dan chose status on top over waiting first and one at a
time). An open question takes the band alone, and everything else comes back the moment it is
answered, so a number key can only mean the answer (design round, over the question at the
bottom of everything).

How it is built (#610): mod-kit holds the band's one hook, and `tools/check-mod-shared-parts.sh`
fails any other mod that hooks `AbovePrompt`. A mod publishes a row with
`$.modkit.bandRow({ mod, id, slot, lines })` and takes it away with
`$.modkit.clearBandRow({ mod, id })`. The slots, drawn top to bottom, are `needs-a-look`,
`compact`, `handoff`, `held`, `steps` and `message`; a `question` row takes the band alone until it
is cleared. Rows in
one slot keep the order they were first published in, and a row published again under its id is
replaced where it stands. A row is plain data, since only plain data crosses between mods: each
line a list of text runs (`text`, `color`, `bold`, `dim`, `strikethrough`; `color: 'warning'` is
the amber) and buttons (`button`, `label`, `hotkey`, and `plain: true` for Claude Code's plain style, a
survey's row: the hotkey in the accent colour, a colon, the label, `1: 7 days`, or the label alone
with no hotkey, #667). A button is Claude Code's own, drawn with the
key `<mod>:<button>`, and its press reaches the publisher through
`on('ui.press', { plugin: 'mod-kit', element: '<mod>:<button>' }, ...)`, since a closure cannot
cross from one mod to another. The rows live in mod-kit's `$.state`, so a reload keeps them, and
they yield to a survey. Later mods that need more than lines of runs add that shape to mod-kit
rather than drawing the band themselves.

The settled extension (2026-10-04), for the cards that followed the status bar: two more slots,
`handoff` and `held`, so the order top to bottom is needs-a-look, compact, handoff, held, steps,
message, and a question still alone. Status stays on top and what waits on Dan sits nearest the
prompt, as Dan chose; the handoff card appears only at session start. A row may carry a `frame`:
`{ kind: 'box' }` draws it inside a rounded border (the held while away card), `{ kind: 'left-rule' }`
a vertical rule down its left edge only (the steps card's amber rule), each in `color`, a theme key
or raw colour, the terminal's grey when left out. A line may be `{ divider: true }` in place of its
parts: a thin grey line the width of the band, cut at the edge of the frame it sits in, between the
lines of a card. A part may carry `indent`, the blank columns drawn before it (on a line's
first part, where the line starts), so a description sits under its option. A frame kind mod-kit does not draw, a malformed divider or an indent that is not a
whole number of columns is refused when the row is published, never drawn as something else.

A side pane is drawn the same way (#690). A mod still opens and closes its pane itself with
`$.ui.open({ id })`, and publishes what is in it with `$.modkit.pane({ mod, id, lines, frame })`: a
band row's lines and frame with no slot, since a pane holds one card. mod-kit draws it with the very
function that draws a band row, so the steps card cannot read differently in the pane and the band
as cards gain shapes, and a button in it reaches the publisher by the same `ui.press` key.
`$.modkit.clearPane({ mod, id })` stops it, after which Claude Code draws a still open pane itself.
Claude Code keys a pane by its id alone, so a pane id another mod already draws is refused rather
than taken over. `tools/check-mod-shared-parts.sh` fails any other mod that draws a card's parts
or its left rule itself. A pane drawn its own way rather than as a card, such as the goals pane's
live list read at each draw (#612), stays the mod's.

### A message to another session, shared by every mod

A mod telling another open session something (the collision guard's note to the session working
first, scope modes' away and home) sends it with `$.session.send` once and reports `reason` when it
was not delivered. mod-kit's `session.send` hook tries a refused send once more (decided with Dan
after the live check of #605 on 2026-10-04, where auto mode's classifier refused one), never after a
throw, since that can come after the message landed (lessons review of #636), and answers the second
refusal's reason trimmed of its full stop, or "no reason given". It is a hook rather than a method
on `$.modkit` (#688) because a method would send as mod-kit, while each receiver tells its own mod's
messages apart by the sending plugin, and a send cannot be handed to a method, since only plain data
crosses between mods. Claude's own SendMessage is left as it is. `tools/check-mod-shared-parts.sh`
fails any other mod that keeps its own retry: a loop that stops once a send is delivered, or the
"no reason given" fallback.

## Is it live (#617), built 2026-10-04

How the settled card behaves, decided at build where the spec and the rounds were silent. The
ones marked open are the builder's choice, waiting on Dan.

- **Claude makes the card through the mod's own tool** (`mcp__is-it-live__card`) after a merge,
  once while the deploy runs and again once it has checked. The mod confirms the merge with
  GitHub itself and makes no card for a change GitHub does not report merged, or when GitHub
  cannot be asked. Live needs Claude to say how it was checked; could not confirm needs why.
- **Who asked:** an issue another person reported (the mod reads the issue's author, and drops
  the message when the issue was filed from Dan's own account, which is how both Dan's and
  Claude's issues are filed), a pasted Slack thread, or a person Dan named. A message with a dash
  is refused. Dan's own accounts are every account `gh auth status` lists as logged in on the Mac
  (danwright32, and dwright-pennie, which owns repo-digest), read with only the logins taken so
  no token is read; when gh cannot list them, the active account alone counts and the card says
  so (#704).
- **A message waits until Dan presses Mark sent**, never until the next card: a later card for
  the same PR that names nobody keeps the message as it was, sent or not, and a message marked
  sent stays sent while a new card carries the same words; new words wait again (#704).
- **Cards are kept per repository** in the mod's store, the newest 50, so `/live` lists them in
  any later session, newest first, then every message not yet marked sent; `/live` also pins
  each unsent message in the band again, so Copy and Mark sent are at hand. The repository is
  the one GitHub's own link for the PR names, folded to lowercase, so a card Claude typed in
  another case or under a repository's old name (gh accepts both) is one list with the rest;
  cards an earlier build kept under another case are read with them and moved onto the one key
  when that repository's cards are next written. Copy and Mark sent find their card in whichever
  repository it is kept, so they work in any session (#704).
- **The card is mod-kit's boxed card** (`$.modkit.card`, #663), since only mod-kit draws a result
  row: the state word leads the bold title in its colour (green `success`, grey, amber `warning`),
  then why live could not be confirmed, what changed, "See it:" and the link, and the numbered
  clicks. The model reads the same lines as the tool's text result, built from the one list, and
  that text is what the row shows after a reload (mod-kit keeps cards in memory). When mod-kit
  refuses the card, the card is still made, the row shows the text, and Claude is told why.
- **Other mods read the verdict** through `$.isItLive.verdict({ repo, pr })` (#687): the newest
  card's state for that PR and when it was made, or null when no card has been made. It is kept in
  session state, whose reference names this mod, rather than read from the store, whose owner a
  read from another mod's hook does not name; so a card made in another session is no verdict
  here, and winding down asks for the card again rather than guess. A malformed repo or PR throws.
  The verdict is keyed on the repository as GitHub's own link names it, in lowercase, and asked
  in any case, so wind down, asking in GitHub's spelling, finds a card Claude typed otherwise (#702).
- Open: the title for a project with no recorded deploy step ("Merged, no deploy step
  recorded:"), its colour (drawn grey until Dan settles it), the violet drawn as the terminal's magenta, the toast's words (the
  card's title), and the Copy and Mark sent buttons having no shortcut keys.

## Ask before saving (#618), built 2026-10-04

How the settled question behaves, decided at build where the spec and the rounds were silent. The
ones marked open are the builder's choice, waiting on Dan.

- **The write is refused at once and replayed on For good, never held open.** A tool call hook that
  waits on a band press is cut at its 10 second budget and the engine then runs the write as if the
  hook were absent (measured with `claude plugin test` on 2026-10-04), so holding the call would
  fail open. Claude's call is refused with a note that Dan is being asked; For good replays the
  exact call through every other mod's checks; each answer reaches Claude as a note. A hook that
  cannot finish refuses the write. This is also the answer to picker manners' (#615) build time
  check: a tool call cannot wait for a band answer.
- **What the question shows as the rule:** a new file's whole text, the lines a rewrite adds, an
  Edit's new text, and a Bash write's command as written (mod-kit's reader drops heredoc bodies and
  hands back no body, so the command, which carries the text, is shown whole).
- **Just this session** rides the system prompt's memory section, assembled afresh for every
  request, so a compaction keeps it; it is dropped at session end and on /clear.
- **A second save** waits behind the first and is asked once the first is answered.
- Open: the chip "Standing rule", the question "Save this as a standing rule?", the line under each
  answer ("Saved to <file>", "Kept until this session ends; nothing is written", "Nothing is
  saved"), a grey rule on both sides of the rule's text, and wrapping it at 76 columns because the
  band cuts a line at its edge.

## Picker manners (#615), built 2026-10-04

The look is the rounds' (a question in the band, above). The build time check the spec asks for
passed in the test kit: a `tool.call` hook on AskUserQuestion can answer from a band press while the
prompt stays free, provided it waits through a `$` call of its own (`$.pickers.wait`), whose time the
engine does not count against the hook's 10 second budget. Awaiting a plain promise instead was
measured to overrun the budget, after which the engine's own picker answers. What the build had to
settle beyond the rounds, taken from the spec or the rounds' renderings rather than chosen afresh,
and open to Dan changing:

- Each option is Claude Code's own button in its plain style, "1: 7 days", the digit its hotkey in the
  accent colour (mod-kit's `plain`, #667): the nearest the terminal draws to the rounds' "1. 7 days".
- One question per call (CLAUDE.md) is enforced: a call with more is refused, by name, to Claude.
- Typed text withdraws the question, and Claude reads: "Dan did not pick an answer: he is sending a
  message instead, which follows. Answer his message first. If this question is still unanswered
  after that, ask it again once; never more than once." The mod counts talk pasts per question text
  and refuses a third asking.
- Numbered prose maps onto the open question only when the whole message is numbered from 1, with
  no more answers than open questions; anything else is a message. Its echo is one dim transcript
  line per question.
- A multi select question marks a chosen option with a dim "chosen" after it, and Submit with
  nothing chosen says "Nothing is chosen yet." in a toast.
- Next issue offers are known by `metadata.source: "next-issue"`, which the `/next-issue` skill now
  passes. Turning them off says so once in a dim line: "Next issue pickers are off for this
  session; /pickers on brings them back."
- An interrupted turn withdraws the question from the band.

## Handoff (#613), built 2026-10-04

The look is the rounds' (the band at session start, and its changed since lines, above). What the
build had to settle beyond them, each taken from the spec or the rounds' renderings rather than
chosen afresh, and open to Dan changing:

- `/handoff [notes]` asks Claude, in a prompt the mod submits, to write the opening prompt and save
  it through the mod's `save` tool with a title of a few words and the whole prompt. The tool
  refuses unless `/handoff` ran in that session ("A handoff is written only when Dan runs
  /handoff."), so the decision that Claude never writes one on its own is enforced, not asked for.
  After saving, Claude shows the saved prompt and Dan asks for any change, which is saved again the
  same way (the spec's "shown back for Dan to edit or approve").
- What a handoff names is read from its own text: every `#N` and every `milestone N`. Their state is
  read from GitHub when it is saved and again at each session start; a line is "changed since:
  #615 closed", "PR #634 merged", "milestone 18 closed" or "#612 updated" (anything else about it
  changed). One GitHub cannot be asked about gets its own grey line, "#615 could not be checked:
  <gh's reason>", rather than passing as unchanged.
- The band appears only once those reads have answered, so it never shows a handoff as current
  before it is checked. Its age is as of that moment.
- The title is the line's own words, in the terminal's normal colour; Use and Dismiss are Claude
  Code's own buttons, on the line under the changes, as the rounds drew them.
- Use submits the prompt as Dan's own words. A Use that cannot send puts the handoff back and says
  why in a toast. Use or Dismiss on a handoff another session already took, or one replaced since
  the band was drawn, acts on nothing and says so; a replacement is shown instead.
- Kept per Mac: a handoff written on one Mac is offered on that Mac only.

## Not design decisions

The rounds were HTML pages standing in for a terminal. The browser window, the font and the exact
greys are idioms of that rendering, not decisions: the mod draws with the terminal's own text and
dim colours.
