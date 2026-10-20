---
name: design-rounds
description: Use when a product or feature is about to get its look settled, when the first screen is about to be designed or built, when an existing screen is being redesigned, or when a choice between visual directions (layout, type, density, chrome, colour) has to be made with Dan. Also use when a settled design decision needs to survive past the session that made it.
---
<!-- design-round-guard contract: 2 -->

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

**A round's files go in this session's scratchpad**, under `<issue number>/round<N>/`: the
builder, the stylesheet, the spec, the switcher and its picker file. They are working files for
choosing with, never screens of the product, so the design round guard never holds a file there,
and needs no issue or branch for it. Name them by their full path, after a cd there, or joined onto
a folder the command names by its full path. The same files written into the project's checkout
are held like any screen edit until Dan answers Settled (claude-config#1191: a round for Slate's
#3718 was refused twice for its own files, and the only way on looked like a skip).

| It gives you | Why |
| --- | --- |
| Tabs, arrow keys, and a jump key per option | Comparing is the whole activity, so it has to be one keystroke |
| A readout naming each option and what it is testing | An option with no stated reason cannot be judged, so the tool refuses one |
| One `buildScreen(variant)` for every option | Makes "everything else identical" structural rather than a promise |
| A page needing nothing from the network | It still renders in a year, on a plane, from a git checkout |
| A refusal instead of a page, on any fault | A switcher with a dead frame or an unwired key looks finished |
| `<out>.picker.json`, the closing picker's options | The tab and the picker entry are the same two facts, so they are emitted once rather than retyped |
| The same scroll position on every option | A round about anything below the fold is compared in place, without scrolling back down after each switch |
| `screenShown(variant, element)`, called after each switch when the builder defines it | The builder always knows which option is on the stage |

**A builder that changes its screen after load (a click that opens an editor, switches a
partner, redraws a list) keeps no single global redraw function and reads no global set in
`buildScreen` when a click lands.** Every option is built once, at load, so whatever global
`buildScreen` last set belongs to the LAST option built: a click in option 1 then redraws
option 4, off the stage, and the screen showing does not move (claude-config#1206, from
Dan's Bidspoke partners rounds). Define `screenShown(variant, element)` instead, which the
page calls with the option on the stage and its element after every switch, the first one
included, and redraw from those. The page also keeps how far each scrolling region was
scrolled across a switch, matched by where each sits in the screen, so no builder needs its own scroll listener.

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

## Rounds about a Claude Code mod: the shared terminal

Every mod round on 2026-10-04 drew the same fake terminal by hand (title bar, transcript,
the band above the prompt, the prompt box, the grey status line), each with its own copy
of the helpers and stylesheet. Copies drift, and two rounds whose terminals differ have a
second variable nobody chose. So the terminal ships with the tool, dark only because Dan
never uses a light terminal. Ask for it in the spec and draw only what varies:

```json
{ "builder": "builder.js", "screen": "terminal", "variants": [ ... ] }
```

```js
function buildScreen(variant) {
  var T = Terminal;
  return T.screen({
    title: "claude-config",
    transcript: [T.user("keep going on the batch"), "Merging #653 once its checks pass."],
    band: [T.card(variant.card, [
      [T.amber("Work has more room"), "  ", T.button("Switch"), " ", T.button("Dismiss")],
      [T.dim("Use in claude.ai is not counted.")]
    ])]
  });
}
```

| Call | Draws |
| --- | --- |
| `T.screen({...})` | The window. Options: `title`, `transcript`, `band`, `prompt` (typed text, or `false` for none), `footer`, `status` (left out, the status line the status bar mod draws, as `docs/mods-design.md` records it; else text segments, divided by a bar, all in the line's one grey, since a coloured segment throws; or `false`), `width` (820), `height` (330, a minimum, so a tall band grows the window rather than being cut off), `fontSize` (13) |
| A row | Text, a list of pieces, or anything below. `transcript`, `band` and a card each take a list of rows |
| `T.amber` `T.grey` `T.red` `T.violet` `T.bold` `T.dim` `T.white` | A run of text in that style; `T.run(text, "amber", "bold")` combines them |
| `T.button("Switch")` | `[ Switch ]`, bold white; `{disabled: true}` greys it |
| `T.user("words")` | A line of what the person typed, with its `>` |
| `T.card("box" or "rule" or "none", rows, {edge: "amber"})` | Rows boxed, ruled down the left edge, or grouped plain |
| `T.divider("violet")` | A rule across the band |
| `T.line(pieces, "dim")` | One line, optionally styled as a whole |

A misspelt style, card, edge or option throws, and the page's own strip quotes it. The
library owns one name, `Terminal`, and classes prefixed `term-`, so a builder's own `el`
and `.line` cannot collide with it; a round whose variable IS part of the terminal's look
overrides a `term-` rule in its own stylesheet, which comes after. The tool refuses a
screen it does not ship, a builder declaring `Terminal` itself, and a builder using
`Terminal` from a spec that did not ask for it. `example-terminal/` is a working round.

## When there is nothing to render

Before round one, name the round's one variable. If there is none, because the change
alters nothing on screen (a prop's value, which data a page hands a component, logic in a
screen file), there is nothing to draw and no round to run. On 2026-10-09 the only route
here was a switcher, so a one prop data change on a page ended in "Is this design
settled?" with nothing in front of Dan (claude-config#1010). So: say in one sentence that
nothing on screen changes, build no switcher, and close one of two ways.

- **A refused edit is waiting** (the design round guard named its id): ask the guard's own
  question about it, one AskUserQuestion with
  `"metadata": { "source": "design-round-guard:<the id the refusal named>", "onScreen": "Nothing on screen changes: <what the edit does instead, in plain words>", "contract": 2 }`
  and the question "Skip design rounds for this issue?". The guard words it, and its answer
  **Not a look change** lets that one edit through, recorded as his word, while every
  other look changing edit stays held. Then send the refused call again, unchanged.
- **Nothing is waiting**: there is nothing to unblock, so ask nothing and carry on.

## What Dan reads first: what changes on screen

Every time the guard's skip question is asked, its metadata carries `"onScreen"`: one plain
sentence saying what Dan will see change, which control or area on which screen ("The Save
button on the invoice screen turns from grey to blue"), or that nothing visible changes and what
the edit does instead. The question leads with it, then asks "Skip design rounds for this
issue?", and names the issue and the file last. Dan, 2026-10-13, shown a question built from a
file path: "I don't know what the file name means or what this change will do"
(claude-config#1138). So the guard refuses to ask without the sentence, or with one that names a
file, and nothing is asked until it is given. A subagent that was refused reports the sentence
with the line the refusal gave it, and the main session asks with it.

A Claude Code mod's own hook file (`mods/<mod>/hooks/<file>.tsx`) counts as a screen file, because
it draws Claude Code's panels, but an edit to one that touches none of its JSX and names none of
the words a mod draws with (a colour, a frame, a border, a row) is logic and goes through unasked.
So does an Edit, MultiEdit or Write to any mod hook file, `.ts` included, that changes only its
comments (claude-config#1341). A shell command writing one that draws is still held whole, since
what it leaves cannot be read before it runs: make a comment only change there with the Edit tool.

## The last step: is this design settled?

Every run that rendered a round ends with one more picker, after the last round and before the
deliverable is written: the question **"Is this design settled?"**. Dan's answer to it is
what lets the build start. The design round guard mod holds every edit that changes how a
screen looks (style files, screen and component files, SwiftUI views) until Dan has
answered Settled for the issue, or has said to skip design rounds for it (claude-config#978,
his words: "claude should never design something without my input").

Ask it exactly like this, one question in one AskUserQuestion call:

```json
{
  "questions": [{ "question": "Is this design settled?", "header": "Design round", "options": [{ "label": "Settled", "description": "x" }, { "label": "Not yet", "description": "x" }], "multiSelect": false }],
  "metadata": { "source": "design-settled", "path": "<a folder or file in the project's checkout>", "contract": 2 }
}
```

- The guard words the question and its two answers itself (Settled, Not yet), naming the
  issue it records for, so what you put there is replaced; the metadata is what matters.
- `"contract": 2` is the version of these steps the guard must know. A session keeps the
  guard it started with while these steps are read fresh, so when the guard answers that it
  predates the steps you read, nothing was asked or recorded: tell Dan, and go on in a new
  session. Asking again in this one gets the same answer (claude-config#1057).
- `"path"`, an absolute path (a relative one is refused, by name), names the project the
  design is for, and the settlement is recorded for the issue its checkout's branch names
  (or the branch, when it names none). Never the folder this session runs in, which can be
  another project altogether (claude-config#1010: a Settled for a trypennie edit landed on
  a Slate issue).
- When the guard refused an edit and this round is for it, give
  `"call": "<the id the refusal named>"` instead of `"path"`: the settlement is then for
  exactly what that edit waits on, the issue the refusal named, as Skip them would be, so
  the edit goes through when you send it again, with whatever new id it gets. With neither,
  it is for the refused edits waiting in this session when they all wait on the same
  answer, and refused when none is waiting.
- When the branch names no issue, say on the default branch, add the number of the issue
  this design is for, in that project, to the metadata as a number,
  `"issue": <the issue number>`, and Dan reads that issue in the question. Beside `"call"`
  it is recorded as well as what the refused edit waits on, never instead of it
  (claude-config#1046: recorded instead, the edit sent again was refused again).
- Only Dan's own choice of Settled records it. Never fill in `answers`, never ask from a
  subagent, and never write anything else to record it: the guard refuses all three, and a
  write to its record. Not yet records nothing: carry on. An answer he types instead of
  choosing counts as Not yet (claude-config#1336): nothing is settled, and what he typed is
  the feedback for the next round. Act on it, answer anything it asks, and ask whether the
  design is settled only once he has seen that round, never straight away.
- Then write the deliverable below. Look changing edits on that issue now go through.

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
5. **It carries a decision map, and the map is checked, not trusted** (claude-config#1290). On
   2026-10-17 a redesign settled 65 decisions and its PRD got 16 requirements; every
   requirement shipped and closed, and about 35 decisions nobody owned (the layout, most
   controls, whole sections of three tabs, four page states) shipped as the old screen while
   the milestone read as nearly done. So the settled file holds one block listing every
   decision in its record, each with the PRD requirement that owns it, or `noCode` and the
   reason it needs no code:

   ```html
   <script type="application/json" id="decision-map">
   {"decisions": [
     {"id": "D1", "decision": "The invoice list is one column", "requirement": "6.4"},
     {"id": "D2", "decision": "The heading reads Invoices", "noCode": "Copy only, already in the PRD"}
   ]}
   </script>
   ```

   Run `python3 ~/.claude/skills/design-rounds/check-decision-map.py <the settled file>`
   before calling the deliverable done. It refuses (exit 1) a decision with neither, or both,
   by name, and a map it cannot read is exit 2, never a pass. Who reads the map next: the
   planner. `/plan-council`, `/plan-lite` and `/milestone` put the settled file's path in
   their plan as `"design"`, and `create-milestone.sh` runs the same check with the plan,
   filing nothing while a decision has no requirement or a requirement has no issue naming it
   as `Requirement <number>`. It then adds the milestone's last issue, "Match the settled
   design", which closes only when the build scores 100% on both halves (below), which finds
   drift on the decisions that did have owners.

## Scoring the build against the settled design

Dan, 2026-10-19: "you'd know you're done not when all issues are completed but instead when the
match up score is equal to each other so the designs are exactly alike" (claude-config#1364). The
build is scored against the settled file on two halves, and it matches only when BOTH are 100%:

- **Decisions.** Each decision in the map is checked by a written, automated check run against the
  built page, and is met only when it passes on every frame it is checked on. The map is what is
  counted, never the checks, so a decision with no check reads `UNCHECKED` and is not met. A
  decision too visual for a check says `"verify": "picture"` in the map and rests on the picture
  half; one another test proves says `"verify": "elsewhere"` and `"provenBy"`. Both are listed on
  every score and left out of the count.
- **Pictures.** Every frame, drawn at its own width, beside the build drawing the same committed
  fixture data. A pixel matches when no channel differs by more than 8 out of 255 (Slate's trial,
  #3934: 8 absorbs rounding, while 24 let a blank white page match a beige one at 97%). Area only
  one side has counts as different, and a frame is 100% only when every pixel matches.

The settled file therefore carries two more blocks beside the decision map: `design-frames`, every
frame with its id, title and width in pixels (and a height when the frame is a fixed size rather than
a full page), and, once Dan approves one, `design-exceptions`. An exception is how a deliberate
difference reaches 100% without a new round: it names one decision, one frame, or a region of one
frame, with Dan's own words, the date and where he said them, and the score skips it and lists it
every time. Nothing else excuses a difference.

A platform adapter draws both sides and leaves a capture (the pictures and the check results) in a
folder; the score reads it:

```bash
python3 ~/.claude/skills/design-rounds/score/design_score.py score <capture folder>
python3 ~/.claude/skills/design-rounds/score/design_score.py show <capture folder>/score.json
```

It prints both halves, every unmet or unchecked decision, every frame's percentage, and the
exceptions it skipped, and writes `score.json` (the one score format, the same for web and SwiftUI)
and a `<frame>-diff.png` per frame, differences in red. Exit 0 is matched, 1 not matched yet, and 2
no score: a capture or design it cannot read, a frame with no picture, a design picture not drawn at
its frame's width, a check that threw, a check the design itself fails (so the check is wrong, not
the build), or nothing left to measure. Unmeasured is never 100%. The capture's shape is at the top
of `design_score.py`. It reads PNGs with the standard library alone, so it runs the same on both Macs
and on CI: two 1280 by 2000 frames scored in about 7 seconds on 2026-10-19.

**Done is 100%, and a hook holds it.** Every pull request in a design milestone posts the current
score, on itself and on the milestone's "Match the settled design" issue:

```bash
python3 ~/.claude/skills/design-rounds/score/design_score.py post <capture folder>/score.json --repo <owner/name> --pr <number>
```

`design-score-gate.sh` refuses to close that issue, or the milestone, unless the newest score
posted on it for the code being closed on (the default branch's head, or the head of a pull request
whose closing keywords name it; a squash merge of the scored branch has the same tree and counts)
reads matched on both halves, was drawn with nothing uncommitted, and was measured against the
design file as committed there. It reads `gh issue close`, `delete` and `transfer`, a REST close of
the issue or the milestone, `gh pr merge` and `merge-when-ready.sh`; a GraphQL `closeIssue` is
refused, since `gh issue close` does the same readably. Anything it cannot read refuses, saying
what. There is no override: a difference Dan means to keep is a new round or an exception in his
words.

## Common mistakes

1. Describing the options in a message and asking him to choose.
2. Moving two things in one round, then reading "I don't love any of them" as taste
   rather than as the round being unreadable.
3. Stacking the options down one page instead of swapping them under one frame.
4. Opening with colour.
5. Rewriting the switcher by hand each round, which is how the working keyboard
   shortcuts were lost between one round and the next. The same goes for the terminal in
   a mod round: ask for `"screen": "terminal"` rather than drawing another copy.
6. Committing the chooser as though it were the design.
7. Building the switcher and then asking for the pick in prose, which turns a one
   keystroke comparison back into a message he has to write.
8. Putting the option choice in a picker and then asking everything else that round in
   prose, which is the same mistake wearing the rule as cover.
9. Retyping the picker's options instead of reading the ones the tool wrote, which is how
   the tab and the picker come to disagree about what an option is called.
10. Ending a round without the "Is this design settled?" picker, or asking it in prose: the design
   is then settled in conversation only, and the guard holds every screen edit after it.
