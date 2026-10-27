---
name: regal-journey-edits
description: Write the page Dan or a teammate follows to hand edit Regal journeys (Pennie's Regal account), in the format Dan chose. Use whenever a change elsewhere (Slate, trypennie, Pipedream, Salesforce) needs nodes added, rewired or edited in live Regal journeys and a person, not Claude, will make the edits. Reads the journeys live and read only, then builds one page with one ticked row per node change.
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

## Tests

`bash test-regal-journey-edits.sh` runs `tests/build_tests.py`: the fixture builds, every copyable
value gets a button, a node with no name or an unknown reference is refused, and no dash reaches the
page.
