---
name: regal-journey-edits
description: Write the page Dan or a teammate follows to hand edit Regal journeys (Pennie's Regal account), in the format Dan chose. Use whenever a change elsewhere (Slate, trypennie, Pipedream, Salesforce) needs nodes added, rewired or edited in live Regal journeys and a person, not Claude, will make the edits. Reads the journeys live and read only, then builds one page with one ticked row per node change. Also use when Dan has Claude make the edits in the Regal editor itself: a snapshot, a page script and jdiff.py check every line before Save as Live and every setting after.
---

# Regal journey edits

Dan makes Regal journey edits himself, from a page Claude writes. On 2026-10-27 he named the
format: the Slate Journey Edits page of 2026-09-23 ("this is the format I like for regal journey
edits"), and asked for every value to be copyable ("I should know exactly what to do and where to
put it with node IDs and copy/pasting"). This skill is that page, built by `build_page.py` from a
JSON spec, so the format is not rewritten, and drifted, for each change.

## The rules

1. **Read every journey live, read only, and record the version.** Use the Regal MCP's
   `fetch-journey` (large journeys come back as a saved file; read it with python, never paste it).
   Never call `update-journey`, `propose-journey-changes` or anything else that writes: Dan makes
   the edits, and a write from Claude is an edit nobody reviewed. Put the version read on each
   journey (`version`, `read`), so a card is never followed against a journey someone has changed
   since.
2. **Name every existing node by its number and its exact live name, everywhere.** In text, write
   `<<8>>` and let the builder render `node 8 "Agent Assigned?"` from the journey's `nodes` map,
   which holds each node's `type` and `label` exactly as Regal stores them (`""` when the node has
   no name, with a `detail` such as `5 seconds`). Never write a node's name by hand, never shorten
   it, and never merge two nodes into one label. Why: on 2026-10-27 a path strip drew a chip
   "3 No / 5", and Dan: "Node numbers can't change. why does the name of the 3 change". The builder
   refuses a reference to a node the map does not hold.
3. **Write wiring as sentences, one line move each.** "On the No exit of <<3>>, remove the line to
   <<8>> and draw it to <<new:Marcia call?>> instead." Name the exit (Yes or No) every time a node
   has two. No path strips, no From and To shorthand.
4. **Every value Dan types or pastes is `[[value]]`**, which draws it with its own Copy button:
   node names, property paths, `{{...}}` templates, emails, campaign numbers, event names. A value
   he only reads is `` `code` ``.
5. **A copied Update Contact node lists every row of its source**, each tagged Keep, Change, Add or
   Remove (`rows`), read from the live journey, never "about 28 rows". Why: a partial list makes him
   guess which rows the copy should keep.
6. **Every node change says what proves it afterwards.** `test` names something that really reaches
   Regal; when nothing can before go live, say it waits for real traffic. In Slate, a booking on an
   `is_test` bucket such as PARTNER never reaches Regal (`SUPPRESSED_RESPONSE` in
   `src/lib/webhooks/emit.ts`), so it is never a Regal test. `after` names the node the next real
   runs should reach once the journey is published, which is how a wrong line is caught.
7. **A journey that needs nothing still gets a card, in a no change group, with the trace that
   proves it.** Why: on 2026-10-27 three journeys a draft would have edited turned out, once traced
   in full, to be handled already by another path, and the edits would have broken them.
8. **Load `artifact-design` and `artifact-capabilities` before publishing.** The page declares
   `capabilities: {db: {}}`, so ticks save for everyone who opens it; it falls back to this
   browser's storage when the store is not served.
9. **In the same turn the page is published, pin a manual steps card** (`mcp__manual-steps__steps`),
   one step per journey: the journey's Regal link as `url`, the page's anchor for it
   (`<page url>#j<journey id>`) as `value`, and the node the runs should reach in its last action.
   Why: claude-config#1811, Dan had to ask for the card ("why did I have to ask you for that?").

## Build it

```bash
python3 ~/.claude/skills/regal-journey-edits/build_page.py spec.json page.html
```

Run it with no arguments for the marks it understands. It refuses, writing nothing and naming every
problem, a node with no number or no name, a reference to a node, copy or new node the spec does not
hold, an unknown tag or group, and any em or en dash. Keep the spec and the page in this session's
scratchpad. `tests/fixture.json` is a small working spec to start from.

### The spec

```json
{
  "title": "...", "subtitle": "one sentence", "storageKey": "unique-per-page",
  "legend": [{"term": "Marcia call?", "text": "..."}],
  "pattern": {"title": "The pattern, once", "steps": ["..."]},
  "notesTop": [{"id": "safe", "title": "Safe to build before go live", "body": ["text", {"list": ["..."]}]}],
  "groups": [{"key": "edit", "title": "Your edits", "tickable": true, "lead": "..."},
             {"key": "nochange", "title": "Traced, no change needed", "tickable": false}],
  "journeys": [{
    "id": 479, "name": "exact live name", "uuid": "...", "version": 25, "read": "27 Oct 2026",
    "trigger": "Slate Booking Created", "group": "edit",
    "nodes": {"8": {"type": "conditional", "label": "Agent Assigned?"},
              "5": {"type": "delay", "label": "", "detail": "5 seconds"}},
    "changes": [{
      "key": "a", "node": 8, "do": "Add before", "current": "the node's settings now",
      "title": "...", "why": "...",
      "new": [{"name": "Marcia call?", "type": "Conditional Match",
               "fields": [{"field": "Property", "value": "[[properties.slateGhostBooking]]"}]},
              {"copyOf": 96, "name": "Set Booking Details (Marcia)", "type": "Update Contact",
               "rows": [{"tag": "Change", "attr": "customProperties.ai_agent_eligible", "was": "FALSE", "value": "TRUE"}]}],
      "steps": ["On the No exit of <<3>>, remove the line to <<8>> and draw it to <<new:Marcia call?>> instead."],
      "skipped": "...", "test": "...", "after": "Each run reaches <<8>>."}]
  }],
  "notesBottom": [{"id": "questions", "title": "Questions still open", "body": [{"ol": ["..."]}]}]
}
```

Marks in any text: `<<8>>` a node of this journey, `<<479:8>>` a node of another journey on the
page, `<<new:Name>>` a node this change adds, `<<copy:97>>` this change's copy of node 97 (a copy
keeps its source's name in Regal, so it is named through its source), `[[value]]` copyable,
`` `text` `` code.

## Check every line landed

Every line a card moves has to be on the canvas, from the exit it names, before Save as Live, and a
crowded canvas makes a missed one easy to save. Why: in Slate's Marcia edits on 2026-10-28 a drag
that missed its handle panned the canvas on journey 481 instead of drawing the line, and only a
check of every line caught it before anything was saved.

**When a person makes the edits, the check is by eye.** Put it in the page's `pattern`, as the step
before Save as Live: check that every line the card names is drawn, from the exit it names. The
card's `after` then catches what the eye missed, once real runs go through.

**When Claude makes the edits in the Regal editor, the script check replaces the by-eye one**
(decided for claude-config#1853 on 2026-10-28): an eye skims a crowded canvas, a script reads every
line. Rule 1 still holds, since the editor is driven like a person and no Regal tool that writes is
called. Keep every file in this session's scratchpad.

1. **Snapshot the version being edited before touching it.** Read it with `fetch-journey` (or
   `fetch-journey-version` when the editor is open on an older version), save the result to a file,
   then:

   ```bash
   python3 ~/.claude/skills/regal-journey-edits/jdiff.py snap journey-481.json snap-481.json
   ```

   It never overwrites a snapshot, because the one taken before the edit is the only record of what
   the journey was.
2. **Prove the page script reads this canvas, before the first edit.** Fit the whole journey on
   screen (the fit view control), so every node is drawn. Run all of `read_lines.js` in the editor
   tab with the browser tools' JavaScript tool, save the text it returns, and diff it:

   ```bash
   python3 ~/.claude/skills/regal-journey-edits/jdiff.py diff snap-481.json canvas-481-before.json
   ```

   It must say No differences. Anything else means the script is not reading this canvas, or the
   canvas has not drawn every node, and a check never seen to pass proves nothing: stop and tell Dan
   rather than edit on it.
3. **Before Save as Live, read the canvas again and diff it against the same snapshot.** The lines
   removed and added must be exactly the card's line moves, each from the exit the card names. A
   line listed as "exit not read from the canvas" leaves a node with more than one exit, and the
   page did not expose which: check that one line's exit on the canvas before saving.
4. **After Save as Live, read back the saved version and diff it** (`fetch-journey` again, saved to a
   new file, then `jdiff.py diff` against the snapshot). It lists every line and every node setting
   that changed; anything the card did not ask for is undone before real runs reach it. Moving a
   node on the canvas and Regal's live counts are not settings, so they are never listed.

`jdiff.py` exits 0 for no differences, 1 when it lists some, and 2 when a file could not be read or
is not what it should be (a missing file, a different journey, a line the page script could not
read). A 2 is never a clean result.

## Tests

`bash test-regal-journey-edits.sh` runs `tests/build_tests.py`: the fixture builds, every copyable
value gets a button, a node with no name or an unknown reference is refused, and no dash reaches the
page.

`tests/test_jdiff.py` runs with every skill's Python tests (`hooks/test-skill-python-tests.sh`). It
checks `jdiff.py` against `tests/journey_v1.json`, shaped on a real fetch-journey result with every
id and name invented, and runs `read_lines.js` under node against `tests/canvas.html`, React Flow's
markup for the same journey: a line removed, a line added, a line moved between exits, a changed
setting, identical inputs exiting 0, and every unreadable input exiting 2.
