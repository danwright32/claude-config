---
name: design-rounds
description: Use when a product or feature is about to get its look settled, when the first screen is about to be designed or built, when an existing screen is being redesigned, or when a choice between visual directions (layout, type, density, chrome, colour) has to be made with Dan. Also use when a settled design decision needs to survive past the session that made it.
---

# Design rounds

## Overview

Dan does not choose a design from prose. Asked to pick between directions described in
words he said: **"I think I need to see renderings of these to get an idea. I'm not
really sure."** A design round is therefore a rendering he can look at and switch
between, never a list of options he is asked to imagine.

**The core rule: one variable per round, everything else held byte identical.** Eleven
rounds settled Ovation's main screen on 2026-09-06, one decision at a time. Rounds that
moved several things at once produced "still not loving any of them" with no usable
signal. Rounds that moved one produced a precise answer every time.

## When to run this

After the PRD is agreed and the screen's content is known, and before the first screen
is built in the real framework. Not earlier: there is nothing to draw until the document
says what is on the screen. Not later: once the screen exists in the real framework
every round costs a rebuild rather than an edit, and the question quietly changes from
what this should look like to what is cheap to change now.

## The seven rules

1. **Render, do not describe.** Build the options and show them. Ask afterwards.
2. **One variable per round.** Everything else identical, produced by one builder, so
   the difference on screen is the only difference there is.
3. **One window, full context, in a switcher.** Draw the whole screen including its
   surrounding chrome, and let him swap options in place. His words: "render the whole
   page. I need the context", then "would it be possible for you to show it to me
   through a switch". A difference you scroll between is remembered; a difference that
   swaps under a frame that stays put is seen.
4. **Colour last.** Settle structure, type and density first. "I think I need to nail
   down the design before the color. let's just do black and work on the rest of it
   before the color."
5. **Every objection is a candidate rule.** Check it against the product, and where it
   holds, promote it into a standing rule with its reason rather than applying it once.
   "I don't think I like red because that feels like something is wrong" became a rule
   that red is reserved for the one place something is genuinely wrong.
6. **Count the facts before showing any chrome.** No number may appear twice. A sidebar
   was rejected on sight for stating the same count in two places.
7. **Ask with a picker, never in prose.** EVERY question this skill puts to Dan is an
   AskUserQuestion picker: the choice between rendered options, and equally whether a
   round settled it or needs another, whether an objection should become a standing
   rule, what the next round's one variable should be, and whether the design is done.
   He answers by selecting, so a question asked in a paragraph hands him the work back
   as typing.

## Asking for the choice

Every round closes the same way: build the switcher, tell him it is open, then put up
the picker. Not a sentence inviting a reply, not a numbered list in the message.

**The options are not retyped.** `make-switcher.py` writes them beside the page, as
`<out>.picker.json`, and names that file in its output. Read it and use what is in it:
one option per tab, in the switcher's order, labelled as the tab is and described by
what the readout says that option is testing. Typing them out again is a second copy of
two facts already on screen, and it drifts, so the picker ends up naming an option
differently from the tab or giving a different reason for it.

- **One question per call.** Multi question calls have lost answers mid selection. So a
  round that has both a choice to make and a follow up to ask puts up the choice, waits,
  then puts up the follow up.
- The file carries no none of these option, deliberately. The picker's own free text
  answer is the escape hatch, and offering a refusal invites one when the round's job is
  a comparison.
- The one thing it does not give you is the picker's short header chip, so write that
  yourself.

The same applies to every OTHER question the round raises, which is where prose creeps
back in. Carry on with another round or settle here, promote this objection to a standing
rule or apply it once, which variable the next round moves: each of those is a picker with
the concrete candidates as its options, never a question at the end of a paragraph.

## The tool

`make-switcher.py` builds the switcher page so it is not rewritten, and quietly
weakened, once per round. That is not hypothetical: on 2026-09-07 a hand written
switcher drew a keyboard badge on every tab and had no key handler at all, so it
offered three shortcuts that did nothing, while the round before it had working ones.

