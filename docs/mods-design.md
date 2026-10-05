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
folder, following a `cd` earlier in the same command. The reader gives a subshell's parentheses as
commands of their own (#700), so in `(cd sub && printf x >> notes.txt)` the write is
`sub/notes.txt`, and a `cd` made inside a subshell ends with it; a parenthesis inside a word (`$(`,
`<(`) stays part of the word. A file another open session edited is judged before the command runs;
once it has run, every file it named is added to this session's edits, also when the command
failed, since it may have written before it failed. Only a refusal leaves the record alone, a later
guard's refusal included (both pinned by tests since #700).

What the words do not name is not guessed at, and is neither judged nor recorded: a script
(`bash ./update.sh`, `python3 -c`, `node -e`, `make`), a path built from a variable, a glob or a
command substitution, and a relative path after a `cd` to a folder that cannot be named (`cd $DIR`,
`cd -`). Stopping every such command would refuse ordinary work (every test run) and cost a judgment
each time, and comparing file times after each command cannot say which session wrote a file, so it
would record the other session's change as this one's. The gap is the same one an Edit made
outside Claude Code always had. A quoted lone `>` is read as a redirect (the reader removes quotes
before anything reads its words), so `grep '>' notes.txt` names notes.txt; the cost is a judgment
that comes back Proceed.

mod-kit now carries one reader of which files a command writes, `$.modkit.writes` (#705), built
from `shellWrites` and widened to the routes ask before saving and no build had each missed: `ln`,
`install`, `rsync`, `ditto`, `dd`, `curl -o`, `wget -O`, `ruby` and `gawk` editing in place, every
file of a `sed -i`, and the writes the words do not name (a patch, an inline script, a script on
standard input) reported as such rather than guessed at. Ask before saving reads it; the collision
guard and no build move onto it in #712, and until then `tools/check-mod-shared-parts.sh` names
them as known exceptions on every run.

Since #698 and #726 the shared reader reads a shell's `-c` in a cluster too (`bash -lc`, `zsh -ec`,
`sh -ce`, for sh, bash, zsh, dash and ksh: the script is the first word after the options, `-o` and
`-O` taking the next word), so every guard sees what those run, and it gives a heredoc's body to a
reader that asks: each command `$.modkit.pipeline` gives carries `heredocs`, the body of every
heredoc feeding it, while `$.modkit.commands` still drops it. The write reader names a file `curl -O` or a plain `wget`
saves under the address's own name (curl takes the query and fragment off, as curl 8.7 does; wget
keeps the query, as GNU wget documents), into `--output-dir` or `-P`, and reports a name the server
gives, a recursive wget and `wget -i` as writes the words do not name. The walk up for a checkout's
`.git` entry described below is mod-kit's too now (`$.modkit.workingTree`), which ask before saving
reads; the collision guard keeps its own copy, a known exception until #712.

### rm, and scratch kept out of the record (#674), decided 2026-10-04

