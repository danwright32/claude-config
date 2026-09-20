# claude-config-sync

Two-way sync of selected `~/.claude` config between my Macs.

This file says what the tool does. [DESIGN.md](DESIGN.md) says what was tried and rejected, where
every threshold's number came from, and how much each guard is actually proven. Read it before
changing a design decision, so an approach that was already measured and discarded does not come
back.

## What syncs

- `payload/hooks/` — automation scripts
- `payload/skills/` — custom + installed skills (plugin-managed skills excluded, see below)
- `payload/agents/` — the `plan-*` agents
- `payload/commands/` — slash commands
- `payload/settings.hooks.json`: **only** the `hooks` block of `settings.json`
- `payload/CLAUDE.md` and `payload/RTK.md` — your global rules files, synced verbatim (standing cross-project instructions travel here)

Every mirrored file (hooks, skills, agents, commands) and the hooks fragment are stored with this
Mac's config directory written as `__CLAUDE_HOME__`, and expanded to each Mac's own on the way in,
so an absolute path inside one is correct on both machines. The top-level rules files are the
exception: they are merged entry by entry, so their bytes are left exactly as written, and a path
in one of them should be a `~` path. `hooks/check-home-paths.sh` enforces that split.

A file stored that way never equals its payload copy byte for byte, so every comparison between the
two sides goes through one view of the payload as it should look on THIS Mac. `claude-sync status`
did not, and reported three files as differing on every single run when nothing had moved, which
made the one report that would reveal genuine drift permanently carry three false alarms. It now
asks, per file, whether the placeholder is the whole of the difference, counts the ones where it is
and says so, and still names a file that has really changed even when it also carries the
placeholder.

One consequence, worth knowing before writing a synced file that talks about the sync: the
placeholder is expanded wherever it appears, and nothing can tell a line that MEANS the
placeholder from a line that means a path. A file naming it in prose, or running a shell
substitution over it, has its own text rewritten into one machine's home directory, which is
how a healthcheck came to report a path made of two homes glued together. Assemble it from
pieces in those files. The same guard refuses it anywhere it is not standing in front of a path.
(This README is not synced, so it can spell it out.)

## What NEVER syncs (stays private to each Mac)

Memory store, session history, caches, the rest of `settings.json` (model / effort / plugins),
and the local permission list (`settings.local.json`). A `pull` cannot overwrite any of these.

Plugin-managed skills are excluded so plugin updates don't cause churn, and so is
`skills/synced/`, where the Claude app downloads each account's built in skills. Both lists live
in `payload/hooks/lib/unmanaged-skills.sh` (`PLUGIN_SKILLS` and `PLATFORM_SKILL_DIRS`), which
`claude-sync` and `hooks/check-home-paths.sh` both read, so the check never judges a skill the
sync does not send. Edit that file to change them.

## Use

```bash
./claude-sync push              # send this Mac's config up
./claude-sync pull              # bring shared config down
./claude-sync sync              # two-way: send local, then receive remote
./claude-sync status            # show differences, no changes
./claude-sync hold 30 "why"     # stop the watcher committing while you commit by hand
./claude-sync release           # lift that hold now instead of waiting for it to run out
./claude-sync cite-scan L2      # which synced files cite that lesson number
./claude-sync reap-scratch      # reclaim scratch a killed run left behind
./claude-sync clean-backups     # remove the .syncbak copies a pull left beside your files
./claude-sync install-autosync  # background auto-sync (see below)
```

## Automatic sync

`install-autosync` sets up two launchd agents (and retires older ones), and installs
the `claudesync` shell alias:

- **`com.claudesync.watch`** — an fswatch process that runs a two-way `sync` on
  every change to a synced folder, however deep, so edits push within seconds.
  Requires fswatch: `brew install fswatch` (then re-run `install-autosync`).
- **`com.claudesync.timer`** (a periodic two-way `sync`, `SYNC_INTERVAL=86400`
  seconds by default, which is daily) so the other Mac's changes arrive even when
  this Mac makes no local edits. That number is a product choice about how often to
  sync, not a measurement, which is why it has no row in DESIGN.md's measured
  numbers table; what holds it honest is that it appears here on the line that names
  the setting, and the suite requires the two to agree.

It also adds this to `~/.zshrc`, so the shortcut arrives with the rest of the setup
instead of being added by hand on each Mac (`~/.zshrc` is deliberately not synced):

    alias claudesync='<repo>/claude-sync pull'

That step is idempotent: it never appends a second copy, it treats a `~` and the
expanded home directory as the same path, and if a `claudesync` alias already exists
pointing somewhere else it leaves your line alone and tells you rather than rewriting
your shell config. Override the target file with `SYNC_ZSHRC=<path>`.

Sending is automatic on change; receiving is automatic on the timer. A no-op sync
writes nothing (idempotent), so the watcher never re-triggers itself. On a merge
conflict the background job stops and fires a desktop notification.

### Backups a pull leaves behind expire on their own

A pull that overwrites a file keeps the previous copy beside it as `.syncbak`, and every later run
lists them. Nothing removed them, so the reminder became permanent noise and the whole line stopped
being read: two backups from 2026-08-31 were still being announced on every pull. A copy older than
`SYNC_BACKUP_KEEP_DAYS=90` days is now swept on the next run that writes one, and each removal is
named rather than done quietly. That number is a product choice about how long somebody might want
to reach back for a pre-merge copy, not a measurement, which is why it has no row in DESIGN.md.
`claude-sync clean-backups` removes them all now instead of waiting. A copy whose date cannot be
read is KEPT, because it is the only copy of somebody's pre-merge work and a guess in the deleting
direction cannot be taken back.

### A burst of edits is one send, and you can hold the watcher off

Everything that arrives while a send is running becomes ONE more send rather than one send each
(`SYNC_WATCH_DRAIN`, default `1` second of quiet before the loop decides the burst is over). Those
events are never simply dropped: anything the drain sees sends the loop round again, so the last
edit always goes out. Without this a run of saves produced a commit each, and since CI cancels a
superseded run there was effectively no build signal during active work (measured 2026-09-02: six
consecutive commits, five runs cancelled, one survivor).

`claude-sync hold [minutes] [why]` stops the AUTOMATIC send for a while, so a session can get its
own commit in with its own message rather than finding the watcher has already committed the same
files as `sync from <host>`. It holds the watcher only: `claude-sync send` typed by a person still
works, because the person asking is not the thing being held off. The hold fails open, which is the
point of the expiry: a hold that outlived the session that took it would silently stop the sync,
which is the hardest failure here to notice. It defaults to 30 minutes (`SYNC_HOLD_MINUTES`, a chosen number and not a measurement: what it
costs to be wrong is one more `hold` or one earlier `release`), lifts
itself when that runs out and says so, is listed by `claude-sync status` for as long as it is live,
and `claude-sync release` ends it early. A marker nothing can read is cleared and reported in those
words, never treated as a hold and never treated as absent.

### A sync stuck for an hour is said in the session, and so is its end

On 2026-09-17 one Mac skipped 57 sends in a row over 11 hours and refused 52 receives, because the
newest shared commit was red and the clone was behind. `claude-sync status` said so the whole time,
and nobody ran it, so edits made that day existed on one Mac only.

`hooks/sync-stuck-notice.sh` runs on every prompt and asks the clone each launch agent runs
`claude-sync stuck`, which is the same function status prints its "sending is stuck" and "receiving
is stuck" lines from, so the two cannot disagree. Once a stuck stretch has lasted past the threshold
it is said once in the session, in status's own words and naming the clone, and when the stretch
ends that session is told it is moving again. A count going up is the same stretch and is not said
twice. A record that is there and cannot be read, a stretch whose start cannot be read, and a clone
too old to have the command are each said once in their own words, never read as a healthy sync.
It asks nothing of the network and takes no lock: measured 2026-09-17, about 70ms per prompt with
one clone to ask, and 16ms on a Mac with no automatic sync installed, where there is nothing that
can stall unwatched and it says nothing.

