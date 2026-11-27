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
- Never write a rule by any other route than step 5: no shell command, no script, no other agent.
- Never send, schedule or draft anything in Slack from this skill.
- A refusal of either command below by the Slack drafts gate is final. Tell Dan its words and stop.
  Do not run the command another way, in pieces, through a file, or with its output sent anywhere.

## 1. Read what was decided before

```
python3 ~/.claude/skills/draft-edit-review/decisions.py status
```

It prints the author, the last review, each decision so far and the `skip arguments` line. If it
fails, tell Dan what it said and stop: state that cannot be read is never treated as nothing decided.

If the author is not set, find Dan's own Slack member id (`slack_read_user_profile` with no user
named answers for the signed in user) and keep it on this Mac:

```
python3 ~/.claude/skills/draft-edit-review/decisions.py author <member id>
```

The member id stays in that state folder. It never goes in a file that syncs.

## 2. Count, with no message text

Run this alone, exactly as written, with the member id and whatever follows `skip arguments:` (leave
that part out when it says none). No pipe, no redirection, nothing before or after it:

```
python3 ~/.claude/hooks/lib/draft-edit-diff.py --author <member id> <skip arguments>
```

It reads this Mac's session records and prints counts only. It can take a minute or two. Read the
result by its exit code first:

- Exit 4, or a line saying read results were in a layout it cannot read: nothing was measured. Run it
  once more with `--shapes` in place of the skip arguments, tell Dan what both runs printed, and stop.
  File what you found with `bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "draft-edit-review"`.
- Exit 3 or 2: tell Dan what it said and stop.
- Exit 0: go on.

Tell Dan the counts in plain words: how many pairs, how many were sent as drafted, how many heavily
rewritten, and each kind of edit with the pairs and threads it rests on. Say what the count cannot
see, in one line: it only pairs a draft with a post in a thread some later session read back, a draft
he deleted and wrote again reads as heavily rewritten, and each Mac counts only its own sessions.

A kind marked `too thin` is reported with its count and no rule is offered for it. The floor is 10
pairs in 3 threads, set in the script: below it one long thread is enough to make an edit look like
a habit. A kind marked `decided before` is not offered either.

If no kind is `recurring`, say so, run step 6, and stop. Ask nothing.

## 3. Get one example pair for each recurring kind

Only now, and once, run the same command with `--examples` added. For each recurring kind it prints
one pair: the draft, and what Dan sent. That text is now in this session. Show it in the question
in step 4 and nowhere else.

## 4. Put each recurring kind to Dan

Ask one AskUserQuestion for each recurring kind, each in a call of its own, in the order the script
printed them. The question holds, in this order:

1. The proposed rule, in one plain sentence. Start from the sentence below for that kind, and reword
   it only so that it says what the example shows. It never quotes the example.
2. What it rests on: "N of M pairs, in T threads".
3. The example pair, the draft and then what he sent, each as the script printed it.

| Kind | The sentence to start from |
| --- | --- |
| figures cut | A Slack message carries only the one or two figures the reader needs to act, and leaves the rest out. |
| length cut | A Slack message says the point and the ask, and leaves out the supporting detail. |
| the ask reworded | The ask in a Slack message is one plain question or request, in the words Dan uses. |
| the opening changed | A Slack message opens with the point, with no line leading up to it. |

The options, in this order:

- **Accept**: "Write this rule down. You pick where next."
- **Not now**: "Leave it. It is offered again at the next review."
- **Never offer this again**: "Stop proposing a rule for this kind of edit on this Mac."

Dan can also answer in his own words. A reworded rule is still his to accept: ask again with his
wording if it is not clear which option he meant.

## 5. Write down what he decided

**Accept.** Then a second AskUserQuestion asks where the rule goes, since Dan decides that for each
rule (his answer on the issue, 2026-11-27). The options:

- **The no-ai-tells skill**: "Checked whenever a message is written for somebody else, on both Macs."
- **The Slack section of the global CLAUDE.md**: "Loaded in every session on both Macs."
- **This project's own file**: "Only sessions in this project, in its CLAUDE.md or AGENTS.md."

Then make the edit yourself, with the Edit tool, in this session: one sentence, with the day and
what it rests on in brackets, for example "(Dan, 2026-11-27, from 46 of 106 drafts he edited)". For
the first two, edit the installed file under `~/.claude` (`skills/no-ai-tells/SKILL.md` or
`CLAUDE.md`), which the config sync carries to the other Mac, unless this session is in the
claude-config repository, where the change goes in `payload/` by that repository's own rules. Run
`/no-ai-tells` on the sentence first.

Expect a second question at the save: the ask before saving mod asks Dan again before a rule file
changes. That is the feature working. Wait for his answer. If he says no there, or the edit is
refused, the rule is not written: record the kind as `not-now` and tell him so.

Never write a rule by any other route. Once the edit is saved, and only then:

```
python3 ~/.claude/skills/draft-edit-review/decisions.py record "<kind>" accepted --where "<the place he picked>"
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

## 6. Close the review

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
remove it only if he asks, through the same Edit and the same question at the save.