An `rm` or `unlink` of a file another open session edited is judged the same way, with the same
cards, toasts and messages; the judge is told the command removes the file. An `rm -r` (`-R`,
`--recursive`, in any cluster such as `-rf`) of a folder is judged once on every file another open
session edited inside it (the coordinator on #691): one judgment that names them all, one card or
toast ("3 files in src", or the file's name when there is one), and one message to each other
session naming its own files, which its toast lists by name. An `mv` source is taken away whole in
the same way, so moving a folder is judged the same. Once it has run, the removed path (the folder,
for `rm -r`) is added to this session's edits. An `rm` of a glob or a variable names nothing, as
decided for #654. A path the command names twice keeps a later removal: in `echo > d; rm -r d`, and
in `cp a x; rm -r x` where `x` is a folder the copy lands in, the folder's removal is still judged
(#700).

A removal says so (changed at Dan's request on 2026-10-04, #700; #674 had kept the edit words): the
toast is "Checked with the other session: safe to remove app.ts." (or "safe to remove 3 files in
src"), the message to the other session reads `Another session wanted to remove "src/app.ts" while
you are working on it, ...`, naming that session's own files, and its toast reads "Another session
wanted to remove app.ts; it was stopped." An ordinary write keeps "edit", and its toast in the
other session keeps the settled "Another session wanted app.ts; ...". The card names the file the
same way for both ("Another session is working on app.ts.").

A message between sessions carries text only (`$.session.send` takes a recipient and a text), so
the receiving side reads the files back out of the sentence. Each name is written as a quoted
string, with JSON's own quoting, and the names are separated by a comma and a space (#700, the
list shape chosen when Dan folded in the finding that a name such as `Notes, draft.md` read as two
files). No comma, space, quote or curly apostrophe inside a name can break that, and the whole path
is sent when the other session's repository is not known. The toast quotes a name holding a comma,
`Another session wanted to remove "Notes, draft.md", app.ts; it was stopped.` A message in the
shape before #700 (names unquoted, from a session still running the code it loaded earlier) is still
read, everything between the verb and "while you are working on it", split on comma and space.

What a session records as its edits, by the edit tools and by shell commands alike: any path inside
its own root (its repository, or its own folder when it works outside one: the record's `repoRoot`,
else its `cwd`), and since #700 (Dan, 2026-10-04) any path inside another git checkout, so a
session working in that checkout is judged against it. A checkout is found on the disk, never by
running git: the nearest folder at or above the path holding a `.git` entry (a folder, or the file
a linked worktree has), looked at once per folder per call, at most 64 folders up, and nothing kept
between calls, so a repository cloned during the session counts at once. Scratch is left out
unless it lies inside the session's own root: `/tmp`, `/private/tmp` (the scratchpad lives there),
`/var/folders` and wherever `$TMPDIR` points, a checkout cloned into scratch included, so it cannot
push real edits out of the twenty the judge reads or raise checks between sessions that share
scratch space. A path in no checkout at all (a file on the Desktop) is left out too. A write is
still judged wherever it lands, so a scratch file an older record already holds is still checked.
What this gives up: a file edited outside every checkout and outside the session's own folder is
not recorded, so another session editing that same file is not judged against it.

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
  read), never a blank. The design rounds' shared terminal (`skills/design-rounds/screens/
  terminal.js`) draws this same line, all in its grey and divided by `|`, whenever a round names
  no status line, and refuses a coloured segment, since a scope mode leads the band; its tests
  read the line from here (#699).
- The amber line's items read as drawn in the rounds: "PR #636 checks failing", "1 job running",
  "dev server kept 2h 14m", "2 unpushed commits", divided by a dim `|` as the status line is.
- A job the watcher measured as stuck (repeating itself, or silent ten minutes) is marked on the
  bar, the spec's "marks the job stuck on the bar" (#706, words not put to Dan): "1 job stuck" ahead
  of "1 job running", and a kept one as "dev server kept 2h 14m, stuck". Without it, a job that went
  stuck while no turn ran showed nowhere.
- A PR whose refresh failed keeps what was last read with its age: "PR #649 checks running, as of
  12m ago" (the spec's "stale with its age"). One that last read as passing stays hidden.
- The Compact row reads "ctx 74%" in amber, then `[ Compact ]`, whether it showed for context or
  for the cache. A compaction that does not run says why in a toast: "Compact did not run: ...".
- The toast 5 minutes before the cache goes cold reads "The prompt cache goes cold in 5 minutes."
- The cache's hour is measured from the last main request, as the spec says, not from the end of
  the turn (#697): each request of a turn starts it again, a subagent's does not (it carries its
  own conversation). While a main turn runs neither the toast nor a Compact row for the cache
  shows, since the turn's next request warms it and Dan has nothing to do; context above 70% still
  brings the row. A compaction of the conversation (the Compact row, `/compact`, the threshold)
  clears the clock as a `/clear` does, so the status line shows no cache until the next request.
- The Supabase project sits beside the repository where a project has one, `SB bidspoke-prod`
  (#697): #610's spec kept it and nothing recorded it dropped, while the rounds drew claude-config,
  which has none. Read as the old status line read it (`SUPABASE_PROJECT_NAME`, else the subdomain
  of `SUPABASE_URL`, from the first `.env` in the folder or the three above it), with the old
  line's label less its colon. Built from the spec, not put to Dan in a round.
- Unpushed commits git cannot count (an error or a timeout) keep their last reading with its age,
  "2 unpushed commits, as of 3m ago", as a PR does, never a zero; a folder that is no repository,
  one with no remote, or one with no commit yet has nothing to push (#697).
- A facts file that cannot be written is said once, in the guards' note style: "Status bar couldn't
  save the cache time for the status line, so it may show it out of date: <reason>." (#697)
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

Built in #706 from the milestone audit and the lessons reviews of #709, not put to Dan, each the
plainest reading of the decisions above:

- **What makes a job a leftover.** A job is judged at a session start only once the Claude Code
  process that started it has gone, measured from the job's own process group: a group in which
  some process has a parent outside the group other than launchd belongs to a running process
  (measured 2026-10-04: a background job's shell has the `claude` process for its parent, and a
  process left behind by its exited parent has launchd, pid 1). What the registry says of the
  session only decides which records are read, never that a job is fair game. So a /clear, which
  closes the record while the process goes on watching its jobs, and a Mac waking from sleep, which
  leaves every session unseen for a while, never expose a running session's jobs; a crashed or
  closed session's jobs are judged as before. A group whose ownership `ps` cannot read is left
  running and named as not judged. A job listed by two records (the one a /clear closed and the
  next) is judged once.
- **One session judges a leftover.** A session claims a leftover by making a folder for it under
  `~/.claude/state/job-watcher/claims` (only one session can make it) and removes it once the job
  is judged; a second session starting meanwhile leaves that job alone and says nothing of it. A
  claim older than ten minutes was left by a session that died while judging and is taken over.
- **A look given up acts on nothing.** A look still running after ten minutes is given up (#694);
  from then on it sends no stop, says nothing and writes nothing, so it never acts beside the next
  look. No second stop is sent for a job whose first is still unanswered: Claude is told once that
  the stop has not been answered. What a stop answered after its look was given up is said, and
  acted on, by the next look, once.
- **Repeating.** A loop is repeating when the end of its output is one pass of up to four lines over
  and over, not only one line: a poll loop printing its error and then "retrying" on each pass is
  stopped as one repeating its error is, when the pass holds an error line. Claude is told about a
  stuck job once a spell: new output no longer ends a spell, since a repeating loop grows as it
  repeats; five minutes of healthy output does.
- **Gone at once.** A job Claude stops with TaskStop is dropped from the reminder and the job list at
  once, and so is one Claude Code reports as ended (its task notification), on the watcher's own
  evidence that its group has ended.
- **Every result reminds.** A refused tool result carries no context, and one refused by a mod
  outside the watcher never reaches it, so the reminder about unkept jobs goes into such a result's
  row as the conversation keeps it: Claude reads it there, and Dan's screen draws the row as it was.
- **Which jobs.** A foreground command Claude Code moves to the background at its timeout is
  recorded like one started in the background, read only from a result that opens with Claude
  Code's own words for it, so a command whose output merely quotes a start (a cat of a test file)
  records nothing; a background start is read only from a call that asked for one. A Monitor task
  is not recorded: Claude Code stops each one at
  its own timeout, thirty minutes at most, and its output reaches Claude as it comes, so it cannot
  run on unseen.

Decided with Dan on 2026-10-04 (his approval of a lessons review finding on #721, recorded on
#706): the leftover judge reads a job's text only as data. The repeated line or pass a leftover
keeps printing reaches the judge only inside the fenced output; the line about its output states
measured facts ("it keeps repeating a pass of 2 lines"), never the text.

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
  session loads them in was not measured. The two differences between the orders left by #694 are
  closed by #706, below.

Built in #706 from the milestone audit and the notes left on it after #694, not put to Dan, each the
plainest reading of the decisions above:

- **Notified once Dan can see it, whichever order.** A question picker manners shows is notified as
  it shows it (its write of the open question). One the tracker sees only as a call (sitting above
  picker manners, or a question Claude Code shows itself) is notified one second after it was asked
  if it is still open then, or at once when picker manners' write of it comes first. So a question
  picker manners refuses at once (more than one in a call, a next issue picker while quiet, one
  talked past) sends no notification in either order. Since #732 a question Claude Code shows
  itself is marked only from the tracker's `classic.PreToolUse` hook, once every guard and settings
  hook has let it through, so one refused after a slow scan is never marked or notified either.
- **Every refusal counts toward failed, whichever mod made it.** A call refused by a mod sitting
  outside the tracker (the collision guard, ask before saving, picker manners above it) never
  reaches the tracker's own hook, but its result's row does, so the rows count too; a call the hook
  already counted is not counted again from its row. A subagent's rows are its own.
- **A save waiting in the band is waiting on Dan.** While ask before saving holds a question in the
  band, read from its writes of the questions it holds (`ask-before-saving.pending`), the session
  shows as waiting on you, "Save this as a standing rule?" (the band's own words), notified once per
  question as "<project> is waiting on you", and the idle "What's next?" is held back until it is
  answered. `tests/test-mods.sh` checks ask before saving's contract still declares it that way.
- **A long call is not a stall.** While any call runs, the session's activity is written each
  minute, and what follows a call is stamped when it returned, never when it began: a test suite
  running twelve minutes no longer shows the session stalled during it or after it.
- **/clear begins again.** A /clear ends the conversation while the process goes on with no session
  start, so the tracker starts its progress afresh then: the new conversation never carries the old
  one's request, steps, goal, failures or waiting marks.
- **A handoff's opening prompt is Dan's request.** The handoff mod's Use button submits the saved
  prompt as Dan's own words, from the plugin, so it becomes the new session's goal text as a typed
  first message does, and closes the pane as his message would. Another plugin's prompt does not.

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
- Only phrasings aimed at Claude switch a mode, never the words in passing (Dan's picker,
  2026-10-04, PR #686). The milestone audit (#702) found the away, home, no coding and build
  phrases still matched anywhere ("the user is stepping away from the form" switched every session
  to away), so every phrase now has to start an instruction of its own: the message, a sentence,
  a line, or a clause after a comma, semicolon or colon, led by nothing but the words a request
  to Claude opens with ("ok", "so", "please", "can you", "let's", "you can", and "I'm" for away
  and home). A phrase in a sentence ending in a question mark never counts.
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
- What no build reads (#702). A shell or interpreter's program is judged where the guard can read
  it: inline (`python3 -c`, `node -e` or `-p`, `perl -ne`, a shell's `-lc`, whose commands are read
  by mod-kit's reader like `bash -c`), a here-string, or text `echo` or `printf` pipes in. A program
  fed by a heredoc, or piped in from anything else, is refused as one it cannot read, as psql fed a
  heredoc already was: mod-kit's command list drops a heredoc's body, and this mod keeps no reader
  of its own (L613). mod-kit gives the body on request since #698 (`heredocs` on each command
  `$.modkit.pipeline` gives); no build moves onto it in #712. The refusal tells Claude that inline
  code is read and judged, so code that only reads still runs. Also refused: `curl -o` and `-O`, `wget` writing a file, `find -delete` and `-exec`
  on what it finds, `awk -i inplace` and `ruby -pi`. Allowed, which it refused before: a GraphQL
  query through `gh api graphql` and a mutation that is issue, label or milestone work; SQL whose
  strings, comments or functions (`replace()`) read like a write; and Claude's own notes outside
  the project, its memory files and plan mode's plans under the home folder's `.claude`. A check
  of a call that throws refuses the call, under any mode, since a skipped hook would let it run.
- After the lessons review of #714: every inline script is judged where the interpreter runs every
  one (`perl -e a -e b`, ruby, node, osascript); what a `find -exec` runs is read as a command of
  its own, its git reading and program included, so `-exec git checkout` and `-exec sh -c` are
  judged; every operation in a GraphQL document is judged, a mutation that spreads a fragment
  being one it cannot read; SQL is read with and without backslash escapes, so `'it\'s'` cannot
  hide a write, and quotes that close under neither reading cannot be judged; and the clients' own
  commands are judged: `\copy ... from` and sqlite's `.import` change data, `\i`, `\gexec`,
  `.read` and `source` run SQL it cannot read, and `\!`, `.shell` and `.system` run a shell.
- How inline code is judged, since the third review of #714 found a hand list of write idioms let
  every route not on it through. Inline code is found by each language's own option grammar
  (`hooks/program.ts`): a flag that takes a value takes the rest of its cluster or the next word, so
  ruby's `-rtime` and perl's `-Mfeature` are no `-e`, perl's `-lane` is `-l -a -n -e`, and node's
  `-pe` is `-p -e`; every script given is judged where the language runs every one, and a program
  in a file (`awk -f`, `sed -f`) cannot be read. The code is then judged per language by what it can
  do (`hooks/code.ts`), for python, node (and deno, bun), ruby, perl, AppleScript, awk and sed:
  write or update a file (python's `open` in any of w, a, x or +, pathlib, `os` and `shutil`;
  node's `fs` write, stream and remove calls; ruby's `File`, `IO`, `FileUtils`; perl's `open` for
  writing, `unlink`, `rename`; AppleScript's write permission; awk's print to a file; sed's `w`),
  run a process (python's `os.system`, `os.exec*`, `subprocess`, `pty`; node's `child_process`;
  ruby's `system`, `exec`, `spawn`, backticks, `%x`, `IO.popen`; perl's `system`, `exec`, backticks,
  `qx`, `open` to a pipe; AppleScript's `do shell script`; awk's `system` and pipes; sed's `e`),
  or build code at run time (`eval`, `exec` of a string, `new Function`, `__import__` or `require`
  of a computed name), which cannot be read. The refusal names what was seen. It reads the text,
  not a parse, so a word that only looks like a call errs toward a refusal; code that writes
  through a library it calls (SQL through a python driver, say) is not seen. A database client is
  read by its own options (`hooks/sql.ts`): every `-c` psql runs, every argument sqlite runs, a
  script file (`-f`, `-init`) as one it cannot read, and what it writes itself: psql's `-o`, `\o`,
  `\w`, `\g` to a file, `\copy ... to <file>`, sqlite's `.output`, `.once`, `.backup` and `.save`,
  MySQL's `tee`, each allowed to the scratchpad, and a shell when the target is `|command` or a
  `program`.
- After #714 merged (#724). Only a `|` (or `|&`) feeds a command what another prints: the command
  before it in a list joined by `;`, `&&`, `||`, `&` or a new line feeds it nothing, so
  `cd repo && python3 --version`, `git status; node -v` and `ls && bash` run, where no build had
  refused them as scripts it could not read. Only the reader can see which separator stood outside
  the quotes, so mod-kit's `$.modkit.pipeline({ command })` gives the same commands as
  `$.modkit.commands`, each with `pipedFrom`, the words of the command a `|` feeds it from; every
  command in a piped subshell, an `if`, `while`, `until`, `for` or `{ }` group, or a shell's `-c` or
  `-lc`, reads what feeds it, and a group's output piped on cannot be read. The reader also looks
  past the reserved words that lead a command (`then git commit` reached every guard as a command
  named then), and past each word that only runs the command after it by that word's own options, so `timeout 5`, `nice -n 10`, `stdbuf -oL`, `env -u HOME`, `sudo -u dan` and
  `xargs -I {}` no longer hide the interpreter, git or file command behind them from any guard;
  `command -v` runs nothing and is the command itself. Inline code is read in its language's one
  spelling of a capability before it is judged: python's `__import__('os')`, `import_module`,
  `sys.modules`, `import os as o`, `o = os`, `from os import system as run`, a star import and
  `posix` all reach `os`; node's fs renamed, imported or destructured is `fs`; ruby's
  `Kernel.system`, `::Kernel.system`, `Kernel::system` and `IO::popen` are the builtins, and
  `send(:system)` or `method(:exec)` on any object runs a process; perl's `CORE::`,
  `CORE::GLOBAL::` and `POSIX::` builtins are the builtins, and `IPC::Open3` and its kin run a
  process. Python's `open` is read by where each API takes its mode, so `Image.open('a.png')` and
  `gzip.open('data.json.gz')` only read; dbm and shelve are read by their flag (shelve creates by
  default), a method's first argument is its mode only when it reads as one, and only the part
  before tarfile's `:` decides. MySQL's `-p` takes only the password attached to it, so no letter
  of a password is read as `-e`; its `--init-command` is SQL it runs, and `--pager=<command>` runs a
  shell. Away holds an AppleScript in a file (`osascript notify.scpt`, or one redirected in) and one
  that runs a script it cannot read (`run script`), as it holds one fed by a heredoc. Not read yet:
  a wrapper in front of what `find -exec` runs, `env -S`, and a heredoc or here-string feeding the
  commands a shell's `-c` runs.
- Winding down finds what to finish from the branch the session is on when it turns on: its PR, the
  issues the PR closes, and the branch and worktree. The deploy is the is it live mod's verdict for
  that PR (#687), read through `$.isItLive.verdict` in the repository GitHub's own link for the PR
  names, never Claude's word: only Live or "no deploy step recorded" finishes it; deploying, could
  not confirm live, no card yet, and a verdict that cannot be read each keep the turn end refused
  and say which, and with is it live not loaded the deploy is unmeasured, never live. On the default branch with no PR and nothing uncommitted there is nothing to
  finish; outside a repository too. A check that cannot read GitHub never counts as finished. It is
  checked at each turn end and each minute, and the toast reads "Wind down finished: safe to close
  this session."
- What winding down finishes, as the milestone audit (#702) left it. Turning it on again (the
  phrase or `/winddown`) keeps the target it has, PR included, rather than reading it afresh. While
  the session sits on its default branch with no PR, each check reads the branch again and follows
  the session onto one. With no PR for the session's own branch, it finishes every PR this session
  opened: each `gh pr create` the session or any of its agents runs is noted from the link gh
  prints, so a PR an agent opened in a worktree the session is not in is finished before "safe to
  close"; each is read in the repository its link names, its branch the PR's own head. A PR in
  another repository than the session's has its branch on GitHub checked there, while its local
  branch and worktree, in a checkout this session cannot see, are said to be unreadable rather than
  read as cleaned, so winding down does not call it finished. A note that cannot be made is
  toasted, since winding down would not know that PR. An agent named after this
  branch's PR, an issue that PR closes, or a PR the session opened goes ahead (the PR is looked up
  first when it has not been yet); any other issue number is still new work.
- Held while away: opening anything (`open`, BBEdit), AppleScript that types, clicks or brings an app
  forward, cliclick and Peekaboo. Since the milestone audit (#702) also an AppleScript dialog
  (`display dialog`, `display alert`, `choose file` and the like; a notification banner takes no
  focus and goes ahead), an AppleScript fed by a heredoc, which cannot be read, browser tools that
  open a page or a tab (Playwright's `browser_navigate` and a new tab, Chrome's `navigate` and
  `tabs_create`), and the Artifact tool's open action; publishing a page goes ahead. A held tool
  call's row replays that call, its input given to Claude. The keystroke guard's own actions are
  held too (#707): it asks its heads up only beneath every mod's `tool.call` hook, so this mod's own
  hold comes first, and while away it hands the action to `$.scopeModes.hold` itself rather than
  ask in the band, which the phone cannot show. `hold` answers with the card and refusal this mod
  words for its own held calls, so the two read the same. A row reads as what it would do ("Open report.html in Google
  Chrome", "Type into Overture"), its button "Open" or "Do it". Pressing one takes the row away and
  asks Claude to do that one thing, so it still passes every guard (the keystroke guard's heads up
  included). The same thing held twice is one row. A /clear ends the session and every mode with it.
- The phone line ends every reply to a phone message while home, not only the first.

### Manual steps behaviour (#614), decided in the build, 2026-10-04

No round: each follows from the spec and the settled surfaces above. The ones marked open were
not settled by either and are waiting on Dan; until he decides, the build does the plainest thing.

- **The handover.** Claude pins steps through the `steps` tool: a heading and a list of steps,
  each with a title, a direct `https://` link or, where there is no page, an exact location, the
  click path and any value to paste. A step with no link or location is refused, naming it, and
  so is a link with a space or a control character anywhere in it (#708). Each
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
- **Asking does not lower the width** (#708). Claude Code places an unasked pane from 110 columns
  rather than 144 once its id has been asked for, in that session and later ones, until Dan closes
  it by hand, and the card closing its own pane does not count. So `/steps` opens the card under its
  own pane id (`steps`) and a new card tries a different one (`steps-card`): at a 120 column laptop
  a new card is still the band after any number of `/steps`. `/steps` with the card in the unasked
  pane moves it to its own and closes the other, and a card pinned while a pane shows one goes into
  that pane rather than opening a second; one mod-kit will not draw there closes that pane and goes
  to the band.
- **The link** (#708). A step's link is drawn as Claude Code's Link, so where the terminal draws
  hyperlinks (Ghostty, iTerm2, kitty, WezTerm, VS Code, Warp, the desktop app) a long dashboard
  link cut at the edge still opens and copies whole. Claude Code draws none on Apple Terminal, where
  the link is plain text cut at the edge, so the link line also carries **Copy link**, as the value
  line carries Copy, with the same toasts ("Copied the link for step 1."). The Link has no text of
  its own, since on a terminal without hyperlinks a Link with text is drawn as the text then the
  address, which would show it twice. The click path and an exact location are text, one line
  each, and wrap at the edge rather than being cut (#734), the amber rule reaching down every row
  they take; the link and the value are still cut, since Copy link and Copy take them whole. Docked
  beside a fullscreen transcript, the pane asks to be as wide as the card's widest line other than
  the link, up to 80 columns, so a click path wraps less there; a width Dan drags it to wins (open:
  Copy link on every link rather than only a long one, and the 80 column cap).
- **Done.** The open step's Done sends "step N done" as Dan's own words and shows "sent" in place of
  the button until Claude answers (open: the words for that waiting state). Claude records its
  verdict through `steps_done`: `checked` (green), `per-you` ("done, per you", grey), or
  `not-done`, which opens the step again with its Done. A Done that cannot reach Claude opens the
  step again with a toast saying why.
- **A Done Claude never answers** (#708). While "sent" shows, Claude Code's own working indicator
  is what says the turn is alive. When the turn "step N done" started ends, answered, interrupted or
  failed, with no verdict on that step, Done comes back and a toast says "Claude did not say whether
  step N took. Press Done to ask again." A turn already running when Done was pressed, which the
  prompt waits behind, and a subagent's turn do not count. A verdict Claude gives later still
  lands. "sent" is never kept in the store, since the turn that would answer it does not reach the
  next session (open: the end of that turn as the limit rather than a time, and the toast's words).
- **A Done whose prompt starts no turn** (#734). A "step N done" queued behind a running turn and
  then dropped (Esc drops the queue), or one a prompt hook refused, starts no turn, so the end of
  its turn never comes. Once no main turn has run for two minutes with the step still sent and its
  turn never started, Done comes back with the same toast. The two minutes count from the press, or
  from the end of the last main turn, never while one runs, so a prompt waiting behind a long turn
  is never taken for dropped. They outlast the settings hooks that run between one turn's end and
  the next turn's start (the Stop hooks, 15 seconds at most, and the prompt hooks, 10, each event's
  in parallel), so a queued prompt whose turn starts after them keeps its "sent" (open: the two
  minutes).
- **Copy.** Copies the open step's value on the surface pressed, with a toast saying it was copied
  or why not (open: whether a successful copy needs a toast at all).
- **The last step.** Once every step is finished the card goes away and nothing is kept (open:
  whether the finished card should stay a while).
- **Carry over.** Unfinished steps are kept per project (the repository root, else the folder) in
  the mod's store on this Mac. The root is the main checkout's for a worktree, so steps handed over
  in a worktree session come back in the main checkout and in any other worktree of it (#708); a
  card a worktree session kept under the worktree's own folder before that is found there and moved,
  its unfinished steps folded under its heading into any card already under the root, so both are
  held for Claude to re-check and neither is lost. A step held under both (its title and link) is
  listed once, from the first fold (#734).
  A repository that cannot be read is never taken as none: the toast says the steps could not be
  saved for the next session, rather than keeping them under the worktree's folder again.
  At the next session start there they are held, not shown, and the conversation's first message
  tells Claude to re-check them and pin them again with the steps tool, a step found done as
  `already-done`, even when every one is: a card all already done is not pinned and the kept steps
  are cleared, where only telling Dan would leave them to come back at every session start (#708).
  Until then Done cannot be recorded on them, and `/steps` shows them as they were kept. Only a
  session's own start holds them: a reload of the mod mid session runs its start again, and the
  card already in the session is the one Dan is working through, so it stays live (#708).
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
fails any other mod that hooks `AbovePrompt`: any line of its hooks naming it as a string, in any
quotes, since the engine takes a filter however it is spelled and an unfiltered `ui.render` hook
that tests `e.component` (#698; a line that is only a comment is not read). The same goes for a
result row, `ToolResult`. A mod publishes a row with
`$.modkit.bandRow({ mod, id, slot, lines })` and takes it away with
`$.modkit.clearBandRow({ mod, id })`. The slots, drawn top to bottom, are `needs-a-look`,
`compact`, `room` (the account room card, #659), `handoff`, `held`, `steps` and `message`; a `question` row takes the band alone until it
is cleared. Rows in
one slot keep the order they were first published in, and a row published again under its id is
replaced where it stands. A row is plain data, since only plain data crosses between mods: each
line a list of text runs (`text`, `color`, `bold`, `dim`, `strikethrough`; `color: 'warning'` is
the amber; `href` makes a run Claude Code's Link to that address, #708, with no text of its own when
the run's text is the address, so a terminal without hyperlinks does not draw it twice; an href
holding a control character is refused, since one could end the hyperlink's sequence early) and buttons (`button`, `label`, `hotkey`, and `plain: true` for Claude Code's plain style, a
survey's row: the hotkey in the accent colour, a colon, the label, `1: 7 days`, or the label alone
with no hotkey, #667). A button is Claude Code's own, drawn with the
key `<mod>:<button>`, and its press reaches the publisher through
`on('ui.press', { plugin: 'mod-kit', element: '<mod>:<button>' }, ...)`, since a closure cannot
cross from one mod to another. The rows live in mod-kit's `$.state`, so a reload keeps them, and
they yield to a survey. Later mods that need more than lines of runs add that shape to mod-kit
rather than drawing the band themselves.

The settled extension (2026-10-04), for the cards that followed the status bar: two more slots,
`handoff` and `held`, so the order top to bottom is needs-a-look, compact, handoff, held, steps,
message, and a question still alone. The account room (#659) then added `room` after compact, so
the order is needs-a-look, compact, room, handoff, held, steps, message. Status stays on top and what waits on Dan sits nearest the
prompt, as Dan chose; the handoff card appears only at session start. A row may carry a `frame`:
`{ kind: 'box' }` draws it inside a rounded border (the held while away card), `{ kind: 'left-rule' }`
a vertical rule down its left edge only (the steps card's amber rule), each in `color`, a theme key
or raw colour, the terminal's grey when left out. A line may be `{ divider: true }` in place of its
parts: a thin grey line the width of the band, cut at the edge of the frame it sits in, between the
lines of a card. A part may carry `indent`, the blank columns drawn before it (on a line's
first part, where the line starts), so a description sits under its option. A frame kind mod-kit does not draw, a malformed divider or an indent that is not a
whole number of columns is refused when the row is published, never drawn as something else.

One question at a time, and one look for every question (#703, #705, after the milestone audit).
Two mods can each have a question open at once: ask before saving leaves its question in the band
while Claude carries on, and a picker can then land beside it. Drawn together, both numbered from 1,
a key meant for the picker could press For good. So the band draws the first question asked, alone,
and the next once it is cleared; `$.modkit.shownQuestion()` names the one in view. A question is
asked with `$.modkit.question({ mod, id, chip, question, body, options, submit })`, which builds it
the settled way: `[chip]` grey and the question amber on one line, the asker's `body` lines (ask
before saving's rule and file), each option as Claude Code's plain button `1: label`, its number its
hotkey, its description dim and indented 3 columns under it, and `submit` last, bracketed. `bandRow`
refuses a `question` row, so no mod draws a question its own way; the two hand built rows had drifted
into two looks on one surface. A text run may carry `wrap: true`, drawn on as many lines as it needs
rather than cut at the band's edge (a question's text and its descriptions wrap, so the brackets at
the end of an issue review option are never cut off). Inside a left rule (#734), a row with no run
that wraps keeps one rule mark per line; a row with one draws its rule as a single column laid over
the row's whole height and clipped to it, holding a mark for every row its lines could take (one per
character of a wrapping line, since a terminal row holds at least one), so the rule reaches down
every wrapped row however wide the band is.

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

### Which guard decides first (#707), built 2026-10-04

Not put to Dan; each is the plainest reading of the issue, and each is open to his changing it.

- **What decides the order.** Hooks on one event nest by tier, then by load order, outermost
  first. Measured in a live headless session on 2026-10-04 (Claude Code 2.1.289, two probe
  plugins): the load order is the order the plugin folders are listed in, which for the mods is
  `CLAUDE_CODE_PLUGIN_DIRS` as the sync writes it, alphabetical by folder; swapping the two folders
  swapped the nesting, and a `dependencies` entry did not move either. The tiers above and beneath
  a person's own (`prepend`, `append`) are an organisation's managed plugins, so a mod has no way
  to choose its place, and a guard's place among the others is its folder name. Under
  `disableAllHooks` no person's mod loads at all.
- **So the order is never relied on.** A guard that only refuses (no build, winding down, the
  secret guard, the style check, the keystroke guard's checks of the app in front) decides in its
  `tool.call` hook, as before. A guard that asks Dan, judges with a model, tells another session or
  toasts a verdict decides from `classic.PreToolUse` instead, which the engine raises inside
  `tool.call` beneath every plugin's `tool.call` hook (measured in the same session, and how
  `claude plugin test` raises it), and only after calling `next`, which there runs the settings
  hooks (the payload write gate, the push gates) and never the tool. So every refusal, a mod's or
  a settings hook's, comes before Sonnet is asked, another session is told, a toast says safe or
  Dan is asked, whatever the folders are called. The collision guard, the keystroke guard's heads
  up and ask before saving's question all decide there; the collision guard notes a call as this
  session's edit only when it judged and let that call through. Renaming folders to force an order
  was not done: it holds only while every name sorts the right way.
- **What still comes after.** Claude Code's own permission step decides after `classic.PreToolUse`:
  a permission rule, the auto mode classifier, or Dan's answer to a permission prompt. A call it
  refuses may already have been judged and toasted safe, or had its heads up asked. The engine
  offers no hook later than `tool.check`, which runs before the mode settles an ask, so this is
  left as it is.
- **Two asking guards on one call.** A Bash call that both types into an app and writes a file
  another session edits is held by both the keystroke guard and the collision guard; whichever
  loads beneath asks first, and the other may then refuse. Rare enough to leave.
- **A mod that answers a call itself** (manual steps, is it live, picker manners, handoff, the job
  watcher's keep, scope modes' switch to build) never calls `next`, so no guard beneath it sees the
  call. Each asks `$.modkit.screen(e)` first and answers with its refusal. mod-kit asks the secret
  guard's `$.secretGuard.screen`, which makes the same check its `tool.call` hook makes, card and
  toast included, from a hook on its own noun's event, where every mod's noun is reachable whatever
  the load order; a noun's own method sees only the mods loaded beneath it. With the secret guard
  not loaded nothing refuses; a screen that cannot ask refuses the call with a card (L42), and so
  does the secret guard's own when its check fails. Only the secret guard is asked: no build and
  the style check refuse what a call would change or write, which an answered call does not.
  `tools/check-mod-shared-parts.sh` fails each `tool.call` hook that answers a call with a result
  and never asks in its own body (#732): a screen in the hook beside it covers nothing, a screen
  named only in a comment asks nothing, and a hook written as a named function is read where that
  function is defined.
- **While Dan is away** the keystroke guard holds its action through `$.scopeModes.hold` before
  any check of the app in front, since he cannot bring it forward from his phone. An away check
  that fails refuses the action rather than ask a question nobody may see, and its toast says the
  away check could not be read ("Couldn't tell whether you are away, so typing into Overture was
  stopped."), never "Blocked typing into Overture", which reads as the action judged (L11, #732).
- **How it is tested.** A mod's tests can load only that mod for real. An inline stand-in cannot
  carry another mod's module (the engine requires a helper taking `$` to be declared at the top of
  a module file), and one plugin holding two real guards is refused for registering `tool.call`
  twice without a matcher (both measured 2026-10-04). So each guard is tested for real with a
  stand-in refuser loaded both above it (`prepend`) and beneath it (`append`), and with a settings
  hook's refusal; each answering mod with a stand-in screen; mod-kit's screen with a stand-in
  secret guard; and the secret guard's screen with a stand-in answering mod above it.
- **The goal tracker waits for them too (#732).** It is not a guard, but its mark and notification
  carry the question's text, so it marks a question only once the refusing guards have let it
  through: a question picker manners shows from picker manners' write of it, made after its screen,
  and one Claude Code shows itself from the tracker's own `classic.PreToolUse` hook, after `next`.
  A question the secret guard refuses, however long its scan takes, is never marked or notified.

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
  repository it is kept, so they work in any session (#704). `/live` asks GitHub for the name the
  session folder's repository has now (`gh repo view`, which follows renames), so a checkout whose
  origin still carries an old name lists the cards kept under the new one; a PR with a card under
  both names is listed once, as its newest card, still carrying any message an older card under
  the other name owes, pinned from that card so Mark sent finds it (#720). When GitHub cannot be
  asked it lists what is kept under the remote's name and says the rest may be missing.
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
  Edit's new text, and a Bash write's command as written (the command carries the text, any heredoc
  body included, so it is shown whole).
- **Just this session** rides the system prompt's memory section, assembled afresh for every
  request, so a compaction keeps it; it is dropped at session end and on /clear.
- **A second save** waits behind the first and is asked once the first is answered. Each save asks
  under its own id and its buttons carry that id, so a press answers only the save it was drawn
  for: a second tap after the first was answered cannot land on the save asked next (#705).
- **Asked beneath every guard** (#705). The question is asked from `classic.PreToolUse`, which the
  engine raises beneath every mod's `tool.call` hook, so a save the style check, the secret guard or
  no build refuses is refused before Dan is asked, whatever order the mods load in, and he is never
  asked to approve a save that cannot land. Since #707 it asks only after the settings hooks beneath
  it have decided too, so a save the payload write gate refuses is never asked about either. The skip for Dan's own permanent words stays a
  `tool.call` hook, the one place the saved result can be read, and passes the save down through
  every other guard all the same.
- **Every shell route** (#705): a Bash call is read by mod-kit's one reader of what a command writes
  (`$.modkit.writes`), which follows a `cd` before a relative path and resolves a copy into a folder.
  A write its words do not name (a patch, an inline script, a script on standard input) is judged by
  the lasting memory its text, and any patch file it reads, mentions. A copy into the memory folder
  itself counts; a file in a temporary folder (`/tmp`, `/var/folders`, the session scratchpad) loads
  into no session, so it does not, unless it is in a git checkout there (#726: a session started in
  a repository or worktree cloned under `/tmp` loads its `CLAUDE.md`), found by mod-kit's walk for
  a `.git` entry. A temporary path built from a variable cannot be looked for, so it counts, and a
  disk that cannot answer refuses the save.
- **The permanent words** (#705) count only as an instruction to Claude in Dan's own message, typed
  or from his phone: "from now on" anywhere, "always" or "never" leading the message, a sentence, a
  line or what a colon introduces (after an opening word such as "ok", "also" or "and"), or after
  "please", "you should" or "you must"; "remember" as a request in the same places. Read anywhere,
  "never mind the screenshots" and "it always fails" skipped the question (#705); "and", "but",
  "so", "should" and "must" inside a sentence lead narrative ("It ran and never finished", "that
  should never take this long"), so they count only as a sentence's opening word (#726). Words limiting it to the moment ("for now", "today", "this
  time", "this session") win, since saving without asking is the harm and asking is not.
- **Claude Code's auto-memory writer goes through tool calls** (the spec's check at build, #705).
  In 2.1.289 the post turn extractor runs as a forked query (`querySource: "extract_memories"`)
  whose saves are Write and Edit tool uses, and the engine's declaration names its memory fork among
  the loops whose calls raise `tool.call`. So its saves are asked about like any other.
- The look is mod-kit's question (`$.modkit.question`, above), shared with picker manners; the
  rule's text wraps at the band's edge rather than at a fixed width.
- Open: the chip "Standing rule", the question "Save this as a standing rule?", the line under each
  answer ("Saved to <file>", "Kept until this session ends; nothing is written", "Nothing is
  saved"), and a grey rule on both sides of the rule's text.

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
  message instead, which follows. Answer his message first." After the first pass it adds "If this
  question is still unanswered after that, ask it again once; never more than once."; after the
  second, "He has now talked past or dismissed this question twice, so do not ask it again: carry
  on from what he says." (#703: the second pass still said ask again, and that asking was refused.)
  A third asking is refused.
- What counts toward that limit (#703, after the milestone audit). A dismissal counts as well as a
  talk past (spec point 3). Only Claude's own questions count: another mod's question asked through
  `$.ui.ask` (the keystroke guard's heads up, Switch to build) reads the same every time, and was
  refused for good after two talk pasts. The same question is the same text however it is spaced or
  punctuated, in any script, or the same chip over the same answers, each described the same way,
  however it is put, since Claude rewords a question when it asks again. Answers with no
  description (a bare Yes and No) mean whatever the question asks, so two questions under one chip
  with only those are two questions, and a question with no letters at all is never the same as
  another by its text (#726: a question in another script compared as nothing, and two Yes or No
  questions under "Confirm" shared one count). A question waiting behind another mod's in the band, which Dan never
  saw, is withdrawn by his message but not counted.
- Dan's messages from his phone through Remote Control count as his own, as in every other mod: the
  band is not drawn on the phone, so a message there is the only way he can answer or dismiss.
- Where no band is drawn at all, Claude Code's own question dialog asks instead, since it is drawn on
  every surface: a `claude -p` or SDK run (where it refuses, so another mod's `$.ui.ask` fails closed
  as written), Dan's phone or VS Code attached, or surfaces that cannot be read. Open: whether a
  phone merely attached while Dan is at the Mac should keep the band.
- The wait for Dan's answer has no deadline: it is a person's answer, not machine work (L737), and
  the prompt stays free throughout, so nothing hangs behind it; the turn interrupted withdraws it.
- Numbered prose maps onto the open question only when the whole message is numbered from 1, with
  no more answers than open questions, and only onto the question in view (with another mod's
  question drawn, "1. yes" is meant for that one); anything else is a message. Its echo is one dim
  transcript line per question.
- A multi select question marks a chosen option with a dim "chosen" after it, and Submit with
  nothing chosen says "Nothing is chosen yet." in a toast.
- Next issue offers are known by `metadata.source: "next-issue"`, which the `/next-issue` skill now
  passes. Turning them off says so once in a dim line: "Next issue pickers are off for this
  session; /pickers on brings them back." While they are off, Claude's system prompt says so too, so
  an offer made from CLAUDE.md's issue loop rule, which carries no tag, is a plain list as well
  (spec point 4: this overrides the loop rule for that session only, #703).
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

## Account room (#659), settled 2026-10-04

Decided with Dan in design rounds on a dark terminal (the issue comment "Decided with Dan
(2026-10-04, design rounds)"). Where it differs from the issue's spec, this wins.

| Surface | Decision | Round |
| --- | --- | --- |
| Shape | A boxed card in the band above the prompt, rounded border (over one line, and a lead line plus figures line) | 1 |
| Lead | Amber, "This account is low. Work has room", then `[ Switch ]` and `[ Dismiss ]` (over "Work has more room" and "Switch to Work for more room") | wording |
| Figures line | Room left, not used: "88% of 5h left, resets 6:40 PM · 70% of week left, resets Thu 9 AM · as of 2h ago" (over "5h 12%, resets ..." and "used until") | wording |
| Dim note | None. Dan dropped it, superseding spec items 5 and 6 where they asked the card to say that use in claude.ai, the desktop app or the phone is not counted and that switching changes the account for every session on the Mac. The reading's age stays on the figures line | wording |
| Switch in progress | The amber lead itself becomes the progress, with elapsed seconds, and the buttons go while it works: "Switching to Work: signing claude.ai out in the browser… 25s", then the sign in page step in the same form (over a step list, and a status line at the foot) | 2, wording |
| Switch failed | The lead turns red (a logout that did not happen is genuinely wrong): "claude.ai didn't confirm the sign out. Nothing else was changed.", with `[ Try again ]` and `[ Dismiss ]`. It claims only what was checked: that the page did not confirm | wording |
| No account has room | The same box, amber lead "This account is low. No other account has room" with `[ Dismiss ]`, and one line: "This account's 5h resets first, at 6:40 PM · Side has no reading yet and may have room" (over every account listed, and one squeezed line) | 3, wording |
| Nickname | Claude Code's standard question dialog: chip "Nickname", "What should this account be called?", the email and org dim under it, a text field, Save and Skip (Esc skips) (over a dim line pointing at /accounts rename, and a question in the band) | nickname round |

Built (#659), with what the rounds and the spec left to the build, each taken from a rendering or
the spec rather than chosen afresh, and open to Dan changing:

- The card is published to mod-kit in a slot named `room`, after `needs-a-look` and `compact` and
  before `handoff`: it is about this account's state, so it sits with the status rows, above what
  waits on Dan from other mods. mod-kit gained the slot in the same change (#670). An older mod-kit
  refuses the row, and that is said once per session in a dim transcript line.
- The sign in page step reads "Switching to Work: opening the sign in page… 3s", the round's
  "in the same form". The seconds count from the start of the step shown, so a stalled step is the
  one whose count keeps climbing.
- Reset times are in the Mac's own time zone: a time alone when the reset falls today ("6:40 PM"),
  else the weekday and time ("Thu 9 AM"), minutes left out on the hour, as every round drew them.
  Each time uses the offset in force at that instant, so a reset after a clock change is not an
  hour off; a time zone that cannot be read shows UTC and says so. The age is in its largest unit
  ("2h", "14m", "<1m").
- An account with no nickname is named by its email and org: "work@example.com (Acme)" in the card
  and "work@example.com, Acme" under the dialog's question, as the rounds drew each.
- The dialog is a pane the mod draws, opened as a dialog (focused, Esc closes it, toasts wait),
  because Claude Code's own question dialog cannot carry the dim line or a field with Save. Enter
  in the field saves; an empty name saves nothing. Skip and Esc record that the ask was answered,
  so neither Mac asks again.
- Claude Code holds a pane opened unasked back below 144 terminal columns, and the dialog opens
  unasked at session start, so in a narrower window it waits unseen (found in the live check on
  2026-10-05). The transcript then says once that the account has no nickname yet, that the
  question shows at 144 columns, and that `/accounts rename` answers it now, since a pane Dan asks
  for opens at any width.
- When the triggering limit is both (95% 5 hour and 90% weekly at once), an account must have more
  room on both. "Most weekly room" ties are broken by the most 5 hour room, then the newest reading.
- Nicknames are shared through the claude-sync payload, in `mods/account-room-nicknames.json`: the
  mods tree is mirrored, and a file beside the mod folders (not in one) is not watched for hot
  reload and is named by no mod list. The repository is public, so the file is keyed by a hash of
  the account and org ids and holds no email; the nickname itself is published.

Not settled by any round, built so the spec holds, and each an open question for Dan:

- **Another Mac's readings unavailable.** The spec asks the card to say so; no round drew it. It is
  a plain line at the foot of the card: "Dans-MacBook-Pro's readings are unavailable: not
  downloaded from iCloud yet".
- **A sign in that does not finish** (`claude auth login` exits non zero or times out after 10
  minutes): a toast, "Switch did not finish: Login cancelled", and the card comes back. On success:
  a toast, "Switched to Work.", and the card is dismissed for the session. A Switch stopped at the
  sign out also toasts the reason ("Switch stopped: no browser logout route has been proven yet"),
  so Try again is not the only way to find out why (L148).
- **Dismiss** lasts for the rest of the session, as the spec says; it does not come back if the
  account recovers and runs low again in the same session.
- **/accounts rename** with no name renames this session's account; with a name (a nickname or an
  email) it renames that one.

## Not design decisions

The rounds were HTML pages standing in for a terminal. The browser window, the font and the exact
greys are idioms of that rendering, not decisions: the mod draws with the terminal's own text and
dim colours.
