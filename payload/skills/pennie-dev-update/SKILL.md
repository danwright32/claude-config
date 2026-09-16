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
/pennie-dev-update                 # everything since the last update, up to now
/pennie-dev-update --no-issues     # draft only, skip the issue check
/pennie-dev-update --issues-only   # run the check, write no post
/pennie-dev-update --since <date>  # escape hatch, see section 2
```

**Takes no date.** The window is always "since the last update, up to right now". Dan should
never have to remember when he last posted, and a date he types by hand is the one way this
can silently skip a period.

Audience: 7 sales team leads plus Kris Hennen. They open PET daily. They do not read code and
do not care how anything is built.

---

## 1. Repos

### It does not matter where Dan runs this

**Run it from any directory, including one that is not a git repo at all.** Every repo it
touches comes from `repos.json`, never from the working directory.

So **every `gh` command must carry `--repo <owner>/<name>` explicitly**, and every `git`
command must be run against the configured `path` (`git -C <path> ...`). This is not a style
preference. Dan's usual working directory for PET is the folder *above* the git repo, which is
not a repo at all, so a bare `gh issue edit` there fails or, worse, resolves to whatever repo
happens to be nearby.

If Dan asks for an update "for Slate" or "for PET" specifically, filter `repos.json` to that
one. Otherwise do them all.

### The config

Read `repos.json` beside this file:

```json
{ "repos": [
  { "name": "PET",
    "repo": "Try-Pennie/project-enrollment-tracker",
    "path": "~/Documents/Project Enrollment Tracker (PET)/pet" }
] }
```

**Every repo in this file is treated identically.** There is no launch mode, no special first
post, no per-repo behaviour of any kind. Dan writes his own introduction post when a product
goes live; this skill only ever does the recurring update, and a product joins that rotation
weeks later.

- A repo with **no merges in the window** is omitted from the post silently.
- A repo that is **unreachable** is skipped with a line in the terminal. Never fail the whole
  run for it, and never silently pretend it had nothing.
- More than one repo means the post gets a top-level section per project, with categories
  nested under each. One repo means no project heading at all.

### Adding a repo

Add an entry to `repos.json`. That is the entire process.

**Add it when you want it appearing in these updates**, which is not the same day its repo is
created and not the same day it launches. A repo absent from this file is invisible to the
skill, which is the correct state for a product managers cannot use yet.

Having no `lastEnd` makes its next run a genuine first run, so the skill asks for a starting
date (section 2) and then behaves exactly like PET forever after.

Slate's repo is `Try-Pennie/slate`. Its entry, for when Dan wants it in the rotation:

```json
{ "name": "Slate", "repo": "Try-Pennie/slate",
  "path": "~/<wherever it is checked out>" }
