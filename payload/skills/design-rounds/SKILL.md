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

The spec names the round, the builder, the options, and the product's captured `chrome`
(below, "No stand ins"), with the round's `fixture` when it has one. Run the script with no
arguments for the exact shape, and see `example/` for a working one. A spec naming no
captured chrome is refused, writing nothing, unless it asks for the shared terminal screen or
names one of the three kinds of screen with no product page around it (below, "No stand ins").
Each option is then the captured page with the round drawn into its slot, in an iframe of
its own at the width it was captured at, every option kept in the stage so switching never
reloads one, and a key pressed inside an option still switches.

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
| Every option whole, on a stage as wide as the window, scaled with its true width and percentage said when the window is narrower | The part cut off or scrolled away is so often the part being judged (claude-config#1499) |
| A warning when two options draw the same picture, judged on each option's whole page, its root and stylesheets included | A round set on the page root, the theme or the spacing, differs outside the slot (claude-config#1512) |

**A builder that changes its screen after load (a click that opens an editor, switches a
partner, redraws a list) keeps no single global redraw function and reads no global set in
`buildScreen` when a click lands.** Every option is built once, at load, so whatever global
`buildScreen` last set belongs to the LAST option built: a click in option 1 then redraws
option 4, off the stage, and the screen showing does not move (claude-config#1206, from
Dan's Bidspoke partners rounds). Define `screenShown(variant, element)` instead, which the
page calls with the option on the stage and its element after every switch, the first one
included, and redraw from those. In a round drawn in captured chrome it runs inside the option's
own frame, with the element drawn in the slot, each time that option is shown, once its frame
has loaded (claude-config#1522); a throw is said on the page either way. The page also keeps how far each scrolling region was
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
`flex: none` so a screen is laid out at the width it declares rather than squeezed (one
wider than the stage is then scaled down whole, with its true width said, as below). A builder may use any class name
it likes except a `dr-` one. Two tests hold this, one asserting the namespace and one
measuring that a 1400px screen is 1400px on the page.

**Draw an option wider than the window inside an iframe, scaled, and say the scale on
screen.** A screen 1720px wide cannot be shown actual size in a 1330px window, and the
three ways of coping all lie: clamping it draws the wrong width, clipping it hides the
part being judged, and scrolling it defeats the comparison. Scale it, and caption it with
its true width and the percentage, so a scaled option can never be mistaken for a clamped
one. It has to be an iframe rather than a scaled div, because a media query inside a
scaled div answers to the outer window and reports the wrong width, which is precisely the
variable a round about width is testing. The switcher does this for every option: a round in
captured chrome is already an iframe at its captured width, the stage is the window's width, and
an option still wider is scaled down whole with the caption above the stage (claude-config#1499,
from PET #1876, whose 1280 options were cut off at the right in a 1900px window).

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

## No stand ins: draw inside the product's real chrome

Dan, 2026-10-19: "No stand ins." A round draws the product's real header, sidebar and controls
(selects, inputs, buttons as they ship), never a copy drawn by hand beside the part being decided,
so nothing in a round is masked and the settled design can be scored against the build pixel for
pixel. A hand drawn copy drifts from the product, and a design that differs from the product
outside the part being decided can never reach 100%.

So capture the chrome before round one, in the main session (a subagent never drives the browser):
open the product's page at the width the round is drawn at, signed in as the person the screen is
for, and run `capture-chrome.js` (beside this skill) with Playwright's `browser_evaluate`. It answers
with the page as one self contained document, every stylesheet, font and image inlined and every
script taken out, and names anything it could not inline in its first comment. Save it beside the
round as `chrome.html`. A native app's chrome is a screenshot of its real window, `chrome.png`. Name
it in the spec, with where it came from and where the round draws:

```json
"chrome": {"captured": "chrome.html", "from": "<the URL, who was signed in, the date>",
           "slot": "#main", "width": 1280}
```

(for a picture, `"slot": [x, y, width, height]` in its pixels). The round's builder then draws only
what goes in the slot, with the product's own classes and controls. A round about a Claude Code mod
asks for `"screen": "terminal"` instead, the terminal that ships with the tool.

**A round whose options belong to different pages is still one round** (claude-config#1536): a panel
in edit mode against a card in view mode, say. List every captured page in `"chromes"`, in place of
`"chrome"`, each with a `"name"`, and have each option name the one it is drawn in, as a settled
design's frames do (below):

```json
"chromes": [{"name": "edit", "captured": "edit.html", "from": "<URL, edit mode, date>", "slot": "#panel", "width": 1280},
            {"name": "view", "captured": "view.html", "from": "<URL, view mode, date>", "slot": "#card", "width": 1280}],
"variants": [{"key": "1", "name": "Espresso", "why": "...", "chrome": "edit"}, {"key": "2", "name": "Ink", "why": "...", "chrome": "view"}]
```

Each option is drawn in its own page, into that page's slot, at that page's width, and each page is
carried once however many options share it. It is read and refused by the same code as a settled
design's `"chromes"`, with the same refusals, and a round with one `"chrome"` writes exactly the page
it always did.

**A screen with no product page around it names its kind instead** (Dan, 2026-10-20, on #1393:
"allow named kinds"). Three kinds, and only these: an email, a document (a PDF, an invoice export),
and a new product whose page does not exist yet. The round names the kind in `"screen"`, where the
terminal is named, and the width it is drawn at:

```json
{ "builder": "builder.js", "screen": "email", "width": 600, "variants": [ ... ] }
```

`"screen"` takes `"email"`, `"document"` or `"new-product"`. Each option is then the round's drawing
alone, in a document of its own at that width with no margin, and the switcher says the kind in one
plain line ("An email, with no product page around it."). Every other screen is drawn in the captured
page. The tool refuses, writing nothing: any other kind, naming the three; a kind with no `"width"`;
a `"width"` without a kind (a captured page's width is its own); and a kind beside a captured chrome,
rather than letting either win, since each says the other is wrong. A screen that sits inside the
product is never a kind: capture its page.

## The deliverable

The settled design is ONE self contained file committed in the repo: no build step, no
hosted URL, fonts and assets embedded so it renders identically with no network. It is
WRITTEN by `make-settled.py` from the round's own builder, the captured chrome and the
committed fixture, never assembled by hand from the switcher:

```bash
python3 ~/.claude/skills/design-rounds/make-settled.py settled.json docs/design/<name>.html
```

`settled.json` names the chrome, builder, styles and fixture as the rounds did, then every frame
(`id`, `title`, `width`, an optional fixed `height`, and the `variant` its builder is handed), every
decision, and Dan's exceptions; `make-settled.py` run with no arguments prints the shape. Two optional
fields carry what a PRD opens with (claude-config#1401): `"intro"`, the design's opening paragraph
(who it is for, how many rounds settled it, who approved it), shown under its title; and
`"requirements"`, the PRD's numbered requirements as `[{"number": "6.4", "text": "the sentence"}]`,
each number written as text exactly as the PRD numbers it. Given, the requirements are listed on the
page, each with an anchor, every decision's owner is `Requirement 6.4` linked to that entry, so the
sentence is on the page once (Dan, 2026-10-20, claude-config#1429), and the decision map carries the
list, so a decision naming a number it does not hold is refused, naming the number, by
`make-settled.py` and by `check-decision-map.py` (`UNLISTED`). Left out, a decision's number is shown
alone, the PRD holds its sentence, and `make-settled.py` says which numbers it showed without one.
The page follows the reader's light or dark scheme, and a decision's reason is its own sentence ahead
of its owner (claude-config#1426), so a settled file written before then changes when regenerated,
though nothing the score or `check-decision-map.py` reads does. The fixture
is the data the frames are drawn from, committed in the app's repository, and the built page renders
the same file in a development only preview, so both sides of the score draw the same data. Each
decision is written so its check can be authored from it: what it is, why, its owner (`requirement`
or `noCode`), how it is verified (`"verify": "check"`, the default, with `"check"`, the one sentence
the check asserts, and `"frames"`, every frame it shows on; or `"picture"`; or `"elsewhere"` with
`"provenBy"`). The file gives `designFrameDocument(<id>)`, each frame's whole document, which the
score's web adapter draws as a page of its own. Each frame calls its builder's `screenShown` once, as it
loads, and a frame whose builder or `screenShown` throws is not the design: the page says so right above
that frame, in the builder's own words, and the score reads the same words from the file's
`designFrameTrouble` and calls that frame no score (claude-config#1539). Only Chrome can see a throw, so
such a design is still written, except a terminal one, whose frames are drawn before writing and which is
refused. A design with no product page around it names its
kind in `"screen"` in place of `"chrome"`, as its rounds did: each frame is drawn alone at its own
width, the file says the kind where a design in chrome names its capture, and its `design-frames`
block carries `"kind"`, which the score records in its score file and says in its report, so a 100%
on an email is never read as a build drawn inside the product. A Claude Code mod's design names
`"screen": "terminal"`, as its rounds did: each frame is the shared terminal alone, drawn as the
switcher draws it, at the size its builder gives the window (`Terminal.screen`'s `width`, 820 when it
names none). Each frame is scored at the width it declares, so before writing anything make-settled.py
draws every frame in Chrome and measures its window, and refuses a frame whose declared width is not
the width its window draws, naming the frame, both widths and the fix (claude-config#1422). It is
measured rather than read from the builder, because a builder usually computes it (`width:
variant.width`). The Chrome is `DESIGN_ROUNDS_CHROME` when set, else the Mac's, else one on PATH, and a
terminal design is refused, naming that variable, where there is none. The file says it is the terminal and its
`design-frames` block carries `"kind": "terminal"`. The score scores its decisions like any others,
and measures its pictures only from the terminal adapter's capture (below, claude-config#1414); from
any other capture it says the picture half is unmeasured, so it is no score. It refuses, writing nothing, a chrome
that was not captured, a kind that is not one of the three or the terminal, or one named beside a chrome, a frame with no width or variant, a terminal design with no Chrome to measure it in or whose measurement fails, a terminal frame whose window draws at another width, that draws no `Terminal.screen` window, or whose builder or its `screenShown` throws, a checked decision with no check sentence or no frame, a
decision on a frame the design does not hold, a decision with no owner, an intro that is not text, a
requirements list that is empty or out of shape, a decision naming a requirement the list does not
hold, and an exception without Dan's words, a date and where he said them.

**A design whose frames were captured from different pages is still one file** (claude-config#1474).
Bidspoke's lead validation design had its panel captured in edit mode and its card in view mode, and
was split into two settled files, so its milestone compared two decision maps. Instead, list every
captured page in `"chromes"`, in place of `"chrome"`, each with a `"name"`, and have each frame name
the one it is drawn in:

```json
"chromes": [{"name": "edit", "captured": "edit.html", "from": "<URL, edit mode, panel open, date>", "slot": "#panel", "width": 1280},
            {"name": "view", "captured": "view.html", "from": "<URL, view mode, zoomed on a card, date>", "slot": "#card", "width": 1280}],
"frames": [{"id": "f1", "chrome": "edit", ...}, {"id": "f2", "chrome": "view", ...}]
```

Each page is carried once however many frames share it, `designFrameDocument(<id>)` gives each frame
in its own page, the file lists each page once with where it was captured, each frame's heading names
its page, and its `design-frames` block names it on each frame, which the score keeps on the frame's
row and says beside it ("f2 1280 wide in view"). The built page's fixture route draws each frame in
the matching mode. A spec with one `"chrome"` writes exactly the file it always did. Refused, writing
nothing: `"chromes"` beside `"chrome"` or a `"screen"`, an empty list, a page with no name, two pages
sharing a name, a page no frame is drawn in, a frame naming a page the list does not hold, a frame
naming none in a design of several, and a frame naming one in a design of one.

The checks themselves go beside the file as `<name>.checks.js`, one per checked decision, written
from those sentences (the score's adapters section below says what a check reads).

**Exceptions live in the file, in Dan's words.** When a difference between the build and the design
is one Dan means to keep, ask him with a picker whether to settle it with a new round or as an
exception. Only on his choice of an exception, add it to `settled.json`'s `exceptions`: the decision,
the frame or the region of a frame it covers, his words quoted exactly, the date, and where he said
them (the issue comment, or this session's link), then write the file again. The score skips it and
lists it every time; nothing else excuses a difference.

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
   by name, and a decision naming a requirement the map's own `"requirements"` list does not
   hold, when the map carries one; a map it cannot read is exit 2, never a pass. Who reads the map next: the
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
exceptions it skipped, and writes `score.json` (the one score format, the same for every adapter)
and a `<frame>-diff.png` per frame, differences in red. Exit 0 is matched, 1 not matched yet, and 2
no score: a capture or design it cannot read, a frame with no picture, a design picture not drawn at
its frame's width, a design frame its builder did not draw whole, a check that threw, a check the design itself fails (so the check is wrong, not
the build), or nothing left to measure. Unmeasured is never 100%. The capture's shape is at the top
of `design_score.py`. It reads PNGs with the standard library alone, so it runs the same on both Macs
and on CI: two 1280 by 2000 frames scored in about 7 seconds on 2026-10-19.

**The three adapters.** Each draws the same data on both sides: the design's fixture, committed in the
app's repository, which the settled file's frames are drawn from and which the app renders in a
development only preview (Slate's `?frame=` route on the page itself, honoured only under a dev flag
on the local machine, never in a deployment), or for a mod, the mod's own band from its fixture.

- **Web**: `node ~/.claude/skills/design-rounds/score/capture-web.mjs --design <settled.html> --build
  <the page's local URL> --out <capture folder> [--fixture <fixture.json>] [--storage <signed in
  state.json>]`, run from the app's checkout. It asks the settled file
  for each frame's whole document (`designFrameDocument(<id>)`, which the settled file gives) and
  draws it as a page of its own, and opens the app's page with `?frame=<id>`, each at the frame's
  width, screenshots both in one Chrome with deterministic rasterisation, runs the
  decision checks on both, writes the capture and scores it. The checks are `<design>.checks.js`
  beside the design: `window.DESIGN_CHECKS = [{id, frames, check(doc, ctx) -> {ok, detail}}]`, one
  per decision verified by a check, reading only what both sides share (text, roles, data
  attributes, computed colours), never a styling class. `--perturb '<css>'` changes the built side on
  purpose, the negative control. `--ready '<selector>'` waits for the built page to show its content
  before the picture (at most 30 seconds, then the frame is no score): a streamed page can fire load
  while its loading placeholder is still on screen, which CI once pictured (Try-Pennie/slate#3947).
- **SwiftUI**: `node capture-web.mjs --design <settled.html> --out <folder> --design-only` draws the
  design's side; then a snapshot test in the app's UI test target, using
  `score/swiftui/DesignScoreTests/DesignScoreCapture.swift` (copied into that target), renders the
  real view for each frame from the fixture at the frame's size, scale 1, in sRGB, with its decision
  checks written in Swift, and fills in the same capture; `design_score.py score <folder>` scores it.
  Measured 2026-10-19: a SwiftUI view of two colour bands matched Chrome's drawing of the same HTML
  at 100%, and the same view 15 levels off did not. Swift checks cannot run on the HTML design, so a
  SwiftUI score says its checks have no positive control.
- **A Claude Code mod** (a design with `"screen": "terminal"`, claude-config#1414): `node
  ~/.claude/skills/design-rounds/score/capture-terminal.mjs --design <settled.html> --mod <the mod's
  screen fixture.json> --out <capture folder> [--fixture <the design's fixture.json>]`. A mod draws
  inside Claude Code, and a picture of the real terminal differs from the design's drawing
  everywhere, so the build is drawn in the design's own form: the mod's band rows, exactly as it
  hands them to `$.modkit.bandRow`, read from a fixture committed with the mod, put through mod-kit's
  own composer and refusals (`mods/mod-kit/hooks/band.ts`), and drawn through the shared terminal in
  place of the band the design's frame draws. Both pictures come from one renderer at the frame's
  width. Everything else in the window (title, transcript, prompt, status line) is the design's on
  both sides, so only the band is the build's, the score says so on every such capture, and the
  build's checks run on the window with everything but the band left out, so a check about the
  transcript can never pass on the mod's behalf. A check for a mod's design therefore reads the band
  (`.term-band`); a decision about anything else in the window is not the mod's to draw and is
  `"verify": "elsewhere"`. Measured 2026-10-21 with the status bar's real rows: 738000 of 738000
  pixels at 820 wide, and 737965 (99.9%) with one character of the band changed.

  **How a mod milestone produces its capture.** Commit, beside the mod's tests, its screen fixture:

  ```json
  {"format": "mod-screen", "version": 1, "mod": "status-bar",
   "provenBy": "payload/mods/status-bar/tests/register.test.tsx",
   "frames": [{"id": "f1", "band": [{"mod": "status-bar", "id": "look", "slot": "needs-a-look",
                                     "lines": [[{"text": "PR #636 checks failing", "color": "warning"}]]}],
               "clickable": true}]}
  ```

  one frame per frame of the design, holding the rows the mod publishes in that frame's state, and
  `clickable` false for a frame drawn where a click cannot land (its buttons then show their
  `instead` text, as mod-kit draws them). The test `provenBy` names must hold the file to the mod: it
  drives the mod into each frame's state through its mod-kit stand in, reads the rows the mod
  published, and asserts they equal the fixture's band, so the fixture changes only when the mod's
  output does. The adapter refuses a fixture with no `provenBy`, a frame the design does not declare,
  and a row of another mod; a design frame with no band in the fixture, and a band the shared
  terminal has no drawing for (a colour other than `warning`, `error`, `magenta` or `gray`,
  strikethrough, a button's hotkey or plain style), are no score for that frame, naming what, never
  drawn plain. Run the adapter on the mod's pull request and post its score as for any other.

**Which Playwright draws.** `capture-web.mjs` uses, in order: the app's own (resolved from its
checkout, as Slate has), the package `DESIGN_SCORE_PLAYWRIGHT` names (one naming nothing is refused),
then the one shared install on this Mac. With none it exits 2 naming the install command, so the
design side is never skipped. The capture records which one drew. The Mac apps have no
`node_modules`, so they use the shared install (Dan, 2026-10-20: one per Mac, outside the app
repositories):

```bash
bash ~/.claude/skills/design-rounds/score/install-playwright.sh
```

It installs the Playwright version `score/shared-playwright.json` pins, and its headless Chromium,
under `~/.local/share/design-score/playwright` (outside `~/.claude`, so the sync never carries it),
never prompts, installs nothing when it is already usable, and prints the path to export. About 216 MB
installed, plus npm's 38 MB download cache, measured 2026-10-20. `--check` says whether it is usable
and installs nothing.

**A copy for an app's CI.** An app whose CI should run the score (Slate, Dan 2026-10-20) keeps the
tools in its own repository, since its CI has no `~/.claude`:

```bash
python3 ~/.claude/skills/design-rounds/score/vendor-score.py copy <app folder for the copy>
python3 <app folder for the copy>/vendor-score.py check <app folder for the copy>
```

`copy` writes the score's files flat in one folder (`capture-web.mjs`, `design_score.py` and its
helpers, `design_file.py`, the shared Playwright's settings and `vendor-score.py` itself) and
`vendor-manifest.json`, each file's hash as claude-config had it. `check` compares the folder with its
manifest everywhere, CI included, which catches a hand edit, a missing file or a stranger in the
folder; and, wherever claude-config's copy is on disk (`~/.claude`, or `--against <score folder>`),
with that too, which catches claude-config having moved on. In CI it says it did not compare with
claude-config rather than claiming to. Exit 0 matches, 1 drift (each file named, and the command that
refreshes the copy), 2 could not check. CI never fetches claude-config to compare, since every change
to the score here would then fail the app's next unrelated pull request; refreshing is a deliberate
change made on a Mac.

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

The Match issue is the one whose body carries the mark itself, outside code; an issue quoting the
mark in backticks or a code block to document it is not one (claude-config#1394). A design Dan
abandons is closed as not planned, `gh issue close <n> --reason "not planned"`, or as a duplicate,
`gh issue close <n> --duplicate-of <m>` (or `--reason duplicate`): the gate lets either through
below 100%, and the milestone then closes too, since its Match issue is the record that the design
was abandoned (claude-config#1405, #1424). That is his decision to make, never a way past a refusal.

A close the gate cannot see, on GitHub's website or by a closing keyword in a commit pushed straight
to the default branch, is undone afterwards: once a day `design-score-reopen.py` finds Match issues
and design milestones closed below 100% (no score, an unreadable one, or one for other code than the
close was made on), comments once on the Match issue with the score it read and the way to 100%, and
reopens them. So score and post before closing anywhere; an exception Dan approves, recorded in the
design file and scored, reads 100% and is left closed, and so is a Match issue closed as not planned
or as a duplicate.

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
