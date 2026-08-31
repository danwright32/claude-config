---
name: pennie-dev-update
description: Draft the recurring dev update Dan posts to Pennie's sales managers, covering what shipped in the internal tools they use (PET, and Slate when it is live) since the last update. Also runs a user-facing issue check that promotes manager-visible issues in the backlog. Use when Dan asks for a dev update, a changelog for managers, or invokes /pennie-dev-update.
trigger: /pennie-dev-update
---

# /pennie-dev-update

Two jobs, run together every time:

1. **Draft the post.** What shipped and reached production since the last update, written for
   non-technical sales managers, in Dan's voice, ready to paste into Slack.
2. **Run the user-facing issue check.** Find open issues a manager would notice, label them
   and raise them in the backlog. **This never appears in the post.** It exists to stop
   manager-visible problems sitting in the p3 pile.

```
/pennie-dev-update                 # ask for the window, then run
/pennie-dev-update 2026-09-01      # from that date to now
/pennie-dev-update --no-issues     # draft only, skip the issue check
/pennie-dev-update --issues-only   # run the check, write no post
```

Audience: 7 sales team leads plus Kris Hennen. They open PET daily. They do not read code and
do not care how anything is built.

---

## 1. Repos

Read `repos.json` beside this file. Today:

```json
{ "repos": [ { "name": "PET", "repo": "Try-Pennie/project-enrollment-tracker",
               "path": "~/Documents/Project Enrollment Tracker (PET)/pet" } ] }
```

Add Slate here when it is live. Rules:

- A repo with **no merges in the window** is omitted from the post silently.
- A repo that **does not exist yet or is unreachable** is skipped with a line in the terminal.
  Never fail the whole run for it, and never silently pretend it had nothing.
- More than one repo means the post gets a top-level section per project, with the categories
  nested under each. One repo means no project heading at all.

---

## 2. The window

State lives at `~/.pennie-dev-update/state.json`, deliberately **outside `~/.claude`**, because
anything under `~/.claude` auto-pushes to Dan's other Mac within seconds and a run timestamp is
state, not config.

```json
{ "Try-Pennie/project-enrollment-tracker": {
    "lastEnd": "2026-09-08T14:22:00Z",
    "heldBack": [1187, 1190],
    "headings": ["COMMISSION AND FIRST PAY", "GOALS"] } }
```

- **Start** = `lastEnd` for that repo, or the date passed as an argument.
- **End** = now.
- **No gaps, ever.** Because start is the previous end, nothing can fall between two updates.
  If Dan passes a date **later** than `lastEnd`, say exactly what period would be skipped and
  ask before proceeding. Do not silently drop it.
- **`heldBack`** carries PR numbers that merged but had not reached production last run. Add
  them to this run's candidate set regardless of the window.
- **`headings`** is the previous run's section names. See section 6.

With no argument and no stored state, ask with a picker: since the last update, last week,
last month, or a custom date.

---

## 3. Gathering

**Use the paginated API, never `gh pr list`.** `gh pr list --limit 2000` silently caps at 500,
which reads exactly like a repo with 500 PRs:

```bash
gh api --paginate '/repos/<owner>/<name>/pulls?state=closed&per_page=100' \
  --jq '.[] | select(.merged_at != null) | [.number, .merged_at, .title] | @tsv'
```

Filter to `merged_at >= start`. Cross-check the count against
`gh api '/search/issues?q=repo:<owner>/<name>+is:pr+is:merged+merged:>=<start>' --jq .total_count`
and refuse if they disagree, because a short read reports as a quiet week.

### Never filter by changed file paths

Measured against PET's June to August corpus on 2026-08-31: a filter keeping only PRs that
touch `dist/`, `calc.js`, `generate.js`, `functions/` or `app.js` ruled out **62%** of PRs and
would have discarded roughly **90 manager-visible items**, including the late-arriving deals
fix, the first-pay reschedule rule, terminated reps leaving phantom rows, every goal digest
change, the Achieve weekend cutoff, and PET noticing a rep became a manager.

The reason is structural and applies to Slate too: **these are data pipelines with a thin board
on top.** Most manager-visible behaviour lives in `scripts/` and `lib/`. Anything that changes
what number appears or what Slack says is manager-visible, and most of that is pipeline code.

