---
name: check-later
description: Use when this session needs work done at a later date or time (a canary week, an N day gate, data still accumulating, a limit to put back once a rolling window clears, "we'll check this in a week"), when Dan types /check-later, or when the end of turn hook's CHECK LATER pointer sends you here, to put that work on his Slack list "Dan Projects To Do List" as a row a fresh session can run, and to hand him a card for setting its reminder.
trigger: /check-later
---

# /check-later

Turns each thing this session left waiting on a date into a row on Dan's Slack list, with a one line
prompt a brand new Claude Code session can run cold on the start date, then pins a card telling Dan
to set the reminder. Dan types nothing after the command: everything comes from this session.

## Started by the session itself

A session that knows a step has to be taken at a later time starts this skill itself, through the Skill
tool, at the moment it knows, rather than handing Dan the command to type (Dan, 2026-11-09: "there's
no reason you shouldn't be able to start that yourself", claude-config#2532).

A session may schedule any step this session itself found it needs, at a known later date or a
known time later the same day: a canary or gate to read, data to check once it has accumulated, a
setting to put back once a window clears (a daily spend limit restored when yesterday's spend leaves
its rolling 24 hour window, some hours from now). Each becomes a row on the list below, run cold by a
fresh session at its start time.

A session may not:

- write a row Dan has not picked. Step 6 still shows each draft as its own question, and Nothing is
  written before Dan picks, whoever started the skill.
- keep a timer running in the session (a one shot `CronCreate`, a sleep loop) in place of a row. Such
  a timer dies with the session, and Dan does not want one held open.
- schedule a change for the cold session to make without asking. The row's prompt keeps step 4's
  gate: the cold session reads and reports, and asks Dan with a picker before it closes, deletes,
  rolls back or changes a setting.
- tick Reminder Saved, or schedule anything that is not waiting on a date or time (step 1).

The end of turn hook stands down on a turn where the session started this skill, as it does when Dan
typed it.

## Started by the end of turn hook

`check-later-nudge.sh` ends a turn that left a check waiting on a later day (a one shot reminder,
a project memory naming a coming date, or a promise to check again on a later day) with a CHECK
LATER pointer to this file, so Dan no longer has to remember to type the command. Do this before
any SESSION REFLECTION or ISSUE REVIEW in the same stop, so these questions come first. Then:

- An item step 5 matches is already on the list: leave it out, with no question and no line about
  it.
- An item step 1 finds is not waiting on a date gets one line saying so, and no row.
- Everything else runs as when Dan types it: step 6 still shows each draft row as its own question,
  and nothing is written before Dan picks.

The hook only points here; it never writes a row, and it stands down on a turn where Dan already
ran /check-later, the session already started this skill, or a row was already written.

## The list

**Dan Projects To Do List**, list id `F0CB5JMEM2P`, in Pennie's Slack
(https://pennieinternalteam.slack.com/lists/T06GHEHDWCT/F0CB5JMEM2P).

| Column | Key | What goes in it |
|---|---|---|
| Task | `name` | Short imperative naming the issues: `Check the first Salesforce canary (#2173)` |
| Status | `people` | `Waiting` when written; the cold session moves it to `In progress`, then `Done` (step 4, part 7) |
| Description | `Col07QBFU85SB` | The one line prompt (step 4) |
| Start Date | `Col0CAWEL5RFH` | `YYYY-MM-DD` |
| Project | `Col0CBFHLQX44` | A select: read its options, never assume them |
| Reminder Saved | `Col0CBDTLART3` | Dan ticks it himself. Never set it to true |

Start with `slack_read_list` on `F0CB5JMEM2P` and `schema_only: true`. If that fails (the connected
Slack is not Pennie's, or has no access), stop: say the connected Slack cannot open the list, and add
nothing. If a column above is missing or renamed, or Status has no `Waiting`, `In progress` or
`Done` option (spelled exactly so), stop and say which.

## Steps

### 1. Find the waiting items

Read this session's conversation. A waiting item is work that cannot start until a known date, or
a known time later today: a canary or trial week ending, a gate of N days without a hit, data that
must accumulate, a change that must bake, a rolling window that must clear. For each, note the repo, the issue numbers, what unlocks it and what to do once it does.
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

A wait that ends on a weekend or in the evening keeps the exact ET time it ends, on that day (Dan,
2026-10-22): a gate ending Sunday at 7:05 PM ET gets a Sunday 7:05 PM ET reminder. It is
never moved to the next working morning. Say in the question (step 6) that the time is the exact
end, so Dan can change the date there if he wants it later.

### 4. Write the row

The Description is ONE line with no line breaks, in plain words, with no dashes as punctuation, and
at most 600 characters (about 90 words), so it reads whole in the preview beside the options in
step 6 and in the list without opening the row. 600 is a chosen number, not a measured width:
drafts of about 300 words (some 1,800 characters) overflowed both. Its parts, in this order:

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
7. Close the row, so a finished check never sits at `Waiting` reading like one nobody ran: the cold
   session sets this row's Status to `In progress` with `slack_update_list_record` when it reports
   the check and starts work, and to `Done` only once every follow on Dan approved in it is finished
   (Dan, 2026-10-23). It names the row by its record id and the list id, never by its Task, because
   a text match can find no row or the wrong one: `Then with slack_update_list_record set row
   <record id> on list F0CB5JMEM2P, column people, to In progress as you report, and to Done once
   every follow on I approved is finished (no call means it stays In progress).` The record id does
   not exist until the row is added, so the draft carries `<record id>` and step 7 fills it in; an
   update to an existing row (step 5) uses that row's id from the start.

When the draft runs past 600 characters, the detail moves into a comment on the issue, never into a
longer Description: the facts of part 3 (times, ids, tables, numbers, the source to read instead of
a purged one), the full conditions of part 4 and any follow on plan. The comment opens with
`Check later, <Start Date>:` and the Description keeps parts 1, 5, 6 and 7 whole, names that comment
by its heading and date in part 2, and keeps of parts 3 and 4 only what still fits. Count with
`printf %s "<description>" | wc -m`, with `<record id>` replaced by the longest record id step 5
read, since the filled in id is what the 600 has to hold.

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
Description, and the comment from step 4 when there is one. A new row's Description shows
`<record id>` where its own id will go, and the question says step 7 fills it in. Options: add it as drafted (Recommended), change the date, change the wording, skip it.
Nothing is written before Dan picks.

### 7. Write and read back

Post the step 4 comment first, where there is one (`gh issue comment <n> --body-file <file>`), so the
row never names a comment that is not there. Then `slack_add_list_record` (or
`slack_update_list_record` for an approved update). Keep the Link and the record id each call
returns. For a new row, replace `<record id>` in its Description with the record id the add
returned and write that Description again with `slack_update_list_record`, so the cold session can
find the row it has to close. Then read the list back and confirm each Description holds no line
break and at most 600 characters, and names its own record id (not the placeholder, not another
row's); if one does not, join it into one line, move more into the comment or put in the right id,
write it again and read back again.

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
| A 300 word Description | At most 600 characters; the facts go in a comment on the issue it names |
| Moving a Sunday evening end to Monday 9:00 AM | Keep the exact ET time the wait ends |
| A prompt that leans on this session ("as discussed") | Name every fact, id and time the cold session needs |
| A Description that ends at the report, so the row stays `Waiting` after the work is done | Part 7: the cold session sets `In progress` as it reports, `Done` once every approved follow on is finished |
| Naming the row for the cold session by its Task | Its record id, written in after the add and read back |
