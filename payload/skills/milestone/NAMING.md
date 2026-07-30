# Milestones, categories and priority

The single source of truth for how a filed issue is organised: which milestone it
belongs to, what it is about, and how urgent it is. Every path that files an issue
(`/milestone`, `/plan-council`, `/plan-lite`, `/production-ready`, `/next-issue`,
the end of turn issue review) points here instead of restating the rules, so there
is one copy to change.

Three separate axes. Keeping them separate is the whole point.

| Axis | Mechanism | How many per issue | Enforced |
|---|---|---|---|
| Which feature does this ship with | Milestone | Exactly one | Yes, a gate |
| What is it about | Category labels | At least one, as many as fit | Yes, a gate |
| How urgent is it | Priority label | Exactly one | Yes, a gate |

All three are required. The category gate checks that a category **exists**, never
which one it is: Dan restricted the priority levels deliberately and left the
categories open, in his words, "it does need category on every issue, and it can be
multiple. I just don't want to restrict what those categories are."

## Why this file exists

On 2026-07-30 Dan opened his milestone list and found this:

    Let Dan act where he is looking
    A queue whose order and contents you can trust
    One store, one truth
    Trustworthy local verification: tests, guards, and the build
    Say it once, and only when Dan can act on it
    One paid contact answer, recorded and reused correctly

Every one of those is a decent sentence and a bad milestone. They read as essay
headings, so the list could not be scanned, and none of them says what feature the
work belongs to. Nothing in the config said what shape a title should be, so each
session invented a theme.

The same day he found the priority labels applied to some issues and not others,
with two rival scales (`sev-*` and `severity:*`) alongside them, so the backlog
could not be read by urgency either.

## Milestone: the feature that ships

A milestone is **an overarching feature**, and its issues are what has to be
finished for that feature to ship. It closes when the feature is done. That is the
whole test: if it can never be completed, it is not a milestone.

The title names the thing being built:

    Saved views
    Salesforce sync v2
    Bulk contact enrichment
    Queue windowing
    Node test coloring in edit mode

The shape, concretely:

| Rule | Why |
|---|---|
| At most 6 words, at most 48 characters | A name that needs a clause is a description, not a name |
| No `,` `;` `:` `.` `!` `?` | Sentence punctuation holds clauses together, and a name has no clauses |
| No pronouns, copulas, modals or relative pronouns (is, are, can, you, he, where, when, that) | Those words describe rather than name |
| No person's name | A milestone is about the work, not about who noticed it |

**The narrative still matters, and it goes in the milestone description**, which is
where the detail belongs and where GitHub actually shows it:

    Title:        Node test coloring in edit mode
    Description:  Failed node-test styling persists into view mode, the wider
                  code-panel default never applies, and there is no way to clear
                  test-run coloring. Ships when a test run's colour is correct in
                  both modes and clearable.

Nothing is lost, and the list becomes scannable.

### What is NOT a milestone

A **category** is not a milestone. `Accessibility`, `UI/UX`, `Monitoring and
alerting`, `Analytics`, `Tech debt and CI hygiene` never complete, and an issue can
hold only one milestone while it is routinely two categories at once (an
accessibility fix that is also tech debt). Those are labels. See below.

### The catch-all: `Ungrouped`

Most issues are standalone bugs and chores belonging to no feature. They still need
a milestone, so every repo has one holding pen, titled `Ungrouped`.

It is exempt from the approval rule: `ensure-milestone.sh` creates it without asking,
because choosing it is not a decision anyone needs to make. Requiring approval there
is what caused the original problem, a session inventing a milestone on the spot to
satisfy the gate. The exemption is an exact title match, so `Ungrouped work and
other things` is an ordinary title and still needs approval.

Its progress bar never completes. That is expected: it is a holding pen, not a
feature.

### Who creates a milestone

**Creating a milestone is a planning decision.** It happens in `/plan-council`,
`/plan-lite` or `/milestone`, where a feature is being planned and its phases become
the issues. Nowhere else.

Every other path that files an issue (the end of turn review, `/next-issue`,
`/production-ready`, anything typed mid flow) has exactly two choices and no third:

1. An existing open milestone, when the work ships with that feature.
2. `Ungrouped`, the catch-all.

It never makes sense to open a milestone for a one-off issue. A milestone with one
issue in it is not a feature, it is a label with extra steps. If the resolver exits
5, that means the title matches nothing: the answer is `Ungrouped`, not a request to
approve a new milestone.

### Resolving a milestone

Always prefer an existing open milestone. Resolve through the helper, which reuses a
match, refuses to create a near duplicate, and never creates without approval
(except the catch-all):

    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<title>"                    # reuse only
    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<title>" --create-approved  # after approval
    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "Ungrouped"                  # catch-all, no approval

Pass the exact title it reports on the `MILESTONE-TITLE` line to
`gh issue create --milestone`, because `gh` matches milestones by name and a case
variant is not found.

The shape rule guards **creation only**. Dan kept the narrative milestones he
already had, so an issue must still be able to attach to one: a lookup is never
shape checked.

## Categories: labels