What each session has been told lives in `claude-sync-stuck-<session>.state` under `$TMPDIR`.
Losing it costs one repeated notice.

| Setting | Default | What it does |
| --- | --- | --- |
| `SYNC_STUCK_NOTICE_AFTER` | `3600` | Seconds a stuck stretch must have lasted before a session hears about it. A chosen number, not a measurement: above an ordinary wait on CI, which is one run of five to eight minutes and routinely two, and well below the eleven hours it exists for. It matches the window after which a red shared repo already raises a desktop notification, so the two arrive together. Being wrong costs an hour of edits on one Mac in one direction and a notice about a stretch that was about to clear in the other. A value that is not a whole number of seconds is refused and the default used, said on the hook's stderr. |
| `CLAUDE_SYNC_STUCK_STATE_DIR` | `$TMPDIR` | Where each session's record of what it was told is kept. |
| `CLAUDE_SYNC_STUCK_NOW` | the clock | An epoch to use as now, so the suite crosses the threshold without waiting for it. |

## Lessons: an index in context, the full text on demand

`CLAUDE.md` imports the lessons index, one line per lesson (the rule, without its body or
provenance). `LESSONS.md` still syncs and still holds everything; it is simply not loaded into every
session. Measured on the real file: 117,050 bytes down to 33,549, with all 180 lessons present.

Read one in full with `./claude-sync lesson L174`, or open the entry in `~/.claude/LESSONS.md`. The
body is where the failure behind the rule is described, so read it whenever a rule is about to
decide something.

