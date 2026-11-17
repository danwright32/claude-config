---
name: no-ai-tells
description: Checks writing against the whole Wikipedia list of AI writing signs. On a draft the session wrote, it hands back the corrected draft in full; on text Dan pastes in, it suggests specific edits.
user-invokable: true
args:
  - name: task
    description: Text to review, pasted in for suggested edits
    required: false
---

## MANDATORY FIRST STEP: read the whole list

Before producing any output, read every part of the Wikipedia list of AI writing signs:

```
https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing
```

The page is about 250,000 characters and one WebFetch reads at most 100,000, so one call is never the whole list. Measured on 2026-11-16: the first call ended with a note that 151,549 characters were unread, and the unread part held the promotional vocabulary, the summary endings and the em dash section (claude-config#3060).

1. Call WebFetch on the URL with a prompt asking for every sign in that part: each heading, with the words, phrases and habits it lists, quoted as the page gives them.
2. When a result says part of the page was not read, call WebFetch again on the same URL with the `offset` that result gives. Repeat until a result has no such note.
3. The list is read only once a part you read reaches the page's "See also" heading, which comes after the last sign. Check for it, rather than trusting the absence of a note.
4. If this session has already read the whole list this way, use what it read rather than fetching it again.

If any part could not be read (a fetch failed, or "See also" never arrived), check against what was read, say which part is missing, and never report the text clean: say the check was partial.

Every sign read is the list to check against for this session.

---

## Two modes

**A session's own draft.** When a session runs this skill on text it wrote, which it is about to show Dan or put in front of other people (a Slack message, an email, a PR description, an issue or PR comment, any prose the prose hook flagged), apply every fix and write the corrected draft in full. That corrected draft is the text shown to Dan and, for a Slack message, exactly the text saved as the draft (global CLAUDE.md, Slack section). Run the skill before the text is shown or offered in a picker, so nothing is reworded after Dan has seen or chosen it. After the draft, list each change in one line: the phrase as it was, and the sign it matched.

**Text Dan pastes in.** When Dan hands over text of his own (the `task` argument, or text pasted with the command), suggest edits and do not rewrite it. Follow "The review process" below.

When it is unclear which mode applies, text the session wrote is its own draft, and text Dan wrote is his.

## This skill never sends

It writes text. It never sends, posts or saves anything. Saving a Slack draft, posting a comment or sending an email is the calling session's step, under the rules that govern that step, and the Slack rules save drafts only, never a sent message.

---

## How to apply the list

For every sentence, ask:

- Does it contain a word from the list's AI vocabulary (delve, tapestry, pivotal, underscore, foster, garner, vibrant, landscape, showcase, testament, crucial, intricate, enduring, quietly, and the rest the page names)?
- Is "quietly" a filler adverb ("quietly became the standard", "quietly reshaping the industry")? Cut it or name what actually happened.
- Is "serves as", "stands as", "marks" or "represents" doing the work of "is"?
- Is it a "Not only X, but also Y" construction?
- Does it list exactly three things to sound comprehensive?
- Does it make a vague significance claim ("this is a pivotal moment", "reflects broader trends")?
- Does it attribute to unnamed experts ("experts argue", "industry reports suggest")?
- Is it a "Despite its strengths, it faces challenges" conclusion?
- Does it hold an em dash or en dash at all? Dan's writing rules allow none, so each one is a finding.
- Does it address the reader with "let's explore" or "you will notice"?
- Does it vary synonyms for a key term for no reason (elegant variation)?
- Does the opening recap the writer's own work (what was checked, what matched, what passed)? See "A reply that reports checking or work" below.
- Does it match any other sign the page lists?

If yes to any of these, it is a finding.

---

## A reply that reports checking or work

The Wikipedia list is about articles, so it has no sign for a reply that recaps the writer's own work. Its nearest entries are the comment signs (claims of effort, "carefully reviewed") and the edit summary signs (canned assurances, and procedural statements such as "ensured" and "verified"). A draft can pass every sign on the page and still open like a machine's status report.

When the draft answers someone after the writer checked, reviewed, tested or built something, its opening is two things:

1. The verdict, in one sentence of fifteen words or fewer, in the words the reader would use: "Thanks, all five check out in staging, and so does the fix."
2. The first thing asked of the reader: what they have to do, answer or decide.

Everything before the first thing asked of the reader, other than that one verdict sentence, is the recap. It is a finding, and it is cut from the message, never moved further down. The recap is: the list of what was checked, how it was checked, what matched, pass counts, deploy and run times, the names of the tests that cover a case, and what the reader wrote, told back to them. The reader did the work being reported on, or asked for it, and wants to know whether it is right and what is left.

Before: "I checked all five against the staging records and they match your notes: the totals, the flags, the archived rows and the export. The fix is in the build deployed at 10:21, and the test suite passes on it (69 of 69). Two cases weren't in your run, but `archive_keepsFlag` and `export_skipsEmpty` cover them, which is enough for me."

After: "Thanks, all five check out in staging, and so does the fix."

In the list of changes after the draft, name this one "recap of the writer's own work".

---

## What human writing sounds like

Human writers:
- Use "is" and "are" without shame
- Repeat a word rather than hunt for a synonym
- Make specific claims, not gestural ones
- Have a point of view, not just "balanced perspectives"
- End sentences before they need a caveat
- Cut words instead of adding them
- Use short sentences when they work
- Don't narrate their own structure ("In this section we will explore...")
- Don't conclude with manufactured optimism about the future

---

## The review process (text Dan pastes in)

1. Read the whole list, as the first step says.
2. Read the text in full.
3. Scan every sentence against the list.
4. Output a numbered list of suggestions. For each:
   - Quote the exact phrase or sentence that needs changing.
   - Name the sign it matches, from the Wikipedia list or the checks above.
   - Give a concrete replacement: not a direction, an actual rewrite of that phrase or sentence. Don't say "replace with something more specific"; say "try: 'She filed the report at 4am'". It can be loose or offer a couple of options, but it must be real text Dan can drop in or riff from.
5. End with a short count: how many findings, and the commonest kind.

---

## Hard rules

- **Text Dan pastes in is never rewritten in full.** Suggest specific, targeted edits only.
- **A session's own draft comes back corrected, in full.** Never as suggestions the session applies afterwards, which leaves the text shown different from the text checked.
- **Quote exactly.** Use the actual words, not paraphrases.
- **Always give real replacement text.** Don't say "make this more specific": write what the specific version could be.
- **Name the exact sign**, not just "this sounds AI-ish".
- **If in doubt, flag it.** Better to over-suggest than miss something.
