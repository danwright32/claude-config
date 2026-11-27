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

Every issue needs a priority and at least one category label, either its own or the plan-level default. The helper refuses the whole plan and files nothing if any phase is missing either, because this is the one filing path the gates cannot see into. A category label the repo does not have yet is created once the milestone check has passed and before the milestone is touched, so a new label needs no manual step, as long as it is a short kebab case name; a plan that is refused creates nothing.

Each phase's `body` carries a `## Must always be true` section: the rules that phase must keep true, and what keeps each one true. What the section holds is written in one place, `~/.claude/skills/milestone/MUST-ALWAYS-BE-TRUE.md`, with a command that checks a body; a phase with no such rule says so there, with its reason. Nothing refuses a phase without the section, so check each body before the preview.

`due_on` is optional; omit the key if there's no date. `issues` may be empty to create a milestone with no issues yet.

**A feature with a settled design** (claude-config#1290): when the design rounds skill has produced a settled design file for this feature, add `"design": "<its absolute path>"` to the plan. The helper then reads the decision map inside that file (the design rounds skill's deliverable says where it lives and how it is written) with `design-rounds/check-decision-map.py`, and files nothing (exit 11) while any decision has no requirement and no stated reason it needs no code, or any requirement the map names is named by no issue as `Requirement <number>` in its title or body. So name each phase's requirements that way. The design must be committed in the app's repository (a file in no git checkout is refused, exit 11), since the score names it by its path there. A plan that passes gets one more issue at its end, **"Match the settled design"** (claude-config#1364): the milestone is done when the build matches the design at 100% on both halves of the design match score (every decision in the map met by its check, every frame's picture matching at its own width), not when its issues close. A hook, `design-score-gate.sh`, refuses to close that issue, or the milestone, below 100%, and every other issue in the plan is told its pull request posts the current score with `design_score.py post`. A plan that writes its own Match issue keeps its words, with the design mark added. Leaving `design` out of a plan whose feature has a settled design is how 35 settled decisions shipped with no owner on 2026-10-17.

**A repository that announces to agents** (claude-config#3669): where the repository's entry in this Mac's dev update registry names an announcements channel (`node ~/.claude/hooks/lib/dev-update-registry.js announce-channel <owner/name>` prints a `channel`), the plan must carry `"announce"`, and the helper files nothing without it (exit 12). Its value is `"yes"`, `"no"` or `"unasked"`, and it comes from one place: Dan's answer to the picker feature discovery asks (`~/.claude/skills/feature-discovery/SKILL.md`, item 7). He answered `Announce it`: `"yes"`. He answered `Not announcing`: `"no"`. Nobody asked him, because the milestone did not come from feature discovery (alert fixes, an audit, a feature already in flight): `"unasked"`, never a guess at what he would say. The helper takes `"yes"` and `"no"` only when this Mac's record holds that as his last answer about the feature, and refuses `"unasked"` when the record holds an answer. His answer is read into the record by a hook when a Bash call runs `create-milestone.sh` by name in the session that asked him, so run the helper as a command of its own there. It is found by one name only (Dan, by picker, 2026-11-26): name the feature in the picker exactly as the milestone will be titled, the plan's `title`, letter case and spacing aside. His answer under any other name does not count for the milestone, the plan no longer takes `announce_feature` (a plan carrying it is refused, exit 12), and if the title changes after he answered, he is asked again under the new title. The milestone's description then carries one line, `Announce to agents: yes (Dan answered "Announce it" on <date>)`, `Announce to agents: no (...)` or `Announce to agents: not asked yet`, written into an existing milestone's description too. The merge gate reads it: the pull request that closes the last open issue of a milestone saying yes is refused under any label but `changelog/announce`, until Dan declines in a picker. For a repository that does not announce, leave `announce` out.

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

An issue that asks for something to be built carries the same `## Must always be true` section as a phase does (step 2).

`Ungrouped` is every repo's holding pen for standalone bugs and chores that belong to no feature, and it is the right answer far more often than a new milestone. It is exempt from the approval rule, so reach for it instead of inventing a milestone to satisfy the gate.

## Priority and category
Every issue also carries exactly one `priority-p0` to `priority-p4` label and at least one category label saying what it is about, each enforced by its own gate. Categories are unrestricted and multiple are expected: an accessibility fix that is also tech debt gets both. **Who picks the level matters**: if Dan reported the problem himself, ask him with an AskUserQuestion picker that carries the meanings in its option descriptions; if you found it, choose it yourself and say which. Both rules, the scale, and the label helper are in [NAMING.md](NAMING.md).

## Notes
- The same helpers back `/plan-council`, `/plan-lite` and `/production-ready`, so milestones look identical no matter which path created them, and re-running a plan reuses its milestone instead of duplicating it.
- `create-milestone.sh` aborts without filing any issue when the milestone needs a human decision (exit 3 or 4), when a settled design's decision map does not hold (exit 11), or when what the plan says about announcing the feature cannot stand (exit 12, claude-config#3669), because half a filed plan is worse than none. Exit 12 is for a repository that announces whose plan carries no `announce` value or one that is not `yes`, `no` or `unasked`, a `yes` or `no` the record holds no picker answer of Dan's for, an `unasked` where the record holds his answer, a plan that still carries `announce_feature` (one name only: the feature is named in the picker as the milestone is titled), a record of his answers that cannot be read, a registry that cannot be read (so whether the repository announces cannot be told), and a line about announcing that could not be written into the milestone's description and read back from GitHub.
- Requires `gh` authenticated (`gh auth status`). If milestone creation fails on permissions, tell the user rather than retrying blindly.
- Tests: `bash ~/.claude/skills/milestone/test-ensure-milestone.sh` and `test-create-milestone.sh`. Both use a fake `gh`, so they never touch a real repo.
