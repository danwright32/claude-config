---
name: migrate-issue-model
description: Bring an existing repo's issues and milestones onto the current organisation model (milestone = feature, category labels required, priority p0 to p4 on every issue). Surveys what is there, proposes every change for approval, then applies it resumably. User-invoked.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion
---

# migrate-issue-model

A repo organised before the current model needs three things fixed: milestones that
are categories or narrative sentences rather than features, issues with no priority,
and issues with no category label. This walks that migration.

**Read `~/.claude/skills/milestone/NAMING.md` first.** It is the source of truth for
the target state. Do not restate or reinterpret it here.

## Rules for this whole run

1. **Survey, propose, then apply. In that order.** Never mutate before Dan has seen
   the proposal. He has hundreds of issues and a wrong bulk edit is tedious to undo.
2. **Nothing is deleted without showing what loses it.** Deleting a label strips it
   from every issue carrying it, including closed ones, and that is not reversible.
3. **Assume it runs twice.** Write progress to `.migrate-issue-model.log` in the repo
   (gitignored, one line per change applied) and skip anything already recorded. A
   rate limit, a timeout, or Dan interrupting must not mean starting over or double
   applying.
4. **Report counts for every mutating step.** "Relabelled 34 issues" not "done".
5. **Rename in place, never close and recreate.** A rename keeps every issue link and
   every cross reference intact. Closing a milestone and opening a replacement orphans
   the history and forces the issues to be reassigned by hand.
6. The three PreToolUse gates apply to every `gh issue create` you run here, but note
   they do NOT see `gh issue edit`, so relabelling is on you to get right.

## 1. Survey, read only  👤

Establish the repo and read the current state. Use `--paginate` and explicit limits
everywhere: `gh issue list` defaults to 30 and would silently hide most of the repo.

    gh repo view --json nameWithOwner -q .nameWithOwner

    # every milestone, both states, with issue counts
    gh api --paginate "repos/<owner>/<name>/milestones?state=all&per_page=100" \
      --jq '.[] | "\(.number)\t\(.state)\t\(.open_issues)/\(.open_issues + .closed_issues)\t\(.title)"'

    # every open issue with its milestone and labels
    gh issue list --state open --limit 1000 \
      --json number,title,milestone,labels \
      --jq '.[] | "\(.number)\t\(.milestone.title // "NONE")\t\([.labels[].name] | join(","))\t\(.title)"'

    # the full label list, so you reuse names instead of inventing near synonyms
    gh label list --limit 200 --json name,description --jq '.[] | "\(.name)\t\(.description)"'

Then report to Dan, in plain language, before proposing anything:

1. How many open issues have no priority label, and how many have no category label.
2. Which milestones look like features (keep), which look like categories (retire),
   and which are narrative sentences (rename or retire). Quote the titles.
3. Which issues carry a retired `sev-*` or `severity:*` label, and how many.
4. Anything that does not fit those buckets, rather than forcing it into one.

## 2. Propose the milestone changes  👤

For each open milestone, one of four outcomes. Present the whole set in a single
table for approval, and say which outcome you chose for each and why:

| Outcome | When | How |
|---|---|---|
| **Keep** | It already names a feature that will complete | nothing |
| **Rename** | It IS a feature but the title is a narrative sentence | `gh api --method PATCH "repos/<o>/<n>/milestones/<num>" -f title="<feature name>" -f description="<the narrative that used to be the title>"` |
| **Retire** | It is a category, or work that can never complete | move its issues off it first, then close it |
| **Split** | It holds two unrelated features | ask Dan, do not decide this yourself |

Renaming carries the old title into the description, so nothing is lost. Check the new
title against the shape rule first, since the helper will refuse a bad one:

    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<proposed title>"

Exit 8 means the title is still not shaped like a feature name. Exit 4 means it would
duplicate an existing milestone, so merge into that one instead.

**Retiring a milestone, in this order**, or its issues become unreachable:

1. Make sure the catch-all exists:
   `bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "Ungrouped"`
2. Move every open issue off it, to a real feature milestone where one fits, otherwise
   to `Ungrouped`: `gh issue edit <n> --milestone "<target>"`
3. Convert what the milestone meant into a label on those issues. A milestone called
   `Accessibility` becomes the `accessibility` label on each of its issues. **This is
   the point of the migration**: the grouping is preserved, as a label that can coexist
   with others.
4. Only then close it: `gh api --method PATCH "repos/<o>/<n>/milestones/<num>" -f state=closed`
5. Verify it has zero open issues before closing, and say so.

Leave already closed milestones alone. They are history, they are not in Dan's way,
and renaming them rewrites a record of how the work actually shipped.

## 3. Propose the labels  👤

Ensure the priority labels exist, and see what rival labels are present:

    bash ~/.claude/skills/milestone/ensure-priority-labels.sh "<owner/name>"

**Priority.** Every open issue needs exactly one level. Dan cannot answer a picker per
issue at this volume, so propose the whole set at once: group the issues by the level
you are proposing, show him the groups (numbers and titles), and ask him to correct the
exceptions rather than confirm every one. Map any existing signal rather than guessing
from scratch:

    sev-high / severity:critical  ->  priority-p0 or priority-p1, judged by whether it is broken in production now
    sev-medium / severity:high    ->  priority-p1 or priority-p2
    sev-low / severity:medium     ->  priority-p2 or priority-p3
    severity:low                  ->  priority-p3
    no signal at all              ->  priority-p2, the default for real work

State plainly that this is a bulk judgement on issues Dan has not re-read, and that
`p2` is doing a lot of work. It is better than leaving them unlabelled, and any single
one is one edit to change.

**Category.** Every open issue needs at least one. Derive it, do not invent it: from
the milestone it used to sit under, from its existing labels, from its title. Reuse a
label the repo already has over any near synonym of it. Only create a label when
nothing existing covers the issue.

Apply both in one edit per issue, so a failure halfway leaves fewer half done issues:

    gh issue edit <n> --add-label "priority-p2,accessibility,tech-debt"

## 4. Retire the old severity labels  👤

Only after every issue carrying one has a priority. Then, separately and explicitly:

1. List exactly which issues would lose a label, open AND closed, and how many.
2. Ask Dan with **AskUserQuestion**: delete them, or leave them in place.
3. On approval only: `gh label delete "<name>" --yes`

Deleting is not reversible and it silently rewrites closed issues too, so it never
happens as a side effect of anything else in this migration.

## 5. Verify, and report  👤

Re-run the survey queries from step 1 and prove the migration landed, rather than
asserting it:

1. Count open issues with no priority. It should be zero. If not, name them.
2. Count open issues with no category. It should be zero. If not, name them.
3. Confirm no open milestone is a category or a narrative sentence, listing what is
   now open.
4. Confirm every issue moved off a retired milestone actually has its new one.

Then give Dan a plain language summary: what was renamed, what was retired and where
its issues went, how many issues were relabelled, and anything you deliberately left
alone with the reason.

## Notes

1. This is user invoked and mutating, so it never runs unprompted.
2. It does not touch pull requests, only issues.
3. If a step fails partway, the log from rule 3 means a re-run resumes. Say what
   failed and what is left rather than reporting a clean run.
4. Run it per repo. Do not try to migrate several repos in one pass: the label
   vocabularies differ, and a single approval covering four repos is not an approval.
