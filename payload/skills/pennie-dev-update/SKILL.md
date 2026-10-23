---
name: pennie-dev-update
description: Draft the recurring dev update Dan posts to Pennie's sales managers, covering what shipped since the last update in every internal tool listed in this Mac's dev update registry. Also runs a user-facing issue check that promotes manager-visible issues in the backlog. Use when Dan asks for a dev update, a changelog for managers, or invokes /pennie-dev-update.
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

**Sonar is agent facing, not manager facing** (Dan, 2026-09-28). Its changes still go in this
same manager post, under their own SONAR section, written as what agents will now see or do
("Agents now get...") so a manager can pass it on. For Sonar, "visible" means an AGENT would
notice it: read `changelog/visible` there that way, and in the issue check (section 9) judge
Sonar issues by whether an agent would bump into them.

---

## 1. Repos

### It does not matter where Dan runs this

**Run it from any directory, including one that is not a git repo at all.** Every repo it
touches comes from the registry (section 1, "The registry"), never from the working directory.

So **every gh command must carry `--repo <owner>/<name>` explicitly** (or name the repo in its
API path). This is not a style preference. Dan's usual working directory for PET is the folder
*above* the git repo, which is not a repo at all, so an issue edit with no repo named there fails
or, worse, resolves to whatever repo happens to be nearby.

### Which account reads each repo