The index is ONE FILE PER SECTION of `LESSONS.md`, named `LESSONS-INDEX-<section>.md`, and CLAUDE.md
imports every one of them between two markers it also generates. Both limits on a file loaded into
every session are per file (the 140,000 byte budget in `hooks/test-rule-file-budget.sh` and the
platform's own banner at 150,000 characters), and the single file was 100,899 characters on
2026-09-19 and growing about 1,130 a day. Splitting removes that deadline and loses no rule: every
file still loads. It saves no tokens, which is the point.

The files are generated from `LESSONS.md` on every send and every apply, never maintained beside it.
A hand edit to one is overwritten on the next run, and a file whose section has been renamed or
removed is deleted, which is the point: a list kept by hand next to the thing it mirrors drifts, and
the drift is silent.

## When a merge cannot be done

The other Mac's version is applied and yours is kept beside it as `<file>.conflict-<host>`, with one
line naming what was only in yours. That copy is then the ONLY place that content exists, so every
later apply keeps reporting it, and `claude-sync status` lists it too, naming what it still holds
that the live file does not.

A file whose version here holds no line the arriving one lacks is not kept beside it at all. The
arriving version already contains everything this Mac had, so it is taken, nothing is left beside
the file, and the pull names the files it settled that way rather than passing over them in silence.
A copy of the dropped version does go to `.resolved/` in the repo clone, outside the mirrored
config, and is swept after two weeks, so a wrong resolution is recoverable without leaving a file in
`~/.claude/hooks` for somebody to delete by hand. A local
DELETION is not treated as contained even though its lines are all present in the arriving version:
the deleted line is work too, and the version this Mac last applied is what tells the two apart.

Both reports go quiet on their own: as soon as the content is back in the live file, or the copy is
deleted, there is nothing outstanding to report. A copy whose content is already in the live file is
still listed by `status`, named as safe to delete, because only you can decide to remove it.
## Receiving config checks what it just installed

A run that lands anything under `hooks/` runs `~/.claude/hooks/run-all-tests.sh` before it reports,
and folds the verdict into its closing line. Receiving is the moment config arrives that has never
executed on this Mac, and success reported without running any of it says exactly what a verified
success says.

Every path that receives, not `pull` alone: `sync`, which is what the receive timer's reconcile
runs, the reconcile that `send` falls through to when this Mac is behind (the watch daemon's own
path), and the `apply-only` resume point after the tool updates itself mid-run. The closing line is
printed once, by the lock's own release step, rather than added to each command, so a receive path
cannot be added without it and the suite is never run while the lock is held.

The verdict is also recorded in `.hook-tests`, with the runner's own words beside it, so a run from
the background daemon (which has no terminal, and whose notification is gone once dismissed) can
still be asked about afterwards. `claude-sync status` reports it while it is outstanding and goes
quiet once a later run passes. It reports the record held by any OTHER clone of this repo on this
Mac as well, and says which clone each record came from: which clone verified something is which
config was verified. Clones are found two ways, both derived from what actually runs rather than
from a list kept by hand: the launch agent plists name the script each background job runs, and
every clone writes itself into `~/.claude-sync-clones` the first time it takes the lock. The second
is what makes it work in both directions, since a launch agent only ever names the clone a
background job runs from.

The verdict comes from the runner's exit code, never from a line of its output, and there are three
outcomes rather than two: the suite passed, the suite FAILED (the config is on disk and a check on it
does not pass), or the suite could NOT be run or completed at all (nothing checked it). The last one
is deliberately not folded into the second, since they send a reader to different places.

A pass says how much of the suite it covered. `run-all-tests.sh` exits 0 when suites merely could
not RUN, and several of them need the git checkout and declare that anywhere else, which is every
deployed Mac, so a bare "the hook suite passed here" covers materially less than it sounds like. The
counts are read from the runner's own report rather than worked out a second time, they go into
`.hook-tests` too, and a report that cannot be read is said to be unknown rather than reported as
full coverage.

It runs with the sync lock RELEASED, after the config is already applied and on disk, so a pull
starting while it works is not refused. Holding the lock for it would starve the watch daemon,
whose only purpose is keeping this Mac current, with the very step that checks this Mac is current.

It runs only when a hook actually arrived, because the suite is minutes of work and the watch daemon
pulls constantly: a pull carrying a rule file has installed nothing this runner checks. Set
`SYNC_NO_HOOK_TESTS=1` to skip it outright, and `SYNC_HOOK_TESTS_TIMEOUT` (default `1800` seconds)
bounds how long the pull will wait before stopping it and saying nothing was verified. The runner is
told `SYNC_NO_HOOK_TESTS=1` in its own environment, because the test suite runs pulls of its own and
a pull that runs the suite would otherwise recurse without end.

### A send names what it keeps back

A path the shared repo has changed since this Mac last applied is held back from the send, because
the repo's copy is newer and mirroring this Mac's copy upward would revert the other Mac. The send
now names those files, says why, and names `claude-sync pull`, which merges the two copies entry by
entry, as the thing that settles it. Only files this Mac really holds something different for are
named, so a Mac that is merely behind does not get a line per send, and nothing is notified: the
watcher sends on every save and the next pull clears the condition.

`claude-sync status` says the same thing on the surface somebody reads when they suspect something
is wrong: while this clone holds config it has not applied, it names each file, says the send is
holding it back, and names the pull that settles it. It says nothing when every path the repo
changed is already here, which is the ordinary aftermath of this clone's own commits and repairs
itself on the next send (#515).

`claude-sync push` also records what it published, which `send` has always done. Without that, the
marker stayed at the previous commit, every path the push committed read as unapplied, and the next
push held those very paths back in silence. Measured on 2026-09-20: three lessons sat unpublished on
this Mac while every push reported a clean send (#511).

### Sending checks the hooks it is about to publish

A `send` runs the suites covering the hooks in that send, and holds back the hooks a failing suite
covers. The
pre push test gate is a Claude Code hook on `git push`, so it only fires for a push a session makes
by hand; the watcher commits and pushes on its own, and that was the one path with no coverage
requirement on it. Measured 2026-08-31: commit `f094409` pushed a 41 line change to
`hooks/lib/issue-spool.sh` with no test at all, and nothing reported it.

Which suites are relevant is asked exactly as `test-hook-coverage.sh` asks it: a suite covers a hook
when the suite's text names it. So a send that touches no hook runs nothing, and a hook edit runs one
or two suites rather than the whole set, which is what makes holding the lock across it acceptable.
A changed `test-*.sh` is its own relevant suite. A changed hook that NO suite names is still sent,
with a line saying plainly that nothing verified it, since the coverage ratchet is what gates an
uncovered hook and a send that ran nothing must not read like one whose suites all passed.

A red suite costs a trip to the hooks it covers, and to nothing else. The first version of this gate
refused the WHOLE send, which is the more expensive of the two failures: an unrelated red suite then
stopped rule files, skills and lessons reaching the other Mac as well, and a watcher that has quietly
stopped sending is already hard to notice from outside. So a send holds those hooks back, names them
and the suite on one line, and delivers everything else, which is the same "only that file waits"
rule a rule file with a duplicate lesson number already gets.

The held-back edit is untouched in `~/.claude` and goes out on the next send once the suite passes.
`SYNC_NO_SEND_TESTS=1` skips the gate for one run. `SYNC_SEND_TESTS_TIMEOUT` (default `600` seconds)
bounds how long it waits for a suite before stopping it, holding back the hooks it covers, and saying
it did not finish in time rather than that it failed.

A suite stopped at either deadline (this one or `SYNC_HOOK_TESTS_TIMEOUT`) is stopped with everything
it started: it is paused, its whole process tree is killed, and only then is it asked to end, so its
own cleanup runs. A suite still there after `SYNC_SUITE_STOP_GRACE` (default `10` seconds) is killed
outright. A plain signal to the suite is not enough: bash holds it while the suite is blocked in a
command substitution, so the wait after it used to last as long as whatever was blocking, with the
sync lock held (#464).

A verdict is remembered in `.send-suite-verdicts` against a digest of the whole staged hook set, and
reused while that digest is unchanged. That is a bound on cost, not a shortcut: the watcher fires a
send on every file event, so without it a suite that stays red is paid for again on every save, with
the sync lock held throughout. Any hook edit changes the digest and retires every entry, so a
remembered verdict can never outlive a change to what it judged, and the send says how many verdicts
it reused rather than saving the time silently.

## Hygiene guards on every push

Six guards fire on every `git push` in every project, with nothing to remember to run and no per
repo opt in file (Dan, 2026-09-18: "I don't want a new skill that I have to remember to run").
They came out of the dev team's 2026-09-18 review of Slate: ten confirmed findings, and every one
was a rule that already existed in prose with nothing checking it (L27), a known gap written in a
comment or a doc and never filed, a class fix that missed a sibling, or a doc claim that had gone
false. Each guard works out the repo's shape for itself and, where a repo lacks that shape, prints
ONE line saying it skipped and why, never nothing (L98). Existing problems never fail a push: each
guard judges what the push ADDS against its merge-base, so no guard needs a state file except the
bundle budget, which cannot avoid one. The thresholds were measured against Slate's real tree and
its last 40 real pushes, and each hook's header records the numbers and the cases it deliberately
does not catch.

| Hook | What fails a push | Escape hatch, one command only, explained first |
| --- | --- | --- |
| `check-duplication.sh` | A new copy of a long line (100 characters or more, `${...}` blanked) or a two line block (160 characters or more) under the source roots. Tests and fixtures are not judged. Slate: 6 of the last 40 real pushes would have been refused, each for a genuine copy. | `SKIP_DUPLICATION_CHECK=1` |
| `check-public-assets.sh` | An asset under `public/`, `static/` or `assets/` that this push added or orphaned and nothing references; a raster image added or changed over 250 KB. Names browsers fetch by convention are exempt; `.claude/hygiene-allow.txt` in the project holds the rest, one path and a reason per line. | `SKIP_ASSET_CHECK=1` |
| `check-deferrals.sh` | An added comment or doc line that defers work ("for now", "separate effort", "deferred to", "follow up" and the rest of `lib/deferral-phrases.txt`) with no `#NNNN` on that line or within two lines. `deferral-edit-check.sh` says the same thing at the moment the text is written. | `SKIP_DEFERRAL_CHECK=1` |
| `check-doc-issue-refs.sh` | A touched doc whose sentence claims an issue is still pending ("#N is the issue for", "once #N lands") when GitHub says that issue is closed or that pull merged. Anchored to the reference and blind to past tense, because 96 percent of the issues Slate's docs cite are closed. Fails open out loud without `gh`. | `SKIP_DOC_REFS_CHECK=1` |
| `check-bundle-budget.sh` | The gzipped client bundle (Next `.next/static/chunks`, Vite `dist/assets`) grew past both 3 percent and 10 KB over the recorded total, when the build output is newer than the commit. A stale or absent build is said and not judged. | `ACCEPT_BUNDLE_GROWTH=1` records the new total; `SKIP_BUNDLE_BUDGET_CHECK=1` |
| `ai-review-on-push.sh` | Nothing. It is advisory: after a successful push it hands the diff, plus the full text of the changed files, to `claude -p` in a detached process and returns at once; `ai-review-nudge.sh` prints the answer on a later prompt, once per session. It exists for the class no scan can see, a sibling left unchanged. | `SKIP_AI_REVIEW_CHECK=1` |

What each one measured, and what it does not catch, is in the hook's own header. Two worth knowing
without opening them. The duplication guard does not catch a copied two line block under 160
characters (Slate's day header cell is 131), because the setting that would catch it refuses one
real push in four, which is the setting nobody reads by the second week (L36). The deferral list
lost "later", "not yet" and "eventually" to measurement: 419 hits across Slate and not one a
deferral.

The AI review runs on the developer's own Claude subscription, so it costs usage allowance rather
than money. Its cap on what it sends (300 KB) skipped none of Slate's last 200 pushes; its
deadline is 240 seconds and a real review measured 130 to 193 seconds with `sonnet` on
2026-09-18. It runs only on the computers `AI_REVIEW_HOSTS` names, which by default is the work Mac
(`Dans-MacBook-Pro`), because Dan wants it there and not on the personal Mac; every other computer
says in one line that it skipped. Set `AI_REVIEW_HOSTS='*'` to run it everywhere.

## Lesson numbers

Each Mac mints lesson numbers from a band it owns, so two lessons written between syncs can never
claim the same number. `claude-sync next-lesson` prints the next free number in this Mac's band, and
`check-lessons` fails on a duplicate anywhere in the file.

An entry has to be written as `- **Lnnn. ...` to be a lesson at all. Everything here reads only that
form, so one written any other way (a heading, a list item with the bold left off) is invisible to
all of it at once: absent from the generated index that loads into every session, unretrievable by
`claude-sync lesson`, uncounted by the duplicate check, and holding a number `next-lesson` goes on
offering as free. `check-lessons` now refuses one, naming the file and the line, and a file holding
one is held back from the send the same way a collided number is. The number it claims is counted
whatever shape it is in, so even with the refusal overridden it cannot be handed out twice. The
generated index is exempt, since its own form is `- Lnnn.` and it is a rendering rather than a place
lessons live.

`check-lessons` also refuses three faults in what the index would show. A lesson's `SHORT:` line whose
significant words are mostly absent from its own rule (under 0.40 of them, a floor measured against
the real file) has drifted, and every session would read it in place of the rule (#369, #389). The
same rule stored under two numbers, compared by its words so a re-wrap is still the same rule,
renders into the index twice (#392). And an entry holding more than one `SHORT:` line leaves which
one the index shows to chance (#392). Each refusal names the lesson numbers. All of these, like the
faults above, come from one list that `check-lessons`, the send, and the hook that runs the moment a
lesson is written all walk, so none of them can disagree about what a fault is.

A lessons file held back takes everything rendered from it with it: every `LESSONS-INDEX-<section>.md`
beside it, and `CLAUDE.md` when its generated list of imports would name one of them (#483). The
refusal lists every file that waited. Publishing an index without its source would put a rule in
front of every session on the other Mac that its own `LESSONS.md` does not hold, and a rendered index
line is indistinguishable from a rule that exists.

A Mac claims its band the first time it asks for a number: the first Mac gets 1 to 500, the next 501
to 1000, and so on. The claim is one file per Mac under `lesson-bands/` in the repo, committed so the
other Mac can see it, and one file per writer means a claim can never produce a merge conflict. Two
Macs that claim while unable to see each other are settled by name order, the same way on either
Mac, and the one that moves says so. A band that fills up rolls over rather than spilling into the
next Mac's numbers: it claims the next free band, skipping any band that already holds numbers left
behind by a Mac that moved off it, and says which band it took. The numbers then have a gap in them,
which costs nothing, and nobody has to do anything.

Raising `SYNC_LESSON_BAND_SIZE` after a band has been claimed is refused rather than applied. The
size is global and the bands are contiguous, so a bigger size moves each band over the one above it,
and this Mac would mint numbers the other one has already published. The refusal names the Mac whose
band is being run into and the size that would fit.

### A number is a display, an id is the reference

A lesson's number can move. Both Macs mint from their own band and a collision still happened on
2026-08-29: each had used L521 for a different entry, and the pull renumbered this Mac's unsent one
to L523 (#199). Anything already quoting the number then points at a different lesson.

So a lesson also has an id, derived from its own rule sentence rather than stored anywhere, which
means there is no registry for two Macs to disagree about and nothing a merge can lose. A renumber
does not touch the rule text, so the id survives it. `claude-sync lesson` prints it beside the
number and accepts it in place of one:

```bash
claude-sync lesson f9c1041ccf
```

Citations inside the config are held to it. `claude-sync cite-pin` records what each cited number
names now, in `lesson-citations.tsv`, and `claude-sync cite-check` re-derives them: a number whose
id has changed is a citation that now points somewhere else, and it says which. A citation written
since the last pin is reported as unpinned rather than as a fault, because failing on that would
mean re-pinning on every commit that quotes a lesson.

## Skills that cannot load

A skill is a directory holding a `SKILL.md` whose frontmatter carries a name and a description.
Anything else under `skills/` is inert, so it is not carried in either direction: a push does not
send it and a pull does not write it onto this Mac. The run names each one and says why, rather than
skipping it quietly, because an entry that cannot load is indistinguishable from one that works
until somebody tries to invoke it.

A pull still leaves this Mac's own files under such an entry alone, but it does not list them with
the local edits that "go up on the next send", because the send refuses them. They get their own
line saying a send will not carry them and why, so a half-built skill is never reported as on its
way to the other Mac.

Measured against the real config on 2026-08-17, this refuses exactly four entries (two directories
holding no `SKILL.md` and two loose markdown files) and every one of the 43 real skills passes.

## Which plugins load (per Mac, and it does not sync)

Plugins are enabled per project rather than everywhere. A plugin that is off at user scope is turned
back on by `enabledPlugins` in that project's own `.claude/settings.json`, which travels with the
project's repo. Proven in a real session on 2026-08-17, with a control: a directory whose project
settings enable a user-scope-disabled plugin sees its skills, and a directory without those settings
does not.

`enabledPlugins` in `~/.claude/settings.json` is deliberately NOT carried between Macs, along with
the rest of that file. Each Mac has different projects checked out, so exporting one Mac's survey
would turn a fix here into a regression there. Set it on each Mac by hand, and read
`claude-sync status`, which prints what this Mac has on and off so the two can be compared.

## A skill provided twice

`claude-sync check-skills` fails when a skill name is provided by an installed plugin AND by
`~/.claude/skills/` or the synced payload, because both copies are then listed in every session and
both are paid for. `status` reports the same thing without being asked, so a duplicate that arrives
with a plugin install surfaces on its own.

The plugin side is read from the install record (`~/.claude/plugins/installed_plugins.json`), so a
plugin installed later is covered without anybody adding it to a list. A Mac where no plugin skills
can be found is told exactly that, rather than passing: nothing to compare against is not the same
answer as nothing wrong.

## Secret scan

Every push/sync scans the payload and aborts if it finds a credential shape.
Accept a known string by adding the sha256 of the matched text to
`.secret-allowlist`, or bypass once with `SYNC_SKIP_SECRET_SCAN=1`.

## Tests

```bash
bash payload/hooks/run-all-tests.sh
```

That is everything: it asks git which directories in the repo hold a `test-*.sh` and reads all of
them, so a suite added anywhere is picked up on the day it lands. Naming directories runs only
those (`bash payload/hooks/run-all-tests.sh tests tools`). A directory it was told to read that
holds no suite is a failure, not a quiet pass, because reading nothing and reading everything green
look identical otherwise.

### Proving a check would notice

A guard is only real once it has been seen to fail. That was done by hand here, by editing a
tracked file, running the section, and putting the file back, and on 2026-09-02 it gave the wrong
answer twice in one session: the fix was removed and the section still passed, so the test proved
nothing and would have shipped as proof (#276). Both times the fixture never reached the state
under test.

```bash
tools/prove-it-fails.sh --run 'bash payload/hooks/test-run-all-tests.sh' \
                        --sed payload/hooks/run-all-tests.sh 's/the line to break/x/'
```

Everything happens on a copy, so the tree you are working in is never touched and an interrupted
round leaves nothing behind. `--revert <file>` puts one file back to its committed state, which is
how a fix that is not committed yet gets removed. It runs the check BEFORE the change as well, so a
section that was already red cannot be mistaken for one that noticed.

It answers with three states and an exit code for each: PROVED (0), NOT PROVED (1), and REFUSED
(2), which is what it says when a patch matched nothing, because a patch that changed nothing
leaves the check passing for the reason it always did and that reads exactly like a check which
cannot discriminate.

The suites run several at a time, since they are independent. Measured on this Mac on 2026-08-21 over the hook
suites: 128 seconds one at a time, 29 seconds in parallel, with byte identical reports.

For the whole repo, take the number rather than trusting one written here. This command prints it,
along with the suites that account for most of it:

    time bash payload/hooks/run-all-tests.sh

Last taken on 2026-09-03: 76 seconds for the hook suites and the tools, of which
`test-run-all-tests.sh` was 73 seconds and `test-subagent-issue-harvest.sh` 41. Before 2026-09-03
that pair alone was 110 and 41: the runner bracketed the live findings spool by forking `wc` once
per file, and the real spool held 157 of them, so 414ms of every 600ms launch was that loop, paid
again by each of the 69 launches its own suite makes (#239). One `wc` over the glob, and a suite
that no longer reads the live spool at all, took the pair from 110 seconds to 70 under matched
conditions.

Taken on 2026-08-30: 3 minutes 11 seconds for the whole repo, of which `test-claude-sync.sh`
was 188 seconds. The wall clock cannot go below the single longest suite, so that one is the floor
and the only thing that moves this number.

The figure is given as a command and a date rather than as a sentence because the sentence here was
wrong for nine days and nothing could tell. It said 38 suites in 84 seconds, measured 2026-08-21,
and by 2026-08-29 the repo held 42 suites taking 195 seconds: 2.3x out, with the suite count stale
too. #41 pins DESIGN.md's thresholds to the code and this paragraph was outside it, because a
duration is not a setting and there is nothing to compare it against (#211, L210, L316).

Nothing here states a CURRENT suite count either, and that is deliberate rather than an oversight.
Every count above is part of a dated account of what was measured when, which cannot go stale
because it does not claim to be true now. A number describing the repo as it stands today would
need a check holding it to the repo, and until there is one the honest form is the command.

How much of the machine a run may take is ONE number (#136). The runner starts several suites at
once and one of those suites splits ITSELF into shards, so what is actually in flight used to be
the product of two numbers set independently and compared nowhere: a four core runner could carry a
dozen heavy processes, each spawning git and python of its own. That never went red. It makes
timing sensitive checks intermittently wrong instead, which is the hardest kind of failure to
attribute, and the sync suite's own deadline guard was measured firing at 1192s against a normal
200 on a loaded Mac, written down 2026-08-21. So the budget below is divided between the suites running at once, each suite
is told its share, and the product is printed at the top of every run.

| Setting | Default | What it does |
| --- | --- | --- |
| `HOOK_TESTS_BUDGET` | CPUs, capped at 8 | How many processes the whole run may have in flight. Everything else is derived from it. A value that is not a positive whole number is refused rather than guessed at. |
| `HOOK_TESTS_JOBS` | half the budget, but never fewer than 2 and never more than the budget | How many suites run at once. The floor of 2 is for the small machine: the CI runner has two cores, half of two is one, and every suite would have run strictly one after another while a second slot sat reserved. `1` runs them one at a time, which is what to reach for when a suite only fails alongside others. A value that is not a positive whole number is refused rather than guessed at, because it decides how many processes start. |
| `HOOK_TESTS_TIMINGS` | `~/.cache/claude-config/suite-timings` | Where each suite's measured wall clock is kept between runs, one small file per suite, keyed on the suite's path inside the repo. It is what the launch order is built from. Set it to empty to turn the record off, so a run reads nothing and writes nothing. Deliberately outside the config directory: a duration measured on this machine is not configuration, and mirroring it would make the other Mac order its runs by numbers from hardware it does not have. |
| `HOOK_TESTS_SLOTS` | set BY the runner | Each suite's share of the budget, which is the budget divided by how many suites are running at once. A suite that splits itself, which today is `test-claude-sync.sh`, reads it as how many of its own processes it may start. Point the runner at one directory holding one suite and that suite is handed the whole budget, so running the long suite on its own is as fast as it ever was. |

What the budget costs, measured on this Mac on 2026-08-21 as one pair of runs back to back: 124 seconds against
88 seconds for the same 38 suites run the old way (8 suites at once, each splitting itself four ways). The machine was 183% busy
under the budget and 319% busy without it, which is the oversubscription this removes. 36 seconds
is the price of every timing sensitive check in the repo being measured on a machine that is not
fighting itself.

Results are collected and printed in the order the suites were FOUND, never the order they
finished, so two runs of the same tree produce the same page and a difference between them is a
difference in the suites rather than in the machine's mood. Suites are launched longest first,
judged by what each one was last MEASURED to cost: every run records each suite's wall clock and
the next run orders by it. Lane 1 carries the largest share of the budget and lane 1 is whatever
launches first, so this is what decides which suite the machine is spent on.

A suite nobody has measured yet, which means a first run or a newly added suite, falls back to
file size and follows the measured ones. Size is a heuristic and bytes are not seconds, so the
run prints which of the two it used and for how many suites. Being wrong about the order costs
some wall clock and nothing else, because every result is collected and reported the same way
regardless.

Every suite ends with one machine readable line, and that is what the runner reads:

```
SUITE-RESULT passed=29 failed=0
```

The human readable summary stays exactly as it was; this is the line for code. Suites used to write
their totals five different ways and the runner had to work out which line was the score, which it
got wrong twice: it printed a per-check line where a verdict belongs, and it read `PASS=805 FAIL=0`
as 805 failures. A suite that prints no result line is still run and still judged, its score
guessed from its prose, and the runner NAMES it at the end rather than falling back quietly.

The main suite on its own:

```bash
bash tests/test-claude-sync.sh
```

It fans its sections out across four processes. Measured on 2026-08-21, 87 sections taking 82
seconds that way and 243 in a single process, with no single section dominating (the slowest five
were 22s, 13s, 11s, 11s and 9s), so there was nothing to speed up, only work to spread. The parent holds the one run at a time lock and the
shards run under it, so this is still one logical run.

| Setting | Default | What it does |
| --- | --- | --- |
| `SUITE_JOBS` | the runner's grant, or `4` | How many shards a full run splits into. Under `run-all-tests.sh` it defaults to `HOOK_TESTS_SLOTS`, this suite's share of that run's budget; started by hand it is 4. Setting it wins over the grant, because that is somebody asking rather than a share being allocated. `1` runs the whole thing in one process, which is what to reach for when a section only fails alongside others. A value that is not a whole number is refused, and so is a grant that cannot be read. |
| `SUITE_PLAN_ONLY` | unset | Prints `SUITE-PLAN jobs=<n> source=<where it came from>` and runs nothing. The number decides what a run costs, and the only other way to see which one was chosen is to pay that cost. |
| `SUITE_SHARD_COVERAGE_ONLY` | unset | Prints the shard's `SUITE-SHARD-COVERAGE` line, which names the sections it would run, and runs none of them. |
| `SUITE_SHARD` | unset | `i/n` runs the prelude plus every n-th section from the i-th offset, for running one slice by hand or on another machine. A spec that is not `i/n`, or that names a shard outside the range, or that would hold no sections at all, is refused rather than reporting a pass over a set nobody chose. |

The shards' totals are added up, and separately their COVERAGE is checked: every section after the
prelude has to be the target of exactly one shard (#137). Each shard prints what it selected and
the parent puts them back together, so a gap, a section claimed twice, a shard that said nothing,
and shards disagreeing about which sections exist each fail the run with their own message. The
totals cannot do that job: 817, then 830, then 943, every one of them legitimate, so a shard that
quietly selected fewer sections would just print a smaller number.

Sections are interleaved rather than cut into contiguous blocks, because their durations are
uneven and blocks would put several slow ones together.

The reported total counts every section ONCE, whatever the shard count (#146). It used to be the
sum of the shards' own totals, which moved with how much of the machine the run was granted:
measured on 2026-08-21, 873 checks in a single process, 920 across two shards, 986 across four and
1118 across eight, all of one file. Two things repeat, not one. Every shard runs the prelude, and
a shard also runs any section its own targets declare with a `# needs:` line even when another
shard owns it. So each shard now reports what its checks were worth in three buckets, the prelude,
its own targets, and anything it borrowed, and the headline is the prelude once plus every target.
The repeated runs are counted and reported beside it rather than folded in.

Two readings have to agree: the sum of the shards' result lines must equal that headline plus
everything that ran again. They are arrived at differently, one from each shard's result line and
one from its buckets, so a run where they disagree reports neither number as trustworthy. A shard
that says nothing about its sections, or shards that disagree about the prelude, fail the run with
their own message rather than being folded into a total that would silently be missing them.

Every push and pull request also runs the suite on a Linux runner
(`.github/workflows/tests.yml`). No path filter: the suite reads `README.md` and `DESIGN.md` as
well as the code, and checks every tracked file for Python bytecode, so filtering by where the code
lives would skip precisely the change that breaks it.

Run ONE section while iterating, which is the fast path:

```bash
SECTION_ONLY="lessons index is derived" bash tests/test-claude-sync.sh
```

That runs the preamble, the first four sections, and the one you named: under four seconds against
roughly six minutes for the whole suite. The first four sections are the only place in the file
that changes shared state, so everything after them runs in one fixed setting and can be run on its
own. All 73 of them can, measured by running each in isolation.

Where one section genuinely does continue another, it says so in a comment directly under its
heading, and that prerequisite is pulled in too:

```
section "== #17: a collision the merge creates is settled by renumbering the unsent entry =="
# needs: #15: duplicate lesson numbers must not be published or go unnoticed
```

There is exactly one of those in the file. It is a comment rather than an argument to `section`
because three separate checks in the suite read the heading line by stripping one trailing quote,
and one of them would have gone on passing silently while checking nothing.

A pattern matching nothing is an error, and so is one matching SEVERAL sections: it lists the
candidates rather than running the first and reporting success under the text you typed. Asking for
`SECTION_ONLY` and `SECTION_UNTIL` together is refused rather than one quietly winning.

If a section turns out to depend on something an earlier one set, the run is refused outright
rather than reported. That matters more than it sounds: an unbound variable inside a command
substitution kills only that subshell, so a section missing a fixture can lose several tool
invocations, print nothing but `ok` lines, and exit 0.

Every run copies this file into the tool's scratch and runs the copy, then removes it. Bash reads a
script incrementally, so editing the suite while a run is in flight makes the running shell resume
at the wrong place, and what comes out is ordinary looking failures in sections that are perfectly
fine. `SUITE_FROM_COPY=1` skips the copy and puts a run back in that state, which is how the checks
guarding it are watched failing.

Every push also runs each section the push CHANGED on its own
(`tests/audit-changed-sections.sh`), which is the only run in which a missing prerequisite shows up.
A push that does not touch the suite costs nothing there.

The older knob still exists for when you want everything up to a point rather than one section:

```bash
SECTION_UNTIL="conflict copies" bash tests/test-claude-sync.sh
```

Every section closes with how many checks it ran and how long it took, and a run ends naming the
five slowest, so "the suite is slow" names a section somebody can act on. The counts are derived by
subtraction and the suite asserts they add up to its own total.

The suite also scans itself for assertions that could pass on output the command prints anyway: two
greps over one captured blob, or a match on nothing but a path, in output that lists paths already.
It prints what it found with a count and holds the numbers to a ceiling, so nothing new is added
while the existing ones are worked through.

It looks for three shapes, and all three are now at ZERO, so any of them fails the suite. The six
double greps were rewritten to require one line carrying both facts. The twenty-one bare path
assertions now name the file next to the fact about it: not `added.sh` but `added.sh reported as a
new file`, not `GONE.md` but `GONE.md is referenced and not on this Mac`. The forty that matched one
bare word now name what the word was about: not `kept` but `kept local edits ... skills/reel/push.py`,
not `retired` but `RETIRED, no sign of it since`. In none of the three families did the legitimate
case the ratchet was left open for actually exist.

Because a zero is read as proof rather than as a measurement, the scan counts every form this suite
has for feeding a captured output to a matcher (a pipe, a herestring, a `case`, a `[[ ]]`), and all
three zeros are backed by a positive control: one instance of each is planted in a copy of the file
being scanned and all three counts have to move to exactly one. Each pass was deliberately broken in
turn and measured passing its ceiling while failing only that control. A negated half never counts,
since an absence cannot be supplied by an unrelated line, and neither does an anchored pattern, a
regex doing real work, or a word grepped from a file the fixture wrote.

`claude-sync status` opens with when config last moved in each direction and when the repo was last
reachable, so a pending list can be read against all three: four files waiting means one thing an
hour after the last send and something very different three weeks after. The first two are the last
time something actually moved, not the last time a sync ran, because a stamp that advanced on every
run would make a Mac with nothing to do look permanently healthy. Reachability is the one that tells
a stuck Mac from an offline one, and it is deliberately labelled as saying nothing about whether
anything crossed.

It also scans itself for check names used more than once. A failure prints the name and the
expression and nothing else, so two checks sharing a name leave you searching the file for which
scenario actually broke.

For writing new checks there is `line_has "$output" 'fact one' 'fact two'`, which passes only when
ONE line carries every fact. That is the form all three bans exist to enforce, so the correct thing
is now the shortest thing to write. It takes two patterns minimum and refuses one, because a single
pattern is the weak form itself and hiding it behind a helper would put it out of the scan's sight.

And it scans itself for settings named in a comment or in this README that the code never
references. One of those had been sitting there describing a way to run a single section that was
never built, under a name that does not exist, and it cost two wasted runs before anyone noticed.

One run at a time, and none of them open ended:

| Setting | Default | What it does |
| --- | --- | --- |
| `SUITE_TIMEOUT` | `3600` | Seconds of wall clock before a run is killed however well it is going. Since #152 this is only an absolute ceiling for a runaway, not what catches a hang: `SUITE_STALL_TIMEOUT` does that. Generous on purpose, because a full single process run measured 348 seconds idle and 1943 at load 160 to 188 on 2026-08-22, so a tighter one kills a healthy run on a busy Mac. It also has a floor of twice `SUITE_STALL_TIMEOUT`, checked by the suite: a ceiling that expires first means the stall bound can never fire, and every real hang is then reported as a run that simply went on too long. At the end of a full run the suite says whether the ceiling still has room over the wall clock that run took, and uses the run's own processor time to tell a suite that has grown from a machine that was busy. `0` disables it. |
| `SUITE_STALL_TIMEOUT` | `1200` | Seconds a run may go without reaching a new section before it is killed as hung and told which section it stopped in. This is what actually catches a hang, and a machine that is merely slow keeps moving between sections and is left alone. Re-measured 2026-08-22 across four loads: the slowest single section was 44 seconds idle, 88 under three competing full runs, and 208 once, so this is at least 5.7x the worst observed. It was 600, which at a 3x floor left no room at all once the suite had grown, and a busy afternoon turned the run red with nothing wrong. The suite checks that ratio against the sections the run really took rather than against this sentence, and prints the margin it achieved on every run so a shrinking one is visible before it fails. `0` disables it. Both this and `SUITE_TIMEOUT` at `0` is refused, since that is a run with no bound at all. |
| `SUITE_LOCK` | `$TMPDIR/claude-sync-suite.lock` | Where the one run at a time lock lives. A second run REFUSES, naming the process that holds it and how long it has been going, rather than queueing. |
| `SUITE_NO_LOCK` | unset | Run without taking the lock. For when you know the run it names has finished. |
| `SUITE_LOCK_MAX_AGE` | `1800` | Seconds after which a lock from ANOTHER machine is broken. A lock from this machine is judged by whether its process is alive, never by the clock, so a clock jump cannot break a live one. |
| `SUITE_MAX_DEPTH` | `1` | How deeply a run may be nested inside another. The suite runs itself as a subprocess in many places, every one of them one level down, and past this it refuses to start rather than multiplying. |
| `SECTION_ONLY` | unset | Run the preamble, the first four sections, and the one named, plus anything it declares it needs. Refuses an ambiguous or unmatched name. |
| `SECTION_UNTIL` | unset | Run from the start up to and including the section named. Refuses to be combined with `SECTION_ONLY`. |
| `SUITE_FROM_COPY` | unset | Set to `1` to run this file in place rather than from a copy. It exists so the checks that guard the copy can be watched failing, and it puts a run back in the state where editing the suite mid-run corrupts it. |
| `SUITE_SLOW_IN` | unset | Pause deliberately in the section named. It exists so the duration column can be watched reporting a known number: most sections legitimately read 0s, and a broken clock would read 0s everywhere too. |

## Scratch left behind by a killed run

The suite and every apply create scratch in `$TMPDIR/claude-sync` and remove it on the way out. A
run that is force-killed never gets there. `claude-sync status` reports what has been abandoned
(how many, how much space, and what those runs were doing), every mutating run reclaims it on a
daily cadence, the suite reclaims it at the start of each run, and `claude-sync reap-scratch` does
it on demand.

A run that creates any scratch also writes one note beside it naming the date, its process id and
the command it was executing. The note is removed on the way out like everything else, so only a
killed run leaves one, and `status` reports which commands the killed runs were running. A count
says the temp folder is filling up; the commands say which part of the tool is being killed, and
only the second can be acted on.

The daily cadence is a stamp on disk rather than a timer in the watch daemon's memory. It was a
variable set to "now" when the loop started, and the daemon is restarted every time `claude-sync`
itself changes, so a twenty four hour timer restarting more often than daily never reached its own
deadline and the sweep never fired: `status` reported 73 abandoned items on 2026-09-04 with a
manual command as the only remedy. Reading it from a mutating run rather than from the daemon also
covers a Mac with no watcher installed. `status` never removes anything, however overdue the sweep
is: it is an inspection.

Only paths carrying this tool's own names are ever touched, never "old directories in the temp
folder": on the day this was measured that same directory held 542 anonymous ones belonging to
other tools. Nothing younger than `SYNC_SCRATCH_MAX_AGE` is removed either, so scratch a live run
is still using is safe. The directory holding them is not scratch and is never swept.

Scratch used to be created directly in the temp root, and the sweep therefore had to read the
whole of it: 113,912 entries on this Mac, 25 of them ours, which was most of what a
`claude-sync status` call cost. Everything an earlier version left there is still reclaimed, but
that location is now read on an interval rather than on every call, and `claude-sync reap-scratch`
reads it every time whatever the interval says.

| Setting | Default | What it does |
| --- | --- | --- |
| `SYNC_SCRATCH_ROOT` | `$TMPDIR` | The temp root. Scratch is created in the `claude-sync` directory inside it, and the sweep looks there and, on an interval, in the root itself. |
| `SYNC_SCRATCH_DIRNAME` | `claude-sync` | The name of that directory. It is half of the pattern deciding what `reap-scratch` may remove, so anything that is not a single directory name is refused. |
| `SYNC_SCRATCH_MAX_AGE` | `14400` | Seconds before scratch counts as abandoned. Four times the suite's own 3600 second ceiling, so the longest run the tool permits is a quarter of the way to being swept, and 2400x the 6 second sync timed on 2026-08-17. The ratio against the ceiling is checked by the suite rather than stated here, because these are one setting living in two files and #152 moved half of it. The cost is that a burst of interrupted runs is not reclaimed until four hours after the last of them. `0` turns the sweep off entirely, and a value that is not a whole number is refused rather than guessed at. |
| `SYNC_REAP_INTERVAL` | `86400` | Seconds between automatic sweeps of the tool's own scratch directory, read from a stamp inside that directory so a restarted process cannot reset it. Only mutating commands sweep, through the same handler that releases the sync lock, so no read-only command ever removes anything. `0` sweeps on every mutating run, and a value that is not a whole number is refused. |
| `SYNC_SCRATCH_NOTE` | `1` | Whether a run writes the note naming what it was doing beside its scratch. `0` turns it off. |
| `SYNC_SCRATCH_NOTE_ECHO` | `0` | `1` prints the note's path and content to stderr as it is written. It exists so the writer can be watched working: without it the only observable trace is a note a killed run left behind, which a test has to plant by hand, so the whole thing could be inert and every check would still pass. |
| `SYNC_SCRATCH_LEGACY_EVERY` | `86400` | Seconds between reads of the old flat location in the temp root. Reading it is what costs six figures of directory entries, so it is not done on every call. The cost is stated: something left there can go unreported for up to this long, though `reap-scratch` always reads it. `0` reads it every call, and a value that is not a whole number is refused. |
| `SYNC_SCRATCH_DU_TIMEOUT` | `30` | Seconds each `du` sizing abandoned scratch may run before it is stopped, and the size reported as not known rather than as the part that was read. The alarm is set on `du` itself, so it holds even when the `status` that started it has been killed. `0` lets `du` run unbounded, and a value that is not a whole number is refused. |

`claude-sync status` also reports watcher processes and test runs the tool left behind, counting
how many started independently and how deeply they are nested. It stays silent for one watcher
and one run, which is what a healthy machine looks like.

It reports this repo's test suites too, any `test-*.sh` or the runner, whether run from a checkout,
the installed hooks or the scratch the suites build their fixtures in (claude-config#444). It speaks
when one has been running longer than `SYNC_SUITE_MAX_AGE` (default `3600`, the longest any suite
may run) and then names every such process in one `kill -9` line, or when more than
`SYNC_SUITE_MAX_ROOTS` (default `8`) were started independently, since a whole run of the runner
counts as one. Nobody runs status while a pile is slowing them down, so `hooks/suite-pile-notice.sh`
says the same thing on a prompt (claude-config#466): both call `hooks/lib/suite-pile.sh`, so they
cannot disagree, and the notice names the same `kill -9` line (or sends you to status when it is
longer than fifty pids). It is said once per stretch in each session, and a stretch ends only after
`SYNC_SUITE_PILE_REARM` (default `600`) seconds of no pile, so suites flickering across the breadth
limit are one notice. It reads the process table and nothing else, and says nothing on any error.
Measured 2026-09-19 on this Mac: about 58ms per prompt.

Every suite in this repo arms `hooks/lib/suite-deadline.sh`, so it bounds its own wall clock however
it was started, and whatever it started is killed if it is stopped from outside. The limit is
`SUITE_WALL_DEFAULT`, one number for every suite, derived and dated in DESIGN.md's measured numbers
table from the slowest suite that takes it, and overridden for one run by `SUITE_WALL_TIMEOUT`,
which set to 0 turns the deadline off. `tests/test-claude-sync.sh` is the one suite with a limit of
its own, its `SUITE_TIMEOUT` plus a margin, because a healthy run of it on a loaded Mac outlasts the
shared default. A suite that does not arm it is a failure in `test-suite-deadline.sh`, which scans
the suites the runner runs, so the next suite added cannot quietly have no bound
(claude-config#465).

## Branches and agent worktrees that already shipped

This repo squashes on merge, so a merged branch is never an ancestor of main and every local way of
asking reports every branch as unmerged (L642). Two tools in `tools/` answer the question instead.
Both take a checkout as their argument and default to the current directory.

`tools/shipped-branches.sh` lists the remote branches and says which have shipped, by ancestry
(proof), by a merged pull request whose head is the branch tip (proof, read with `gh`), or by a
squash commit on main carrying one of the branch's subjects (a guess). It changes nothing, so a
guess is allowed. When `gh` cannot be read it says so above the rows, stops asking, and marks each
row that fell back to the guess "GitHub not read", never unmerged.

`tools/shipped-worktrees.sh` lists the agent worktrees under `.claude/worktrees/` and marks each one
REMOVABLE or KEEP, naming every reason it keeps one. REMOVABLE needs all of: GitHub (read with `gh`)
reports a merged pull request from its branch and none still open; no uncommitted or untracked
files; no commit that is not on main, on the remote branch, or at the head the merged pull request
recorded; not locked (Claude Code locks the worktree of a running agent); and no running process
has its current directory inside it. It reports and changes nothing unless given `--remove`, which
removes each REMOVABLE worktree with an unforced `git worktree remove`, deletes its local branch,
and names each removal. It never touches a remote branch or the primary checkout. When `gh` cannot
be read it refuses the whole run with exit 3 rather than treating unreadable as either answer.

```
bash tools/shipped-worktrees.sh ~/Non-icloudDocuments/Apps/claude-config
bash tools/shipped-worktrees.sh --remove ~/Non-icloudDocuments/Apps/claude-config
```

It is a sibling of `shipped-branches.sh` rather than a mode of it because it deletes things and so
may not act on a guess, and it is not a `claude-sync` command because it is about any git checkout
rather than the synced config. Which branch counts as main is one rule both read, in
`tools/lib/default-branch.sh`, and how GitHub's record of a branch's pull requests is read is one
reading both use, in `tools/lib/pull-requests.sh`.

## Local state (per Mac, never synced)

Thirteen things hold state outside `payload/` and belong to the Mac that wrote them. All are gitignored,
so a fresh clone starts without them. (`lesson-bands/` and `lesson-citations.tsv` also sit outside
`payload/` and are the two exceptions: both are tracked and shared on purpose. A band nobody else
can see cannot stop anybody else claiming a number, and a record of what a citation was written
about is a fact about the shared payload rather than about one Mac. See Lesson numbers above.) A folder COPIED or RESTORED from a backup carries stale ones, which is why each has a
defined answer for being absent or untrustworthy.

| File | Written by | Read by | Missing or stale |
| --- | --- | --- | --- |
| `.last-applied` | every apply, and a `push` or `send` whose payload is fully applied here afterwards | the guard that blocks sending while behind, and the staging that holds back what the repo has changed | absent means nothing is protected yet, so sending is allowed. A `push` records it only when nothing was kept back, because this Mac may hold commits it has not applied and claiming otherwise would let the next send revert the other Mac (#511, #514) |
| `.last-success` | a successful pull, fetch or push | the outage clock | absent, unparseable, or dated in the FUTURE all mean "no record", which alerts rather than staying quiet |
| `.last-sent` | a push that went through | `claude-sync status` | absent means nothing has ever gone up from this clone, which is said in those words rather than shown as a date; a value that will not parse is reported as unreadable, never as never |
| `.last-received` | an apply that wrote at least one file | `claude-sync status` | same three answers as `.last-sent`. It does not move for an apply that only rebuilt the hooks block, since that is regenerated from whatever payload is present, including one this Mac just staged itself |
| `.hook-tests` | any run that reached a verdict on the hook suite it installed: `pull`, `sync`, the reconcile `send` falls through to, or `apply-only` | `claude-sync status`, in this clone and in any other clone on this Mac | absent means nothing has verified anything here yet and status says nothing, since it reports what needs attention. A record that will not parse is reported as unreadable, never as a pass. A pass is silent; every other outcome keeps its own wording, so a suite that FAILED and one that could NOT be run stay apart. It also carries how many suites ran and how many could not, with `?` where the runner's report could not be read, which is never written as zero. Since #218 it carries the measured wall clock too, and a PASS is no longer silent: it reports how long that run took against the deadline it is given, and says so plainly when it has used over half of it, so a suite outgrowing `SYNC_HOOK_TESTS_TIMEOUT` shows up as headroom shrinking rather than as a timeout on the day it runs out. A record written before that field existed says no duration was recorded, which is never folded into being within budget |
| `.resurrected-reported` | a send that refused to publish a leftover copy back over a deletion, and was told to keep it with `SYNC_ACCEPT_DELETIONS=0` | that same refusal, to say it once per file rather than on every edit. With the default, which removes the leftover, there is nothing left to repeat and nothing is written here | absent means nothing has been refused here, which is the normal state. Each line is the path AND a digest of its content, so a file that CHANGES is a new decision and is reported again, and a file the person deletes or edits stops matching. Losing it costs one repeated message and nothing else, which is why it is not treated as important state |
| `.ci-unreadable-since` | the automatic pull, the first time it cannot read whether the shared repo's head passed its tests | that same gate, to decide when to stop waiting for an answer that is not coming | absent means the last verdict was readable, whatever it said, which is the normal state. It holds when the condition started and, once expired, when that was first reported, so the alert is raised on the transition rather than on every edit. Any readable verdict removes it, including a red one, because those mean the lookup is working. Expiring does NOT remove it: once the verdict is judged unobtainable, config keeps arriving until the lookup works again, since restarting the clock would deliver config in three hour bursts. A value that will not parse is treated as the condition starting now, which errs toward waiting rather than toward applying unjudged config |
| `.behind-skips` | a watcher send that found itself behind and whose reconcile did not clear it | `claude-sync status`, `claude-sync stuck` and so the per prompt notice, and the escalation that tells you once rather than on every edit | absent means sending is not stuck, which is the normal state and is said by saying nothing. It holds the count, the moment the run of skips started, and the moment of the last one; any run that gets through removes it, so the count is a measurement of the current state rather than a total that only grows. A count that will not parse is counted from zero again by the next skip, and until then status and the notice say the record could not be read, never that sending is stuck and never nothing |
| `.ci-red-since` | the automatic pull, the first time the shared repo's head reads as having failed its tests | `claude-sync status`, `claude-sync stuck` and so the per prompt notice, and the escalation that tells you once rather than on every tick | absent means the shared repo's head is not red, which is the normal state and is said by saying nothing. It holds when the run of red verdicts started, how many there have been, and, once past its window, when that was first reported, so the alert is raised on the transition rather than on every automatic tick. The clock is on the CONDITION and not on the commit: keyed per commit it would reset on every push, and a push is exactly what keeps happening while somebody is fixing the red. Any readable verdict that is not red removes it, so the count measures the current state rather than growing for ever. Unlike `.ci-unreadable-since` it never expires into applying anyway: nobody can act on an unreadable verdict, and anybody can act on a red one, so the escape here is to tell a person rather than to lower the gate. Only the last field may be empty, because a blank middle column would be read as the one after it. A count that will not parse is reported as a record that could not be read, never as nothing |
| `.my-push` | the trap every mutating run passes through, when that run left this Mac level with the shared repo | the next run, to ask what became of it, and `claude-sync status` once the answer is in | absent means the last thing this Mac sent was judged and passed, or nothing has been sent, which is the normal state. It holds the commit, when the current run of failures started, and, once reported, when that was. The verdict is deliberately NOT waited for at send time: a run holds the lock and a test run takes minutes, so the sha is written down and a later run asks. A green or cancelled verdict removes it, cancelled because the workflow cancels a superseded run and there is nothing to report about one nobody finished. A push made while it still stands keeps its start time and its reported marker and only moves the commit, so a run of failures is announced once rather than per push. A verdict that never arrives is given up on after the same window an unreadable one gets. Only the last field may be empty |
| `.send-suite-verdicts` | a send that ran a suite covering a hook it is about to publish | the next send, to decide whether that suite has to run again | absent means every relevant suite runs, which is the pre-#269 behaviour and only costs time. An entry is keyed on a digest of the whole staged hook set, so any hook edit retires it; a verdict is never reused across a change to what it judged. A `fail` is remembered exactly like a `pass`, because what it saves is re-running a red suite on every keystroke while the sync lock is held |
| `.resolved/` | a conflict resolved automatically because this Mac's version held nothing extra | nothing reads it; it exists so a wrong resolution is recoverable | absent means no conflict has resolved itself here. Entries are swept once older than two weeks, and one whose date cannot be read is KEPT rather than deleted on a guess, since this directory holds the only copy of something |
| `.claude-sync-clones` (in your home, not in a clone) | every clone on this Mac, the first time it takes the lock | `claude-sync status`, to find the records other clones hold | absent means no clone has done work since this was added, so status reports only what it can reach through the launch agents. An entry naming a clone that has gone is skipped rather than reported, and nothing prunes it: the file is only ever appended to, so a run that dies part way cannot lose the entries already there |
| `.claude-sync-watch.pid` (in your home, not in a clone) | `claude-sync watch`, on the way up | the next `claude-sync watch`, to refuse starting a second one | absent means no watcher has started here since this was added, and the next one starts normally. The pid in it is confirmed against what that process actually IS before it is believed, because a stale pid is reused by the system constantly and a guard that trusts the number refuses to start over something unrelated. It is removed on the way out, and only by the watcher whose own pid it holds, so one watcher exiting cannot clear another's record |
| `.claude-sync-hold` (in your home, not in a clone) | `claude-sync hold` | the watcher's send, and `claude-sync status` | absent means no hold, which is the normal state. It carries an expiry and fails OPEN: once that passes it is cleared and the watcher says the hold expired, because a hold that outlives the session that took it silently stops the sync. A marker that will not parse is cleared too, and reported in its own words rather than as an expiry, since obeying it would stop the sync until somebody found the file and ignoring it silently would discard a decision somebody made |
| `.outage-log` | every outage decision | `claude-sync status` | absent means no decisions yet, and a line that will not parse is counted and reported as unreadable rather than skipped |
| `.sync-lock/` | any mutating run | every mutating run | a lock from THIS Mac whose process is alive is respected whatever its age; one from another Mac, or with no Mac recorded, is broken once older than an hour |
| `state/` | every apply | nothing reads the local copy; it exists so a marker is only republished when it changes | absent just means the next apply republishes |
| `refs/claude-sync-state` | every apply, pushed per Mac | `claude-sync verify` | nothing published means "cannot be answered", never agreement; a Mac silent for 60 days is reported as retired |

None of this travels between Macs except the published refs, and those deliberately never
land on the config branch: a marker commit there is a commit the other Mac does not have,
which the send guard correctly reads as being behind, and every send is then skipped.
