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
- `payload/mods/`: Claude Code mods, each a plugin folder, loaded on **both** Macs (see Mods below)
- `payload/settings.hooks.json`: **only** the `hooks` block of `settings.json`
- `payload/settings.shared.json`: the few other `settings.json` settings both Macs share, today
  `ultracode` (off since 2026-10-06) and the effort level per model, as
  `modelSettings.<full model name>.effortLevel` (`high` for `claude-opus-5-5`). It is edited in the
  repo, never published back from a Mac, and a pull writes each value into `settings.json`
  (refusing the whole file, by name, if it holds any key not on the allowlist in `claude-sync`, or a
  value Claude Code would not act on). Off is `false`, never a deletion. A `/effort` pick on one Mac
  lasts until the next pull puts the shared level back; change the level here instead.
  Because `settings.json` names an alias (`opus`), `claude-sync status` asks the claude command
  which full model that alias runs on this Mac (`claude -p --bare /model`, answered locally at no
  cost) and names it when this file has no effort for it, with the entry to add, so a newer model
  behind the alias is noticed rather than quietly running at its own default (#828). When the
  claude command cannot answer, status says it could not check, never that the model is fine.
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

Memory store, session history, caches, the rest of `settings.json` (model / plugins / any effort the shared file does not name),
and the local permission list (`settings.local.json`). A `pull` cannot overwrite any of these.
The two exceptions are the shared settings above and `statusLine`: a pull writes the status bar
mod's status line into `settings.json`, naming this Mac's own copy of its script, when no
`statusLine` is set. One pointing anywhere else is never overwritten, and `claude-sync status`
names it.

Any file named `*.local.json` inside a synced folder stays on the Mac that wrote it: the send
never carries it and a pull never deletes it. That is where a skill keeps a secret, such as the
tracker skill's `config.local.json` with its Apps Script write token (#675). A second Mac needs
its own copy, made by hand.

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

## Setting up a new Mac

Besides cloning this repository and running `./claude-sync install-autosync`, every Mac needs one
file the sync cannot carry: `/Library/Application Support/ClaudeCode/managed-settings.json`
holding `{"prependPlugins": []}`. It lives outside `~/.claude`, and writing it needs the Mac's admin
password, so it is made by hand once per Mac. Both Macs have had it since 2026-10-07 (#876).

Why it is needed: on a Team or Enterprise account (Dan's is one), or on any Mac with managed
settings, Claude Code's built-in security default seats itself ahead of every plugin and sends
every `classic.*`, `prompt.section` and `prompt.context` hook past the user tier our mods load in,
so those hooks never run and only a debug log line says so (#875). A managed `prependPlugins` list
that leaves it out moves it to last, where it still loads. Without the file, the mod hooks listed
in `tools/sec-default-bypassed-hooks.tsv` (scope-modes and manual-steps refusing a turn end, the
prompt text of ask-before-saving, picker-manners and manual-steps, goal-tracker's permission and
idle notices, auto-session-name) silently do nothing. The cost Dan accepted: any installed plugin
can then also sit ahead of the security default's checks.

Create it:

```bash
sudo mkdir -p "/Library/Application Support/ClaudeCode" && echo '{"prependPlugins": []}' | sudo tee "/Library/Application Support/ClaudeCode/managed-settings.json"
```

Check it works, from a new session (the file is read once, at startup), in any folder:

```bash
claude -p --debug --model haiku "run echo hi with Bash"
```

```bash
grep -h "sec-default@builtin not seated\|bypassed by cc-plugin-sec-default" $(ls -t ~/.claude/debug/*.txt | head -1)
```

It must print `cc-plugin-sec-default@builtin not seated: managed prependPlugins does not list it`
and no `bypassed by cc-plugin-sec-default` line. `claude-sync status` reads the file (never running
claude) and names it, with the command that fixes it, when it is missing, is not valid JSON, has no
`prependPlugins` list (any managed settings without one are what seat the security default), or
lists the security default in it. Set `SYNC_MANAGED_SETTINGS` to check another path.

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
edit always goes out. Without this a run of saves produced a commit each, and since CI then
cancelled a superseded run there was effectively no build signal during active work (measured
2026-09-02: six consecutive commits, five runs cancelled, one survivor). CI no longer cancels a run
on main at all (#594), so every commit there now gets a verdict, but one send per burst still saves
the runner the work.

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

### The lessons core (built, not yet switched on)

A subset of the index can load in place of the whole library (claude-config#564). The list is
`LESSONS-CORE.txt`, set only with `./claude-sync core-set <file of lesson numbers>`, which checks
every number is a lesson, measures the core in characters and refuses past 20,000 unless
`SYNC_CORE_OVER_CAP=1` (that is Dan's decision), and writes a `# count N` line so the other Mac can
tell a deliberate change from a damaged list. From it the sync renders `LESSONS-CORE-<section>.md`,
the same lines as the library, and CLAUDE.md imports those instead; the library files are still
written and still travel, so `claude-sync lesson` and every PR lessons review keep all of them.

With no list nothing changes, which is how it ships. A list that is empty, unreadable, names a
lesson that does not exist, or holds fewer lessons than it declares (or, undeclared, under half the
last one applied) loads the whole library instead, records why in `~/.claude/.lessons-core-state`,
and `lessons-core-notice.sh` says so once in each session. Switching it on is claude-config#566,
after the measurement in #562.

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

The same two settlements hold inside a `sync` whose clone has diverged from the shared repo
(#845). A rule file both Macs changed is merged entry by entry inside the rebase, and a file whose
own mod merges it (the account room nicknames) keeps the shared copy while this Mac's goes beside
it as `.conflict-<host>` for that mod. Anything else conflicting still stops the sync, and says to
reconcile by hand.

Both reports go quiet on their own: as soon as the content is back in the live file, or the copy is
deleted, there is nothing outstanding to report. A copy whose content is already in the live file is
still listed by `status`, named as safe to delete, because only you can decide to remove it.
## A typed pull waits its turn for the sync lock

Only one run that changes things works at a time, guarded by `.sync-lock`. A `claude-sync pull`
that finds the lock held by a live run on this Mac, most often the change watcher part way through
a send, waits for it rather than refusing (#850). It says whose lock it is (the change watcher's
send, or which command, with its process and how long it has held the lock), says it is still
waiting every `SYNC_LOCK_WAIT_REPORT` seconds (30), and says how long it waited once it goes ahead.
It waits at most `SYNC_PULL_LOCK_WAIT` seconds (720, twelve minutes, set on 2026-10-06 against the longest send it can wait behind) and then stops without
changing anything, naming the run that still holds the lock. While it waits it holds the place at
the front in `.sync-lock.next`, so a watcher send starting in between does not take the lock ahead
of it. Every other command keeps the shorter `SYNC_LOCK_WAIT` (90 seconds) and waits silently.

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

Only a change that came from the shared repo counts as one this Mac has not applied. A sync that
cannot reach the shared repo commits this Mac's edit into its clone and stops before applying, so
the marker stays behind a commit made here. Counting that commit held back the next edit to the
same file with a message blaming the shared repo for it. A path is now held back only when a commit
the shared repo also holds changed it, and when the clone has no copy of the shared branch to ask,
every path counts as before (#855). Two things that false hold back had been covering for now speak
for themselves: a `push` the shared repo refuses says it published nothing and, when the shared repo
holds commits this clone lacks, names `claude-sync sync`; and the rebase that settles entry merged
files carries on when it stops again on this Mac's next commit, rather than aborting.

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

A scan over every hook names none of them, so that question never picks it, and those scans were
what turned main red: of the 18 red runs from `sync from <host>` commits between 2026-09-08 and
2026-10-05, 16 failed one (short circuiting pipes, hook registration, hooks naming their repository,
short form drift, result lines) and the other 2 were flakes (#809). So a scan declares what it reads
with a `# send-gate: scans <paths>` line, paths relative to `payload/`, either anywhere in a suite
or on the line straight after a `section "..."` heading for one section of the sync suite. A send
touching those paths runs it, a section alone with its timing record off and the suite lock
skipped, and a red scan holds back the files in its scope like any red suite. Its verdict is
remembered against its scope and its own text, so a burst of sends pays once. Measured on
2026-10-05 on a loaded Mac: the four standalone scans take about 30 seconds together, the hook
coverage suite most of it, and each section about 8.5 seconds, while the watcher pushed about 12
times a day, a quarter of them within six seconds of the one before.

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
| `check-bundle-budget.sh` | The gzipped client bundle (Next `.next/static/chunks`, Vite `dist/assets`) grew past both 3 percent and 10 KB over the recorded total, when the build output is newer than the commit. A stale or absent build is said and not judged. The record follows every total that passes, so it never drifts behind main (#586), and a repository committing its own `bundle-budget.txt` is left to judge itself. | `ACCEPT_BUNDLE_GROWTH=1` records the new total; `SKIP_BUNDLE_BUDGET_CHECK=1` |
| `ai-review-on-push.sh` | Nothing. It is advisory: after a successful push it hands the diff, plus the full text of the changed files and the complete list of every file the push changed, to `claude -p` in a detached process and returns at once, with the lessons index in its prompt and the rest of the global config switched off; `ai-review-nudge.sh` prints the answer on a later prompt, once per session. It exists for the class no scan can see, a sibling left unchanged. | `SKIP_AI_REVIEW_CHECK=1` |

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

### The lessons review before a merge

Every pull request's whole branch, merge base to head and every file type, is read against the
recorded lessons before it can merge, on both Macs (claude-config#560). `ai-review-on-pr.sh` starts
the review in the background when `gh pr create` succeeds, and again for the new head when a push
lands on a branch whose pull request is open; `pr-review-gate.sh` refuses a merge until
the review of that pull request's head has finished and its findings have been READ. Printing them
is not reading them (claude-config#788: another hook can refuse the same merge and only its message
is shown, and the nudge reaches whichever session prompts next), so the gate's refusal and the
`ai-review-nudge.sh` message both carry a read key, and the merge is allowed once a merge command
presents it as `PR_REVIEW_READ=<key> <the merge command>`; until then every attempt is refused
with the findings again. A head
with no review gets one started by the gate. A repo whose own script merges inside it asks the same
checker, `lib/pr-review.sh check`, before merging: Overture's `merge_pr` does. `check` exits 0 to
allow, 1 to refuse on a verdict, and 3 to refuse because the review has not finished yet.

The same review is asked BEFORE a push, so its findings are fixed before GitHub sees the branch
and CI is not spent on a head the merge gate would refuse (claude-config#599; on 2026-10-02 every
after the fact catch in one Slate session was this review, at about 5 minutes of CI a round).
`ai-review-on-pr.sh` starts the review of a branch's new head when a `git commit` succeeds there,
so it has usually finished by the push, and `pr-review-push-gate.sh` asks `lib/pr-review.sh check
--gate push` before any push of a branch other than the default one. A review still running is
waited for, polling, for at most 100 seconds (`PR_REVIEW_PUSH_WAIT_SECONDS`, inside the hook's 150
second timeout so a slow review can never time the hook out into allowing); past that the push is
refused with how long it waited, and the review goes on for the next attempt. Unread findings
refuse the push with their read key, and `PR_REVIEW_READ=<key> <the push command>` goes through; 0
findings and an empty diff pass; a review that could not run refuses in its own words with the
restart command and `SKIP_PR_REVIEW=1 <the push command>`, explained to Dan first. A commit and a
push in one command is refused, because the head it pushes does not exist yet for anything to read.

The merge gate is exactly as strict as before. Reviews are keyed by repository (a hash of the origin
URL, so every worktree and clone of one repository shares them) and commit, so the merge finds the
push's review of the same head and starts no second one. But a key presented to a push is recorded
in `<review>.push-acknowledged`, which only pushes read, so the merge still needs the key itself
(the one the push was shown reads the same review). And because the push reviews from the default
branch, a merge into another base reuses a review only when that review's own base is an ancestor
of the merge base it is asked about, so it read every commit the merge brings; otherwise it is
started again over the whole range.

The review is the PULL REQUEST's, wherever the merge is run from (claude-config#852). The gate
labels it with the pull request's own head branch (`--branch`, from `headRefName`), never the branch
the merging checkout happens to be on, which on a shared primary checkout is another session's work;
without a label the checkout's branch is used only when it stands on the reviewed commit, and the
short commit otherwise. And the base it diffs from is fetched from origin first, never this
checkout's copy, which can be far behind (a merge from a primary checkout 130 commits stale diffed
305 KB against the 300 KB cap). When origin cannot be reached the review says its base may be stale.

A pull request the merge gate sends back for being behind its base (`block-red-merge.sh`, #766) can
be updated, waited on and merged in one step, run in the background from a checkout of the
repository: `bash ~/.claude/hooks/lib/merge-when-ready.sh <pr> [--repo owner/name] --squash`
(claude-config#851). It updates the branch, starts the new head's lessons review alongside its
checks, waits for both, updates again if the base has moved meanwhile (three times at most), and
then hands the exact pinned merge command to `block-red-merge.sh` and `pr-review-gate.sh` and merges
only when both allow it, so it decides nothing either gate would refuse. It carries only the merge
method and `--delete-branch`, and stops, in its own words, on a gate's refusal, on findings to read
(come back with `PR_REVIEW_READ=<key>` in front of it), on a conflict, or when its hour runs out.

Every outcome is named and none reads as clean by accident: finished with findings, finished clean,
still running (with elapsed time), did not finish, failed, came back empty, answered in some other
shape (`unparsed`), abandoned, could not run (no claude, no python3, no base), too large, and an
empty diff. All but the clean ones, the read ones and the empty diff refuse, naming
`bash ~/.claude/hooks/lib/pr-review.sh restart --dir <repo> --sha <head>` and the one command
override `SKIP_PR_REVIEW=1`, which is explained to Dan before it is used. The reviewer runs with
hooks off and with Claude Code's built in `ReportFindings` tool disallowed, because a review
reported through that tool leaves no finding line to read and came back `unparsed` in 6 of about 10
rounds on one pull request (#804). It also starts with no MCP servers (`--strict-mcp-config` and no
`--mcp-config`), since a review of a diff calls none of them and loading every connected one cost
startup on each review (#956).

Measured 2026-09-24: across the last 150 squash merges of claude-config, Overture, Ovation and
PostRoll, 11 of 600 branches were over the 300 KB cap it shares with the push review. Two real
reviews took 195 and 231 seconds against a 600 second deadline. Each review with findings adds a
line to `~/.claude/state/ai-review/citations.tsv` naming the lessons it cited, which the 14 day sweep
leaves alone, for the monthly re-rank of the lessons core.

Every opening and every finished review, whatever its outcome, is also recorded in
`pr-opened.tsv` and `pr-reviews.tsv` beside it, which the sweep leaves alone too. They feed the
measurement claude-config#562 gates the lessons core on: after two to three weeks, run
`bash ~/.claude/hooks/lib/pr-review-report.sh` on each Mac. It prints pull requests opened, reviews
by outcome, findings per review, how many reviews with findings were acted on (a later commit on the
pull request changed a file a finding named), and this Mac's half of the gate, UNMEASURED under 5
pull requests.

### What a push actually waits on

Seventeen PreToolUse hooks fire on a `git push` here, declaring timeouts of 10 to 300 seconds,
which the settings SET and are not measurements of anything. A declared timeout is evidence of what
somebody feared, not of what a gate costs, so they were timed:

```bash
bash tools/time-push-gates.sh --repo <checkout>
```

Measured on this Mac on 2026-09-21, driving each installed gate with the payload Claude Code sends
for `git push`, against a checkout one commit ahead of `origin/main`:

| What the push carries | Total before git runs | Where it goes |
| --- | --- | --- |
| A commit touching no test section | 20.1 seconds | `scanners-before-push.sh` 15.3, every other gate 0.3 each (2026-09-21) |
| A commit touching a test section | 26.0 seconds | `scanners-before-push.sh` 18.3, `linux-sections-before-push.sh` 1.5, the rest 0.3 each (2026-09-21) |

So the whole-tree scanner gate is three quarters of the wait and everything else is noise, which is
where any speed work belongs (L299). Two things the timing showed that no timeout could:

- `linux-sections-before-push.sh` returned in 1.5 seconds on 2026-09-21 having judged nothing,
  because docker is installed on this Mac and its daemon is not running. It said nothing at all, so a push nobody had
  checked on Linux read exactly like one that passed. It now repeats the audit's UNMEASURED notice
  (#523), and the audit's closing line no longer claims that sections it never judged passed.
- `require-tests-before-push.sh` declares 120 seconds, a number the settings set, for a model call
  it did not make on either push of 2026-09-21, because the change carried a test. The gate is cheap when the answer is obvious; the
  declared ceiling is for the case where it asks.

A scanner that already passed on exactly this tree and these uncommitted files is not run again
(#531). Measured on 2026-09-21: 14.0 seconds cold, 0.6 seconds when nothing it reads has changed.
That saving lands on a REPEAT attempt, a push blocked by another gate and tried again, because a
push that follows a fresh commit changes the tree and pays in full. Only a pass is remembered, so a
failure is never skipped past, and the gate says when it scanned nothing rather than reporting zero
scans as a clean run.

The readings are of the INSTALLED hooks, which is what a push waits on. A gate edited in this
checkout costs nothing until it is installed (L423).

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

The terminal line is said on every run, but the desktop notification is posted once per new folder:
the same set refused again posts nothing, a folder joining it posts again, and a set that only
shrinks is not news. A folder counts as told only once a notification was really posted, so one
held by the sleep record, turned off or failed is posted on the next run instead. The pull's notice
about kept local files a send will refuse works the same way. The record is `.unloadable-notified` in the sync clone (claude-config#968).

A skill installed as a git clone keeps its `.git` when the shared config retires it, because the
mirror never touches `.git`, so the retirement used to leave a folder holding nothing else, reported
as a skill that cannot load on every send. A pull now removes such a folder, saying so in one line,
but only on proof that nothing is lost: the shared repo deleted that skill and no longer holds it,
the folder holds nothing but `.git` and regenerable cruft (`.DS_Store`, `__pycache__`, `*.pyc`, `.claude-plugin/types`), and
no ref outside its remote-tracking ones (a branch, a tag, a note, the stash) and no reflog entry
reaches a commit its own remote lacks. A folder holding anything else (a `*.local.json`, a conflict
copy, any file somebody made, a commit only it has) is left alone and the pull says why
(claude-config#968).

## A copy left at an earlier release is stale, not a local edit

A file on this Mac that is byte for byte a version the shared repo once held for that path, no
longer holds, and has not been written since the newer version arrived on this Mac (judged on this
Mac's own clock, never a commit time another Mac stamped), carries no work of this Mac's. A pull replaces it with the current version and a send never publishes it; the send says it
held the file back and that a pull fixes it. This does not depend on the applied marker: on
2026-10-04 the marker named the merge of PR #636 while seven mod files were still the release before,
the pull called them local edits, and the next send mirrored them over main (claude-config#638). An
older version put back by editing the file here is newer than that arrival, so it is still a local
edit and sends as one. A file in a skill that cannot load here is left out, since a pull does not
write it either. A pull that writes nothing because it left files alone says so, rather than
"Already up to date".

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

### A refused send does not stop this Mac receiving

A send copies this Mac's config into the clone, scans it, and only then commits, so a refused send
leaves its staged copy uncommitted in the clone. That used to stop receiving too: `pull` refused
because git will not fast forward over local changes to a file the shared repo also changed, and
`sync` (what both automatic jobs run) ended at the scan before it reached its receiving half. On
2026-10-08 that meant the fix for a wrong scan could not arrive, because receiving was blocked (#947).

Now both receive. `pull` sets aside the uncommitted payload edits that stand in the way of the
files it receives, and `sync` sets aside everything the refused send staged, then fetches, rebases
and applies as usual. Each edit is checked against this Mac's own config first, which it was copied
from: when the live file holds it, the apply treats it as an edit this Mac has not sent yet (kept,
merged, or set beside the file as `.conflict-<host>` if the other Mac changed it too, exactly as
for any unsent edit). An edit the live file does not hold, such as one made in the clone by hand,
is kept beside the live file as `<file>.conflict-<host>` before anything is reverted, and `status`
reports it until it is dealt with. Edits are put back with `git checkout HEAD --`, never the stash,
which every worktree shares.

The scan is exactly as strong as before. A refused sync commits nothing, pushes nothing (commits
left by earlier runs included), closes by saying it SENT NOTHING and exits non zero with the scan's
own finding. The refusal is also recorded in `.send-refused`, so a later pull names it as the cause
of the edits it set aside. The edits go out on the next send that passes the scan. An uncommitted
edit OUTSIDE the payload is somebody's own work on the repository: a pull leaves it alone and
reports git's refusal.

`tests/test-payload-secret-scan.sh` runs that same scan, cut out of `claude-sync` by name, over
the payload git would carry, so a file that would block every send fails CI before it merges. A
placeholder in a shipped template is the usual cause: a key named `token`, `secret`, `password` or
`api_key` followed by 24 or more letters, digits, `_`, `+`, `/` or `-` reads as a credential, so
write placeholders with spaces or angle brackets (`<set by tracker.sh new-token>`).

## Tests

```bash
bash payload/hooks/run-all-tests.sh
```

That is everything: it asks git which directories in the repo hold a `test-*.sh` and reads all of
them, so a suite added anywhere is picked up on the day it lands. Naming directories runs only
those (`bash payload/hooks/run-all-tests.sh tests tools`). A directory it was told to read that
holds no suite is a failure, not a quiet pass, because reading nothing and reading everything green
look identical otherwise.

A skill's Python tests (`test_*.py` or `*_test.py`, unittest classes or plain `test_*` functions)
need no wrapper: `payload/hooks/test-skill-python-tests.sh` runs every one under `payload/skills`
through `hooks/lib/skill-python-tests.py`, found from disk. To run one skill's alone:
`python3 payload/hooks/lib/skill-python-tests.py payload/skills/<skill>`. Beside it,
`test-skill-integrity.sh` fails on a relative link in a skill's markdown that reaches no file and on
a file shaped like a test that nothing runs, and `test-skill-helper-exits.sh` on a skill helper that
can report success when it failed (claude-config#676, #677).

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

### Measuring the section time budget's margin

The sync suite fails a run whose sections add up past a fraction of the ceiling (#492). The margin
against that budget is a MEASUREMENT, and for a while it was not one: two readings taken hours
apart on 2026-09-20, 963s and 1847s against a 2520s budget, were read as the suite having grown.
Section time is wall clock per section, so it inflates on a busy machine, and neither reading
recorded what else was on the machine, so neither could be re-read afterwards (#517).

```bash
MEASURE_RUNS=3 MEASURE_WAIT_SECONDS=3600 bash tools/measure-section-time.sh
```

It takes several readings, because one per arm cannot be told from noise, and it records ambient
CPU beside each number rather than leaving that to be argued about later. `MEASURE_WAIT_SECONDS`
makes it wait for a quiet window first, judged against the floor THIS machine sits at rather than a
fixed bar, since a Mac running a backup, a sync daemon and two editors never reaches a fixed one.
`MEASURE_LOAD_PROCS=12` runs the other arm, under a load it starts and stops itself, so the two
arms differ in one known thing. `MEASURE_RECORD=<file>` appends a row per reading.

Each reading carries the load average as well as the ambient CPU, because the two say different
things: on 2026-09-20 this Mac sat at load 90 with an honest ambient CPU of a few hundred percent,
the difference being four backup and indexing daemons all waiting on the disk. Only the load
average showed why the suite took twice as long that evening.

The readings themselves live in `tests/section-time-readings.tsv`, and a section of the sync suite
recomputes the median, lowest and highest per arm from that file and requires the paragraph above
`SUITE_WORK_BUDGET_PCT` to quote them, so the prose cannot drift from the data. The record's
columns are named by the tool that writes them (`tools/measure-section-time.sh --columns`) and read
back by NAME, so adding a column cannot silently re-aim the reader (#524).

A fresh reading is taken once a month, at 02:00 on the 1st, waiting for a quiet window:

```bash
bash tools/install-section-time-schedule.sh          # and --remove to take it off
```

The job runs `tools/take-section-time-reading.sh`, which holds a lock so two readings never measure
each other, logs to `~/.claude-section-time.log`, and refuses rather than recording a number taken
on a busy machine. It appends to the record and commits nothing: a fresh reading makes the suite
fail until the paragraph is updated to match, which is the drift being caught rather than sitting
(#520). Monthly rather than weekly is Dan's call, taken on 2026-09-21, because each reading is a
suite run on a Mac somebody uses.

It refuses rather than reporting a flattering number: a run that failed, a run that emitted no
total, a machine that never settled, and an arm whose shard count moved partway are all
UNMEASURED, because a total of zero would clear every budget there is. The shard count is part of
it because the suite runs its prelude inside every shard and counts each copy, so a total taken at
four shards is not the same quantity as one taken at two.


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
A push that does not touch the suite costs nothing there. Before a session's push the hook
`linux-sections-before-push.sh` runs those sections on Linux in a container (`tests/run-on-linux.sh`)
when Docker is running, and reads the suite's own counts so that a failing prelude under a passing
section is reported as the prelude, with the way to tell a broken base from this change (#625).

In this repository that same hook refuses a session's push straight to `main`
(`ALLOW_DIRECT_MAIN_PUSH=1` for one push, explained first): a change goes up as a branch and a pull
request, whose CI runs every suite on Linux. The pre push Linux run cannot stand in for that. On
2026-10-05 its record on Daniels-MacBook-Pro-2 read 0 judged of the 15 pushes it had a section to
check, because Docker's daemon was not running, and it only ever covers sections of the sync suite
(#596). The automatic `sync from <host>` commits are pushed by claude-sync, not by a session, so
the refusal never sees them. The refusal is judged by where the push goes (#892): the directory it
runs in (a `git -C`, a `cd` in the same command, or the session's) and the URL of the remote it
reaches, so a scratch copy of this repository pushing to a local bare remote is left alone, while
claude-config under any remote name is still refused. A push that names `main`, or whose branch
cannot be read (a bare `git push`, `HEAD`), from a directory that cannot be resolved (a variable,
or a directory the same command creates) is refused rather than guessed at. A remote is judged by its
push URL's repository path (owner and name, any host or port), and the refusal stands down only when
that path is positively another repository: one it cannot read is refused too.

CI's environment step is the list the container is built from, and
`tests/test-ci-environment-tools.sh` fails when claude-sync or any shell file in the repository
invokes an interpreter or tool from its checked set (python3, perl, node, jq, rsync, pgrep and a few
more) that the step does not name (#624).

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

## Mods

A mod is a Claude Code plugin folder (`.claude-plugin/plugin.json` plus a hooks module) kept in
`~/.claude/mods/<name>/`. The `mods` tree is mirrored like `hooks`, so a mod added, changed or
deleted on one Mac reaches the other on its next pull. Unlike third party plugins, which stay per
Mac (#48), every mod loads on both Macs (#606).

Claude Code finds them through `CLAUDE_CODE_PLUGIN_DIRS` in the `env` block of each Mac's own
`settings.json`. That block does not travel, so every apply rewrites the value from the mod folders
actually present (a folder without a manifest is not named), and so does every send, so a mod
written on this Mac is named here at once rather than after this Mac's next pull (#628). A send does
this even when a gate (a hold, being behind) stops it publishing, and it never removes a mod folder:
only an apply clears the empty folder a removal on the other Mac leaves behind, and only for a folder this Mac last held as a mod (`.mods-seen`), so a mod folder just made here and still empty is never taken for one (#629). Only entries under `~/.claude/mods/`
are the sync's; any other folder named there by hand is kept. With none left, the key is removed.
The change reaches **new** sessions only: a running session keeps the plugins it loaded.

A change to a mod that is already named does reach running sessions: each one reloads the mod's
code, at once when idle and at the end of its turn when busy. When one delivery changes mod-kit and
a mod that starts using something mod-kit only now provides, a session can reload that mod first,
against the old mod-kit. Claude Code then unloads it, and its tools and commands are gone from that
session, although its notice says "the previous version stays loaded" (#960, measured 2026-10-08;
this is how the steps card lost `steps` and `steps_done` after #946). So mod-kit, at its own reload,
touches the manifest of every mod that depends on it and changed since mod-kit last started in that
session, and Claude Code loads each one again against the new mod-kit. The touch changes only the
file's time, so the sync carries nothing. The same can happen to a mod that depends on one of the
other mods that provide something (session-registry, status-bar, is-it-live, addon-notes), whose
reload mod-kit cannot see (#966). So mod-kit also looks at the start of each turn: a provider that
changed since the last look has reloaded by then, and each mod that depends on it and changed since
then is touched the same way, so its tools come back at the end of that turn. A mod that could not
be touched is named in the session (by a turn's look only the first time) and tried again at the
next look or mod-kit reload. If a mod's tools are still missing, a new session brings them back.

After each apply, and after a send that changed which mods are named, `claude plugin list --json`
and `claude plugin validate` are asked about every mod,
and the pull names any mod Claude Code does not list as enabled, or that validation refuses, with
the reason. When there is no `claude` command to ask (the scheduled job's short PATH falls back to
`~/.local/bin/claude`), the pull says the mods could not be checked rather than that they are fine.
This measures that each mod is configured and valid; it cannot see inside a running session.
Each `claude` question is stopped after `SYNC_CLAUDE_CHECK_TIMEOUT` seconds (30 by default; each
answered in under half a second when measured), because the check runs under the sync lock and a hung
`claude` would otherwise hold every sync behind it.

Deleting a mod deletes it on the other Mac. Deleting the whole `~/.claude/mods` folder does not: a
Mac with no mods folder cannot be told apart from one that never had mods yet, and reading that as a
deletion would wipe the other Mac's mods the first time a fresh Mac sends. Delete the mods inside it.

The mods in use, each with its agreed spec in its issue (milestone "Claude Code mods"):

| Mod | What it does | Issue |
| --- | --- | --- |
| `mod-kit` | What every mod shares, so no mod keeps its own copy: the boxed card a tool result row is drawn as (`$.modkit.card({ toolUseId, title, lines })`: a grey rounded border, a bold title whose runs may carry a colour, such as a leading state word, then lines of runs; a malformed card is refused by name), of which the grey card a blocked action is drawn as (`$.modkit.blocked`) is one use, the one reader of shell commands (`$.modkit.commands`: quotes, heredocs, the reserved words that lead a command (`then`, `do`, `else`, `{`), sudo, env, timeout, nice, xargs and the other words that only run the command after them, each read by its own options, a shell's `-c` alone or in a cluster such as `bash -lc` or `zsh -ec`, and a shell's script fed on standard input (a heredoc, a here-string, `echo` or `cat` piped in), each read as the commands it runs, `env -S`'s string, what `find -exec` runs past any wrapper, a `case`'s clauses, a redirect as its own word however it is spaced, a subshell's parentheses as commands their own; `$.modkit.pipeline` gives the same commands, each with the words of the command a `|` feeds it from, since only the reader can tell a pipe from a `;` or `&&`, the body of each heredoc feeding it and whether its delimiter was quoted, which stops the shell expanding it (#831), and for a shell or interpreter what it runs: its `program` (inline, or what its standard input gives it), the `script` file it runs instead, its `language`, and the `verdict` of the per language judge of inline code (writes files, runs a process, or cannot be read), moved here from scope-modes in #712), of which files a command changes (`$.modkit.writes({ command, cwd, home })`: redirects, `tee`, the destination of `cp`, `mv`, `ln`, `install`, `rsync` and `ditto` (into a folder, under each source's name), every file of `sed`, `perl`, `ruby` or `gawk` editing in place, `dd of=`, curl and wget's files (`curl -o`, `wget -O`, a file saved under the address's own name by `curl -O` or a plain `wget`, into `--output-dir` or `-P`, curl's cookie jar and trace, wget's log), each relative path resolved after any `cd` before it, and a variable the command set before the write (`F=path; ... "$F"`) read as its value where the reader can be sure of it; the other changes, in `changes`: a file removed (`rm`, `rmdir`, a `mv`'s source, `find -delete`, with its `tree`), stamped, emptied, made a folder or changed in mode; and the writes the words do not name, a patch, a program the judge finds writes, runs a process or cannot be read (with `targets`, the files a python program's text names as every one it writes, #830), a script on standard input, a file command `xargs` gives its files to, a download the server names or a recursive one), of git commands (`$.modkit.git`), of gh commands (`$.modkit.gh({ words })`: the subcommand and action past gh's global flags, each flag as pflag reads it, the positionals, the repository the command names itself, from `-R`, a github.com link or a `gh repo` owner/name, and for `gh api` its method, endpoint, fields, the repository its endpoint names as gh reaches it and its GraphQL document; moved here from scope-modes in #961, asked once per command beside `pipeline`), of the git checkout a path sits in (`$.modkit.workingTree({ path })`, found by its `.git` entry on the disk), of where that checkout stands (`$.modkit.branch({ path })`, #978: its main working tree, branch, default branch, whether it is on it, and the issues the branch names, every run of 2 to 6 digits on its own, from three git reads at once, each bounded at 3 seconds (a bound chosen on 2026-10-08 to sit inside a noun's 10, not measured); null in no checkout, and a branch git cannot read, a detached head or no main working tree `unreadable`, saying which; made for the design round guard, and read by scope modes (what winding down finishes, and the branches a push overnight is judged by) and the collision guard (the branch its judge is told) since #980, which deleted their own readings), and of a session's repository (`$.modkit.repo({ root, remote })`, given what `$.session.repo()` gives or a remote's address alone: `github`, its GitHub owner/name, null for another host or a local path, and `name`, the origin's last part on any host, else the checkout folder, a worktree under `.claude/worktrees/` naming its parent; an address read as git reads one, https, ssh with a user and a port, the scp form, git://, file:// and a local path, #951), of a repository as gh spells one (`$.modkit.ghRepo({ spelling })`, -R or GH_REPO, where owner/name alone is a repository, #961) and of the repository a github.com link names (`$.modkit.linkRepo({ link })`, a pull request's, an issue's or the repository's own, in the case the link spells it, #961), and the band above the prompt, which Claude Code gives one drawing: a mod publishes a row with `$.modkit.bandRow({ mod, id, slot, lines })` and takes it away with `$.modkit.clearBandRow({ mod, id })`, and mod-kit draws every row in the settled order of the slots (`needs-a-look`, `compact`, `room`, `handoff`, `held`, `steps`, `message`). No question is drawn in the band: since #744 and #777 every question is Claude Code's own dialog, and a row naming a `question` slot is refused. A row may carry a `frame` (`box`, a rounded border, or `left-rule`, a rule down its left edge, in an optional `color`, reaching down every row a wrapping run takes, #734). A line is plain data: text runs (`text`, `color`, `bold`, `dim`, `strikethrough`, `indent`, `wrap: true` for a run that goes on to the next line rather than being cut at the band's edge, and `href`, which draws the run as Claude Code's Link to that address) and Claude Code's own buttons (`button`, `label`, `hotkey`, `indent`, and `plain: true` for Claude Code's plain style, `1: 7 days` in place of `[ 7 days ]`), whose press reaches the publisher through `on('modkit.press', ...)` with the element `<mod>:<button>`, and which, wherever a click may not land (a terminal's main screen, Apple Terminal, whose per tab Allow Mouse Reporting no mod can read), is drawn instead as its `instead` text or "type: /press <mod> <button>" (#939; mod-kit's `/press` raises the same `modkit.press` a click does; `$.modkit.clickable(e)` gives a mod drawing its own Button the same answer, and `tools/check-mod-shared-parts.sh` fails a mod hooking `ui.press` for mod-kit's buttons or drawing a Button without asking); or a whole line may be `{ divider: true }`, a thin grey line across the card. A part's `indent` is the blank columns drawn before it. A side pane a mod opened with `$.ui.open({ id })` that shows a card is drawn by mod-kit too, with the band's own row drawing, so a card reads the same in both: the mod publishes it with `$.modkit.pane({ mod, id, lines, frame })` (a band row's lines and frame, no slot) and stops it with `$.modkit.clearPane({ mod, id })`; a pane id another mod already draws is refused. mod-kit also tries every mod's refused `$.session.send` once more, in its `session.send` hook so the message still arrives as the sending mod's, never after a throw (it may have landed), and answers the second refusal's reason trimmed of its full stop; a mod sends once and reports `reason`. A mod that answers a tool call itself, and so passes it to no guard beneath it, asks `$.modkit.screen(e)` before acting on it and answers with its refusal: mod-kit asks the secret guard wherever its folder sorts, answers null when the secret guard is not loaded, and refuses with the card when it cannot ask. `tools/check-mod-shared-parts.sh`, run by `tests/test-mods.sh`, fails any other mod that keeps its own copy, draws a result row or the band itself (any line naming `ToolResult` or `AbovePrompt` as a string, however the hook is written), draws a card's parts or left rule, retries a send, reads which files a command writes, walks up for a `.git` entry (`.git` as a whole path part however it is written, never `.gitignore` or `.github`), reads a git remote's address by hand (a pattern taking a trailing `.git` off, or matching `github.com` before a `:` or `/`, #951), reads a github.com link's repository by hand (a pattern capturing right after `github.com/`, #961), reads where a checkout stands by hand (`--show-current`, `--abbrev-ref`, `symbolic-ref` or `origin/HEAD`, or a run of `\d{2,6}` for the issues a branch names, #980), reads what a shell or interpreter runs or judges inline code its own way, or has a `tool.call` hook answering with a result that does not ask the screen in its own body, comments taken out first by `tools/lib/ts_source.py` and the rest of each line read (#732); no mod holds a known exception since #961 moved the last, scope-modes' gh argument reader, into mod-kit. A mod's tests may read with mod-kit's own readers through a byte for byte copy under its `tests/mod-kit` (a test cannot import another mod's files), which the scan holds to mod-kit's, naming the `cp` that brings a stale one back. The settled look of all mods is `docs/mods-design.md`. | #607 to #609, #605, #610, #663, #667, #688, #690, #698, #700, #703, #705, #707, #712, #726, #730, #743, #744, #939 |
| `session-registry` | One record per open session on this Mac in `~/.claude/state/sessions` (never synced): folder, repository, files edited inside its repository or any other git checkout (by the edit tools, or named by a shell command, noted by the collision guard; scratch such as `/tmp`, `$TMPDIR` and the scratchpad is left out, as is a file in no checkout), transcript path, a beat every minute, closed on a clean end, dead after five quiet minutes. A record that ended over an hour ago moves at the next session start to `~/.claude/state/sessions-archive/<the UTC day it ended>`, never deleted on the way, unless it still names background jobs, which the job watcher reads for its full 7 days; a day's folder goes once that whole day is 7 days past (#633). The list reads again only the open records and files the folder listing shows changed, and answers inside a limit of its own, short of the engine's, or refuses, which the collision guard turns into a refusal of the call (#911). After a /clear or a resume, which go on under a new session id with no session start, the new conversation's record is made once the /clear's (or the /resume's) own command has run, or at the first write or read of the list, never left to the next beat (#735). Never from the classic SessionStart that announces the start: Claude Code's built-in security default, seated on a Team or Enterprise organization as both Macs are, sends every classic hook event past the mods a person installs, so no mod here ever sees one (#751); a write queued before the session ended stays on the old record. An end that keeps its id stops being asked about once that command's look or the beat has looked, and a write made while the id cannot be read is held for the record the next look names, never failed and never put on the closed record, said once in the debug log (#739). Read through `$.sessions` by the collision guard, the job watcher and the goal tracker. Records are written whole and moved into place; one that cannot be read is named, never read as no session. | #605, #611, #612, #700, #911 |
| `collision-guard` | Before an edit to a file another open session has edited (by the edit tools, or by a shell command that names the file, read by mod-kit's one write reader since #712: a redirect, `tee`, `sed -i`, `perl -i`, `touch`, `truncate`, `cp`, `mv`, `rm` or `unlink`, and `rm -r`, `mv` or `find -delete` of a folder holding it, inside a subshell or a shell's heredoc too; a script's writes are not seen, docs/mods-design.md), or a checkout wide git command (checkout, switch, `branch -D`, `reset --hard`, `stash pop`, `add -A` or `.`) in a checkout another open session works in, asks Sonnet for Proceed, Worktree or Stop with the other session's latest request (read from its transcript). Proceed is a toast; Worktree and Stop are the grey card plus a message and toast in the other session (a refused message is tried once more by mod-kit, then said on the card); a removal says remove rather than edit in both. An unreadable record or a judgment that cannot be had is Stop. It judges from `tool.check`, beneath every mod's `tool.call` hook and after the settings hooks, so a call any other guard refuses is never judged, told or toasted, whatever order the mods load in; only a call it judged and let through is noted as this session's edit. Until #875 it judged from `classic.PreToolUse`, which the security default sends past every mod, so it never ran. | #605, #654, #674, #700, #707, #712, #875 |
| `secret-guard` | Refuses commands that print a secret (`cat .env`, `echo $TOKEN`, bare `printenv` or `env`, an uncaptured `gh auth token`), refuses any tool input carrying a known secret or a token shaped value outside a `.env` file, and scrubs secrets from tool results before the transcript keeps them. A call another mod answers itself never reaches its `tool.call` hook, so that mod asks first through mod-kit's screen, which asks `$.secretGuard.screen`: the same check, card and toast; a check that fails refuses. Values come from the environment, the project's `.env*` files and the gh token, held in memory only. No override. | #607, #707 |
| `keystroke-guard` | Synthetic input (osascript keystrokes and clicks, cliclick, Peekaboo) must name its target as `TARGET_APP=<executable path>`; it is refused unless that executable runs exactly once, no other copy of the app runs, and the frontmost pid (read separately) is that one. A heads up is asked once per app and holds until 10 quiet minutes pass. Focus stealers (`open -a`, `activate`, `set frontmost`) get the heads up only. It decides from `tool.check`, beneath every mod's `tool.call` hook and after the settings hooks, so an action another guard refuses is never asked about; a check that fails refuses. Until #875 it decided from `classic.PreToolUse`, which the security default sends past every mod, so it never ran. While Dan is away the action is held through scope modes for the held card, worded as scope modes' own held calls, and never asked in the band; an away check that fails refuses, its toast saying the away check could not be read rather than that the action was judged. | #608, #707, #732, #875 |
| `simpler` | After an answer over 250 words, or from 80 words with at least 6% technical terms (identifiers, paths, flags, issue numbers, code lines), a Simpler button at the top of that answer, drawn into the reply; where a click may not land (Apple Terminal, a terminal's main screen, as `$.modkit.clickable` answers) it reads "type: /simpler" instead, and `/simpler` asks the same way (#939). Pressing it asks, as Dan, for the same answer in 2 to 3 plain sentences, any open decision restated, and one example from the session's project; it goes once Dan types or a newer answer does not earn it. Each press is kept in the mod's store (this Mac only) with the kind of answer it followed, and once a week a session start shows one dim line naming which kinds needed simplifying, claimed on this Mac first (`~/.claude/state/simpler/weekly.lock`) so two sessions starting together show it once. The reply is drawn by whatever sits beneath the mod, so beside add-on notes a long reply opening with the resume line reads the dim line, then the button, then the answer, whichever mod sits outermost; it asks add-on notes where that line ends. | #619, #701 |
| `auto-session-name` | Names an unnamed interactive session once: 10 minutes after it starts (a setting the mod holds, not measured), or after its first exchange when nothing was asked by then, with one Haiku call over the opening request and the recent messages. Never overwrites a name already there (a resumed session's, or one Dan set with `/rename`, even during the 10 minutes). Sets the name with the built-in `/rename`; when that refuses or does not confirm, returns it as `sessionTitle` on Dan's next message unless that message shows it already took. Every name it sets starts with the session's repository in brackets, `(claude-config) Sleep mode phase 3`, read from `$.session.repo()` when the name is set and named by mod-kit's one reader (`$.modkit.repo`, #951): the origin's repository name in lower case, else the name of the project's main checkout folder (`$.session.repo()` gives the main working tree even for a session in a linked worktree, measured on Claude Code 2.1.295, #996), else no prefix. This repository's prefix already there is never doubled. Any other bracket at the start, `(v2)`, `(wip)` or another repository's name, is kept as part of the name, since no shape tells them apart, and the prompt asks Haiku to start with none. The name made is kept without a prefix and the repository is read when it is set, so a session that moved is named for where it is; the prefix counts toward the 60 character cap and the name after it is what gets shortened, at a word. A repository that cannot be read still gets the session named, without the prefix, and one dim line says so (#945). Silent on success; a failure is one dim line and exactly one retry at the next idle point, which a failed write at the 10 minute mark does not lose. One Haiku call per session: an attempt keeps its claim while `/rename` waits out a long turn, and the name made is kept for an attempt that takes over from one a reload cut off. Skips `claude -p` runs and subagents. The built-in `/rename` route was confirmed on the live build on 2026-10-05: it named a real session on this Mac (#713). Replaces the retired `session-namer.sh` hook. | #635 |
| `style-check` | Refuses writes, commit messages, `gh issue`/`gh pr` bodies and Slack messages carrying an em dash, en dash or emoji, by running `hooks/lib/style-scan.py --plain`, the same scanner `check-style-guide.sh` runs at push. A chat reply cannot be refused, so it gets a toast and a count. | #609 |
| `status-bar` | The grey status line under the prompt and the amber needs-a-look line above it. `statusline.sh` in the mod's folder is the classic status line command: project (with its Supabase project, `SB <name>`, from `SUPABASE_PROJECT_NAME` or `SUPABASE_URL` in the nearest `.env`, where it has one), 5 hour and weekly limits (the share amber over 70% on the 5 hour or 85% on the weekly, red at 100%), cache time left, model and effort, account and org (or the account room's nickname for the account, when one is set), read from Claude Code's JSON, from the session's own account as the mod read the login file at session start (#815; a facts file from before falls back to the login file as it stands), and from the one fact only the mod knows (when the prompt cache goes cold, an hour after the last main request, cleared by a compaction or `/clear`), which the mod writes to `~/.claude/state/status-bar/<session>.json` (never synced, deleted when the session ends; a file it cannot write is said once in a dim line). In the band, through mod-kit: a scope mode in bold, a failing or running PR (kept as last read, with its age, when a refresh fails), the job watcher's jobs from `$.jobs` when it is loaded, each by state and owner (`1 job not progressing, left to Claude`, `dev server running 2h 14m`, `agent fix CI: PR 776 rerun wait waiting 12m`), and background agents quiet twenty minutes (`agent fix CI quiet 34m, left to Claude`), and unpushed commits (kept as last read, with its age, when git cannot answer); under it the Compact row with the context figure, when context passes 70% or the cache is 5 minutes from cold, with one toast at that moment, neither for the cache while a turn runs. `$.statusbar.setModes({ modes })` sets every mode that is on at once (`ASLEEP`, `NO BUILD` or `WINDING DOWN`, and `AWAY`), each bold and divided like the other items, or clears them with an empty list, for the scope modes mod; `setMode({ mode })` sets one. Behaviour settled with Dan on 2026-10-04; job wording reworked for #784. Each Mac's own `settings.json` names the script, and a pull writes that setting there when none is set (#772): `"statusLine": { "type": "command", "command": "bash <this Mac's ~/.claude>/mods/status-bar/statusline.sh", "refreshInterval": 30 }`. A `statusLine` pointing at anything else is left alone and named by `claude-sync status`. | #610, #697, #706, #772, #759, #784, #815 |
| `addon-notes` | A message starting with `+` typed while Claude works is an add-on: Claude Code already delivers it without stopping the turn, and the mod tells the model to fold it in at the next break, with the toast "Noted, applying after this step." After an Esc, a short reply that adds scope ("also...", "and...", "include...", "sorry keep going") tells the model to resume the interrupted step with the addition and keep the agreed scope; Claude opens with one line, "+ add-on: ... and carrying on.", which the mod draws dim. A redirect, or anything it is unsure of, is left exactly as typed. Only context is added; the words typed are never changed. Other mods read the resume line through `$.addonNotes.resumeLine({ text })`, the rule it is drawn by. | #620, #701, #744 |
| `is-it-live` | After a merge Claude calls the mod's card tool with what it found: the deploy as checked (`live` with how it was checked, `deploying`, `failed` or `unreachable` with why, `none` for no deploy step), what changed in 2 to 3 sentences, and the link and clicks to see it. The mod confirms the merge with `gh pr view` and refuses a card for anything not merged. The card's state leads its title (`Live:`, `Merged, deploying:`, `Could not confirm live:`), and it is toasted. When someone other than Dan asked (an issue another person filed, read with `gh issue view` and checked against every account `gh auth status` lists as logged in, all of them Dan's; a pasted Slack thread; a person Dan named), the message for them, in Dan's voice and with no dash, is pinned in the band (slot `message`, violet heading) with Copy and Mark sent, which work in any session whatever repository the card is for. A message waits until Mark sent: a later card for the same PR that names nobody keeps it, and one Dan marked sent stays sent. Cards are kept per repository in the mod's store, under the repository as GitHub's own link for the PR names it and in one case, so a card Claude typed in another case or under an old name is found; `/live` lists them and every unsent message. Other mods read the newest card's state for a PR through `$.isItLive.verdict({ repo, pr })` (null when no card has been made in this session; the repo in any case), which is how winding down knows the deploy is live. The card's result row is mod-kit's boxed card, its state word leading the title in green, grey or amber; the model reads the same lines as text, which is also what the row shows after a reload or when mod-kit refuses the card (Claude is told why). The call's own row above the card names the repository and PR alone, never the facts the card shows, and every answer tells Claude that Dan has already seen the card, so the reply does not restate it (#771). The card tool asks mod-kit's screen first, so a card or message carrying a secret is refused before GitHub is asked or anything is kept or pinned. | #617, #663, #707, #771 |
| `ask-before-saving` | Before anything reaches lasting memory (the memory folder, any `MEMORY.md`, `CLAUDE.md`, `AGENTS.md` or `LESSONS.md`, outside a temporary folder or inside a checkout there, which a session started in it loads) by Write, Edit or Bash (every write mod-kit's `$.modkit.writes` reads, a `cd` before it followed and a variable the command set (`F=path; ... "$F"`) read as its value, a patch or inline script whose text or patch file names lasting memory, an inline python program whose text names every file it writes judged by those files alone, never by paths its text only quotes (#830), and a target the words cannot name, such as a variable or a command's output, when the command mentions lasting memory anywhere; one in a command that mentions none goes through), refuses the write and asks in the band, with the exact text and the file: For good approves that save for 10 minutes (a chosen number, not a measurement) and asks Claude to send the same call again (a note while it works, a prompt of its own while it is idle, the call given whole), and the call that writes the same thing then goes through once, judged again by every other check and by auto mode's classifier (which refuses a call no model request asked for, so the mod never makes the call itself); an approval that lapses unused, or that the session ends before, is said. Just this session holds the rule in the system prompt's memory section until the session ends (a compaction keeps it), Not at all saves nothing. Asked from `tool.check` (#875; before it, from `classic.PreToolUse`, which the security default sends past every mod), beneath every mod's `tool.call` hook, so a save another guard refuses is refused before Dan is asked. Just this session's rule rides `prompt.section`, which the security default also sends past every mod, so it does not reach the system prompt today (#876). Each save asks under its own id, so a press answers only the save it was drawn for; a second save waits behind the first. Each answer reaches Claude as a note. Claude Code's own auto-memory writer saves through tool calls, so it is asked about too. Skipped when Dan's own latest message, typed or from his phone, gives the rule as an instruction to Claude ("from now on", or "always", "never" or "remember" leading a sentence or after "please", "you should" or "you must"; never "it ran and never finished"), and not when it limits it ("for now", "today", "this session"); then Claude is told to say what it saved. A hook that cannot finish refuses the write, and says why. It asks only after the settings hooks beneath it have decided, so a save the payload write gate refuses is never asked about. Dan's Add to LESSONS.md in the durable lesson check's picker (which carries `metadata.source` `durable-lesson` and the rule, stated word for word in the question) approves the one Edit or Write that only adds that rule to `~/.claude/LESSONS.md`, for 10 minutes, so he is not asked For good about it again; any other write still asks. | #618, #705, #707, #726, #743, #738, #867 |
| `design-round-guard` | Holds every edit that changes how a screen looks until Dan has settled a design round for its issue, or said to skip design rounds for it (Dan, 2026-10-08: "claude should never design something without my input"). Look changing: style files (`.css`, `.scss`, `.sass`, `.less`, `.styl`, `.pcss`), the Tailwind config, design tokens (`tokens.*`, `design-tokens.*`, `*.tokens.json`), screen and component files (`.tsx`, `.jsx`, `.vue`, `.svelte`, `.html`, `.htm`) and SwiftUI views (a `.swift` file whose text imports SwiftUI or declares a view, or whose text cannot be read), in every project, this repository's mods included; a file in no git checkout (a design round's own switcher in the scratchpad) is in no project and passes, and so does every other file, untouched. So does every test file (Dan, on seeing the guard, 2026-10-08: "On, but let tests through"): a `.test.` or `.spec.` part in its name, a `__tests__`, `tests` or `test` folder above it inside its project, and for Swift a folder ending `Tests` or a name ending `Tests.swift`; a name merely holding "test" (`latest.tsx`, `contest.css`) is still held, and a project checked out under a folder named tests is not let through whole. Written by any tool carrying a file path (Write, Edit, MultiEdit, NotebookEdit and any added later; only a tool known to read its path, such as Read, Grep, Glob or Artifact, is not judged) or by Bash: every file mod-kit's `$.modkit.writes` names, a removal or emptying of one, a program whose text names the files it writes, and a look changing file a patch or inline script only mentions; a write whose destination cannot be followed is held when the command names a look changing file anywhere (a glob such as `app/*.tsx` included), and runs when it names none. Kept per project (the main working tree, so every worktree shares it, read with mod-kit's `$.modkit.branch` and named by `$.modkit.repo`) under the issue the branch names, each one when it names several, else the branch; on the default branch for that session only, since every later issue may be built there; a new issue starts held. Settled is Dan's Settled to the design rounds skill's closing picker, "Is this design settled?" (`metadata.source` `design-settled`, with `issue` when the branch names none); skipped is his Skip them to "Skip design rounds for this issue?" (`metadata.source` `design-round-guard:<the refused call's id>`), as ask before saving asks. The guard words both questions and their answers itself and reads his choice from the dialog's own result; answers the call carries, his own typed words, a dialog that closed while he was away, a subagent's question and any write Claude makes record nothing, and a write to the guard's own record (`~/.claude/plugins/store/design-round-guard_*`) is refused, as is a shell write whose destination cannot be followed when it names such a file or the command names the plugin store. The refusal names the file and both ways on; a subagent is refused alike and told to stop and report the line the main session asks with. A branch, checkout or record it cannot read refuses, saying which. The main session's calls are judged at `tool.check`, after the settings hooks, so a call one of them refuses is never turned into a question; a subagent's at `tool.call`, where its loop is known. Answers kept in the mod's store on this Mac. | #978 |
| `scope-modes` | Per session modes, each leading the amber line in the band in bold through the status bar, all off when the session ends and none carried into a new one. Every phrase counts only as an instruction of its own (starting the message, a sentence, a line or a clause), never in passing and never in a question. **No build** (`/nobuild`, or Dan's "no coding yet", "stay read only", "read only for now", "just file, don't build"; never "read only" in passing): reading, research, tests, scratchpad notes, Claude's own memory and plan notes, read only SQL (whatever its strings say), GraphQL reads and GitHub issue, milestone and label work go ahead; edits outside the scratchpad, commits, branches, PRs, deploys and data changing SQL are refused with the grey card, the shell routes around it (redirects, `sed -i`, `awk -i inplace`, `ruby -pi`, `tee`, `cp`, `curl -o`, `wget`, `find -delete`, `rm`, inline scripts, `bash -lc`, a file command `xargs` gives its files to) included, every command and every file a call changes read through mod-kit's readers (#712). A script fed to python, node, ruby, perl or a shell by a heredoc, a here-string or echo is judged by its text, a shell's as the commands it runs; one piped in from anything else is refused as one it cannot read, with Claude told that inline code or a heredoc is read and judged. It guards the usual routes Claude takes, not a sealed box: routes found after #730 collect in #760. Only a real `|` feeds a command, so `cd repo && python3 --version` runs (#724). Inline code is found by each language's own options and judged by what it can do in that language (write a file, run a process, or build code at run time, which cannot be read), for python, node, ruby, perl, AppleScript, awk and sed, the refusal naming what was seen; a database client by every piece of SQL it runs and what it writes itself (`\o`, `\copy ... to`, `.output`). A check that throws refuses the call. Claude asks Dan "Switch to build?" through its `switch_to_build` tool, whose yes alone lifts it. **Winding down** (`/winddown`, "pause after this issue", "wind down now", "let's wind down"; never "winding down" in passing): the turn end is refused until the branch's PR is merged, its issues closed, the branch and worktree gone and the is it live mod's card for the PR says Live or no deploy step recorded (read through `$.isItLive.verdict`, never Claude's own report; deploying, could not confirm, no card yet, or is it live not loaded keeps it refused and says which). Turning it on again keeps the PR it found; on the default branch it follows the session onto a branch. Winding down finalizes everything the session has open: every PR the session or its agents opened (noted from what `gh pr create` prints, so another session's PRs never hold it) is outstanding until merged, whether or not the session's own branch has a PR, so none is left open waiting on Dan; its note, the `/winddown` context and the turn end refusal tell Claude to ask Dan right then with an AskUserQuestion picker, one question at a time, when a decision or sign off is needed, and merge once he answers, and asking is never refused as new work (#856). A PR stays open only on Dan's own answer to the `leave_pr_open` tool (#917): it reads the PR's head commit, asks him "Leave PR #N in owner/name open (why)?" with Leave it open or Merge it, and records only his Leave it open, against the repository, number and that head; winding down then lists the PR as left open by his choice (in the turn end refusal and the finish toast) rather than as outstanding, and a push after his answer makes it outstanding again until he is asked again. Any other answer withdraws an earlier one, a picker Claude asks itself is never read as his choice, and nothing is asked while he is asleep. New work (the next-issue skill, a new branch, `gh issue develop`, an agent for another issue) is refused, while an agent named after this PR or an issue it closes goes ahead; checked each minute, it ends itself with a "safe to close" toast. `/build` or "go ahead and build" turns either off, and "stop winding down", "exit no build mode" or "turn read only off" turn off only the mode they name. A message Dan types while a turn runs is read the same way, at Enter, as the engine's types document it (not yet seen live; a debug log line records each one and how many modes it switched); one asking to end the mode that is on in words that do not switch it ("winding down is done for today", never the name in passing or in a question) gets a note telling Claude to say it is still on and that `/build` turns it off (#805). **Away** (`/away`, "I'm stepping away", or "away" from the phone) and **home** (`/home`, "I'm back at my computer") switch every open session on this Mac, told through the session registry and `$.session.send`. Away, Claude is told to publish private claude.ai pages, and opening anything, AppleScript or JavaScript for Automation that takes focus or shows a dialog (or that it cannot read, a script file included, one `cat` pipes in too), cliclick, Peekaboo, a browser tool opening a page (Playwright, Chrome) and the Artifact tool's open action are held; at home each session shows a boxed "Held while you were away" card, one row and button per held thing, and nothing runs until pressed. A message from the phone while home ends the reply with "You're on your phone. Reply away to switch every session." Other mods hold their own items through `$.scopeModes.hold({ label, prompt })`, which answers a held call's card and refusal in this mod's own words (the keystroke guard holds its actions that way). `switch_to_build` asks mod-kit's screen before showing Dan the change. **Sleep mode** (#840, phase 1 of the Sleep mode milestone) is the whole Mac's, not a session's: `/sleep` writes one record, `~/.claude/state/sleep/current.json` (`v`, `generation`, `since`, `until`, `night`, `bootTime`, `bootSession`, `report`, `startedBy`, `workers`, `placeBefore`), whole beside it and linked into place, so two `/sleep` at once place one record and a second `/sleep` only says when and where sleep started; it enrols as `workers` this session and every open session that told the session registry it has a person at its prompt (a `-p` or detached run never). While it holds, every session shows ASLEEP first in the band and is kept quiet as away (what away holds is held, whatever the session's own place, and the held card is not offered until wake). It ends by itself at noon ET the day after the night (before noon ET counts as the night before), or on a new boot (told by `bootSession`, which only a restart changes, else by `bootTime` within 300 seconds, since a clock correction moves it): the first session to see that, each minute, moves it aside to `ended/`, notes why in `notes/<generation>.jsonl` and notifies once. `/wake` or Dan's "I'm up" moves it aside too, and only the session whose move succeeds acts, putting every session back where Dan was before sleep. A record that cannot be read reads as awake (a mute that cannot say when it ends never holds), `/sleep` leaves it and `/wake` clears it. Whether the Mac is asleep is one predicate read afresh at every decision, `readSleep` here and `sleep_active` in `hooks/lib/sleep.sh` for the shell, both held to one fixture set (`tests/sleep-fixtures.ts`). While asleep nothing pages Dan (#841): a question (AskUserQuestion, or `switch_to_build`) is refused in every session and noted for his morning report in the night's notes, Claude told to leave what needs him and carry on; other mods ask through `$.scopeModes.isAsleep()` and note through `$.scopeModes.sleepNote({ kind, ... })` (the goal tracker sends no notification, ask before saving notes a save rather than asking); the turn end sound (`hooks/turn-end-sound.sh`), the session reflection and issue review, the PR quiz, the lesson fan out notice and claude-sync's desktop alert (written to its log instead) all stand down. `tests/test-sleep-silence.sh` derives every route that can reach Dan (settings hooks on turn end and waiting events, every mod's notifier, sound, question and classic Stop, Notification or PermissionRequest hook, claude-sync's `notify`) and fails on one that neither reads the sleep record nor sits on its exempt list with a reason, then runs each shell route asleep and awake. The night's report (#835), `~/Downloads/Sleep report <night>.md`, is written from the first minute of `/sleep` (start time ET, power, workers), rebuilt after every note, and once more at wake or the limit with done read from GitHub and checked against the notes, sessions and claims that went quiet flagged, each rate limit wait and paid usage; every note, the noun's and the shell's `sleep_note` in `hooks/lib/sleep.sh` alike, goes through `hooks/lib/sleep-report.py`, which writes it. An enrolled session is kept working overnight (#844): each Stop is blocked with the overnight rules, counted by its own counter on disk, until a circuit breaker (3 blocks or 20 active minutes with no new commit, claim or note), the night's cap, the weekly limit at 95% or an hour with no weekly reading lets it stop with a note; a claim is parked after 2 attempts or 2 active hours; a rate limit or server error is waited out at waits of five, ten, twenty and forty minutes, then hourly, each wait noted, and the session started again; `/sleep` refuses on battery and holds `caffeinate -i` for the night. While asleep (#834, phase 3, Dan's "everything not banned"), a worker session's own permission prompts are approved, never a question or the plan approval and never over a decision beneath; a classifier refusal is noted as `failed` and never retried; and in every session the ban list in `hooks/overnight.ts` is refused by effect (issue, label and milestone writes, every gh write but a comment, opening, readying, retitling or merging a PR on the checkout's own repository, any write whose repository cannot be resolved, LESSONS.md, write tools under claude.ai, Chrome and PostHog, Supabase and psql writes, a branch switch in a primary checkout, force pushes, branch deletes, `claude-sync` pull and install). At wake, the overnight check reads GitHub and the disk for issues created, milestones touched, LESSONS.md changes and deploy runs since sleep began, and notes each for the top of the report. What may merge and deploy overnight is per repository (#843): `mods/sleep-repos.json` lists `mergeOnly` (never deploy; a merge runs only where `mergeDeploys` is false, and true or unsaid leaves the green PR open) and `mayDeploy`, and `waitOwners` names owners every repository of which waits (no merge, no deploy), listed or not, in any case and ahead of both lists. Dan's list as confirmed on 2026-10-07: Bidspoke and Slate and everything owned by Halo-lab-Trypennie wait; claude-config, project-enrollment-tracker, paperboi, sonar, new-agent-onboarding, repo-digest, Overture, Ovation, Downbeat, PostRoll, backstage, PlayedIt and NurseDex merge and deploy. At `/sleep` each worker's repository the file does not decide is asked about (each question waits ten minutes, a chosen limit, not a measurement; the answer written into the shared file so it is asked once; "Go to sleep now" asks nothing more), every entry is checked with `gh repo view` under each logged in account, and the result goes into the record as `repos`; while asleep, merges, deploys and any push to a default branch are refused by effect against it, and everything without an answer (no file, both lists, neither list, unknown to GitHub, unanswered, met after sleep began) has no merge and no deploy that night and is noted for the morning report. After those, in the same ten minutes, `/sleep` asks the open questions on the queue's issues (#836): each `question` a worker noted overnight with its repository, issue and text, still unanswered and its issue still open, one at a time in Claude Code's own dialog, a question more issues wait on first, then the issue with fewest questions left, then the more urgent issue, each with "Skip this one" and "Go to sleep now" (anything typed is the answer). Each answer is posted on its issue as Dan's decision, dated in ET with the question quoted, and recorded so it is not asked again; every issue a question was left on is written to `state/sleep/unanswered/<generation>` before the record, so the night's queue leaves it out (a list that cannot be written stops sleep starting), and the question is noted again for the morning report. Waking (#837, Dan's decisions of 2026-10-07): only `/wake` or "I'm up" ends sleep, in every session; a message from Dan between 7 AM and 7 PM ET while asleep has Claude ask once a night, in a plain line, whether he is up (`isDaytimeEt` in `hooks/sleep.ts`, tested at both edges in each season and on both change days). The one session whose move of the record succeeds opens the finished report with BBEdit's helper and `--front-window` (else `open -a BBEdit`, never a bare `open`), saying in the same reply that focus moved; away, or woken from the phone, it waits in the held card instead, and at the noon limit nothing opens. That session asks each other worker still open for its own summary (one that closed or could not be told is said), and summarises its own night in a turn of its own after `/wake` or in the turn "I'm up" starts, then offers what the workers proposed, since nothing is filed and no lesson is added overnight: the proposed issues (`repo`, `title`, `priority`, `labels`, `milestone`, as the overnight rules ask workers to note them) in the end of turn issue review's multi select picker, each option ending with its proposed priority, labels and milestone so Dan can correct them, and each proposed lesson in the durable lesson picker with its `durable-lesson` metadata, filing or adding only what he selects (`hooks/wake.ts`). Text overnight sessions wrote reaches what Claude is told only through `hooks/overnightdata.ts` (#922): the proposals, what waking found (it quotes titles made overnight) and the claim queue's answers in a Stop block each go in one `<untrusted-overnight-text>` block, where only that name is neutralised (in any case or spacing, so nothing written can close or forge the block) and every other character is left as written, since a lesson's rule goes word for word into LESSONS.md, after a sentence saying it is data, never instructions, and naming the only picker it may be offered through (or none); the summaries are told the night's notes are data too. The before bed questions are not framed: Claude Code's own dialog shows them to Dan, and Claude never reads them as an instruction. | #616, #621, #707, #712, #730, #805, #834, #835, #836, #837, #840, #841, #844, #856, #843, #917, #922 |
| `manual-steps` | The steps card. Claude hands Dan manual steps through the `steps` tool, which refuses a step with no direct link or exact location, or one Claude has not said it checked against the current state. The card is a side pane when a pane opened unasked fits (144 columns), else the `steps` row of the band, both drawn by mod-kit (`$.modkit.pane` and `$.modkit.bandRow`); a pane mod-kit refuses is never opened, and the card goes to the band; `/steps` shows it again, in a pane of its own id so asking never lowers the width a later card opened unasked needs. Only the next step is open (title and Done, its link as Claude Code's Link with Copy link, or its location, its clicks, a value with Copy; a long location, click path, link or value wraps under the amber rule rather than being cut, #734, #939). Where a click may not land (Apple Terminal, whose per tab Allow Mouse Reporting no mod can read, or a terminal's main screen) the buttons are not drawn: Done reads "type: step N done", and the link, on a line of its own under "Where:", and the value are text to select (#939); finished steps are struck through with how and when they finished, grey only for one found already done or finished in an earlier session, so a step done this session never reads as old, and a step Dan pressed Done on reads differently from one Claude recorded per you (#886). Done sends "step N done", and Claude answers through `steps_done` (checked, per you, or not done), which takes those only on the open step and refuses any other, telling Claude to ask Dan which step he means (#886); when the turn that prompt started ends with no answer, Done comes back with a toast, and so it does when that prompt starts no turn at all (dropped from the queue by Esc, or refused by a prompt hook) once no main turn has run for two minutes (#734). Unfinished steps are kept per project (the repository root, the main checkout's for a worktree) in the mod's store and held at the next session start there until Claude re-checks them, a step held under both the root and a pre-#708 worktree key listed once; a reload mid session keeps the live card. While Dan is away, a new card goes to the scope modes mod's held card (`$.scopeModes.hold`) instead of the Mac. Both tools ask mod-kit's screen first, so a value carrying a secret is refused before it is drawn with Copy or kept. The heading reads "waiting on you" while the open step is Dan's to do (not once its Done is sent). At the turn's end (`classic.Stop`), a final message from Claude that leaves Dan a step in prose ("waiting on you", "once you run", "you'll need to run", "needs you to paste", "your step", never one negated right before it or quoted) with no unfinished step on a card he can see is blocked once, telling Claude to check the step and pin it with the `steps` tool; never twice in one chain of turn ends (`stop_hook_active`), and never in a -p run. Behaviour in `docs/mods-design.md`, "Manual steps behaviour". | #614, #707, #708, #863, #886, #939 |
| `picker-manners` | Claude Code's own question dialog asks every question (decided with Dan 2026-10-05, #744). The band question it was built with is removed, with what only the band made possible (a typed message withdrawing a question, numbered prose answers, and the limit on asking a question talked past twice): it waited for Dan's press through the mod's own `$.pickers.wait`, and Claude Code cuts a plugin's own `$` noun off at 10 seconds ("did not answer within 10000ms"), so the dialog then asked every question a second time; `claude plugin test` does not apply that limit, so its tests had passed. More than one question in a call, or none, is refused. `no next issue` or `just give me the list`, typed at the Mac or sent from his phone, refuses next issue pickers (those the `/next-issue` skill tags with `metadata.source: "next-issue"`) for the rest of the session and tells Claude in its system prompt to offer next issues as a plain list; `/pickers on` brings them back. | #615, #703, #726, #744 |
| `job-watcher` | Records every Bash background job, one Claude Code moved there at its timeout included (not Monitor tasks, which end at their own timeout), with its process group (traced through its output file, never by command text) into the session registry. Each minute it looks at each job: one repeating a pass of up to four lines or silent ten minutes is said to Claude once a spell, and a poll loop whose repeated pass holds an error is stopped by itself. Claude keeps a job on purpose with the `keep_job` tool and a reason; until then every tool result names the unkept job, a refused one included. A job Claude stops, or Claude Code reports ended, is dropped at once. The turn end is never refused. Leftovers are judged at session start only once the Claude Code process that started them has gone (read from the job's process group, never from the registry), by one session at a time (a claim folder in `~/.claude/state/job-watcher/claims`), by Haiku, then Sonnet, stopped only when measured stuck, and summed up in one dim line. Each job records the background agent that started it, and its reminders and notices go to that agent while it runs, to this conversation once it has ended; a poll loop gone quiet is waiting, never stuck; an untraced entry whose output file is gone is dropped (#784). A background agent listed as running with no tool call started or finished for twenty minutes is said to this conversation once, with its last tool call (#759). A session list that cannot be asked is said as such and asked again once a minute later; an unreadable record is named (#753). The status bar reads this session's jobs through `$.jobs.list()` and the quiet agents through `$.jobs.agents()`. A look still running is never overlapped by a second, a session start's included; one that has not finished in ten minutes is given up, said to Claude once, and acts on nothing after, and no second stop is sent while one is unanswered. Keeping a job asks mod-kit's screen first, so a name or reason carrying a secret never reaches the status bar. | #611, #694, #706, #707, #753, #759, #784 |
| `goal-tracker` | Records each session's task list, goal text (the `/goal` condition, else the first request cut to six words, typed or a handoff's opening prompt), activity, waiting on Dan (a question, a save waiting in the band from ask before saving, or a permission) and failed (three failing or refused calls in a row, a refusal by any mod counted from the result's row) into the session registry, beginning again at a session start and at a `/clear`. While any call runs its activity is written each minute, so a long test suite is not a stall. A permission prompt is held by the running call whose arguments it names, never by its tool and wording, and comes off when that call returns or rejects; a question, a save and a permission are kept apart, the pane showing the latest, so one ending never erases another. A question is marked from its own `tool.check` hook (#875) once every guard and settings hook has let it through, and notified a second after, if it is still open then (Claude Code's own dialog asks every question since #744, so the tracker no longer reads picker manners' open question). So a question refused at once, or by a secret scan however long it takes, is never marked or notified. `/goals` opens a live pane of every open session on this Mac, closed by Dan's next message. Sends the macOS notifications for a question, a save waiting in the band, a permission and an idle "What's next?" (with `terminal-notifier`), which replaced the two settings hooks that sent them, and sends none while the Mac is asleep (sleep mode, read through `$.scopeModes.isAsleep()`, #841); a check that fails counts as awake. | #612, #694, #706, #732, #744 |
| `handoff` | `/handoff`, run only by Dan, asks Claude to write the next session's opening prompt and save it with the mod's `save` tool, which refuses unless `/handoff` ran in that session. One per repository, kept in `~/.claude/state/handoff/<repository>/` on this Mac (never synced), keyed on the repository's main working tree so every worktree of it shares one; a new one archives the one it replaces. At the next interactive session start in that repository, the band shows `Handoff saved 3h ago: <title>` with Use and Dismiss, after re-reading from GitHub every issue, PR and milestone it names: each one closed, merged or changed since gets a grey line of its own (`changed since: #615 closed`), and one GitHub cannot be asked about says so. Use submits it as Dan's prompt; Use or Dismiss moves it into `archive/` in one step, so two sessions cannot both take it, and nothing is ever deleted. The save asks mod-kit's screen first, so a handoff carrying a secret is never written. | #613, #707 |
| `account-room` | Records every 5 hour and weekly reading a session receives (the engine's `session.measure`, the one recorder: the status bar reads its figures from the status line JSON and records nothing) under the account and org the session started on, keyed by a hash of their ids, off the measurement's own path. Each Mac writes only its own file, `readings/<LocalHostName>.json` in a private GitHub repository (the `readingsRepo` setting, default `danwright32/account-room-readings`, through `gh api` over the file's sha so a stale write is refused, never forced), and only when a figure the card shows moved or its newest reading is over 10 minutes old; it reads every Mac's only while the card is up, keeping a good read for a minute, and keeps the newest figure per account and window, judged by the figures rather than when a session read them: a later reset time wins, then within one window the higher use, the read time breaking only an exact tie (#848). gh must be logged in on each Mac to an account that can see the repository. Whatever GitHub could not give (a file, the whole folder, this Mac's own save) is named in the card in gh's words, never dropped. At 95% on the 5 hour limit or 90% weekly, a boxed card in the band names the account with the most weekly room among those with more room on the limit that triggered it, with Switch (sign claude.ai out in the browser, confirmed, then `claude auth login --email`) and Dismiss (this session only); or says no account has room, with the soonest reset and every account with no reading yet. The first session on an account asks once for a nickname; `/accounts rename` changes one. Nicknames are `mods/account-room-nicknames.json` in the payload, so both Macs share them; each entry carries the time it was recorded, so two Macs' answers merge entry by entry (a name beats a skip, the later of two names stands), and a copy the sync set aside as `.conflict-<Mac>` is merged back at the next session start and moved into the mod's state folder. The card sits in mod-kit's `room` slot, after the status rows and before the handoff card. The browser is chosen per Mac by `bin/browser.sh` (#808), the manifest's default: Safari on Daniels-MacBook-Pro-2 (`bin/safari-logout.sh` opens claude.ai's logout page in Safari, and `bin/safari-signed-out.sh` waits up to about 50 seconds for Safari's cookie store to hold no live claude.ai session cookie; not yet proven at a real Switch), and on Dans-MacBook-Pro the Chrome route, proven on Daniels-MacBook-Pro-2 on 2026-10-05 and on Dans-MacBook-Pro on 2026-10-07 (#786) (`bin/chrome-logout.sh` loads claude.ai's logout page in Chrome's last used profile, and `bin/chrome-signed-out.sh` waits for that profile's claude.ai session cookie to go). A Mac named in neither is refused by name. With either setting emptied Switch stops at its first step. The red card says which way it stopped (no route set up, the logout command failed, the check could not run, the check did not confirm, or a reload cut it off). Behaviour and look settled with Dan on 2026-10-04 (`docs/mods-design.md`). | #659, #736, #747, #750, #808, #848 |

Two things are deliberately not carried:

- `.claude-plugin/types/`, which Claude Code writes into every plugin folder on every load,
  describing that Mac's build and MCP tools. It is excluded on both sides of the mirror.
- A `*.local.json`, which every synced folder keeps to its own Mac (see "What NEVER syncs").
- Nothing else. A mod's own `tsconfig.json` IS carried: the engine writes one only where none
  exists and leaves an existing one alone (measured on 2.1.288). So every mod ships its own:
  `tools/check-mods.sh` fails a mod without one, because the copy the engine would generate is
  otherwise sent up to main as a local edit (two arrived that way on 2026-10-04, #638).

Before a push, `tests/test-mods.sh` runs `tools/check-mods.sh` over `payload/mods`, which validates
every mod and runs its own `*.test.ts` and `*.test.tsx` with `claude plugin test`. Where no `claude` command exists
(CI's Linux runner) it reports UNMEASURED rather than a pass, and the same, with its own exit code
and the engine's words, when `claude` answers that hooks modules are turned off in this process
(its cached rollout switch saved off, or a setting such as `disableAllHooks`), which no test can
set; it never counts that as every mod failing (#740). A failure carrying no verdict line names the
exit code and the last lines of output instead of an empty reason.
It also fails a mod whose hook is on an event Claude Code's built-in security default sends past
the user tier every mod loads in (#875): every `classic.*` event, `prompt.section`, `prompt.context`,
`prompt.compose`, `skill.prompt`, `attribution.text` and `settings.read`. Seated outermost for a
Team or Enterprise organization, it routes each of those straight past our mods, so such a hook
never runs and only a debug log line says so (`bypassed by cc-plugin-sec-default`). Both Macs keep
it out of first place with the managed settings file in "Setting up a new Mac" above, so these
hooks do run there, but only while that file is in place (#876). A check that must run beneath
every mod's `tool.call` hook and the settings hooks still belongs in `tool.check`. The hooks on
these events are listed by mod and event in `tools/sec-default-bypassed-hooks.tsv`, each with the
issue deciding it (#876), so a new one is a decision to depend on that file rather than an
accident, and a listing for a hook that has gone fails too. This part reads only the files, so it holds on CI. Where a
`claude` binary is found, the list is compared with that build's own routes, and a difference fails.
It also type checks each mod strictly (#758), as the mod's own `tsconfig.json` says, with the
TypeScript compiler pinned in `tools/typescript` (#803; TypeScript 7.0.2, installed once per checkout
with `npm ci --prefix tools/typescript`, and on CI before the suites; `TSC_BIN` overrides it, and
`tsc` on the path is the last resort). The types it checks against come from this repository alone
(#953), never from an installed copy: Claude Code lays a mod's types only in the copy it loads, and
their MCP part lists whatever tools the session had connected when that copy last reloaded, so a
check that borrowed them gave the same tree a different verdict from one hour to the next
(manual-steps' matchers on its own tools failed on 2026-10-08 with no change to manual-steps) and
none at all where nothing was installed. Each mod is checked in a scratch copy beside
`tools/typescript/claude-code-types/`: one Claude Code build's engine API (`claude-code/`) and
built-in tools (`claude-code-tools/`), whose first line names the build, an MCP list declaring no
tool (`claude-code-mcp/`, so the engine's own fallback accepts every `mcp__<server>__<tool>` name
with loose arguments; a misspelled name of that shape is not caught, which it only ever was while
its server was connected), and a `tsconfig.json` to which each mod's dependencies are added. Any
types laid in the mod's own folder are replaced, never written through. A dependency's contract is
the file its own `plugin.json` names as `types`, read from the folder under review (#840), so a
change made to a mod and its dependency in one PR is checked as one; a dependency the folder does
not hold fails the mod by name. None of this needs Claude Code, so the type check runs before the
`claude` lookup and holds on CI's runner too, where a type error fails the run rather than hiding
behind the UNMEASURED exit. The check allows the `./x.ts` imports every mod uses itself
(`--allowImportingTsExtensions`), since the laid tsconfig does not, so no mod needs its own copy of
that setting. Errors fail the run with the mod named and counted, except a mod listed in
`tools/typescript/known-type-errors.tsv` (empty since #822 fixed the errors the first run found,
2026-10-05, in 12 mods), kept by file and error code, which passes while each file and code is at or under its recorded count and fails on any beyond it, so fixing one error makes no room for a new one. A compiler
that exits without any type error is said as that, never as 0 errors. Where no compiler is found,
each mod's line says its types were not checked and why, and the run says UNMEASURED, counting them
and naming the install command, which is not a failure. `claude-sync status` names a sync clone
where the pinned compiler is not installed, with its `npm ci` command (the apply does not install
it, which would put npm and the network on every pull). The pinned types are Claude Code 2.1.294's
(2026-10-08, all 19 mods clean). A run on a Mac with another build says so and changes no verdict;
to move the pin, run `bash tools/refresh-claude-code-types.sh` once a mod has loaded on the new build
(it copies the engine and built-in tool types from `~/.claude/mods/mod-kit/.claude-plugin/types`, or
a laid folder named as its argument, cuts the tsconfig's types back to the three, never takes the
session's MCP list, and leaves out every line that is wholly a comment but the engine's first, since
comments carry no types and Claude Code's carry dashes and words the push gates refuse, refusing
outright where such a character sits in what is kept), then run `tests/test-mods.sh` and
commit the result with whatever the newer types ask of a mod. On 2.1.292, nineteen stand-ins
returned their object cast to `never`, which passes any shape; removing those casts showed eight of
them, in seven mods, hiding a missing member or a parameter narrower than the real one. Every one is
now returned uncast, typed with the real noun's types, and `check-mods.sh` refuses such a cast in
any mod file, by file and line, without needing Claude Code (#833).
It also runs `tools/check-mod-dependencies.sh`, which fails a mod whose `plugin.json` lists a
dependency its code never uses (neither a noun the dependency's contract declares on `$` nor the
dependency's name, comments left out by `tools/lib/ts_source.py`, which reads a regex literal and JSX text as what they are (#735), in any source file of the mod but its tests and contract),
or one that is no mod in the folder, whose contract cannot be read whole, or that has no source at
all (#694). It runs `tools/check-mod-noun-waits.sh`, which fails a mod whose own `$` noun waits on a
person (`$.ui.ask`) or on a promise only a later event settles with no timer under 10 seconds
settling it: Claude Code cuts a noun call off at 10 s (measured on 2026-10-05) and `claude plugin
test` does not, so such a noun passes its own tests and fails only in a session (#744). It follows
each call a noun makes to the function the TypeScript compiler's own checker resolves it to, through
`tools/lib/ts-resolve.mjs` on the compiler pinned in `tools/typescript`, so scope, shadowing and
parameters are the language's answer rather than the first function of that name in the mod (#895).
A promise kept in a variable outside a noun's code is linked to a noun's read the same way, so only
a read of that same variable counts, never another function's variable sharing its name (#915).
Run on its own, it refuses (exit 4, naming `npm ci --prefix tools/typescript`) where that compiler
is not installed. `tests/test-mods.sh` judges the compiler by whether it starts (a Mac's native build
copied to Linux is installed and cannot run), and where it does not, reports its noun wait checks
UNMEASURED with the same command, as the type check above does, rather than failing. Under `CI=true`,
where the workflow installs it, a compiler that does not start fails instead. (It no
longer checks ask before saving's waiting saves against the goal tracker: since #777 the question
is Claude Code's own dialog, which the goal tracker reads like any other question.)

## Sleep mode

Sleep mode lets the Claude Code sessions you leave open keep working on their issues while you
sleep, without anything pinging you, and leaves you a report in the morning. It belongs to the
whole Mac: each Mac has its own night.

**Starting it.** Type `/sleep` in any session. The sessions open at that moment with a person at
their prompt (not background or `claude -p` runs) are enrolled to work overnight. Before it starts
it may ask you a few questions, one at a time:

- for each enrolled session's repository that is not on the list below, what Claude may do there
  overnight: "Merge, never deploy", "Hold merges, never deploy" or "Allowed to deploy". The answer
  is saved for every night after, on both Macs, so each repository is asked once;
- any questions the overnight sessions left on an issue on earlier nights, the one that frees the
  most work first. Each answer is posted on its issue as your dated decision.

Every question has "Go to sleep now", which asks nothing more, and an issue's question also has
"Skip this one". The questions share one 10 minute wait (a chosen
limit, not a measurement); anything you leave unanswered gets the strictest choice for the night (no merge, no deploy, and an
issue whose question is unanswered is not worked) and is listed again in the morning report.
`/sleep` refuses when the Mac is on battery, so plug it in first. It keeps the Mac awake until the
night ends, and the band above the prompt shows ASLEEP in every session.

**Ending it.** Type `/wake`, or say "I'm up", in any session. If you write to a session between 7 AM
and 7 PM ET while sleep is still on, Claude asks you once, in a plain line, whether you are up; it
never ends sleep by itself. If you forget, sleep ends on its own at noon ET the next day (or when the
Mac restarts) and sends one notification. The session you woke it in opens the night's report in
BBEdit (focus moves there), unless you are away or woke it from your phone, when opening it waits
for you in the held card. That session then summarises its own night and offers what the overnight
sessions proposed: new issues in one multi select picker, with the priority, labels and milestone
each was proposed with so you can correct them, and new lessons one at a time. Nothing is filed and
no lesson is added until you pick it. Every other session that worked overnight is asked for its
own short summary.

**What it does overnight.** Each enrolled session takes one issue at a time from its repository's
open issues (priority p0 to p3, most urgent first), each in a worktree of its own, and works it as in the daytime: test first, a pull request, and a merge and
deploy only where the list below allows. It approves its own permission prompts, except for anything
banned below. It writes for you only into the report: a question it needs you to answer, a proposed
issue or lesson, or anything it noticed. An issue that takes two attempts or two hours of work is
parked for the morning. A session that makes no progress for three turn ends in a row, or for 20
minutes, is let go with a note. A usage limit or an overloaded server is waited out (5, 10, 20 and
40 minutes, then hourly, all night, each wait in the report). These limits are chosen, not
measurements. Work stops when the weekly usage
reaches 95 percent; if it is already there when sleep starts, each session stops at its first turn
end and the report says why.

**What it will not do overnight.** Ask you anything; file or edit issues, labels or milestones
(a comment is allowed); add lessons; merge or deploy anywhere the list below says wait, or anywhere it has no
answer for; push straight to a default branch; force push or delete branches; switch branches in
your main checkout; write to a database (Supabase, psql); use claude.ai, Chrome or PostHog tools that
write; run `claude-sync` pull or install; retry anything Claude Code's own safety check refused; or
work an issue someone else opened. No sound, notification or end of turn review reaches you. At
wake it checks GitHub and the disk for anything outward that happened anyway (issues created,
milestones touched, LESSONS.md changed, deploys) and puts it at the top of the report.

**Which repositories may merge and deploy overnight** (your list, confirmed 2026-10-07, in
`payload/mods/sleep-repos.json`):

- Wait overnight, no merge and no deploy (a green pull request stays open for the morning):
  Try-Pennie/bidspoke, Try-Pennie/slate, and every repository owned by Halo-lab-Trypennie, now and
  any added later (today that is Halo-lab-Trypennie/trypennie).
- Merge and deploy as in the daytime: danwright32/claude-config, Try-Pennie/project-enrollment-tracker,
  Try-Pennie/paperboi, Try-Pennie/sonar, dwright-pennie/new-agent-onboarding,
  dwright-pennie/repo-digest, danwright32/overture, danwright32/ovation, danwright32/downbeat,
  danwright32/PostRoll, danwright32/backstage, PlayedItApp/playedit and nursedexapp/nursedex.
- Anything else (eavesly-web-app, for one) is asked once at bedtime, as above, and waits for that
  night if you do not answer.

The file has three lists: `waitOwners` (owners every repository of which waits, which outranks the
other two), `mergeOnly` (merging allowed, deploying never; each entry says with `mergeDeploys`
whether a merge there deploys by itself, and only `false` lets the merge run) and `mayDeploy`. A
repository on both lists, or one GitHub cannot confirm at bedtime, waits.

**The report** is `Sleep report YYYY-MM-DD.md` in your Downloads folder, dated for the evening sleep
started (anything before noon ET counts as the night before). It exists from the first minute and is
rebuilt after every note, so it is there however the night ends. At wake it is finished: what was
done is read from GitHub (merged pull requests and closed issues) and checked against what the
sessions noted, with any disagreement flagged. Above that comes Needs a look (anything outward,
anything that could not be checked, and any session or claim that went quiet without saying why),
then Questions for you; below it Parked and failed, Proposed issues, Proposed lessons, Findings, and
Limits and usage (each wait on a limit, the usage readings and paid usage).

**Tested against the real engine.** `tests/test-sleep-real-engine.sh` runs one night with Claude
Code itself, in a scratch home folder and a scratch repository that never reach GitHub: `/sleep`,
two refused pushes, a permission prompt approved and one refused, a session kept working through
one issue by the overnight driver, the notes in the report, and `/wake` with its morning turn. The
model's answers come from a scripted stand-in, so it costs nothing and runs in every local test run
(`SLEEP_REAL_ENGINE=0` skips it); CI has no Claude Code, so there it says UNMEASURED. What it cannot
show, the first real night measures: an interactive session enrolled by `/sleep`, a real model
following the overnight rules for hours, and a real usage limit.

## Local state (per Mac, never synced)

Every file in the table below holds state outside `payload/` and belongs to the Mac that wrote it. All are gitignored,
so a fresh clone starts without them. (`lesson-bands/` and `lesson-citations.tsv` also sit outside
`payload/` and are the two exceptions: both are tracked and shared on purpose. A band nobody else
can see cannot stop anybody else claiming a number, and a record of what a citation was written
about is a fact about the shared payload rather than about one Mac. See Lesson numbers above.) A folder COPIED or RESTORED from a backup carries stale ones, which is why each has a
defined answer for being absent or untrustworthy.

| File | Written by | Read by | Missing or stale |
| --- | --- | --- | --- |
| `.last-applied` | every apply, and a `push` or `send` whose payload is fully applied here afterwards | the guard that blocks sending while behind, and the staging that holds back what the repo has changed | absent means nothing is protected yet, so sending is allowed. A `push` records it only when nothing was kept back, because this Mac may hold commits it has not applied and claiming otherwise would let the next send revert the other Mac (#511, #514) |
| `.mods-seen` | every send and apply (#606) | the send, deciding whether an empty `mods` folder is a deletion | absent or empty means this Mac has never held a mod, so an empty mods folder publishes nothing and cannot wipe the other Mac's mods; a stale list only means the next empty folder is read as a deletion, which is what it is if the mods were here |
| `.trees-seen` | every send and apply (#627) | the send, deciding whether an empty hooks, agents, commands, audits, mods or skills folder is a deletion | absent is read as the trees the commit this Mac last applied held files in (so a Mac upgrading to it keeps what it held), and no record at all, on a Mac that has applied nothing, means it held nothing; a tree not listed means this Mac has never held files in it, so an empty folder for it clears nothing from the shared copy and the send says so. An apply never drops a tree from it, since an apply can leave a tree empty by holding back this Mac's deletion of its last file; a stale list only means the next empty folder is read as a deletion, which is what it is if the files were here |
| `.last-success` | a successful pull, fetch or push | the outage clock | absent, unparseable, or dated in the FUTURE all mean "no record", which alerts rather than staying quiet |
| `.last-sent` | a push that went through | `claude-sync status` | absent means nothing has ever gone up from this clone, which is said in those words rather than shown as a date; a value that will not parse is reported as unreadable, never as never |
| `.last-received` | an apply that wrote at least one file | `claude-sync status` | same three answers as `.last-sent`. It does not move for an apply that only rebuilt the hooks block, since that is regenerated from whatever payload is present, including one this Mac just staged itself |
| `.hook-tests` | any run that reached a verdict on the hook suite it installed: `pull`, `sync`, the reconcile `send` falls through to, or `apply-only` | `claude-sync status`, in this clone and in any other clone on this Mac | absent means nothing has verified anything here yet and status says nothing, since it reports what needs attention. A record that will not parse is reported as unreadable, never as a pass. A pass is silent; every other outcome keeps its own wording, so a suite that FAILED and one that could NOT be run stay apart. It also carries how many suites ran and how many could not, with `?` where the runner's report could not be read, which is never written as zero. Since #218 it carries the measured wall clock too, and a PASS is no longer silent: it reports how long that run took against the deadline it is given, and says so plainly when it has used over half of it, so a suite outgrowing `SYNC_HOOK_TESTS_TIMEOUT` shows up as headroom shrinking rather than as a timeout on the day it runs out. A record written before that field existed says no duration was recorded, which is never folded into being within budget |
| `.resurrected-reported` | a send that refused to publish a leftover copy back over a deletion, and was told to keep it with `SYNC_ACCEPT_DELETIONS=0` | that same refusal, to say it once per file rather than on every edit. With the default, which removes the leftover, there is nothing left to repeat and nothing is written here | absent means nothing has been refused here, which is the normal state. Each line is the path AND a digest of its content, so a file that CHANGES is a new decision and is reported again, and a file the person deletes or edits stops matching. Losing it costs one repeated message and nothing else, which is why it is not treated as important state |
| `.unloadable-notified` | every send and apply, recording which skills folders each cannot load notice (not sent, not applied, kept local files a send will refuse) last named, an empty set included | those same notices, to post the desktop notification only when a folder is new to the set (claude-config#968) | absent or unreadable means the next notice is posted, which is the safe side: a repeated notification is noise, a missing one is a broken skill nobody hears about. Stale costs at most one skipped notification for a folder already named. A `.unloadable-notified.XXXXXX` beside it is a write that died before its rename, and is ignored |
| `.ci-unreadable-since` | the automatic pull, the first time it cannot read whether the shared repo's head passed its tests | that same gate, to decide when to stop waiting for an answer that is not coming | absent means the last verdict was readable, whatever it said, which is the normal state. It holds when the condition started and, once expired, when that was first reported, so the alert is raised on the transition rather than on every edit. Any readable verdict removes it, including a red one, because those mean the lookup is working. Expiring does NOT remove it: once the verdict is judged unobtainable, config keeps arriving until the lookup works again, since restarting the clock would deliver config in three hour bursts. A value that will not parse is treated as the condition starting now, which errs toward waiting rather than toward applying unjudged config |
| `.behind-skips` | a watcher send that found itself behind and whose reconcile did not clear it | `claude-sync status`, `claude-sync stuck` and so the per prompt notice, and the escalation that tells you once rather than on every edit | absent means sending is not stuck, which is the normal state and is said by saying nothing. It holds the count, the moment the run of skips started, and the moment of the last one; any run that gets through removes it, so the count is a measurement of the current state rather than a total that only grows. A count that will not parse is counted from zero again by the next skip, and until then status and the notice say the record could not be read, never that sending is stuck and never nothing |
| `.send-refused` | the secret scan, whenever it refuses a send (#947) | a `pull` or `sync` that has to set aside the uncommitted edits that refused send left in the clone, to name the scan's finding as the cause rather than leave git's complaint as the only explanation | absent means no send is being refused by the scan, which is the normal state. It holds when the scan last refused and the files it found. The next scan that passes removes it. A time that will not parse is left out of the sentence rather than guessed |
| `.ci-red-since` | the automatic pull, the first time the shared repo's head reads as having failed its tests | `claude-sync status`, `claude-sync stuck` and so the per prompt notice, and the escalation that tells you once rather than on every tick | absent means the shared repo's head is not red, which is the normal state and is said by saying nothing. It holds when the run of red verdicts started, how many there have been, and, once past its window, when that was first reported, so the alert is raised on the transition rather than on every automatic tick. The clock is on the CONDITION and not on the commit: keyed per commit it would reset on every push, and a push is exactly what keeps happening while somebody is fixing the red. Any readable verdict that is not red removes it, so the count measures the current state rather than growing for ever. Unlike `.ci-unreadable-since` it never expires into applying anyway: nobody can act on an unreadable verdict, and anybody can act on a red one, so the escape here is to tell a person rather than to lower the gate. Only the last field may be empty, because a blank middle column would be read as the one after it. A count that will not parse is reported as a record that could not be read, never as nothing |
| `.my-push` | the trap every mutating run passes through, when that run left this Mac level with the shared repo | the next run, to ask what became of it, and `claude-sync status` once the answer is in | absent means the last thing this Mac sent was judged and passed, or nothing has been sent, which is the normal state. It holds the commit, when the current run of failures started, and, once reported, when that was. The verdict is deliberately NOT waited for at send time: a run holds the lock and a test run takes minutes, so the sha is written down and a later run asks. A green or cancelled verdict removes it, cancelled because there is nothing to report about a run nobody finished (the workflow no longer cancels a superseded run on main, #594, but a run can still be cancelled by hand). A push made while it still stands keeps its start time and its reported marker and only moves the commit, so a run of failures is announced once rather than per push. A verdict that never arrives is given up on after the same window an unreadable one gets. Only the last field may be empty |
| `.send-suite-verdicts` | a send that ran a suite covering a hook it is about to publish | the next send, to decide whether that suite has to run again | absent means every relevant suite runs, which is the pre-#269 behaviour and only costs time. An entry is keyed on a digest of the whole staged hook set, so any hook edit retires it; a verdict is never reused across a change to what it judged. A `fail` is remembered exactly like a `pass`, because what it saves is re-running a red suite on every keystroke while the sync lock is held |
| `.resolved/` | a conflict resolved automatically because this Mac's version held nothing extra | nothing reads it; it exists so a wrong resolution is recoverable | absent means no conflict has resolved itself here. Entries are swept once older than two weeks, and one whose date cannot be read is KEPT rather than deleted on a guess, since this directory holds the only copy of something |
| `.claude-sync-clones` (in your home, not in a clone) | every clone on this Mac, the first time it takes the lock | `claude-sync status`, to find the records other clones hold | absent means no clone has done work since this was added, so status reports only what it can reach through the launch agents. An entry naming a clone that has gone is skipped rather than reported, and nothing prunes it: the file is only ever appended to, so a run that dies part way cannot lose the entries already there |
| `.claude-sync-watch.pid` (in your home, not in a clone) | `claude-sync watch`, on the way up, claimed so two watchers starting together cannot both write it (#604) | the next `claude-sync watch`, to refuse starting a second one, and every running watcher's loop before each send, which stops when the file names another live watcher or the watcher that started the loop has gone | absent means no watcher has started here since this was added, and the next one starts normally. The pid in it is confirmed against what that process actually IS before it is believed, because a stale pid is reused by the system constantly and a guard that trusts the number refuses to start over something unrelated. It is removed on the way out, and only by the watcher whose own pid it holds, so one watcher exiting cannot clear another's record |
| `.claude-sync.log` (in your home, not in a clone) | the scheduled and watch jobs, whose launch agents send their output here; the watcher one summary line per send, with whatever the send said indented beneath it, and a send that held files back logged as `NOT sent: <files> held back,` with its reason rather than as nothing to send (#849); and any send that holds the hooks block back, which appends its verdict with a time whichever entry point ran it (#592) | a person diagnosing a notification or a quiet sync | absent means no automatic job has run here yet. It is never read by the tool itself, so nothing goes wrong when it is removed |
| `.claude-sync-hold` (in your home, not in a clone) | `claude-sync hold` | the watcher's send, and `claude-sync status` | absent means no hold, which is the normal state. It carries an expiry and fails OPEN: once that passes it is cleared and the watcher says the hold expired, because a hold that outlives the session that took it silently stops the sync. A marker that will not parse is cleared too, and reported in its own words rather than as an expiry, since obeying it would stop the sync until somebody found the file and ignoring it silently would discard a decision somebody made |
| `.outage-log` | every outage decision | `claude-sync status` | absent means no decisions yet, and a line that will not parse is counted and reported as unreadable rather than skipped |
| `.sync-lock/` | any mutating run | every mutating run | a lock from THIS Mac whose process is alive is respected whatever its age; one from another Mac, or with no Mac recorded, is broken once older than an hour |
| `.sync-lock.next` | a typed `claude-sync pull` that finds the lock held, while it waits for it (#850) | every mutating run, before it takes the lock, so a run arriving while a pull waits does not take the lock in front of it | absent means nobody is waiting, which is the normal state. It names the waiting pull's process and is created by a hard link, so two waiters cannot both hold it. The pull removes it on taking the lock or at its deadline; one left by a process that has gone, or older than any wait could last, is removed by the next run rather than honoured |
| `state/` | every apply | nothing reads the local copy; it exists so a marker is only republished when it changes | absent just means the next apply republishes |
| `refs/claude-sync-state` | every apply, pushed per Mac | `claude-sync verify` | nothing published means "cannot be answered", never agreement; a Mac silent for 60 days is reported as retired |

None of this travels between Macs except the published refs, and those deliberately never
land on the config branch: a marker commit there is a commit the other Mac does not have,
which the send guard correctly reads as being behind, and every send is then skipped.