So: read every title. No mechanical shortcut is trustworthy.

---

## 4. Did it actually ship

A merged PR is not a shipped change (LESSONS L4). A post announcing something managers cannot
see is the one failure that would make them stop trusting these updates.

PET records one row per **verified** deploy in `build_history`, appended by
`scripts/record-build-history.js` only after the live site is confirmed serving the new build.
Measured 2026-08-31: 94 rows, all 94 carrying `commit_sha`.

```sql
select commit_sha, recorded_at from build_history
where commit_sha is not null order by recorded_at desc limit 1;
```

A PR is live when its merge commit is an ancestor of that sha:

```bash
git merge-base --is-ancestor <merge_sha> <live_sha>
```

Three cases that must stay distinct (L11, L98):

| Situation | What to do |
|---|---|
| Merge commit is an ancestor of the live sha | List it |
| Merged, not yet live | Hold it back, add to `heldBack`, say so in the terminal |
| Window starts before the record exists (PET: before 2026-07-29) | List everything, print a note that the deploy record does not cover this period. Do NOT hold back a whole backdated run |
| `build_history` has no row in the last 3 days | **Refuse.** The recorder has stopped, so an empty answer means "cannot tell", not "nothing shipped" |

A repo with no deploy record at all: list everything, print that the check could not run for it.

---

## 5. Classifying

Every PR is **manager-visible** or **behind the scenes**.

Manager-visible means it changes something a manager sees, changes what a number says, or
changes what they can do. That includes changes to the Slack alerts and digests they receive,
and to data correctness even when no pixel moved.

Behind the scenes: tests, CI, refactors, schema guards, monitoring plumbing, dependency
updates, internal error handling nobody outside sees.

**Read the body of anything whose meaning is not obvious from the title.** Titles are written
for the person merging, not the person reading this post. On 2026-08-31 a title-only reading
produced a wrong item that a body read caught. If in doubt, open it.

---

## 6. Format

Taken from Dan's own rewrite of the first post. Follow it exactly.

```
Update for the week of September 8

Some of these you may have noticed and some you will not, because they are backend-only.

COMMISSION AND FIRST PAY
- The first thing that changed
- The second thing that changed

BEHIND THE SCENES (technical, skip unless curious)
- Testing: what changed
- Build and deploy: what changed
```

**Structure**
- **No title line.** Open with the period line.
- Period label from the actual window: "Update for the week of September 8" for roughly a
  week, "Update for September" for roughly a month, otherwise a date range.
- One short line noting some items are backend-only.
- Headings are **bare uppercase**, no bold markers, first item on the very next line, blank
  line between sections.
- Items are `- ` prefixed. **Never `•`.** No bold anywhere in the body.
- Under about **five** manager-visible items: drop headings entirely, print one flat list, then
  the behind-the-scenes section.

**Headings are derived per run** from what actually shipped, not from a fixed vocabulary. But
read `headings` from the state file first and **reuse the previous run's exact wording whenever
it still fits**, so the sections do not drift into synonyms week to week. Write this run's
headings back to state.

**Voice**
- First person, as Dan. "PET alerts **me** if the badge mix looks off." "**I** get a Slack
  message with a link."
- "You" is the manager reading it. Be careful about who actually receives an alert: Dan gets
  the operator alerts, managers do not.
- An item may carry a question back to the reader, e.g. offering them an alert they do not
  currently get and asking whether they want it.

**What to cut**
- **Justification.** "Rankings now run on three components" stays. "Reliability sat near 100%
  and was separating nobody" goes.
- **Methodology numbers.** 319 rep-months modelled, 82 of 100 reps on a stale goal: cut.
- **Impact numbers stay.** 44 units lost, 4 to 5 points of inflation, 60 to 92 reversed
  payments. The test: a number quantifying an error in *their* numbers earns its place, a
  number describing *how it was validated* does not.
- **Expand jargon, do not delete it.** "Achieve renamed a column" became "Achieve renamed a
  column in their data export".
- **Do not shorten where the detail is the change.** The first-pay rule and the closed-month
  attribution items are long because that length is the substance.

**Writing rules** (from `~/.claude/CLAUDE.md`, non-negotiable)
- No em dashes, no en dashes, no dashes as sentence connectors. The `- ` bullet prefix is a
  list marker, not punctuation, and is correct.
