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
| A blocked action in the transcript | A grey boxed card: title "Blocked by <guard>", the reason, then the safe way in dim text. Drawn once, by `mod-kit`, for every guard. | 1 (shape: card over plain error row and two named lines), 3 (colour: grey) |
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
- A scope mode is set by another mod with `$.statusbar.setMode({ mode })`, one of `NO BUILD`,
  `WINDING DOWN` and `AWAY`, or `null` to clear it.

Why the split: a live probe on 2026-10-04 showed a mod's `$.ui.status` line is drawn by Claude Code
as a warning notice, amber with a warning sign and the mod's name in front, and terminal colour
codes come out as broken characters. A mod cannot own a grey line with amber items through it; the
classic status line command passes colour through, and the band above the prompt draws colour.

## Job watcher and goal tracker (#611, #612), behaviour settled 2026-10-04

- A waiting loop is stopped by the watcher only when the line it keeps repeating reads as an error.
  A loop repeating "waiting" is reported to Claude and never stopped (picker).
- A job kept on purpose, with a reason, still shows in amber in the band like any running job,
  named with its run time ("dev server kept 2h 14m"): kept does not mean out of sight (design round).
- Turn end with a running job that was not kept: the turn is refused until Claude stops or keeps
  it, and Dan sees nothing of the refusal itself, only what Claude does next (picker).
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
| Notification | One per waiting moment, naming the project: "<project> is waiting on you" with the question, or "<project> needs a permission" with what for. It replaces the PermissionRequest "Permission needed" hook and the idle "What's next?" hook while a question is open, in the same change (pickers) |

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
  the week stays open, so the next session tries again.

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
- The fallback route checks before it sets: when `/rename` refuses or answers with nothing
  recognisable, Dan's next message carries the name as `sessionTitle` only if that message shows
  the session still has no name. A different name on it, or a `/rename` of Dan's first, wins.
- After a `/clear` (a new session id with no fresh start event) the new conversation is not named.

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
`compact`, `steps` and `message`; a `question` row takes the band alone until it is cleared. Rows in
one slot keep the order they were first published in, and a row published again under its id is
replaced where it stands. A row is plain data, since only plain data crosses between mods: each
line a list of text runs (`text`, `color`, `bold`, `dim`, `strikethrough`; `color: 'warning'` is
the amber) and buttons (`button`, `label`, `hotkey`). A button is Claude Code's own, drawn with the
key `<mod>:<button>`, and its press reaches the publisher through
`on('ui.press', { plugin: 'mod-kit', element: '<mod>:<button>' }, ...)`, since a closure cannot
cross from one mod to another. The rows live in mod-kit's `$.state`, so a reload keeps them, and
they yield to a survey. Later mods that need more than lines of runs (the steps card's amber rule
down its left edge, the boxed held while away card) add that shape to mod-kit rather than drawing
the band themselves.

## Not design decisions

The rounds were HTML pages standing in for a terminal. The browser window, the font and the exact
greys are idioms of that rendering, not decisions: the mod draws with the terminal's own text and
dim colours.