What an issue is *about* is a label. **Every issue needs at least one**, and carries
**as many as genuinely apply**. An accessibility fix that is also tech debt gets both.
That is the whole reason categories are labels rather than milestones.

A gate blocks any `gh issue create` that has no label other than its priority. It does
not check which label, only that one is there.

Aim for **one type label plus every area label that fits**.

**Type**, what kind of work it is. Pick exactly one:

    bug              something is broken
    enhancement      new or improved behaviour
    tech-debt        works, but the way it is built is a liability
    documentation    docs, comments, READMEs

**Area**, what part of the product or practice it touches. Pick all that apply:

    accessibility      ui-ux              performance
    security           data-integrity     error-handling
    monitoring         analytics          ci-hygiene
    test-coverage      onboarding         deployment

This is a **starting list, not a closed one.** Two rules govern going outside it:

1. **Reuse what the repo already has, first.** The repos already carry
   `accessibility`, `ux`, `tech-debt`, `frontend`, `canvas`, `data-pipeline`, `bug`,
   `enhancement`. If the repo says `ux` and this list says `ui-ux`, use `ux`: a
   second name for a category that already has one is worse than an imperfect fit.
   Read the repo's labels before you decide (`gh label list --limit 100`).
2. **Add a new label when nothing above covers it.** Do not force a bad fit and do
   not leave the issue bare. Create it first, then apply it:

       gh label create <name> --color <hex> --description "<what it means>"

   Keep new names short, kebab-case, and reusable across issues. A label used once
   is a note, not a label.

Never apply `claude-suggested` or any label attributing the issue to Claude or AI.
Never apply `sev-*` or `severity:*`: priority is the only urgency scale.

The vocabulary above is guidance, and the presence of a category is enforced. Those
are different things on purpose: a closed list would go stale and start forcing bad
fits, while a missing category leaves an issue that can never be found by area.

## Priority: p0 to p4

Every issue carries exactly one priority label. This is the only urgency scale.

| Label | Meaning |
|---|---|
| `priority-p0` | Broken now, drop everything |
| `priority-p1` | Important, do next |
| `priority-p2` | Normal, the default for real work |
| `priority-p3` | Nice to have |
| `priority-p4` | Someday, maybe never |

If a repo does not have the labels yet, create them first. Idempotent, safe to
re-run, and it reports any leftover rival labels without deleting them:

    bash ~/.claude/skills/milestone/ensure-priority-labels.sh "<owner/name>"

### Who picks the level

This is the part that is easy to get wrong, so it is explicit.

**When Dan reported it himself**, meaning he was looking at the product, noticed
something, and told you about it: **ask him**. Use an `AskUserQuestion` picker and
put the meaning of each level in its option description, so the scale is in front of
him as he chooses rather than something he has to remember. Do not guess on his
behalf and do not ask in prose.

A picker holds at most 4 options, so offer p0, p1, p2 and p3, and say in the
question text that p4 (someday, maybe never) is available under Other. Those four
are the realistic range for something he just noticed.

    Question: "How urgent is this? (p4, someday, is available under Other)"
      priority-p0   Broken now, drop everything
      priority-p1   Important, do next
      priority-p2   Normal, the default for real work
      priority-p3   Nice to have

Ask once per batch, not once per issue: if he reported three things in one message,
one picker per issue is worse than a single pass where each option is an issue and
he sets the level for each.

**When you found it yourself**, meaning an audit, a sweep, the end of turn issue
review, or something you noticed while working: **choose the level yourself** and
say in one line which you chose and why. Do not make him arbitrate a backlog item
he has not seen. Default to `priority-p2` unless there is a reason to go up or down.

### The retired scales

`sev-low`, `sev-medium`, `sev-high` and `severity:*` are retired. Priority replaced
them on 2026-07-30, because an issue carrying both said the same thing twice and an
issue carrying only a severity said nothing about when it would be done.

Do not apply them to new issues. Do not delete the existing ones without asking:
removing a label strips it from every issue that carries it, so that is Dan's call.
`ensure-priority-labels.sh` reports any it finds.

## What is enforced, and how to override it

| Rule | Enforced by | Visible override |
|---|---|---|
| An issue has a milestone | `~/.claude/hooks/require-milestone-on-issue.sh` (PreToolUse) | `SKIP_MILESTONE_CHECK=1 <command>` |
| An issue has a priority | `~/.claude/hooks/require-priority-on-issue.sh` (PreToolUse) | `SKIP_PRIORITY_CHECK=1 <command>` |
| A new milestone title names a feature | `ensure-milestone.sh`, on the create path only | `ALLOW_ANY_MILESTONE_TITLE=1 <command>` |

Every override is visible in the command itself, so it cannot happen by accident or
go unnoticed in the transcript. Explain to Dan why you are using one, first. An
override is good for that one command, never standing permission.

Tests: `test-ensure-milestone.sh`, `test-ensure-priority-labels.sh`,
`test-create-milestone.sh` in this directory, and
`test-require-milestone-on-issue.sh`, `test-require-priority-on-issue.sh` in
`~/.claude/hooks/`. All use a fake `gh`, so none of them can reach a real repo.
