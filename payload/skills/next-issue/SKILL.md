---
name: next-issue
description: Keep the GitHub issue loop moving without the user driving it. Use the moment work on an issue is finished (tests green, PR up), whenever the user says "what's next" or similar, or when a session starts with no active task in a repo with open issues. Closes out the current work (merge, deploy step) and presents the next issues as a picker.
---

# next-issue

Dan does not write code and should never have to pump the loop by typing "what's next". This skill is the loop: settle the finished work, then hand him the next choice as a picker. His standing spec, verbatim: "You can merge and then always suggest next issues."

## 1. Settle the current work

If there is an open PR for the work just finished:
1. Check CI yourself: `gh pr checks <pr> --watch` (run in the background if slow; report elapsed progress, never a silent wait).
2. When green, merge it yourself: `gh pr merge <pr> --squash --delete-branch` (match the repo's
   usual merge style if different), and then CONFIRM it, because a merge command that exits 0 is
   not a merge. Ask `gh pr view <pr> --json state --jq .state` and treat anything but `MERGED` as
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

1. `gh issue list --state open --limit 50` in the current repo.
2. Rank by **priority label first**: every issue carries one of `priority-p0` through `priority-p4` (`p0` broken now, `p1` do next, `p2` normal, `p3` nice to have, `p4` someday). A `p0` outranks everything. Within a level, prefer in this order: a **`user-facing`** issue (see below), then whatever continues the feature just shipped (its milestone), then other bugs affecting live behavior, then value for effort.
3. **`user-facing` outranks within its level.** The label means somebody judged that a real user would notice this, recorded durably rather than re-argued each time. In Dan's projects it is applied by `/pennie-dev-update`'s issue check, which reads issue bodies to decide. Treat it as settled evidence, not a hint: a labelled issue beats an unlabelled one at the same priority. It never crosses levels, so a `user-facing` p2 still loses to any p1. If the repo has no such label, this rule is simply inert.
4. Pick the top 3 candidates. Show each one's level in the picker so Dan can see he is being offered the right tier, and say so plainly if the top candidates are only `p3` and below, because that is worth knowing. Say which candidates are `user-facing`, so he can see why they rose.
4. An issue with no priority label predates the rule. Do not silently rank it last: `gh issue edit <n> --add-label priority-pN` as you go, choosing the level yourself (these are not Dan's to arbitrate, he has not read them). The scale is in `~/.claude/skills/milestone/NAMING.md`.

## 4. Present the picker and continue

Present the 3 candidates with AskUserQuestion (label = issue number + short title, description = one plain-language line on what it is and why it is next). On selection, start immediately: read the issue, plan if non-trivial, then implement test-first per the global rules.

## 5. Loop

When that issue is finished, run this skill again from step 1 without being asked. Never end a working session by saying "we're done" while open issues remain; the session ends when Dan ends it or the picker goes unanswered.

## Status line

Every cycle ends with an explicit status before the picker: what merged (PR number), what deployed, and what state the branch is in (pushed and merged, awaiting CI, blocked by the test gate, or intentionally local).
