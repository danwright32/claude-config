# Milestone titles and issue priority

The single source of truth for two things every filed issue depends on: what a
milestone is called, and how urgent the issue is. Every path that files an issue
(`/milestone`, `/plan-council`, `/plan-lite`, `/production-ready`, `/next-issue`,
the end of turn issue review) points here instead of restating the rules, so there
is one copy to change.

Both rules are also enforced by code, because a rule that lives only in a prompt is
a hope. The enforcement is listed at the bottom.

## Why this file exists

On 2026-07-30 Dan opened his milestone list and found this:

    Let Dan act where he is looking
    A queue whose order and contents you can trust
    One store, one truth
    Trustworthy local verification: tests, guards, and the build
    Say it once, and only when Dan can act on it
    One paid contact answer, recorded and reused correctly

Every one of those is a decent sentence and a bad milestone. They read as essay
headings, so the list cannot be scanned, two of them overlap without it being
visible, and none of them tells you what kind of work is inside. Nothing in the
config said what shape a title should be, so each session invented a theme.

The same day he found the priority labels applied to some issues and not others,
with two rival scales (`sev-*` and `severity:*`) sitting alongside them, so the
backlog could not be read by urgency either.

## Milestone titles: name a category

A milestone groups a **category of work** that stays true for months. Its title is
a short noun phrase naming that category. Nothing else.

Dan's own examples of the right shape:

    Accessibility
    UI/UX
    Monitoring and alerting
    Analytics
    Tech debt and CI hygiene

Others that fit the same mould: `Data integrity`, `Security and privacy`,
`Performance`, `Reliability`, `Docs`, `Onboarding`, `Error handling`,
`Canvas & editor`, `Test coverage`.

The shape, concretely:

| Rule | Why |
|---|---|
| At most 5 words, at most 48 characters | A category name that needs a clause is not a category |
| No `,` `;` `:` `.` `!` `?` | Sentence punctuation holds clauses together, and a name has no clauses |
| No pronouns, copulas, modals or relative pronouns (is, are, can, you, he, where, when, that) | Those words describe rather than name |
| No person's name | A milestone is about the work, not about who noticed it |

**The narrative still matters. It goes in the milestone description**, which is
where the detail belongs and where GitHub actually shows it. So the milestone that
used to be titled "One store, one truth" becomes:

    Title:        Data integrity
    Description:  Duplicates with no way out, retired columns nobody reads,
                  write-only snapshot fields, and no record of what the nightly
                  scout did to which show.

Nothing is lost, and the list becomes readable.

### Choosing between an existing milestone and a new one

Always prefer an existing open milestone. Resolve through the helper, which reuses a
match, refuses to create a near duplicate, and never creates without approval:

    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<title>"                    # reuse only
    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<title>" --create-approved  # after approval

Pass the exact title it reports on the `MILESTONE-TITLE` line to
`gh issue create --milestone`, because `gh` matches milestones by name and a case
variant is not found.

The shape rule guards **creation only**. Dan kept the narrative milestones he
already had, so an issue must still be able to attach to one: a lookup is never
shape checked.

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
| A new milestone title is a category | `ensure-milestone.sh`, on the create path only | `ALLOW_ANY_MILESTONE_TITLE=1 <command>` |

Every override is visible in the command itself, so it cannot happen by accident or
go unnoticed in the transcript. Explain to Dan why you are using one, first. An
override is good for that one command, never standing permission.

Tests: `test-ensure-milestone.sh`, `test-ensure-priority-labels.sh`,
`test-create-milestone.sh` in this directory, and
`test-require-milestone-on-issue.sh`, `test-require-priority-on-issue.sh` in
`~/.claude/hooks/`. All use a fake `gh`, so none of them can reach a real repo.
