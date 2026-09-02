---
name: milestone
description: Create a GitHub milestone for a big feature and break it into one tracked issue per phase, all assigned to the milestone. Use as the escape hatch for tracking a feature that did NOT start from /plan-council or /plan-lite (those offer milestone creation automatically). Use when a feature already in flight needs tracking, or when the user asks to open a milestone.
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion
---

# milestone

Turn a big feature into a GitHub milestone with one issue per phase. This is the **ad-hoc** path: for work already in flight, or anything you didn't plan via `/plan-council` or `/plan-lite` (those two offer this automatically at the end of a run, using the same helper).

Use for: a feature worth tracking as a milestone. Not for single tasks, just open an issue for those.

## Steps

### 1. Frame  (user)
In a short exchange, confirm:
- The **feature** (becomes the milestone title) and a one-paragraph **description**. The title NAMES the feature, with NO punctuation at all (a comma or colon is refused at any length) and at most 8 words (`Saved views`, `Bulk contact enrichment for scouted shows`); the narrative goes in the description. Never a narrative sentence, and never a category like `Accessibility` (categories are labels, since an issue can be two at once). The create path enforces that shape, and the full rule is in [NAMING.md](NAMING.md).
- The **GitHub repo** (`owner/name`). If you're in a project dir, infer it from `gh repo view --json nameWithOwner -q .nameWithOwner` and confirm.
- The **phases**: the chunks of work, each becoming one issue. If the user has a plan, derive phases from it; otherwise ask for the breakdown. Keep phases at feature-chunk altitude, not micro-tasks.
- Optional: a **due date** (ISO8601).

If the work is a standalone bug or chore that no feature ships with, it does not need a milestone of its own: use the repo's catch-all `Ungrouped` and just file the issue. See "Single issue" below.

### 2. Build the plan JSON
Write a temp JSON file in the shape the helper expects:

    {
      "title": "<feature name>",
      "description": "<milestone description, markdown ok>",
      "due_on": "2026-09-01T00:00:00Z",
      "priority": "p2",
      "labels": ["enhancement"],
      "issues": [
        { "title": "Phase 1: <name>", "body": "<what this phase covers>",
          "priority": "p1", "labels": ["enhancement", "onboarding"] },
        { "title": "Phase 2: <name>", "body": "...", "labels": ["tech-debt"] }
      ]
    }

Every issue needs a priority and at least one category label, either its own or the plan-level default. The helper refuses the whole plan and files nothing if any phase is missing either, because this is the one filing path the gates cannot see into.

`due_on` is optional; omit the key if there's no date. `issues` may be empty to create a milestone with no issues yet.

### 3. Preview  (user)
Show the user the milestone title and the list of issue titles, and confirm before writing to GitHub: this creates real, outward-facing records. You can dry-run to show exactly what will be created:

    DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>

### 4. Create
On approval, run the helper for real:

    bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>

It prints `MILESTONE <url>` and one `ISSUE <url>` per phase. Relay the milestone URL to the user.

## Single issue, not a whole feature
For one issue that just needs the right milestone (the common case, including the end-of-turn issue review), skip the plan JSON and use the resolver directly. Every issue-filing path shares it, and a PreToolUse gate blocks a `gh issue create` with no `--milestone`:

    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<milestone title>"                    # reuse only, never creates
    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<milestone title>" --create-approved --for-issues <n>  # only after the user approves, n >= 2
    bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "Ungrouped"                            # the catch-all, no approval needed

It prints `MILESTONE-EXISTS` or `MILESTONE-CREATED` plus a `MILESTONE-TITLE <title>` line. Pass that exact title to `gh issue create --milestone`, because `gh` matches milestones by name and a case variant is not found. Exit codes tell you what needs a human: `3` an identically named milestone exists but is closed, `4` the title closely resembles an open milestone (attach to that one instead of creating a twin), `5` nothing matched and creating was not approved, `6` the list could not be read, `8` the title is not shaped like a feature name.

`Ungrouped` is every repo's holding pen for standalone bugs and chores that belong to no feature, and it is the right answer far more often than a new milestone. It is exempt from the approval rule, so reach for it instead of inventing a milestone to satisfy the gate.

## Priority and category
Every issue also carries exactly one `priority-p0` to `priority-p4` label and at least one category label saying what it is about, each enforced by its own gate. Categories are unrestricted and multiple are expected: an accessibility fix that is also tech debt gets both. **Who picks the level matters**: if Dan reported the problem himself, ask him with an AskUserQuestion picker that carries the meanings in its option descriptions; if you found it, choose it yourself and say which. Both rules, the scale, and the label helper are in [NAMING.md](NAMING.md).

## Notes
- The same helpers back `/plan-council`, `/plan-lite` and `/production-ready`, so milestones look identical no matter which path created them, and re-running a plan reuses its milestone instead of duplicating it.
- `create-milestone.sh` aborts without filing any issue when the milestone needs a human decision (exit 3 or 4), because half a filed plan is worse than none.
- Requires `gh` authenticated (`gh auth status`). If milestone creation fails on permissions, tell the user rather than retrying blindly.
- Tests: `bash ~/.claude/skills/milestone/test-ensure-milestone.sh` and `test-create-milestone.sh`. Both use a fake `gh`, so they never touch a real repo.
