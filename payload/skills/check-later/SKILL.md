---
name: check-later
disable-model-invocation: true
description: Use when Dan types /check-later in a session that has left work waiting on a later date (a canary week, an N day gate, data still accumulating, "we'll check this in a week"), to put that work on his Slack list "Dan Projects To Do List" as a row a fresh session can run, and to hand him a card for setting its reminder.
trigger: /check-later
---

# /check-later

Turns each thing this session left waiting on a date into a row on Dan's Slack list, with a one line
prompt a brand new Claude Code session can run cold on the start date, then pins a card telling Dan
to set the reminder. Dan types nothing after the command: everything comes from this session.

## The list

**Dan Projects To Do List**, list id `F0CB5JMEM2P`, in Pennie's Slack
(https://pennieinternalteam.slack.com/lists/T06GHEHDWCT/F0CB5JMEM2P).

| Column | Key | What goes in it |
|---|---|---|
| Task | `name` | Short imperative naming the issues: `Check the first Salesforce canary (#2173)` |
| Status | `people` | Always `Waiting` |
| Description | `Col07QBFU85SB` | The one line prompt (step 4) |
| Start Date | `Col0CAWEL5RFH` | `YYYY-MM-DD` |
| Project | `Col0CBFHLQX44` | A select: read its options, never assume them |
| Reminder Saved | `Col0CBDTLART3` | Dan ticks it himself. Never set it to true |

Start with `slack_read_list` on `F0CB5JMEM2P` and `schema_only: true`. If that fails (the connected
Slack is not Pennie's, or has no access), stop: say the connected Slack cannot open the list, and add
nothing. If a column above is missing or renamed, stop and say which.

## Steps

### 1. Find the waiting items

Read this session's conversation. A waiting item is work that cannot start until a known date: a
canary or trial week ending, a gate of N days without a hit, data that must accumulate, a change that
must bake. For each, note the repo, the issue numbers, what unlocks it and what to do once it does.
Take every one in the session, not just the last.

- Nothing waiting: say "This session left nothing waiting on a date" and stop.
- Waiting on something with no date (a review, a person, another PR): it does not belong on this
  list. Say so for that item and leave it out.
- A follow on that can only start once a dated item passes (the next canary, a contract migration
  after a deploy) gets no row of its own: it goes inside that item's prompt as what to do next.

### 2. Fact check each item against the record

The session's own words are the claim; the record is the evidence, and where the record is newer
than the session (a later comment, a later version), the record wins. All read only.

1. Read the issue with every comment (`gh issue view <n> --comments` in the session's repo). Read
   each issue the item names.
2. Find the instant the clock started, from what proves it was LIVE: the first successful deploy
   containing the merge (`gh pr view <n> --json mergeCommit`, then
   `gh run list --workflow Deploy --limit 200 --json headSha,conclusion,createdAt,updatedAt` filtered
   to runs after the merge, then `git merge-base --is-ancestor <merge> <deployed sha>`), an audit
   row for a setting change, or a timestamped comment. A merge time is not a live time.
3. Add the wait in UTC, then convert to ET. US clocks go back at 2 AM on the first Sunday of
   November and forward on the second Sunday of March, so a wait that crosses one ends at a
   different ET clock time than it started. Check every weekday you write:
   `date -j -f %Y-%m-%d 2026-10-23 +%A`.
4. Look for what moves the date or breaks the check: data that arrives late (GA4 takes up to a
   day), data purged before the read (execution_steps keeps 7 days; log retention), a scheduled
   report whose next run is the one that covers the last day.
5. Every number, id, table, file and time the prompt will quote must be found in the issue, its
   comments or the code. Anything the session got wrong is corrected in the row and told to Dan.

### 3. Pick the start date and reminder time

Start Date is the first ET day the check can run with complete data. The reminder is 9:00 AM ET on
that day. When the wait ends later that day, or the data comes from a scheduled report that lands at
or after 9:00 AM, or the time otherwise matters, give the exact ET time instead and say why.

### 4. Write the row

The Description is ONE line with no line breaks, in plain words, with no dashes as punctuation. Its
parts, in this order:

1. What and where: `Check #2220 in Bidspoke:` or `Finish #1437 in Bidspoke.`
2. What to read first: the issue and its comments, naming the comment date that matters.
3. The facts a cold session needs: exact times in ET (UTC too where a query needs it), ids, tables,
   project refs, file paths, the numbers from the last reading. Where a source will have been purged
   by the start date, name the source to read instead.
4. The read only check: every condition of the gate, dated or not (a proof still to be recorded, a
   log source that must still reach back far enough), what counts as passing, and what to do when
   the data is too thin: say so and make no call.
5. What to report: `Tell me in plain words whether ...`, and the issue to post it on as a comment
   (that comment needs no approval).
6. The gate: `ask me with a picker before` closing, deleting, rolling back or changing a setting,
   and `propose a short numbered plan for my approval before building.` Any follow on from step 1
   comes here, as what to plan once Dan approves.

Project is the select option matching the repo. When none matches, leave it empty; the card gets a
step for it (step 8).

### 5. Check for an existing row

Read every row (follow `next_cursor`). A row whose Task or Description names the same issue is a
match. Show it beside the new draft and ask with a picker: update that row, add a second row, or
leave it. An update that changes Start Date also sets Reminder Saved to false, because the reminder
Dan set is for the old date.

### 6. Show Dan each draft

One AskUserQuestion per row, one question per call. Put any correction from step 2 in the question.
The recommended option carries a preview holding Task, Start Date, Project, reminder time and the
Description. Options: add it as drafted (Recommended), change the date, change the wording, skip it.
Nothing is written before Dan picks.

### 7. Write and read back

`slack_add_list_record` (or `slack_update_list_record` for an approved update). Keep the Link each
call returns. Then read the list back and confirm each Description holds no line break; if one does,
write it again joined into one line and read back again.

### 8. Pin the reminder card

`mcp__manual-steps__steps`, heading `Set reminders for the new list rows`. One step per written row:

- title: `Set a reminder for <Task>`
- url: the row's Link from step 7
- clicks: `Open the row`, `Set a reminder for <Weekday Month D> at <time> ET`, `Tick Reminder Saved`
- checked: `not-done`

For a row with Project left empty, put a step before it: `Add <repo> as a Project option`, url the
list, clicks `Open the Project column's options`, `Add <repo>`, `Pick <repo> on the new row`.

When Dan presses Done on a reminder step, read that row: Reminder Saved true is `checked`, anything
else is `not-done`.

### 9. Report

Say which rows were added or updated, each start date and reminder time, and every correction from
step 2, in plain words.

## Common mistakes

| Mistake | Instead |
|---|---|
| Counting the wait from the merge | Count from the deploy, change or comment that proves it went live |
| Writing a weekday from memory | Check it with `date` (an Oct 23 written as Thursday was a Friday) |
| Copying ET clock times across a clock change | Convert the end instant from UTC |
| Treating a ticked Reminder Saved as proof the date is right | The tick is Dan's, for the date the row had when he set it |
| Wrapped text becoming line breaks in the Description | Join it into one line, then read back |
| A prompt that leans on this session ("as discussed") | Name every fact, id and time the cold session needs |
