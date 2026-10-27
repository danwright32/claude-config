---
name: architecture-pass
disable-model-invocation: true
description: Use when Dan types /architecture-pass to look over one repository for structural problems no single pull request could see (chains every new job must edit, helpers each caller drives by hand, one fact in two homes, multi step writes made safe several ways), and to propose issues for them.
trigger: /architecture-pass
---

# /architecture-pass

A read only pass over one repository that finds structural problems nobody has filed, and proposes
issues for them. It changes no code. It files only what Dan picks.

It exists because a pass run by hand on two work repos on 2026-10-22 found problems no pull request
could see, the largest with no issue at all. The area check mod (#1506) only knows what has been
filed; this pass is what files the problems nobody saw.

## How it runs, settled

Settled when #1504 was built (2026-10-27), taking the recommended answers to its two open questions:

- **It runs only when Dan starts it.** It never runs unattended: no schedule, no overnight run, so
  it never spends anything he did not start.
- **Monthly, suggested from a date kept on this Mac.** Each repo's last pass is recorded locally
  (`~/.claude-architecture-pass/last-pass.json`, outside `~/.claude` so the sync never carries or
  deletes it), and the pass opens by saying how long it has been.

The repo is the one the session is in, unless Dan names another. Below, `<repo>` is its checkout's
absolute path, `<owner/name>` its GitHub name, and `<scratch>` is `architecture-pass/` inside this
session's scratchpad (make it first).

## 1. Say when the last pass was

```bash
python3 ~/.claude/skills/architecture-pass/measure.py last-pass <repo>
```

Tell Dan the sentence it prints. If the pass is not due, say so in one line and carry on: he
started it on purpose.

## 2. Measure (deterministic, in measure.py)

Fetch first, so the counts are of what shipped and not of a stale local main:

```bash
git -C <repo> fetch --quiet origin
```

```bash
python3 ~/.claude/skills/architecture-pass/measure.py hotspots <repo> > <scratch>/hotspots.json
python3 ~/.claude/skills/architecture-pass/measure.py kinds <repo> > <scratch>/kinds.json
```

Both read the last 90 days of origin's default branch and say which ref and sha they read; a
`ref_note` means they fell back to HEAD, which must be said in the report. Prose, docs and
lockfiles are left out.

Every count comes from these two files. Never count fixes with `git log --grep`: it matches commit
bodies as well as titles, and on 2026-10-22 it turned one file's 5 real fixes into 59. measure.py
reads titles only.

## 3. Read the measurements (judgement)

**Kinds are the signal, not sizes.** `kinds.json` sorts every fix title into a kind by rule. A kind
that recurs (3 or more in the window, and more so when its `paths` sit in one area) is a candidate
finding. Two kinds need reading before they count:

- `stop-title` is kept out of the fix total because "Stop X" is a fix in some repos and a new
  feature in others (in claude-config it is mostly a fix; in one work repo it was mostly features).
  Read five of its titles, decide which this repo means, and say which in the report.
- `other` is every fix the rules could not place. Read its titles and group them by hand; a group
  you can name counts like a kind.

`not_fixes` (alerting features worded "Page when X stops", reverts) never count as breakage.

**A hot file is not a finding.** In `hotspots.json`, a file is a candidate only when a recurring
kind lands in it or one of the four shapes below is found in it. When its `pure_addition_share` is
0.5 or more, or its `net_growth_share` is near 1.0 (it was born or doubled in the window), its
change count is growth, and no proposal may cite that count as breakage.

## 4. Look for the four shapes directly

The same four shapes appeared in both manual passes, so look for them rather than ranking files and
asking why. Dispatch one agent per shape, which is four agents, at most four running at once; tell
Dan the count before dispatching.

| Shape | What it looks like |
|---|---|
| Hand wired chain | A list of jobs, monitors, routes or steps that every new one must be added to by hand in several places (a registry, a schedule, a dispatcher, a test list), with nothing failing when one is missed |
| Helper whose calling sequence each caller rewrites | A shared helper that only works when called in a fixed sequence (open, check, write, close; fetch, parse, alert) and each caller writes that sequence out again |
| One fact in two homes | One value, rule, list or threshold kept in two places (two constants, a constant and a database row, code and config) that can drift |
| Multi step write safety done several ways | Writes that span steps (a database write plus an external call, a retry, a background job) made safe by different means in different places: a lock here, an idempotency key there, careful ordering elsewhere |

Each agent's brief, filled in per shape:

> Read only: change nothing in `<repo>`. Find every instance of this shape: <the row above>. The
> measurements are in `<scratch>/hotspots.json` and `<scratch>/kinds.json`; recurring kinds point
> at where to look first. For each instance return: a one line claim, every `path:line` it rests on,
> and any count as the exact command that re-derives it. Write working files under
> `<scratch>/<shape>/`. Something worth fixing that is not this shape: record it with
> `bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "architecture-pass"`. Wait for
> anything you start in the foreground, then hand back your report.

## 5. Spot check every claim

An agent's claim is a lead, not a finding: in the manual pass one inflated metric was caught only
because an agent re-derived it. For every claim, before it can be proposed:

1. Open each cited `path:line` and confirm the code says what the claim says.
2. Re-run each count with the command given, and use your number, not the agent's.
3. Drop a claim that does not hold, and say how many were dropped in the report.

Note in each proposal what was checked, so the issue carries its own evidence.

## 6. Look across repos

A good pattern in one repo can be the fix for another (one work repo's shared alert dispatcher
answers the other's per monitor glue). For each finding that survived, search the other repos
checked out on this Mac (listed under this Mac's heading in `~/.claude/CLAUDE.md`, Projects) for a
mechanism that already solves the shape, and cite it by repo and path as the fix direction. The
reverse counts too: a pattern found here that another repo lacks is a proposal for that repo.
Read only, in every repo.

## 7. Drop what is already filed

Read the repo's open issues whole (no `--search`, which reads a stale index):

```bash
gh issue list --repo "<owner/name>" --state open --limit 1000 --json number,title,body > <scratch>/open-issues.json
```

If it returns exactly 1000, the list is truncated: say so. A finding an open issue already covers
is not proposed; name that issue in the report instead.

## 8. Propose, and file only what Dan picks

Propose each finding to Dan with AskUserQuestion, one question per call, strongest first. The
question names the repo, the issue title and one sentence of evidence. You found these, so you
choose each proposal's priority and milestone by the rules in `~/.claude/skills/milestone/NAMING.md`
(not restated here) and show them in the options:

- **File it**: the description says the repo, priority, milestone and labels.
- **File it at p3**: the same, one step less urgent.
- **Skip**: nothing is filed.

Never file before his answer, and file only what Dan picks. For each one picked, resolve the
milestone and labels, then file with the body written to a file first:

```bash
bash ~/.claude/skills/milestone/ensure-priority-labels.sh "<owner/name>"
```

```bash
bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<existing milestone title, or Ungrouped>"
```

Create the `architecture` label only when `gh label list --repo "<owner/name>"` lacks it, with the
description "Structural problem found by an architecture pass". Use the exact title
ensure-milestone.sh reports.

```bash
gh issue create --repo "<owner/name>" --title "<title>" --body-file <scratch>/issue-<n>.md --milestone "<milestone title>" --label "architecture" --label "priority-p<level>"
```

Add any other category label the repo already has that fits. The body holds: the shape, every
`path:line`, the measured numbers with the commands behind them, what the spot check confirmed, the
pattern from another repo if one was found, and "Found by an architecture pass on <date>". Some
repos are public: code paths and titles only, never customer data.

## 9. Record the pass, then report

```bash
python3 ~/.claude/skills/architecture-pass/measure.py record-pass <repo>
```

Record it whether or not anything was filed: a pass that found nothing still happened. Then tell
Dan, in plain words: the window and ref read, the recurring kinds, how many agent claims were
dropped at the spot check, each issue filed with its link, what he skipped, and anything the pass
could not read.
