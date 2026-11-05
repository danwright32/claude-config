---
name: next-issue
description: Keep the GitHub issue loop moving without the user driving it. Use the moment work on an issue is finished (tests green, PR up), whenever the user says "what's next" or similar, or when a session starts with no active task in a repo with open issues. Closes out the current work (merge, deploy step) and presents the next issues as a picker.
---

# next-issue

Dan does not write code and should never have to pump the loop by typing "what's next". This skill is the loop: settle the finished work, then hand him the next choice as a picker. His standing spec, verbatim: "You can merge and then always suggest next issues."

## 1. Settle the current work

If there is an open PR for the work just finished:
1. Wait for CI and merge in one step, through the shared watcher, run from a checkout of the
   repository: `bash ~/.claude/hooks/lib/merge-when-ready.sh <pr> --squash --delete-branch` (match
   the repo's usual merge method if different). It updates a branch that is behind its base, waits
   for the head's checks and lessons review, and merges exactly that head, PINNED, only when every
   merge gate allows it, saying what it waits on as it goes. Never watch checks with gh's own
   `--watch` loop: the watcher follows the one polling policy every loop in the session shares
   (`hooks/lib/gh-poll.sh`, claude-config#1482), a wait that grows while nothing changes, a pause
   on GitHub's rate limit, and a cap on the session's looks a minute, so one session cannot trip
   the account's burst limit for every other one, as on 2026-10-22.
2. The pin is what stops a push that lands between the check reading and the merge being merged
   unjudged, and the merge gate refuses an unpinned merge for that reason (claude-config#345). The
   gate also refuses a branch that does not contain the base branch's current tip, because its
   green was earned against an older base and two green pull requests can merge into a red main
   (claude-config#766); the watcher updates the branch and waits for the new head's checks itself.
   Then CONFIRM it, because a merge command
   that exits 0 is not a merge. Ask `gh pr view <pr> --json state --jq .state` and treat anything but `MERGED` as
   not merged: say so, do not delete a branch, do not close the issue, and do not move on to the
   next one. Measured 2026-08-13 in Overture: `gh pr merge` failed with a transient
   `GraphQL: Something went wrong while executing your query`, and the script around it reported
   `merged PR #2609`, deleted the local branch of a PR that was still open, and exited 0. If the
   repo has its own merge script that already does this (Overture:
   `scripts/verify-and-merge-branch.sh`), prefer it. Never ask Dan to merge, and never ask him
   whether something merged when `gh pr view` can answer it.
3. If CI fails, fix it before moving on; that is still the current issue.
4. Close the issue if the merge did not auto-close it, with a one-line comment linking the PR.

## 2. Run the project's post-merge step

Check the project's CLAUDE.md and memory for a deploy step that does not happen automatically (for example PET requires a manually triggered build after merge). Run it and confirm it took effect. If the project has no such step, skip silently.

## 3. Pick the next issues

The ranking is a script, not a judgement: run it and offer exactly the picks it prints, in its order (claude-config#1505). It used to be prose, and nothing in the prose ever brought structural work forward.

1. List EVERY open issue and rank them in one step, from the repo's checkout:

       gh issue list --state open --limit 1000 --json number,title,labels,milestone | python3 ~/.claude/skills/next-issue/rank-next-issues.py --limit 1000 --milestone "<title of the milestone just shipped, if any>"

   Leave `--milestone` out when the finished work had none. Never rank a first page: on 2026-09-17 in PaperBoi a `--limit 50` listing of 90 open issues showed one p1 while fourteen more sat past the cut, and a p1 was reported as the only one. Exit 3 means the listing reached its limit and was cut off: raise both limits and run it again. Exit 2 means the listing could not be read: say so and rank nothing, never treat it as an empty backlog.
2. What the script does, so its picks can be explained. **Priority label first**: every issue carries one of `priority-p0` through `priority-p4` (`p0` broken now, `p1` do next, `p2` normal, `p3` nice to have, `p4` lowest; the full scale is in NAMING.md). A `p0` outranks everything, then **`lesson-sweep`** issues, oldest first, ahead of `p1`: each asks for this project to be checked for a defect a lesson recorded in another project (filed by `hooks/lib/lesson-fanout.sh`, titled `Lesson Lnnn sweep: ...`), and Dan's decision (2026-10-02) is that a known defect class that may already be live here outranks new work. Within a level: a **`user-facing`** issue first (somebody judged a real user would notice it; in Dan's projects `/pennie-dev-update`'s issue check applies it; it never crosses levels), then whatever continues the milestone just shipped, then `bug`, then oldest first.
3. **The structural slot.** When none of the picks carries `tech-debt`, `refactor` or `test-refactor` (the area check's own list), the last pick goes to the highest ranked open issue that does, marked `structural slot`. It never displaces a `p0`, a `p1` or a lesson sweep, and never adds a second structural pick. The `SLOT` line says which happened: `filled`, `already` (a structural issue is already a pick), `held` (every pick is p0, p1 or a lesson sweep) or `none` (no structural issue is open). Say a filled slot plainly in the picker, so Dan sees why a lower level is offered.
4. Show each pick's level in the picker so Dan can see he is being offered the right tier, and say which are `user-facing`. A `LOW` line means every pick is `p3` or below: say so plainly, because that is worth knowing.
5. An `UNLABELLED` line names issues with no priority label, which predate the rule and are ranked at the `p2` default meanwhile. Label each as you go, `gh issue edit <n> --add-label priority-pN`, choosing the level yourself (these are not Dan's to arbitrate, he has not read them; the scale is in `~/.claude/skills/milestone/NAMING.md`), then run step 1 again.

## 4. Present the picker and continue

Present the script's picks, all of them and in its order, with AskUserQuestion (label = issue number + short title, description = one plain-language line on what it is and why it is next; for the structural slot, that it is the structural work brought forward), passing `metadata: { source: "next-issue" }` so the picker manners mod knows it is a next issue offer. If that call is refused because Dan turned next issue pickers off for the session, give the same 3 as a plain numbered list instead. On selection, start immediately: read the issue, plan if non-trivial, then implement test-first per the global rules.

## 5. Loop

When that issue is finished, run this skill again from step 1 without being asked. Never end a working session by saying "we're done" while open issues remain; the session ends when Dan ends it or the picker goes unanswered.

## Status line

Every cycle ends with an explicit status before the picker: what merged (PR number), what deployed, and what state the branch is in (pushed and merged, awaiting CI, blocked by the test gate, or intentionally local).
