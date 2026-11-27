---
name: draft-edit-review
description: Use when Dan asks for the review of how he edits Slack drafts, answers the weekly "[Draft edit review]" session start notice with a yes, or types /draft-edit-review. Compares the Slack drafts sessions saved with what he sent, and offers each edit he keeps making to him as a writing rule.
trigger: /draft-edit-review
---

# /draft-edit-review

Sessions save every Slack message as a draft, and Dan edits it before he sends it. This compares the
two, counts the kinds of edit he makes, and puts each one he keeps making to him as a proposed
writing rule. He decides each rule. Nothing changes without his pick (claude-config#3554).

Run it only when Dan asks. The weekly notice says the review is due; it is not a request to run it.

## What you never do here

- Never copy an example pair, or any part of one, anywhere but the question that shows it to Dan: not
  into a rule, a file, a note, a commit, an issue, a memory or a message. It is Slack message text.
- Never write a rule by any other route than step 6: no shell command, no script, no other agent.
- Never write a sentence Dan has not seen. The sentence he accepts in step 5 is the sentence written
  in step 6, word for word, and nothing rewords it in between.
- Never send, schedule or draft anything in Slack from this skill.
- A refusal of either command below by the Slack drafts gate is final. Tell Dan its words and stop.
  Do not run the command another way, in pieces, through a file, or with its output sent anywhere.

## 1. Read what was decided before

```
python3 ~/.claude/skills/draft-edit-review/decisions.py status
```

It prints the author, the last review and each decision so far. If it fails, tell Dan what it said
and stop: state that cannot be read is never treated as nothing decided.

If the author is not set, find Dan's own Slack member id (`slack_read_user_profile` with no user
named answers for the signed in user) and keep it on this Mac:

```
python3 ~/.claude/skills/draft-edit-review/decisions.py author <member id>
```

The member id stays in that state folder. It never goes in a file that syncs.

## 2. Count, with no message text

Run this alone, exactly as written, with the member id. No pipe, no redirection, nothing before or
after it. Give the command a timeout of ten minutes: it reads every session record on this Mac.

```
python3 ~/.claude/hooks/lib/draft-edit-diff.py --author <member id> --differences --likeness
```

It prints counts only: the tallies, then how the changed pairs differ, then the pairs by how like
their draft they are. It reads the decisions from step 1 itself, so a kind Dan accepted or said
never to offer is marked `decided before` without anything being passed. Read the result by its
exit code first:

- Exit 4: nothing was measured. The read results are laid out in a way it does not read, or the text
  of the messages is not where it looks. Run it once more with `--shapes` added, tell Dan what both
  runs printed, and stop. Then record that it happened, in these words and no others:
  `bash ~/.claude/hooks/lib/issue-spool.sh note . "draft-edit-diff.py exited 4 on this Mac: the Slack read layout is not one it reads. The --shapes output is in the session that ran it." "draft-edit-review"`
  Never put a line of either run's output in that note. The note becomes an issue on a public
  repository, and Dan already has the output in front of him.
- Exit 3 or 2: tell Dan what it said and stop.
- Exit 0: go on.

Tell Dan the counts in plain words: how many pairs, how many were sent as drafted, how many heavily
rewritten, and each kind of edit with the pairs and threads it rests on. Say what was left out, with
its count: read results it could not read, concise reads (which show no time, so nothing is paired
from them), drafts with no post read back and how many of those sit where a concise read came
afterwards, posts more than an hour after their draft, and pairs whose post begins or ends in a line
that may be the connector's own (a line of his shaped like "Update: ..." that the draft did not hold
is left out with them). Say what the count cannot see, in one line: it only pairs a draft with a
post in a thread some later session read back in the detailed layout, a heavily rewritten pair is
in no kind because it may not be an edit of that draft at all, and each Mac counts only its own
sessions.

Before any rule is put to him, tell Dan the doubt over these counts, in plain words, with this
run's numbers:

- How many pairs read as sent as drafted, and how many sit at 0.98 and over in the count by
  likeness.
- Of the pairs changed but not heavily rewritten, how many one difference in how a read writes a
  message would make the same, and how many are none of these. Say that this is a ceiling: he also
  changes punctuation and adds and cuts lines, so some of those are his edits.
- That the first count, on the issue on 2026-11-24, read about one draft in five as sent as
  drafted, that the first run of this reader read 6 of 184, and that nobody yet knows why. The
  likeliest reason is that the two counts meant different things by it. Until that is settled, a
  rule below may rest partly on differences that are not his edits.

Say it at every review for as long as the reader's own account, at the top of
`draft-edit-diff.py`, lists that share as not explained.

A kind marked `too thin` is reported with its count and no rule is offered for it. The floor is 10
pairs in 3 threads, set in the script: below it one long thread is enough to make an edit look like
a habit. A kind marked `decided before` is not offered either.

If no kind is `recurring`, say so, run step 7, and stop. Ask nothing.

## 3. Get one example pair for each recurring kind

Only now, and once, run the same command with `--examples` added. For each recurring kind it prints
one pair: the draft, and what Dan sent. That text is now in this session. Show it in the question
in step 5 and nowhere else.

## 4. Word each proposed rule, and check it, before any question

For each recurring kind, in the order the script printed them, settle the sentence first:

1. Start from the sentence below for that kind, and reword it only so that it says what the example
   shows. It never quotes the example, and it names nobody and nothing from it: no person, channel,
   customer or project. The file it goes into can sync to a public repository.
2. Add the day and what it rests on in brackets at its end, for example
   "(Dan, 2026-11-27, from 46 of 106 drafts he edited)". Dan's own name there is the only name in it.
3. Run `/no-ai-tells` on that whole sentence now, and take what it hands back as the sentence.

The check comes before the question on purpose. Run after it, the check could change words Dan had
already accepted, and the sentence saved would be one he never saw.

| Kind | The sentence to start from |
| --- | --- |
| figures cut | A Slack message carries only the one or two figures the reader needs to act, and leaves the rest out. |
| length cut | A Slack message says the point and the ask, and leaves out the supporting detail. |
| the ask reworded | The ask in a Slack message is one plain question or request, in the words Dan uses. |
| the opening changed | A Slack message opens with the point, with no line leading up to it. |

## 5. Put each recurring kind to Dan

Ask one AskUserQuestion for each recurring kind, each in a call of its own, in the same order. The
question holds, in this order:

1. The proposed rule: the sentence from step 4, whole, brackets included, exactly as it would be
   written.
2. What it rests on: "N of M pairs, in T threads", and how many of those N pairs one difference in
   how a read is written would make the same, from the reader's line for that kind under "Of the
   pairs under each kind": "up to K of those N may be no edit of yours".
3. The example pair, the draft and then what he sent, each as the script printed it.

The options, in this order:

- **Accept**: "Write this sentence down, word for word. You pick where next."
- **Not now**: "Leave it. It is offered again at the next review."
- **Never offer this again**: "Stop proposing a rule for this kind of edit on this Mac."

Dan can also answer in his own words. If he rewords the rule, run `/no-ai-tells` on his wording,
and ask this question again with the sentence that comes back. Nothing is written until he has
picked Accept on the exact sentence in front of him.

## 6. Write down what he decided

**Accept.** Then a second AskUserQuestion asks where the rule goes, since Dan decides that for each
rule (his answer on the issue, 2026-11-27). The options:

- **The no-ai-tells skill**: "Checked whenever a message is written for somebody else, on both Macs."
- **The Slack section of the global CLAUDE.md**: "Loaded in every session on both Macs."
- **This project's own file**: "Only sessions in this project, in its CLAUDE.md or AGENTS.md."

For the first two, the file is the installed one under `~/.claude` (`skills/no-ai-tells/SKILL.md`
or `CLAUDE.md`), which the config sync carries to the other Mac and into a public repository,
unless this session is in the claude-config repository, where the change goes in `payload/` by
that repository's own rules.

What checks the save depends on the place, so do the one that applies:

- **A `CLAUDE.md` or `AGENTS.md`** (the second and third places). The ask before saving mod asks
  Dan before a save to a `CLAUDE.md`, an `AGENTS.md` or a memory file. Expect its question. That
  is the feature working. Wait for his answer.
- **The no-ai-tells skill file.** The ask before saving mod does not ask about a skill file, so
  the check is a question of this skill's own. Before the edit, ask one more AskUserQuestion that
  shows the final sentence in full and the file's name and path, with the options **Write it**
  ("Add exactly this sentence to that file.") and **Do not write it** ("Leave the file as it is.").

Then make the edit yourself, with the Edit tool, in this session: exactly the sentence he accepted,
word for word, and nothing else. Do not run `/no-ai-tells` again and do not tidy the sentence: it
was checked in step 4, before he saw it.

If he says no at either question, or the edit is refused, the rule is not written: record the kind
as `not-now` and tell him so.

Never write a rule by any other route. Once the edit is saved, and only then, record it, with the
label for the place he picked: `no-ai-tells`, `global-claude-md`, or `project` with the project's
folder name.

```
python3 ~/.claude/skills/draft-edit-review/decisions.py record "<kind>" accepted --where no-ai-tells
python3 ~/.claude/skills/draft-edit-review/decisions.py record "<kind>" accepted --where global-claude-md
python3 ~/.claude/skills/draft-edit-review/decisions.py record "<kind>" accepted --where project --project <folder name>
```

**Not now.**

```
python3 ~/.claude/skills/draft-edit-review/decisions.py record "<kind>" not-now
```

**Never offer this again.**

```
python3 ~/.claude/skills/draft-edit-review/decisions.py record "<kind>" never
```

If a record fails, tell Dan it was not recorded and what the command said. Do not go on as if it
was: the kind would be put to him again next week.

## 7. Close the review

```
python3 ~/.claude/skills/draft-edit-review/decisions.py reviewed
```

That is what the weekly notice reads: it stays quiet until a draft is saved after this moment and a
week has passed since it last spoke.

Then tell Dan, in a few lines: each kind and what he decided, where each accepted rule was written,
and that the decisions are kept on this Mac only, so the other Mac can offer the same kind once.

## Taking a decision back

`decisions.py status` shows every decision. To undo one, so the kind is offered again:

```
python3 ~/.claude/skills/draft-edit-review/decisions.py forget "<kind>"
```

Forgetting an accepted kind does not remove the rule that was written. Tell Dan where it is, and
remove it only if he asks, through the same Edit and the same check at the save.