```bash
python3 ~/.claude/skills/design-rounds/make-switcher.py spec.json switcher.html
```

The spec names the round, the builder, and the options. Run the script with no
arguments for the exact shape, and see `example/` for a working one.

| It gives you | Why |
| --- | --- |
| Tabs, arrow keys, and a jump key per option | Comparing is the whole activity, so it has to be one keystroke |
| A readout naming each option and what it is testing | An option with no stated reason cannot be judged, so the tool refuses one |
| One `buildScreen(variant)` for every option | Makes "everything else identical" structural rather than a promise |
| A page needing nothing from the network | It still renders in a year, on a plane, from a git checkout |
| A refusal instead of a page, on any fault | A switcher with a dead frame or an unwired key looks finished |
| `<out>.picker.json`, the closing picker's options | The tab and the picker entry are the same two facts, so they are emitted once rather than retyped |

`bash test-make-switcher.sh` runs its checks, and `run-all-tests.sh` finds that suite on its own. The refusals above each have a test that produces them, including the unwired key.

**The page's own chrome is namespaced `dr-`, and the screen keeps whatever width it
declares.** Both were failures, on 2026-09-08, in one round. The chrome styled a class it
called `frame` with a 1180px ceiling, and the round's builder happened to name its element
`frame` too; separately, the stage is a flexbox, so a screen wider than the stage was
shrunk to fit whatever it was called. Three options declaring 1100, 1440 and 1720 all drew
at the same size, under a readout naming three different widths, and nothing refused,
because the page was structurally perfect. A person spotted that the pictures matched.
So: every class the chrome styles now carries the `dr-` prefix, the round's heading has a
class rather than being a bare `h1` that reached into the screen, and `.dr-stage > *` is
`flex: none` so the stage scrolls rather than squeezing. A builder may use any class name
it likes except a `dr-` one. Two tests hold this, one asserting the namespace and one
measuring that a 1400px screen is 1400px on the page.

**Draw an option wider than the window inside an iframe, scaled, and say the scale on
screen.** A screen 1720px wide cannot be shown actual size in a 1330px window, and the
three ways of coping all lie: clamping it draws the wrong width, clipping it hides the
part being judged, and scrolling it defeats the comparison. Scale it, and caption it with
its true width and the percentage, so a scaled option can never be mistaken for a clamped
one. It has to be an iframe rather than a scaled div, because a media query inside a
scaled div answers to the outer window and reports the wrong width, which is precisely the
variable a round about width is testing.

## The deliverable

The settled design is ONE self contained file committed in the repo: no build step, no
hosted URL, fonts and assets embedded so it renders identically with no network.

1. Its decision record lives inside it, each decision with its reason.
2. **Strip the switcher out of it.** The committed file is the design, not the chooser it
   came from. The options file the tool writes beside the page goes with the chooser:
   it is a working file for choosing with, never kept alongside the settled design. Ovation's was committed with all six candidates still in it and a README
   calling it "the agreed design", which was false: anyone opening it got a picker.
3. Name the parts that are idioms of the rendering medium rather than design decisions,
   so they get translated instead of copied. Ovation's README names the three web idioms
   in an HTML file standing in for a SwiftUI window.
4. Every decision with code consequences goes back into the PRD as numbered requirements,
   so the PRD stays the single alignment document.

## Common mistakes

1. Describing the options in a message and asking him to choose.
2. Moving two things in one round, then reading "I don't love any of them" as taste
   rather than as the round being unreadable.
3. Stacking the options down one page instead of swapping them under one frame.
4. Opening with colour.
5. Rewriting the switcher by hand each round, which is how the working keyboard
   shortcuts were lost between one round and the next.
6. Committing the chooser as though it were the design.
7. Building the switcher and then asking for the pick in prose, which turns a one
   keystroke comparison back into a message he has to write.
8. Putting the option choice in a picker and then asking everything else that round in
   prose, which is the same mistake wearing the rule as cover.
9. Retyping the picker's options instead of reading the ones the tool wrote, which is how
   the tab and the picker come to disagree about what an option is called.
