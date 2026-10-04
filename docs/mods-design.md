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

A session silent for five minutes counts as closed; its latest request is read from its transcript,
never copied into the registry.

## Not design decisions

The rounds were HTML pages standing in for a terminal. The browser window, the font and the exact
greys are idioms of that rendering, not decisions: the mod draws with the terminal's own text and
dim colours.
