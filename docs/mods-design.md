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
   the goals pane's state colours, and the status line's limit shares (amber past 70% on the 5 hour
   limit or 85% on the weekly, red at 100%, in the Status bar's Colour row).
2. **Plain wording.** A refusal says what was blocked and the safe way, in one or two short
   sentences: "Blocked: this would print GITHUB_TOKEN. Check it without printing: test -n, its
   length, or gh auth status." Settled 2026-10-03, then applied to every refusal and toast of the
   three guards at Dan's choice.
3. **Ask before focus moves.** Anything that brings an app forward is announced and waits for Dan
   (CLAUDE.md, and the keystroke guard enforces it).
4. **A mod's own `$` noun answers within 10 seconds.** Claude Code cuts a call to a plugin's noun
   off at 10 s: measured live on 2026-10-05 on 2.1.289 (#744), a probe plugin's `$.probe.wait` was
   rejected at 10,003 ms with "did not answer within 10000ms". `claude plugin test` does not apply
   that limit, so a noun that waits longer passes every test of its own and fails only in a
   session. So a noun never waits on a person (Dan's answer has no bound) or on anything else with
   no bound under 10 s: it answers at once, or settles from a timer under 10 s. A hook that must
   wait on Dan asks through an engine `$` call, which does not spend its budget, or refuses and lets
   the answer arrive later, as ask before saving does. `tools/check-mod-noun-waits.sh`, run by
   `tests/test-mods.sh`, fails a mod whose noun's code waits on `$.ui.ask` or on a promise only a
   later event settles (its resolve kept, handed on or called back) with no timer under 10 s
   settling it in the same executor. Before #744 removed it, picker manners' `$.pickers.wait` failed
   it (`payload/mods/picker-manners/hooks/register.ts:89` at 53c803b, which `git show` still
   reproduces); in the tree, the `waits-in-map` fixture in `tests/test-mods.sh` is that shape and
   fails it on every run. Since #756 it also follows a promise made outside a noun's code (in
   another hook) and kept in a variable, map or list a noun reads, and counts a wait bounded when
   the noun races it against a timer under 10 s made in another executor, a helper's included.
   A noun's 10 s does not stop while its own `$` calls are in flight, unlike a hook's budget:
   measured live on 2026-10-05 (2.1.289, #756), a noun whose only wait was
   `$.process.run(['/bin/sleep', '13'])` was rejected at 10,003 ms, like the 13 s timer control at
   10,002 ms. So `$.ui.ask` in a noun is always cut, and so is any other slow `$` call there.
   Since #802 the check names those too: a noun's own `$.process.run` with no `timeoutMs` under
   10 s (none given waits up to Claude Code's 30 s default) and a `$.model.complete` with none under
   10 s (a completion can take a minute), unless the noun races it against a shorter timer. Its first run found two in session-registry's
   engine.create code (a save's `mv` and the repository root lookup), now bounded at 5 s.

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
its own word however it is spaced. Since #712 the collision guard reads which files a command
writes through mod-kit's one write reader (`$.modkit.writes`, below), as `hooks/collide.ts`'s
`judgedWrites` judges them: every file content goes into (redirect targets, `tee`'s files, `sed -i`
and `perl -i`'s files, the destination of `cp` and `mv`, a file inside it when it is a folder, and
every other write the shared reader names), stamped (`touch`) or emptied (`truncate`), as an edit;
and every file removed, `mv`'s sources among them, as a removal. A folder made or a mode changed
touches no other session's work and is not judged. Paths are made absolute against the session's
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
standard input) reported as such rather than guessed at. Ask before saving reads it, and since
#712 so do the collision guard and no build, so `tools/check-mod-shared-parts.sh` names no known
exception any more. Since #743 it reads a variable the command set before a write as its value
(`F=path; ... "$F"`), asking the shared reader for the assignments it otherwise drops
(`pipeline(cmd, { assignments: true })`, through `commandWrites`, off for every other caller); what
it cannot be sure of stays as written (Ask before saving, below).

What #712 brought into it, from the two copies it replaced. Beside `files`, the files content goes
into, it reports `changes`: a file removed (`rm`, `unlink`, `rmdir`, a `mv`'s source, `find
-delete`, `shred -u`), stamped (`touch`), emptied (`truncate`, `shred`), made (`mkdir`) or changed
in mode (`chmod`, `chown`, `chgrp`), with `tree` where the whole folder is reached (`rm -r`, `-R`, a
`mv`'s source, `find -delete`); ask before saving reads only `files`, so a removal is not taken for a
save. A file edited in place is marked `edits`, a copy of one source onto one name `mayBeFolder` (it
lands inside the name when that is a folder, which only the disk can say). Where the copies
disagreed, each case was decided and tested: `>& file` writes the file (the collision guard's
reading), `wget --spider` saves nothing (no build's), `find -fprint` writes its file and `find
-delete` removes what it finds (no build's), and a download whose files no word names says the
folder it lands in (`into`) when the words name one. Inline code is judged by the per language
judge no build built (below), moved into mod-kit (`hooks/code.ts`, with the option reader in
`hooks/program.ts`), in place of the write reader's own list of write idioms and of interpreter
names, so a program that writes, runs a process or cannot be read is a write the words do not name,
for `python3.12` or `/usr/local/bin/python3.11` as for `python3`; a script file fed on standard
input (`sh < setup.sh`, `cat build.py | python3`) is one too, marked `script`, its files to read in
`inputs`. A file command xargs gives its files to (`ls | xargs rm`) is a write the words do not
name (#730).

Since #698 and #726 the shared reader reads a shell's `-c` in a cluster too (`bash -lc`, `zsh -ec`,
`sh -ce`, for sh, bash, zsh, dash and ksh: the script is the first word after the options, `-o` and
`-O` taking the next word), so every guard sees what those run, and it gives a heredoc's body to a
reader that asks: each command `$.modkit.pipeline` gives carries `heredocs`, the body of every
heredoc feeding it, while `$.modkit.commands` still drops it. The write reader names a file `curl -O` or a plain `wget`
saves under the address's own name (curl takes the query and fragment off, as curl 8.7 does; wget
keeps the query, as GNU wget documents), into `--output-dir` or `-P`, and reports a name the server
gives, a recursive wget and `wget -i` as writes the words do not name. The walk up for a checkout's
`.git` entry described below is mod-kit's too now (`$.modkit.workingTree`), which ask before saving
reads, and since #712 the collision guard as well.

Since #712 and #730 the reader also reads what each shell and interpreter runs, so every mod reads
it once: each command `$.modkit.pipeline` gives carries its `program` (inline code, or what its
standard input gives it: a heredoc's body, a here-string, text `echo` or `printf` pipes in, or a
heredoc piped in through `cat`), the `script` file it runs instead (an operand, a file redirected or
piped in through `cat`), its `language` and the `verdict` of the per language judge. A shell whose
script it can read is read as the commands it runs, whether the script came by `-c` or on standard
input (`bash <<'EOF'`, `cat <<'EOF' | sh`), and a heredoc or here-string feeding a `-c` feeds the
commands it runs. It reads a `case`'s clauses without taking a pattern's `)` for a subshell's close,
`env -S`'s string as the command it runs, what `find -exec` runs past any wrapper in front of it,
an input redirect (`cat<<EOF`, `cmd<file`) as a word of its own however it is spaced, and marks a
command xargs runs (`xargs`), since its operands come from its input.

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
a linked worktree has), through mod-kit's one walk for it (`$.modkit.workingTree`, since #712), at
most 64 folders up, and nothing kept between calls, so a repository cloned during the session counts
at once. A path whose checkout the disk cannot say (a folder it cannot read, or one deeper than the
walk goes) is recorded, since mod-kit refuses rather than guesses: noting it costs at most a judgment
that comes back Proceed, where the guard's own walk had taken a failed look for no checkout. Scratch is left out
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
| Facts always shown | Project, 5 hour limit, weekly limit, cache time left, model and effort, account and org (status round 2; the account room's nickname replaces the name and org when one is set, as Dan expected in the live check on 2026-10-05) |
| Facts shown only when they need a look | Unpushed commits, PR and checks (failing or running), a running background job, context above 70% (status round 2) |
| Hidden | Branch, uncommitted files, commits behind main (status round 2) |
| Account | The session's own account, the one its limits belong to (#815, Dan 2026-10-05: "the status bar must always name the right account for the session"), superseding the picker's "whatever the login file names now". The mod reads the login file at session start into the facts file, as the account room reads it at its start, so the bar and the rename dialog name the same account; a Switch made in another session no longer changes this one's. A facts file written before #815 falls back to the login file as it stands; one whose start read failed says "account unknown". The account room's nickname for the account replaces the name and org when one is set (live check, 2026-10-05). |
| Colour | The status line is all grey, but for a limit's share past its threshold: amber over 70% on the 5 hour limit or over 85% on the weekly, red at 100%, the number alone, judged on the share as shown (Dan, 2026-10-05, picked over amber alone and red alone); the needs-a-look items in the band are amber; the Compact button is Claude Code's own bold white (colour round, design rounds). A deliberate exception to standing rule 1: a running PR, a running job, a job kept on purpose and a scope mode label are amber though nothing needs doing yet, because Dan chose to keep work in flight in view (status round 2, colour round, kept job round) and a mode changes what Claude will do; the scope mode label shows even when nothing else is in the band (scope mode round). |
| Where it is drawn | The always-shown facts stay on the classic status line script below the prompt, fed by the mod. The amber items are drawn by the mod in the band above the prompt, only while something needs a look or a scope mode is on (picker, after the probe below; scope mode round). |
| The band | Two rows when both show: the amber line, then the Compact row carrying the context figure, so context shows once. Either row alone otherwise (design round). |
| Order of the amber line | A scope mode (NO BUILD, WINDING DOWN, AWAY) leads it in bold, since it changes what Claude will do (scope mode round). Then most urgent first: a failing or running PR, a running job, unpushed commits, so a narrow window cuts off what can wait longest (design round) |
| Compact button | Claude Code's default button, `[ Compact ]` in bold white, pressed by clicking or ctrl+x tab then Enter (design round, styles copied from a live probe) |

Built (#610), with what the rounds left to the build, each taken from the rounds' renderings or
the spec rather than chosen afresh, and open to Dan changing:

- The status line reads `claude-config | 5h 68% (1h 52m) | week 91% (4d 14h) | cache 41m |
  Opus 5.5 (high) | Dan, Personal`, as every round drew it: the account is the session's own, as
  the login file named it at session start (#815), by its display name (its email when it has none)
  and the organisation, or the account room's nickname in their place
  when the account has one. It is drawn by `statusline.sh` in the mod's
  folder, which the `statusLine` setting names; that setting lives in each Mac's own settings and
  does not travel, so it is set once per Mac. A fact that cannot be read says so ("cache unknown"
  when the mod has written nothing for the session, "account unknown" when the login file could not be
  read at session start; only a facts file from before #815 reads the login file as it stands),
  never a blank. The design rounds' shared terminal (`skills/design-rounds/screens/
  terminal.js`) draws this same line, all in its grey and divided by `|`, whenever a round names
  no status line, and refuses a coloured segment, since a scope mode leads the band; its tests
  read the line from here (#699).
- The amber line's items read: "PR #636 checks failing", "1 job running", "dev server running 2h
  14m", "2 unpushed commits", divided by a dim `|` as the status line is.
- Jobs say whose they are, what state they are in, and who acts (#784, Dan on 2026-10-05: "I dont
  really know how to read this" of "suite summary wait kept 1h 4m, stuck"). "Kept" and "stuck" are
  gone as internal words. A job is running, waiting (a poll loop quiet or repeating a line that is no
  error: it waits on something outside, a queued CI run, and is never stuck), or not progressing
  (silent ten minutes or repeating, anything else), the last with who it is left to: "1 job not
  progressing, left to Claude", "suite summary not progressing 1h 4m, left to Claude". Stalled first
  within each owner. A background agent's jobs are one item under its task's name, so the line never
  reads as though the conversation in front of Dan is hung: "agent fix CI: PR 776 rerun wait
  waiting 12m, 1 job running". No job item asks Dan to act. An entry whose process and output file
  are both gone is dropped rather than shown.
- A background agent listed as running whose tool calls have stopped for twenty minutes (#759) is
  named ahead of the jobs: "agent fix CI quiet 34m, left to Claude"; Claude is told once on its next
  tool result, with the agent, how long, and the last tool call it started and whether it returned.
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
  named with its run time: kept does not mean out of sight (design round). Since #784 it reads by
  its state ("dev server running 2h 14m"), not as "kept".
- Whose job (#784): every loop's tool calls pass through the one watcher, so each job records the
  background agent that started it, and its reminders and notices go to that agent while it runs,
  to this conversation once it has ended ("left by agent fix CI").
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
| Notification | One per waiting moment, naming the project: "<project> is waiting on you" with the question, or "<project> needs a permission" with what for. The permission request Claude Code raises for its own question dialog is that question, never "needs a permission" (#814): it sends nothing for a question the tracker already notified, and for one it does not hold (a subagent's) it is the one "is waiting on you" with the question, marked by that question's own call apart from any permission open beside it (#824). A /clear in the second before a question is notified still notifies it, once (#824). The mod sends all three, the idle "What's next?" only while nothing is being asked, and both notifying settings hooks are removed; if mods are ever off there are no notifications (pickers) |
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
- Every question is asked by Claude Code's own dialog: picker manners only refuses some, and hands
  the rest down (#744). Hooks on one event nest by tier (an organisation's prepended plugins,
  everything a person installs, the appended ones, the built in ones) and within a tier in load
  order, outermost first, and the plugin API gives a person's mod no way to say where it sits; since
  picker manners calls `next` for every question it lets through, the tracker sees each one wherever
  the two sit. The tests load picker manners both above and beneath the goal tracker. (Until #744,
  picker manners answered questions from its band itself, and the tracker also watched its writes of
  the question it held open, `picker-manners.open`; that reader went with the band question.)

Built in #706 from the milestone audit and the notes left on it after #694, not put to Dan, each the
plainest reading of the decisions above:

- **Notified once Dan can see it, whichever order.** A question is notified one second after it was
  asked if it is still open then. So a question picker manners refuses at once (more than one in a
  call, a next issue picker while quiet) sends no notification in either order. Since #732 a
  question is marked only from the tracker's `classic.PreToolUse` hook, once every guard and
  settings hook has let it through, so one refused after a slow scan is never marked or notified
  either.
- **Every refusal counts toward failed, whichever mod made it.** A call refused by a mod sitting
  outside the tracker (the collision guard, ask before saving, picker manners above it) never
  reaches the tracker's own hook, but its result's row does, so the rows count too; a call the hook
  already counted is not counted again from its row. A subagent's rows are its own.
- **A save question is a question like any other.** Since #777 ask before saving has Claude ask in
  Claude Code's own dialog, so the tracker marks and notifies it as it does every question. Until
  then it read ask before saving's band questions from `ask-before-saving.pending`; that reading,
  and the check in `tests/test-mods.sh` that held the two mods to one shape, went with the band
  question (L29).
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
- **A `+` note while a question is open** was left as typed, with no context and no toast (#701),
  while picker manners held questions in the band and withdrew one when Dan typed. Since #744
  Claude Code's own dialog asks every question and holds the keyboard while it does, so no note can
  be typed under one, and the mod no longer reads picker manners' state.
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
| Picker manners (#615) | A question in the band | The chip and the question on one line, then each option on its own line with its description indented on the line under it (over two columns and a flowing line). Picker manners stopped drawing questions in #744, and ask before saving in #777; mod-kit's question builder went in #796 |
| Ask before saving (#618) | The question | Superseded by #777: Claude asks in Claude Code's own dialog, naming the file and stating the rule in plain words. Was: the rule's exact text and the file it would go to between the question and the three answers, set off by a grey rule |
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
- Confirmed live on 2026-10-05 (#713): the built-in `/rename` route named a real session on this
  Mac, queued by the mod and answered "Session renamed to: Mac statusline shell script
  configuration" at 9:39:43 AM ET, ten minutes after the session started at 9:29:42, at the mark.
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
- No build is a guard against the usual routes Claude takes, not a sealed box (Dan, 2026-10-04,
  recorded on #730): it reads what Claude reaches for when an edit is refused, and a determined route
  around it (a script that writes what no word names) is not what it is for. #730 was the last pass
  on its routes inside the mods milestone; any found after it collect in one backlog issue outside
  the milestone (#760), never another round here.
- What no build reads (#702). A shell or interpreter's program is judged where the guard can read
  it: inline (`python3 -c`, `node -e` or `-p`, `perl -ne`, a shell's `-lc`, whose commands are read
  by mod-kit's reader like `bash -c`), a here-string, or text `echo` or `printf` pipes in, and since
  #712 a heredoc's body: no build reads every command and every file a call changes through
  mod-kit's readers (`$.modkit.pipeline`, each command with its program and the judge's verdict, and
  `$.modkit.writes`), keeping no reader of its own (L613), so `python3 - <<'EOF'` is judged by what
  its body does and `bash <<'EOF'` as the commands it runs. A program piped in from anything else,
  or fed by a heredoc with no body, is refused as one it cannot read, as psql fed a heredoc still
  is. The refusal tells Claude that inline code or a heredoc is read and judged, so code that only
  reads still runs. A script file runs, named as an operand or fed on standard input (`cat build.py
  | python3`), as tests and checks do. A removal says so ("this would not remove dist"), as do a
  folder made and a mode changed; a relative path after a `cd` is judged where it lands, so a note
  written after `cd` into the scratchpad is one. Also refused: `curl -o` and `-O`, `wget` writing a file, `find -delete` and `-exec`
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
  (mod-kit's `hooks/program.ts` since #712): a flag that takes a value takes the rest of its cluster or the next word, so
  ruby's `-rtime` and perl's `-Mfeature` are no `-e`, perl's `-lane` is `-l -a -n -e`, and node's
  `-pe` is `-p -e`; every script given is judged where the language runs every one, and a program
  in a file (`awk -f`, `sed -f`) cannot be read. The code is then judged per language by what it can
  do (mod-kit's `hooks/code.ts` since #712), for python, node (and deno, bun), ruby, perl, AppleScript, awk and sed:
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
  that runs a script it cannot read (`run script`), as it holds one fed by a heredoc with no body.
- The routes left from #724, closed in #730, each tested: a `case` pattern's `)` no longer cuts a
  piped loop's feed (`curl x | while read l; do case $l in a) sh;; esac; done` is refused); ruby's
  `send(:spawn_worker)` and `method(:fork_helper)` name no builtin, the whole name having to be one;
  away holds `cat script.scpt | osascript`, the file being the script it runs; a wrapper in front of
  what `find -exec` runs is looked past (`-exec timeout 5 python3 -c ...`); `env -S` runs the command
  line it splits; a heredoc or here-string feeding a shell's `-c` feeds the commands it runs; a file
  command xargs gives its files to cannot be read for which files (`ls | xargs rm` is refused, `ls |
  xargs wc -l` runs); python's `fileinput` in place and pathlib's `.rename` and `.replace` write
  files (a plain `str.replace` does not); `mariadb` is read as the mysql client it is; away holds a
  JavaScript for Automation dialog (`app.displayDialog()`); and an input redirect written without a
  space (`cat<<EOF`, `python3 -<<EOF`, `cmd<file`) is read. The session tests read with mod-kit's
  own reader rather than a stand-in that split inside quotes: a test cannot import another mod's
  files, so each mod whose tests need it keeps a byte for byte copy under `tests/mod-kit`, which
  `tools/check-mod-shared-parts.sh` holds to mod-kit's own, naming the `cp` that brings a stale one
  back.
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
  the session onto one. It finishes every PR this session opened, whether or not the session's own
  branch has a PR (#856; before that only a session with no PR of its own looked, and a session
  whose branch PR was finished parked three PRs it had opened "waiting on you"): each `gh pr create`
  the session or any of its agents runs is noted from the link gh prints, so a PR an agent opened in
  a worktree the session is not in is finished before "safe to close", and only those, so another
  session's PRs never hold it; the branch's own PR, matched by its link, is read once. Each is read
  in the repository its link names, its branch the PR's own head. A PR in
  another repository than the session's has its branch on GitHub checked there, while its local
  branch and worktree, in a checkout this session cannot see, are said to be unreadable rather than
  read as cleaned, so winding down does not call it finished. A note that cannot be made is
  toasted, since winding down would not know that PR. An agent named after this
  branch's PR, an issue that PR closes, or a PR the session opened goes ahead (the PR is looked up
  first when it has not been yet); any other issue number is still new work.
- Winding down means finalizing everything (Dan, 2026-10-06, #856: "winding down means finalizing
  everything. ask me questions if you have them when they come up but those should be merged"). Its
  note, the `/winddown` context and the turn end refusal all say it the same way: winding down
  finalizes everything the session has open, every PR it opened is merged and never left open
  waiting on Dan, and when a decision or sign off is needed Claude asks him right then with an
  AskUserQuestion picker, one question at a time, and merges once he answers. Asking is never new
  work, so AskUserQuestion is never refused while winding down.
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
- **A step left in prose** (#863). On 2026-10-06 a session ended a turn with "The one thing still
  waiting on you is the migration command from my earlier message"; the command had only ever been
  prose in an earlier reply, and Dan never saw it. So at the turn's end (`classic.Stop`) the mod
  reads Claude's own final message (`last_assistant_message`, never Dan's) for a step handed over
  in prose: "waiting on you", "once you run" (or apply, paste, click, approve), "you'll need to run",
  "needs you to paste" and the like, "your step". One negated right before it, in its own clause
  and within five words ("nothing else is waiting on you", "no longer waiting on you"), or quoted
  as the name of a thing ("is waiting on you", the notification) does not count; a negation in
  another clause ("the deploy did not finish, so it's waiting on you") does not hide it. When one is there and no unfinished step is on a card Dan can see
  (a card carried from an earlier session is held, not shown, so it does not count), the turn end
  is blocked with: check it against the current state, pin it with the steps tool, say in one line
  that it is on the card, or say that nothing is left for Dan. Never twice in one chain of turn
  ends (`stop_hook_active`), so it cannot loop; never in a -p run or the SDK, which have no steps
  tool; a block from a Stop hook beneath (winding down) is kept beside it. A card that cannot be
  read is logged and the turn end passes, rather than sending Claude to pin a card that may be
  there.
  Measured before it shipped (L172, L36), with the matcher itself, on every turn final message of
  the 30 days to 2026-10-06 on this Mac: 19 of 7,647 (0.25%) fired, 19 of the 6,091 outside the
  temp folder sessions that headless runs use (0.31%). Read one by one, 18 hand Dan a real step (a
  restore to run, a relaunch, a setting to type in, an issue to check), and one says a show is
  still waiting on his reply in Overture's Reached out list, which is his to do but not a step. The real sentences that only quote or negate the phrase, which a plain match
  fired on in the same sample, are passing cases in `tests/waiting.test.ts`, and the 2026-10-06
  wording is the case that must fire.
  The original session ran on the other Mac, so its wording is taken from the issue.
- **Waiting on you** (#863). While the open step is Dan's to do, the card's heading line reads
  "<heading>  waiting on you", the words dim after the amber heading; once its Done is sent the
  step waits on Claude, the step line says "sent", and the words go until the next step opens. On
  the card's own line rather than a row of its own: the card already is the `steps` row of the
  band whenever no pane holds it, and a pane is always on screen (docked, or inline above the
  prompt), so a second row naming the same step would state it twice (L605). The issue asked for
  "waiting on you: <step title>" in the band; the open step's title is the line under the heading.

### The band, shared by every mod

Claude Code gives the band above the prompt one drawing, so the mods that use it compose one tree.
When several want it at once, the status rows come first (the amber needs-a-look line, then the
Compact row), and what waits on Dan sits under them, nearest the prompt where he will act: the
steps card, then a message to send (Dan chose status on top over waiting first and one at a
time). Questions are not drawn in the band: since #744 and #777 Claude Code's own dialog asks
every question.

How it is built (#610): mod-kit holds the band's one hook, and `tools/check-mod-shared-parts.sh`
fails any other mod that hooks `AbovePrompt`: any line of its hooks naming it as a string, in any
quotes, since the engine takes a filter however it is spelled and an unfiltered `ui.render` hook
that tests `e.component` (#698; a line that is only a comment is not read). The same goes for a
result row, `ToolResult`. A mod publishes a row with
`$.modkit.bandRow({ mod, id, slot, lines })` and takes it away with
`$.modkit.clearBandRow({ mod, id })`. The slots, drawn top to bottom, are `needs-a-look`,
`compact`, `room` (the account room card, #659), `handoff`, `held`, `steps` and `message` (a
`question` slot that took the band alone went in #796). Rows in
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
message. The account room (#659) then added `room` after compact, so
the order is needs-a-look, compact, room, handoff, held, steps, message. Status stays on top and what waits on Dan sits nearest the
prompt, as Dan chose; the handoff card appears only at session start. A row may carry a `frame`:
`{ kind: 'box' }` draws it inside a rounded border (the held while away card), `{ kind: 'left-rule' }`
a vertical rule down its left edge only (the steps card's amber rule), each in `color`, a theme key
or raw colour, the terminal's grey when left out. A line may be `{ divider: true }` in place of its
parts: a thin grey line the width of the band, cut at the edge of the frame it sits in, between the
lines of a card. A part may carry `indent`, the blank columns drawn before it (on a line's
first part, where the line starts), so a description sits under its option. A frame kind mod-kit does not draw, a malformed divider or an indent that is not a
whole number of columns is refused when the row is published, never drawn as something else.

No question in the band (#796). Picker manners (#744) and then ask before saving (#777) moved to
Claude Code's own question dialog, so the band's question slot and mod-kit's question builder
(`$.modkit.question`, which drew one question at a time, alone, in one settled look, #703, #705)
had no caller and were removed in #796 (L29). A row naming a `question` slot is refused as no slot. A text
run may carry `wrap: true`, drawn on as many lines as it needs rather than cut at the band's edge
(so the brackets at the end of a long line are never cut off). Inside a left rule (#734), a row with no run
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
- **A mod that answers a call itself** (manual steps, is it live, handoff, the job watcher's keep,
  scope modes' switch to build) never calls `next`, so no guard beneath it sees the call. Each asks `$.modkit.screen(e)` first and answers with its refusal. mod-kit asks the secret
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
  through, from the tracker's own `classic.PreToolUse` hook, after `next` (every question is shown
  by Claude Code itself since #744). A question the secret guard refuses, however long its scan
  takes, is never marked or notified.

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

How the settled question behaves, decided at build where the spec and the rounds were silent.

**Asked in Claude Code's own dialog, in plain words, and never for a subagent** (#777, Dan,
2026-10-05: "I thought standing rule questions were going to be claude pickers, not the mod
version? also that's wildly hard to read. I don't really know what it's asking."). Picker manners'
decision (#744, below) that Claude Code's own dialog asks every question now covers this one too,
and the band question is removed rather than kept beside it (L29). Three defects went with it:

- **The surface.** The refusal tells Claude to ask Dan with AskUserQuestion: one question, with
  `metadata.source` `ask-before-saving:<the refused call's id>`, naming the file and stating the rule
  in one plain sentence, never the command or the raw text. The mod checks that question (it must
  name every file, carry no answers of its own, and be about a save still waiting) and sets its
  header (`Memory rule`, the dialog takes at most 12 characters) and its three answers itself (For good, "Saved to <file>"; Just this
  session, "Followed until this session ends; nothing is written"; Not at all, "Nothing is saved"),
  so the label read back is always one of them. Dan's answer is read from that dialog's own result,
  and what Claude must do next is said in the same result: For good approves the identical call
  once (#738, below), Just this session keeps Claude's plain words in the system prompt, Not at all
  saves nothing. A dialog that closed itself while Dan was away (`afkTimeoutMs`) and an answer typed
  in his own words approve nothing. No prompt or note goes to the session for any of it.
- **Subagents.** A subagent's write to lasting memory is refused and never asked about, and its
  refusal tells it to put the rule and the file in its final report. Its call ran in its own tree
  and conversation; before #777 its question came up in Dan's main session, and For good then
  asked the main session (twice) to send the subagent's call again, which would have run its edit in
  the main checkout. Which loop a call runs in is known only at `tool.call` (`e.agentId`), so the
  judgement for a subagent is made there; the main session's refusal stays at `classic.PreToolUse`,
  beneath every other guard. Claude Code's own background loops (the memory writer) carry an id no
  agent list names: refused the same way, and the main session is told what they would have saved,
  so it can save it itself and ask Dan first. A subagent's write elsewhere is untouched.
- **The false trigger.** The subagent's call was a python heredoc editing a test file whose text
  built fixture homes, `$E27HA/CLAUDE.md`, from `E27HA="$WORK/..."`. A mention of lasting memory
  built from a variable now counts only when that variable could hold a path when the command runs:
  each Bash call is a fresh shell, so a variable reaches it only from Claude Code's environment
  (asked through `printenv`, since `$.env.get` takes literal names alone), a shell profile, or the
  command itself. One the command gives a value is followed through the variables that value is
  built from; a literal, a path under home, or a command's output can be anything, so it counts; a
  fresh `$(mktemp ...)` folder does not; any other use of the bare name (a loop, a `read`) counts.
  A variable every shell sets for itself (`PWD`, `OLDPWD`, `TMPDIR`, `USER` and the like) always
  counts, whatever the environment holds.
  A variable named nowhere and set nowhere expands to nothing, so a path through it reaches no
  lasting memory. The same holds for a target the command names through such a variable.

- **The write is refused at once, never held open.** A tool call hook that waits on Dan is cut at
  its 10 second budget and the engine then runs the write as if the hook were absent (measured with
  `claude plugin test` on 2026-10-04), so holding the call would fail open. A hook that cannot
  finish refuses the write, and so does one that cannot read Dan's answer.
- **For good asks Claude to send the call again** (#738, built 2026-10-05). Until then For good
  replayed the call itself, and in auto mode, Dan's `defaultMode`, it never saved: the classifier
  judges a call by the model request that produced it and refused the replay ("gave no verdict ...
  the request that produced this action did not ask for one"), Claude sent the call again as told,
  and that was asked about as a new save, so For good went round for ever (seen twice on
  2026-10-05). Now:
  - For good records an approval in `$.state`, so a reload keeps it, keyed by what the save writes
    (a Write's file and content, an Edit's file and change, a Bash call's command and the folder
    its relative targets resolve in; never the call's description, which Claude words afresh, and a
    path by any spelling of the same file). The key is taken where Dan is asked, so it approves the
    file he was shown: the same relative path sent again after the session has moved is another
    file, and is asked about again.
  - Claude is asked to send the same call again, given whole, since a compaction may have taken the
    call out of its context. Since #777 that is said in the result of the dialog Claude itself
    opened, so it reaches the loop that asked; until then it went as a note or a prompt of the mod's
    own to the main session, whichever loop had made the call.
  - The call that writes the same thing takes the approval at `classic.PreToolUse` and goes on to
    the settings hooks and the permission check beneath, the classifier among them, never asked
    about again; every mod's own checks have seen it already. It is used once: the same call after
    it is asked about again. Its result is said: to Claude as `Saved to <file>, as Dan answered For
    good.`, and when it fails, to Dan as a toast, since he pressed For good believing it saved.
  - **Chosen: an approval stands 10 minutes** (L523), the issue's number, not a measurement. One
    Claude does not use in that time lapses: it is taken out and said to Dan and to Claude, and the
    call after it is asked about again. It is refused on its age where it is used too (L567), since
    a reload drops the timer that says it lapsed; the session start after a reload times each one
    still waiting again. A time read back that is not a number stands for nothing (L50: it compares
    false against every clock, so read plainly it would never lapse), and timing it is never a wait
    `$.clock.after` refuses by throwing; a timer that cannot be set is said, and never stops Claude
    being asked. One the session ends before is said to Dan. A tool call running longer than
    10 minutes before Claude's next step lets it lapse, which costs one more question, never a save
    unasked.
  - **Chosen: one path in every permission mode, so the mode is never read.** The issue allowed
    keeping the replay where no classifier judges calls, chosen by the session's mode. The engine
    gives a mod that mode only on the classic hook events (`permission_mode`), a reading as old as
    the last such event, while Dan can change the mode between it and his press; Dan runs auto mode
    everywhere, so the replay would run almost never and its failures would go unseen (L535); and
    the call Claude sends again meets the same permission check the replay met, the dialog in
    default mode included. Nothing tries one path and falls back on the other's error (L156).
  - What only a live session shows: whether the classifier allows the call Claude sends again, which
    it judges against the conversation as for any call (a For good cannot overrule it), and that a
    plugin's prompt starts Claude's turn while the session is idle.
- **An approved durable lesson is not asked about again** (#867, built 2026-10-06; Dan: "The
  confirmation that I want to add the durable lesson should be enough to indicate that I want to add
  it forever."). The durable lesson check (`hooks/durable-lesson-check.sh`) has Claude propose a
  rule in a picker, and Dan's add was followed by For good's own question for the same write (L330:
  an acknowledgement must be consulted by every rule raising that question). Now the picker carries
  `metadata.source` `durable-lesson` and the rule in `metadata.rule`, and the mod treats it as it
  treats its own question: the rule must be stated word for word in the question Dan reads (and run
  to at least 40 characters, so a word or two cannot approve any entry), the call may carry no
  answers, and the mod sets the answers itself (Add to LESSONS.md, Project memory instead, Skip), so
  the label read back is its own. Only Add to LESSONS.md, read from the dialog's result, records an
  approval: keyed to `~/.claude/LESSONS.md` and the rule, for the same 10 minutes as For good, and
  lapsing, refused on its age and said at session end the same way. The write it lets through is an
  Edit or Write whose one lasting target is that file, which only adds (an Edit keeping the text it
  replaces, a Write that is the old file with one block inserted in one place), and whose added text
  is exactly one entry: `- **L<n>.`, the rule word for word (bold marks and wrapping ignored), then
  only its provenance as `(repo#N, YYYY-MM-DD)` and one SHORT line no longer than the index cap. Nothing Dan
  did not read rides along with it (lessons review of #869). Anything else, a shell append included, is asked
  about as before. It is used once; a write that does not land gives it back for the rest of its
  time, so the corrected write is not asked about either, and a refusal by another guard is said to
  Dan and recorded, so its lapse never calls it unused (#764). Project memory instead and Skip
  approve nothing, and a subagent's picker records nothing.
- **What Dan reads as the rule:** Claude's own plain sentence and the file (#777). The band showed a
  new file's whole text, the lines a rewrite adds, an Edit's new text, or a Bash command as written,
  which for a heredoc or a script was unreadable.
- **Just this session** rides the system prompt's memory section, assembled afresh for every
  request, so a compaction keeps it; it is dropped at session end and on /clear. The rule kept is
  Claude's plain words after the file in its question.
- **Each save waits under its own id** (the refused call's), which the dialog's `metadata.source`
  names, so an answer applies only to the save it was asked about (#705). The same save refused
  again waits under the newer id alone.
- **Asked beneath every guard** (#705). The question is asked from `classic.PreToolUse`, which the
  engine raises beneath every mod's `tool.call` hook, so a save the style check, the secret guard or
  no build refuses is refused before Dan is asked, whatever order the mods load in, and he is never
  asked to approve a save that cannot land. Since #707 it asks only after the settings hooks beneath
  it have decided too, so a save the payload write gate refuses is never asked about either. Since
  #738 the call Claude sends again after For good is judged by every one of them again, as any call is. The skip for Dan's own permanent words stays a
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
- **A target the words cannot name** (#743, decided at build 2026-10-05). `F=<memory
  folder>/MEMORY.md; printf ... >> "$F"` appended to `MEMORY.md` unasked: the reader gave the
  target as `$F` with no path, judged by its file name alone, and the command's own text, which
  names the file, was read only for a write the words do not name at all. Now:
  - mod-kit's write reader reads a variable the command set before the write (`F=path`, `export
    F=path`, `declare -x F=path`, one built from another it set) as its value, a `cd` between them
    followed, so the question names the real file. Where it cannot be sure it leaves the variable as
    written: a value from a command's output, one a loop or `read` sets, one given two different
    values (the reader cannot tell a `;` from an `&&`), and every value once an `eval` or `source`
    may have changed it.
  - A target the words still cannot name (a variable, a command's output such as `"$(ls ...)"`, a
    pattern), and one the reader followed through a variable to a file that is no lasting memory, is
    judged like a write the words do not name: asked about when the command mentions lasting memory
    anywhere, the assignment `F=<path>` included, and the question shows the file it mentions.
  - **Chosen: when the command mentions no lasting memory anywhere, the write goes through.** Asking
    is the harmless side for one save, but this question would name no file, since there is none to
    name, and would come on Claude's routine writes (`>> "$LOG"`, `> "$tmp"`, `tee "$out"`) many
    times a session; a question that comes that often and names nothing gets answered For good
    without being read (L36), which costs the real save its question. The gap it leaves is narrow:
    each Bash call starts a fresh shell (a variable exported in one call read as unset in the next,
    measured 2026-10-05), so a path to memory reaches a command only through a word in it, and every
    word is now read. What stays outside is a path the command takes from a file or the environment
    without ever spelling it (`F=$(cat where.txt)`), which no reading of its words can see.
  - A path spelled out, or under home by `$HOME`, is judged by that path alone, so a backup of
    `CLAUDE.md` (`cat ~/.claude/CLAUDE.md > notes.txt`) is still no save. The other way round is
    the known over reach: `cat ~/.claude/CLAUDE.md > "$OUT"` is asked about, showing the file it
    reads, which is the harmless side.
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
  the loops whose calls raise `tool.call`, carrying an id no agent list names. Since #777 its saves
  are refused, never asked, and the main session is told what it would have saved (above).
- The band look (mod-kit's `$.modkit.question`) had no other caller, so it was removed too (#796).

## Picker manners (#615), built 2026-10-04

**Claude Code's own question dialog asks every question, for good** (decided with Dan on
2026-10-05, in a picker, after the findings on #744; ask before saving's standing rule question
followed in #777). The band question picker manners was built
with is removed rather than kept switched off (L29), and with it what only the band made possible:
typing a message in the prompt to withdraw a question, numbered prose answers, and counting a pass
over a question, with the refusal of a question talked past twice that was built on that count.

Why it went, as measured on #744. In the live checks every question was asked twice: in the band,
then, after about 10 seconds, by Claude Code's own dialog. The `tool.call` hook waited for Dan's
press through the mod's own `$` noun, `$.pickers.wait`, and Claude Code cuts a call to a plugin's
noun off at 10 s: a probe plugin's noun, in a headless 2.1.289 session, was rejected at 10,003 ms
with "did not answer within 10000ms". The hook's `try`/`finally` had no `catch`, so the rejected
wait cleared the band and threw; a hook that throws is skipped, the rest of the chain ran, and
Claude Code's own dialog asked. `claude plugin test` does not apply that limit to a plugin's noun,
which is why the build time check (a press after 11 seconds) passed in the test kit. Standing rule 4
above, and `tools/check-mod-noun-waits.sh`, hold every mod to it now. Ways to bring the band back
without the noun were set out on #744 (the most promising raced `next(e)` against the band, and
needed an interactive check first); Dan chose to stay with the dialog.

What picker manners does:

- One question per call (CLAUDE.md) is enforced: a call with more, or with none, is refused, by
  name, to Claude.
- Next issue offers are known by `metadata.source: "next-issue"`, which the `/next-issue` skill
  passes. "no next issue" or "just give me the list", typed at the Mac or sent from Dan's phone
  through Remote Control, turns them off for the session, and says so once in a dim line: "Next
  issue pickers are off for this session; /pickers on brings them back." While they are off,
  Claude's system prompt says so too, so an offer made from CLAUDE.md's issue loop rule, which
  carries no tag, is a plain list as well (spec point 4: this overrides the loop rule for that
  session only, #703). `/pickers on` brings them back.
- Everything else is Claude Code's own dialog: the prompt is not free while a question is open,
  text typed there is an answer rather than a message, and numbered prose answers nothing.

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
| Switch failed | The lead turns red (a logout that did not happen is genuinely wrong): "claude.ai didn't confirm the sign out. Nothing else was changed.", with `[ Try again ]` and `[ Dismiss ]`. It claims only what was checked: that the page did not confirm. Since #736 this sentence is kept for that one case, a signed out check that ran and did not print "signed out"; the other ways Switch stops say what was found instead (below, open for Dan) | wording |
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
  2026-10-05). The transcript then says once that the question is waiting, with Claude Code's own
  reason, and that `/accounts rename` answers it now, since a pane Dan asks for opens at any width.
- When the triggering limit is both (95% 5 hour and 90% weekly at once), an account must have more
  room on both. "Most weekly room" ties are broken by the most 5 hour room, then the newest reading.
- Nicknames are shared through the claude-sync payload, in `mods/account-room-nicknames.json`: the
  mods tree is mirrored, and a file beside the mod folders (not in one) is not watched for hot
  reload and is named by no mod list. The repository is public, so the file is keyed by a hash of
  the account and org ids and holds no email; the nickname itself is published.
- Two Macs can answer the nickname question for one account before a sync (found in the live check
  on 2026-10-05, #747: one skipped, the other named it, and the sync applied the skip and set the
  name aside as a `.conflict-<Mac>` copy). The file's version 2 gives every entry the time it was
  recorded, `{"name": "Work", "at": 1759671234567}`, one account per line in key order, and copies
  are merged entry by entry: a name beats a skip whatever their times, and of two names the later
  stands (an entry the first build wrote, with no time, counts as older; an exact tie goes to the
  greater name, so both Macs settle alike). **A skip recorded after a name means nothing**: a skip
  only records that the question was answered, so it never takes a name away, whichever Mac
  recorded it or when; the way to change a name is `/accounts rename`, and there is no way to
  clear one back to the email and org. Recording an answer merges rather than replaces, and a
  rename is stamped later than the name it replaces even when the other Mac's clock ran ahead.
  Version 1 files still read as written and are rewritten, as version 2, only when the nicknames in
  them change. At each session start, and on every write, any copy the sync set aside beside the
  file is merged back; once the file reads back holding the merge, the copy moves into this Mac's
  `~/.claude/state/account-room/` (kept, never deleted) and the transcript says so once. A copy
  that cannot be read is named and left where it is. The sync itself is not taught to merge this
  file (#747 asked whether it should): it stays blind to what a payload file means, and this mod is
  the one reader that knows the rule. The status line reads both versions.
- Readings move between the Macs through a private GitHub repository (#750, decided with Dan on
  2026-10-05 after the live check found iCloud Drive's upload backlog leaving figures late however
  rarely a file was written; not a gist, which anyone with its link can read). It is named by the
  `readingsRepo` setting, `danwright32/account-room-readings` by default, and each Mac writes only
  `readings/<LocalHostName>.json`, in the same shape the iCloud file had. iCloud Drive is no longer
  written or read. Writes go through `gh api`'s contents PUT over the sha the file was read at, so a
  stale write is refused rather than overwriting; a refused write reads the file again and merges,
  up to three times, never forcing. The file is rewritten only when a figure moved as the card shows
  it (the whole percent left, or a reset time), an account is new or changed, or its newest reading
  is more than 10 minutes old, so the same figures measured again cost no GitHub call. The whole
  percent, rather than the tenth the engine reports, keeps writes near one per point of use: a 5
  hour window used from empty to full is about a hundred writes per Mac on that account, against a
  thousand at the tenth, plus at most six an hour from the 10 minute rule, which also bounds how
  stale the tenth can be. Each write is a commit in the repository. The other Macs' files are read
  only while the card is up, and a good read is kept for a minute; a read with anything GitHub
  could not give is not kept, so the card stops saying so at the first read after it is fixed. The
  repository is read from the setting each time the mod loads, never from the session's stored
  state. gh must be logged in, on each Mac, to an account that can see the repository.
- A rate limit measurement hands its reading work (saving it, reading the Macs' figures, drawing the
  card) to a timer and goes on at once, so a slow GitHub or a held lock never holds up the mods
  beneath (#736). Readings writes take turns on their own queue, and the other Macs are read before
  a redraw joins the queue the progress ticks use, so a slow GitHub never stops Switch's elapsed
  seconds. Two measurements arriving together take turns updating the live reading, so neither
  drops the other's window.

Not settled by any round, built so the spec holds, and each an open question for Dan:

- **Readings GitHub could not give.** The spec asks the card to say another Mac's readings are
  unavailable; no round drew it. Each is a plain line at the foot of the card, in gh's own words:
  "Dans-MacBook-Pro's readings are unavailable: not readable JSON (...)" for one Mac's file; "The
  other Macs' readings are unavailable: gh is not logged in to GitHub (gh auth login)" when the
  readings folder could not be listed at all (likewise "gh api failed: error connecting to
  api.github.com ...", "gh could not be run: ...", or "danwright32/account-room-readings was not
  found, or gh's account dwright-pennie cannot see it"); and "Daniels-MacBook-Pro-2's readings could
  not be saved to GitHub: ..." when this Mac's own write failed, until one lands. The save failure
  is also said once in the transcript.
- **Why Switch stopped** (#736). Only the not confirmed sentence came from a round; the others say
  what was measured instead of claiming a page check that never ran, each red with `[ Try again ]`
  and `[ Dismiss ]`: "No sign out was attempted: no browser logout route is set up. Nothing was
  changed." (no `logoutCommand` and `signedOutCheck` set); "The browser logout command failed.
  Nothing else was changed." (it exited non zero, could not start, or ran past 60 seconds); "The
  signed out check could not be run. Nothing else was changed." (the check could not start or ran
  past 60 seconds); "The signed out check could not read the browser, so whether it signed out is
  unknown. Nothing else was changed." (the check ran and exited 2, its "could not tell", as
  `bin/chrome-signed-out.sh` does when Chrome's last used profile or its cookies cannot be read, so
  no answer was read, #773); "A reload cut Switch off before the sign out was confirmed. Nothing else was
  changed." (the mod reloaded mid sign out, so nothing checked the page afterwards). The toast
  carries the detail, as before.
- **A nickname typed as an email address** is refused (#758): the nicknames file is in the public
  claude-config repository, so a name holding something shaped like `name@domain.tld` would publish
  it. The dialog stays open and a toast says why: "The nickname could not be saved: it looks like an
  email address, and the nicknames file is published in a public repository. Use a name instead."
- **The nickname dialog on the mobile app**, which draws no text field yet, shows the question and
  "Type the name in the terminal or the desktop app." with Skip alone (#758).
- **/accounts rename with a name, while some Macs could not be read** (#758): no match is not "No
  account is called ...". It says which read failed: "No account that could be read is called
  "work". The other Macs' accounts could not be listed: gh api failed: ..." (or "Dans-MacBook-Pro's
  accounts could not be read: ..." for one Mac's file).
- **The card's first appearance** never waits on this Mac's write to GitHub (#758): the write runs on
  its own queue beside the redraw, and the card is drawn again when it lands, so a save that failed
  shows then. Reading every Mac's file still comes first, since the card is drawn from it.
- **The waiting question's line** falls back on "Claude Code has not placed it" when Claude Code
  gives no reason, names an account with no email as "the Acme account" (or "this account" with no
  org either), and is said once per account.
- **A sign in that does not finish** (`claude auth login` exits non zero or times out after 10
  minutes): a toast, "Switch did not finish: Login cancelled", and the card comes back. On success:
  a toast, "Switched to Work.", and the card is dismissed for the session. A Switch stopped at the
  sign out also toasts the reason ("Switch stopped: no browser logout route is set up"), so Try
  again is not the only way to find out why (L148).
- **The browser sign out route was proven on 2026-10-05** (#659), on Google Chrome on
  Daniels-MacBook-Pro-2. Since #808 that Chrome route runs on Dans-MacBook-Pro only, chosen by
  `bin/browser.sh` (below); Daniels-MacBook-Pro-2 signs out through Safari.
  `logoutCommand` runs `bin/chrome-logout.sh`, which loads `https://claude.ai/logout` in Chrome's
  last used profile (read from Chrome's `Local State`), because that is the profile `claude auth
  login` opens its sign in page in (Dan's pick over a fixed profile or every signed in profile).
  `signedOutCheck` runs `bin/chrome-signed-out.sh`, which prints exactly "signed out" once that
  profile's cookie file holds no claude.ai `sessionKey` cookie. It reads a copy of the file, names
  only, never values (Dan's pick over reading the tab's address, which shows where the page landed
  rather than that the session is gone, and over turning on Chrome's JavaScript from Apple Events,
  which would let any local script act in every signed in page). The run: with Profile 3 signed in,
  the check first said "still signed in to claude.ai in profile Profile 3" (exit 1); the logout
  exited 0 at once; the check printed "signed out" (exit 0) 31 seconds after the logout, at 2:31 PM
  ET; and Dan confirmed the tab showed the claude.ai login page. Those 31 seconds are Chrome writing
  cookie changes to disk about every 30 seconds, so the check looks once a second for up to 50
  tries, and the mod now allows it 60 seconds rather than 30. Chrome comes to the front when the
  logout page opens, which is acceptable here since the sign in page follows straight after.
- **The browser is chosen per Mac** (#808, Dan 2026-10-05: "the sign out prompt ... open in safari
  on this mac and chrome on my other mac"). The defaults run `bin/browser.sh logout` and
  `bin/browser.sh signed-out`, which read the Mac's LocalHostName and run Safari's pair on
  Daniels-MacBook-Pro-2 and Chrome's pair on Dans-MacBook-Pro (proven on Daniels-MacBook-Pro-2, not
  yet run on Dans-MacBook-Pro, #786); a Mac named in neither is
  refused by name rather than given a browser (L75). Keyed in the script, not a synced setting,
  because the payload is shared and a per Mac default cannot live in one manifest.
  `bin/safari-logout.sh` opens `https://claude.ai/logout` in Safari. `bin/safari-signed-out.sh`
  prints "signed out" once Safari's `Cookies.binarycookies` (in Safari's container) holds no
  unexpired claude.ai `sessionKey`, read by `bin/safari-cookies.py`, which prints only a count. It
  was measured before it was built (L82): on Daniels-MacBook-Pro-2 on 2026-10-05 a Claude Code
  session reads that store with no Full Disk Access prompt (532,410 bytes, 1,930 cookies, one live
  claude.ai session). A store the system refuses says so and names Full Disk Access; one that does
  not parse says that; either is exit 2 with the reason, so the card says the check could not read
  the browser rather than claiming an answer (#773). Not yet proven: that Safari's logout page
  removes the cookie and how long Safari takes to write the removal to the store. That proof needs
  a real Switch with Dan present, as #659 had for Chrome, and stays open on #808.
- **Dismiss** lasts for the rest of the session, as the spec says; it does not come back if the
  account recovers and runs low again in the same session.
- **/accounts rename** with no name renames this session's account; with a name (a nickname or an
  email) it renames that one.

## Not design decisions

The rounds were HTML pages standing in for a terminal. The browser window, the font and the exact
greys are idioms of that rendering, not decisions: the mod draws with the terminal's own text and
dim colours.
