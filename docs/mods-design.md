# Mods: the settled design

The design decisions for Claude Code mods (milestone "Claude Code mods"), each settled with Dan
in a rendered design round or a one question picker, with its reason. A new mod starts from these
and settles its own surfaces in rounds of its own before it is built.

## Standing rules (every mod)

1. **Colour only for something Dan has to act on.** A notice Claude handles by itself is neutral
   grey. Settled 2026-10-03 in the guard rounds: asked to colour the blocked card, Dan asked
   whether a block needs anything from him, and on hearing it is a notice Claude works around, he
   chose grey and made it the rule for every mod.
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
| Colour | The status line is all grey; the needs-a-look items in the band are amber; the Compact button is Claude Code's own bold white (colour round, design rounds). A deliberate exception to standing rule 1: a running PR, a running job and a job kept on purpose are amber though nothing needs doing yet, because Dan chose to keep work in flight in view (status round 2, colour round, kept job round). |
| Where it is drawn | The always-shown facts stay on the classic status line script below the prompt, fed by the mod. The amber items are drawn by the mod in the band above the prompt, only while something needs a look (picker, after the probe below). |
| The band | Two rows when both show: the amber line, then the Compact row carrying the context figure, so context shows once. Either row alone otherwise (design round). |
| Order of the amber line | Most urgent first: a failing or running PR, a running job, unpushed commits, so a narrow window cuts off what can wait longest (design round) |
| Compact button | Claude Code's default button, `[ Compact ]` in bold white, pressed by clicking or ctrl+x tab then Enter (design round, styles copied from a live probe) |

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

## Not design decisions

The rounds were HTML pages standing in for a terminal. The browser window, the font and the exact
greys are idioms of that rendering, not decisions: the mod draws with the terminal's own text and
dim colours.
