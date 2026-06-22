---
name: milestone
description: Create a GitHub milestone for a big feature and break it into one tracked issue per phase, all assigned to the milestone. Use as the escape hatch for tracking a feature that did NOT start from /plan-council or /plan-lite (those offer milestone creation automatically). User-invoked.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion
---

# milestone

Turn a big feature into a GitHub milestone with one issue per phase. This is the **ad-hoc** path — for work already in flight, or anything you didn't plan via `/plan-council` or `/plan-lite` (those two offer this automatically at the end of a run, using the same helper).

Use for: a feature worth tracking as a milestone. Not for single tasks — just open an issue for those.

## Steps

### 1. Frame  👤
In a short exchange, confirm:
- The **feature** (becomes the milestone title) and a one-paragraph **description**.
- The **GitHub repo** (`owner/name`). If you're in a project dir, infer it from `gh repo view --json nameWithOwner -q .nameWithOwner` and confirm.
- The **phases** — the chunks of work, each becoming one issue. If the user has a plan, derive phases from it; otherwise ask for the breakdown. Keep phases at feature-chunk altitude, not micro-tasks.
- Optional: a **due date** (ISO8601).

### 2. Build the plan JSON
Write a temp JSON file in the shape the helper expects:

    {
      "title": "<feature name>",
      "description": "<milestone description, markdown ok>",
      "due_on": "2026-09-01T00:00:00Z",
      "issues": [
        { "title": "Phase 1: <name>", "body": "<what this phase covers>" },
        { "title": "Phase 2: <name>", "body": "..." }
      ]
    }

`due_on` is optional; omit the key if there's no date. `issues` may be empty to create a milestone with no issues yet.

### 3. Preview  👤
Show the user the milestone title and the list of issue titles, and confirm before writing to GitHub — this creates real, outward-facing records. You can dry-run to show exactly what will be created:

    DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>

### 4. Create
On approval, run the helper for real:

    bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>

It prints `MILESTONE <url>` and one `ISSUE <url>` per phase. Relay the milestone URL to the user.

## Notes
- The same `create-milestone.sh` helper backs `/plan-council` and `/plan-lite`, so milestones look identical no matter which path created them.
- Requires `gh` authenticated (`gh auth status`). If milestone creation fails on permissions, tell the user rather than retrying blindly.