**Every repo is read as the GitHub account the registry names for it (`account`), whichever account
gh has active** (claude-config#1182). Dan runs sessions under different GitHub accounts at once, and
on the personal MacBook the active one is danwright32, which GitHub answers 404 for the work organisation's
private repos. `gather.js` takes the named account's token from gh's own store and hands it to each
call in that call's environment only, the way the merge helper does. **Never switch the active
account** (`gh auth switch`): other sessions are using it.

So **no gh command in this skill runs bare.** The issue check's commands (section 9) run through
`gather.js gh`, which runs the command as the account of the repo it names, refuses one that names
no repo, two repos or a repo missing from the registry, and passes gh's own output and exit code
back unchanged:

```bash
node ~/.claude/skills/pennie-dev-update/gather.js gh -- issue list --repo <owner>/<name> --state all --limit 200
```

If the account is not signed in to gh on this Mac, `gather.js` refuses that repo by name and prints
the one command that signs it in. Tell Dan exactly that, with the command; never report the repo as
quiet, and never read it as another account.

**No step needs a local checkout.** Gathering, the changelog records and the deploy check all ask
GitHub by `owner/name`, so the registry records no path, and `gather.js` refuses an entry that carries one. The paths it used to carry were typed by
hand, pointed at `~/Documents/...`, and stopped existing when the work MacBook's Documents folder
moved on 2026-10-02 (claude-config#679, L153).

If Dan asks for an update "for Slate" or "for PET" specifically, filter the registry to that
one. Otherwise do them all.

### The registry

The repos come from this Mac's own registry, the file `repos.local.json` in this skill's folder
(`~/.claude/skills/pennie-dev-update/`), which no copy of the skill ships with. It names work repositories, so it is **never** in the shared config, which is a public repository
(claude-config#1526): the sync never sends a `*.local.json` and never deletes one, so each Mac keeps
its own copy and an edit on one Mac does not reach the other. Edit it on the Mac you run the update
from, and copy it across by hand when both need the change.

`gather.js`, `lint-post.js` and the merge gate (`hooks/require-changelog-tag.sh`) all read it
through one reader, `hooks/lib/dev-update-registry.js`, so they can never be reading different
files. With no registry on this Mac all three refuse, and say where to create it and what goes in
it; the gate refuses every merge until it exists, because a missing registry cannot tell a gated
repo from one nobody gated. A registry holding `{"repos": []}` gates nothing, on purpose.

It used to be `repos.json` in this folder, shared through the sync. The first pull of the change
that moved it renamed each Mac's copy in place, before the sync could remove the shared one, so
nothing had to be recreated. A copy that turns up under the old name again is never sent, and the
next pull moves it (or sets it aside beside the registry, if the two differ). If a Mac has none,
the last shared version is in the sync clone's history, as the parent of the commit that removed
`payload/skills/pennie-dev-update/repos.json`.

An entry looks like this (an invented repository):

```json
{ "repos": [
  { "name": "Widget",
    "repo": "acme/widget",
    "account": "acme-bot",
    "deployRecord": "build_history",
    "deployRecordFrom": "2026-07-29",
    "changelogFrom": "2026-08-31" }
] }
```

**Every repo in the registry is treated identically, apart from its first appearance.** There is no
per-repo behaviour of any kind. A product's first appearance (its repo has no `lastEnd` in state)
introduces it in general and never lists its changes one by one; every run after that is the
recurring update, exactly as for PET. Section 2, "First appearance", says how.

- A repo with **no merges in the window** is omitted from the post silently.
- A repo that is **unreachable** is skipped with a line in the terminal. Never fail the whole
  run for it, and never silently pretend it had nothing.
- More than one repo means the post gets a top-level section per project, with categories
  nested under each. One repo means no project heading at all.
- **The products appear in the order the registry lists them**, which is Slate, PET, Sonar
  (Dan, 2026-10-13: "put Slate first"). That one order sets the product line in the opener
  (section 6) and the order of the product sections, and `lint-post.js` reads it from this file,
  so reordering a product means reordering the registry, never only the draft.

### Adding a repo

Add an entry to the registry. That is the entire process. Put a newly launched product at the
top, so its launch section leads the post (section 6), and move it only when Dan asks.

**Add it when you want it appearing in these updates**, which is not the same day its repo is
created and not the same day it launches. A repo absent from this file is invisible to the
skill, which is the correct state for a product managers cannot use yet.

Having no `lastEnd` makes its next run its first appearance, which introduces the product
(section 2) and then behaves exactly like PET forever after.

An entry needs `name`, `repo` and `account`, the GitHub account that can see the repo
(`dwright-pennie` for the work organisation's). Give it `changelogFrom` from the day its pull requests
carry changelog records (section 3), and `deployRecord` with `deployRecordFrom` only if it has a
verified deploy record (section 4): a name read by hand and passed with `--live`, or one of the
records `gather.js` reads from GitHub itself, measured against the repo's real merges first.

---

## 2. The window

**`gather.js` computes the window and `gather.js commit-state` is the only thing that writes the
state** (claude-config#680). Never compute a window or edit the state file by hand. This section
is the rule those two implement, and why; `tests/scripts.test.js` holds each rule.

State lives at `~/.pennie-dev-update/state.json`, deliberately **outside `~/.claude`**, because
anything under `~/.claude` auto-pushes to Dan's other Mac within seconds and a run timestamp is
state, not config.

```json
{ "acme/widget": {
    "lastEnd": "2026-09-08T14:22:00Z",
    "heldBack": [1187, 1190],
    "headings": ["COMMISSION AND FIRST PAY", "GOALS"] } }
```

- **Start** = `lastEnd` for that repo, exclusive. **End** = now. That is the whole rule.
- **No gaps, ever**, because each window begins exactly where the last one ended. No date is
  asked for and none is needed.
- **`heldBack`** carries PR numbers that merged but had not reached production last run, or
  could not be confirmed live (section 4). Add them to this run's candidate set regardless of
  the window.
- **`headings`** is the previous run's section names. See section 6.

### First appearance

A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced
in general. Dan decided this on 2026-09-28, when the skill asked him for a starting date for
Sonar: "sonar shouldn't announce specific updates. this would be the announcement of sonar in
general." So no date is asked for, and the product's merged PRs are never listed one by one.

The introduction is the product's own section, placed first (section 6, the launch rules): what
it is, who uses it, when to open it, what it checks, and how to share a result, plus where it is
bookmarked. Write it from the product as it stands in production (its README, its live pages,
what it shows a manager), never from its PR titles. A launch also gets the launch line in the
opener, after the product line (section 6).

Then set that repo's `lastEnd` to the `merged_at` of its newest merged PR that reached
production (section 4), so the next run reports changes only, from after the introduction. A
newer merge not yet in production goes in `heldBack`, as on any run. Record what the boundary
came from in `_seededFrom` beside it (the PR number and its `merged_at`), so a later reader can
tell a seeded boundary from one written after a listed post. The Sonar entry written on
2026-09-28 (on the Mac that holds that state file) is the worked example. `gather.js` reports
such a repo as `first_appearance` with the `seed` it found, and `commit-state` writes the seed
and `_seededFrom` (it refuses `--listed` for it).

A repo with no merged PR at all has nothing live to introduce: say so in the terminal and leave
it without a `lastEnd` until it has one.

A repo missing from a state file that exists is a first appearance. A state file that is missing
**altogether** is lost state, not a set of new products, and `gather.js` refuses rather than
introduce every product again; `--since` (below) is the way back.

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
A first appearance lists nothing and still seeds its boundary ("First appearance" above).
The window simply grows until there is something to report.

**Write `lastEnd` only after the draft file exists.** If the run dies partway the boundary must
not move, or that period is skipped forever. `commit-state` takes `--draft` and refuses when the
file is missing or empty, when a `--headings` entry is not a line of it, when a `--listed` PR was
not gathered or was held back, and when the state moved since the gather (so running it twice
changes nothing). It takes `lastEnd` from the gathered `merged_at` of the newest listed PR,
`heldBack` from what gather found not yet live, and keeps every other field.

### `--since <ISO timestamp>` is an escape hatch

Only for redoing a period or recovering lost state. When it is **later** than `lastEnd`,
`gather.js` refuses that repo, naming exactly the period that would be skipped; ask Dan, and pass
`--confirm-skip` only on his yes. A redo never moves `lastEnd` backwards (`commit-state` keeps the
later of the two). A repo with no `lastEnd` recovered this way gets the `--since` start as its
`lastEnd` even when the post lists nothing, so the next run does not read it as a first
appearance.

---

## 3. Gathering

**`gather.js` does all of this; read its output, never re-fetch by hand.** What it does, and why:

- It reads the REST pulls API page by page until a page comes back short, never `gh pr list`,
  whose `--limit 2000` silently caps at 500 and reads exactly like a repo with 500 PRs.
- It keeps `merged_at > start`, strictly, as section 2 says: the PR merged exactly at `lastEnd`
  is the newest one the last post listed.
- It cross checks that count against GitHub search (`merged:>` the same instant) and refuses the
  repo when they disagree, because a short read reports as a quiet week.
- A repo GitHub cannot be reached for is `unreachable`, with GitHub's own error, and the other
  repos still gather. It never reads as a repo with nothing in it.

Each PR in its output carries `record` (below), `deploy` (section 4), `carried` (true for a
`heldBack` PR from the last run that sits below the window), and its title, labels and body.

### The record each change carries (PET #1186)

From a repo's `changelogFrom` date in the registry, every merged pull request carries the
judgment already, made at merge time by the person who made the change and enforced by
`~/.claude/hooks/require-changelog-tag.sh`:

| Label | Means | Body |
|---|---|---|
| `changelog/visible` | A manager would notice this | A `## Changelog` heading with the manager-facing sentence under it, required |
| `changelog/technical` | Plumbing worth a roll-up line | Optional |
| `changelog/none` | Not in the update at all | Must not carry a block |

`gather.js` reads each record through `hooks/lib/changelog-entry.js`, the same parser the merge
gate uses, so the two cannot disagree about what a record is. A PR's `record.kind` is
`visible` (with `record.line`, the block's sentence), `technical`, `none`, `gap` (merged on or
after the cutover with no valid record; `record.code` and `record.reason` say what is wrong),
`unrecorded` (merged before the cutover, judged by hand) or `dependency` (Dependabot). The
cutover day is the local day the merge fell on, as the gate judged it.

So for anything merged on or after that date: **read the label, and take the sentence from the
block verbatim as the starting point.** Do not re-derive the judgment from the title. That
re-derivation is what made the first post cost a read of 499 titles, and the merge-time
judgment is the better one because the person who made the change was still holding it.

Editing the sentence is still expected. Grouping, wording, and merging two related items into
one line are this skill's job. What is no longer this skill's job is deciding, from an
engineering-voiced title, whether anyone outside engineering would notice.

**Before the cutover date, and for anything with no record, fall back to reading titles and
bodies exactly as below.** Say in the terminal how many of the window's pull requests carried a
record and how many were judged by hand (`gather.js` prints both, from its `counts`), because a window that is entirely hand-judged looks
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

Every repo names its deploy record in the registry as `deployRecord`, and each record gives one
thing: the **live commit**, the newest commit known to be serving everyone. Three records exist:

**PET, `build_history` (read by hand).** PET records one row per **verified** deploy in
`build_history`, appended by `scripts/record-build-history.js` only after the live site is
confirmed serving the new build. Measured 2026-08-31: 94 rows, all 94 carrying `commit_sha`.
Read the newest row yourself (the one step `gather.js` cannot do, since it needs the database):

```sql
select commit_sha, recorded_at from build_history
where commit_sha is not null order by recorded_at desc limit 1;
```

and hand it over as `--live <owner>/<name>=<commit_sha>@<recorded_at>`. A repo whose
`deployRecord` is a name like this is refused without it.

**Slate, `actions_deploy_job` (read by `gather.js` from GitHub).** Slate deploys from the
`deploy` job of its CI run on main, through a 10% canary that is probed and then promoted to 100%
or put back (slate#3165). The exit code of the job's "Deploy gradually" step says
where production ended (Slate's DEPLOY.md), and GitHub keeps it as the annotation "Process
completed with exit code N". The live commit is the newest run whose step succeeded or exited
with a `liveExits` code (the new version serving 100%); an `unchangedExits` code (production put
back as it was, the canary failing at 10% among them) is passed over. Any other ending since then,
or any Rollback run since then, makes the live commit unknown, because GitHub does not record
which commit a rollback put back (`unconfirmed`, below). Measured 2026-10-13: 175 merges since
2026-10-04, all 175 reached 100%, a median of 11 minutes after merge, 90th percentile 19 minutes,
longest 15 hours (waiting behind a deploy that exited 11); no Rollback run had ever been made.

**Sonar, `deploy_check_run` (read by `gather.js` from GitHub).** Sonar is built and deployed by
Cloudflare Pages, which writes a "Cloudflare Pages" check run on each merge commit. The live
commit is the newest merge whose check run, from Cloudflare's own app, succeeded. Pages swaps in
a whole version at once, so there is no canary to tell apart. Measured 2026-10-13: 71 of 72
merges since 2026-09-25 had a successful run, about 30 seconds after merge; the 72nd (#123) had
no check run at all and went live with the next merge.

**What neither GitHub record can see:** a deploy or a rollback done by hand outside GitHub
(`wrangler` from a laptop for Slate, the Pages dashboard for Sonar). Pass nothing for these two:
`gather.js` refuses a `--live` for a repo whose record it reads itself.

A PR is live when its merge commit is an ancestor of the live commit. `gather.js` asks GitHub's
compare endpoint, never a local checkout, which may not have fetched the live sha at all: `ahead`
or `identical` means live, `behind` or `diverged` means not live yet, and an error means the check
could not be made, which makes the repo `unreachable` rather than holding the PR.

Seven cases that must stay distinct (L11, L98), each a `deploy` value or a refusal in the output:

| Situation | What to do |
|---|---|
| Merge commit is an ancestor of the live commit (`live`) | List it |
| Merged, not yet live (`held`) | Hold it back; it is in the repo's `heldBack`. Say so in the terminal |
| Production may have changed to a commit nobody recorded since the newest full deploy: a Slate deploy that may have left the 10% split standing (exit 20), was interfered with (22) or failed without saying (24, or no exit code), or a Rollback run (`unconfirmed`) | **Do not list it, and do not call it held.** It is in `heldBack` and checked again next run. Tell Dan in the terminal, in these words or close: "N Slate changes could not be confirmed live", with the reason from the repo's note |
| Merged before the record exists, PET before 2026-07-29, Slate before 2026-10-04, Sonar before 2026-09-25 (`uncovered`) | List it, with the note that the deploy record does not cover this period. Do NOT hold back a whole backdated run |
| `build_history` has no row in the last 3 days (refused) | **Refuse.** The recorder has stopped, so an empty answer means "cannot tell", not "nothing shipped" |
| No run or merge `gather.js` read reached production, or a successful deploy job has no "Deploy gradually" step (refused) | **Refuse**, naming the record. The record has stopped or changed shape, so holding everything would read as a quiet week |
| GitHub fails to answer for the deploy record (`unreachable`) | Skip the repo with GitHub's own error, as for any unreachable repo |

A repo with no deploy record at all (`unchecked`): list everything, and say the check could not
run for it. No repo is like this today.

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

Taken from Dan's own rewrite of the first post, and from the draft he accepted on
2026-09-16 after rejecting a longer-bulleted one. Follow it exactly. **It reads like
release notes**: many bullets, one change each, most under 25 words. The 2026-09-16 post
covered 53 manager-visible PRs in 70 bullets. Its opener is shown as Dan changed it on
2026-09-28 (below), since that is the opener every draft uses now.

```
Updates for August 31 to September 15 :thread:

GOALS
The automatic unit goal is now two tiers: 15 units for months 1 to 3, 22 units from month 4 on. The old 20 and 25 tiers are gone.
Volume goals follow, so a rep on 22 units carries a $1.1M volume goal.
April through August have been re-scaled to the new tiers, so goal attainment on those history pages has changed.

POWER RANKINGS
Units, Volume and Conversion now show beside each rep's score, replacing the Focus column.
A rep too new for a conversion rate shows "New" instead of 0%.
On All Teams, the profile bars no longer sit empty for two seconds and then pop into place.

COMMISSION AND FIRST PAY
New Rolled column: how many of each rep's deals had their first payment moved to a later month. Click it for the clients and the date each moved to.
A deal with no deposit and no estimated first pay date is no longer counted as rolled. This moved 16 deals in June and 8 in July, all on Achieve.
The August servicer split was briefly showing zero on both sides while the total was right. Fixed.

BEHIND THE SCENES (technical, skip unless curious)
Data checks: weekly checks for a rep who worked a month but recorded nothing, and for the Beyond and Achieve volume split
Build and deploy: the daily build is triggered from a Cloudflare Worker with the GitHub crons as backstop
```

**What Dan changed before posting on 2026-09-28** (the first post with two products). Apply
these on the first draft:
- He rewrote the opener as `Updates for September 15 to 28 :thread:`, with the detail going in
  the thread, and deleted the line saying some items are backend only. Both are in the structure
  rules below.
- A product being LAUNCHED goes first, above PET (it sits at the top of the registry for
  that). Its section explains what it is, when to
  open it, what it checks and how to share a result. Dan added where it is bookmarked and
  that agents should start with it.
- He cut: the count of corrected history rows, "closed months keep their rankings", the Sonar
  voice playback line, "nothing to install", "please pass the link on", and the whole COPYING
  TO SLACK section (Copy Week So Far, the image cards, tied ranks). He did not say why, so
  do not assume copy button changes are never wanted. Keep a draft lean, though: one fact a
  manager acts on beats three that restate it.
- He folded "a team's score is the average of its reps' scores" into the line introducing
  the chart, and corrected "the managers who hired them" to the managers whose team the reps
  are on. Managers do not hire, so never write that they do.

Note the shape of the visible bullets above: a PR whose Changelog block carried four
facts (the two-tier goal) became four bullets, one per fact, with the detail kept and the
connective prose dropped. That is the target for the FIRST draft, not a rewrite.

**What Dan changed before posting on 2026-10-13** (the first post with three products). His
draft went from 29 Slate lines to 17 and from 20 PET lines to 15. Apply
these on the first draft:
- **Cut what managers never see.** Lead-only edge cases went: a link with no routing code, a
  lead re-picking a time that was just taken, a mistyped email. Rules that only touch admins
  went too (admins can no longer approve their own time off). Ask of each line: does a sales
  manager see this, act on it, or get asked about it by a rep?
- **Cut alert mechanics unless managers receive and act on the alert.** The whole SLACK
  ALERTS section went (coverage retries, alert wording, the below tier alert), and so did "the
  alerts channel hears only if neither acts" and "those waits are shorter when...".
- **Cut the safety-net follow-ons once the headline is there.** "The nightly sync can no longer
  do it either", "the weekly data check no longer wipes days worked", "September and earlier
  keep their goals", and the shortened time off waiting for approval all went. One line for the
  rule; the guards that protect it are behind the scenes at most.
- **Cut who-moved detail once the rule is stated**, even as counts ("three reps move from 22
  to 15"). This is not the impact number rule below: an error in their numbers stays, a list
  of who a rule change touched goes.
- **Explain a technical term in the manager's words where the line uses it.** After "routed on
  their latest application's score" he added "Now we check to make sure their debt level is the
  most up to date amount we have." Score, tier and bucket mean debt level to a manager.
- **Use a current example.** He changed "Low with Beyond" to "Low with Achieve", because Beyond
  is winding down. Pick examples from what is live now.
- **Point managers at a tool they may not have opened.** He headed Slate's console section
  "THE CONSOLE (if you haven't looked at it yet, go check it out!)". A product or page new to
  managers can carry a short invitation in its heading.
- **Behind the scenes can be fuller** ("think we can add more to the technical section"): one
  line per area per product, prefixed with the product and area (`Slate releases:`,
  `PET backups:`), about 12 lines, each saying what it protects or speeds up. Leave out the
  dependency updates line, lines about monitoring that only alerts Dan (log shipping, a database
  memory alert), and work that is built but switched off ("coming next"): all four went.
- **No vendor or internal tool names a manager does not know.** "Restored from the Snowflake
  copy" became "restored from the copy". Say what the thing does, not what it is called.
- **Never a bare @channel, @here or @everyone.** Pasting the post would ping the whole channel,
  so he wrote "@ channel" with a space. `lint-post.js` refuses the bare form.

**Structure**
- **No title line.** The first line is the opener, `Updates for <period> :thread:`, and the
  detail goes in the thread (Dan, 2026-09-28).
- The period comes from the actual window: "the week of September 8" for roughly a week,
  "September" for roughly a month, otherwise a range such as "September 15 to 28".
- **The product line (Dan, 2026-10-13).** A post covering two or more products puts, on the
  line straight after the opener, the products it covers joined with ` | `, in the registry's
  order: `Slate | PET | Sonar`. A product with nothing to report is left off the line, as it is
  left out of the post. A post covering one product has no product heading and so no product
  line.
- **Product layout (Dan, 2026-10-13, both deliberate).** The first product's heading sits on
  the line straight under the product line, with no blank line. Each product's section starts
  with its name in uppercase on its own line (`SLATE`), its first category heading on the very
  next line, then that category's items. **Two blank lines** separate one product from the
  next; one blank line separates categories inside a product, and the behind the scenes section.
  The 2026-10-13 post, trimmed:

  ```
  Updates for September 29 to October 13 :thread:
  Slate | PET | Sonar
  SLATE
  ROUTING AND BOOKING
  Leads who open the booker after 6pm Eastern now see the next three open days instead of two.

  THE CONSOLE (if you haven't looked at it yet, go check it out!)
  Pools now show in words, such as "Low with Achieve", instead of bucket codes like 112.


  PET
  GOALS
  Rookie goals now count from the floor date, not the date the Salesforce account was created.


  SONAR
  Agents now get a larger "Share this result" button in the result panel.

  BEHIND THE SCENES (technical, skip unless curious)
  Slate releases: each release now goes to 10% of traffic first, with a tested one step rollback
  ```
- A launch gets a launch line after the product line, before the first product heading:
  "Including the launch of a new tool, Sonar!".
- **No line saying some items are backend only.** Dan deleted it on 2026-09-28.
- Headings are **bare uppercase**, no bold markers, first item on the very next line, blank
  line between sections.
- **Items carry no prefix at all: no `- `, no `•`** (Dan, 2026-09-28: "can you take out
  the dashes"). Each item is its own line directly under its heading. No bold anywhere in
  the body.
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
- No em dashes, no en dashes, no dashes as sentence connectors, and no dash as a list
  marker either. Avoid hyphenated words in the post too ("backend only", not "backend-only"),
  except where the word is the literal name of something on screen, such as the Top-out column.
- No emoji.
- Plain language for a product manager. Describe technical things by what they affect.

**Quiet period.** When nothing manager-visible shipped:

```
Updates for the week of September 8 :thread:

Nothing changed on screen this week. Behind the scenes:

Retry handling on the Achieve fetch
Faster test runs
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

Write to the session scratchpad directory and check it against the format rules:

```bash
node ~/.claude/skills/pennie-dev-update/lint-post.js <file>
```

It refuses (exit 1, one `line N:` per finding) a dash as punctuation, an item prefix, bold, an
emoji or a shortcode other than the opener's `:thread:`, a heading that is not bare uppercase or
ends in a colon or has no item under it, an opener that is not `Updates for <period> :thread:`,
a bare @channel, @here or @everyone, a multi product post whose product line is missing or does not match its product sections, a
product line on a one product post, product sections out of the registry's order, and the
deleted "backend only" line. It reads the products from this Mac's registry (`--config`
points it at another), and refuses to run if that cannot be read. Fix every finding before Dan sees the draft. A hyphenated
word is only a warning: keep it if it is the literal name of something on screen, such as the
Top-out column. Then open it:

```bash
/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window <file>
```

`bbedit` is not on PATH and `open` triggers the Island browser. Use the helper above, with
`--front-window`: without it the helper opens the file in the background, reports success, and
Dan sees nothing. Say in the same reply that focus is about to move.

Not archived. The window mechanism already prevents repeating content, so there is nothing to
compare against.

---

## 9. The user-facing issue check

Runs every time unless `--no-issues`. **Its output never goes in the post.**

### What counts

A **defect or rough edge a manager would notice** (for Sonar, an agent; see the audience note
at the top). Two categories:

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

Every gh command here, the reads that find the candidates included, runs through `gather.js gh`
so it runs as the repo's account (section 1, "Which account reads each repo"). For each issue
judged user-facing:

```bash
node ~/.claude/skills/pennie-dev-update/gather.js gh -- issue edit <n> --repo <owner>/<name> --add-label user-facing
node ~/.claude/skills/pennie-dev-update/gather.js gh -- issue edit <n> --repo <owner>/<name> --remove-label priority-p3 --add-label priority-p2
```

A non zero exit is gh's own: the edit did not happen, so report it as failed, never as changed.

- Add the **`user-facing`** label. This is the durable record of the judgment, so the priority
  change has a visible reason and later runs can see what was already decided.
- Raise priority to **p2**, **unless it is already p0 or p1**, which would be a demotion. Leave
  those alone.
- Already p2: label only, no priority change.
- Create the label if missing:
  `node ~/.claude/skills/pennie-dev-update/gather.js gh -- label create user-facing --repo <owner>/<name> --color 0E8A16 --description "A manager would notice this"`

### Across runs

- Each run classifies issues **opened or updated since the last run**.
- Issues **already carrying `user-facing`** are revisited only to **remove the label** when the
  issue was misjudged. **A closed issue keeps the label** (Dan, 2026-09-16): it is the record
  of which fixes were manager-visible, and stripping it on close would erase that.
- **Never lower a priority.** Dan or a human reviewer may have set it deliberately.

### Report it

Print exactly what changed, one line per issue, old and new priority. A silent bulk mutation of
the backlog is not acceptable even when authorised.

---

## 10. Sequence

The scripts sit beside this file, at `~/.claude/skills/pennie-dev-update/`. Keep this run's
files in the session scratchpad.

1. For each repo whose `deployRecord` is a name read by hand (PET's `build_history`), read its
   newest row (section 4). Slate's and Sonar's are read by `gather.js` itself.
2. Gather, with one `--live` per repo read by hand (and `--only <name>` when Dan asked for one product):

   ```bash
   node ~/.claude/skills/pennie-dev-update/gather.js gather --live <owner>/<name>=<commit_sha>@<recorded_at> --out <scratchpad>/gathered.json
   ```

   Exit 0 is every repo gathered, 3 is at least one refused or unreachable (say which and why,
   carry on with the rest), 1 is the whole run refused. Each repo's `status` is `ok`,
   `first_appearance` (section 2: introduce it, list nothing), `refused` or `unreachable`. A repo
   refused because its account is not signed in names the account and the command that signs it
   in; give Dan both, word for word.
3. Classify (section 5) the `ok` repos' PRs. Read bodies where ambiguous.
4. Draft in the format (section 6), applying the accuracy pass (section 7).
5. Write it, run `lint-post.js` until it is clean, and open it in BBEdit (section 8).
6. Run the issue check (section 9), every gh command through `gather.js gh` so it runs as the
   repo's account, and print what it changed.
7. Commit the state, once per repo that was `ok` or `first_appearance`, naming the PRs the post
   listed and the headings it used:

   ```bash
   node ~/.claude/skills/pennie-dev-update/gather.js commit-state --gathered <scratchpad>/gathered.json --draft <file> --repo <owner>/<name> --listed <n,n,...> --headings 'HEADING ONE|HEADING TWO'
   ```

   Leave out `--listed` for a first appearance and for a repo the post listed nothing from.
8. Tell Dan: the window covered, how many changes, how many held back and why, how many could
   not be confirmed live and why (never folded into the held count), and what the issue check
   changed.