```

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

- **Start** = `lastEnd` for that repo, exclusive. **End** = now. That is the whole rule.
- **No gaps, ever**, because each window begins exactly where the last one ended. No date is
  asked for and none is needed.
- **`heldBack`** carries PR numbers that merged but had not reached production last run. Add
  them to this run's candidate set regardless of the window.
- **`headings`** is the previous run's section names. See section 6.

**The only time it asks:** a repo with no `lastEnd` at all, its genuine first run. Then ask for
a starting date, because nothing else can know it. Every run after that is silent.

### The boundary is an instant, never a day

`lastEnd` is a full UTC timestamp and the comparison is strictly `merged_at > lastEnd`.

This matters because Dan posts an update and then keeps working the same day. A day-granular
boundary breaks both ways and there is no safe rounding: store `2026-08-31` and tomorrow's run
re-reports everything already posted today; store `2026-09-01` and everything merged after the
post is skipped forever. `merged_at` from the GitHub API is a full ISO timestamp, so comparing
instants is exact.

### What to store as the new `lastEnd`

**The `merged_at` of the newest PR actually LISTED in the post.** Not wall-clock now, and not
the newest PR considered.

- Not wall-clock now: a PR that merges while the run is drafting would fall before the boundary
  and never appear in any update.
- Not the newest considered: a held-back PR sits above the newest listed one, and advancing past
  it would make its future inclusion depend entirely on the `heldBack` list being written
  correctly. Leaving the boundary below it means the next window re-covers it naturally *and*
  `heldBack` names it. Two independent paths to the same guarantee, which is what you want for
  the one failure this design exists to prevent.

The cost is that the next run re-examines a handful of already-considered PRs. That is harmless:
it either lists them or holds them back again.

**If nothing was listed** (a quiet period, or everything held back), leave `lastEnd` untouched.
The window simply grows until there is something to report.

**Write `lastEnd` only after the draft file exists.** If the run dies partway the boundary must
not move, or that period is skipped forever.

### `--since <date>` is an escape hatch

Only for redoing a period or recovering lost state. If the date given is **later** than
`lastEnd`, print exactly what period would be skipped and ask before proceeding. A redo never
moves `lastEnd` backwards.

---

## 3. Gathering

**Use the paginated API, never `gh pr list`.** `gh pr list --limit 2000` silently caps at 500,
which reads exactly like a repo with 500 PRs:

```bash
gh api --paginate '/repos/<owner>/<name>/pulls?state=closed&per_page=100' \
  --jq '.[] | select(.merged_at != null)
        | [.number, .merged_at, .title, ([.labels[].name] | join(" ")), (.body // "")]
        | @tsv'
```

Filter to `merged_at >= start`. Cross-check the count against
`gh api '/search/issues?q=repo:<owner>/<name>+is:pr+is:merged+merged:>=<start>' --jq .total_count`
and refuse if they disagree, because a short read reports as a quiet week.

### The record each change carries (PET #1186)

From a repo's `changelogFrom` date in `repos.json`, every merged pull request carries the
judgment already, made at merge time by the person who made the change and enforced by
`~/.claude/hooks/require-changelog-tag.sh`:

| Label | Means | Body |
|---|---|---|
| `changelog/visible` | A manager would notice this | A `## Changelog` heading with the manager-facing sentence under it, required |
| `changelog/technical` | Plumbing worth a roll-up line | Optional |
| `changelog/none` | Not in the update at all | Must not carry a block |

So for anything merged on or after that date: **read the label, and take the sentence from the
block verbatim as the starting point.** Do not re-derive the judgment from the title. That
re-derivation is what made the first post cost a read of 499 titles, and the merge-time
judgment is the better one because the person who made the change was still holding it.

Editing the sentence is still expected. Grouping, wording, and merging two related items into
one line are this skill's job. What is no longer this skill's job is deciding, from an
engineering-voiced title, whether anyone outside engineering would notice.

**Before the cutover date, and for anything with no record, fall back to reading titles and
bodies exactly as below.** Say in the terminal how many of the window's pull requests carried a
record and how many were judged by hand, because a window that is entirely hand-judged looks
identical to one that is entirely recorded, and the difference is how much to trust the sort.

A pull request merged **after** the cutover with **no** record is a gap, not a plumbing change:
it means something merged around the gate. Name those explicitly rather than defaulting them
into behind-the-scenes.

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

**Where a record exists (section 3), it decides.** `changelog/visible` is manager-visible,
`changelog/technical` is behind the scenes, `changelog/none` is neither and does not appear.
Overrule a record only when it is plainly wrong, and when you do, say so in the terminal and
fix the label on the pull request, so the next run does not make the same correction again.
A judgment corrected only in a draft is a judgment nobody recorded.

Everything below is how to classify a pull request with **no** record: everything merged before
the cutover date, and any gap.

Manager-visible means it changes something a manager sees, changes what a number says, or
changes what they can do. That includes changes to the Slack alerts and digests they receive,
and to data correctness even when no pixel moved.

Behind the scenes: tests, CI, refactors, schema guards, monitoring plumbing, dependency
updates, internal error handling nobody outside sees.

**Read the body of anything whose meaning is not obvious from the title.** Titles are written
for the person merging, not the person reading this post. On 2026-08-31 a title-only reading
produced a wrong item that a body read caught. If in doubt, open it.

Dependabot pull requests never carry a record, by design: they merge themselves and gating them
would stall the auto-merge workflow. They collapse into one standing line about dependency
updates, as in the June to August post.

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
- **Release notes, not paragraphs (Dan, 2026-09-16).** One change per bullet, each bullet
  short. A PR whose Changelog block holds four facts becomes four bullets, never one
  paragraph. The first draft that merged 53 changes into long bullets was rejected with
  "this should read like patch or release notes. keep each bullet point short and sweet";
  the rewrite that landed had 70 bullets, most under 25 words. Keep the detail, split it.

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
gh issue edit <n> --repo <owner>/<name> --add-label user-facing
gh issue edit <n> --repo <owner>/<name> --remove-label priority-p3 --add-label priority-p2
```

- Add the **`user-facing`** label. This is the durable record of the judgment, so the priority
  change has a visible reason and later runs can see what was already decided.
- Raise priority to **p2**, **unless it is already p0 or p1**, which would be a demotion. Leave
  those alone.
- Already p2: label only, no priority change.
- Create the label if missing:
  `gh label create user-facing --repo <owner>/<name> --color 0E8A16 --description "A manager would notice this"`

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