- No emoji.
- Plain language for a product manager. Describe technical things by what they affect.

**Quiet period.** When nothing manager-visible shipped:

```
Update for the week of September 8

Nothing changed on screen this week. Behind the scenes:

- Retry handling on the Achieve fetch
- Faster test runs
```

---

## 7. Accuracy

The failure mode is a confident sentence describing something that did not happen.

- **Every number traces to a PR body or the code.** Never carry a figure forward from memory
  or from another summary.
- **Never describe a change from an ambiguous title alone.** Open the PR.
- **Before handing over, spot-check the three or four claims you would least want to be wrong**
  (anything asserting a thing was previously broken, anything naming a quantity, anything
  saying who receives something). Read those PRs properly. Report what you checked.
- When you are not sure a change is manager-visible, put it in behind-the-scenes. An item
  wrongly omitted is invisible; an item wrongly claimed damages trust.

---

## 8. Output

Write to the session scratchpad directory, then open it:

```bash
/Applications/BBEdit.app/Contents/Helpers/bbedit_tool <file>
```

`bbedit` is not on PATH and `open` triggers the Island browser. Use the helper above.

Not archived. The window mechanism already prevents repeating content, so there is nothing to
compare against.

---

## 9. The user-facing issue check

Runs every time unless `--no-issues`. **Its output never goes in the post.**

### What counts

A **defect or rough edge a manager would notice**. Two categories:

- **Defects**: something currently wrong they could bump into. Wrong or missing data, a
  control that does nothing, a misleading message, a page that contradicts itself.
- **Rough edges**: unfinished behaviour they would call a gap. No empty state, no undo, no
  loading state, an unverified layout, accessibility defects such as a missing skip link or
  an invisible focus ring.

Not included: planned features and roadmap phases (this is not a roadmap), fragile
dependencies that are not currently broken, and anything only Dan ever sees such as operator
alerts, heartbeats, schema guards, pagination sweeps, CI and test work.

### Read bodies, not titles

Both traps below were caught this way on 2026-08-31 and would have reached managers otherwise:

- An issue whose body says outright it is **"a live landmine rather than a current visible
  fault"**, found while measuring something else, never reported by anyone.
- An issue still open whose contents **mostly shipped three months earlier**, so it reads as a
  live bug and is a stale bundle.

So for each candidate: read the body, and check whether it was since fixed. PET's audit-derived
issues carry explicit `### User Impact` and `### UX Impact` fields. Read those where present;
they are a far better signal than labels.

**Labels are not a gate.** Real user-facing issues in PET carry no `ux` label at all, for
example a rep whose PET team disagrees with Salesforce. Use labels to rank what to read first,
never to decide.

### What it does

For each issue judged user-facing:

```bash
gh issue edit <n> --add-label user-facing
gh issue edit <n> --remove-label priority-p3 --add-label priority-p2
```

- Add the **`user-facing`** label. This is the durable record of the judgment, so the priority
  change has a visible reason and later runs can see what was already decided.
- Raise priority to **p2**, **unless it is already p0 or p1**, which would be a demotion. Leave
  those alone.
- Already p2: label only, no priority change.
- Create the label if missing:
  `gh label create user-facing --color 0E8A16 --description "A manager would notice this"`

### Across runs

- Each run classifies issues **opened or updated since the last run**.
- Issues **already carrying `user-facing`** are revisited only to **remove the label** when the
  issue is closed, fixed, or was misjudged.
- **Never lower a priority.** Dan or a human reviewer may have set it deliberately.

### Report it

Print exactly what changed, one line per issue, old and new priority. A silent bulk mutation of
the backlog is not acceptable even when authorised.

---

## 10. Sequence

1. Resolve the window (section 2). Refuse a gap.
2. For each repo: gather merged PRs (section 3), verify each reached production (section 4).
3. Classify (section 5). Read bodies where ambiguous.
4. Draft in the format (section 6), applying the accuracy pass (section 7).
5. Write and open in BBEdit (section 8).
6. Run the issue check (section 9) and print what it changed.
7. Write `lastEnd`, `heldBack` and `headings` back to state.
8. Tell Dan: the window covered, how many changes, how many held back and why, and what the
   issue check changed.
